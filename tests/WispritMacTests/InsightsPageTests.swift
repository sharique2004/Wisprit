import XCTest
import WispritMacUI
import WispritPersistence
@testable import WispritMac

/// Insights' mapper, layout and read — `docs/design/ui-redesign.md` §3.5.
///
/// `InsightsModel` is already pinned in `WispritMacUITests`; what is asserted
/// here is everything that needs to know what `metrics.log` actually looks
/// like: that a stream spanning three eras maps without inventing anything,
/// that a row which cannot be placed in time is counted but not drawn, and that
/// the read behind the page stats the file before it parses it.
final class InsightsMapperTests: XCTestCase {

    /// UTC, so a day boundary is a fixed number and not the test machine's.
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()

    /// 2026-08-09 12:00 UTC — midday, so "N days ago" never straddles midnight
    /// by accident.
    private var now: Double {
        calendar.date(from: DateComponents(year: 2026, month: 8, day: 9, hour: 12))!
            .timeIntervalSince1970
    }

    private func daysAgo(_ days: Double) -> Double { now - days * 86_400 }

    private func row(_ pairs: (String, SettingValue)...) -> JSONObject {
        JSONObject(pairs)
    }

    /// A row exactly as this build writes it, round-tripped through the real
    /// serializer — the mapper is never fed a shape the writer cannot produce.
    private func written(_ record: MetricsRecord) -> JSONObject {
        guard case .object(let object)? = try? WispritJSON.parse(record.jsonLine()) else {
            XCTFail("MetricsRecord.jsonLine() must parse back")
            return JSONObject()
        }
        return object
    }

    private func spoken(ts: Double, releaseMs: Double, finalizeMs: Double = 100,
                        ai: String? = nil) -> JSONObject {
        written(MetricsRecord(ts: ts, heldMs: 1_800, engine: "apple_live",
                              finalizeMs: finalizeMs, timedOut: false, postMs: 4,
                              insertMs: 9, outcome: "paste", chars: 42,
                              releaseToTextMs: releaseMs, ai: ai))
    }

    private func empty(ts: Double, reason: String?, peak: Double? = nil,
                       heldMs: Double = 400) -> JSONObject {
        written(MetricsRecord(ts: ts, heldMs: heldMs, engine: "apple_live",
                              finalizeMs: 40, timedOut: false, postMs: 0, insertMs: 0,
                              outcome: "empty", chars: 0, emptyReason: reason,
                              peakLevel: peak))
    }

    /// Ten spoken rows and ten empties — one of every empty the stream can
    /// contain, including the two that look identical until you read
    /// `peak_level`.
    private func stream() -> [JSONObject] {
        var rows: [JSONObject] = []
        let releases: [Double] = [180, 190, 200, 210, 220, 230, 240, 250, 260, 400]
        for (index, release) in releases.enumerated() {
            rows.append(spoken(ts: daysAgo(Double(index)), releaseMs: release,
                               ai: index < 6 ? "cleaned" : "verbatim"))
        }
        for index in 0..<4 { rows.append(empty(ts: daysAgo(Double(index)), reason: "short_hold")) }
        for index in 0..<3 { rows.append(empty(ts: daysAgo(Double(index)), reason: "silent")) }
        // Audible speech, a long hold, a clean finish, nothing back: the one
        // number on this page worth alarming on.
        rows.append(empty(ts: daysAgo(1), reason: "produced_nothing", peak: 0.4, heldMs: 2_400))
        // Same reason, but the microphone never heard anything — explained.
        rows.append(empty(ts: daysAgo(2), reason: "produced_nothing", peak: 0.001, heldMs: 2_400))
        // The Python era: an empty with no reason at all.
        rows.append(empty(ts: daysAgo(3), reason: nil))
        return rows
    }

    private func input(_ rows: [JSONObject],
                       choice: MetricsWindowChoice = .days30,
                       dictionary: [DictionaryRow] = []) -> InsightsInput {
        InsightsMapper.input(rows: rows, window: choice.window,
                             dictionary: dictionary, now: now, calendar: calendar)
    }

