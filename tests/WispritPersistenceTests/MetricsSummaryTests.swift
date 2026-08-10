import XCTest
@testable import WispritPersistence

/// The fixture is shaped like the real 342-row `metrics.log`: Python-era rows
/// with nine keys, later rows with `release_to_text_ms` and the refine pair, and
/// new rows carrying the empty telemetry. Mixing the eras in one array is the
/// point — the summary has to survive the file it will actually be pointed at.
final class MetricsSummaryTests: XCTestCase {

    /// Fixed clock; every window in this file is measured against it.
    private let now = 1_786_400_000.0

    private func rows(_ lines: [String]) -> [JSONObject] {
        lines.compactMap {
            guard case .object(let object)? = try? WispritJSON.parse($0) else { return nil }
            return object
        }
    }

    /// File order, oldest first — the order `readAll()` returns.
    private var production: [JSONObject] {
        rows([
            // 30 days old: inside the file, outside a 7-day window.
            #"{"ts": 1783808000.0, "held_ms": 1500.0, "engine": "apple_live", "finalize_ms": 200.0, "timed_out": false, "post_ms": 1.0, "insert_ms": 500.0, "outcome": "paste", "chars": 40, "release_to_text_ms": 1000.0}"#,
            #"{"ts": 1786390000.0, "held_ms": 1175.2, "engine": "apple_live", "finalize_ms": 75.5, "timed_out": false, "post_ms": 0.4, "insert_ms": 509.2, "outcome": "paste", "chars": 14, "release_to_text_ms": 775.9, "ai_ms": 185.5, "ai": "applied"}"#,
            #"{"ts": 1786391000.0, "held_ms": 46647.7, "engine": "apple_live", "finalize_ms": 103.8, "timed_out": false, "post_ms": 2.9, "insert_ms": 535.2, "outcome": "paste", "chars": 613, "release_to_text_ms": 3188.3, "ai_ms": 2413.8, "ai": "applied"}"#,
            #"{"ts": 1786392000.0, "held_ms": 1304.3, "engine": "apple_live", "finalize_ms": 183.7, "timed_out": false, "post_ms": 2.1, "insert_ms": 8.7, "outcome": "type", "chars": 6, "release_to_text_ms": 488.2, "ai_ms": 286.7, "ai": "applied"}"#,
            #"{"ts": 1786393000.0, "held_ms": 927.7, "engine": "apple_live", "finalize_ms": 60.1, "timed_out": false, "post_ms": 0.4, "insert_ms": 1.1, "outcome": "im_streaming", "chars": 6, "release_to_text_ms": 265.2, "ai_ms": 191.9, "ai": "applied"}"#,
            #"{"ts": 1786394000.0, "held_ms": 2100.0, "engine": "apple_live", "finalize_ms": 120.0, "timed_out": false, "post_ms": 1.2, "insert_ms": 480.0, "outcome": "paste", "chars": 88, "release_to_text_ms": 900.0}"#,
            // Pre-telemetry empties: the two rows nobody could tell apart.
            #"{"ts": 1786395000.0, "held_ms": 451.0, "engine": "apple_live", "finalize_ms": 1501.3, "timed_out": true, "post_ms": 0.0, "insert_ms": 0.0, "outcome": "empty", "chars": 0}"#,
            #"{"ts": 1786396000.0, "held_ms": 3000.0, "engine": "apple_live", "finalize_ms": 1500.9, "timed_out": false, "post_ms": 0.0, "insert_ms": 0.0, "outcome": "empty", "chars": 0}"#,
            // Classified empties.
            #"{"ts": 1786396500.0, "held_ms": 2000.0, "engine": "apple_live", "finalize_ms": 95.0, "timed_out": false, "post_ms": 0.0, "insert_ms": 0.0, "outcome": "empty", "chars": 0, "ai_ms": 100.0, "ai": "empty", "empty_reason": "silent", "peak_level": 0.0, "audio_ms": 1950.0}"#,
            #"{"ts": 1786397000.0, "held_ms": 300.0, "engine": "apple_live", "finalize_ms": 88.0, "timed_out": false, "post_ms": 0.0, "insert_ms": 0.0, "outcome": "empty", "chars": 0, "empty_reason": "short_hold", "peak_level": 0.0, "audio_ms": 260.0}"#,
            // The real defect: audible, held, clean, nothing out.
            #"{"ts": 1786397500.0, "held_ms": 2153.6, "engine": "apple_live", "finalize_ms": 118.4, "timed_out": false, "post_ms": 0.0, "insert_ms": 0.0, "outcome": "empty", "chars": 0, "empty_reason": "produced_nothing", "peak_level": 0.1842, "audio_ms": 2100.0}"#,
            // produced_nothing, but the hold was under a second — not unexplained.
            #"{"ts": 1786398000.0, "held_ms": 900.0, "engine": "apple_live", "finalize_ms": 130.0, "timed_out": false, "post_ms": 0.0, "insert_ms": 0.0, "outcome": "empty", "chars": 0, "empty_reason": "produced_nothing", "peak_level": 0.0301, "audio_ms": 850.0}"#,
            // produced_nothing, but nothing was ever audible — not unexplained.
            #"{"ts": 1786398500.0, "held_ms": 2000.0, "engine": "apple_live", "finalize_ms": 140.0, "timed_out": false, "post_ms": 0.0, "insert_ms": 0.0, "outcome": "empty", "chars": 0, "empty_reason": "produced_nothing", "peak_level": 0.01, "audio_ms": 1950.0}"#,
            #"{"ts": 1786399000.0, "held_ms": 1200.0, "engine": "apple_live", "finalize_ms": 1500.4, "timed_out": true, "post_ms": 0.0, "insert_ms": 0.0, "outcome": "empty", "chars": 0, "empty_reason": "timed_out", "peak_level": 0.3, "audio_ms": 1150.0}"#,
            #"{"ts": 1786399500.0, "held_ms": 2500.0, "engine": "apple_live", "finalize_ms": 110.0, "timed_out": false, "post_ms": 0.5, "insert_ms": 0.0, "outcome": "correction", "chars": 25}"#,
        ])
    }

