import Foundation

/// The read side of `metrics.log`: what 342 append-only lines actually say.
///
/// Pure by construction — it takes the `[JSONObject]` rows `MetricsWriter.readAll()`
/// returns plus an explicit `now`, and never reads the clock, the disk or the
/// settings itself. That is what lets `Wisprit stats`, the doctor row and a test
/// with a hand-written fixture all agree on the same numbers.
///
/// The stream spans the Python era, the pre-telemetry Swift era and this one, so
/// every field is read defensively: a missing key is never a zero, it is an
/// absence, and empties that predate `empty_reason` are counted as
/// `unclassified` rather than being folded into a real bucket. Inventing a
/// reason for them would poison exactly the number this file exists to report.

/// Which slice of the stream to summarize. Both bounds are optional and compose:
/// days first, then the last N of what survives.
public struct MetricsWindow: Sendable, Equatable {
    /// Keep rows with `ts >= now - days * 86400`. A row with no usable `ts`
    /// cannot be placed in time, so a day window drops it.
    public var days: Double?
    /// Keep at most this many rows, taken from the end (`readAll` is newest-last).
    public var rows: Int?

    public init(days: Double? = nil, rows: Int? = nil) {
        self.days = days
        self.rows = rows
    }

    /// The whole file.
    public static let all = MetricsWindow()

    public var label: String {
        switch (days, rows) {
        case (nil, nil): return "all time"
        case (let d?, nil): return "last \(MetricsSummary.trim(d)) days"
        case (nil, let r?): return "last \(r) rows"
        case (let d?, let r?): return "last \(MetricsSummary.trim(d)) days, last \(r) rows"
        }
    }
}

public struct MetricsSummary: Sendable, Equatable {
    public var window: MetricsWindow
    public var total: Int
    /// `outcome` → count over every row in the window (`paste`, `type`,
    /// `im_streaming`, `correction`, `empty`, …).
    public var outcomes: [String: Int]
    public var empty: Int
    public var emptyRate: Double
    /// `empty_reason` → count, CLASSIFIED empties only.
    public var emptyReasons: [String: Int]
    /// Empties carrying no `empty_reason` — rows written before the classifier
    /// existed. Reported next to `emptyReasons`, never merged into it.
    public var unclassifiedEmpty: Int
    public var timedOut: Int
    public var timedOutRate: Double
    public var finalizeMsP50: Double?
    public var finalizeMsP90: Double?
    public var releaseToTextMsP50: Double?
    public var releaseToTextMsP90: Double?
    /// `ai` → count over the rows that carry it (absent = refine never ran).
    public var aiOutcomes: [String: Int]
    /// Empties the telemetry cannot explain away: the analyzer was given audible
    /// speech, finished cleanly, and returned nothing. The one number worth
    /// alarming on — everything else is a user who did not speak or a fault that
    /// already announced itself.
    public var unexplainedEmpty: Int
    /// `unexplainedEmpty / total` — over ALL utterances, not just empties, so it
    /// reads as "how often does Wisprit silently fail me".
    public var unexplainedEmptyRate: Double
    /// `edit_observed` rows in the window: utterances whose fate the pipeline
    /// actually re-read out of a field. This is the zero-edit denominator, and
    /// it is reported wherever the rate is — a rate without its `n` is how the
    /// metric gets quietly inflated.
    public var editObserved: Int
    /// …of which `edit_dist == 0`: the user did not have to touch a character.
    /// A `.changed` observation whose size could not be measured carries no
    /// `edit_dist` at all — observed, never zero-edit.
    public var zeroEdit: Int
    /// `zeroEdit / editObserved`, over OBSERVED utterances ONLY. Unobserved
    /// utterances are excluded from the denominator rather than assumed clean
    /// (`docs/eval/DEFINITIONS.md` § Zero-edit rate); 0 when nothing was
    /// observed, and the renderer refuses to print a rate with no denominator.
    public var zeroEditRate: Double

    /// Mirrors `SpeechAnalyzerEngine.voicedPeakThreshold`. WispritPersistence
    /// cannot import WispritEngine (WispritKit is the only shared seam), so the
    /// constant is restated here; it is pinned to the engine's by test.
    public static let voicedPeakThreshold = 0.02
    /// Below this the hold was too short to have said anything.
    public static let shortHoldMs = 1000.0
    /// The `empty_reason` value that means "no benign explanation applies".
    public static let producedNothing = "produced_nothing"