    private func tile(_ label: String, _ input: InsightsInput) -> InsightTile? {
        InsightsModel.tiles(from: input).first { InsightsLayout.label(of: $0) == label }
    }

    // MARK: - the fields

    func testEveryFieldComesStraightFromTheSummaryInTheUnitsTheModelDeclares() {
        let input = input(stream())

        XCTAssertEqual(input.windowLabel, "last 30 days")
        XCTAssertEqual(input.total, 20)
        XCTAssertEqual(input.outcomes, ["paste": 10, "empty": 10])

        // Rates are fractions, not percentages: ten of twenty is 0.5.
        XCTAssertEqual(input.empty, 10)
        XCTAssertEqual(input.emptyRate, 0.5, accuracy: 1e-9)
        XCTAssertEqual(input.unexplainedEmpty, 1)
        XCTAssertEqual(input.unexplainedEmptyRate, 0.05, accuracy: 1e-9)
        XCTAssertEqual(input.timedOut, 0)
        XCTAssertEqual(input.timedOutRate, 0)

        // Latencies are milliseconds, and the optional pair is present here
        // because every spoken row carried `release_to_text_ms`.
        XCTAssertEqual(input.releaseP50, 220)
        XCTAssertEqual(input.releaseP90, 260)
        XCTAssertEqual(input.finalizeP50, 40)
        XCTAssertEqual(input.finalizeP90, 100)

        XCTAssertEqual(input.aiOutcomes, ["cleaned": 6, "verbatim": 4])
    }

    /// Phase 5: the zero-edit pair rides from `MetricsSummary` unchanged — the
    /// observation lines feed the tile and never the utterance counts.
    func testZeroEditComesFromTheObservationLinesAndNotTheUtteranceCounts() {
        var rows = stream()
        rows.append(written(MetricsRecord(
            ts: daysAgo(1), heldMs: 0, engine: "", finalizeMs: 0, timedOut: false,
            postMs: 0, insertMs: 0, outcome: "edit_observed", chars: 0,
            editDist: 0, editScope: "im")))
        rows.append(written(MetricsRecord(
            ts: daysAgo(2), heldMs: 0, engine: "", finalizeMs: 0, timedOut: false,
            postMs: 0, insertMs: 0, outcome: "edit_observed", chars: 0,
            editDist: 4, editScope: "ax")))

        let mapped = input(rows)
        XCTAssertEqual(mapped.zeroEditObserved, 2)
        XCTAssertEqual(mapped.zeroEditRate, 0.5, accuracy: 1e-9)
        XCTAssertEqual(mapped.total, 20, "observation lines are not utterances")

        let clean = input(stream())
        XCTAssertEqual(clean.zeroEditObserved, 0)
        XCTAssertNil(tile(InsightsModel.zeroEditLabel, clean),
                     "nothing observed, no tile — never a fake 0%")
    }

    /// The rule `MetricsSummary` is explicit about and the page inherits: an
    /// empty logged before reasons existed is its own number, never folded into
    /// a real bucket.
    func testUnclassifiedEmptiesAreCarriedSeparatelyAndNeverMerged() {
        let input = input(stream())

        XCTAssertEqual(input.emptyReasons,
                       ["short_hold": 4, "silent": 3, "produced_nothing": 2])
        XCTAssertEqual(input.unclassifiedEmpty, 1)
        XCTAssertEqual(input.emptyReasons.values.reduce(0, +) + input.unclassifiedEmpty,
                       input.empty)
    }

    /// The empties tile, end to end: a caption, a ranking that excludes the
    /// unclassified row, that row as a footnote, and the alarm underneath.
    func testTheEmptiesTileKeepsTheFootnoteAndTheAlarmApartFromTheRanking() {
        guard case .ranked(_, let caption, let rows, let footnote, let alarm)? =
                tile(InsightsModel.emptiesLabel, input(stream()))
        else { return XCTFail("ten empties is well over the five-row floor") }

        XCTAssertEqual(caption, "10 · 50.0% of holds")
        XCTAssertEqual(rows, [LabeledCount("short_hold", 4),
                              LabeledCount("silent", 3),
                              LabeledCount("produced_nothing", 2)])
        XCTAssertEqual(footnote, "unclassified 1 — logged before reasons existed")
        XCTAssertEqual(alarm, "1 unexplained (5.0%) — audible speech, clean finish, no text")
    }

