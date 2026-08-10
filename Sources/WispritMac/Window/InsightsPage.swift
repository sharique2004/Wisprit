#if os(macOS)
import Foundation
import SwiftUI
import WispritMacUI
import WispritPersistence

/// Insights — `docs/design/ui-redesign.md` §3.5.
///
/// The page is three things stacked on top of each other, and only the last one
/// is a view:
///
///  1. `InsightsMapper` — the neutral seam. `WispritMacUI` cannot name
///     `MetricsSummary`, so this file summarizes `metrics.log` and hands the
///     result over as an `InsightsInput`. It is pure (rows + window + `now` in,
///     value out) and it is where the honesty rules that need disk knowledge
///     live: a row that never recorded an outcome is *named* rather than
///     silently bucketed, and a row that cannot be placed in time is counted
///     but not drawn on a day.
///  2. `InsightsPageModel` — the read. `MetricsWriter.readAll()` parses the
///     whole file, so it runs on `Task.detached(priority: .utility)`, is gated
///     on the file's `contentModificationDate`, and only ever runs while this
///     page is on screen and the window's own tick is armed (§3.5's threading
///     paragraph; the tick is off for the duration of an utterance).
///  3. The tiles, which decide nothing. `InsightsModel.tiles(from:)` already
///     decided which tile exists, which one degrades to a placeholder and what
///     the placeholder says; everything below just draws the case it is given.
///
/// `DoctorFacts.metrics` is deliberately NOT reused: it is a fixed 14-day
/// window and it rides the expensive full probe (§3.5's note).

// MARK: - the window control (§3.5)

/// The segmented control's three options. In memory only — a window choice is
/// not a preference, and writing it to `config.json` would make a glance at a
/// chart a config edit.
public enum MetricsWindowChoice: String, CaseIterable, Identifiable, Sendable {
    case days7, days30, all

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .days7: return "7 days"
        case .days30: return "30 days"
        case .all: return "All time"
        }
    }

    public var window: MetricsWindow {
        switch self {
        case .days7: return MetricsWindow(days: 7)
        case .days30: return MetricsWindow(days: 30)
        case .all: return .all
        }
    }
}

// MARK: - the mapper

/// `metrics.log` + the dictionary → `InsightsInput`.
///
/// Every field is one `MetricsSummary` field passed through unchanged: rates
/// stay fractions (0…1), latencies stay milliseconds, and an optional
/// percentile stays optional. The three places this adds anything are all
/// honesty rules, and each one is a test:
///
///  * `unclassifiedEmpty` is copied across as its own number. It is never
///    folded into `emptyReasons` — inventing a reason for a row written before
///    reasons existed would poison the one figure this page exists to report.
///  * A row whose `outcome` key never made it to disk lands in `MetricsSummary`
///    under the empty string. A blank legend entry is not honest, and dropping
///    the row would make the stacked bar stop summing to the total, so it is
///    labelled `unrecorded`.
///  * The sparkline only bins rows that carry a usable `ts`. A row that cannot
///    be placed in time still counts towards the total; it just is not drawn on
///    a day it may not belong to.
public enum InsightsMapper {
    /// What a row with no `outcome` is called. Not a bucket — a name for an
    /// absence, so the legend can say what it is.
    public static let unrecordedOutcome = "unrecorded"
    /// The sparkline's ceiling. "All time" can be three years wide, and 1,000
    /// daily bars in a 370 pt tile is a texture, not a trend: the value stays
    /// all-time, the shape shows the most recent 90 days.
    public static let maxSparklineDays = 90

