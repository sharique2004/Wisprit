import XCTest
import WispritDictionary
import WispritEngine
import WispritMacInput
import WispritMacUI
import WispritPersistence
import WispritRefine
@testable import WispritMac

/// The Dictations page's WispritMac half: what the session persists for it,
/// the history/metrics mapping seam, the feed the page reads, Teach, and the
/// Paste again handoff. The pure rules are in `WispritMacUITests`.
final class DictationsSessionTests: XCTestCase {

    /// The row's icon and the inspector's timings come from what the session
    /// writes once the text has landed — keyed to the transcript it just added.
    func testADeliveredDictationRecordsWhereItWentAndHowLongEachStageTook() {
        let h = SessionControllerTests.Harness(frontmostBundleID: { "com.apple.Notes" })
        h.asr.result = UtteranceResult(text: "hello world", engine: "apple_live", finalizeMs: 137)
        h.refiner.transform = { RefineResult(text: $0, outcome: .applied) }

        h.utterance()

        XCTAssertEqual(h.history.metas.count, 1)
        let (transcriptId, meta) = h.history.metas[0]
        XCTAssertEqual(transcriptId, 1, "the id `add` returned")
        XCTAssertEqual(meta.appBundleID, "com.apple.Notes")
        XCTAssertEqual(meta.outcome, "paste")
        XCTAssertEqual(meta.finalizeMs, 137)
        XCTAssertEqual(meta.ai, "applied")
        XCTAssertNotNil(meta.releaseToTextMs)
        // The same numbers the metrics line carries, so a persisted row and a
        // matched one can never disagree.
        XCTAssertEqual(meta.releaseToTextMs, h.metrics.last?.releaseToTextMs)
        XCTAssertEqual(meta.aiMs, h.metrics.last?.aiMs)
        XCTAssertEqual(meta.insertMs, h.metrics.last?.insertMs)
    }

    func testAFailedInsertStillRecordsItsRung() {
        let h = SessionControllerTests.Harness()
        h.asr.result = UtteranceResult(text: "hello world", engine: "apple_live", finalizeMs: 10)
        h.inserter.result = InsertResult(ok: false, method: .error, detail: "nope")

        h.utterance()

        XCTAssertEqual(h.history.metas.first?.meta.outcome, "error")
        XCTAssertNil(h.history.metas.first?.meta.appBundleID, "an unwired seam records no app")
    }

    func testAnEmptyHoldWritesNoMeta() {
        let h = SessionControllerTests.Harness(frontmostBundleID: { "com.apple.Notes" })
        h.asr.result = UtteranceResult(text: "", engine: "apple_live", finalizeMs: 10)
        h.utterance(heldSeconds: 2)
        XCTAssertTrue(h.history.metas.isEmpty)
        XCTAssertEqual(h.metrics.last?.outcome, "empty", "the miss lives in the log")
    }

    /// "Map every empty_reason": each reason the engine can write has its own
    /// plain-language copy, not the catch-all.
    func testEveryEmptyReasonTheEngineWritesHasItsOwnCopy() {
        let generic = MissCopy.for(reason: "a-reason-no-build-writes")
        for reason in EmptyReason.allCases {
            let copy = MissCopy.for(reason: reason.rawValue)
            XCTAssertNotEqual(copy, generic, "\(reason.rawValue) falls through to generic copy")
            XCTAssertFalse(copy.short.contains(reason.rawValue), "no machine token on screen")
        }
    }
}

final class DictationsSourceTests: XCTestCase {

    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()

    private func rows(_ lines: [String]) -> [JSONObject] {
        lines.compactMap {
            guard case .object(let object)? = try? WispritJSON.parse($0) else { return nil }
            return object
        }
    }

