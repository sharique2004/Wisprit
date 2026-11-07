#if os(macOS)
import Foundation
import SwiftUI
import WispritMacUI
import WispritPersistence

/// Insights — headlines first, details on demand.
///
/// The page used to be a dashboard in the engine's own words (`im_streaming`,
/// `starved`, a red "empty 25" bar across the top). It is now three or four
/// one-sentence headlines, each with one simple chart and — when something
/// went wrong — what to try, then the activity grid, then a "Technical
/// details" disclosure that keeps every number the old page had, in plain
/// labels.
///
/// Three layers, and only the last one is a view:
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
///     page is on screen and the window's own tick is armed.
///  3. The cards, which decide nothing. `InsightsModel.headlines` and
///     `.details` already decided what exists, what it says and what tone it
///     takes; everything below just draws the case it is given.

// MARK: - the window control

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
/// Every summary field is one `MetricsSummary` field passed through unchanged:
/// rates stay fractions (0…1), latencies stay milliseconds, and an optional
/// percentile stays optional. What this adds, each one a test:
///
///  * `unclassifiedEmpty` is copied across as its own number. It is never
///    folded into `emptyReasons` — inventing a reason for a row written before
///    reasons existed would poison the one figure this page exists to report.
///  * A row whose `outcome` key never made it to disk lands in `MetricsSummary`
///    under the empty string. A blank label is not honest, and dropping the
///    row would make the holds bar stop summing to the total, so it is named
///    `unrecorded` (shown as "Not recorded").
///  * The daily counts only bin rows that carry a usable `ts`.
///  * The capture figures (`capture_backend`, `first_chunk_ms`) are counted
///    over the same windowed utterance rows; they exist only on rows written
///    since the 2026-11-06 capture update, and their absence is what lets the
///    page say the old no-audio holds predate it.
public enum InsightsMapper {
    /// What a row with no `outcome` is called. Not a bucket — a name for an
    /// absence.
    public static let unrecordedOutcome = "unrecorded"
    /// "All time" can be three years wide; the per-day bars show the most
    /// recent 90 days.
    public static let maxSparklineDays = 90

    public static let captureBackendKey = "capture_backend"
    public static let firstChunkKey = "first_chunk_ms"