    public static func input(rows: [JSONObject],
                             window: MetricsWindow,
                             dictionary: [DictionaryRow],
                             now: Double,
                             calendar: Calendar) -> InsightsInput {
        let summary = MetricsSummary.summarize(rows, window: window, now: now)
        return InsightsInput(
            windowLabel: summary.window.label,
            total: summary.total,
            outcomes: outcomes(summary.outcomes),
            empty: summary.empty,
            emptyRate: summary.emptyRate,
            emptyReasons: summary.emptyReasons,
            unclassifiedEmpty: summary.unclassifiedEmpty,
            unexplainedEmpty: summary.unexplainedEmpty,
            unexplainedEmptyRate: summary.unexplainedEmptyRate,
            timedOut: summary.timedOut,
            timedOutRate: summary.timedOutRate,
            finalizeP50: summary.finalizeMsP50,
            finalizeP90: summary.finalizeMsP90,
            releaseP50: summary.releaseToTextMsP50,
            releaseP90: summary.releaseToTextMsP90,
            aiOutcomes: summary.aiOutcomes,
            dailyCounts: dailyCounts(rows, window: window, now: now, calendar: calendar),
            vocabulary: vocabulary(dictionary),
            learnedTermCount: dictionary.filter(\.isLearned).count,
            zeroEditObserved: summary.editObserved,
            zeroEditRate: summary.zeroEditRate)
    }

    /// The outcome histogram, with the nameless bucket named.
    public static func outcomes(_ counts: [String: Int]) -> [String: Int] {
        guard let unnamed = counts[""] else { return counts }
        var named = counts
        named[""] = nil
        named[unrecordedOutcome, default: 0] += unnamed
        return named
    }

    /// One bucket per calendar day the window can contain, silent days
    /// included: a gap in the sparkline is a day the user did not dictate, and
    /// closing it up would draw a busier month than there was.
    ///
    /// The span comes from the window's own cutoff rather than a rounded day
    /// count, so a 7-day window that reaches back into the middle of an eighth
    /// day draws that day too instead of dropping its rows.
    public static func dailyCounts(_ rows: [JSONObject],
                                   window: MetricsWindow,
                                   now: Double,
                                   calendar: Calendar) -> [DayCount] {
        var counts: [Date: Int] = [:]
        var earliest: Date?
        for row in MetricsSummary.windowed(rows, in: window, now: now) {
            guard let ts = number(row, "ts") else { continue }
            let day = calendar.startOfDay(for: Date(timeIntervalSince1970: ts))
            counts[day, default: 0] += 1
            if let known = earliest { earliest = min(known, day) } else { earliest = day }
        }

        let today = calendar.startOfDay(for: Date(timeIntervalSince1970: now))
        var first: Date
        if let days = window.days {
            first = calendar.startOfDay(for: Date(timeIntervalSince1970: now - days * 86_400))
        } else if let earliest {
            first = earliest
        } else {
            return []   // no row carries a time: there is no shape to draw
        }
        if let earliest, earliest < first { first = earliest }
        guard first <= today,
              let span = calendar.dateComponents([.day], from: first, to: today).day
        else { return [] }

        let bins = min(span + 1, maxSparklineDays)
        let start = calendar.date(byAdding: .day, value: span + 1 - bins, to: first) ?? first
        var out: [DayCount] = []
        out.reserveCapacity(bins)
        for offset in 0..<bins {
            guard let stepped = calendar.date(byAdding: .day, value: offset, to: start) else { break }
            let day = calendar.startOfDay(for: stepped)
            out.append(DayCount(day: day, count: counts[day] ?? 0))
        }
        return out
    }

    /// Terms that have actually fired. A term the user added and never spoke is
    /// not a chart row, and `InsightsModel` hides the tile when none has.
    public static func vocabulary(_ dictionary: [DictionaryRow]) -> [TermUse] {
        dictionary.filter { $0.hitCount > 0 }.map { TermUse(term: $0.term, hits: $0.hitCount) }
    }

    /// `ts` is a float today and was an int in some Python-era rows;
    /// `MetricsSummary` reads numbers the same way and its reader is internal
    /// to its own module.
    static func number(_ row: JSONObject, _ key: String) -> Double? {
        switch row[key] {
        case .double(let value)?: return value
        case .int(let value)?: return Double(value)
        default: return nil
        }
    }
}

// MARK: - the page model

