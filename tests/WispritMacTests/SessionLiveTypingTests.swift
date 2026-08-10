import XCTest
import WispritCorrections
import WispritEngine
import WispritIMProtocol
import WispritKit
import WispritMacInput
import WispritPersistence
import WispritRefine
@testable import WispritMac

/// The session state machine wired to the input-method rungs, end to end.
///
/// The "input method" is `FakeIMPeer` — a real generation gate and a real
/// document string in this process. Nothing touches an input source, a text
/// field, the pasteboard or `~/.wisprit`.
final class SessionLiveTypingTests: XCTestCase {

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
        let peer = FakeIMPeer()
        let cache = BundleCapabilityCache()
        let live: LiveTypingSession
        let session: SessionController

        init(corrector: SpokenSpellingCorrector? = nil,
             liveTypingEnabled: Bool = true,
             reconcile: Bool = false,
             vocabularyRetro: Bool = true) {
            inserter.history = history
            inserter.asr = asr
            let peer = self.peer
            live = LiveTypingSession(
                peer: peer,
                cache: cache,
                counter: IMGenerationCounter(seed: 500),
                configuration: LiveTypingConfiguration(
                    isEnabled: { liveTypingEnabled },
                    frontmostBundleID: { "com.apple.TextEdit" }))
            live.start()
            refiner.transform = { RefineResult(text: $0, outcome: .applied) }
            session = SessionController(
                events: events,
                asr: asr,
                audio: audio,
                inserter: inserter,
                history: history,
                metrics: metrics,
                refiner: refiner,
                pill: pill,
                vocabulary: vocabulary,
                corrections: dictionary,
                corrector: corrector,
                gate: gate,
                liveTyping: live,
                configuration: SessionController.Configuration(
                    holdDebounceMs: { 150 },
                    levelTickInterval: nil,
                    reconcileVocabulary: reconcile,
                    vocabularyRetro: { vocabularyRetro }))
            inserter.deferredLabel = { [weak session] in session?.deferredLabel }
        }

        func utterance(heldSeconds: Double = 1.0) {
            session.dispatch(HotkeyEvent(.press, ts: 0))
            session.dispatch(HotkeyEvent(.release, ts: heldSeconds))
        }

        /// Block until the detached reconciliation has parked its plan. The pass
        /// runs 0.5–2.5 s after insertion in reality, so there is nothing to
        /// synchronize on but the slot it fills.
        func waitForDeferred(file: StaticString = #filePath, line: UInt = #line) {
            let deadline = Date().addingTimeInterval(5)
            while session.deferredLabel != "vocab-retro" && Date() < deadline { usleep(2_000) }
            XCTAssertEqual(session.deferredLabel, "vocab-retro",
                           "the reconciliation never parked a plan", file: file, line: line)
        }