    private func summary(_ window: MetricsWindow = .all) -> MetricsSummary {
        MetricsSummary.summarize(production, window: window, now: now)
    }

    // MARK: histograms

    func testOutcomeHistogramCoversEveryInsertionTier() {
        let s = summary()
        XCTAssertEqual(s.total, 15)
        XCTAssertEqual(s.outcomes, ["paste": 4, "type": 1, "im_streaming": 1,
                                    "empty": 8, "correction": 1])
        XCTAssertEqual(s.empty, 8)
        XCTAssertEqual(s.emptyRate, 8.0 / 15.0, accuracy: 1e-12)
    }

    /// The one rule the whole file exists to protect: rows that predate the
    /// classifier are counted apart, never folded into a real reason.
    func testLegacyEmptiesAreUnclassifiedAndNeverJoinARealBucket() {
        let s = summary()
        XCTAssertEqual(s.unclassifiedEmpty, 2)
        XCTAssertEqual(s.emptyReasons, ["silent": 1, "short_hold": 1,
                                        "produced_nothing": 3, "timed_out": 1])
        XCTAssertEqual(s.emptyReasons.values.reduce(0, +) + s.unclassifiedEmpty, s.empty)
    }

    func testAiHistogramOnlyCountsRowsThatCarryTheField() {
        XCTAssertEqual(summary().aiOutcomes, ["applied": 4, "empty": 1])
    }

    func testTimedOutRateSpansBothErasOfEmptyRow() {
        let s = summary()
        XCTAssertEqual(s.timedOut, 2)
        XCTAssertEqual(s.timedOutRate, 2.0 / 15.0, accuracy: 1e-12)
    }

    // MARK: the alarm

    func testUnexplainedEmptyRequiresAudibleSpeechAndARealHold() {
        let s = summary()
        XCTAssertEqual(s.unexplainedEmpty, 1, "only the audible, held, clean-finish row")
        XCTAssertEqual(s.unexplainedEmptyRate, 1.0 / 15.0, accuracy: 1e-12,
                       "measured over ALL utterances, not just empties")
    }

    func testUnexplainedEmptyBoundariesAreInclusive() {
        func line(peak: Double, held: Double) -> String {
            #"{"ts": 1786399000.0, "held_ms": \#(held), "engine": "apple_live", "finalize_ms": 100.0, "timed_out": false, "post_ms": 0.0, "insert_ms": 0.0, "outcome": "empty", "chars": 0, "empty_reason": "produced_nothing", "peak_level": \#(peak)}"#
        }
        let cases: [(Double, Double, Int)] = [
            (0.02, 1000.0, 1),      // exactly at both gates: counted
            (0.0199, 1000.0, 0),
            (0.02, 999.9, 0),
            (0.5, 5000.0, 1),
        ]
        for (peak, held, expected) in cases {
            let s = MetricsSummary.summarize(rows([line(peak: peak, held: held)]), now: now)
            XCTAssertEqual(s.unexplainedEmpty, expected, "peak \(peak), held \(held)")
        }
    }

