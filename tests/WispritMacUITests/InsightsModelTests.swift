import XCTest
@testable import WispritMacUI

/// Insights' pure logic — `ui-redesign.md` §3.5 / §6.1.
///
/// No disk and no SQLite: `InsightsInput` is the neutral seam, so every rule
/// about what a tile refuses to draw is assertable as a value transformation.
final class InsightsModelTests: XCTestCase {

    private let locale = Locale(identifier: "en_US_POSIX")

    private func label(_ tile: InsightTile) -> String {
        switch tile {
        case .value(let label, _, _, _),
             .latency(let label, _, _, _),
             .stacked(let label, _),
             .sparse(let label, _):
            return label
        case .ranked(let label, _, _, _, _):
            return label
        }
    }

    private func tile(_ named: String, _ input: InsightsInput) -> InsightTile? {
        InsightsModel.tiles(from: input, locale: locale).first { label($0) == named }
    }

    private func isSparse(_ tile: InsightTile?) -> Bool {
        if case .sparse = tile { return true }
        return false
    }

    // MARK: - the sparse contract

    /// The rule, at its boundary: four rows is a rumour, five is a chart.
    func testSparseAtFourRowsAndRealAtFive() {
        let four = InsightsInput(windowLabel: "last 30 days", total: 4,
                                 outcomes: ["paste": 4],
                                 dailyCounts: [DayCount(day: Date(), count: 4)])
        XCTAssertTrue(isSparse(tile(InsightsModel.utterancesLabel, four)))
        XCTAssertTrue(isSparse(tile(InsightsModel.outcomesLabel, four)))
        if case .sparse(_, let need)? = tile(InsightsModel.utterancesLabel, four) {
            XCTAssertEqual(need, "Needs 5 dictations. You have 4.", "never a zero, always the gap")
        } else {
            XCTFail("expected a sparse tile")
        }

        var five = four
        five.total = 5
        five.outcomes = ["paste": 5]
        guard case .value(_, let value, let sub, _)? = tile(InsightsModel.utterancesLabel, five) else {
            return XCTFail("expected a value tile")
        }
        XCTAssertEqual(value, "5")
        XCTAssertEqual(sub, "last 30 days")
        XCTAssertFalse(isSparse(tile(InsightsModel.outcomesLabel, five)))
    }

    /// `release_to_text_ms` rides only on rows that put text in front of the
    /// user, so nil is a normal answer and it degrades rather than showing 0.
    func testMissingLatencyIsSparseNotZero() {
        var input = InsightsInput(total: 40, outcomes: ["paste": 40])
        XCTAssertTrue(isSparse(tile(InsightsModel.latencyLabel, input)))

        input.releaseP50 = 214
        input.releaseP90 = 391
        guard case .latency(_, let p50, let p90, let reference)? = tile(InsightsModel.latencyLabel, input) else {
            return XCTFail("expected a latency tile")
        }
        XCTAssertEqual(p50, 214)
        XCTAssertEqual(p90, 391)
        XCTAssertEqual(reference, InsightsModel.latencyReferenceMs)
    }

    func testASingleMissingPercentileStillDegrades() {
        let input = InsightsInput(total: 40, releaseP50: 214, releaseP90: nil)
        XCTAssertTrue(isSparse(tile(InsightsModel.latencyLabel, input)),
                      "half a latency tile is not a latency tile")
    }

    // MARK: - the gated tiles

    /// The gated-section rule: no refine pass has ever run on this Mac, so the
    /// tile does not exist. Not empty, not disabled — absent.
    func testAiCleanupTileIsAbsentWhenNoRefineEverRan() {
        let input = InsightsInput(total: 40, aiOutcomes: [:])
        XCTAssertNil(tile(InsightsModel.cleanupLabel, input))

        let ran = InsightsInput(total: 40, aiOutcomes: ["cleaned": 812, "verbatim": 640])
        XCTAssertNotNil(tile(InsightsModel.cleanupLabel, ran))
    }