/// The Insights read — §3.5's threading paragraph and §6.4.
///
/// Cheap by construction: the poll stats the file and only parses when its
/// modification date has moved, both on a detached utility task, and the caller
/// only polls while the page is on screen and `WispritWindowModel.isPolling`
/// says the window's own tick is armed. That flag is false while the window is
/// closed AND for the whole duration of an utterance, which is exactly the
/// "no page adds main-thread work while a key is held" rule.
@MainActor
@Observable
public final class InsightsPageModel {
    /// The same cadence the window's tick runs at. A stat every two seconds is
    /// nothing; the parse behind it happens only when the file has changed.
    public static let pollInterval: TimeInterval = 2.0

    /// Seams, so the whole model is drivable from a fixture with no disk.
    public struct Ports: Sendable {
        public var modificationDate: @Sendable () -> Date?
        public var readAll: @Sendable () -> [JSONObject]
        public var now: @Sendable () -> Double
        public var calendar: @Sendable () -> Calendar

        public init(modificationDate: @escaping @Sendable () -> Date? = { nil },
                    readAll: @escaping @Sendable () -> [JSONObject] = { [] },
                    now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 },
                    calendar: @escaping @Sendable () -> Calendar = { .current }) {
            self.modificationDate = modificationDate
            self.readAll = readAll
            self.now = now
            self.calendar = calendar
        }

        /// The real file, through the same `MetricsWriter` the CLI reads with.
        public static func live(path: URL? = nil) -> Ports {
            let writer = path.map { MetricsWriter(path: $0) } ?? MetricsWriter()
            let file = writer.metricsPath
            return Ports(
                modificationDate: {
                    let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
                    return attributes?[.modificationDate] as? Date
                },
                readAll: { writer.readAll() })
        }
    }

    /// Nil until the first read lands — the page shows nothing rather than a
    /// window full of zeros it has not verified.
    public private(set) var input: InsightsInput?

    /// The segmented control. Changing it re-summarizes the rows already in
    /// memory; it never re-reads the file.
    public var choice: MetricsWindowChoice = .days30 {
        didSet {
            guard choice != oldValue, hasRead else { return }
            recompute()
        }
    }

    private let ports: Ports
    private var rows: [JSONObject] = []
    private var dictionary: [DictionaryRow] = []
    private var modified: Date?
    private var hasRead = false
    private var isReading = false

    public nonisolated init(ports: Ports = .live()) {
        self.ports = ports
    }

    /// One poll. Returns as soon as the file's stamp says nothing has changed.
    ///
    /// The dictionary rides in from `WispritWindowModel`, which already holds
    /// it in memory — the vocabulary tile is fed by `DictionaryEditor.rows()`,
    /// not by metrics (§3.5), and re-reading `dictionary.json` here would be a
    /// second disk hit for data the window has open. The caller passes its
    /// current rows on every poll; a term whose count moved is a recompute, not
    /// a re-read.
    public func refreshIfNeeded(dictionary terms: [DictionaryRow] = [],
                                force: Bool = false) async {
        if terms != dictionary {
            dictionary = terms
            if hasRead { recompute() }
        }
        guard !isReading else { return }
        isReading = true
        defer { isReading = false }

        let stamp = ports.modificationDate
        let read = ports.readAll
        let known = modified
        let mustRead = force || !hasRead
        let result = await Task.detached(priority: .utility) { () -> (Date?, [JSONObject]?) in
            let date = stamp()
            // Same stamp (including "still no file") means the same bytes.
            if !mustRead, date == known { return (date, nil) }
            return (date, read())
        }.value

        modified = result.0
        hasRead = true
        guard let fresh = result.1 else { return }
        self.rows = fresh
        recompute()
    }

    private func recompute() {
        input = InsightsMapper.input(rows: rows,
                                     window: choice.window,
                                     dictionary: dictionary,
                                     now: ports.now(),
                                     calendar: ports.calendar())
    }
}

// MARK: - grid layout

