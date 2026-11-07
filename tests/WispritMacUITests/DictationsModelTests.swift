import XCTest
@testable import WispritMacUI

/// The Dictations page's rules, over neutral values: the Heard | Written diff,
/// metrics ↔ history matching, the miss rows and their copy, chips, search,
/// keyboard movement, the header line.
final class WordDiffTests: XCTestCase {

    private func joined(_ segments: [WordDiff.Segment]) -> String {
        segments.map(\.text).joined()
    }

    private func changed(_ segments: [WordDiff.Segment]) -> [String] {
        segments.filter(\.changed).map(\.text)
    }

    func testIdenticalTextHasNoChanges() {
        let result = WordDiff.diff(heard: "hello there world", written: "hello there world")
        XCTAssertTrue(result.isUnchanged)
        XCTAssertEqual(result.changeCount, 0)
        XCTAssertEqual(changed(result.heard), [])
        XCTAssertEqual(joined(result.written), "hello there world")
    }

    func testAReplacedWordIsUnderlinedOnBothSides() {
        let result = WordDiff.diff(heard: "One of them is whispered, the other",
                                   written: "One of them is Whisper, the other")
        XCTAssertEqual(changed(result.heard), ["whispered,"])
        XCTAssertEqual(changed(result.written), ["Whisper,"])
        XCTAssertEqual(result.changeCount, 1)
    }

    func testCapitalisationAndPunctuationAreChanges() {
        let result = WordDiff.diff(heard: "send you all the slack conversations",
                                   written: "send you all the Slack conversations")
        XCTAssertEqual(changed(result.written), ["Slack"])

        let dots = WordDiff.diff(heard: "Secondly, it's... .", written: "Secondly, it's....")
        XCTAssertEqual(changed(dots.heard), ["it's... ."], "a run of adjacent changes reads as one")
        XCTAssertEqual(changed(dots.written), ["it's...."])
        XCTAssertEqual(dots.changeCount, 1)
    }

    /// A removed filler shows in Heard only — there is nothing to underline in
    /// Written where a word simply is not.
    func testARemovedWordShowsOnTheHeardSideOnly() {
        let result = WordDiff.diff(heard: "and to do the, um, and to do the Q and A",
                                   written: "and to do the, and to do the Q and A")
        XCTAssertEqual(changed(result.heard), ["um,"])
        XCTAssertEqual(changed(result.written), [])
        XCTAssertEqual(result.changeCount, 1)
    }

    func testSeparateEditsAreCountedSeparately() {
        let result = WordDiff.diff(heard: "uh the meeting scribe app and uh the speaker",
                                   written: "the MeetingScribe app and the speaker")
        XCTAssertEqual(result.changeCount, 3, "two removed fillers and one merge")
        XCTAssertEqual(changed(result.written), ["MeetingScribe"])
    }

    /// Joining either side's segments gives that side back byte for byte —
    /// newlines, double spaces and leading/trailing whitespace included.
    func testBothSidesRoundTripTheirOwnText() {
        let heard = "  first line\nsecond  line  with   gaps "
        let written = "First line.\nSecond line with gaps"
        let result = WordDiff.diff(heard: heard, written: written)
        XCTAssertEqual(joined(result.heard), heard)
        XCTAssertEqual(joined(result.written), written)
    }

    /// The underline covers the word, not the space after it.
    func testAChangeDoesNotUnderlineTheFollowingSpace() {
        let result = WordDiff.diff(heard: "a b c", written: "a x c")
        XCTAssertEqual(result.written, [WordDiff.Segment("a ", changed: false),
                                        WordDiff.Segment("x", changed: true),
                                        WordDiff.Segment(" c", changed: false)])
    }

    func testEmptySides() {
        XCTAssertEqual(WordDiff.diff(heard: "", written: "").changeCount, 0)
        let added = WordDiff.diff(heard: "", written: "new words")
        XCTAssertEqual(changed(added.written), ["new words"])
        XCTAssertEqual(added.changeCount, 1)
    }

    /// Past the table limit the middle is marked changed wholesale instead of
    /// paying a quadratic — and the shared prefix and suffix still are not.
    func testAHugeMiddleFallsBackWithoutLosingThePrefixAndSuffix() {
        let middleA = (0..<(WordDiff.tableLimit + 10)).map { "a\($0)" }.joined(separator: " ")
        let middleB = (0..<(WordDiff.tableLimit + 10)).map { "b\($0)" }.joined(separator: " ")
        let result = WordDiff.diff(heard: "start " + middleA + " end",
                                   written: "start " + middleB + " end")
        XCTAssertEqual(result.written.first, WordDiff.Segment("start ", changed: false))
        XCTAssertEqual(result.written.last, WordDiff.Segment(" end", changed: false))
        XCTAssertEqual(result.changeCount, 1)
    }
}