    /// A legacy empty is never unexplained, however loud it might have been —
    /// the row simply does not say.
    func testLegacyEmptiesAreNeverCountedAsUnexplained() {
        let legacy = rows([
            #"{"ts": 1786399000.0, "held_ms": 3000.0, "engine": "apple_live", "finalize_ms": 1500.9, "timed_out": false, "post_ms": 0.0, "insert_ms": 0.0, "outcome": "empty", "chars": 0}"#,
        ])
        let s = MetricsSummary.summarize(legacy, now: now)
        XCTAssertEqual(s.unexplainedEmpty, 0)
        XCTAssertEqual(s.unclassifiedEmpty, 1)
        XCTAssertTrue(s.emptyReasons.isEmpty)
    }

    // MARK: percentiles

    func testPercentilesUseNearestRankOverThePresentSamples() {
        let s = summary()
        XCTAssertEqual(s.finalizeMsP50, 120.0)
        XCTAssertEqual(s.finalizeMsP90, 1500.9)
    }

    /// `release_to_text_ms` only exists on rows that put text in front of the
    /// user, so the percentile must be over those six rows, not all fifteen.
    func testReleaseToTextPercentilesSkipRowsWithoutTheField() {
        let s = summary()
        XCTAssertEqual(s.releaseToTextMsP50, 775.9)
        XCTAssertEqual(s.releaseToTextMsP90, 3188.3)
    }

    func testPercentilesAreNilWithNoSamples() {
        let s = MetricsSummary.summarize([], now: now)
        XCTAssertNil(s.finalizeMsP50)
        XCTAssertNil(s.releaseToTextMsP90)
        XCTAssertEqual(s.total, 0)
        XCTAssertEqual(s.emptyRate, 0, "no rows must not divide by zero")
    }

    func testNearestRankRule() {
        let samples = [1.0, 2, 3, 4, 5, 6, 7, 8, 9, 10]
        XCTAssertEqual(MetricsSummary.percentile(samples, 50), 5)
        XCTAssertEqual(MetricsSummary.percentile(samples, 90), 9)
        XCTAssertEqual(MetricsSummary.percentile(samples, 100), 10)
        XCTAssertEqual(MetricsSummary.percentile([42.0], 90), 42)
        XCTAssertNil(MetricsSummary.percentile([], 50))
    }

    // MARK: windowing

    func testDayWindowDropsRowsOlderThanTheCutoff() {
        let s = summary(MetricsWindow(days: 7))
        XCTAssertEqual(s.total, 14)
        XCTAssertEqual(s.outcomes["paste"], 3)
        XCTAssertEqual(s.releaseToTextMsP50, 775.9)
    }

    func testRowWindowTakesTheNewestRows() {
        let s = summary(MetricsWindow(rows: 3))
        XCTAssertEqual(s.total, 3)
        XCTAssertEqual(s.outcomes, ["empty": 2, "correction": 1])
        XCTAssertEqual(s.emptyReasons, ["produced_nothing": 1, "timed_out": 1])
        XCTAssertEqual(s.unexplainedEmpty, 0)
    }

    func testBothBoundsCompose() {
        XCTAssertEqual(summary(MetricsWindow(days: 7, rows: 100)).total, 14)
        XCTAssertEqual(summary(MetricsWindow(days: 7, rows: 2)).total, 2)
        XCTAssertEqual(summary(MetricsWindow(days: 3650)).total, 15)
        XCTAssertEqual(MetricsSummary.windowed(production, in: MetricsWindow(rows: 1),
                                               now: now).count, 1)
    }

    func testARowWithNoTimestampCannotBePlacedInADayWindow() {
        let untimed = rows([
            #"{"held_ms": 100.0, "engine": "apple_live", "finalize_ms": 10.0, "timed_out": false, "post_ms": 0.0, "insert_ms": 0.0, "outcome": "paste", "chars": 3}"#,
        ])
        XCTAssertEqual(MetricsSummary.summarize(untimed, now: now).total, 1)
        XCTAssertEqual(MetricsSummary.summarize(untimed, window: MetricsWindow(days: 7),
                                                now: now).total, 0)
    }