    public static func input(rows: [JSONObject],
                             window: MetricsWindow,
                             dictionary: [DictionaryRow],
                             now: Double,
                             calendar: Calendar) -> InsightsInput {
        let summary = MetricsSummary.summarize(rows, window: window, now: now)
        let capture = capture(rows, window: window, now: now)
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
            dictionaryTermCount: dictionary.filter { !$0.isPending }.count,
            zeroEditObserved: summary.editObserved,
            zeroEditRate: summary.zeroEditRate,
            captureBackends: capture.backends,
            starvedSinceCaptureUpdate: capture.starved,
            firstChunkP50: percentile(capture.firstChunks, 50),
            firstChunkP90: percentile(capture.firstChunks, 90))
    }

    /// The outcome histogram, with the nameless bucket named.
    public static func outcomes(_ counts: [String: Int]) -> [String: Int] {
        guard let unnamed = counts[""] else { return counts }
        var named = counts
        named[""] = nil
        named[unrecordedOutcome, default: 0] += unnamed
        return named
    }

    /// Capture-path figures over the windowed utterance rows.
    static func capture(_ rows: [JSONObject], window: MetricsWindow,
                        now: Double) -> (backends: [String: Int], starved: Int, firstChunks: [Double]) {
        var backends: [String: Int] = [:]
        var starved = 0
        var firstChunks: [Double] = []
        for row in utteranceRows(rows, window: window, now: now) {
            if let backend = string(row, captureBackendKey) {
                backends[backend, default: 0] += 1
                if string(row, "outcome") == "empty", string(row, "empty_reason") == "starved" {
                    starved += 1
                }
            }
            if let ms = number(row, firstChunkKey) { firstChunks.append(ms) }
        }
        return (backends, starved, firstChunks)
    }

    /// Nearest rank, the way `MetricsSummary` takes its percentiles: a
    /// measurement that was actually taken, never an interpolation.
    static func percentile(_ samples: [Double], _ p: Double) -> Double? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        let rank = Int((p / 100 * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank, 1), sorted.count) - 1]
    }

    /// One bucket per calendar day the window can contain, silent days
    /// included: a gap is a day the user did not dictate, and closing it up
    /// would draw a busier month than there was.
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

    /// Terms that have actually fired.
    public static func vocabulary(_ dictionary: [DictionaryRow]) -> [TermUse] {
        dictionary.filter { $0.hitCount > 0 }.map { TermUse(term: $0.term, hits: $0.hitCount) }
    }

    /// `ts` is a float today and was an int in some Python-era rows.
    static func number(_ row: JSONObject, _ key: String) -> Double? {
        switch row[key] {
        case .double(let value)?: return value
        case .int(let value)?: return Double(value)
        default: return nil
        }
    }

    static func string(_ row: JSONObject, _ key: String) -> String? {
        guard case .string(let value)? = row[key] else { return nil }
        return value
    }

    /// `true` / `1` — the same 0/1-era boolean `MetricsSummary` accepts.
    static func isTrue(_ row: JSONObject, _ key: String) -> Bool {
        switch row[key] {
        case .bool(let value)?: return value
        case .int(let value)?: return value != 0
        default: return false
        }
    }

    /// Recovery figures from the same `metrics.log` slice `input` already
    /// summarized. Rescued count and empty reasons follow `window`; quiet
    /// speech is always the last 7 days, as its label names.
    public static func recovery(rows: [JSONObject],
                                window: MetricsWindow,
                                now: Double) -> InsightsRecovery {
        let summary = MetricsSummary.summarize(rows, window: window, now: now)
        let rescued = utteranceRows(rows, window: window, now: now)
            .filter(isRescued).count

        let quietRows = utteranceRows(rows,
                                      window: MetricsWindow(days: InsightsRecovery.quietSpeechDays),
                                      now: now)
        var quiet = 0, sample = 0
        for row in quietRows {
            guard let peak = number(row, InsightsRecovery.peakLevelKey) else { continue }
            sample += 1
            if peak < InsightsRecovery.quietPeakCeiling { quiet += 1 }
        }

        return InsightsRecovery(rescued: rescued,
                                emptyReasons: summary.emptyReasons,
                                unclassifiedEmpty: summary.unclassifiedEmpty,
                                quietSpeech: quiet,
                                quietSpeechSample: sample)
    }

    /// Utterance rows in `window`, through the same filter `MetricsSummary`
    /// uses — `vocab_retro` / `edit_observed` / `onboarding` are not holds.
    static func utteranceRows(_ rows: [JSONObject],
                              window: MetricsWindow,
                              now: Double) -> [JSONObject] {
        MetricsSummary.windowed(rows, in: window, now: now).filter { row in
            !MetricsSummary.nonUtteranceOutcomes.contains(string(row, "outcome") ?? "")
        }
    }

    /// A rescued hold is `engine == apple_batch` or `rescued: true`, counted
    /// once when both are set.
    static func isRescued(_ row: JSONObject) -> Bool {
        string(row, "engine") == InsightsRecovery.appleBatchEngine
            || isTrue(row, InsightsRecovery.rescuedKey)
    }
}

// MARK: - the page model

/// The Insights read.
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

    /// Same read as `input`; nil until that read lands.
    public private(set) var recovery: InsightsRecovery?

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
    /// it in memory; a term whose count moved is a recompute, not a re-read.
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
        let now = ports.now()
        input = InsightsMapper.input(rows: rows,
                                     window: choice.window,
                                     dictionary: dictionary,
                                     now: now,
                                     calendar: ports.calendar())
        recovery = InsightsMapper.recovery(rows: rows,
                                           window: choice.window,
                                           now: now)
    }
}

// MARK: - the page

struct InsightsPage: View {
    @ObservedObject var model: WispritWindowModel
    @State private var insights = InsightsPageModel()
    @State private var showsDetails = InsightsPage.detailsOpenByDefault