final class DictationsModelTests: XCTestCase {

    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()

    private let base: Double = 1_794_000_000   // a fixed instant

    private func record(_ id: Int64, at ts: Double, _ text: String = "hello world",
                        held: Double? = 1234.5678) -> DictationRecord {
        DictationRecord(id: id, ts: ts, text: text, engine: "apple_live", durationMs: held)
    }

    private func line(at ts: Double, held: Double, outcome: String = "paste",
                      rtt: Double? = 200, reason: String? = nil) -> MetricsUtterance {
        MetricsUtterance(ts: ts, heldMs: held, outcome: outcome, emptyReason: reason,
                         releaseToTextMs: rtt, finalizeMs: 80, aiMs: 50, ai: "applied",
                         inputDevice: "AirPods")
    }

    // MARK: - matching

    /// The rule the real log supports: same hold to the logged decimal, metrics
    /// written a fraction of a second after the transcript.
    func testALineMatchesItsTranscriptByHoldAndTime() {
        let records = [record(1, at: base)]
        let lines = [line(at: base + 0.5, held: 1234.6, rtt: 412)]
        let matched = DictationsModel.match(records, metrics: lines)
        XCTAssertEqual(matched[0].timing?.releaseToTextMs, 412)
        XCTAssertEqual(matched[0].timing?.recognizeMs, 80)
        XCTAssertEqual(matched[0].timing?.cleanupMs, 50)
        XCTAssertEqual(matched[0].ai, "applied")
        XCTAssertEqual(matched[0].inputDevice, "AirPods")
        XCTAssertEqual(matched[0].outcome, "paste")
    }

    func testADifferentHoldNeverMatchesHoweverCloseInTime() {
        let matched = DictationsModel.match([record(1, at: base)],
                                            metrics: [line(at: base + 0.01, held: 999)])
        XCTAssertNil(matched[0].timing)
    }

    func testALineOutsideTheWindowNeverMatches() {
        let late = DictationsModel.match([record(1, at: base)],
                                         metrics: [line(at: base + 31, held: 1234.6)])
        XCTAssertNil(late[0].timing)
        let early = DictationsModel.match([record(1, at: base)],
                                          metrics: [line(at: base - 2, held: 1234.6)])
        XCTAssertNil(early[0].timing)
    }

    /// Misses and spelling corrections have no transcript; even with the same
    /// hold they are never somebody's timing.
    func testOnlyDeliveryLinesMatch() {
        let matched = DictationsModel.match(
            [record(1, at: base)],
            metrics: [line(at: base + 0.2, held: 1234.6, outcome: "empty"),
                      line(at: base + 0.3, held: 1234.6, outcome: "correction")])
        XCTAssertNil(matched[0].timing)
    }

    /// Two transcripts with the same hold length, a second apart: each claims
    /// its own line, and the nearer one wins.
    func testEachLineIsSpentOnceAndTheNearestWins() {
        let records = [record(2, at: base + 1), record(1, at: base)]
        let lines = [line(at: base + 0.2, held: 1234.6, rtt: 111),
                     line(at: base + 1.3, held: 1234.6, rtt: 222)]
        let matched = DictationsModel.match(records, metrics: lines)
        XCTAssertEqual(matched.first { $0.id == 1 }?.timing?.releaseToTextMs, 111)
        XCTAssertEqual(matched.first { $0.id == 2 }?.timing?.releaseToTextMs, 222)
    }

    /// Python-era rows carry no hold: only a near-simultaneous line counts.
    func testARowWithNoHoldMatchesOnlyANearbyLine() {
        let near = DictationsModel.match([record(1, at: base, held: nil)],
                                         metrics: [line(at: base + 1, held: 500)])
        XCTAssertEqual(near[0].timing?.releaseToTextMs, 200)
        let far = DictationsModel.match([record(1, at: base, held: nil)],
                                        metrics: [line(at: base + 5, held: 500)])
        XCTAssertNil(far[0].timing)
    }