    // MARK: rows that are not utterances

    /// The `vocab_retro` line reports an off-path pass, not a dictation. Left in
    /// the counts it would add a `finalize_ms` of 0 to the latency percentiles
    /// and dilute every rate here by roughly the success rate — this summary
    /// answers "how often does Wisprit fail me", and that has to be per
    /// utterance.
    func testVocabRetroRowsAreNotCountedAsUtterances() {
        let mixed = rows([
            #"{"ts": 1786399000.0, "held_ms": 1200.0, "engine": "apple_live", "finalize_ms": 120.0, "timed_out": false, "post_ms": 0.5, "insert_ms": 10.0, "outcome": "im_streaming", "chars": 43, "release_to_text_ms": 300.0}"#,
            #"{"ts": 1786399001.0, "held_ms": 0.0, "engine": "apple_dictation", "finalize_ms": 0.0, "timed_out": false, "post_ms": 0.0, "insert_ms": 0.0, "outcome": "vocab_retro", "chars": 0, "vocab_ms": 1243.6, "vocab_hits": 2, "vocab_delta": 1, "applied": true}"#,
            #"{"ts": 1786399002.0, "held_ms": 2000.0, "engine": "apple_live", "finalize_ms": 130.0, "timed_out": false, "post_ms": 0.0, "insert_ms": 0.0, "outcome": "empty", "chars": 0, "empty_reason": "produced_nothing", "peak_level": 0.2, "audio_ms": 1950.0}"#,
        ])
        let s = MetricsSummary.summarize(mixed, now: now)
        XCTAssertEqual(s.total, 2)
        XCTAssertEqual(s.outcomes, ["im_streaming": 1, "empty": 1])
        XCTAssertEqual(s.emptyRate, 0.5, accuracy: 1e-12)
        XCTAssertEqual(s.unexplainedEmptyRate, 0.5, accuracy: 1e-12)

        // …and the latency percentiles, which the vocab row's `finalize_ms: 0.0`
        // would otherwise anchor to zero.
        let one = MetricsSummary.summarize(rows([
            #"{"ts": 1786399000.0, "held_ms": 1200.0, "engine": "apple_live", "finalize_ms": 120.0, "timed_out": false, "post_ms": 0.5, "insert_ms": 10.0, "outcome": "paste", "chars": 43}"#,
            #"{"ts": 1786399001.0, "held_ms": 0.0, "engine": "apple_dictation", "finalize_ms": 0.0, "timed_out": false, "post_ms": 0.0, "insert_ms": 0.0, "outcome": "vocab_retro", "chars": 0, "vocab_ms": 1243.6, "vocab_hits": 2, "vocab_delta": 1, "applied": true}"#,
        ]), now: now)
        XCTAssertEqual(one.finalizeMsP50, 120.0)
    }

    // MARK: zero-edit rate (Phase 5)

    /// The observable-denominator rule, as data: three observations — two
    /// clean, one edited — over five utterances yield 2/3, never 2/5. The
    /// unobserved utterances simply do not exist to this metric.
    func testZeroEditRateIsOverObservedUtterancesOnly() {
        let mixed = rows([
            #"{"ts": 1786399000.0, "held_ms": 1200.0, "engine": "apple_live", "finalize_ms": 120.0, "timed_out": false, "post_ms": 0.5, "insert_ms": 10.0, "outcome": "im_streaming", "chars": 43, "release_to_text_ms": 300.0}"#,
            #"{"ts": 1786399001.0, "held_ms": 0.0, "engine": "", "finalize_ms": 0.0, "timed_out": false, "post_ms": 0.0, "insert_ms": 0.0, "outcome": "edit_observed", "chars": 0, "edit_dist": 0, "edit_scope": "im"}"#,
            #"{"ts": 1786399002.0, "held_ms": 1300.0, "engine": "apple_live", "finalize_ms": 110.0, "timed_out": false, "post_ms": 0.5, "insert_ms": 10.0, "outcome": "paste", "chars": 20, "release_to_text_ms": 700.0}"#,
            #"{"ts": 1786399003.0, "held_ms": 0.0, "engine": "", "finalize_ms": 0.0, "timed_out": false, "post_ms": 0.0, "insert_ms": 0.0, "outcome": "edit_observed", "chars": 0, "edit_dist": 2, "edit_scope": "im"}"#,
            #"{"ts": 1786399004.0, "held_ms": 1300.0, "engine": "apple_live", "finalize_ms": 100.0, "timed_out": false, "post_ms": 0.5, "insert_ms": 10.0, "outcome": "paste", "chars": 20, "release_to_text_ms": 650.0}"#,
            #"{"ts": 1786399005.0, "held_ms": 0.0, "engine": "", "finalize_ms": 0.0, "timed_out": false, "post_ms": 0.0, "insert_ms": 0.0, "outcome": "edit_observed", "chars": 0, "edit_dist": 0, "edit_scope": "ax"}"#,
            #"{"ts": 1786399006.0, "held_ms": 1300.0, "engine": "apple_live", "finalize_ms": 100.0, "timed_out": false, "post_ms": 0.5, "insert_ms": 10.0, "outcome": "paste", "chars": 20}"#,
            #"{"ts": 1786399007.0, "held_ms": 1300.0, "engine": "apple_live", "finalize_ms": 100.0, "timed_out": false, "post_ms": 0.5, "insert_ms": 10.0, "outcome": "paste", "chars": 20}"#,
        ])
        let s = MetricsSummary.summarize(mixed, now: now)
        XCTAssertEqual(s.total, 5, "observation lines are not utterances")
        XCTAssertEqual(s.editObserved, 3)
        XCTAssertEqual(s.zeroEdit, 2)
        XCTAssertEqual(s.zeroEditRate, 2.0 / 3.0, accuracy: 1e-12)
    }