    func testMetricsLinesBecomeUtterancesAndTheReferenceLessOnesAreDropped() {
        let lines = rows([
            #"{"ts": 1794040715.85, "held_ms": 1944.7, "engine": "apple_live", "finalize_ms": 154.3, "timed_out": false, "post_ms": 0.0, "insert_ms": 0.0, "outcome": "empty", "chars": 0, "ai_ms": 0.1, "ai": "empty", "empty_reason": "starved", "audio_ms": 0.0, "input_device": "AirPods Max", "marginal_audio": true}"#,
            #"{"ts": 1794040720.0, "held_ms": 0, "engine": "apple_live", "finalize_ms": 0, "timed_out": false, "post_ms": 0, "insert_ms": 0, "outcome": "vocab_retro", "chars": 0}"#,
            #"{"ts": 1700000000, "held_ms": 900, "engine": "mlx_whisper", "finalize_ms": 80, "timed_out": false, "post_ms": 1.0, "insert_ms": 5.0, "outcome": "paste", "chars": 9, "release_to_text_ms": 210.5, "refine_delta": 3}"#,
        ])
        let utterances = HomeSource.utterances(lines)
        XCTAssertEqual(utterances.count, 2)
        XCTAssertEqual(utterances[0].outcome, "empty")
        XCTAssertEqual(utterances[0].emptyReason, "starved")
        XCTAssertEqual(utterances[0].heldMs, 1944.7)
        XCTAssertEqual(utterances[0].inputDevice, "AirPods Max")
        XCTAssertTrue(utterances[0].marginalAudio)
        XCTAssertTrue(utterances[0].isMiss)
        XCTAssertEqual(utterances[1].ts, 1_700_000_000, "an integer ts from the Python era")
        XCTAssertEqual(utterances[1].releaseToTextMs, 210.5)
        XCTAssertEqual(utterances[1].refineDelta, 3)
        XCTAssertTrue(utterances[1].isDelivery)
    }

    func testHistoryRowsCarryTheirDetailAndMetaIntoTheRecord() {
        let entry = HistoryEntry(id: 5, ts: 1, text: "Send it to Slack.", engine: "apple_live",
                                 durationMs: 1200)
        let detail = UtteranceDetail(id: 1, transcriptId: 5, raw: "send it to slack",
                                     corrected: "send it to slack", refined: "Send it to Slack.",
                                     inserted: "", vocab: nil, ai: "applied", termsHit: [],
                                     created: 1, text: entry.text, engine: entry.engine, ts: 1)
        let meta = TranscriptMeta(appBundleID: "com.tinyspeck.slackmacgap", outcome: "paste",
                                  releaseToTextMs: 300, finalizeMs: 90, aiMs: 120,
                                  inputDevice: "MacBook Pro Microphone")
        let record = HomeSource.records([DictationRow(entry: entry, detail: detail, meta: meta)])[0]
        XCTAssertEqual(record.heard, "send it to slack")
        XCTAssertEqual(record.refined, "Send it to Slack.")
        XCTAssertEqual(record.delivered, false, "inserted is empty: saved, never reached the app")
        XCTAssertEqual(record.appBundleID, "com.tinyspeck.slackmacgap")
        XCTAssertEqual(record.timing, DictationTiming(releaseToTextMs: 300, recognizeMs: 90,
                                                      cleanupMs: 120))
        XCTAssertEqual(record.inputDevice, "MacBook Pro Microphone")
        XCTAssertEqual(DictationsModel.chips(for: record), [.polished, .notPasted])
    }

    func testAnOldRowHasNoHeardTextNoAppAndNoTiming() {
        let entry = HistoryEntry(id: 1, ts: 1, text: "legacy", engine: "mlx_whisper", durationMs: nil)
        let record = HomeSource.records([DictationRow(entry: entry)])[0]
        XCTAssertNil(record.heard)
        XCTAssertNil(record.appBundleID)
        XCTAssertNil(record.timing)
        XCTAssertNil(record.delivered)
        XCTAssertEqual(record.wordCount, 1)
    }

    func testABlockedRungMarksTheRowNotDeliveredEvenWithoutDetail() {
        let entry = HistoryEntry(id: 1, ts: 1, text: "secret", engine: "apple_live", durationMs: 1)
        let record = HomeSource.records([DictationRow(
            entry: entry, meta: TranscriptMeta(outcome: "blocked_secure"))])[0]
        XCTAssertEqual(record.delivered, false)
    }