    /// `outcome` values that are NOT an utterance.
    ///
    /// `vocab_retro` is a second line about the off-path vocabulary pass, written
    /// after some utterance's own row was already on disk. Counting it here would
    /// put a `finalize_ms` of 0 into the latency percentiles and dilute every
    /// rate on this struct by roughly the success rate — this summary is about
    /// utterances, so a row that is not one is dropped before anything is
    /// counted. (`correction` stays: a spoken-spelling directive IS an
    /// utterance, it just had nothing to insert.) `edit_observed` is the same
    /// shape one phase later: a reference-less line about text some earlier
    /// utterance inserted, written when a field re-read finally showed its fate.
    public static let nonUtteranceOutcomes: Set<String> = ["vocab_retro", "edit_observed"]

    /// The Phase-5 observation row's `outcome`.
    public static let editObservedOutcome = "edit_observed"

    // MARK: - aggregation

    public static func summarize(_ rows: [JSONObject],
                                 window: MetricsWindow = .all,
                                 now: Double) -> MetricsSummary {
        let inWindow = windowed(rows, in: window, now: now)

        // The zero-edit pair comes from the very rows the utterance stats drop:
        // count them before the filter, or the denominator can never be honest.
        var editObserved = 0, zeroEdit = 0
        for row in inWindow where string(row, "outcome") == editObservedOutcome {
            editObserved += 1
            if let dist = double(row, "edit_dist"), dist == 0 { zeroEdit += 1 }
        }

        let rows = inWindow
            .filter { !nonUtteranceOutcomes.contains(string($0, "outcome") ?? "") }
        let total = rows.count

        var outcomes: [String: Int] = [:]
        var emptyReasons: [String: Int] = [:]
        var aiOutcomes: [String: Int] = [:]
        var empty = 0, unclassified = 0, timedOut = 0, unexplained = 0
        var finalizeSamples: [Double] = []
        var releaseSamples: [Double] = []

        for row in rows {
            let outcome = string(row, "outcome") ?? ""
            outcomes[outcome, default: 0] += 1
            if let ai = string(row, "ai") { aiOutcomes[ai, default: 0] += 1 }
            if bool(row, "timed_out") { timedOut += 1 }
            if let finalizeMs = double(row, "finalize_ms") { finalizeSamples.append(finalizeMs) }
            // `release_to_text_ms` is written only on rows that actually put text
            // in front of the user, so presence IS the filter — hard-coding
            // "paste" would silently drop the `type` and `im_streaming` tiers.
            if let release = double(row, "release_to_text_ms") { releaseSamples.append(release) }

            guard outcome == "empty" else { continue }
            empty += 1
            guard let reason = string(row, "empty_reason") else {
                unclassified += 1
                continue
            }
            emptyReasons[reason, default: 0] += 1
            if reason == producedNothing,
               (double(row, "peak_level") ?? 0) >= voicedPeakThreshold,
               (double(row, "held_ms") ?? 0) >= shortHoldMs {
                unexplained += 1
            }
        }

        return MetricsSummary(
            window: window,
            total: total,
            outcomes: outcomes,
            empty: empty,
            emptyRate: rate(empty, of: total),
            emptyReasons: emptyReasons,
            unclassifiedEmpty: unclassified,
            timedOut: timedOut,
            timedOutRate: rate(timedOut, of: total),
            finalizeMsP50: percentile(finalizeSamples, 50),
            finalizeMsP90: percentile(finalizeSamples, 90),
            releaseToTextMsP50: percentile(releaseSamples, 50),
            releaseToTextMsP90: percentile(releaseSamples, 90),
            aiOutcomes: aiOutcomes,
            unexplainedEmpty: unexplained,
            unexplainedEmptyRate: rate(unexplained, of: total),
            editObserved: editObserved,
            zeroEdit: zeroEdit,
            zeroEditRate: rate(zeroEdit, of: editObserved))
    }

    /// The rows `summarize` would have looked at — exposed so a caller can list
    /// the same slice it just reported on.
    public static func windowed(_ rows: [JSONObject], in window: MetricsWindow,
                                now: Double) -> [JSONObject] {
        var kept = rows
        if let days = window.days {
            let cutoff = now - days * 86_400
            kept = kept.filter { (double($0, "ts") ?? -.infinity) >= cutoff }
        }
        if let limit = window.rows, kept.count > limit {
            kept = Array(kept.suffix(limit))
        }
        return kept
    }