    func testVocabularyTileIsAbsentUntilATermFires() {
        let unused = InsightsInput(total: 40,
                                   vocabulary: [TermUse(term: "Sharique", hits: 0)],
                                   learnedTermCount: 4)
        XCTAssertNil(tile(InsightsModel.vocabularyLabel, unused))

        let used = InsightsInput(total: 40,
                                 vocabulary: [TermUse(term: "Sharique", hits: 14),
                                              TermUse(term: "InsForge", hits: 6)],
                                 learnedTermCount: 4)
        guard case .ranked(_, _, let rows, let footnote, _)? = tile(InsightsModel.vocabularyLabel, used) else {
            return XCTFail("expected a ranked tile")
        }
        XCTAssertEqual(rows, [LabeledCount("Sharique", 14), LabeledCount("InsForge", 6)])
        XCTAssertEqual(footnote, "4 terms learned by ear")
    }

    /// Nothing to explain, no explanation. A breakdown of zero empties is a
    /// chart of nothing.
    func testEmptiesTileIsAbsentWhenThereAreNoEmpties() {
        let clean = InsightsInput(total: 40, empty: 0)
        XCTAssertNil(tile(InsightsModel.emptiesLabel, clean))
    }

    // MARK: - zero-edit (Phase 5)

    /// The observable-denominator rule on the page: no observation, no tile —
    /// a rate over an empty denominator is not 0%, it is nothing.
    func testZeroEditTileIsAbsentUntilSomethingWasObserved() {
        let unobserved = InsightsInput(total: 40)
        XCTAssertNil(tile(InsightsModel.zeroEditLabel, unobserved))
    }

    func testZeroEditTileDegradesBelowTheMinimumAndNamesTheGap() {
        let three = InsightsInput(total: 40, zeroEditObserved: 3, zeroEditRate: 1.0)
        guard case .sparse(_, let need)? = tile(InsightsModel.zeroEditLabel, three) else {
            return XCTFail("expected a sparse tile")
        }
        XCTAssertEqual(need, "Needs 5 observed dictations. You have 3.")
    }

    /// The `n` is part of the tile, not an option: a zero-edit percentage
    /// without its denominator is how the metric gets quietly inflated.
    func testZeroEditTileCarriesTheRateAndItsDenominator() {
        let input = InsightsInput(total: 40, zeroEditObserved: 8, zeroEditRate: 0.625)
        guard case .value(_, let value, let sub, let spark)? = tile(InsightsModel.zeroEditLabel, input) else {
            return XCTFail("expected a value tile")
        }
        XCTAssertEqual(value, "62.5%")
        XCTAssertEqual(sub, "of 8 observed dictations")
        XCTAssertEqual(spark, [], "no trend data yet — no fake trend line")
    }

    // MARK: - empties

    /// `unclassifiedEmpty` is reported separately and **never merged** —
    /// `MetricsSummary` is explicit about it and the UI honours it.
    func testUnclassifiedEmptiesAreNeverFoldedIntoTheReasons() {
        let input = InsightsInput(
            total: 1842, empty: 95, emptyRate: 0.052,
            emptyReasons: ["short_hold": 41, "silent": 22, "produced_nothing": 14, "starved": 7],
            unclassifiedEmpty: 11, unexplainedEmpty: 6, unexplainedEmptyRate: 0.003)

        guard case .ranked(_, let caption, let rows, let footnote, let alarm)? =
                tile(InsightsModel.emptiesLabel, input) else {
            return XCTFail("expected a ranked tile")
        }
        XCTAssertEqual(rows.map(\.label), ["short_hold", "silent", "produced_nothing", "starved"])
        XCTAssertFalse(rows.contains { $0.label == "unclassified" })
        XCTAssertEqual(rows.reduce(0) { $0 + $1.count }, 84, "the 11 unclassified stay out of the bars")
        XCTAssertEqual(footnote, "unclassified 11 — logged before reasons existed")
        XCTAssertEqual(alarm, "6 unexplained (0.3%) — audible speech, clean finish, no text")
        XCTAssertEqual(caption, "95 · 5.2% of holds")
    }