    // MARK: - Recovery

    private func mappedRecovery(_ rows: [JSONObject],
                                choice: MetricsWindowChoice = .days30) -> InsightsRecovery {
        InsightsMapper.recovery(rows: rows, window: choice.window, now: now)
    }

    private func rescued(ts: Double, engine: String = "apple_batch",
                         rescuedFlag: Bool? = nil) -> JSONObject {
        var object = written(MetricsRecord(ts: ts, heldMs: 1_800, engine: engine,
                                           finalizeMs: 400, timedOut: false, postMs: 4,
                                           insertMs: 9, outcome: "paste", chars: 18,
                                           releaseToTextMs: 420))
        if let rescuedFlag { object[InsightsRecovery.rescuedKey] = .bool(rescuedFlag) }
        return object
    }

    /// `engine == apple_batch` and `rescued: true` both count, and a row that
    /// carries both is still one utterance.
    func testRecoveryCountsRescuedHoldsOnce() {
        let rows = [
            rescued(ts: daysAgo(1)),
            rescued(ts: daysAgo(1), engine: "apple_live", rescuedFlag: true),
            rescued(ts: daysAgo(1), engine: "apple_batch", rescuedFlag: true),
            spoken(ts: daysAgo(1), releaseMs: 200),
        ]
        XCTAssertEqual(mappedRecovery(rows).rescued, 3)
    }

    /// Integer-era `rescued: 1` still counts — the same 0/1 boolean the rest
    /// of the stream already accepts.
    func testRecoveryReadsIntegerEraRescuedFlags() {
        var row = spoken(ts: daysAgo(1), releaseMs: 200)
        row[InsightsRecovery.rescuedKey] = .int(1)
        XCTAssertEqual(mappedRecovery([row]).rescued, 1)
    }

    func testRecoveryEmptyReasonsIncludeDeviceChangedAndNeverFoldUnclassified() {
        let rows = [
            empty(ts: daysAgo(1), reason: InsightsRecovery.deviceChangedReason),
            empty(ts: daysAgo(1), reason: InsightsRecovery.deviceChangedReason),
            empty(ts: daysAgo(1), reason: "silent"),
            empty(ts: daysAgo(1), reason: nil),
        ]
        let recovery = mappedRecovery(rows)

        XCTAssertEqual(recovery.emptyReasons,
                       [InsightsRecovery.deviceChangedReason: 2, "silent": 1])
        XCTAssertEqual(recovery.unclassifiedEmpty, 1)
        XCTAssertEqual(recovery.unclassifiedFootnote,
                       "unclassified 1 — logged before reasons existed")
        XCTAssertFalse(recovery.emptyReasons.keys.contains("unclassified"))
    }

    /// Quiet speech is last 7 days, even when the page window is all-time.
    /// A hold without `peak_level` is an absence, not a quiet hold.
    func testQuietSpeechIsTheLastSevenDaysAndIgnoresMissingPeaks() {
        let rows = [
            empty(ts: daysAgo(1), reason: "silent", peak: 0.05),
            empty(ts: daysAgo(2), reason: "silent", peak: 0.20),
            empty(ts: daysAgo(3), reason: "silent"),            // no peak
            empty(ts: daysAgo(10), reason: "silent", peak: 0.04), // outside 7 days
            spoken(ts: daysAgo(1), releaseMs: 200),
        ]
        // spoken() does not write peak_level, so the 7-day sample is the two
        // empties that carried one: 0.05 (quiet) and 0.20 (not).
        let recovery = mappedRecovery(rows, choice: .all)

        XCTAssertEqual(recovery.quietSpeechSample, 2)
        XCTAssertEqual(recovery.quietSpeech, 1)
        XCTAssertEqual(recovery.quietSpeechShare, 0.5, accuracy: 1e-9)
        XCTAssertTrue(recovery.showsQuietCaption)
        XCTAssertEqual(InsightsRecovery.quietSpeechCaption,
                       "Speak a touch louder or raise input gain for best accuracy")
    }