/// Which tiles span both columns, and how the rest pair up.
///
/// §3.5: a two-column grid of 370 pt tiles with a 16 pt gap, tiles 3 and 4
/// spanning both columns. Pure, because "which tiles exist" is
/// `InsightsModel`'s answer and it changes with the data — a fresh install has
/// three tiles, a mature one has six.
public enum InsightsLayout {
    /// The two full-width tiles, named by the label `InsightsModel` gives them
    /// (a `.sparse` placeholder for one of them spans too — the grid must not
    /// reflow just because a tile degraded).
    public static let wideLabels: Set<String> = [InsightsModel.outcomesLabel,
                                                 InsightsModel.emptiesLabel]

    public static func isWide(_ tile: InsightTile) -> Bool {
        wideLabels.contains(label(of: tile))
    }

    public static func label(of tile: InsightTile) -> String {
        switch tile {
        case .value(let label, _, _, _): return label
        case .latency(let label, _, _, _): return label
        case .stacked(let label, _): return label
        case .ranked(let label, _, _, _, _): return label
        case .sparse(let label, _): return label
        }
    }

    /// Rows of at most two tiles, in page order.
    public static func rows(_ tiles: [InsightTile]) -> [[InsightTile]] {
        var out: [[InsightTile]] = []
        var pending: [InsightTile] = []
        for tile in tiles {
            if isWide(tile) {
                if !pending.isEmpty { out.append(pending); pending = [] }
                out.append([tile])
                continue
            }
            pending.append(tile)
            if pending.count == 2 { out.append(pending); pending = [] }
        }
        if !pending.isEmpty { out.append(pending) }
        return out
    }
}

// MARK: - the page

struct InsightsPage: View {
    @ObservedObject var model: WispritWindowModel
    @State private var insights = InsightsPageModel()

    var body: some View {
        HubPage(title: WispritWindowModel.Tab.insights.title, actions: {
            windowPicker
        }, content: {
            content
        })
        .task {
            // Bound to the page's lifetime: SwiftUI cancels it the moment the
            // user leaves Insights, so nothing polls a page nobody is looking
            // at. `isPolling` covers the other two gates — the window is open,
            // and no dictation is in flight.
            while !Task.isCancelled {
                if model.isPolling {
                    await insights.refreshIfNeeded(dictionary: model.dictionaryRows)
                }
                try? await Task.sleep(for: .seconds(InsightsPageModel.pollInterval))
            }
        }
    }

    private var windowPicker: some View {
        Picker("Window", selection: $insights.choice) {
            ForEach(MetricsWindowChoice.allCases) { choice in
                Text(choice.title).tag(choice)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 240)
        .accessibilityLabel("Time window")
    }

    @ViewBuilder
    private var content: some View {
        if let input = insights.input {
            let grid = InsightsLayout.rows(InsightsModel.tiles(from: input))
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: InsightsMetrics.gap) {
                    ForEach(Array(grid.enumerated()), id: \.offset) { _, row in
                        gridRow(row)
                    }
                    if let footer = InsightsModel.footer(from: input) {
                        footerStrip(footer)
                    }
                }
                .padding(.bottom, Theme.Space.s8)
            }
            .scrollBounceBehavior(.basedOnSize)
        } else {
            Text("Reading metrics…")
                .font(Theme.font(Theme.Role.body))
                .foregroundStyle(Theme.inkTertiary)
        }
    }

    private func gridRow(_ row: [InsightTile]) -> some View {
        HStack(alignment: .top, spacing: InsightsMetrics.gap) {
            ForEach(Array(row.enumerated()), id: \.offset) { _, tile in
                InsightsTileView(tile: tile)
            }
            // A lone narrow tile keeps its column rather than stretching
            // across the grid.
            if row.count == 1 && !InsightsLayout.isWide(row[0]) {
                Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
            }
        }
    }

    private func footerStrip(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s8) {
            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 1)
            Text(text)
                .font(Theme.font(Theme.Role.mono))
                .foregroundStyle(Theme.inkTertiary)
        }
        .padding(.top, Theme.Space.s4)
    }
}

// MARK: - tile geometry