    /// What the session persisted is the truth; the log only fills gaps.
    func testPersistedFactsWinOverTheLog() {
        var persisted = record(1, at: base)
        persisted.timing = DictationTiming(releaseToTextMs: 999, recognizeMs: nil, cleanupMs: nil)
        persisted.ai = "off"
        persisted.inputDevice = "MacBook Pro Microphone"
        let matched = DictationsModel.match([persisted], metrics: [line(at: base + 0.4, held: 1234.6)])
        XCTAssertEqual(matched[0].timing?.releaseToTextMs, 999)
        XCTAssertEqual(matched[0].timing?.recognizeMs, 80, "a gap is still filled")
        XCTAssertEqual(matched[0].ai, "off")
        XCTAssertEqual(matched[0].inputDevice, "MacBook Pro Microphone")
    }

    func testABlockedDeliveryIsMarkedNotDelivered() {
        let matched = DictationsModel.match([record(1, at: base)],
                                            metrics: [line(at: base + 0.4, held: 1234.6,
                                                           outcome: "blocked_secure")])
        XCTAssertEqual(matched[0].delivered, false)
        XCTAssertEqual(DictationsModel.chips(for: matched[0]), [.notPasted])
    }

    // MARK: - the timeline

    private var now: Date { Date(timeIntervalSince1970: base + 3600) }

    func testMissesAreInterleavedByTimeNewestFirst() {
        let entries = DictationsModel.timeline(
            records: [record(2, at: base + 100), record(1, at: base)],
            metrics: [line(at: base + 50, held: 1300, outcome: "empty", reason: "starved")],
            isComplete: false, now: now)
        XCTAssertEqual(entries.map(\.id), [.dictation(2), .missed(Int64((base + 50) * 1000)),
                                           .dictation(1)])
        XCTAssertEqual(entries[1].miss?.copy.short, "the mic was still connecting")
    }

    /// One page of history at a time: a miss older than the oldest row on the
    /// page would sit under a "Show older" button that cannot load it.
    func testMissesStopWhereThePageStops() {
        let older = line(at: base - 60, held: 900, outcome: "empty", reason: "silent")
        let partial = DictationsModel.timeline(records: [record(1, at: base)], metrics: [older],
                                               isComplete: false, now: now)
        XCTAssertEqual(partial.count, 1)
        let complete = DictationsModel.timeline(records: [record(1, at: base)], metrics: [older],
                                                isComplete: true, now: now)
        XCTAssertEqual(complete.count, 2, "with the whole history loaded, it belongs")
    }

    func testWithNoHistoryOnlyRecentMissesShow() {
        let recent = line(at: base + 3000, held: 900, outcome: "empty", reason: "silent")
        let ancient = line(at: base - 30 * 24 * 3600, held: 900, outcome: "empty", reason: "silent")
        let entries = DictationsModel.timeline(records: [], metrics: [recent, ancient],
                                               isComplete: true, now: now)
        XCTAssertEqual(entries.count, 1)
    }

    // MARK: - folding a run of misses

    private func miss(_ offset: Double, _ reason: String?) -> DictationEntry {
        .missed(MissedCapture(ts: base + offset, heldMs: 1000, reason: reason))
    }

    func testABurstOfTheSameMissFoldsIntoOneRow() {
        let folded = DictationsModel.foldMisses([miss(30, "silent"), miss(20, "silent"),
                                                 miss(10, "silent")])
        XCTAssertEqual(folded.count, 1)
        XCTAssertEqual(folded[0].miss?.count, 3)
        XCTAssertEqual(folded[0].miss?.ts, base + 30, "the row sits at the newest try")
        XCTAssertEqual(folded[0].miss?.firstTs, base + 10)
    }

    func testDifferentReasonsADictationOrALongGapKeepRowsApart() {
        XCTAssertEqual(DictationsModel.foldMisses([miss(30, "silent"), miss(20, "starved")]).count, 2)
        XCTAssertEqual(DictationsModel.foldMisses([
            miss(30, "silent"), .dictation(record(1, at: base + 25)), miss(20, "silent"),
        ]).count, 3)
        XCTAssertEqual(DictationsModel.foldMisses([
            miss(DictationsModel.missRunGap + 100, "silent"), miss(0, "silent"),
        ]).count, 2)
    }

    /// A selected run stays selected when a newer try joins it: its identity is
    /// its first try.
    func testARunKeepsItsIdentityAsItGrows() {
        let before = DictationsModel.foldMisses([miss(20, "silent"), miss(10, "silent")])
        let after = DictationsModel.foldMisses([miss(30, "silent"), miss(20, "silent"),
                                                miss(10, "silent")])
        XCTAssertEqual(before[0].id, after[0].id)
    }

