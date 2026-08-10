import XCTest
import WispritContext
import WispritCorrections
import WispritDictionary
import WispritEngine
import WispritIMProtocol
import WispritKit
import WispritMacInput
import WispritPersistence
import WispritRefine
@testable import WispritMac

/// Phase 5 end to end, with the fake input method: commit text, let the "user"
/// edit the field, re-read it at the next key-down / session close, and pin
/// what comes out the other side — the `edit_observed` metrics line, the
/// `PendingLearnStore` evidence, the propose notice at threshold, and the
/// silence everywhere honesty demands it.
///
/// Nothing here touches an input source, the pasteboard, or `~/.wisprit`: the
/// learn ledger writes to a per-test temp file, everything else is in-memory.
final class SessionEditCaptureTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wisprit-edit-capture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    // MARK: - harness

    /// Settable auto-accept, readable from a `@Sendable` closure.
    final class AutoAcceptFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var on: Bool {
            get { lock.lock(); defer { lock.unlock() }; return value }
            set { lock.lock(); value = newValue; lock.unlock() }
        }
    }

    /// Strictly increasing observation stamps: `PendingLearnStore` uses the
    /// stamp as utterance identity, and two synchronous test rounds can land in
    /// the same millisecond of wall clock. Anchored near NOW — the store's
    /// 30-day expiry reads the real clock, and evidence stamped 1970 is dead on
    /// arrival.
    final class TickingClock: @unchecked Sendable {
        private let lock = NSLock()
        private var t = Date().addingTimeInterval(-3_600)
        func next() -> Date {
            lock.lock(); defer { lock.unlock() }
            t.addTimeInterval(1)
            return t
        }
    }

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
        let autoAccept = AutoAcceptFlag()
        let clock = TickingClock()
        let store: PendingLearnStore
        let editCapture: EditCapture
        let live: LiveTypingSession
        let session: SessionController

        init(storePath: URL,
             corrector: SpokenSpellingCorrector? = nil,
             liveTypingEnabled: Bool = true,
             reconcile: Bool = false,
             context: FakeContext? = nil) {
            inserter.history = history
            inserter.asr = asr
            store = PendingLearnStore(path: storePath)
            live = LiveTypingSession(
                peer: peer,
                cache: cache,
                counter: IMGenerationCounter(seed: 700),
                configuration: LiveTypingConfiguration(
                    isEnabled: { liveTypingEnabled },
                    frontmostBundleID: { "com.apple.TextEdit" },
                    // Any idle at all closes the session — `tickIdle()` is how
                    // a test forces the close-time read on demand.
                    idleTimeout: -1))
            live.start()
            let vocabulary = self.vocabulary
            let autoAccept = self.autoAccept
            let clock = self.clock
            let live = self.live
            let capture = EditCapture(
                store: store,
                metrics: metrics,
                vocabulary: vocabulary,
                pill: pill,
                lexicon: FixedLexicon(HighFrequencyWords.words),
                committedText: { [weak live] in live?.committedText(for: $0) },
                configuration: EditCapture.Configuration(
                    knownTerm: { vocabulary.isKnownTerm($0) },
                    autoAccept: { autoAccept.on },
                    now: { clock.next() }))
            editCapture = capture
            live.onCommittedSnapshot { [weak capture] generation, snapshot in
                capture?.consumeCommitted(wireGeneration: generation, snapshot)
            }
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
                context: context,
                editObserver: capture,
                configuration: SessionController.Configuration(
                    holdDebounceMs: { 150 },
                    levelTickInterval: nil,
                    reconcileVocabulary: reconcile))
        }

        func dictate(_ text: String) {
            asr.result = UtteranceResult(text: text, engine: "apple_live", finalizeMs: 70)
            session.dispatch(HotkeyEvent(.press, ts: 0))
            session.dispatch(HotkeyEvent(.release, ts: 1.0))
        }

        /// Every `edit_observed` line so far, as (distance, scope).
        var observations: [(dist: Int?, scope: String?)] {
            metrics.records
                .filter { $0.outcome == MetricsSummary.editObservedOutcome }
                .map { ($0.editDist, $0.editScope) }
        }
    }

    private func makeHarness(corrector: SpokenSpellingCorrector? = nil,
                             liveTypingEnabled: Bool = true,
                             reconcile: Bool = false,
                             context: FakeContext? = nil) -> Harness {
        Harness(storePath: tempDir.appendingPathComponent("learn_pending.json"),
                corrector: corrector,
                liveTypingEnabled: liveTypingEnabled,
                reconcile: reconcile,
                context: context)
    }

    /// One full flywheel round on the IM rung: dictate into a fresh field, let
    /// the user fix the misheard name, close the session — which posts the
    /// committed read whose answer is the observation.
    private func editedRound(_ h: Harness) {
        h.peer.preload("")   // a fresh field: each round is its own document
        h.dictate("Please ping Shariq about the migration.")
        h.peer.userEdits("Shariq", with: "Sharique")
        h.live.tickIdle()
    }

    // MARK: - zero-edit (the IM rung)

    func testAnUntouchedRunIsObservedAsZeroEditAtTheNextKeyDown() {
        let h = makeHarness()
        h.dictate("Hello world.")
        XCTAssertEqual(h.observations.count, 0, "nothing observed until the field is re-read")

        // The next utterance's key-down in the SAME session asks the field
        // what became of the last commit, before writing anything new.
        h.dictate("And more.")

        XCTAssertTrue(h.peer.readNames.contains("read_committed"))
        XCTAssertEqual(h.observations.count, 1)
        XCTAssertEqual(h.observations.first?.dist, 0, "our run was exactly where we left it")
        XCTAssertEqual(h.observations.first?.scope, "im")
        XCTAssertTrue(h.store.all().isEmpty, "a zero edit proposes nothing")
    }

    func testSessionCloseObservesTheLastCommit() {
        let h = makeHarness()
        h.dictate("Hello world.")

        h.live.tickIdle()   // idle close posts the last read for this session

        XCTAssertEqual(h.observations.map(\.dist), [0])
        XCTAssertEqual(h.observations.map(\.scope), ["im"])
    }

    /// The key-down read and the close read can both answer about the same
    /// committed state; the second answer is the same fact, not a second
    /// utterance, and must not inflate the denominator.
    func testTheSameCommittedStateIsCountedOnce() {
        let h = makeHarness()
        h.dictate("Hello world.")

        // Two more key-downs with nothing new committed in between: two reads,
        // two identical answers, one observation.
        h.session.dispatch(HotkeyEvent(.press, ts: 10))
        h.session.dispatch(HotkeyEvent(.esc, ts: 10.5))
        h.session.dispatch(HotkeyEvent(.press, ts: 20))
        h.session.dispatch(HotkeyEvent(.esc, ts: 20.5))

        XCTAssertGreaterThanOrEqual(h.peer.readNames.filter { $0 == "read_committed" }.count, 2)
        XCTAssertEqual(h.observations.count, 1)
    }

    // MARK: - an observed edit (the IM rung)

    func testASingleTokenCorrectionIsObservedAndRecordedAsEvidence() {
        let h = makeHarness()

        editedRound(h)

        XCTAssertEqual(h.observations.count, 1)
        XCTAssertEqual(h.observations.first?.scope, "im")
        XCTAssertEqual(h.observations.first?.dist, 2, "Shariq → Sharique moved two characters")

        // Recorded, NOT proposed and NOT learned: one utterance is a
        // coincidence, and the ledger is not the dictionary.
        let entries = h.store.all()
        XCTAssertEqual(entries.map(\.term), ["Sharique"])
        XCTAssertEqual(entries.first?.count, 1)
        XCTAssertEqual(entries.first?.observations.map(\.heard), ["Shariq"])
        XCTAssertTrue(h.store.pending().isEmpty, "below threshold there is nothing to review")
        XCTAssertTrue(h.vocabulary.learned.isEmpty)
        XCTAssertTrue(h.pill.notices.isEmpty)
    }

    func testTheThresholdRaisesTheProposeNoticeAndTheDictionaryBadge() {
        let h = makeHarness()

        editedRound(h)
        editedRound(h)

        XCTAssertEqual(h.pill.notices, [EditCapture.proposalNotice("Sharique")],
                       "propose-first: the word is NOT learned, the notice says where to decide")
        XCTAssertTrue(h.vocabulary.learned.isEmpty)
        let pending = h.store.pending()
        XCTAssertEqual(pending.map(\.term), ["Sharique"])
        XCTAssertEqual(pending.first?.count, 2, "two distinct utterances of evidence")
        // The badge model the Dictionary nav row draws from.
        XCTAssertEqual(WispritWindowModel.dictionaryBadge(proposals: pending.count), .attention)
        XCTAssertNil(WispritWindowModel.dictionaryBadge(proposals: 0))
    }

    func testDismissIsForever() {
        let h = makeHarness()
        h.store.dismiss(term: "Sharique")

        editedRound(h)
        editedRound(h)
        editedRound(h)

        XCTAssertTrue(h.store.pending().isEmpty, "a dismissed term is never proposed again")
        XCTAssertTrue(h.pill.notices.isEmpty)
        XCTAssertTrue(h.vocabulary.learned.isEmpty)
        XCTAssertEqual(h.store.all().map(\.status), [.dismissed],
                       "the negative is the record — nothing accumulates behind it")
        XCTAssertEqual(h.observations.count, 3,
                       "the observations still count: the metric is about edits, not learning")
    }

    func testAutoAcceptWritesTheTermSilentlyAtThreshold() {
        let h = makeHarness()
        h.autoAccept.on = true

        editedRound(h)
        editedRound(h)

        XCTAssertEqual(h.vocabulary.learned,
                       [LearnedTerm(term: "Sharique", heard: ["Shariq"], source: "edit_capture")])
        XCTAssertTrue(h.store.all().isEmpty,
                      "the ledger's job is done — dictionary.json is now the record")
        XCTAssertTrue(h.pill.notices.isEmpty, "silent means silent")
    }

    // MARK: - honesty: no observation, no line

    func testNothingObservedWritesNoLineAtAll() {
        let h = makeHarness(liveTypingEnabled: false)   // paste rung, no context

        h.dictate("Hello world.")
        h.dictate("And more.")

        XCTAssertEqual(h.observations.count, 0,
                       "an unobserved utterance never enters the zero-edit denominator")
        XCTAssertEqual(h.peer.readNames, [], "no session, no reads")
    }

    /// The shipping input method reports `.changed` with no text rather than
    /// guessing which edit happened. That is still an observation — an edit is
    /// a fact — but with no distance and no proposal.
    func testAChangedRunWithNoTextIsObservedWithoutADistance() {
        let h = makeHarness()
        h.dictate("Hello world.")
        // Mangle the field so thoroughly that even the anchored relocation
        // fails: the fake answers plain `.changed`.
        h.peer.userEdits("Hello world.", with: "Entirely rewritten by hand")

        h.live.tickIdle()

        XCTAssertEqual(h.observations.count, 1)
        XCTAssertNil(h.observations.first?.dist, "observed, size unknown — never zero-edit")
        XCTAssertEqual(h.observations.first?.scope, "im")
        XCTAssertTrue(h.store.all().isEmpty, "no text means nothing to propose from")
    }

    // MARK: - the paste rung (edit_scope: "ax")

    func testThePastedTextFoundIntactInTheNextSnapshotIsZeroEdit() {
        let context = FakeContext()
        let h = makeHarness(liveTypingEnabled: false, context: context)

        h.dictate("Ping the InsForge team.")
        XCTAssertEqual(h.inserter.inserted, ["Ping the InsForge team."], "paste rung delivered")

        context.outcome = ContextOutcome(status: .read, terms: [], captureMs: 5,
                                         fieldText: "Ping the InsForge team.")
        h.dictate("And more.")

        XCTAssertEqual(h.observations.map(\.dist), [0])
        XCTAssertEqual(h.observations.map(\.scope), ["ax"])
    }

    func testASingleTokenCorrectionInTheSnapshotFeedsTheGate() {
        let context = FakeContext()
        let h = makeHarness(liveTypingEnabled: false, context: context)

        h.dictate("Please ping Shariq today.")
        context.outcome = ContextOutcome(status: .read, terms: [], captureMs: 5,
                                         fieldText: "Please ping Sharique today.")
        h.dictate("And more.")

        XCTAssertEqual(h.observations.count, 1)
        XCTAssertEqual(h.observations.first?.scope, "ax")
        XCTAssertEqual(h.observations.first?.dist, 2)
        XCTAssertEqual(h.store.all().map(\.term), ["Sharique"])
    }

    /// A window that neither contains our text nor diffs to a single-token
    /// substitution could be a rewrite, a clipped window, or a different field
    /// entirely — from one bounded snapshot those are the same picture, so the
    /// answer is silence, not a guess.
    func testAnAmbiguousSnapshotIsNoSignal() {
        let context = FakeContext()
        let h = makeHarness(liveTypingEnabled: false, context: context)

        h.dictate("Please ping Shariq today.")
        context.outcome = ContextOutcome(status: .read, terms: [], captureMs: 5,
                                         fieldText: "Totally unrelated document text here.")
        h.dictate("And more.")

        XCTAssertEqual(h.observations.count, 0)
        XCTAssertTrue(h.store.all().isEmpty)
    }

    func testNoContextConsentMeansNoPasteRungObservation() {
        let context = FakeContext()   // outcome stays ContextOutcome(): feature off
        let h = makeHarness(liveTypingEnabled: false, context: context)

        h.dictate("Ping the InsForge team.")
        h.dictate("And more.")

        XCTAssertEqual(h.observations.count, 0,
                       "the AX fallback exists only where context awareness already reads")
    }

    /// The IM rungs are observed by their own read channel; the snapshot diff
    /// must not double-observe them under the weaker scope.
    func testTheInputMethodRungIsNeverObservedThroughTheSnapshot() {
        let context = FakeContext()
        let h = makeHarness(context: context)

        h.dictate("Hello world.")
        context.outcome = ContextOutcome(status: .read, terms: [], captureMs: 5,
                                         fieldText: "Hello world.")
        h.dictate("And more.")

        XCTAssertFalse(h.observations.contains { $0.scope == "ax" },
                       "im_streaming deliveries belong to the read channel alone")
        XCTAssertTrue(h.observations.allSatisfy { $0.scope == "im" })
    }

    // MARK: - the utterance triple (history detail)

    func testTheTripleRidesTheTranscriptAndTheVocabColumnArrivesLate() {
        let h = makeHarness(reconcile: true)
        h.asr.reconciliation = VocabularyReconciliation(
            transcript: "Ping the InsForge team about the migration.",
            termHits: ["InsForge": 1], termCount: 1, elapsedMs: 900)

        h.dictate("Ping the in forge team about the migration.")

        let detail = h.history.details.first
        XCTAssertEqual(h.history.details.count, 1)
        XCTAssertEqual(detail?.transcriptId, 1)
        XCTAssertEqual(detail?.raw, "Ping the in forge team about the migration.")
        XCTAssertEqual(detail?.corrected, "Ping the in forge team about the migration.")
        XCTAssertEqual(detail?.refined, "Ping the in forge team about the migration.")
        XCTAssertEqual(detail?.inserted, "Ping the in forge team about the migration.")
        XCTAssertEqual(detail?.ai, "applied")
        XCTAssertNil(detail?.vocab, "the vocab column is NULL until the pass finishes")

        let deadline = Date().addingTimeInterval(5)
        while h.history.vocabUpdates.isEmpty && Date() < deadline { usleep(2_000) }
        XCTAssertEqual(h.history.vocabUpdates.map(\.transcriptId), [1])
        XCTAssertEqual(h.history.vocabUpdates.map(\.vocab),
                       ["Ping the InsForge team about the migration."],
                       "the update path fills exactly the late column")
    }

    func testAnEmptyUtteranceWritesNoDetailRow() {
        let h = makeHarness()
        h.dictate("")
        XCTAssertTrue(h.history.details.isEmpty, "no transcript row, no detail row")
    }
}