/// §3.5's sizes. The chart heights are also what the sparse placeholder is:
/// "a dashed plate, height = the chart's normal height" — so a tile that
/// degrades leaves the grid exactly where it was.
enum InsightsMetrics {
    static let tileWidth: Double = 370
    static let gap: Double = Theme.Space.s16
    static let padding: Double = Theme.Space.s16
    static let spark: Double = 40
    static let latency: Double = 56
    static let stacked: Double = 44
    static let ranked: Double = 88
    /// The bar in a stacked or ranked chart.
    static let barHeight: Double = 12
    /// Leading column of a ranked chart — wide enough for `produced_nothing`.
    static let rankedLabel: Double = 132
    static let rankedValue: Double = 44

    static func chartHeight(for label: String) -> Double {
        switch label {
        case InsightsModel.utterancesLabel: return spark
        case InsightsModel.latencyLabel: return latency
        case InsightsModel.outcomesLabel: return stacked
        case InsightsModel.zeroEditLabel: return spark
        default: return ranked
        }
    }

    /// §1.4: `outcome`, `empty_reason` and `ai` are machine vocabulary and are
    /// set in mono. Dictionary terms are words a human chose, and are not.
    static func isMachineVocabulary(_ label: String) -> Bool {
        label != InsightsModel.vocabularyLabel
    }
}

/// The chart palette (§3.5): a five-step ink ramp by rank, plus `critical` for
/// the `empty` segment and for nothing else. Series are told apart by ramp
/// position and an always-visible label, never by hue.
enum InsightsPalette {
    static let emptyOutcome = "empty"

    /// The ramp step for a rank, clamped: a seventh outcome shares the last
    /// step and is told apart by its label, which is always drawn.
    static func ramp(rank: Int) -> Color {
        let ramp = Theme.chartRamp
        return ramp[min(max(rank, 0), ramp.count - 1)]
    }

    static func fill(rank: Int, label: String) -> Color {
        label == emptyOutcome ? Theme.chartEmpty : ramp(rank: rank)
    }
}

// MARK: - tiles

/// One tile: a flat plate with a hairline and no shadow (§1.7 — no nested
/// cards), a label, and whatever chart the case names.
private struct InsightsTileView: View {
    let tile: InsightTile

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s12) {
            header
            chart
        }
        .padding(InsightsMetrics.padding)
        // 370 at the 756 pt content width (§3.5); flexible above it, because
        // the window is resizable and two half-columns is still the grid.
        .frame(idealWidth: InsightsMetrics.tileWidth, maxWidth: .infinity,
               alignment: .topLeading)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1))
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s8) {
            Text(InsightsLayout.label(of: tile))
                .font(Theme.font(Theme.Role.captionEmph))
                .tracking(Theme.Role.captionEmph.tracking)
                .textCase(.uppercase)
                .foregroundStyle(Theme.inkTertiary)
            Spacer(minLength: Theme.Space.s8)
            if case .ranked(_, let caption?, _, _, _) = tile {
                Text(caption)
                    .font(Theme.font(Theme.Role.mono))
                    .foregroundStyle(Theme.inkSecondary)
            }
        }
    }

    @ViewBuilder
    private var chart: some View {
        switch tile {
        case .value(_, let value, let sub, let spark):
            ValueChart(value: value, sub: sub, spark: spark)
        case .latency(_, let p50, let p90, let reference):
            LatencyChart(p50: p50, p90: p90, reference: reference)
        case .stacked(_, let segments):
            StackedChart(segments: segments)
        case .ranked(let label, _, let rows, let footnote, let alarm):
            RankedChart(rows: rows, footnote: footnote, alarm: alarm,
                        machine: InsightsMetrics.isMachineVocabulary(label))
        case .sparse(let label, let need):
            SparsePlate(need: need, height: InsightsMetrics.chartHeight(for: label))
        }
    }
}

/// The headline number, its sparkline, and the window label under it.
private struct ValueChart: View {
    let value: String
    let sub: String?
    let spark: [Double]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s8) {
            Text(value)
                .font(Theme.font(Theme.Role.numeralL))
                .tracking(Theme.Role.numeralL.tracking)
                .foregroundStyle(Theme.ink)
            // The zero-edit tile has a number and an `n`, not a trend yet — no
            // sparkline means no chart, not an empty plate.
            if !spark.isEmpty {
                SparkBars(values: spark)
                    .frame(height: InsightsMetrics.spark)
            }
            if let sub {
                Text(sub)
                    .font(Theme.font(Theme.Role.caption))
                    .foregroundStyle(Theme.inkSecondary)
            }
        }
    }
}