    /// Histogram in report order: commonest first, ties broken by name so the
    /// output is stable across runs (a dictionary's order is not).
    public static func ranked(_ histogram: [String: Int]) -> [(String, Int)] {
        histogram.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { ($0.key, $0.value) }
    }

    // MARK: - rendering

    /// Plain multi-line text for a terminal: `Wisprit stats` prints it verbatim
    /// and the doctor row quotes the lines it cares about.
    public static func render(for summary: MetricsSummary) -> String {
        var lines = ["Wisprit metrics — \(summary.window.label)"]
        guard summary.total > 0 else {
            lines.append("  no utterances recorded")
            return lines.joined(separator: "\n")
        }
        func row(_ label: String, _ value: String) {
            lines.append("  " + label.padding(toLength: 16, withPad: " ", startingAt: 0) + value)
        }

        row("utterances", "\(summary.total)")
        row("outcomes", histogram(summary.outcomes))
        row("empty", "\(summary.empty) (\(percent(summary.emptyRate)))")
        if !summary.emptyReasons.isEmpty {
            row("empty reasons", histogram(summary.emptyReasons))
        }
        if summary.unclassifiedEmpty > 0 {
            row("", "unclassified \(summary.unclassifiedEmpty) (logged before empty_reason existed)")
        }
        row("unexplained", "\(summary.unexplainedEmpty) (\(percent(summary.unexplainedEmptyRate)))"
            + "  audible speech, clean finish, no text")
        row("timed out", "\(summary.timedOut) (\(percent(summary.timedOutRate)))")
        row("finalize_ms", "p50 \(ms(summary.finalizeMsP50))  p90 \(ms(summary.finalizeMsP90))")
        row("release_to_text", "p50 \(ms(summary.releaseToTextMsP50))  p90 \(ms(summary.releaseToTextMsP90))")
        if !summary.aiOutcomes.isEmpty {
            row("ai", histogram(summary.aiOutcomes))
        }
        // Only when something was observed: a rate over an empty denominator is
        // not a rate, and the `n` rides in the same cell as the fraction.
        if summary.editObserved > 0 {
            row("zero-edit", "\(summary.zeroEdit)/\(summary.editObserved) observed "
                + "(\(percent(summary.zeroEditRate)))")
        }
        return lines.joined(separator: "\n")
    }

    static func histogram(_ counts: [String: Int]) -> String {
        ranked(counts).map { "\($0.0) \($0.1)" }.joined(separator: ", ")
    }

    static func percent(_ rate: Double) -> String { String(format: "%.1f%%", rate * 100) }

    static func ms(_ value: Double?) -> String {
        guard let value else { return "n/a" }
        return String(format: "%.1f", value)
    }

    /// `7.0` reads as "7 days"; a fractional window keeps its digits.
    static func trim(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }

    // MARK: - row access

    /// Nearest-rank percentile over the samples present. Deliberately not
    /// interpolated: with 62 empties in a month there is no resolution to
    /// interpolate, and "p90 is a measurement we actually took" is easier to
    /// reason about when a number moves.
    static func percentile(_ samples: [Double], _ p: Double) -> Double? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        let rank = Int((p / 100 * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank, 1), sorted.count) - 1]
    }

    static func rate(_ part: Int, of total: Int) -> Double {
        total > 0 ? Double(part) / Double(total) : 0
    }

    /// Numbers arrive as `.int` or `.double` depending on how the writer of the
    /// day emitted them (`chars` is an int, `held_ms` a float, and Python wrote
    /// `0.0` where a later build might write `0`).
    static func double(_ row: JSONObject, _ key: String) -> Double? {
        switch row[key] {
        case .double(let d)?: return d
        case .int(let i)?: return Double(i)
        default: return nil
        }
    }

    static func string(_ row: JSONObject, _ key: String) -> String? {
        guard case .string(let s)? = row[key] else { return nil }
        return s
    }

    static func bool(_ row: JSONObject, _ key: String) -> Bool {
        switch row[key] {
        case .bool(let b)?: return b
        case .int(let i)?: return i != 0          // pre-JSON-bool rows wrote 0/1
        default: return false
        }
    }
}