    // MARK: - what a miss says

    /// Every reason the engine writes has its own plain-language copy (the
    /// exhaustive check against `EmptyReason.allCases` lives in
    /// `WispritMacTests`, which can see the engine).
    func testEveryKnownReasonHasItsOwnCopy() {
        let reasons = ["timed_out", "crashed", "starved", "device_changed", "silent",
                       "short_hold", "produced_nothing"]
        let generic = MissCopy.for(reason: "something_new")
        let copies = reasons.map { MissCopy.for(reason: $0) }
        for (reason, copy) in zip(reasons, copies) {
            XCTAssertNotEqual(copy, generic, reason)
            XCTAssertFalse(copy.short.contains("_"), "no machine tokens on screen: \(reason)")
            XCTAssertFalse(copy.advice.lowercased().contains("retry"),
                           "there is no audio to retry: \(reason)")
        }
        XCTAssertEqual(Set(copies.map(\.short)).count, reasons.count, "each says something different")
    }

    func testAFaintMissSaysSoAndAnUnrecordedOneSaysThat() {
        XCTAssertEqual(MissCopy.for(reason: "produced_nothing", marginal: true).short,
                       "it was too faint to make out")
        XCTAssertNotEqual(MissCopy.for(reason: "produced_nothing", marginal: true),
                          MissCopy.for(reason: "produced_nothing"))
        XCTAssertEqual(MissCopy.for(reason: nil).short, "no reason was recorded")
    }

    // MARK: - chips

    func testPolishedNeedsCleanupToHaveRunAndChangedTheWords() {
        var record = record(1, at: base)
        record.ai = "applied"
        record.corrected = "send it to slack"
        record.refined = "Send it to Slack."
        XCTAssertEqual(DictationsModel.chips(for: record), [.polished])

        record.refined = record.corrected
        XCTAssertEqual(DictationsModel.chips(for: record), [], "ran, changed nothing")

        record.refined = "Different."
        record.ai = "skipped_verbatim_app"
        XCTAssertEqual(DictationsModel.chips(for: record), [], "did not run")
    }

    func testWithoutTheDetailTheLogsEditDistanceStandsIn() {
        var record = record(1, at: base)
        record.ai = "applied"
        record.refineDelta = 4
        XCTAssertTrue(DictationsModel.isPolished(record))
        record.refineDelta = 0
        XCTAssertFalse(DictationsModel.isPolished(record))
    }

    // MARK: - search and keyboard

    func testSearchMatchesWhatWasWrittenOrHeardAndDropsMisses() {
        var record = record(1, at: base, "Is it Loki fire?")
        record.heard = "is it low key fire"
        let entries: [DictationEntry] = [.dictation(record), miss(5, "silent")]
        XCTAssertEqual(DictationsModel.filter(entries, query: "loki").count, 1)
        XCTAssertEqual(DictationsModel.filter(entries, query: "LOW KEY").count, 1,
                       "the misheard spelling is often the one remembered")
        XCTAssertEqual(DictationsModel.filter(entries, query: "  ").count, 2)
        XCTAssertEqual(DictationsModel.filter(entries, query: "nothing").count, 0)
    }

    func testArrowsMoveWithinTheVisibleRowsAndClamp() {
        let entries: [DictationEntry] = [.dictation(record(3, at: base + 2)),
                                         .dictation(record(2, at: base + 1)),
                                         .dictation(record(1, at: base))]
        XCTAssertEqual(DictationsModel.move(nil, by: 1, in: entries), .dictation(3))
        XCTAssertEqual(DictationsModel.move(nil, by: -1, in: entries), .dictation(1))
        XCTAssertEqual(DictationsModel.move(.dictation(3), by: 1, in: entries), .dictation(2))
        XCTAssertEqual(DictationsModel.move(.dictation(3), by: -1, in: entries), .dictation(3))
        XCTAssertEqual(DictationsModel.move(.dictation(1), by: 1, in: entries), .dictation(1))
        XCTAssertEqual(DictationsModel.move(.dictation(99), by: 1, in: entries), .dictation(3),
                       "a selection the filter hid starts again at the top")
        XCTAssertNil(DictationsModel.move(nil, by: 1, in: []))
    }

    func testDaysGroupNewestFirst() {
        let entries: [DictationEntry] = [.dictation(record(2, at: base + 86_400)),
                                         .dictation(record(1, at: base))]
        let days = DictationsModel.days(entries, now: Date(timeIntervalSince1970: base + 86_400),
                                        calendar: calendar)
        XCTAssertEqual(days.map(\.title), ["Today", "Yesterday"])
    }