    /// Collapsed: the details are for the curious and the troubleshooting.
    static let detailsOpenByDefault = false

    var body: some View {
        HubPage(title: WispritWindowModel.Tab.insights.title, actions: {
            windowPicker
        }, content: {
            content
        })
        .task {
            // The streak grid and the speaking rate come from history, which
            // the window reads when it opens; ask once if it has not yet.
            if model.homeStats == nil { model.refreshHomeStats() }
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
            let activity = model.insightsActivity()
            let headlines = InsightsModel.headlines(from: input, activity: activity)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: InsightsMetrics.gap) {
                    ForEach(Array(InsightsMetrics.rows(headlines).enumerated()), id: \.offset) { _, row in
                        // Cards in a row share a height: two plates of different
                        // lengths side by side read as a layout bug.
                        HStack(alignment: .top, spacing: InsightsMetrics.gap) {
                            ForEach(row) { headline in
                                HeadlineCard(headline: headline, activity: activity)
                            }
                            if row.count == 1, row[0].kind != .activity {
                                Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    TechnicalDetails(sections: InsightsModel.details(from: input,
                                                                     recovery: insights.recovery),
                                     isExpanded: $showsDetails)
                        .padding(.top, Theme.Space.s8)
                }
                .padding(.bottom, Theme.Space.s24)
            }
            .scrollBounceBehavior(.basedOnSize)
        } else {
            Text("Reading your dictation history…")
                .font(Theme.font(Theme.Role.body))
                .foregroundStyle(Theme.inkTertiary)
        }
    }
}

// MARK: - geometry

enum InsightsMetrics {
    static let gap: Double = Theme.Space.s16
    static let padding: Double = Theme.Space.s20
    static let barHeight: Double = 12
    static let placeholderHeight: Double = 44
    static let ratesHeight: Double = 64
    static let gridCell: Double = 15
    static let gridGap: Double = 4

    /// Headlines in rows of two; the activity grid gets a row to itself.
    static func rows(_ headlines: [InsightHeadline]) -> [[InsightHeadline]] {
        var out: [[InsightHeadline]] = []
        var pending: [InsightHeadline] = []
        for headline in headlines {
            if headline.kind == .activity {
                if !pending.isEmpty { out.append(pending); pending = [] }
                out.append([headline])
                continue
            }
            pending.append(headline)
            if pending.count == 2 { out.append(pending); pending = [] }
        }
        if !pending.isEmpty { out.append(pending) }
        return out
    }
}

/// The chart palette: steps of `ink`, never orange, and `critical` for a
/// genuine fault only. Series are told apart by lightness and an always-
/// visible label, never by hue alone.
enum InsightsPalette {
    static func hold(_ group: HoldGroup) -> Color {
        switch group {
        case .delivered: return Theme.ink.opacity(0.86)
        case .correction: return Theme.ink.opacity(0.55)
        case .mic: return Theme.ink.opacity(0.40)
        case .noWords: return Theme.ink.opacity(0.30)
        case .unknown: return Theme.ink.opacity(0.22)
        case .quiet: return Theme.ink.opacity(0.16)
        case .blocked: return Theme.ink.opacity(0.12)
        case .fault: return Theme.critical
        }
    }