    func testQuietSpeechCaptionFiresOnlyAboveTwentyPercent() {
        // 1 of 5 is 20% — at the line, not over it.
        let atLine = (0..<5).map { index -> JSONObject in
            empty(ts: daysAgo(1), reason: "silent",
                  peak: index == 0 ? 0.05 : 0.20)
        }
        XCTAssertEqual(mappedRecovery(atLine).quietSpeechShare, 0.20, accuracy: 1e-9)
        XCTAssertFalse(mappedRecovery(atLine).showsQuietCaption)

        let over = atLine + [empty(ts: daysAgo(1), reason: "silent", peak: 0.04)]
        XCTAssertGreaterThan(mappedRecovery(over).quietSpeechShare, 0.20)
        XCTAssertTrue(mappedRecovery(over).showsQuietCaption)
    }

    func testRecoveryDropsNonUtteranceRowsAndHidesWhenThereIsNothingToShow() {
        let observation = written(MetricsRecord(
            ts: daysAgo(1), heldMs: 0, engine: "", finalizeMs: 0, timedOut: false,
            postMs: 0, insertMs: 0, outcome: "edit_observed", chars: 0,
            editDist: 0, editScope: "im"))
        var rescuedObservation = observation
        rescuedObservation[InsightsRecovery.rescuedKey] = .bool(true)
        rescuedObservation["engine"] = .string(InsightsRecovery.appleBatchEngine)

        XCTAssertTrue(mappedRecovery([observation, rescuedObservation]).isEmpty)
        XCTAssertEqual(mappedRecovery([spoken(ts: daysAgo(1), releaseMs: 200)]).rescued, 0)
        XCTAssertTrue(mappedRecovery([]).isEmpty)
    }

    /// Rescued count follows the page window; a 10-day-old rescue is all-time
    /// only.
    func testRecoveryRescuedCountFollowsThePageWindow() {
        let rows = [rescued(ts: daysAgo(1)), rescued(ts: daysAgo(10))]
        XCTAssertEqual(mappedRecovery(rows, choice: .days7).rescued, 1)
        XCTAssertEqual(mappedRecovery(rows, choice: .all).rescued, 2)
    }

    // MARK: - legacy shapes

    /// Python wrote `ts` as a float and `timed_out` as 0/1; a later build wrote
    /// booleans. Both eras are one file and both have to read.
    func testIntegerEraShapesAreReadAsNumbersAndBooleans() {
        let legacy = [
            row(("ts", .int(Int(daysAgo(1)))), ("outcome", .string("paste")),
                ("finalize_ms", .int(120)), ("timed_out", .int(1)), ("chars", .int(9))),
            row(("ts", .double(daysAgo(1))), ("outcome", .string("paste")),
                ("finalize_ms", .double(80)), ("timed_out", .int(0)), ("chars", .int(4))),
        ]
        let input = input(legacy)

        XCTAssertEqual(input.total, 2)
        XCTAssertEqual(input.timedOut, 1)
        XCTAssertEqual(input.timedOutRate, 0.5, accuracy: 1e-9)
        XCTAssertEqual(input.finalizeP50, 80)
        XCTAssertEqual(input.finalizeP90, 120)
        XCTAssertNil(input.releaseP50, "no row of that era put text in front of the user")
        // An integer `ts` still places the row on a day.
        XCTAssertEqual(input.dailyCounts.reduce(0) { $0 + $1.count }, 2)
    }

    /// A row whose `outcome` never reached disk lands in `MetricsSummary` under
    /// the empty string. A blank legend entry is not honest, and dropping the
    /// row would stop the stacked bar summing to the total, so it is named.
    func testARowWithNoOutcomeIsNamedRatherThanBlankOrDropped() {
        let input = input([
            row(("ts", .double(daysAgo(1))), ("finalize_ms", .double(50))),
            row(("ts", .double(daysAgo(1))), ("outcome", .string("paste"))),
        ])

        XCTAssertNil(input.outcomes[""], "a chart segment with no name is not a chart segment")
        XCTAssertEqual(input.outcomes[InsightsMapper.unrecordedOutcome], 1)
        XCTAssertEqual(input.outcomes.values.reduce(0, +), input.total)
    }

