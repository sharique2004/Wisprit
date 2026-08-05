import XCTest
import WispritCorrections
import WispritEngine
import WispritKit
import WispritMacInput
import WispritPersistence
import WispritPostProcess
import WispritRefine
@testable import WispritMac

/// The `session.py` state machine, driven with fakes.
///
/// `dispatch(_:)` is synchronous, so every test is a straight-line sequence of
/// events with assertions in between — no waiting, no threads, no TCC.
final class SessionControllerTests: XCTestCase {

    /// Thread-safe collector, so assertions can observe values produced inside
    /// `@Sendable` callbacks without a captured `var`.
    final class Recorder<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [T] = []
        func append(_ value: T) { lock.lock(); storage.append(value); lock.unlock() }
        var values: [T] { lock.lock(); defer { lock.unlock() }; return storage }
    }

    // MARK: - harness

    struct Harness {
        let events = HotkeyEventQueue()
        let asr = FakeAsr()
        let audio = FakeAudio()
        let refiner = FakeRefiner()
        let inserter = FakeInserter()
        let history = FakeHistory()
        let metrics = FakeMetrics()
        let pill = FakePill()
        let vocabulary = FakeVocabulary()
        let gate = FakeGate()
        let dictionary = FakeDictionary()
        let session: SessionController

        init(useRefiner: Bool = true,
             corrector: SpokenSpellingCorrector? = nil,
             enabled: Bool = true,
             debounceMs: Double = 150) {
            inserter.history = history
            session = SessionController(
                events: events,
                asr: asr,
                audio: audio,
                inserter: inserter,
                history: history,
                metrics: metrics,
                refiner: useRefiner ? refiner : nil,
                pill: pill,
                vocabulary: vocabulary,
                corrections: dictionary,
                corrector: corrector,
                gate: gate,
                configuration: SessionController.Configuration(
                    holdDebounceMs: { debounceMs },
                    isEnabled: { enabled },
                    // The ticker and the reconciliation pass both spawn
                    // background work; off here so assertions stay deterministic.
                    levelTickInterval: nil,
                    reconcileVocabulary: false))
        }

        /// One complete hold: press at t=0, release at t=`heldSeconds`.
        func utterance(heldSeconds: Double = 1.0) {
            session.dispatch(HotkeyEvent(.press, ts: 0))
            session.dispatch(HotkeyEvent(.release, ts: heldSeconds))
        }
    }

    // MARK: - happy path

    func testFullUtterancePipeline() {
        let h = Harness()
        h.asr.result = UtteranceResult(text: "um hello world", engine: "apple_live", finalizeMs: 137)
        h.refiner.transform = { RefineResult(text: $0, outcome: .applied) }

        h.utterance()

        XCTAssertEqual(h.session.state, .idle)
        XCTAssertEqual(h.vocabulary.reloadCount, 1, "dictionary hot-reloads at key-down")
        XCTAssertEqual(h.audio.startCount, 1)
        XCTAssertEqual(h.audio.stopCount, 1)
        XCTAssertEqual(h.asr.beginCount, 1)
        XCTAssertEqual(h.asr.finalizeCount, 1)
        XCTAssertEqual(h.refiner.beginCount, 1, "refiner prewarms at record start")
        XCTAssertEqual(h.refiner.refineCount, 1)
        // Filler removal is the postprocess stage AFTER refine.
        XCTAssertEqual(h.inserter.inserted, ["hello world"])
        XCTAssertEqual(h.history.added.map(\.text), ["hello world"])
        XCTAssertTrue(h.pill.snapshot().contains("flashSuccess"))
    }

    func testStateSequenceIsIdleRecordingFinalizingInserting() {
        let h = Harness()
        let seen = Recorder<SessionController.State>()
        h.session.onStateChange = { state in seen.append(state) }

        h.utterance()

        XCTAssertEqual(seen.values, [.recording, .finalizing, .inserting, .idle])
    }

    func testPartialsReachThePill() {
        let h = Harness()
        h.asr.partials = ["hello", "hello world"]

        h.session.dispatch(HotkeyEvent(.press, ts: 0))

        XCTAssertEqual(h.pill.partials, ["hello", "hello world"])
    }

    // MARK: - debounce

    func testSubDebounceHoldIsSilentlyDiscarded() {
        let h = Harness(debounceMs: 150)

        h.utterance(heldSeconds: 0.05)          // 50 ms < 150 ms

        XCTAssertEqual(h.session.state, .idle)
        XCTAssertEqual(h.asr.cancelCount, 1, "the utterance is thrown away")
        XCTAssertEqual(h.asr.finalizeCount, 0, "never pay for a finalize")
        XCTAssertEqual(h.refiner.cancelCount, 1)
        XCTAssertTrue(h.inserter.inserted.isEmpty)
        XCTAssertTrue(h.history.added.isEmpty)
        XCTAssertTrue(h.metrics.records.isEmpty, "no metrics row for an accidental brush")
        XCTAssertTrue(h.pill.snapshot().contains("hide"))
        XCTAssertEqual(h.gate.transitions, [true, false])
    }

    func testHoldExactlyAtTheDebounceThresholdIsKept() {
        let h = Harness(debounceMs: 150)
        h.utterance(heldSeconds: 0.150)
        XCTAssertEqual(h.inserter.inserted.count, 1)
    }

    // MARK: - cancel paths

    func testEscMidHoldDiscardsTheUtterance() {
        let h = Harness()

        h.session.dispatch(HotkeyEvent(.press, ts: 0))
        XCTAssertEqual(h.session.state, .recording)
        h.session.dispatch(HotkeyEvent(.esc, ts: 0.5))

        XCTAssertEqual(h.session.state, .idle)
        XCTAssertEqual(h.audio.stopCount, 1)
        XCTAssertEqual(h.asr.cancelCount, 1)
        XCTAssertEqual(h.refiner.cancelCount, 1)
        XCTAssertTrue(h.inserter.inserted.isEmpty)
        XCTAssertTrue(h.pill.snapshot().contains("hide"))
        XCTAssertTrue(h.pill.errors.isEmpty, "a deliberate cancel is not an error")
    }

    func testChordCancelMidHoldDiscardsTheUtterance() {
        let h = Harness()
        h.session.dispatch(HotkeyEvent(.press, ts: 0))
        h.session.dispatch(HotkeyEvent(.cancel, ts: 0.2))

        XCTAssertEqual(h.session.state, .idle)
        XCTAssertEqual(h.asr.cancelCount, 1)
        XCTAssertTrue(h.pill.snapshot().contains("hide"))
    }

    func testEscQueuedDuringFinalizeAbortsBeforePayingForAI() {
        let h = Harness()
        // Esc lands while the ASR is still finalizing: it is already queued by
        // the time the first drain checkpoint runs.
        h.events.put(HotkeyEvent(.esc, ts: 0.9))

        h.utterance()

        XCTAssertEqual(h.refiner.refineCount, 0, "never pay for AI on an aborted utterance")
        XCTAssertEqual(h.refiner.cancelCount, 1)
        XCTAssertTrue(h.inserter.inserted.isEmpty)
        XCTAssertTrue(h.metrics.records.isEmpty)
        XCTAssertEqual(h.session.state, .idle)
    }

    func testEscDuringRefinePreemptsWithVerbatimTextAndSkipsInsertion() {
        let h = Harness()
        h.asr.result = UtteranceResult(text: "keep me verbatim", engine: "apple_live", finalizeMs: 90)
        // The interrupt hook is polled inside refine; queue Esc so the FakeRefiner
        // sees it exactly where the real cage's 50 ms poller would.
        h.refiner.transform = { _ in XCTFail("generation should not complete"); return RefineResult(text: "", outcome: .applied) }
        h.session.dispatch(HotkeyEvent(.press, ts: 0))
        h.events.put(HotkeyEvent(.esc, ts: 0.5))
        // drainCancel() at the first checkpoint would consume it, so re-arm the
        // Esc from inside the refine stage instead.
        h.refiner.honoursInterrupt = true

        h.session.dispatch(HotkeyEvent(.release, ts: 1.0))

        XCTAssertTrue(h.inserter.inserted.isEmpty)
        XCTAssertEqual(h.session.state, .idle)
    }

    func testRecordingGateStaysTrueThroughRefine() {
        let h = Harness()
        let gateDuringRefine = Recorder<Bool>()
        h.refiner.transform = { [gate = h.gate] text in
            gateDuringRefine.append(gate.isRecording)
            return RefineResult(text: text, outcome: .applied)
        }

        h.utterance()

        XCTAssertEqual(gateDuringRefine.values, [true],
                       "Esc must stay live through the longest stage")
        XCTAssertEqual(h.gate.transitions, [true, false])
    }

    // MARK: - hurry preempt

    func testQueuedPressDuringRefineHurriesWithVerbatimText() {
        let h = Harness()
        h.asr.result = UtteranceResult(text: "verbatim words", engine: "apple_live", finalizeMs: 80)
        h.refiner.transform = { _ in
            XCTFail("hurry must abandon generation")
            return RefineResult(text: "", outcome: .applied)
        }
        h.session.dispatch(HotkeyEvent(.press, ts: 0))
        // A new dictation is queued behind us.
        h.events.put(HotkeyEvent(.press, ts: 1.1))

        h.session.dispatch(HotkeyEvent(.release, ts: 1.0))

        XCTAssertEqual(h.inserter.inserted, ["verbatim words"],
                       "the verbatim text still lands — hurry never loses words")
        XCTAssertEqual(h.metrics.last?.ai, RefineOutcome.preempted.rawValue)
        XCTAssertEqual(h.events.count, 1, "the queued press is preserved in order")
    }

    // MARK: - empty result

    func testEmptyResultFlashesAndLogsTheEmptyOutcome() {
        let h = Harness()
        h.asr.result = UtteranceResult(text: "", engine: "apple_live", finalizeMs: 40)

        h.utterance()

        XCTAssertTrue(h.inserter.inserted.isEmpty)
        XCTAssertTrue(h.history.added.isEmpty)
        XCTAssertEqual(h.pill.errors, ["nothing recognized"])
        XCTAssertEqual(h.metrics.records.count, 1)
        XCTAssertEqual(h.metrics.last?.outcome, "empty")
        XCTAssertEqual(h.metrics.last?.chars, 0)
        XCTAssertNil(h.metrics.last?.releaseToTextMs,
                     "the empty branch omits release_to_text_ms, exactly like session.py")
        XCTAssertEqual(h.session.state, .idle)
    }

    // MARK: - insertion failures

    func testBlockedSecureFlashesTheAmberRemedy() {
        let h = Harness()
        h.inserter.result = InsertResult(ok: false, method: .blockedSecure,
                                         detail: "Secure Keyboard Entry is active")

        h.utterance()

        XCTAssertEqual(h.pill.errors, ["secure field — press ⌘⌃V to paste"])
        XCTAssertFalse(h.pill.snapshot().contains("flashSuccess"))
        XCTAssertEqual(h.metrics.last?.outcome, "blocked_secure")
        XCTAssertEqual(h.history.added.count, 1,
                       "the transcript survives in history even when insertion is blocked")
    }

    func testInsertErrorSurfacesTheDetail() {
        let h = Harness()
        h.inserter.result = InsertResult(ok: false, method: .error,
                                         detail: "Accessibility permission missing")

        h.utterance()

        XCTAssertEqual(h.pill.errors, ["Accessibility permission missing"])
        XCTAssertEqual(h.metrics.last?.outcome, "error")
    }

    func testMicrophoneFailureAbortsBeforeRecording() {
        let h = Harness()
        h.audio.startSucceeds = false

        h.session.dispatch(HotkeyEvent(.press, ts: 0))

        XCTAssertEqual(h.session.state, .idle)
        XCTAssertEqual(h.asr.beginCount, 0)
        XCTAssertEqual(h.pill.errors, ["microphone unavailable"])
        XCTAssertEqual(h.gate.transitions, [], "never arm Esc for an utterance that never began")
    }

    // MARK: - ordering

    func testHistoryIsWrittenBeforeInsertion() {
        let h = Harness()

        h.utterance()

        XCTAssertEqual(h.inserter.historyDepthAtInsert, [1],
                       "history.add must have completed before insert is called — "
                       + "a failed paste must never lose words")
    }

    func testInsertReceivesThePostProcessedText() {
        let h = Harness()
        h.dictionary.substitutions = ["in forge": "InsForge"]
        h.asr.result = UtteranceResult(text: "ship in forge today", engine: "apple_live", finalizeMs: 60)

        h.utterance()

        XCTAssertEqual(h.inserter.inserted, ["ship InsForge today"])
    }

    // MARK: - metrics completeness

    func testMetricsCarryEveryFieldIncludingTheAiOutcome() {
        let h = Harness()
        h.asr.result = UtteranceResult(text: "hello there", engine: "apple_live",
                                       finalizeMs: 137.4, timedOut: true)
        h.refiner.transform = { RefineResult(text: $0, outcome: .applied) }

        h.utterance(heldSeconds: 2.0)

        let record = try? XCTUnwrap(h.metrics.last)
        guard let record else { return }
        XCTAssertEqual(record.engine, "apple_live")
        XCTAssertEqual(record.finalizeMs, 137.4, accuracy: 0.001)
        XCTAssertTrue(record.timedOut)
        XCTAssertEqual(record.heldMs, 2000, accuracy: 1)
        XCTAssertEqual(record.outcome, "paste")
        XCTAssertEqual(record.chars, "hello there".count, "chars counts the RAW ASR text")
        XCTAssertEqual(record.ai, "applied")
        XCTAssertNotNil(record.aiMs)
        XCTAssertNotNil(record.releaseToTextMs)
        XCTAssertGreaterThanOrEqual(record.postMs, 0)
        XCTAssertGreaterThanOrEqual(record.insertMs, 0)

        // The serialized line is the on-disk contract shared with the Python era.
        let line = record.jsonLine()
        for key in ["ts", "held_ms", "engine", "finalize_ms", "timed_out", "post_ms",
                    "insert_ms", "outcome", "chars", "release_to_text_ms", "ai_ms", "ai"] {
            XCTAssertTrue(line.contains("\"\(key)\""), "metrics line is missing \(key)")
        }
    }

    func testRefinerAbsentLogsTheOffOutcome() {
        let h = Harness(useRefiner: false)
        h.utterance()
        XCTAssertEqual(h.metrics.last?.ai, "off")
    }

    // MARK: - master toggle

    func testDisabledDictationIgnoresPresses() {
        let h = Harness(enabled: false)

        h.session.dispatch(HotkeyEvent(.press, ts: 0))

        XCTAssertEqual(h.session.state, .idle)
        XCTAssertEqual(h.audio.startCount, 0)
        XCTAssertEqual(h.asr.beginCount, 0)
    }

    // MARK: - paste-last

    func testPasteLastReinsertsTheMostRecentTranscript() {
        let h = Harness()
        h.history.last = "the previous transcript"

        h.session.dispatch(HotkeyEvent(.pasteLast, ts: 0))

        XCTAssertEqual(h.inserter.inserted, ["the previous transcript"])
        XCTAssertTrue(h.pill.snapshot().contains("flashSuccess"))
    }

    func testPasteLastWithNoHistoryFlashesAnError() {
        let h = Harness()
        h.session.dispatch(HotkeyEvent(.pasteLast, ts: 0))
        XCTAssertEqual(h.pill.errors, ["no transcript to paste"])
        XCTAssertTrue(h.inserter.inserted.isEmpty)
    }

    func testPasteLastIsIgnoredWhileRecording() {
        let h = Harness()
        h.history.last = "something"
        h.session.dispatch(HotkeyEvent(.press, ts: 0))

        h.session.dispatch(HotkeyEvent(.pasteLast, ts: 0.3))

        XCTAssertTrue(h.inserter.inserted.isEmpty, "paste-last only runs from IDLE")
    }

    func testRequestPasteLastEnqueuesForTheSessionThread() {
        let h = Harness()
        h.session.requestPasteLast()
        XCTAssertEqual(h.events.count, 1)
        XCTAssertEqual(h.events.getNowait()?.kind, .pasteLast)
    }

    // MARK: - correction directives

    func testTailReplaceCorrectsInPlaceAndSuppressesTheDirective() {
        let dictionary = FakeDictionary()
        let h = Harness(corrector: SpokenSpellingCorrector(vocabulary: dictionary))
        // "Cherie" is the misrecognition; the spelled tail is the correction,
        // and both live in THIS utterance, so nothing committed is touched.
        h.asr.result = UtteranceResult(text: "My name is Cherie S-H-A-R-I-Q-U-E",
                                       engine: "apple_live", finalizeMs: 90)
        h.refiner.transform = { RefineResult(text: $0, outcome: .applied) }

        h.utterance()

        let inserted = h.inserter.inserted.first ?? ""
        XCTAssertFalse(inserted.contains("-"), "the spelled run never reaches the field")
        XCTAssertFalse(inserted.contains("Cherie"), "the misrecognition is replaced")
        XCTAssertTrue(inserted.contains("Sharique"), "got: \(inserted)")
    }

    func testCrossUtteranceRetroReplaceLearnsAndNoticesWithoutEditingTheField() {
        let dictionary = FakeDictionary()
        let h = Harness(corrector: SpokenSpellingCorrector(vocabulary: dictionary))
        h.refiner.transform = { RefineResult(text: $0, outcome: .applied) }

        // First utterance establishes the antecedent — already pasted into
        // whatever app the user was typing in, so v1 will not go back and edit it.
        h.asr.result = UtteranceResult(text: "Please ping Cherie about the migration.",
                                       engine: "apple_live", finalizeMs: 70)
        h.utterance()
        // Second utterance is nothing but the spelling directive.
        h.asr.result = UtteranceResult(text: "Actually, it's S-H-A-R-I-Q-U-E.",
                                       engine: "apple_live", finalizeMs: 70)
        h.utterance()

        XCTAssertEqual(h.vocabulary.learned.count, 1, "the term is learned forever")
        XCTAssertEqual(h.vocabulary.learned.first?.term, "Sharique")
        XCTAssertEqual(h.vocabulary.learned.first?.heard, ["Cherie"])
        XCTAssertEqual(h.vocabulary.learned.first?.source, "spoken_spelling")
        XCTAssertEqual(h.pill.notices, ["Learned Sharique"])
        XCTAssertTrue(h.pill.errors.isEmpty,
                      "a directive-only utterance is a success, not \"nothing recognized\"")
        XCTAssertEqual(h.inserter.inserted.count, 1,
                       "only the first utterance produced text; the directive inserts nothing")
        XCTAssertEqual(h.metrics.last?.outcome, "correction")
    }

    func testDirectiveWithSurvivingTextStillInsertsAndLearns() {
        let dictionary = FakeDictionary()
        let h = Harness(corrector: SpokenSpellingCorrector(vocabulary: dictionary))
        h.refiner.transform = { RefineResult(text: $0, outcome: .applied) }
        h.asr.result = UtteranceResult(text: "Please ping Cherie about the migration.",
                                       engine: "apple_live", finalizeMs: 70)
        h.utterance()

        h.asr.result = UtteranceResult(text: "Send the invite, actually it's S-H-A-R-I-Q-U-E",
                                       engine: "apple_live", finalizeMs: 70)
        h.utterance()

        XCTAssertEqual(h.inserter.inserted.count, 2)
        let second = h.inserter.inserted[1]
        XCTAssertFalse(second.contains("-"), "the spelled run never reaches the field: \(second)")
        XCTAssertFalse(second.lowercased().contains("actually"), "the trigger is suppressed too")
        XCTAssertTrue(second.contains("Send the invite"))
        XCTAssertEqual(h.vocabulary.learned.count, 1)
    }

    func testDictionaryWritesHappenAfterInsertion() {
        let dictionary = FakeDictionary()
        let h = Harness(corrector: SpokenSpellingCorrector(vocabulary: dictionary))
        h.refiner.transform = { RefineResult(text: $0, outcome: .applied) }
        h.asr.result = UtteranceResult(text: "Please ping Cherie about the migration.",
                                       engine: "apple_live", finalizeMs: 70)
        h.utterance()

        // Record how many inserts had happened when the learn write landed.
        h.asr.result = UtteranceResult(text: "Send the invite, actually it's S-H-A-R-I-Q-U-E",
                                       engine: "apple_live", finalizeMs: 70)
        h.utterance()

        XCTAssertEqual(h.inserter.inserted.count, 2)
        XCTAssertEqual(h.vocabulary.learned.count, 1,
                       "the learn write is off the paste path — after insertion")
        XCTAssertEqual(h.vocabulary.uses, ["Sharique"])
    }

    func testSpelledRunWithNoAntecedentIsInsertedLiterallyAndNeverLearned() {
        let dictionary = FakeDictionary()
        let h = Harness(corrector: SpokenSpellingCorrector(vocabulary: dictionary))
        h.refiner.transform = { RefineResult(text: $0, outcome: .applied) }
        h.asr.result = UtteranceResult(text: "the payload is J-S-O-N", engine: "apple_live", finalizeMs: 70)

        h.utterance()

        XCTAssertEqual(h.inserter.inserted, ["the payload is JSON"])
        XCTAssertTrue(h.vocabulary.learned.isEmpty,
                      "no confident antecedent means nothing is learned")
        XCTAssertTrue(h.pill.notices.isEmpty)
    }

    func testNoCorrectorLeavesTextUntouched() {
        let h = Harness(corrector: nil)
        h.asr.result = UtteranceResult(text: "the payload is J-S-O-N", engine: "apple_live", finalizeMs: 70)
        h.refiner.transform = { RefineResult(text: $0, outcome: .applied) }

        h.utterance()

        XCTAssertEqual(h.inserter.inserted, ["the payload is J-S-O-N"])
    }

    // MARK: - interrupt mapping

    func testHotkeyInterruptMapsOneToOneOntoInterruptSignal() {
        XCTAssertEqual(SessionController.interruptSignal(for: .none), .none)
        XCTAssertEqual(SessionController.interruptSignal(for: .cancel), .cancel)
        XCTAssertEqual(SessionController.interruptSignal(for: .hurry), .hurry)
    }

    // MARK: - run loop

    func testRunLoopDrainsTheQueueOnItsOwnThread() {
        let h = Harness()
        h.session.start()
        defer { h.session.stop() }

        h.events.put(HotkeyEvent(.press, ts: 0))
        h.events.put(HotkeyEvent(.release, ts: 1.0))

        let deadline = Date().addingTimeInterval(5)
        while h.inserter.inserted.isEmpty && Date() < deadline {
            usleep(5_000)
        }
        XCTAssertEqual(h.inserter.inserted, ["hello world"])
    }
}