    /// An observed edit whose size could not be measured (`.changed` with no
    /// text) carries no `edit_dist` at all: it joins the denominator and never
    /// the numerator — the honest direction for the metric to err.
    func testAnUnknowableDistanceCountsObservedButNeverZeroEdit() {
        let s = MetricsSummary.summarize(rows([
            #"{"ts": 1786399000.0, "held_ms": 0.0, "engine": "", "finalize_ms": 0.0, "timed_out": false, "post_ms": 0.0, "insert_ms": 0.0, "outcome": "edit_observed", "chars": 0, "edit_scope": "im"}"#,
            #"{"ts": 1786399001.0, "held_ms": 0.0, "engine": "", "finalize_ms": 0.0, "timed_out": false, "post_ms": 0.0, "insert_ms": 0.0, "outcome": "edit_observed", "chars": 0, "edit_dist": 0, "edit_scope": "im"}"#,
        ]), now: now)
        XCTAssertEqual(s.editObserved, 2)
        XCTAssertEqual(s.zeroEdit, 1)
        XCTAssertEqual(s.zeroEditRate, 0.5, accuracy: 1e-12)
    }

    func testNothingObservedIsZeroOverZeroNotAHundredPercent() {
        let s = summary()
        XCTAssertEqual(s.editObserved, 0)
        XCTAssertEqual(s.zeroEdit, 0)
        XCTAssertEqual(s.zeroEditRate, 0)
        XCTAssertFalse(MetricsSummary.render(for: s).contains("zero-edit"),
                       "no denominator, no rate — the row is absent, not 0%")
    }

    func testRenderShowsTheRateWithItsDenominator() {
        let s = MetricsSummary.summarize(rows([
            #"{"ts": 1786399000.0, "held_ms": 1200.0, "engine": "apple_live", "finalize_ms": 120.0, "timed_out": false, "post_ms": 0.5, "insert_ms": 10.0, "outcome": "paste", "chars": 43}"#,
            #"{"ts": 1786399001.0, "held_ms": 0.0, "engine": "", "finalize_ms": 0.0, "timed_out": false, "post_ms": 0.0, "insert_ms": 0.0, "outcome": "edit_observed", "chars": 0, "edit_dist": 0, "edit_scope": "im"}"#,
            #"{"ts": 1786399002.0, "held_ms": 0.0, "engine": "", "finalize_ms": 0.0, "timed_out": false, "post_ms": 0.0, "insert_ms": 0.0, "outcome": "edit_observed", "chars": 0, "edit_dist": 3, "edit_scope": "ax"}"#,
        ]), now: now)
        let text = MetricsSummary.render(for: s)
        XCTAssertTrue(text.contains("zero-edit"), text)
        XCTAssertTrue(text.contains("1/2 observed (50.0%)"),
                      "the n rides in the same cell as the rate: \(text)")
    }