    func testAHistogramWithNothingToRenameIsPassedThroughUnchanged() {
        XCTAssertEqual(InsightsMapper.outcomes(["paste": 3, "empty": 1]),
                       ["paste": 3, "empty": 1])
    }

    // MARK: - the window control

    func testTheWindowChoiceDecidesBothTheRowsAndTheLabel() {
        let rows = [spoken(ts: daysAgo(1), releaseMs: 200),
                    spoken(ts: daysAgo(10), releaseMs: 200),
                    spoken(ts: daysAgo(60), releaseMs: 200)]

        XCTAssertEqual(input(rows, choice: .days7).total, 1)
        XCTAssertEqual(input(rows, choice: .days7).windowLabel, "last 7 days")
        XCTAssertEqual(input(rows, choice: .days30).total, 2)
        XCTAssertEqual(input(rows, choice: .days30).windowLabel, "last 30 days")
        XCTAssertEqual(input(rows, choice: .all).total, 3)
        XCTAssertEqual(input(rows, choice: .all).windowLabel, "all time")
    }

    func testTheThreeChoicesAreTheThreeTheSpecNames() {
        XCTAssertEqual(MetricsWindowChoice.allCases.map(\.title),
                       ["7 days", "30 days", "All time"])
        XCTAssertEqual(MetricsWindowChoice.days7.window, MetricsWindow(days: 7))
        XCTAssertEqual(MetricsWindowChoice.days30.window, MetricsWindow(days: 30))
        XCTAssertEqual(MetricsWindowChoice.all.window, .all)
    }

    // MARK: - the sparkline

    /// Silent days are drawn, not closed up: a gap is a day the user did not
    /// dictate, and squeezing it out draws a busier week than there was.
    func testTheSparklineHasOneBucketPerDayIncludingTheSilentOnes() {
        let rows = [spoken(ts: daysAgo(0), releaseMs: 200),
                    spoken(ts: daysAgo(0), releaseMs: 200),
                    spoken(ts: daysAgo(3), releaseMs: 200)]
        let days = input(rows, choice: .days7).dailyCounts

        // The seven-day cutoff lands at midday, so the eighth (partial) day is
        // a day the window can contain — it is drawn, not dropped.
        XCTAssertEqual(days.count, 8)
        XCTAssertEqual(days.map(\.count), [0, 0, 0, 0, 1, 0, 0, 2])
        XCTAssertEqual(days.map(\.day), days.map(\.day).sorted(), "oldest first")
        XCTAssertEqual(days.last?.day,
                       calendar.startOfDay(for: Date(timeIntervalSince1970: now)))
        XCTAssertEqual(InsightsModel.sparkline(days), [0, 0, 0, 0, 0.5, 0, 0, 1])
    }

    /// A row with no usable `ts` cannot be placed on a day. It still counts —
    /// the total is the total — but it is not drawn on a day it may not belong
    /// to.
    func testARowWithNoTimestampIsCountedButNeverPlacedOnADay() {
        let rows = [spoken(ts: daysAgo(1), releaseMs: 200),
                    row(("outcome", .string("paste")), ("chars", .int(12)))]
        let input = input(rows, choice: .all)

        XCTAssertEqual(input.total, 2)
        XCTAssertEqual(input.dailyCounts.reduce(0) { $0 + $1.count }, 1)
    }

    func testAnAllTimeSparklineIsCappedAtNinetyBucketsEndingToday() {
        let rows = [spoken(ts: daysAgo(400), releaseMs: 200),
                    spoken(ts: daysAgo(1), releaseMs: 200)]
        let input = input(rows, choice: .all)

        XCTAssertEqual(input.dailyCounts.count, InsightsMapper.maxSparklineDays)
        XCTAssertEqual(input.dailyCounts.last?.day,
                       calendar.startOfDay(for: Date(timeIntervalSince1970: now)))
        XCTAssertEqual(input.dailyCounts.reduce(0) { $0 + $1.count }, 1,
                       "the 400-day-old row falls off the shape, not out of the total")
        XCTAssertEqual(input.total, 2)
    }

