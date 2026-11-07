import XCTest
@testable import WispritMacUI

/// Insights' pure logic: plain-language labels, the headlines, and the
/// technical details.
///
/// No disk and no SQLite: `InsightsInput` is the neutral seam, so every rule
/// about what a headline says — and refuses to say — is assertable as a value
/// transformation.
final class InsightsModelTests: XCTestCase {

    private let locale = Locale(identifier: "en_US_POSIX")

    /// The 2026-11-07 30-day window on the owner's Mac, as the audit read it:
    /// 34 holds, 9 became text, 25 empties of which 7 were the AirPods stall
    /// (all before the capture update) and none was Wisprit's fault.
    private func lastThirtyDays() -> InsightsInput {
        InsightsInput(windowLabel: "last 30 days", total: 34,
                      outcomes: ["empty": 25, "im_streaming": 7, "paste": 2],
                      empty: 25, emptyRate: 25.0 / 34,
                      emptyReasons: ["silent": 12, "starved": 7, "short_hold": 5, "produced_nothing": 1],
                      releaseP50: 200.4, releaseP90: 617,
                      aiOutcomes: ["empty": 25, "skipped_verbatim_app": 9],
                      captureBackends: ["hal": 3, "engine": 1],
                      starvedSinceCaptureUpdate: 0)
    }

    private func headline(_ kind: InsightHeadline.Kind, _ input: InsightsInput,
                          activity: InsightsActivity? = nil) -> InsightHeadline? {
        InsightsModel.headlines(from: input, activity: activity, locale: locale)
            .first { $0.kind == kind }
    }

    // MARK: - labels

    /// The spec's own examples, verbatim.
    func testTheEngineVocabularyIsTranslated() {
        XCTAssertEqual(InsightsLabels.outcome("im_streaming"), "Typed live")
        XCTAssertEqual(InsightsLabels.outcome("paste"), "Pasted")
        XCTAssertEqual(InsightsLabels.outcome("type"), "Typed")
        XCTAssertEqual(InsightsLabels.outcome("empty"), "Nothing inserted")
        XCTAssertEqual(InsightsLabels.emptyReason("silent"), "Nothing heard")
        XCTAssertEqual(InsightsLabels.emptyReason("starved"), "Mic sent no audio")
        XCTAssertEqual(InsightsLabels.emptyReason("short_hold"), "Key released too soon")
        XCTAssertEqual(InsightsLabels.emptyReason("produced_nothing"), "Heard sound, no words")
        XCTAssertEqual(InsightsLabels.cleanup("skipped_verbatim_app"), "Cleanup skipped for this app")
    }

    func testNoLabelInAnyTableLeaksMachineSpelling() {
        let tables = [InsightsLabels.outcomeLabels, InsightsLabels.emptyReasonLabels,
                      InsightsLabels.cleanupLabels, InsightsLabels.captureBackendLabels]
        for table in tables {
            for (key, label) in table {
                XCTAssertFalse(label.contains("_"), "\(key) → \(label)")
                XCTAssertNotEqual(label, key, "\(key) is not translated")
                XCTAssertEqual(label.first.map { String($0) }, label.first.map { String($0).uppercased() },
                               "\(label) is sentence case")
            }
        }
    }

    /// A value from a build that does not exist yet still reads as words.
    func testAnUnknownValueFallsBackToWordsNotTheToken() {
        XCTAssertEqual(InsightsLabels.outcome("im_future_rung"), "Im future rung")
        XCTAssertEqual(InsightsLabels.emptyReason("mic-was-asleep"), "Mic was asleep")
        XCTAssertEqual(InsightsLabels.cleanup("NEW_THING"), "New thing")
        XCTAssertEqual(InsightsLabels.fallback(""), "Other")
        XCTAssertEqual(InsightsLabels.fallback("___"), "Other")
    }

    // MARK: - the sparse contract

    func testTimingAndHoldsWaitForFiveDictations() {
        let four = InsightsInput(windowLabel: "last 30 days", total: 4, outcomes: ["paste": 4],
                                 releaseP50: 200, releaseP90: 300)
        for kind in [InsightHeadline.Kind.speed, .holds] {
            guard case .placeholder(let need)? = headline(kind, four)?.chart else {
                return XCTFail("\(kind) must degrade below five rows")
            }
            XCTAssertEqual(need, "Needs 5 dictations. You have 4.", "never a zero, always the gap")
        }

        var five = four
        five.total = 5
        five.outcomes = ["paste": 5]
        guard case .latency(let p50, let p90, let reference)? = headline(.speed, five)?.chart else {
            return XCTFail("five rows draw the latency chart")
        }
        XCTAssertEqual([p50, p90, reference], [200, 300, 400])
    }