    static func ramp(_ rank: Int) -> Color {
        let ramp = Theme.chartRamp
        return ramp[min(max(rank, 0), ramp.count - 1)]
    }
}

// MARK: - a headline card

private struct HeadlineCard: View {
    let headline: InsightHeadline
    let activity: InsightsActivity?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s12) {
            header
            sentence
            chart
            if let detail = headline.detail {
                Text(detail)
                    .font(Theme.font(Theme.Role.body))
                    .foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !headline.advice.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Space.s4) {
                    ForEach(Array(headline.advice.enumerated()), id: \.offset) { index, line in
                        AdviceLine(text: line,
                                   isFault: headline.tone == .fault && index == 0)
                    }
                }
            }
        }
        .padding(InsightsMetrics.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous)
                .fill(Theme.surfaceRaised))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1))
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s8) {
            Text(headline.kicker)
                .font(Theme.font(Theme.Role.captionEmph))
                .tracking(Theme.Role.captionEmph.tracking)
                .textCase(.uppercase)
                .foregroundStyle(Theme.inkTertiary)
            Spacer(minLength: Theme.Space.s8)
            Text(headline.scope)
                .font(Theme.font(Theme.Role.caption))
                .foregroundStyle(Theme.inkTertiary)
        }
    }

    /// Words in the sans at reading size; the figures in the display serif —
    /// the one place it is allowed, numerals (§1.3).
    private var sentence: some View {
        headline.sentence.reduce(Text("")) { text, run in
            text + (run.isFigure
                ? Text(run.text).font(Theme.serif(27)).foregroundColor(Theme.ink)
                : Text(run.text).font(.system(size: 17, weight: .medium)).foregroundColor(Theme.ink))
        }
        .lineSpacing(2)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel(headline.text)
    }

    @ViewBuilder
    private var chart: some View {
        switch headline.chart {
        case .latency(let p50, let p90, let reference):
            LatencyChart(p50: p50, p90: p90, reference: reference)
        case .holds(let segments):
            HoldsChart(segments: segments)
        case .terms(let rows):
            TermsChart(rows: rows)
        case .rates(let samples, let median):
            RatesChart(samples: samples, median: median)
                .frame(height: InsightsMetrics.ratesHeight)
        case .activity:
            if let activity { ActivityChart(activity: activity) }
        case .placeholder(let need):
            Placeholder(need: need)
        case .none:
            EmptyView()
        }
    }
}

private struct AdviceLine: View {
    let text: String
    let isFault: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s8) {
            Image(systemName: isFault ? "exclamationmark.triangle.fill" : "arrow.turn.down.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isFault ? Theme.critical : Theme.inkTertiary)
                .frame(width: 14)
            Text(text)
                .font(Theme.font(Theme.Role.body))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - charts

/// Median and 90th percentile on one axis, against the dashed line where
/// release-to-text stops feeling instant.
private struct LatencyChart: View {
    let p50: Double
    let p90: Double
    let reference: Double

    private var scale: Double { max(p90, reference) * 1.12 }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s8) {
            GeometryReader { proxy in
                let width = proxy.size.width
                let x = { (value: Double) in width * min(1, max(0, value) / scale) }
                ZStack(alignment: .topLeading) {
                    Canvas(rendersAsynchronously: false) { context, size in
                        guard size.width > 0, scale > 0 else { return }
                        let top = 16.0
                        let height = InsightsMetrics.barHeight
                        let radius = height / 2
                        context.fill(Path(roundedRect: CGRect(x: 0, y: top, width: size.width, height: height),
                                          cornerRadius: radius),
                                     with: .color(Theme.fillSubtle))
                        context.fill(Path(roundedRect: CGRect(x: 0, y: top, width: max(height, x(p90)),
                                                              height: height), cornerRadius: radius),
                                     with: .color(Theme.ink.opacity(0.28)))
                        context.fill(Path(roundedRect: CGRect(x: 0, y: top, width: max(height, x(p50)),
                                                              height: height), cornerRadius: radius),
                                     with: .color(Theme.ink.opacity(0.86)))
                        var mark = Path()
                        mark.move(to: CGPoint(x: x(reference), y: top - 3))
                        mark.addLine(to: CGPoint(x: x(reference), y: top + height + 3))
                        context.stroke(mark, with: .color(Theme.inkSecondary),
                                       style: StrokeStyle(lineWidth: 1.5, dash: [2, 2]))
                    }
                    Text(InsightsModel.seconds(reference))
                        .font(Theme.font(Theme.Role.caption))
                        .foregroundStyle(Theme.inkTertiary)
                        .monospacedDigit()
                        .fixedSize()
                        .position(x: min(max(x(reference), 20), width - 20), y: 5)
                }
            }
            .frame(height: 16 + InsightsMetrics.barHeight + 3)
            .accessibilityHidden(true)

            HStack(spacing: Theme.Space.s16) {
                key(Theme.ink.opacity(0.86), "Median \(InsightsModel.seconds(p50))")
                key(Theme.ink.opacity(0.28), "9 in 10 within \(InsightsModel.seconds(p90))")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Median \(InsightsModel.seconds(p50)), 9 in 10 within "
                            + "\(InsightsModel.seconds(p90)), instant is under \(InsightsModel.seconds(reference))")
    }

    private func key(_ color: Color, _ text: String) -> some View {
        HStack(spacing: Theme.Space.s4) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(color)
                .frame(width: 10, height: 10)
            Text(text)
                .font(Theme.font(Theme.Role.caption))
                .foregroundStyle(Theme.inkSecondary)
                .monospacedDigit()
                .fixedSize()
        }
    }
}

