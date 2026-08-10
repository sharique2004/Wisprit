import Foundation

/// A label and its count. The spec sketches these as `[(String, Int)]`, but a
/// tuple array is not `Equatable`, and an `InsightTile` that cannot be compared
/// cannot be asserted on — which is the whole point of putting this logic in
/// the pure target. Same shape, one name.
public struct LabeledCount: Identifiable, Equatable, Sendable {
    public var label: String
    public var count: Int
    public var id: String { label }

    public init(_ label: String, _ count: Int) {
        self.label = label
        self.count = count
    }
}

/// One day of the utterance sparkline.
public struct DayCount: Identifiable, Equatable, Sendable {
    public var day: Date
    public var count: Int
    public var id: Date { day }

    public init(day: Date, count: Int) {
        self.day = day
        self.count = count
    }
}

/// One dictionary term and how often it fired.
public struct TermUse: Identifiable, Equatable, Sendable {
    public var term: String
    public var hits: Int
    public var id: String { term }

    public init(term: String, hits: Int) {
        self.term = term
        self.hits = hits
    }
}

/// Everything Insights needs, in `WispritMacUI`'s own vocabulary —
/// `docs/design/ui-redesign.md` §6.1.
///
/// The neutral seam again: this target cannot name `MetricsSummary`, so
/// `WispritMac/Window/` maps one into this. Every field below is a field
/// `MetricsSummary` already publishes; nothing here is derived from data the
/// app does not have (§3.5 lists what was refused and why).
///
/// Rates are **fractions**, 0…1 — `emptyRate` 0.052 renders as "5.2% of holds".
/// Latencies are milliseconds. The optional ones are optional because the rows
/// that carry them are optional: `releaseP50` exists only on rows that put text
/// in front of the user.
public struct InsightsInput: Equatable, Sendable {
    public var windowLabel: String
    public var total: Int
    public var outcomes: [String: Int]
    public var empty: Int
    public var emptyRate: Double
    public var emptyReasons: [String: Int]
    /// Reported **separately and never merged** into `emptyReasons` —
    /// `MetricsSummary` is explicit about this and the UI honours it.
    public var unclassifiedEmpty: Int
    public var unexplainedEmpty: Int
    public var unexplainedEmptyRate: Double
    public var timedOut: Int
    public var timedOutRate: Double
    public var finalizeP50: Double?
    public var finalizeP90: Double?
    public var releaseP50: Double?
    public var releaseP90: Double?
    public var aiOutcomes: [String: Int]
    public var dailyCounts: [DayCount]
    /// From `DictionaryEditor.rows()`, **not** metrics.
    public var vocabulary: [TermUse]
    public var learnedTermCount: Int

    public init(windowLabel: String = "",
                total: Int = 0,
                outcomes: [String: Int] = [:],
                empty: Int = 0,
                emptyRate: Double = 0,
                emptyReasons: [String: Int] = [:],
                unclassifiedEmpty: Int = 0,
                unexplainedEmpty: Int = 0,
                unexplainedEmptyRate: Double = 0,
                timedOut: Int = 0,
                timedOutRate: Double = 0,
                finalizeP50: Double? = nil,
                finalizeP90: Double? = nil,
                releaseP50: Double? = nil,
                releaseP90: Double? = nil,
                aiOutcomes: [String: Int] = [:],
                dailyCounts: [DayCount] = [],
                vocabulary: [TermUse] = [],
                learnedTermCount: Int = 0) {
        self.windowLabel = windowLabel
        self.total = total
        self.outcomes = outcomes
        self.empty = empty
        self.emptyRate = emptyRate
        self.emptyReasons = emptyReasons
        self.unclassifiedEmpty = unclassifiedEmpty
        self.unexplainedEmpty = unexplainedEmpty
        self.unexplainedEmptyRate = unexplainedEmptyRate
        self.timedOut = timedOut
        self.timedOutRate = timedOutRate
        self.finalizeP50 = finalizeP50
        self.finalizeP90 = finalizeP90
        self.releaseP50 = releaseP50
        self.releaseP90 = releaseP90
        self.aiOutcomes = aiOutcomes
        self.dailyCounts = dailyCounts
        self.vocabulary = vocabulary
        self.learnedTermCount = learnedTermCount
    }
}