    /// `release_to_text_ms` rides only on rows that put text in front of the
    /// user, so nil is a normal answer and the headline degrades.
    func testMissingLatencyIsAPlaceholderNotAZero() {
        let input = InsightsInput(total: 12, outcomes: ["empty": 12], empty: 12)
        guard case .placeholder? = headline(.speed, input)?.chart else {
            return XCTFail("no release timing, no speed headline figure")
        }
    }

    // MARK: - speed

    func testSpeedSaysSecondsAndTheNinetiethPercentile() {
        let speed = headline(.speed, lastThirtyDays())
        XCTAssertEqual(speed?.text, "Text lands 0.20 seconds after you let go.")
        XCTAssertEqual(speed?.scope, "Last 30 days")
        XCTAssertEqual(speed?.detail,
                       "9 in 10 land within 0.62 s. The dashed line, 0.40 s, is where a wait starts to show.")
        XCTAssertEqual(speed?.advice, [], "fast is not a problem to solve")
        XCTAssertEqual(speed?.sentence.filter(\.isFigure).map(\.text), ["0.20"])
    }

    func testSlowTextWithCleanupOnPointsAtTheSetting() {
        var input = lastThirtyDays()
        input.releaseP50 = 700
        input.releaseP90 = 1_206
        input.aiOutcomes = ["applied": 359]
        let speed = headline(.speed, input)
        XCTAssertEqual(speed?.text, "Text lands 0.70 seconds after you let go.")
        XCTAssertEqual(speed?.advice.count, 1)
        XCTAssertTrue(speed?.advice.first?.contains("Settings") ?? false)
    }

    // MARK: - holds

    func testHoldSegmentsSumToTheTotalAndNameTheFaultSeparately() {
        let input = InsightsInput(
            total: 20,
            outcomes: ["paste": 8, "type": 1, "correction": 1, "blocked_secure": 1, "error": 1,
                       "empty": 7, "unrecorded": 1],
            empty: 7,
            emptyReasons: ["short_hold": 1, "silent": 1, "device_changed": 1,
                           "produced_nothing": 2, "crashed": 1],
            unclassifiedEmpty: 1, unexplainedEmpty: 1)
        let segments = InsightsModel.holdSegments(input)

        XCTAssertEqual(segments.reduce(0) { $0 + $1.count }, input.total)
        XCTAssertEqual(segments, [HoldSegment(.delivered, 9),
                                  HoldSegment(.correction, 1),
                                  HoldSegment(.quiet, 2),
                                  HoldSegment(.mic, 1),
                                  HoldSegment(.noWords, 1),
                                  HoldSegment(.unknown, 2),
                                  HoldSegment(.blocked, 1),
                                  // crashed + the one unexplained empty + the insert error
                                  HoldSegment(.fault, 3)])
        XCTAssertEqual(segments.filter(\.group.isFault).map(\.group), [.fault],
                       "critical is for one group only")
    }

    /// The headline the audit asked for, on the data the audit read.
    func testTheThirtyDayHeadlineIsNumbersAndAdvice() {
        guard let holds = headline(.holds, lastThirtyDays()) else { return XCTFail("holds headline") }
        XCTAssertEqual(holds.text, "9 of your last 34 holds became text.")
        XCTAssertEqual(holds.detail,
                       "25 caught nothing: 17 were quick taps or silence, 7 got no audio from "
                       + "the mic and 1 heard sound but no words.")
        XCTAssertEqual(holds.advice, [
            "If you were speaking, check that the mic named in the toolbar is the one you talk into.",
            "The no-audio holds all came before Wisprit's new mic capture — none since.",
        ])
        XCTAssertEqual(holds.tone, .neutral, "taps, silence and a fixed stall are not alarms")
        guard case .holds(let segments) = holds.chart else { return XCTFail("holds chart") }
        XCTAssertFalse(segments.contains { $0.group.isFault })
    }

    func testAFaultLeadsTheSentenceAndTheAdviceAndSetsTheTone() {
        var input = lastThirtyDays()
        input.emptyReasons["produced_nothing"] = 3
        input.outcomes["empty"] = 27
        input.empty = 27
        input.total = 36
        input.unexplainedEmpty = 2
        guard let holds = headline(.holds, input) else { return XCTFail("holds headline") }

        XCTAssertEqual(holds.tone, .fault)
        XCTAssertTrue(holds.detail?.hasPrefix("27 caught nothing: 2 were missed by Wisprit,") ?? false,
                      holds.detail ?? "nil")
        XCTAssertTrue(holds.advice.first?.contains("Copy diagnostics") ?? false)
        XCTAssertLessThanOrEqual(holds.advice.count, InsightsModel.adviceLimit)
    }