/// Every hold in one bar, a legend that names each part. Grey for normal
/// behaviour; `critical` only for the part that was Wisprit's fault.
private struct HoldsChart: View {
    let segments: [HoldSegment]

    private var total: Int { segments.reduce(0) { $0 + $1.count } }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s12) {
            Canvas(rendersAsynchronously: false) { context, size in
                guard total > 0, size.width > 0 else { return }
                let gap = 2.0
                let usable = size.width - gap * Double(max(0, segments.count - 1))
                var x: Double = 0
                for segment in segments {
                    let width = max(2, usable * Double(segment.count) / Double(total))
                    context.fill(Path(roundedRect: CGRect(x: x, y: 0, width: width, height: size.height),
                                      cornerRadius: 2),
                                 with: .color(InsightsPalette.hold(segment.group)))
                    x += width + gap
                }
            }
            .frame(height: InsightsMetrics.barHeight)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .accessibilityHidden(true)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: Theme.Space.s12,
                                         alignment: .leading)],
                      alignment: .leading, spacing: Theme.Space.s4) {
                ForEach(segments) { segment in
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s8) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(InsightsPalette.hold(segment.group))
                            .overlay(
                                RoundedRectangle(cornerRadius: 2, style: .continuous)
                                    .strokeBorder(Theme.hairlineStrong, lineWidth: 0.5))
                            .frame(width: 10, height: 10)
                            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                        Text(segment.group.label)
                            .font(Theme.font(Theme.Role.caption))
                            .foregroundStyle(Theme.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("\(segment.count)")
                            .font(Theme.font(Theme.Role.caption))
                            .foregroundStyle(segment.group.isFault ? Theme.critical : Theme.ink)
                            .monospacedDigit()
                        Spacer(minLength: 0)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(segment.group.label) \(segment.count)")
                }
            }
        }
    }
}

/// The busiest dictionary terms, as a short leaderboard.
private struct TermsChart: View {
    let rows: [LabeledCount]

    private var peak: Int { rows.map(\.count).max() ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s8) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { rank, row in
                HStack(spacing: Theme.Space.s8) {
                    Text(row.label)
                        .font(Theme.font(Theme.Role.body))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(width: 104, alignment: .leading)
                    GeometryReader { proxy in
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(InsightsPalette.ramp(rank))
                            .frame(width: max(3, proxy.size.width
                                              * (peak > 0 ? Double(row.count) / Double(peak) : 0)))
                    }
                    .frame(height: 8)
                    Text("\(row.count)")
                        .font(Theme.font(Theme.Role.caption))
                        .foregroundStyle(Theme.inkSecondary)
                        .monospacedDigit()
                        .frame(width: 32, alignment: .trailing)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(row.label), \(row.count) fixes")
            }
        }
    }
}

/// Every dictation in the sample as a dot on a words-per-minute axis, the
/// median as a line through them. Self-relative: there is no population line.
private struct RatesChart: View {
    let samples: [Double]
    let median: Double

    /// A round axis end, so the ticks are numbers a person would pick.
    private var top: Double {
        let peak = max(samples.max() ?? 0, median)
        return max(100, (peak / 50).rounded(.up) * 50)
    }