        /// Block until the pass has written its `vocab_retro` row.
        func waitForVocabRow(file: StaticString = #filePath, line: UInt = #line) -> MetricsRecord? {
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                if let row = metrics.records.last(where: { $0.outcome == "vocab_retro" }) {
                    return row
                }
                usleep(2_000)
            }
            XCTFail("no vocab_retro row was written", file: file, line: line)
            return nil
        }
    }

    /// The utterance the retro-correction tests all use: the live engine heard
    /// "in forge", the biased pass heard the dictionary term.
    private static let liveText = "Ping the in forge team about the migration."
    private static let reconciledText = "Ping the InsForge team about the migration."

    private func arm(_ h: Harness) {
        h.asr.result = UtteranceResult(text: Self.liveText, engine: "apple_live", finalizeMs: 70)
        h.asr.reconciliation = VocabularyReconciliation(
            transcript: Self.reconciledText, termHits: ["InsForge": 1],
            termCount: 1, elapsedMs: 1240.4)
    }

    // MARK: - rung 1: streaming into the field

    func testTextGoesIntoTheFieldAndTheClipboardIsNeverTouched() {
        let h = Harness()
        h.asr.result = UtteranceResult(text: "hello world", engine: "apple_live", finalizeMs: 90)
        h.asr.partials = ["hello", "hello wor"]

        h.utterance()

        XCTAssertEqual(h.peer.snapshot.document, "hello world",
                       "rung 1 committed the final text through the input method")
        XCTAssertTrue(h.inserter.inserted.isEmpty, "the paste rung was never reached")
        XCTAssertEqual(h.metrics.last?.outcome, "im_streaming")
        XCTAssertEqual(h.history.addedCount, 1, "history is still written before insertion")
    }

    func testPartialsAreStreamedAsMarkedTextAndTheBubbleIsSuppressed() {
        let h = Harness()
        h.asr.partials = ["the quick", "the quick brown"]

        h.session.dispatch(HotkeyEvent(.press, ts: 0))

        XCTAssertEqual(h.peer.count(of: "update_volatile"), 2)
        XCTAssertEqual(h.peer.snapshot.marked, "the quick brown")
        XCTAssertTrue(h.pill.partials.isEmpty,
                      "the bubble is suppressed while the words are appearing in the field")
    }

    func testThePillKeepsThePreviewWhenLiveTypingIsOff() {
        let h = Harness(liveTypingEnabled: false)
        h.asr.partials = ["the quick", "the quick brown"]

        h.session.dispatch(HotkeyEvent(.press, ts: 0))

        XCTAssertEqual(h.pill.partials, ["the quick", "the quick brown"])
        XCTAssertEqual(h.peer.commandNames, [], "no input source was touched at all")
    }

    func testTheBubbleComesBackTheInstantTheClientIsLost() {
        let h = Harness()
        h.asr.partials = ["first partial"]
        h.session.dispatch(HotkeyEvent(.press, ts: 0))
        XCTAssertTrue(h.pill.partials.isEmpty)

        h.peer.loseClient()

        // The partial routing is re-evaluated per partial, so the preview lands
        // back on the pill without waiting for the next utterance.
        h.asr.partials = ["second partial"]
        h.session.dispatch(HotkeyEvent(.release, ts: 1.0))
        h.session.dispatch(HotkeyEvent(.press, ts: 2.0))
        XCTAssertEqual(h.pill.partials, ["second partial"])
    }

    // MARK: - live self-correction, in the field

    /// The feature, on rung 1: the words the user is watching appear, the
    /// misspoken weekday disappears, and none of it has been committed yet.
    func testTheSelfCorrectionLandsInTheMarkedTextWhileTheUserIsStillSpeaking() {
        let h = Harness()

        h.session.dispatch(HotkeyEvent(.press, ts: 0))
        for partial in LiveCorrectionScript.partials { h.asr.deliverPartial(partial) }

        XCTAssertEqual(h.peer.snapshot.marked, LiveCorrectionScript.corrected)
        XCTAssertEqual(h.peer.snapshot.document, "",
                       "the tail is still provisional — nothing is committed until Fn ↑")
        XCTAssertTrue(h.pill.partials.isEmpty, "one preview, not two")
        // Verbatim until the marker completes, exactly as the bubble shows it.
        XCTAssertEqual(h.peer.volatileTails,
                       LiveCorrectionScript.partials.dropLast() + [LiveCorrectionScript.corrected])
    }

    /// The commit is the raw final's turn through the whole pipeline, not the
    /// corrected tail the field is already showing.
    func testTheCommittedTextComesFromTheRawFinalNotTheDisplayedTail() {
        let h = Harness()
        let raw = "I want to have a meeting with person x on thuersday umm no actually friday"
        h.asr.result = UtteranceResult(text: raw, engine: "apple_live", finalizeMs: 130)

        h.session.dispatch(HotkeyEvent(.press, ts: 0))
        for partial in LiveCorrectionScript.partials { h.asr.deliverPartial(partial) }
        h.session.dispatch(HotkeyEvent(.release, ts: 1.0))

        XCTAssertEqual(h.peer.snapshot.document,
                       "I want to have a meeting with person x on friday",
                       "capitalised as the engine said it — the preview never edited the record")
        XCTAssertEqual(h.peer.snapshot.marked, "")
        XCTAssertEqual(h.refiner.lastInput, raw)
        XCTAssertEqual(h.metrics.last?.rawChars, raw.count)
        XCTAssertEqual(h.metrics.last?.outcome, "im_streaming")
    }

    // MARK: - falling off the ladder

    func testClientLostMidUtteranceFallsBackToPasteWithoutLosingText() {
        let h = Harness()
        h.asr.result = UtteranceResult(text: "hello world", engine: "apple_live", finalizeMs: 90)
        h.asr.partials = ["hello"]

        h.session.dispatch(HotkeyEvent(.press, ts: 0))
        h.peer.loseClient()                       // focus change while speaking
        h.session.dispatch(HotkeyEvent(.release, ts: 1.0))

        XCTAssertEqual(h.inserter.inserted, ["hello world"], "the paste rung caught it")
        XCTAssertEqual(h.peer.snapshot.document, "", "and it was not also written to the field")
        XCTAssertEqual(h.metrics.last?.outcome, "paste")
        XCTAssertEqual(h.history.addedCount, 1)
        XCTAssertEqual(h.inserter.historyDepthAtInsert, [1],
                       "history-before-insert survives the downgrade")
    }

    func testInputMethodGoingAwayEntirelyStillDeliversTheText() {
        let h = Harness()
        h.asr.result = UtteranceResult(text: "hello world", engine: "apple_live", finalizeMs: 90)
        h.session.dispatch(HotkeyEvent(.press, ts: 0))
        h.peer.reachable = false                  // the process died

        h.session.dispatch(HotkeyEvent(.release, ts: 1.0))

        XCTAssertEqual(h.inserter.inserted, ["hello world"])
        XCTAssertEqual(h.metrics.last?.outcome, "paste")
    }

    func testRefusedCommitDowngradesTheBundleAndPastesInstead() {
        let h = Harness()
        h.peer.insertWorks = false
        h.asr.result = UtteranceResult(text: "hello world", engine: "apple_live", finalizeMs: 90)

        h.utterance()

        XCTAssertEqual(h.inserter.inserted, ["hello world"])
        XCTAssertEqual(h.cache.verdict(for: "com.apple.TextEdit"), .unsupported)
        XCTAssertEqual(h.metrics.last?.outcome, "paste")
    }

    // MARK: - the provisional tail is always cleaned up

    func testEscDuringRecordingTakesTheMarkedTailBackDown() {
        let h = Harness()
        h.asr.partials = ["half a th"]
        h.session.dispatch(HotkeyEvent(.press, ts: 0))
        XCTAssertEqual(h.peer.snapshot.marked, "half a th")

        h.session.dispatch(HotkeyEvent(.esc, ts: 0.5))

        XCTAssertEqual(h.peer.snapshot.marked, "", "the field is left exactly as it was")
        XCTAssertEqual(h.peer.snapshot.document, "")
    }

    func testASubDebounceBrushLeavesNothingBehind() {
        let h = Harness()
        h.asr.partials = ["oh"]
        h.session.dispatch(HotkeyEvent(.press, ts: 0))
        h.session.dispatch(HotkeyEvent(.release, ts: 0.05))

        XCTAssertEqual(h.peer.snapshot.marked, "")
        XCTAssertEqual(h.peer.snapshot.document, "")
        XCTAssertTrue(h.metrics.records.isEmpty, "still no metrics row for a brush")
    }

    func testAnEmptyFinalClearsTheTailAndInsertsNothing() {
        let h = Harness()
        h.asr.partials = ["mm"]
        h.asr.result = UtteranceResult(text: "   ", engine: "apple_live", finalizeMs: 40)

        h.utterance()

        XCTAssertEqual(h.peer.snapshot.marked, "")
        XCTAssertEqual(h.peer.snapshot.document, "")
        XCTAssertEqual(h.metrics.last?.outcome, "empty")
    }

    // MARK: - cross-utterance retro replace, for real

    func testCrossUtteranceRetroReplaceRewritesTheWordInTheField() {
        let dictionary = FakeDictionary()
        let h = Harness(corrector: SpokenSpellingCorrector(vocabulary: dictionary))

        h.asr.result = UtteranceResult(text: "Please ping Cherie about the migration.",
                                       engine: "apple_live", finalizeMs: 70)
        h.utterance()
        XCTAssertEqual(h.peer.snapshot.document, "Please ping Cherie about the migration.")

        h.asr.result = UtteranceResult(text: "Actually, it's S-H-A-R-I-Q-U-E.",
                                       engine: "apple_live", finalizeMs: 70)
        h.utterance()

        XCTAssertEqual(h.peer.snapshot.document,
                       "Please ping Sharique about the migration.",
                       "the word already committed to the user's document was corrected in place")
        XCTAssertEqual(h.pill.notices, ["Fixed Sharique"],
                       "the notice says what actually happened, not just what was learned")
        XCTAssertEqual(h.vocabulary.pending.first?.term, "Sharique",
                       "learning still happens — quarantined until a second observation")
        XCTAssertEqual(h.vocabulary.pending.first?.observation, "Cherie")
        XCTAssertTrue(h.inserter.inserted.isEmpty, "no paste, no clipboard, no keystroke")
        XCTAssertEqual(h.metrics.last?.outcome, "correction")
    }

    func testRetroReplaceKeepsLearnAndNoticeWhenTheFieldCannotBeEdited() {
        // No TSMDocumentAccess: the replacement range would be silently dropped
        // and the correction appended. Rungs 3–5 behaviour is the honest answer.
        let dictionary = FakeDictionary()
        let h = Harness(corrector: SpokenSpellingCorrector(vocabulary: dictionary))
        h.peer.capabilities = IMClientCapabilities(
            supportsUnicode: true, bundleID: "com.example.legacy", supportsDocumentAccess: false)

        h.asr.result = UtteranceResult(text: "Please ping Cherie about the migration.",
                                       engine: "apple_live", finalizeMs: 70)
        h.utterance()
        h.asr.result = UtteranceResult(text: "Actually, it's S-H-A-R-I-Q-U-E.",
                                       engine: "apple_live", finalizeMs: 70)
        h.utterance()

        XCTAssertEqual(h.peer.snapshot.document, "Please ping Cherie about the migration.",
                       "the field is untouched rather than corrupted")
        XCTAssertEqual(h.pill.notices, ["Learned Sharique"])
        XCTAssertEqual(h.vocabulary.pending.count, 1,
                       "first observation quarantines rather than creating live vocabulary")
    }

    func testRetroReplaceWithLiveTypingOffIsUnchangedFromPhaseOne() {
        let dictionary = FakeDictionary()
        let h = Harness(corrector: SpokenSpellingCorrector(vocabulary: dictionary),
                        liveTypingEnabled: false)

        h.asr.result = UtteranceResult(text: "Please ping Cherie about the migration.",
                                       engine: "apple_live", finalizeMs: 70)
        h.utterance()
        h.asr.result = UtteranceResult(text: "Actually, it's S-H-A-R-I-Q-U-E.",
                                       engine: "apple_live", finalizeMs: 70)
        h.utterance()

        XCTAssertEqual(h.pill.notices, ["Learned Sharique"])
        XCTAssertEqual(h.inserter.inserted.count, 1)
        XCTAssertEqual(h.peer.commandNames, [])
    }

    // MARK: - vocabulary retro-correction

    func testAMisheardDictionaryTermIsFixedInTheFieldAfterTheFact() {
        let h = Harness(reconcile: true)
        arm(h)

        h.utterance()

        XCTAssertEqual(h.peer.snapshot.document, Self.liveText,
                       "the live text lands first, unchanged — nothing waits on the second engine")
        XCTAssertEqual(h.peer.count(of: "apply_edit"), 0,
                       "nothing retroactive happens before the text is in the field")

        h.waitForDeferred()
        XCTAssertEqual(h.peer.count(of: "apply_edit"), 0,
                       "…nor when the plan is ready: it is parked until the machine is idle")

        h.session.drainDeferred()

        XCTAssertEqual(h.peer.snapshot.document, Self.reconciledText,
                       "the word the user is looking at was corrected in place")
        XCTAssertEqual(h.pill.notices, ["Fixed InsForge"])
        XCTAssertTrue(h.vocabulary.learned.isEmpty,
                      "the field was fixed, so there is nothing to fall back to learning")
        XCTAssertTrue(h.inserter.inserted.isEmpty, "no paste, no clipboard, no keystroke")
    }

    func testTheRetroEditNeverRunsBeforeTheTextReachesTheField() {
        // The paste rung's half of the same promise: reconciliation and the work
        // it parks are both strictly after `inserter.insert`.
        let h = Harness(liveTypingEnabled: false, reconcile: true)
        arm(h)
        h.vocabulary.known = ["InsForge"]

        h.utterance()

        XCTAssertEqual(h.inserter.reconcileDepthAtInsert, [0])
        XCTAssertEqual(h.inserter.deferredAtInsert, [nil],
                       "no work was parked when the text was delivered")
    }

    func testAPasteRungLearnsTheMisrecognitionInsteadOfEditingTheDocument() {
        let h = Harness(liveTypingEnabled: false, reconcile: true)
        arm(h)
        h.vocabulary.known = ["InsForge"]

        h.utterance()
        h.waitForDeferred()
        h.session.drainDeferred()

        XCTAssertEqual(h.inserter.inserted, [Self.liveText],
                       "the text was pasted and is no longer ours to edit")
        XCTAssertEqual(h.vocabulary.learned,
                       [LearnedTerm(term: "InsForge", heard: ["in forge"], source: "vocab_retro")],
                       "the misrecognition becomes hear evidence on the term that already exists")
        XCTAssertEqual(h.pill.notices, ["Learned InsForge"])
    }

    /// The fallback's entire safety argument. A term the dictionary does not
    /// already hold is never created from a second engine's opinion — that is
    /// how the three junk canonical terms got written the first time.
    func testTheFallbackNeverCreatesACanonicalTermItOnlyAddsEvidence() {
        let h = Harness(liveTypingEnabled: false, reconcile: true)
        arm(h)
        h.vocabulary.known = []

        h.utterance()
        h.waitForDeferred()
        h.session.drainDeferred()

        XCTAssertTrue(h.vocabulary.learned.isEmpty)
        XCTAssertTrue(h.vocabulary.pending.isEmpty)
        XCTAssertTrue(h.pill.notices.isEmpty, "nothing was learned, so nothing is claimed")
    }

    func testTwoFixesInOneUtteranceStillFlashExactlyOneNotice() {
        let h = Harness(reconcile: true)
        let live = "We tested in forge then whisper it plus Monday morning with the whole team"
        h.asr.result = UtteranceResult(text: live, engine: "apple_live", finalizeMs: 70)
        h.asr.reconciliation = VocabularyReconciliation(
            transcript: "We tested InsForge then Wisprit plus Monday morning with the whole team",
            termHits: ["InsForge": 1, "Wisprit": 1], termCount: 2, elapsedMs: 900)

        h.utterance()
        h.waitForDeferred()
        h.session.drainDeferred()

        XCTAssertEqual(h.peer.snapshot.document,
                       "We tested InsForge then Wisprit plus Monday morning with the whole team")
        XCTAssertEqual(h.peer.count(of: "apply_edit"), 2)
        XCTAssertEqual(h.pill.notices, ["Fixed InsForge"],
                       "one notice per utterance, naming the first thing fixed")
    }

    func testANewUtteranceDropsAPlanThatHasNotBeenAppliedYet() {
        let h = Harness(reconcile: true)
        arm(h)

        h.utterance()
        h.waitForDeferred()

        // The user starts talking again inside the reconcile window. The document
        // the edit was planned against is about to stop being the current one.
        h.session.dispatch(HotkeyEvent(.press, ts: 2))
        h.session.dispatch(HotkeyEvent(.release, ts: 3))
        h.session.drainDeferred()

        XCTAssertEqual(h.peer.count(of: "apply_edit"), 0,
                       "a stale plan is dropped, never applied late")
        XCTAssertTrue(h.pill.notices.isEmpty)
    }

    func testTheSettingTurnsRetroCorrectionOffWithoutStoppingTheReconciliation() {
        let h = Harness(reconcile: true, vocabularyRetro: false)
        arm(h)

        h.utterance()
        let row = h.waitForVocabRow()

        XCTAssertEqual(h.session.deferredLabel, nil, "nothing is planned, so nothing is parked")
        XCTAssertEqual(h.peer.snapshot.document, Self.liveText)
        XCTAssertEqual(h.vocabulary.uses, ["InsForge"],
                       "the pass still runs — its usage bookkeeping is useful either way")
        XCTAssertEqual(row?.vocabDelta, 0)
    }

    // MARK: - the vocab_retro metrics row

    func testTheVocabRetroRowCarriesTheTimingHitsAndOutcome() {
        let h = Harness(reconcile: true)
        arm(h)

        h.utterance()
        h.waitForDeferred()
        h.session.drainDeferred()
        let row = h.waitForVocabRow()

        XCTAssertEqual(row?.outcome, "vocab_retro")
        XCTAssertEqual(row?.engine, "apple_dictation")
        XCTAssertEqual(row?.vocabMs ?? -1, 1240.4, accuracy: 0.001)
        XCTAssertEqual(row?.vocabHits, 1)
        XCTAssertEqual(row?.vocabDelta, 1)
        XCTAssertEqual(row?.applied, true)
        // It is its own line, not a rewrite of the utterance's.
        XCTAssertEqual(h.metrics.records.map(\.outcome), ["im_streaming", "vocab_retro"])
        XCTAssertNil(h.metrics.records.first?.vocabMs,
                     "the utterance row was on disk before the pass even started")
    }

    func testARefusedPlanStillReportsTheReconciliation() {
        let h = Harness(reconcile: true)
        h.asr.result = UtteranceResult(text: "Ping the InsForge team about the migration.",
                                       engine: "apple_live", finalizeMs: 70)
        h.asr.reconciliation = VocabularyReconciliation(
            transcript: "Ping the InsForge team about the migration.",
            termHits: ["InsForge": 2], termCount: 1, elapsedMs: 640)

        h.utterance()
        let row = h.waitForVocabRow()

        XCTAssertEqual(row?.vocabHits, 2)
        XCTAssertEqual(row?.vocabDelta, 0, "the planner proposed nothing")
        XCTAssertEqual(row?.applied, false)
        XCTAssertEqual(h.peer.count(of: "apply_edit"), 0)
    }

    func testSameUtteranceCorrectionNeverReachesTheInputMethod() {
        // The antecedent is in the pending text, so it is fixed before anything
        // is committed — there is nothing retroactive to do.
        let dictionary = FakeDictionary()
        let h = Harness(corrector: SpokenSpellingCorrector(vocabulary: dictionary))
        h.asr.result = UtteranceResult(text: "My name is Cherie S-H-A-R-I-Q-U-E",
                                       engine: "apple_live", finalizeMs: 90)

        h.utterance()

        XCTAssertEqual(h.peer.count(of: "apply_edit"), 0)
        XCTAssertTrue(h.peer.snapshot.document.contains("Sharique"))
        XCTAssertFalse(h.peer.snapshot.document.contains("Cherie"))
    }
}