/// A rendered tile. The view picks a chart shape per case and never decides
/// whether a tile exists.
public enum InsightTile: Equatable, Sendable {
    case value(label: String, value: String, sub: String?, spark: [Double])
    case latency(label: String, p50: Double, p90: Double, reference: Double)
    case stacked(label: String, segments: [LabeledCount])
    /// `caption` is the trailing header line ("95 · 5.2% of holds"); `footnote`
    /// is the never-merged unclassified count; `alarm` is the unexplained-empty
    /// line, which is the one thing on this page that gets `critical`.
    case ranked(label: String, caption: String?, rows: [LabeledCount],
                footnote: String?, alarm: String?)
    /// The under-`minimumRows` placeholder: a dashed plate and one line naming
    /// what it needs. Never a zero, never a chart of one bar, never a fake
    /// trend line.
    case sparse(label: String, need: String)
}

/// Insights' pure logic — §3.5 and §6.1.
///
/// Three rules run through all of it:
///
/// 1. **Named fields.** Every tile is fed by a field this struct declares, and
///    a field only exists here because `MetricsSummary` already publishes it.
/// 2. **Hide when there is nothing.** A tile whose data does not exist on this
///    Mac is absent, not empty and not disabled.
/// 3. **The sparse contract.** Fewer than `minimumRows` contributing rows and
///    the tile degrades to a placeholder that says what it needs.
public enum InsightsModel {
    public static let minimumRows = 5
    /// The dotted reference line on the latency tile: 400 ms is the point at
    /// which release-to-text stops feeling immediate.
    public static let latencyReferenceMs: Double = 400
    /// How many terms the vocabulary tile lists before it stops being a chart.
    public static let vocabularyLimit = 5

    public static let utterancesLabel = "Utterances"
    public static let latencyLabel = "Release → text"
    public static let outcomesLabel = "Where the words went"
    public static let emptiesLabel = "Empties, explained"
    public static let cleanupLabel = "AI cleanup"
    public static let vocabularyLabel = "Vocabulary at work"

    /// The tiles, in page order.
    public static func tiles(from input: InsightsInput,
                             locale: Locale = .autoupdatingCurrent) -> [InsightTile] {
        var tiles: [InsightTile] = []
        tiles.append(utterances(input, locale: locale))
        tiles.append(latency(input))
        tiles.append(outcomes(input))
        if let empties = empties(input, locale: locale) { tiles.append(empties) }
        if let cleanup = cleanup(input) { tiles.append(cleanup) }
        if let vocabulary = vocabulary(input) { tiles.append(vocabulary) }
        return tiles
    }

    // MARK: - tiles

    /// `summary.total` plus a sparkline over `dailyCounts`. Always available:
    /// `ts` has been on every row since the Python era.
    static func utterances(_ input: InsightsInput, locale: Locale) -> InsightTile {
        guard input.total >= minimumRows else {
            return .sparse(label: utterancesLabel, need: need(input.total, noun: "dictations"))
        }
        return .value(label: utterancesLabel,
                      value: count(input.total, locale: locale),
                      sub: input.windowLabel.isEmpty ? nil : input.windowLabel,
                      spark: sparkline(input.dailyCounts))
    }

    /// Optional by construction: `release_to_text_ms` is written only on rows
    /// that put text in front of the user, so nil is a normal answer.
    static func latency(_ input: InsightsInput) -> InsightTile {
        guard input.total >= minimumRows,
              let p50 = input.releaseP50, let p90 = input.releaseP90 else {
            return .sparse(label: latencyLabel, need: need(input.total, noun: "dictations"))
        }
        return .latency(label: latencyLabel, p50: p50, p90: p90, reference: latencyReferenceMs)
    }

    /// `outcome` is present on every row, so this tile is always available —
    /// it just needs enough rows to be a bar rather than a rumour.
    static func outcomes(_ input: InsightsInput) -> InsightTile {
        guard input.total >= minimumRows else {
            return .sparse(label: outcomesLabel, need: need(input.total, noun: "dictations"))
        }
        return .stacked(label: outcomesLabel, segments: ranked(input.outcomes))
    }