    private var ticks: [Double] {
        let step = top > 300 ? 100.0 : 50.0
        return stride(from: 0, through: top, by: step).map { $0 }
    }

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, size in
            guard size.width > 0, top > 0 else { return }
            let axisY = size.height - 16
            let dotY = axisY - 16
            func x(_ value: Double) -> Double { 10 + (size.width - 24) * min(1, max(0, value) / top) }

            var axis = Path()
            axis.move(to: CGPoint(x: x(0), y: axisY))
            axis.addLine(to: CGPoint(x: x(top), y: axisY))
            context.stroke(axis, with: .color(Theme.hairlineStrong), lineWidth: 1)
            for tick in ticks {
                var mark = Path()
                mark.move(to: CGPoint(x: x(tick), y: axisY))
                mark.addLine(to: CGPoint(x: x(tick), y: axisY + 3))
                context.stroke(mark, with: .color(Theme.hairlineStrong), lineWidth: 1)
                context.draw(Text("\(Int(tick))")
                                .font(Theme.font(Theme.Role.caption))
                                .foregroundColor(Theme.inkTertiary),
                             at: CGPoint(x: x(tick), y: axisY + 10), anchor: .center)
            }
            for (index, sample) in samples.enumerated() {
                // A little vertical spread so neighbours stay countable.
                let jitter = Double((index * 7) % 5 - 2) * 3
                let rect = CGRect(x: x(sample) - 3.5, y: dotY + jitter - 3.5, width: 7, height: 7)
                context.fill(Path(ellipseIn: rect), with: .color(Theme.ink.opacity(0.38)))
            }
            var line = Path()
            line.move(to: CGPoint(x: x(median), y: 14))
            line.addLine(to: CGPoint(x: x(median), y: axisY))
            context.stroke(line, with: .color(Theme.ink), lineWidth: 2)
            context.draw(Text("median \(Int(median.rounded()))")
                            .font(Theme.font(Theme.Role.caption))
                            .foregroundColor(Theme.inkSecondary),
                         at: CGPoint(x: x(median), y: 5), anchor: .center)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(samples.count) dictations, median \(Int(median.rounded())) words per minute")
    }
}

/// The streak grid with its labels and its legend.
private struct ActivityChart: View {
    let activity: InsightsActivity

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.s32) {
            StreakGrid(weeks: activity.weeks,
                       today: activity.today,
                       labels: StreakGrid.Labels(months: activity.monthLabels,
                                                 weekdays: StreakCalendar.weekdaySymbols(
                                                    calendar: activity.calendar),
                                                 tooltips: activity.tooltips),
                       cell: InsightsMetrics.gridCell,
                       gap: InsightsMetrics.gridGap)
            StreakLegend(scale: StreakScale.fit(activity.weeks.flatMap { $0 }))
                .padding(.top, 18)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Activity grid: dictated on \(activity.activeDays) of the last "
                            + "\(activity.elapsedDays) days")
    }
}

/// Not enough data yet: a dashed plate at a chart's height and the line that
/// says what it needs. Never a zero, never a chart of one bar.
private struct Placeholder: View {
    let need: String

    var body: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
            .fill(Theme.groundRecessed.opacity(0.6))
            .frame(height: InsightsMetrics.placeholderHeight)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                    .strokeBorder(Theme.hairlineStrong, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
            .overlay(
                Text(need)
                    .font(Theme.font(Theme.Role.caption))
                    .foregroundStyle(Theme.inkSecondary))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(need)
    }
}

// MARK: - technical details

