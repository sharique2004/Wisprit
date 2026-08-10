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
             debounceMs: Double = 150,
             reconcile: Bool = false,
             vocabularyRetro: Bool = true,
             context: FakeContext? = nil,
             // Swap in a different pill for the tests whose subject is what the
             // bubble renders rather than which calls it received.
             pillPort: (any PillPort)? = nil) {
            inserter.history = history
            inserter.asr = asr
            session = SessionController(
                events: events,
                asr: asr,
                audio: audio,
                inserter: inserter,
                history: history,
                metrics: metrics,
                refiner: useRefiner ? refiner : nil,
                pill: pillPort ?? pill,
                vocabulary: vocabulary,
                corrections: dictionary,
                corrector: corrector,
                gate: gate,
                context: context,
                configuration: SessionController.Configuration(
                    holdDebounceMs: { debounceMs },
                    isEnabled: { enabled },
                    // The ticker and the reconciliation pass both spawn
                    // background work; off here so assertions stay deterministic.
                    levelTickInterval: nil,
                    reconcileVocabulary: reconcile,
                    vocabularyRetro: { vocabularyRetro }))
            inserter.deferredLabel = { [weak session] in session?.deferredLabel }
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

    // MARK: - live self-correction

    /// The feature, on the surface that shows it when the field cannot: the
    /// bubble says "friday" while the user is still holding the key.
    func testTheSelfCorrectionReachesThePillBubbleWhileTheUserIsStillSpeaking() {
        let pill = ModelPill()
        let h = Harness(pillPort: pill)

        h.session.dispatch(HotkeyEvent(.press, ts: 0))
        for partial in LiveCorrectionScript.partials { h.asr.deliverPartial(partial) }

        XCTAssertEqual(pill.bubble, "x on friday",
                       "the rendered tail — PartialTail's window over the corrected text")
        XCTAssertEqual(pill.partials.last, LiveCorrectionScript.corrected)
        XCTAssertFalse(pill.bubble.contains("thuersday"))
        // Verbatim-first: every partial before the marker completes is passed
        // through untouched, because until "actually friday" lands there is no
        // unambiguous correction to make.
        XCTAssertEqual(Array(pill.partials.dropLast()),
                       Array(LiveCorrectionScript.partials.dropLast()))
    }

    /// Partials arrive cumulatively-windowed and are corrected from scratch each
    /// time, so the same partial twice is the same tail twice — no flicker, no
    /// second bite at an already-resolved correction.
    func testRepeatingThePartialLeavesTheCorrectedTailWhereItIs() {
        let pill = ModelPill()
        let h = Harness(pillPort: pill)

        h.session.dispatch(HotkeyEvent(.press, ts: 0))
        for partial in LiveCorrectionScript.partials { h.asr.deliverPartial(partial) }
        h.asr.deliverPartial(LiveCorrectionScript.partials[3])
        h.asr.deliverPartial(LiveCorrectionScript.corrected)

        XCTAssertEqual(pill.bubble, "x on friday")
        XCTAssertEqual(pill.partials.suffix(3),
                       [LiveCorrectionScript.corrected, LiveCorrectionScript.corrected,
                        LiveCorrectionScript.corrected])
    }

    /// The regression that matters: the preview is a preview. Finalize re-runs
    /// the whole pipeline on the RAW final, so the corrected display text must
    /// not reach the corrections/refine input, history, or `raw_chars`.
    func testTheDisplayedCorrectionNeverLeaksIntoTheFinalizedText() {
        let raw = "I want to have a meeting with person x on thuersday umm no actually friday"
        let pill = ModelPill()
        let h = Harness(pillPort: pill)
        h.asr.result = UtteranceResult(text: raw, engine: "apple_live", finalizeMs: 130)

        h.session.dispatch(HotkeyEvent(.press, ts: 0))
        for partial in LiveCorrectionScript.partials { h.asr.deliverPartial(partial) }
        h.session.dispatch(HotkeyEvent(.release, ts: 1.0))

        XCTAssertEqual(h.refiner.lastInput, raw,
                       "refine is handed what the engine heard, not what the pill showed")
        XCTAssertEqual(h.metrics.last?.rawChars, raw.count)
        XCTAssertEqual(h.metrics.last?.chars, raw.count)
        // …and the finalize pass makes the same correction on its own, from the
        // raw text, which is why nothing was lost by keeping the display out of it.
        XCTAssertEqual(h.inserter.inserted,
                       ["I want to have a meeting with person x on friday"])
        XCTAssertEqual(h.history.added.map(\.text), h.inserter.inserted)
    }

    /// The budget. A pathological partial is shown verbatim rather than scanned
    /// on the session thread; finalize still fixes it.
    func testAPathologicalPartialIsShownVerbatimRatherThanCorrected() {
        let h = Harness()
        let filler = String(repeating: "word ", count: 500)     // 2 500 characters
        let tail = "on thuersday umm no actually friday"
        h.asr.partials = [filler + tail]

        h.session.dispatch(HotkeyEvent(.press, ts: 0))

        XCTAssertGreaterThan(filler.count + tail.count, LivePartialCorrection.maxCharacters)
        XCTAssertEqual(h.pill.partials, [filler + tail],
                       "past the cap the tail passes through untouched")
        XCTAssertEqual(LivePartialCorrection.display("on thuersday umm no actually friday"),
                       "on friday", "…and anything inside it is still corrected")
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
        XCTAssertEqual(h.pill.errors, ["Didn't hear anything — is the right mic selected?"],
                       "a full second of hold with nothing audible in it is a user who did "
                       + "not speak, and the pill now says so")
        XCTAssertEqual(h.metrics.records.count, 1)
        XCTAssertEqual(h.metrics.last?.outcome, "empty")
        XCTAssertEqual(h.metrics.last?.emptyReason, EmptyReason.silent.rawValue)
        XCTAssertEqual(h.metrics.last?.chars, 0)
        XCTAssertNil(h.metrics.last?.releaseToTextMs,
                     "the empty branch omits release_to_text_ms, exactly like session.py")
        XCTAssertEqual(h.session.state, .idle)
    }

    /// The whole point of `empty_reason`: one row per fault, and pill copy that
    /// tells the user which of them just happened.
    func testEmptyBranchNamesTheReasonAndSaysTheRightThing() {
        // Anything at or above the voiced threshold means the audio really did
        // contain speech; MetricsSummary restates the engine's constant.
        let voiced = Float(MetricsSummary.voicedPeakThreshold) + 0.1
        let cases: [(reason: EmptyReason, result: UtteranceResult, heldSeconds: Double,
                     error: String?, notice: String?)] = [
            (.starved,
             UtteranceResult(text: "", engine: "apple_live", finalizeMs: 1500, starvedInput: true),
             2.0, "Microphone delivered no audio", nil),
            (.silent,
             UtteranceResult(text: "", engine: "apple_live", finalizeMs: 40, peakLevel: 0.001),
             2.0, "Didn't hear anything — is the right mic selected?", nil),
            (.shortHold,
             UtteranceResult(text: "", engine: "apple_live", finalizeMs: 40, peakLevel: 0.001),
             0.4, nil, "Hold the key while you speak"),
            (.producedNothing,
             UtteranceResult(text: "", engine: "apple_live", finalizeMs: 40, peakLevel: voiced),
             2.0, "nothing recognized", nil),
            (.timedOut,
             UtteranceResult(text: "", engine: "apple_live", finalizeMs: 1500,
                             timedOut: true, peakLevel: voiced),
             2.0, "nothing recognized", nil),
            (.crashed,
             UtteranceResult(text: "", engine: "apple_live", finalizeMs: 12,
                             crashed: true, peakLevel: voiced),
             2.0, "nothing recognized", nil),
        ]

        for c in cases {
            let h = Harness()
            h.asr.result = c.result

            h.utterance(heldSeconds: c.heldSeconds)

            XCTAssertEqual(h.metrics.last?.outcome, "empty", "\(c.reason)")
            XCTAssertEqual(h.metrics.last?.emptyReason, c.reason.rawValue, "\(c.reason)")
            XCTAssertEqual(h.pill.errors, c.error.map { [$0] } ?? [], "\(c.reason)")
            XCTAssertEqual(h.pill.notices, c.notice.map { [$0] } ?? [], "\(c.reason)")
        }
    }

    func testTextThatSurvivesAsrButNotTheCleanupHasNoEmptyReason() {
        let h = Harness()
        h.asr.result = UtteranceResult(text: "um", engine: "apple_live", finalizeMs: 40,
                                       peakLevel: 0.5)

        h.utterance()

        XCTAssertEqual(h.metrics.last?.outcome, "empty")
        XCTAssertNil(h.metrics.last?.emptyReason,
                     "the engine did produce text — nothing about it is unexplained")
        XCTAssertEqual(h.pill.errors, ["nothing recognized"])
    }

    // MARK: - insertion failures

    /// `blocked_secure` gets its own pill state (§2.4) rather than an error
    /// flash: nothing failed, the text is in history, and ⌘⌃V is a remedy the
    /// user can still act on — which needs longer on screen than an alarm.
    func testBlockedSecureRaisesItsOwnPillStateNotAnError() {
        let h = Harness()
        h.inserter.result = InsertResult(ok: false, method: .blockedSecure,
                                         detail: "Secure Keyboard Entry is active")

        h.utterance()

        XCTAssertTrue(h.pill.snapshot().contains("flashBlockedSecure"))
        XCTAssertTrue(h.pill.errors.isEmpty, "a blocked paste is not a failure to report")
        XCTAssertFalse(h.pill.snapshot().contains("flashSuccess"))
        XCTAssertEqual(h.metrics.last?.outcome, "blocked_secure")
        XCTAssertEqual(h.history.added.count, 1,
                       "the transcript survives in history even when insertion is blocked")
    }

    // MARK: - the two new stage states (§2.4)

    /// The pill goes up on key-down, before the microphone opens: `audio.start()`
    /// plus the analyzer's prepare is tens of milliseconds in which the user has
    /// pressed a key and seen nothing at all.
    func testPrewarmingIsShownBeforeAudioStarts() {
        let h = Harness()
        h.session.dispatch(HotkeyEvent(.press, ts: 0))

        let calls = h.pill.snapshot()
        guard let prewarm = calls.firstIndex(of: "showPrewarming"),
              let recording = calls.firstIndex(of: "showRecording") else {
            return XCTFail("both states must appear: \(calls)")
        }
        XCTAssertLessThan(prewarm, recording, "prewarming precedes the recording state")
        XCTAssertEqual(h.audio.startCount, 1)
    }

    /// A microphone that will not open must not leave a pill hanging in
    /// prewarming — the error flash takes over.
    func testAFailedMicrophoneReplacesPrewarmingWithTheError() {
        let h = Harness()
        h.audio.startSucceeds = false

        h.session.dispatch(HotkeyEvent(.press, ts: 0))

        XCTAssertEqual(h.pill.snapshot(), ["showPrewarming", "flashError"])
        XCTAssertEqual(h.pill.errors, ["microphone unavailable"])
    }

    func testRefiningIsShownForTheAiStageAndOnlyWhenThereIsOne() {
        let withAi = Harness()
        withAi.utterance()
        let calls = withAi.pill.snapshot()
        guard let finalizing = calls.firstIndex(of: "showFinalizing"),
              let refining = calls.firstIndex(of: "showRefining") else {
            return XCTFail("both stages must appear: \(calls)")
        }
        XCTAssertLessThan(finalizing, refining, "refine runs after the final lands")

        let withoutAi = Harness(useRefiner: false)
        withoutAi.utterance()
        XCTAssertFalse(withoutAi.pill.snapshot().contains("showRefining"),
                       "no refine pass, no refining state")
    }

    /// A tap under the debounce writes no metrics row and leaves no pill: the
    /// prewarm flash must not survive an utterance that never happened.
    func testASubDebounceTapTakesThePrewarmBackDown() {
        let h = Harness(debounceMs: 150)
        h.utterance(heldSeconds: 0.05)

        XCTAssertEqual(h.pill.snapshot(), ["showPrewarming", "showRecording", "hide"])
        XCTAssertTrue(h.metrics.records.isEmpty)
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

        // A first observation of a brand-new term is QUARANTINED, not made live
        // vocabulary — a second spelling (or the user) promotes it. This is the
        // plausibility gate's core guarantee against one-shot pollution.
        XCTAssertEqual(h.vocabulary.learned.count, 0,
                       "a single observation never creates live vocabulary")
        XCTAssertEqual(h.vocabulary.pending.count, 1)
        XCTAssertEqual(h.vocabulary.pending.first?.term, "Sharique")
        XCTAssertEqual(h.vocabulary.pending.first?.observation, "Cherie")
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
        XCTAssertEqual(h.vocabulary.pending.count, 1, "first observation quarantines")
        XCTAssertEqual(h.vocabulary.learned.count, 0)
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
        XCTAssertEqual(h.vocabulary.pending.count, 1,
                       "the learn write is off the paste path — after insertion")
        XCTAssertEqual(h.vocabulary.uses, [],
                       "a quarantined term is not live vocabulary, so no use is recorded")
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

    // MARK: - telemetry fields

    func testEveryRowCarriesPeakLevelAndAudioMs() {
        let h = Harness()
        h.asr.result = UtteranceResult(text: "hello there", engine: "apple_live",
                                       finalizeMs: 20, peakLevel: 0.42)
        h.asr.retainedPcm = Data(count: 32_000)         // 1.0 s of 16 kHz mono Int16

        h.utterance()

        let record = try? XCTUnwrap(h.metrics.last)
        guard let record else { return }
        XCTAssertEqual(record.peakLevel ?? -1, 0.42, accuracy: 1e-6)
        XCTAssertEqual(record.audioMs ?? -1, 1000, accuracy: 0.001)
        XCTAssertEqual(record.rawChars, record.chars, "raw_chars restates chars for the new schema")
    }

    func testRefineDeltaIsWrittenOnlyWhenRefineRan() {
        let h = Harness()
        h.asr.result = UtteranceResult(text: "hello there", engine: "apple_live", finalizeMs: 20)
        h.refiner.transform = { RefineResult(text: $0 + "!", outcome: .applied) }

        h.utterance()

        XCTAssertEqual(h.metrics.last?.refineDelta, 1, "one character moved")

        let off = Harness(useRefiner: false)
        off.asr.result = UtteranceResult(text: "hello there", engine: "apple_live",
                                         finalizeMs: 20, peakLevel: 0.3)

        off.utterance()

        XCTAssertNil(off.metrics.last?.refineDelta, "no refine stage, no delta to report")
        XCTAssertEqual(off.metrics.last?.peakLevel ?? -1, 0.3, accuracy: 1e-6,
                       "peak_level rides every row, refine or not")
    }

    func testRefineDeltaCountsCharactersAndIsZeroForAVerbatimPass() {
        XCTAssertEqual(SessionController.refineDelta(raw: "same", refined: "same"), 0)
        XCTAssertEqual(SessionController.refineDelta(raw: "teh cat", refined: "the cat"), 2)
        XCTAssertEqual(SessionController.refineDelta(raw: "", refined: "added"), 5)
    }

    // MARK: - retention race

    func testNoReconcileRunsBeforeInsertion() {
        let h = Harness(reconcile: true)
        // A reconciliation that WOULD propose a retro edit: the ordering claim is
        // only worth anything when there is something to have run early.
        h.asr.result = UtteranceResult(text: "Ping the in forge team about the migration.",
                                       engine: "apple_live", finalizeMs: 70)
        h.asr.reconciliation = VocabularyReconciliation(
            transcript: "Ping the InsForge team about the migration.",
            termHits: ["InsForge": 1], termCount: 1, elapsedMs: 1100)

        h.utterance()

        XCTAssertEqual(h.inserter.reconcileDepthAtInsert, [0],
                       "the vocabulary pass costs seconds — none of it may run before the "
                       + "text reaches the field")
        XCTAssertEqual(h.inserter.deferredAtInsert, [nil],
                       "…and neither may anything it wants to do afterwards")
        // …but it does run, off the path, or the assertion above proves nothing.
        let deadline = Date().addingTimeInterval(5)
        while h.asr.reconcileTally == 0 && Date() < deadline { usleep(5_000) }
        XCTAssertEqual(h.asr.reconcileTally, 1)
    }

    // MARK: - vocabulary retro-correction, off the input-method rungs

    /// Waits for the reconciliation to park its plan, then drains it.
    private func drainVocabRetro(_ h: Harness, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(5)
        while h.session.deferredLabel != "vocab-retro" && Date() < deadline { usleep(2_000) }
        XCTAssertEqual(h.session.deferredLabel, "vocab-retro", file: file, line: line)
        h.session.drainDeferred()
    }

    private func armRetro(_ h: Harness) {
        h.asr.result = UtteranceResult(text: "Ping the in forge team about the migration.",
                                       engine: "apple_live", finalizeMs: 70)
        h.asr.reconciliation = VocabularyReconciliation(
            transcript: "Ping the InsForge team about the migration.",
            termHits: ["InsForge": 1], termCount: 1, elapsedMs: 1100)
    }

    /// With no live-typing port at all — the Phase-1 shape — every rung is a
    /// paste, so the only honest thing to do with a recovered term is learn it.
    func testWithoutAnInputMethodTheFixDegradesToLearningTheTerm() {
        let h = Harness(reconcile: true)
        armRetro(h)
        h.vocabulary.known = ["InsForge"]

        h.utterance()
        drainVocabRetro(h)

        XCTAssertEqual(h.inserter.inserted, ["Ping the in forge team about the migration."],
                       "the document is left exactly as the user has it")
        XCTAssertEqual(h.vocabulary.learned,
                       [LearnedTerm(term: "InsForge", heard: ["in forge"], source: "vocab_retro")])
        XCTAssertEqual(h.pill.notices, ["Learned InsForge"])
    }

    func testTheSettingSuppressesPlanningEntirely() {
        let h = Harness(reconcile: true, vocabularyRetro: false)
        armRetro(h)
        h.vocabulary.known = ["InsForge"]

        h.utterance()
        let deadline = Date().addingTimeInterval(5)
        while h.asr.reconcileTally == 0 && Date() < deadline { usleep(2_000) }
        while h.metrics.records.count < 2 && Date() < deadline { usleep(2_000) }

        XCTAssertNil(h.session.deferredLabel)
        XCTAssertTrue(h.vocabulary.learned.isEmpty)
        XCTAssertEqual(h.vocabulary.uses, ["InsForge"], "recordUse is not what the flag gates")
        XCTAssertEqual(h.metrics.records.last?.vocabDelta, 0)
    }

    /// An utterance that inserted nothing has nothing in the field to correct,
    /// however much the biased pass recovered from its audio. The pure spelling
    /// directive — the `outcome: "correction"` branch — is that utterance.
    func testACorrectionUtteranceWithNothingToInsertPlansNothing() {
        let dictionary = FakeDictionary()
        let h = Harness(corrector: SpokenSpellingCorrector(vocabulary: dictionary), reconcile: true)
        h.refiner.transform = { RefineResult(text: $0, outcome: .applied) }
        h.asr.reconciliation = VocabularyReconciliation(
            transcript: "Actually, it's Sharique.", termHits: ["Sharique": 1],
            termCount: 1, elapsedMs: 800)

        h.asr.result = UtteranceResult(text: "Please ping Cherie about the migration.",
                                       engine: "apple_live", finalizeMs: 70)
        h.utterance()
        h.asr.result = UtteranceResult(text: "Actually, it's S-H-A-R-I-Q-U-E.",
                                       engine: "apple_live", finalizeMs: 70)
        h.utterance()

        let deadline = Date().addingTimeInterval(5)
        while h.metrics.records.filter({ $0.outcome == "vocab_retro" }).count < 2
            && Date() < deadline { usleep(2_000) }

        XCTAssertTrue(h.metrics.records.contains { $0.outcome == "correction" })
        XCTAssertEqual(h.metrics.records.filter { $0.outcome == "vocab_retro" }.map(\.vocabDelta),
                       [0, 0], "neither pass had anything in the field to plan against")
        XCTAssertNil(h.session.deferredLabel)
    }

    func testReconcileKeepsTheUtteranceItWasSpawnedFor() {
        let h = Harness(reconcile: true)
        let first = Data(repeating: 1, count: 32_000)
        let second = Data(repeating: 2, count: 16_000)
        let entered = expectation(description: "the reconcile pass started")
        h.asr.onReconcileEnter = { entered.fulfill() }
        h.asr.parkReconciles = true
        h.asr.retainedPcm = first

        h.utterance()
        wait(for: [entered], timeout: 5)

        // A second Fn press inside the 0.5–2.5 s reconcile window: this is the
        // race. The engine's live retention buffer now holds the NEW utterance.
        h.asr.retainedPcm = second
        h.session.dispatch(HotkeyEvent(.press, ts: 2))
        h.asr.releaseReconciles()

        let deadline = Date().addingTimeInterval(5)
        while h.asr.reconcileLog.isEmpty && Date() < deadline { usleep(5_000) }
        let calls = h.asr.reconcileLog
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.retained.id, 1, "utterance 1's pass, utterance 1's id")
        XCTAssertEqual(calls.first?.retained.pcm, first,
                       "the pass transcribes the audio snapshotted at ITS finalize")
        XCTAssertEqual(calls.first?.live, second,
                       "…and the live buffer had genuinely moved on by then")
    }

    // MARK: - deferred work

    func testDeferredWorkRunsOnlyOnceTheMachineIsIdle() {
        let h = Harness()
        let ran = Recorder<String>()

        h.session.dispatch(HotkeyEvent(.press, ts: 0))
        h.session.enqueueDeferred("retro") { ran.append("retro") }
        h.session.drainDeferred()
        XCTAssertEqual(ran.values, [], "never mid-utterance")

        h.session.dispatch(HotkeyEvent(.release, ts: 1.0))
        h.session.drainDeferred()
        XCTAssertEqual(ran.values, ["retro"])

        h.session.drainDeferred()
        XCTAssertEqual(ran.values, ["retro"], "the slot is consumed, not repeated")
    }

    func testEnqueueingDeferredWorkReplacesThePendingSlot() {
        let h = Harness()
        let ran = Recorder<String>()

        h.session.enqueueDeferred("stale") { ran.append("stale") }
        h.session.enqueueDeferred("fresh") { ran.append("fresh") }
        h.session.drainDeferred()

        XCTAssertEqual(ran.values, ["fresh"], "one slot: the newer reconciliation wins")
    }

    func testANewUtteranceDropsPendingDeferredWork() {
        let h = Harness()
        let ran = Recorder<String>()
        h.session.enqueueDeferred("stale") { ran.append("stale") }

        h.utterance()
        h.session.drainDeferred()

        XCTAssertEqual(ran.values, [],
                       "an edit planned against the previous utterance's document must never "
                       + "land after the next one")
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