    // MARK: - the header

    func testTheStatLineOmitsWhatItCannotSay() {
        let stats = HomeStats(lifetimeWords: 25_934, wordsToday: 27, dictationsToday: 4,
                              medianWPM: 122.6, streakDays: 3, heatmap: [], heatmapWeeks: 0)
        let parts = DictationsModel.statParts(stats: stats, secondsToText: 0.2,
                                              decimal: { $0 == 25_934 ? "25,934" : "\($0)" })
        XCTAssertEqual(parts.map { $0.lead + $0.value + $0.label },
                       ["Today 27 words", "123 wpm", "0.20 s to text", "25,934 all time"])

        let bare = DictationsModel.statParts(
            stats: HomeStats(lifetimeWords: 0, wordsToday: 1, dictationsToday: 1, medianWPM: nil,
                             streakDays: 0, heatmap: [], heatmapWeeks: 0),
            secondsToText: nil, decimal: { "\($0)" })
        XCTAssertEqual(bare.map { $0.lead + $0.value + $0.label }, ["Today 1 word"])
        XCTAssertEqual(DictationsModel.statParts(stats: nil, secondsToText: nil,
                                                 decimal: { "\($0)" }), [])
    }

    func testSecondsToTextIsTheMedianOfRecentDeliveries() {
        let lines = [line(at: 1, held: 1, rtt: 100), line(at: 2, held: 1, rtt: 300),
                     line(at: 3, held: 1, rtt: 200),
                     line(at: 4, held: 1, outcome: "empty", rtt: 9_000)]
        XCTAssertEqual(DictationsModel.medianSecondsToText(lines), 0.2)
        XCTAssertEqual(DictationsModel.medianSecondsToText(lines, sample: 1), 0.2,
                       "the newest delivery only")
        XCTAssertNil(DictationsModel.medianSecondsToText([]))
    }

    // MARK: - formatting

    func testDurationsReadAsMillisecondsThenSeconds() {
        XCTAssertEqual(DictationsModel.duration(ms: 412.4), "412 ms")
        XCTAssertEqual(DictationsModel.duration(ms: 1430), "1.4 s")
        XCTAssertEqual(DictationsModel.heldLength(ms: 1300), "1.3 s")
    }

    func testNoMachineNamesReachTheInspector() {
        XCTAssertEqual(DictationsModel.speechEngineName("apple_live"), "Apple speech")
        XCTAssertEqual(DictationsModel.speechEngineName("something_new"), "Speech recognition")
        for ai in ["applied", "off", "skipped_verbatim_app", "too_long", "timeout",
                   "has_letter_run", "implausible", "obeyed", "helper_error", "new_thing"] {
            let text = DictationsModel.cleanupDescription(ai) ?? ""
            XCTAssertFalse(text.contains("_"), ai)
            XCTAssertFalse(text.isEmpty, ai)
        }
        XCTAssertTrue(DictationsModel.cleanupRan("applied"))
        XCTAssertFalse(DictationsModel.cleanupRan("skipped_verbatim_app"))
        XCTAssertNil(DictationsModel.micName("CADefaultDeviceAggregate-1470-0"))
        XCTAssertEqual(DictationsModel.micName("Sharique’s AirPods Max"), "Sharique’s AirPods Max")
        XCTAssertNil(DictationsModel.micName("  "))
    }

    // MARK: - teach

    func testTeachingFromAChangedHeardWordSuggestsWhatItBecame() {
        let diff = WordDiff.diff(heard: "One of them is whispered, the other is parakeet",
                                 written: "One of them is Whisper, the other is Parakeet")
        XCTAssertEqual(DictationsModel.suggestedSpelling(for: "parakeet", diff: diff), "Parakeet")
        XCTAssertNil(DictationsModel.suggestedSpelling(for: "other", diff: diff),
                     "an unchanged word has nothing to suggest")
        XCTAssertNil(DictationsModel.suggestedSpelling(for: "", diff: diff))
    }

    func testASelectedPhraseLosesTheEdgesADragPicksUp() {
        XCTAssertEqual(DictationsModel.teachablePhrase(" whispered, "), "whispered")
        XCTAssertEqual(DictationsModel.teachablePhrase("“low-key”."), "low-key")
        XCTAssertEqual(DictationsModel.teachablePhrase("it's"), "it's")
    }
}