    /// A row window is a window over the FILE, because `windowed` is also what a
    /// caller lists; the non-utterance rows are dropped afterwards, so "last 2
    /// rows" can legitimately summarize one utterance.
    func testARowWindowCountsLinesAndThenDropsTheNonUtterances() {
        let mixed = rows([
            #"{"ts": 1786399000.0, "held_ms": 1200.0, "engine": "apple_live", "finalize_ms": 120.0, "timed_out": false, "post_ms": 0.5, "insert_ms": 10.0, "outcome": "paste", "chars": 43}"#,
            #"{"ts": 1786399001.0, "held_ms": 1200.0, "engine": "apple_live", "finalize_ms": 120.0, "timed_out": false, "post_ms": 0.5, "insert_ms": 10.0, "outcome": "paste", "chars": 43}"#,
            #"{"ts": 1786399002.0, "held_ms": 0.0, "engine": "apple_dictation", "finalize_ms": 0.0, "timed_out": false, "post_ms": 0.0, "insert_ms": 0.0, "outcome": "vocab_retro", "chars": 0, "vocab_ms": 900.0, "vocab_hits": 1, "vocab_delta": 0, "applied": false}"#,
        ])
        XCTAssertEqual(MetricsSummary.windowed(mixed, in: MetricsWindow(rows: 2), now: now).count, 2)
        XCTAssertEqual(MetricsSummary.summarize(mixed, window: MetricsWindow(rows: 2),
                                                now: now).total, 1)
    }

    // MARK: defensive reads

    func testIntegerShapedNumbersAndFlagsStillCount() {
        // Nothing writes these today, but the file spans app versions and a `0`
        // where a `0.0` was expected must not silently become an absence.
        let odd = rows([
            #"{"ts": 1786399000, "held_ms": 2000, "engine": "apple_live", "finalize_ms": 100, "timed_out": 1, "post_ms": 0, "insert_ms": 0, "outcome": "empty", "chars": 0, "empty_reason": "produced_nothing", "peak_level": 1}"#,
        ])
        let s = MetricsSummary.summarize(odd, now: now)
        XCTAssertEqual(s.timedOut, 1)
        XCTAssertEqual(s.finalizeMsP50, 100)
        XCTAssertEqual(s.unexplainedEmpty, 1)
    }

    func testTheVoicedThresholdMatchesTheEnginesConstant() {
        // WispritPersistence cannot import WispritEngine; EmptyReasonTests pins
        // the other side of this pair to `SpeechAnalyzerEngine.voicedPeakThreshold`.
        XCTAssertEqual(MetricsSummary.voicedPeakThreshold, 0.02)
        XCTAssertEqual(MetricsSummary.shortHoldMs, 1000)
    }

    // MARK: rendering

    func testRenderIsAStableMultiLineBlock() {
        let text = MetricsSummary.render(for: summary(MetricsWindow(days: 7)))
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(lines.first, "Wisprit metrics — last 7 days")
        XCTAssertTrue(text.contains("utterances      14"), text)
        XCTAssertTrue(text.contains("empty 8, paste 3"), "histograms rank by count: \(text)")
        XCTAssertTrue(text.contains("produced_nothing 3"), text)
        XCTAssertTrue(text.contains("unclassified 2"), text)
        XCTAssertTrue(text.contains("finalize_ms"), text)
        XCTAssertTrue(text.contains("p50 775.9  p90 3188.3"), text)
        XCTAssertFalse(text.contains("\n\n"), "no blank lines in a CLI block")
        XCTAssertEqual(text, MetricsSummary.render(for: summary(MetricsWindow(days: 7))),
                       "render must not depend on dictionary order")
    }

    func testRenderSaysSoWhenThereIsNothingToReport() {
        let text = MetricsSummary.render(for: MetricsSummary.summarize([], now: now))
        XCTAssertEqual(text, "Wisprit metrics — all time\n  no utterances recorded")
    }

    func testWindowLabels() {
        XCTAssertEqual(MetricsWindow.all.label, "all time")
        XCTAssertEqual(MetricsWindow(days: 7).label, "last 7 days")
        XCTAssertEqual(MetricsWindow(rows: 50).label, "last 50 rows")
        XCTAssertEqual(MetricsWindow(days: 1, rows: 50).label, "last 1 days, last 50 rows")
        XCTAssertEqual(MetricsWindow(days: 0.5).label, "last 0.5 days")
    }

    func testRankedHistogramBreaksTiesByName() {
        XCTAssertEqual(MetricsSummary.ranked(["b": 1, "a": 1, "c": 9]).map(\.0),
                       ["c", "a", "b"])
    }
}