    func testQuickTapsGetTheHoldLongerAdvice() {
        let input = InsightsInput(total: 10, outcomes: ["paste": 6, "empty": 4], empty: 4,
                                  emptyReasons: ["short_hold": 3, "silent": 1])
        XCTAssertEqual(headline(.holds, input)?.advice,
                       ["Hold the key for the whole sentence — very short taps are ignored on purpose."])
    }

    func testANoAudioHoldOnTheCurrentCapturePathGetsTheHeadsetAdvice() {
        let input = InsightsInput(total: 10, outcomes: ["paste": 8, "empty": 2], empty: 2,
                                  emptyReasons: ["starved": 2],
                                  captureBackends: ["hal": 10], starvedSinceCaptureUpdate: 1)
        XCTAssertEqual(headline(.holds, input)?.advice.first,
                       "With AirPods or another Bluetooth headset, wait a moment after pressing "
                       + "the key before you speak.")
    }

    func testEveryHoldDeliveredSaysSoAndAdvisesNothing() {
        let input = InsightsInput(total: 6, outcomes: ["paste": 4, "im_streaming": 2])
        let holds = headline(.holds, input)
        XCTAssertEqual(holds?.text, "Every one of your last 6 holds became text.")
        XCTAssertNil(holds?.detail)
        XCTAssertEqual(holds?.advice, [])
    }

    // MARK: - dictionary

    func testDictionaryHeadlineCountsFixesAndListsTheBusiestTerms() {
        let input = InsightsInput(
            vocabulary: [TermUse(term: "Sharique", hits: 32), TermUse(term: "hackathon", hits: 14),
                         TermUse(term: "Claude", hits: 9), TermUse(term: "MCP", hits: 7),
                         TermUse(term: "WellX", hits: 7), TermUse(term: "Qwen", hits: 0),
                         TermUse(term: "Letta", hits: 1)],
            learnedTermCount: 2, dictionaryTermCount: 139)
        let dictionary = headline(.dictionary, input)
        XCTAssertEqual(dictionary?.text, "Your dictionary has fixed 70 words so far.")
        XCTAssertEqual(dictionary?.detail,
                       "The fixes came from 6 of your 139 terms. Wisprit learned 2 terms from "
                       + "your spelled-out corrections.")
        XCTAssertEqual(dictionary?.chart, .terms([LabeledCount("Sharique", 32), LabeledCount("hackathon", 14),
                                                  LabeledCount("Claude", 9), LabeledCount("MCP", 7),
                                                  LabeledCount("WellX", 7)]))
    }

    func testAnEmptyDictionaryAndAnUnusedOneAreDifferentSentences() {
        XCTAssertEqual(headline(.dictionary, InsightsInput())?.text, "Your dictionary is empty.")
        XCTAssertEqual(headline(.dictionary, InsightsInput())?.advice.count, 1)
        XCTAssertEqual(headline(.dictionary, InsightsInput(dictionaryTermCount: 3))?.text,
                       "None of your 3 dictionary terms have been needed yet.")
        XCTAssertEqual(headline(.dictionary, InsightsInput(dictionaryTermCount: 1))?.text,
                       "Your one dictionary term hasn't been needed yet.")
    }