    func testAStreamWithNoUsableTimesDrawsNoSparklineAtAll() {
        let rows = [row(("outcome", .string("paste"))), row(("outcome", .string("empty")))]
        XCTAssertEqual(input(rows, choice: .all).dailyCounts, [])
    }

    // MARK: - the vocabulary tile

    func testVocabularyComesFromTheDictionaryAndOnlyListsTermsThatFired() {
        let dictionary = [
            DictionaryRow(term: "Sharique", source: "spoken_spelling", hitCount: 14),
            DictionaryRow(term: "InsForge", source: "manual", hitCount: 6),
            DictionaryRow(term: "Unspoken", source: "manual", hitCount: 0),
            DictionaryRow(term: "Ghost", source: "spoken_spelling", hitCount: 0),
        ]
        let input = input(stream(), dictionary: dictionary)

        XCTAssertEqual(input.vocabulary, [TermUse(term: "Sharique", hits: 14),
                                          TermUse(term: "InsForge", hits: 6)])
        // Learned-by-ear counts what Wisprit taught itself, whether or not the
        // term has fired yet — it is a fact about the dictionary.
        XCTAssertEqual(input.learnedTermCount, 2)

        guard case .ranked(_, _, let rows, let footnote, _)? =
                tile(InsightsModel.vocabularyLabel, input)
        else { return XCTFail("a fired term draws the vocabulary tile") }
        XCTAssertEqual(rows, [LabeledCount("Sharique", 14), LabeledCount("InsForge", 6)])
        XCTAssertEqual(footnote, "2 terms learned by ear")
    }

    func testADictionaryNoTermHasFiredDrawsNoVocabularyTile() {
        let input = input(stream(), dictionary: [DictionaryRow(term: "Unspoken", hitCount: 0)])
        XCTAssertTrue(input.vocabulary.isEmpty)
        XCTAssertNil(tile(InsightsModel.vocabularyLabel, input))
    }

    // MARK: - what a fresh install draws

    /// The whole page over an empty file: three placeholders that say what they
    /// need, and no tile at all for data this Mac has never produced.
    func testAnEmptyStreamDegradesToPlaceholdersRatherThanZeros() {
        let fresh = input([])
        let tiles = InsightsModel.tiles(from: fresh)

        XCTAssertEqual(tiles.map { InsightsLayout.label(of: $0) },
                       [InsightsModel.utterancesLabel,
                        InsightsModel.latencyLabel,
                        InsightsModel.outcomesLabel])
        for tile in tiles {
            guard case .sparse(_, let need) = tile else {
                return XCTFail("\(InsightsLayout.label(of: tile)) must degrade, not show a zero")
            }
            XCTAssertEqual(need, "Needs 5 dictations. You have 0.")
        }
        XCTAssertNil(InsightsModel.footer(from: fresh))
    }

    /// The gated-section rule, end to end: no row carries `ai`, so no cleanup
    /// tile exists.
    func testAStreamWhereRefineNeverRanHasNoCleanupTile() {
        let rows = (0..<6).map { spoken(ts: daysAgo(Double($0)), releaseMs: 200) }
        let input = input(rows)

        XCTAssertTrue(input.aiOutcomes.isEmpty)
        XCTAssertNil(tile(InsightsModel.cleanupLabel, input))
    }

    func testTheFooterStripQuotesTheFinalizeTimingsAndTheWindow() {
        XCTAssertEqual(InsightsModel.footer(from: input(stream())),
                       "finalize p50 40 ms · p90 100 ms · last 30 days")
    }

    // MARK: - the grid