    /// Absent when there is nothing to explain — a breakdown of zero empties is
    /// a chart of nothing, and the good news is already legible in the outcomes
    /// tile. `unclassifiedEmpty` rides as a footnote and is **never** folded
    /// into the reasons.
    static func empties(_ input: InsightsInput, locale: Locale) -> InsightTile? {
        guard input.empty > 0 else { return nil }
        guard input.empty >= minimumRows else {
            return .sparse(label: emptiesLabel, need: need(input.empty, noun: "empty holds"))
        }
        var footnote: String?
        if input.unclassifiedEmpty > 0 {
            footnote = "unclassified \(input.unclassifiedEmpty) — logged before reasons existed"
        }
        var alarm: String?
        if input.unexplainedEmpty > 0 {
            alarm = "\(input.unexplainedEmpty) unexplained (\(percent(input.unexplainedEmptyRate)))"
                + " — audible speech, clean finish, no text"
        }
        return .ranked(label: emptiesLabel,
                       caption: "\(count(input.empty, locale: locale)) · \(percent(input.emptyRate)) of holds",
                       rows: ranked(input.emptyReasons),
                       footnote: footnote,
                       alarm: alarm)
    }

    /// The gated-section rule: no refine pass ever ran on this Mac, so the tile
    /// does not exist.
    static func cleanup(_ input: InsightsInput) -> InsightTile? {
        guard !input.aiOutcomes.isEmpty else { return nil }
        let rows = ranked(input.aiOutcomes)
        let contributing = rows.reduce(0) { $0 + $1.count }
        guard contributing >= minimumRows else {
            return .sparse(label: cleanupLabel, need: need(contributing, noun: "cleaned dictations"))
        }
        return .ranked(label: cleanupLabel, caption: nil, rows: rows, footnote: nil, alarm: nil)
    }

    /// From the dictionary, not from metrics. Hidden when no term has ever
    /// fired — an empty leaderboard is not a chart.
    static func vocabulary(_ input: InsightsInput) -> InsightTile? {
        let used = input.vocabulary.filter { $0.hits > 0 }
        guard !used.isEmpty else { return nil }
        let rows = used
            .sorted { $0.hits == $1.hits ? $0.term < $1.term : $0.hits > $1.hits }
            .prefix(vocabularyLimit)
            .map { LabeledCount($0.term, $0.hits) }
        let footnote = input.learnedTermCount > 0
            ? "\(input.learnedTermCount) term\(input.learnedTermCount == 1 ? "" : "s") learned by ear"
            : nil
        return .ranked(label: vocabularyLabel, caption: nil, rows: Array(rows),
                       footnote: footnote, alarm: nil)
    }

    /// The metrics footer strip. Nil when the window carries no finalize
    /// timings at all.
    public static func footer(from input: InsightsInput, locale: Locale = .autoupdatingCurrent) -> String? {
        guard let p50 = input.finalizeP50 else { return nil }
        var parts = ["finalize p50 \(ms(p50))"]
        if let p90 = input.finalizeP90 { parts.append("p90 \(ms(p90))") }
        if input.timedOut > 0 {
            parts.append("timed out \(count(input.timedOut, locale: locale)) (\(percent(input.timedOutRate)))")
        }
        if !input.windowLabel.isEmpty { parts.append(input.windowLabel) }
        return parts.joined(separator: " · ")
    }

    // MARK: - shared shaping

    /// Count descending, then key ascending — the same tie-break
    /// `MetricsSummary.ranked` uses, so a tile and a Doctor report never
    /// disagree about which of two equal outcomes comes first.
    public static func ranked(_ counts: [String: Int]) -> [LabeledCount] {
        counts
            .map { LabeledCount($0.key, $0.value) }
            .sorted { $0.count == $1.count ? $0.label < $1.label : $0.count > $1.count }
    }

    /// Daily counts, normalised against the busiest day. An all-zero window
    /// produces a flat line rather than a division by zero.
    public static func sparkline(_ days: [DayCount]) -> [Double] {
        let peak = days.map(\.count).max() ?? 0
        guard peak > 0 else { return days.map { _ in 0 } }
        return days.map { Double($0.count) / Double(peak) }
    }

    /// "Needs 5 dictations. You have 2." — never a zero, always the gap.
    public static func need(_ have: Int, noun: String) -> String {
        "Needs \(minimumRows) \(noun). You have \(have)."
    }

    static func count(_ value: Int, locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = locale
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// One decimal, because 5.2% and 0.3% are both meaningful and 5% and 0%
    /// are not.
    static func percent(_ fraction: Double) -> String {
        guard fraction.isFinite else { return "0.0%" }
        return String(format: "%.1f%%", fraction * 100)
    }

    static func ms(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        return "\(Int(value.rounded())) ms"
    }
}