    func testCaptionsReadAsTheBriefSaysThem() {
        let ts = calendar.date(from: DateComponents(year: 2026, month: 11, day: 7,
                                                    hour: 0, minute: 29))!.timeIntervalSince1970
        let miss = MissedCapture(ts: ts, heldMs: 1300, reason: "starved")
        XCTAssertEqual(HomeSource.missCaption(miss, calendar: calendar),
                       "00:29 · 1.3 s of audio · the mic was still connecting")

        let run = MissedCapture(ts: ts + 180, heldMs: 900, reason: "silent", count: 4, firstTs: ts)
        XCTAssertEqual(HomeSource.missCaption(run, calendar: calendar),
                       "00:29–00:32 · 4 tries · it was quiet the whole time")

        let record = DictationRecord(id: 1, ts: ts, text: "This is low-key fire.",
                                     engine: "apple_live")
        XCTAssertEqual(HomeSource.dictationCaption(record, calendar: calendar), "00:29 · 4 words")
    }
}

final class PasteAgainHandoffTests: XCTestCase {
    private let own: pid_t = 100
    private let notes: pid_t = 200
    private let other: pid_t = 300

    /// The rule that matters: ⌘V is never posted while Wisprit has the front.
    func testWisprit_NeverReceivesThePaste() {
        for elapsed in [0.0, 0.5, 1.0, 1.49] {
            XCTAssertEqual(PasteAgainHandoff.decide(frontmost: own, own: own, target: notes,
                                                    elapsed: elapsed), .wait)
        }
        XCTAssertEqual(PasteAgainHandoff.decide(frontmost: own, own: own, target: notes,
                                                elapsed: PasteAgainHandoff.timeout), .giveUp)
        XCTAssertEqual(PasteAgainHandoff.decide(frontmost: nil, own: own, target: nil,
                                                elapsed: PasteAgainHandoff.timeout), .giveUp)
    }

    func testThePasteGoesOnceTheAppTheUserWasInIsFront() {
        XCTAssertEqual(PasteAgainHandoff.decide(frontmost: notes, own: own, target: notes,
                                                elapsed: 0.1), .paste)
    }

    /// Asked for one app, another came forward: give the asked-for one the
    /// whole timeout, then accept whatever is front as long as it is not us.
    func testAnotherAppIsAcceptedOnlyAtTheTimeout() {
        XCTAssertEqual(PasteAgainHandoff.decide(frontmost: other, own: own, target: notes,
                                                elapsed: 0.2), .wait)
        XCTAssertEqual(PasteAgainHandoff.decide(frontmost: other, own: own, target: notes,
                                                elapsed: PasteAgainHandoff.timeout), .paste)
    }

    func testWithNoKnownTargetAnyOtherAppWillDo() {
        XCTAssertEqual(PasteAgainHandoff.decide(frontmost: other, own: own, target: nil,
                                                elapsed: 0.05), .paste)
    }

    func testTheSettleTopsUpToTheMeasuredQuarterSecond() {
        XCTAssertEqual(PasteAgainHandoff.settle(after: 0.05), 0.2, accuracy: 1e-9)
        XCTAssertEqual(PasteAgainHandoff.settle(after: 0.9), 0.1, accuracy: 1e-9)
    }
}

/// The feed the page reads and the actions it takes, through fake ports.
@MainActor
final class DictationsFeedTests: XCTestCase {