    // MARK: - pace and activity

    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.firstWeekday = 1
        return calendar
    }()

    /// Saturday 2026-11-07, midday UTC.
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: 7, hour: 12))!
    }

    private func activity(rates: [Double] = [], median: Double? = 123,
                          weeks: [[Int]] = Array(repeating: Array(repeating: 0, count: 7), count: 18),
                          streak: Int = 0) -> InsightsActivity {
        InsightsActivity(weeks: weeks,
                         gridStart: StreakCalendar.gridStart(weeks: weeks.count, now: now, calendar: calendar)!,
                         today: StreakCalendar.today(weeks: weeks.count, now: now, calendar: calendar),
                         streakDays: streak, medianWPM: median, rates: rates, calendar: calendar)
    }

    func testPaceIsAbsentWithoutARateAndChartsOnlyWithEnoughDots() {
        XCTAssertNil(InsightsModel.pace(activity(median: nil)))

        let few = InsightsModel.pace(activity(rates: [120, 130], median: 125))
        XCTAssertEqual(few?.text, "You speak at 125 words per minute.")
        XCTAssertEqual(few?.chart, HeadlineChart.none)
        XCTAssertNil(few?.detail)

        let rates: [Double] = [90, 100, 110, 120, 130, 140, 150, 160]
        let many = InsightsModel.pace(activity(rates: rates, median: 125))
        XCTAssertEqual(many?.scope, "Last 8 dictations")
        XCTAssertEqual(many?.detail, "Half of them fall between 100 and 140 words per minute.")
        XCTAssertEqual(many?.chart, .rates(samples: rates, median: 125))
    }

    func testActivityCountsDaysUpToTodayAndNamesTheBusiestDay() {
        var weeks = Array(repeating: Array(repeating: 0, count: 7), count: 18)
        weeks[0][0] = 3           // Sunday 2026-07-05
        weeks[5][2] = 53          // Tuesday 2026-08-11
        weeks[17][6] = 4          // today, Saturday 2026-11-07
        let grid = activity(weeks: weeks, streak: 1)

        XCTAssertEqual(grid.elapsedDays, 126, "a Saturday 'today' fills the last column")
        XCTAssertEqual(grid.activeDays, 3)
        let headline = InsightsModel.activity(grid, locale: locale)
        XCTAssertEqual(headline.text, "You dictated on 3 of the last 126 days.")
        XCTAssertEqual(headline.detail, "1-day streak. Busiest day: 53 dictations on Tue, Aug 11.")
        XCTAssertEqual(headline.scope, "Last 18 weeks")
    }

    func testTheRateSampleIsHomeModelsSoTheDotsAndTheMedianAgree() {
        let items = (0..<40).map { index in
            TranscriptItem(id: Int64(index), ts: Double(1_000 + index),
                           text: Array(repeating: "word", count: 10 + index % 7).joined(separator: " "),
                           engine: "apple_live", durationMs: 5_000)
        }
        let stats = HomeModel.stats(items, now: now, calendar: calendar)
        let made = InsightsActivity.make(stats: stats, items: items, now: now, calendar: calendar)

        XCTAssertEqual(made?.rates.count, HomeModel.defaultRateSample)
        XCTAssertEqual(made?.medianWPM, HomeModel.medianWPM(items))

        let fallback = InsightsActivity.make(stats: stats, items: [], now: now, calendar: calendar)
        XCTAssertEqual(fallback?.rates, [])
        XCTAssertEqual(fallback?.medianWPM, stats.medianWPM, "no page loaded: the rail's median stands")
    }

    func testHeadlineOrder() {
        let kinds = InsightsModel.headlines(from: lastThirtyDays(), activity: activity(), locale: locale)
            .map(\.kind)
        XCTAssertEqual(kinds, [.speed, .holds, .dictionary, .pace, .activity])
        XCTAssertEqual(InsightsModel.headlines(from: lastThirtyDays(), activity: nil, locale: locale)
                        .map(\.kind),
                       [.speed, .holds, .dictionary], "history not read yet: no pace, no grid")
    }

    // MARK: - technical details

    private func everything() -> InsightsInput {
        InsightsInput(windowLabel: "all time", total: 30,
                      outcomes: ["paste": 10, "im_streaming": 5, "im_commit": 1, "type": 2,
                                 "blocked_secure": 1, "error": 1, "correction": 1, "empty": 8,
                                 "unrecorded": 1],
                      empty: 8, emptyRate: 8.0 / 30,
                      emptyReasons: ["silent": 1, "starved": 1, "short_hold": 1, "produced_nothing": 1,
                                     "timed_out": 1, "crashed": 1, "device_changed": 1],
                      unclassifiedEmpty: 1, unexplainedEmpty: 1, unexplainedEmptyRate: 1.0 / 30,
                      timedOut: 1, timedOutRate: 1.0 / 30,
                      finalizeP50: 58, finalizeP90: 176, releaseP50: 200, releaseP90: 617,
                      aiOutcomes: Dictionary(uniqueKeysWithValues:
                        InsightsLabels.cleanupLabels.keys.map { ($0, 1) }),
                      dailyCounts: [DayCount(day: Date(timeIntervalSince1970: 0), count: 1),
                                    DayCount(day: Date(timeIntervalSince1970: 86_400), count: 3)],
                      zeroEditObserved: 8, zeroEditRate: 0.75,
                      captureBackends: ["hal": 3, "engine": 1],
                      firstChunkP50: 149, firstChunkP90: 175)
    }

    func testTheTechnicalDetailsCarryEveryNumberInPlainWords() {
        let sections = InsightsModel.details(
            from: everything(),
            recovery: InsightsRecovery(rescued: 3, quietSpeech: 3, quietSpeechSample: 4),
            locale: locale)

        XCTAssertEqual(sections.map(\.title),
                       ["Timing", "What happened to each hold", "Why holds caught nothing",
                        "AI cleanup", "Recovery", "Mic capture", "Edits"])
        for section in sections {
            for row in section.rows {
                XCTAssertFalse(row.label.contains("_"), "\(section.title): \(row.label)")
            }
        }
        let timing = sections[0]
        XCTAssertEqual(timing.columns, ["Median", "9 in 10 within"])
        XCTAssertEqual(timing.rows.map(\.label), ["Key press to first audio", "Speech engine finishing",
                                                  "Key release to text", "Finishing took too long"])
        XCTAssertEqual(timing.rows[2].value, "200 ms")
        XCTAssertEqual(timing.rows[2].secondary, "617 ms")
        XCTAssertTrue(timing.rows[3].isFault, "a timeout is a genuine fault")

        let empties = sections[2]
        XCTAssertEqual(empties.notes, ["1 older hold was logged before Wisprit recorded a reason."])
        XCTAssertEqual(empties.alarm,
                       "1 hold (3.3%) had clear speech and a clean finish but still produced no text.")
        XCTAssertEqual(empties.rows.filter(\.isFault).map(\.label).sorted(),
                       ["Recognition took too long", "Speech engine stopped"])

        XCTAssertEqual(sections[1].spark, [1.0 / 3, 1])
        XCTAssertEqual(sections[4].notes, [InsightsRecovery.quietSpeechCaption + "."])
        XCTAssertEqual(sections[6].rows.first?.value, "75.0% of 8 checked dictations")
    }

    /// The rule `MetricsSummary` is explicit about: empties logged before
    /// reasons existed are their own line, never a reason row.
    func testUnclassifiedEmptiesAreNeverFoldedIntoTheReasons() {
        let input = InsightsInput(total: 10, outcomes: ["empty": 10], empty: 10,
                                  emptyReasons: ["silent": 6], unclassifiedEmpty: 4)
        let empties = InsightsModel.details(from: input, recovery: nil, locale: locale)
            .first { $0.title == "Why holds caught nothing" }
        XCTAssertEqual(empties?.rows.map(\.label), ["Nothing heard"])
        XCTAssertEqual(empties?.notes, ["4 older holds were logged before Wisprit recorded a reason."])
        XCTAssertNil(empties?.alarm)
    }

    func testAFreshInstallHasNoDetailsAndZeroEditWaitsForItsFloor() {
        XCTAssertEqual(InsightsModel.details(from: InsightsInput(), recovery: nil, locale: locale), [])
        let sparse = InsightsModel.details(from: InsightsInput(total: 6, outcomes: ["paste": 6],
                                                               zeroEditObserved: 2, zeroEditRate: 1),
                                           recovery: nil, locale: locale)
        XCTAssertEqual(sparse.last?.rows.first?.value, "Needs 5 checked dictations. You have 2.")
    }

    // MARK: - shared shaping

    func testRankedOrdersByCountThenKey() {
        XCTAssertEqual(InsightsModel.ranked(["b": 2, "a": 2, "c": 5]),
                       [LabeledCount("c", 5), LabeledCount("a", 2), LabeledCount("b", 2)])
    }

    func testSparklineNormalisesAgainstTheBusiestDayAndSurvivesAnEmptyWindow() {
        let day = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(InsightsModel.sparkline([DayCount(day: day, count: 2),
                                                DayCount(day: day, count: 4)]), [0.5, 1])
        XCTAssertEqual(InsightsModel.sparkline([DayCount(day: day, count: 0)]), [0])
        XCTAssertEqual(InsightsModel.sparkline([]), [])
    }

    func testSecondsReadLikeAPersonWouldSayThem() {
        XCTAssertEqual(InsightsModel.seconds(200.4), "0.20 s")
        XCTAssertEqual(InsightsModel.seconds(617), "0.62 s")
        XCTAssertEqual(InsightsModel.seconds(1_206), "1.2 s")
        XCTAssertEqual(InsightsModel.secondsFigure(400), "0.40")
        XCTAssertEqual(InsightsModel.seconds(.nan), "—")
    }
}