/// Every number the old page carried, in plain labels, behind one disclosure.
private struct TechnicalDetails: View {
    let sections: [InsightDetailSection]
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s16) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: Theme.Space.s8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundStyle(Theme.inkTertiary)
                    Text("Technical details")
                        .font(Theme.font(Theme.Role.sectionTitle))
                        .foregroundStyle(Theme.ink)
                    Text("Timings, every outcome, cleanup and microphone")
                        .font(Theme.font(Theme.Role.caption))
                        .foregroundStyle(Theme.inkTertiary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Hide technical details" : "Show technical details")

            if isExpanded {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: Theme.Space.s32, alignment: .top),
                                    GridItem(.flexible(), spacing: Theme.Space.s32, alignment: .top)],
                          alignment: .leading, spacing: Theme.Space.s24) {
                    ForEach(sections) { section in
                        DetailSectionView(section: section)
                    }
                }
                .padding(.leading, Theme.Space.s20)
            }
        }
    }
}

private struct DetailSectionView: View {
    let section: InsightDetailSection

    static let column: Double = 92

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s8) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s8) {
                Text(section.title)
                    .font(Theme.font(Theme.Role.rowTitle))
                    .foregroundStyle(Theme.ink)
                Spacer(minLength: Theme.Space.s8)
                ForEach(section.columns, id: \.self) { title in
                    Text(title)
                        .font(Theme.font(Theme.Role.caption))
                        .foregroundStyle(Theme.inkTertiary)
                        .frame(width: Self.column, alignment: .trailing)
                }
            }
            if !section.spark.isEmpty {
                VStack(spacing: Theme.Space.s4) {
                    SparkBars(values: section.spark)
                        .frame(height: 28)
                    HStack {
                        Text("Holds per day")
                        Spacer()
                        Text("Today")
                    }
                    .font(Theme.font(Theme.Role.caption))
                    .foregroundStyle(Theme.inkTertiary)
                }
                .padding(.bottom, Theme.Space.s4)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(section.rows) { row in
                    DetailRowView(row: row, columned: !section.columns.isEmpty)
                }
            }
            ForEach(section.notes, id: \.self) { note in
                Text(note)
                    .font(Theme.font(Theme.Role.caption))
                    .foregroundStyle(Theme.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let alarm = section.alarm {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.critical)
                    Text(alarm)
                        .font(Theme.font(Theme.Role.caption))
                        .foregroundStyle(Theme.critical)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct DetailRowView: View {
    let row: InsightDetailRow
    let columned: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s8) {
                Text(row.label)
                    .font(Theme.font(Theme.Role.body))
                    .foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Theme.Space.s8)
                if columned, let secondary = row.secondary {
                    value(row.value).frame(width: DetailSectionView.column, alignment: .trailing)
                    value(secondary).frame(width: DetailSectionView.column, alignment: .trailing)
                } else {
                    value(row.value)
                }
            }
            if let fraction = row.fraction {
                GeometryReader { proxy in
                    Capsule()
                        .fill(row.isFault ? Theme.critical.opacity(0.7) : Theme.ink.opacity(0.32))
                        .frame(width: max(2, proxy.size.width * min(1, max(0, fraction))))
                }
                .frame(height: 3)
            }
        }
        .padding(.vertical, 5)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.hairline).frame(height: 1)
        }
        .accessibilityElement(children: .combine)
    }

    private func value(_ text: String) -> some View {
        Text(text)
            .font(Theme.font(Theme.Role.body))
            .foregroundStyle(row.isFault ? Theme.critical : Theme.ink)
            .monospacedDigit()
            .multilineTextAlignment(.trailing)
    }
}

/// Holds per day, normalised against the busiest day. A silent day still draws
/// a 1 pt stub: an invisible zero reads as a missing day rather than a quiet one.
private struct SparkBars: View {
    let values: [Double]

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, size in
            guard !values.isEmpty, size.width > 0 else { return }
            let slot = size.width / Double(values.count)
            let width = max(1, slot - min(2, slot / 3))
            for (index, value) in values.enumerated() {
                let clamped = min(max(value, 0), 1)
                let height = max(1, clamped * size.height)
                let rect = CGRect(x: Double(index) * slot, y: size.height - height,
                                  width: width, height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: min(1, width / 2)),
                             with: .color(clamped > 0 ? Theme.ink.opacity(0.5) : Theme.inkQuaternary))
            }
        }
        .accessibilityHidden(true)
    }
}
#endif