    func testTheTwoWideTilesOwnTheirRowAndTheRestPairUp() {
        let tiles: [InsightTile] = [
            .sparse(label: InsightsModel.utterancesLabel, need: "x"),
            .sparse(label: InsightsModel.latencyLabel, need: "x"),
            .sparse(label: InsightsModel.outcomesLabel, need: "x"),
            .sparse(label: InsightsModel.emptiesLabel, need: "x"),
            .sparse(label: InsightsModel.cleanupLabel, need: "x"),
            .sparse(label: InsightsModel.vocabularyLabel, need: "x"),
        ]
        let rows = InsightsLayout.rows(tiles).map { $0.map(InsightsLayout.label(of:)) }

        XCTAssertEqual(rows, [[InsightsModel.utterancesLabel, InsightsModel.latencyLabel],
                              [InsightsModel.outcomesLabel],
                              [InsightsModel.emptiesLabel],
                              [InsightsModel.cleanupLabel, InsightsModel.vocabularyLabel]])
    }

    /// A tile that degraded to a placeholder still spans the grid: the layout
    /// must not reflow just because the data thinned out.
    func testASparsePlaceholderKeepsTheColumnSpanOfTheTileItReplaced() {
        let rows = InsightsLayout.rows(InsightsModel.tiles(from: input([])))
        XCTAssertEqual(rows.map(\.count), [2, 1])
        XCTAssertFalse(InsightsLayout.isWide(rows[0][0]))
        XCTAssertTrue(InsightsLayout.isWide(rows[1][0]))
    }

    /// The placeholder is the chart's height, so a tile that degrades leaves
    /// the grid where it was.
    func testEveryTileNamesAChartHeightForItsPlaceholder() {
        for label in [InsightsModel.utterancesLabel, InsightsModel.latencyLabel,
                      InsightsModel.outcomesLabel, InsightsModel.emptiesLabel,
                      InsightsModel.cleanupLabel, InsightsModel.vocabularyLabel] {
            XCTAssertGreaterThan(InsightsMetrics.chartHeight(for: label), 0, label)
        }
        // §1.4: machine vocabulary is mono; dictionary terms are words a human
        // chose and are not.
        XCTAssertTrue(InsightsMetrics.isMachineVocabulary(InsightsModel.emptiesLabel))
        XCTAssertFalse(InsightsMetrics.isMachineVocabulary(InsightsModel.vocabularyLabel))
    }
}

// MARK: - the read

/// A counter the detached read can touch from off the main actor.
private final class Reads: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func bump() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

private final class Stamp: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date?
    init(_ value: Date?) { self.value = value }
    var date: Date? {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}

/// The page's own read of `metrics.log` — §3.5's threading paragraph.
@MainActor
final class InsightsPageModelTests: XCTestCase {

    private func rows(_ count: Int) -> [JSONObject] {
        (0..<count).map { index in
            JSONObject([("ts", .double(1_786_000_000 - Double(index) * 3_600)),
                        ("outcome", .string("paste")),
                        ("finalize_ms", .double(60)),
                        ("release_to_text_ms", .double(200))])
        }
    }

    private func model(reads: Reads, stamp: Stamp, rows: [JSONObject]) -> InsightsPageModel {
        InsightsPageModel(ports: .init(modificationDate: { stamp.date },
                                       readAll: { reads.bump(); return rows },
                                       now: { 1_786_000_000 },
                                       calendar: { .current }))
    }

    func testNothingIsShownUntilTheFirstReadLands() async {
        let reads = Reads(), stamp = Stamp(Date())
        let model = model(reads: reads, stamp: stamp, rows: rows(6))

        XCTAssertNil(model.input, "a page of unverified zeros is worse than an empty page")
        XCTAssertEqual(model.choice, .days30, "§3.5: the default window is 30 days")

        await model.refreshIfNeeded()
        XCTAssertEqual(model.input?.total, 6)
        XCTAssertEqual(reads.count, 1)
    }

    /// `readAll()` parses the whole file, so a poll that finds the same
    /// modification date must not touch it.
    func testAnUnchangedFileIsNeverParsedTwice() async {
        let reads = Reads(), stamp = Stamp(Date())
        let model = model(reads: reads, stamp: stamp, rows: rows(6))

        await model.refreshIfNeeded()
        await model.refreshIfNeeded()
        await model.refreshIfNeeded()
        XCTAssertEqual(reads.count, 1)

        stamp.date = Date().addingTimeInterval(60)
        await model.refreshIfNeeded()
        XCTAssertEqual(reads.count, 2, "a moved stamp is new bytes")
    }