    private var root: URL!
    private var settings: Settings!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wisprit-dictations-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        settings = Settings(path: root.appendingPathComponent("config.json"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func bump() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    private func makeModel(rows: [DictationRow] = [],
                           metrics: [JSONObject] = [],
                           stamp: Date? = Date(timeIntervalSince1970: 1),
                           reads: Counter = Counter()) -> WispritWindowModel {
        WispritWindowModel(
            settings: settings,
            dictionary: DictionaryEditor(store: DictionaryStore(
                path: root.appendingPathComponent("dictionary.json"))),
            ports: WispritWindowModel.Ports(
                dictations: { Array(rows.prefix($0)) },
                metricsStamp: { stamp },
                metricsRows: { reads.bump(); return metrics }))
    }

    private func settle(_ condition: @MainActor () -> Bool) async {
        var attempts = 0
        while !condition(), attempts < 300 {
            attempts += 1
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    private func metricsLine(ts: Double, outcome: String, held: Double,
                             reason: String? = nil) -> JSONObject {
        var pairs: [(String, SettingValue)] = [("ts", .double(ts)), ("held_ms", .double(held)),
                                               ("outcome", .string(outcome)),
                                               ("release_to_text_ms", .double(250))]
        if let reason { pairs.append(("empty_reason", .string(reason))) }
        return JSONObject(pairs)
    }

    func testLoadingHistoryFillsTheFeedWithDictationsAndMisses() async {
        let now = Date().timeIntervalSince1970
        let row = DictationRow(entry: HistoryEntry(id: 1, ts: now - 100, text: "hello there",
                                                   engine: "apple_live", durationMs: 1500))
        let model = makeModel(rows: [row], metrics: [
            metricsLine(ts: now - 99.6, outcome: "paste", held: 1500),
            metricsLine(ts: now - 50, outcome: "empty", held: 1300, reason: "starved"),
        ])
        XCTAssertFalse(model.dictationsFeed.hasLoaded)
        model.loadHistory(reset: true)
        await settle { model.dictationsFeed.hasLoaded }

        let entries = model.dictationsFeed.entries
        XCTAssertEqual(entries.count, 2)
        XCTAssertNotNil(entries[0].miss, "the newer miss is first")
        XCTAssertEqual(entries[1].record?.timing?.releaseToTextMs, 250, "matched from the log")
        XCTAssertEqual(model.dictationsFeed.secondsToText, 0.25)
    }

    /// An idle page costs a `stat` per tick, not a parse of the whole log.
    func testTheLogIsParsedOnlyWhenItChanges() async {
        let reads = Counter()
        let model = makeModel(reads: reads)
        model.loadHistory(reset: true)
        await settle { model.dictationsFeed.hasLoaded }
        model.loadHistory()
        model.loadHistory()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(reads.count, 1)
    }

    func testAPreselectionPicksItsRowOnceTheFirstLoadLands() async {
        let now = Date().timeIntervalSince1970
        let row = DictationRow(entry: HistoryEntry(id: 1, ts: now - 100, text: "hi",
                                                   engine: "apple_live", durationMs: 1))
        let model = makeModel(rows: [row], metrics: [
            metricsLine(ts: now - 10, outcome: "empty", held: 900, reason: "silent"),
        ])
        model.dictationsFeed.preselect = .missed
        model.loadHistory(reset: true)
        await settle { model.dictationsFeed.selection != nil }
        XCTAssertNotNil(model.dictationsFeed.selectedEntry?.miss)
        XCTAssertNil(model.dictationsFeed.preselect, "applied once")
    }

    // MARK: - teach

    func testTeachAddsTheHeardSpellingToANewTerm() {
        let model = makeModel()
        XCTAssertEqual(model.teach(heard: " whispered, ", spelling: "Whisper"),
                       .added(term: "Whisper"))
        let row = model.dictionaryRows.first { $0.term == "Whisper" }
        XCTAssertEqual(row?.hear, ["whispered"])
    }

    func testTeachAddsAPhraseToAnExistingTermWithoutRenamingIt() {
        let model = makeModel()
        XCTAssertTrue(model.saveTerm(original: nil, term: "Sharique", hear: ["shariq"]))
        XCTAssertEqual(model.teach(heard: "sharik", spelling: "sharique"), .added(term: "Sharique"))
        XCTAssertEqual(model.dictionaryRows.map(\.term), ["Sharique"])
        XCTAssertEqual(model.dictionaryRows.first?.hear, ["shariq", "sharik"])
        XCTAssertEqual(model.teach(heard: "sharik", spelling: "Sharique"),
                       .alreadyKnown(term: "Sharique"))
    }

    func testTeachWithNoSpellingDoesNothing() {
        let model = makeModel()
        XCTAssertEqual(model.teach(heard: "anything", spelling: "  "), .invalid)
        XCTAssertTrue(model.dictionaryRows.isEmpty)
    }

    func testTeachingATermAsItsOwnSpellingAddsJustTheTerm() {
        let model = makeModel()
        XCTAssertEqual(model.teach(heard: "Parakeet", spelling: "Parakeet"),
                       .added(term: "Parakeet"))
        XCTAssertEqual(model.dictionaryRows.first?.hear, [])
    }
}