    func testNoUnclassifiedAndNoUnexplainedMeansNoFootnoteAndNoAlarm() {
        let input = InsightsInput(total: 100, empty: 9, emptyRate: 0.09,
                                  emptyReasons: ["short_hold": 9])
        guard case .ranked(_, _, _, let footnote, let alarm)? = tile(InsightsModel.emptiesLabel, input) else {
            return XCTFail("expected a ranked tile")
        }
        XCTAssertNil(footnote)
        XCTAssertNil(alarm, "the alarm is for a real anomaly, not for a quiet week")
    }

    // MARK: - ranking

    /// Count descending, then key ascending — the same tie-break
    /// `MetricsSummary.ranked` uses, so a tile and a Doctor report never
    /// disagree about the order of two equal outcomes.
    func testRankedOrdersByCountThenKey() {
        let ranked = InsightsModel.ranked(["paste": 508, "type": 96, "im_streaming": 1102,
                                           "beta": 96, "alpha": 96])
        XCTAssertEqual(ranked.map(\.label), ["im_streaming", "paste", "alpha", "beta", "type"])
        XCTAssertEqual(ranked.map(\.count), [1102, 508, 96, 96, 96])
        XCTAssertTrue(InsightsModel.ranked([:]).isEmpty)
    }

    func testOutcomesTileIsAStackedRanking() {
        let input = InsightsInput(total: 1747,
                                  outcomes: ["im_streaming": 1102, "paste": 508, "type": 96, "empty": 41])
        guard case .stacked(_, let segments)? = tile(InsightsModel.outcomesLabel, input) else {
            return XCTFail("expected a stacked tile")
        }
        XCTAssertEqual(segments.map(\.label), ["im_streaming", "paste", "type", "empty"])
    }

    // MARK: - sparkline

    func testSparklineNormalisesAgainstTheBusiestDayAndSurvivesAnEmptyWindow() {
        let days = [DayCount(day: Date(), count: 5), DayCount(day: Date(), count: 10)]
        XCTAssertEqual(InsightsModel.sparkline(days), [0.5, 1.0])
        XCTAssertEqual(InsightsModel.sparkline([DayCount(day: Date(), count: 0)]), [0],
                       "an all-zero window is flat, not a division by zero")
        XCTAssertTrue(InsightsModel.sparkline([]).isEmpty)
    }

    // MARK: - the footer strip

    func testFooterStrip() {
        let input = InsightsInput(windowLabel: "last 30 days", total: 1842,
                                  timedOut: 12, timedOutRate: 0.007,
                                  finalizeP50: 88, finalizeP90: 141)
        XCTAssertEqual(InsightsModel.footer(from: input, locale: locale),
                       "finalize p50 88 ms · p90 141 ms · timed out 12 (0.7%) · last 30 days")
    }

    func testFooterIsAbsentWithoutFinalizeTimings() {
        XCTAssertNil(InsightsModel.footer(from: InsightsInput(total: 40), locale: locale))
    }

    // MARK: - page order

    /// The tiles a fresh install can honestly draw, in page order.
    func testPageOrderAndTheThingsAFreshInstallRefusesToDraw() {
        let fresh = InsightsInput(windowLabel: "last 30 days")
        let labels = InsightsModel.tiles(from: fresh, locale: locale).map(label)
        XCTAssertEqual(labels, [InsightsModel.utterancesLabel,
                                InsightsModel.latencyLabel,
                                InsightsModel.outcomesLabel],
                       "empties, AI cleanup and vocabulary are absent, not empty")
        XCTAssertTrue(InsightsModel.tiles(from: fresh, locale: locale).allSatisfy(isSparse))
    }
}