    /// A missing file is a stable state, not a reason to re-read every two
    /// seconds — and it stops being one the moment the first utterance lands.
    func testAMissingFileSettlesAndThenNoticesItAppear() async {
        let reads = Reads(), stamp = Stamp(nil)
        let model = model(reads: reads, stamp: stamp, rows: rows(6))

        await model.refreshIfNeeded()
        await model.refreshIfNeeded()
        XCTAssertEqual(reads.count, 1)

        stamp.date = Date()
        await model.refreshIfNeeded()
        XCTAssertEqual(reads.count, 2)
    }

    func testForcingARereadIgnoresTheStamp() async {
        let reads = Reads(), stamp = Stamp(Date())
        let model = model(reads: reads, stamp: stamp, rows: rows(6))

        await model.refreshIfNeeded()
        await model.refreshIfNeeded(force: true)
        XCTAssertEqual(reads.count, 2)
    }

    /// Changing the segmented control re-summarizes what is already in memory.
    /// Re-parsing the file to answer "what about the last 7 days" would be a
    /// disk read per click.
    func testChangingTheWindowRecomputesWithoutRereadingTheFile() async {
        let reads = Reads(), stamp = Stamp(Date())
        let model = model(reads: reads, stamp: stamp, rows: rows(6))

        await model.refreshIfNeeded()
        XCTAssertEqual(model.input?.windowLabel, "last 30 days")

        model.choice = .all
        XCTAssertEqual(model.input?.windowLabel, "all time")
        XCTAssertEqual(model.input?.total, 6)
        XCTAssertEqual(reads.count, 1)
    }

    /// The vocabulary tile is fed by the dictionary the window already holds —
    /// the page never opens `dictionary.json` itself.
    func testTheDictionaryRidesInFromTheWindowModel() async {
        let reads = Reads(), stamp = Stamp(Date())
        let model = model(reads: reads, stamp: stamp, rows: rows(6))

        await model.refreshIfNeeded(dictionary: [DictionaryRow(term: "InsForge", hitCount: 3)])
        XCTAssertEqual(model.input?.vocabulary, [TermUse(term: "InsForge", hits: 3)])

        await model.refreshIfNeeded(dictionary: [DictionaryRow(term: "InsForge", hitCount: 4)])
        XCTAssertEqual(model.input?.vocabulary, [TermUse(term: "InsForge", hits: 4)])
        XCTAssertEqual(reads.count, 1, "a dictionary edit is not a metrics change")
    }

    /// Recovery is computed from the rows already in memory, on the same
    /// recompute as the tiles — never a second parse.
    func testRecoveryIsComputedFromTheSameReadAsTheTiles() async {
        var rescued = JSONObject([("ts", .double(1_786_000_000)),
                                  ("outcome", .string("paste")),
                                  ("engine", .string(InsightsRecovery.appleBatchEngine)),
                                  ("finalize_ms", .double(60)),
                                  ("release_to_text_ms", .double(200))])
        rescued[InsightsRecovery.rescuedKey] = .bool(true)
        let empty = JSONObject([("ts", .double(1_786_000_000)),
                                ("outcome", .string("empty")),
                                ("empty_reason", .string(InsightsRecovery.deviceChangedReason)),
                                ("peak_level", .double(0.05))])
        let reads = Reads(), stamp = Stamp(Date())
        let model = InsightsPageModel(ports: .init(modificationDate: { stamp.date },
                                                   readAll: { reads.bump(); return [rescued, empty] },
                                                   now: { 1_786_000_000 },
                                                   calendar: { .current }))

        XCTAssertNil(model.recovery)
        await model.refreshIfNeeded()
        XCTAssertEqual(model.recovery?.rescued, 1)
        XCTAssertEqual(model.recovery?.emptyReasons[InsightsRecovery.deviceChangedReason], 1)
        XCTAssertEqual(model.recovery?.quietSpeech, 1)
        XCTAssertEqual(reads.count, 1)

        model.choice = .days7
        XCTAssertEqual(model.recovery?.rescued, 1)
        XCTAssertEqual(reads.count, 1, "a window change is not a metrics change")
    }
}