/// Daily counts, normalised against the busiest day. A silent day still draws a
/// 1 pt stub: an invisible zero reads as a missing day rather than a quiet one
/// (the same rule `StreakIntensity` step 0 encodes).
private struct SparkBars: View {
    let values: [Double]

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, size in
            guard !values.isEmpty, size.width > 0 else { return }
            let slot = size.width / Double(values.count)
            let width = max(1, slot - min(2, slot / 3))
            let live = InsightsPalette.ramp(rank: 1)
            for (index, value) in values.enumerated() {
                let clamped = min(max(value, 0), 1)
                let height = max(1, clamped * size.height)
                let rect = CGRect(x: Double(index) * slot, y: size.height - height,
                                  width: width, height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: min(1, width / 2)),
                             with: .color(clamped > 0 ? live : Theme.inkQuaternary))
            }
        }
        .accessibilityHidden(true)
    }
}

/// p50 and p90 against the 400 ms reference — the point at which release-to-text
/// stops feeling immediate.
private struct LatencyChart: View {
    let p50: Double
    let p90: Double
    let reference: Double

    private var scale: Double { max(p90, reference) * 1.15 }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s8) {
            Text(InsightsFormat.ms(p50))
                .font(Theme.font(Theme.Role.numeralL))
                .tracking(Theme.Role.numeralL.tracking)
                .foregroundStyle(Theme.ink)
            row("p50", value: p50, rank: 0)
            row("p90", value: p90, rank: 1)
            Text("\(InsightsFormat.ms(reference)) reference")
                .font(Theme.font(Theme.Role.mono))
                .foregroundStyle(Theme.inkTertiary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(InsightsModel.latencyLabel): median \(InsightsFormat.ms(p50)), "
                            + "90th percentile \(InsightsFormat.ms(p90)), "
                            + "reference \(InsightsFormat.ms(reference))")
    }

    private func row(_ label: String, value: Double, rank: Int) -> some View {
        HStack(spacing: Theme.Space.s8) {
            Text(label)
                .font(Theme.font(Theme.Role.mono))
                .foregroundStyle(Theme.inkTertiary)
                .frame(width: 26, alignment: .leading)
            LatencyBar(value: value, scale: scale, reference: reference, rank: rank)
                .frame(height: InsightsMetrics.barHeight)
            Text(InsightsFormat.ms(value))
                .font(Theme.font(Theme.Role.mono))
                .foregroundStyle(Theme.inkSecondary)
                .frame(width: 56, alignment: .trailing)
        }
    }
}

private struct LatencyBar: View {
    let value: Double
    let scale: Double
    let reference: Double
    let rank: Int

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, size in
            guard size.width > 0, scale > 0 else { return }
            let radius = size.height / 2
            context.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: radius),
                         with: .color(Theme.fillSubtle))
            let filled = max(2, size.width * min(1, max(0, value) / scale))
            context.fill(Path(roundedRect: CGRect(x: 0, y: 0, width: filled, height: size.height),
                              cornerRadius: radius),
                         with: .color(InsightsPalette.ramp(rank: rank)))
            var mark = Path()
            let x = size.width * min(1, max(0, reference) / scale)
            mark.move(to: CGPoint(x: x, y: -2))
            mark.addLine(to: CGPoint(x: x, y: size.height + 2))
            context.stroke(mark, with: .color(Theme.inkTertiary),
                           style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
        }
        .accessibilityHidden(true)
    }
}

/// One bar, every outcome in it, and a legend that names each segment. The
/// `empty` segment is the reserved `critical` step; everything else is a ramp
/// position.
private struct StackedChart: View {
    let segments: [LabeledCount]

    private var total: Int { segments.reduce(0) { $0 + $1.count } }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s12) {
            Canvas(rendersAsynchronously: false) { context, size in
                guard total > 0, size.width > 0 else { return }
                var x: Double = 0
                for (rank, segment) in segments.enumerated() {
                    let width = size.width * Double(segment.count) / Double(total)
                    let rect = CGRect(x: x, y: 0, width: max(width, 0.5), height: size.height)
                    context.fill(Path(rect),
                                 with: .color(InsightsPalette.fill(rank: rank, label: segment.label)))
                    x += width
                }
            }
            .frame(height: InsightsMetrics.barHeight)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
            .accessibilityHidden(true)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: Theme.Space.s12,
                                         alignment: .leading)],
                      alignment: .leading, spacing: Theme.Space.s4) {
                ForEach(Array(segments.enumerated()), id: \.element.id) { rank, segment in
                    HStack(spacing: Theme.Space.s4) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(InsightsPalette.fill(rank: rank, label: segment.label))
                            .frame(width: 8, height: 8)
                        Text(segment.label)
                            .font(Theme.font(Theme.Role.mono))
                            .foregroundStyle(Theme.inkSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("\(segment.count)")
                            .font(Theme.font(Theme.Role.mono))
                            .foregroundStyle(Theme.ink)
                        Spacer(minLength: 0)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(segment.label) \(segment.count)")
                }
            }
        }
    }
}

/// A leaderboard: label, bar, count. The footnote is quiet; the alarm is the
/// one line on this page that gets `critical`, and it sits under a hairline so
/// it is never mistaken for another row of the ranking.
private struct RankedChart: View {
    let rows: [LabeledCount]
    let footnote: String?
    let alarm: String?
    let machine: Bool

    private var peak: Int { rows.map(\.count).max() ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s8) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { rank, row in
                HStack(spacing: Theme.Space.s8) {
                    Text(row.label)
                        .font(Theme.font(machine ? Theme.Role.mono : Theme.Role.body))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(width: InsightsMetrics.rankedLabel, alignment: .leading)
                    RankedBar(fraction: peak > 0 ? Double(row.count) / Double(peak) : 0,
                              label: row.label, rank: rank)
                        .frame(height: InsightsMetrics.barHeight)
                    Text("\(row.count)")
                        .font(Theme.font(Theme.Role.mono))
                        .foregroundStyle(Theme.inkSecondary)
                        .frame(width: InsightsMetrics.rankedValue, alignment: .trailing)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(row.label) \(row.count)")
            }
            if let footnote {
                Text(footnote)
                    .font(Theme.font(Theme.Role.caption))
                    .foregroundStyle(Theme.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let alarm {
                Rectangle()
                    .fill(Theme.hairline)
                    .frame(height: 1)
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s4) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.critical)
                    Text(alarm)
                        .font(Theme.font(Theme.Role.caption))
                        .foregroundStyle(Theme.critical)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

private struct RankedBar: View {
    let fraction: Double
    let label: String
    let rank: Int

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, size in
            guard size.width > 0 else { return }
            let radius = min(Theme.Radius.chip, size.height / 2)
            let width = max(2, size.width * min(1, max(0, fraction)))
            context.fill(Path(roundedRect: CGRect(x: 0, y: 0, width: width, height: size.height),
                              cornerRadius: radius),
                         with: .color(InsightsPalette.fill(rank: rank, label: label)))
        }
        .accessibilityHidden(true)
    }
}

/// The sparse contract (§3.5): a dashed plate at the chart's normal height and
/// one line naming what the tile needs. Never a zero, never a chart of one bar,
/// never a fake trend line.
private struct SparsePlate: View {
    let need: String
    let height: Double

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s8) {
            RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                .fill(Theme.groundRecessed)
                .frame(height: height)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                        .strokeBorder(Theme.hairline,
                                      style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
            Text(need)
                .font(Theme.font(Theme.Role.caption))
                .foregroundStyle(Theme.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(need)
    }
}

/// Latency readouts, in the one shape §1.4 allows for a machine number.
enum InsightsFormat {
    static func ms(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        return "\(Int(value.rounded())) ms"
    }
}
#endif
