import XCTest
import WispritIMProtocol
@testable import WispritMac

/// The app half of live in-field streaming, against a fake input method.
///
/// Press → select → stream → finalize → edit → deselect, plus every way it can
/// go wrong: a stale generation, a client that vanishes mid-utterance, a client
/// that cannot hold marked text, and a process that stops answering.
final class LiveTypingSessionTests: XCTestCase {

    private var peer: FakeIMPeer!
    private var cache: BundleCapabilityCache!
    private var now: Date!

    override func setUp() {
        super.setUp()
        peer = FakeIMPeer()
        cache = BundleCapabilityCache()
        now = Date(timeIntervalSince1970: 1_000_000)
    }

    private func makeSession(enabled: Bool = true,
                             secure: Bool = false,
                             frontmost: String? = "com.apple.TextEdit",
                             idleTimeout: TimeInterval = 20) -> LiveTypingSession {
        LiveTypingSession(
            peer: peer,
            cache: cache,
            counter: IMGenerationCounter(seed: 100),
            configuration: LiveTypingConfiguration(
                isEnabled: { enabled },
                terminalBundleIDs: { ["com.apple.Terminal"] },
                frontmostBundleID: { frontmost },
                secureInputActive: { secure },
                idleTimeout: idleTimeout),
            clock: { [self] in now })
    }

    // MARK: - the happy path

    func testFullUtteranceStreamsCommitsAndLeavesTheFieldCorrect() {
        let session = makeSession()

        XCTAssertEqual(session.beginUtterance(), .imStreaming)
        XCTAssertEqual(peer.selectCount, 1, "the palette source is selected on key-down")
        XCTAssertTrue(session.isStreaming)

        session.streamPartial("the quick")
        session.streamPartial("the quick brown")
        XCTAssertEqual(peer.snapshot.marked, "the quick brown",
                       "each partial replaces the marked tail wholesale")
        XCTAssertEqual(peer.snapshot.document, "", "provisional text is not committed")

        XCTAssertEqual(session.commit("The quick brown fox. "), .committed(.imStreaming))
        XCTAssertEqual(peer.snapshot.document, "The quick brown fox. ")
        XCTAssertEqual(peer.snapshot.marked, "", "insertText: clears the mark in one call")
        session.endUtterance()
    }

    func testEveryMessageCarriesTheSameGenerationForOneSession() {
        let session = makeSession()
        session.beginUtterance()
        session.streamPartial("hi")
        _ = session.commit("Hi. ")

        let generations = Set(peer.commandNames.indices.compactMap { index -> UInt64? in
            peer.lastCommand(peer.commandNames[index])?.generation
        })
        XCTAssertEqual(generations.count, 1, "one open session, one generation")
        XCTAssertEqual(peer.lastCommand("begin_session")?.generation, 101,
                       "generations are strictly increasing from the seed")
    }

    func testSessionSpansConsecutiveUtterancesInTheSameField() {
        // This is what makes a cross-utterance retro-edit possible at all: the
        // input method resets its committed-text record on beginSession, so a
        // session per utterance would forget the word we are about to fix.
        let session = makeSession()
        session.beginUtterance()
        _ = session.commit("Hi Sharik. ")
        session.endUtterance()

        session.beginUtterance()
        XCTAssertEqual(peer.count(of: "begin_session"), 1, "the open session is reused")
        _ = session.commit("How are you? ")
        XCTAssertEqual(peer.snapshot.committed, "Hi Sharik. How are you? ")
    }

    /// Mutable across `@Sendable` closure boundaries without a data race.
    final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: T
        init(_ value: T) { storage = value }
        var value: T {
            get { lock.lock(); defer { lock.unlock() }; return storage }
            set { lock.lock(); storage = newValue; lock.unlock() }
        }
    }

    func testFocusChangeToAnotherAppClosesTheSessionFirst() {
        let frontmost = Box("com.apple.TextEdit")
        let session = LiveTypingSession(
            peer: peer, cache: cache, counter: IMGenerationCounter(seed: 100),
            configuration: LiveTypingConfiguration(
                isEnabled: { true },
                frontmostBundleID: { frontmost.value }),
            clock: { [self] in now })

        session.beginUtterance()
        _ = session.commit("first ")

        frontmost.value = "com.tinyspeck.slackmacgap"
        peer.capabilities = IMClientCapabilities(
            supportsUnicode: true, bundleID: "com.tinyspeck.slackmacgap",
            supportsDocumentAccess: true)
        session.beginUtterance()

        XCTAssertEqual(peer.count(of: "end_session"), 1,
                       "the committed-text anchor belongs to one field")
        XCTAssertEqual(peer.count(of: "begin_session"), 2)
        XCTAssertEqual(peer.snapshot.committed, "", "the new session starts with a clean record")
    }

    // MARK: - retro edits

    func testCrossUtteranceRetroEditRewritesTheEarlierWord() {
        let session = makeSession()
        session.beginUtterance()
        _ = session.commit("Hi Sharik, how are you? ")
        session.endUtterance()

        session.beginUtterance()
        let result = session.applyRetroEdit(replace: "Sharik", with: "Sharique")
        XCTAssertEqual(result?.ok, true)
        XCTAssertEqual(result?.detail, .applied)
        XCTAssertEqual(peer.snapshot.document, "Hi Sharique, how are you? ",
                       "the word already in the user's document is the one that changed")
    }

    func testRetroEditIsRefusedWithoutDocumentAccess() {
        // Without TSMDocumentAccess the replacement range is silently discarded
        // and the "correction" lands at the end of the field — worse than none.
        peer.capabilities = IMClientCapabilities(
            supportsUnicode: true, bundleID: "com.example.legacy", supportsDocumentAccess: false)
        let session = makeSession()
        session.beginUtterance()
        _ = session.commit("Hi Sharik. ")

        let result = session.applyRetroEdit(replace: "Sharik", with: "Sharique")
        XCTAssertEqual(result?.ok, false)
        XCTAssertEqual(result?.detail, .noDocumentAccess)
        XCTAssertEqual(peer.count(of: "apply_edit"), 0, "we do not even ask")
        XCTAssertEqual(peer.snapshot.document, "Hi Sharik. ", "the field is untouched")
    }

    func testRetroEditReportsTargetNotFoundWithoutTouchingTheField() {
        let session = makeSession()
        session.beginUtterance()
        _ = session.commit("nothing relevant here ")

        let result = session.applyRetroEdit(replace: "Sharik", with: "Sharique")
        XCTAssertEqual(result?.ok, false)
        XCTAssertEqual(result?.detail, .targetNotFound)
        XCTAssertEqual(peer.snapshot.document, "nothing relevant here ")
    }

    func testRetroEditIsNilWhenNoInputMethodSessionIsOpen() {
        let session = makeSession(enabled: false)
        session.beginUtterance()
        XCTAssertNil(session.applyRetroEdit(replace: "a", with: "b"),
                     "nil means 'this tier cannot do it' — the caller keeps learn+notice")
    }

    func testEmptyTargetIsRejectedBeforeTheWire() {
        let session = makeSession()
        session.beginUtterance()
        XCTAssertEqual(session.applyRetroEdit(replace: "", with: "x")?.detail, .emptyEdit)
        XCTAssertEqual(peer.count(of: "apply_edit"), 0)
    }

    // MARK: - stale generations

    func testAStaleGenerationCanNeverTouchTheField() {
        let session = makeSession()
        session.beginUtterance()
        _ = session.commit("first ")

        // A message from a session that is over, arriving after a newer one
        // opened. The gate is what makes it harmless.
        let stale = IMCommandMessage.commitFinal(generation: 1, text: "LEAKED")
        let reply = peer.exchange(stale, timeout: 1)
        guard case .event(let message) = reply, case .editResult(let result) = message.event else {
            return XCTFail("expected an editResult, got \(reply)")
        }
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.detail, .staleGeneration)
        XCTAssertEqual(peer.snapshot.document, "first ", "nothing leaked into the field")
    }

    func testGenerationsAreStrictlyIncreasingAcrossSessions() {
        let session = makeSession()
        session.beginUtterance()
        let first = peer.lastCommand("begin_session")!.generation
        session.shutdown()

        peer.capabilities = IMClientCapabilities(
            supportsUnicode: true, bundleID: "com.apple.TextEdit", supportsDocumentAccess: true)
        session.beginUtterance()
        let second = peer.lastCommand("begin_session")!.generation
        XCTAssertGreaterThan(second, first)
    }

    // MARK: - degradation

    func testClientLostMidUtteranceHandsTheTextBackToPaste() {
        let session = makeSession()
        session.start()
        session.beginUtterance()
        session.streamPartial("half a sentence")
        XCTAssertTrue(session.isStreaming)

        peer.loseClient()

        XCTAssertFalse(session.isStreaming, "the pill takes the preview back over")
        XCTAssertFalse(session.isEngaged)
        XCTAssertEqual(session.tier, .paste)
        // And crucially: the commit is refused rather than swallowed, so the
        // session controller pastes the whole utterance instead.
        if case .committed = session.commit("Half a sentence. ") {
            XCTFail("a lost client must never report a successful commit")
        }
        XCTAssertEqual(peer.snapshot.document, "", "nothing was written twice")
    }

    func testMarkedTextRefusalDropsToCommitOnlyAndIsRemembered() {
        peer.markedTextWorks = false
        peer.capabilities = IMClientCapabilities(
            supportsUnicode: true, bundleID: "org.qt.app", supportsDocumentAccess: true)
        let session = makeSession(frontmost: "org.qt.app")

        // First utterance: we optimistically stream, the client refuses.
        XCTAssertEqual(session.beginUtterance(), .imStreaming)
        session.streamPartial("hello")
        XCTAssertEqual(peer.snapshot.marked, "")

        // The commit still lands — rung 2 is a real rung, not a failure.
        XCTAssertEqual(session.commit("Hello. "), .committed(.imStreaming))
        XCTAssertEqual(peer.snapshot.document, "Hello. ")
    }

    func testCachedCommitOnlyVerdictSuppressesTheLiveTailNextTime() {
        cache.downgradeMarkedText(for: "org.qt.app", reason: "setMarkedText refused")
        peer.capabilities = IMClientCapabilities(
            supportsUnicode: true, bundleID: "org.qt.app", supportsDocumentAccess: true)
        let session = makeSession(frontmost: "org.qt.app")

        XCTAssertEqual(session.beginUtterance(), .imCommit)
        XCTAssertFalse(session.isStreaming, "no second flicker for a client we already know")
        session.streamPartial("hello")
        XCTAssertEqual(peer.count(of: "update_volatile"), 0)
        XCTAssertEqual(session.commit("Hello. "), .committed(.imCommit))
    }

    func testCommitRefusalDowngradesTheBundleAndFallsBack() {
        peer.insertWorks = false
        let session = makeSession()
        session.beginUtterance()

        guard case .fallback = session.commit("Hello. ") else {
            return XCTFail("a refused insertText must fall back to paste")
        }
        XCTAssertEqual(cache.verdict(for: "com.apple.TextEdit"), .unsupported)
        XCTAssertEqual(session.tier, .paste)
    }

    func testUnreachableInputMethodFallsBackWithoutSending() {
        let session = makeSession()
        session.beginUtterance()
        peer.reachable = false

        guard case .fallback = session.commit("Hello. ") else {
            return XCTFail("an unreachable input method must fall back")
        }
        XCTAssertEqual(peer.count(of: "commit_final"), 0,
                       "nothing was delivered, so pasting cannot duplicate anything")
    }

    func testRefusedClientMeansPasteAndNoStreaming() {
        peer.refuseClient = true
        let session = makeSession()
        XCTAssertEqual(session.beginUtterance(), .paste)
        XCTAssertFalse(session.isStreaming)
        session.streamPartial("hello")
        XCTAssertEqual(peer.count(of: "update_volatile"), 0)
    }

    // MARK: - gating

    func testLiveTypingOffNeverTouchesTheInputSource() {
        let session = makeSession(enabled: false)
        XCTAssertEqual(session.beginUtterance(), .paste)
        XCTAssertEqual(peer.selectCount, 0)
        XCTAssertEqual(peer.commandNames, [])
    }

    func testSecureInputSkipsTheInputMethodEntirely() {
        let session = makeSession(secure: true)
        XCTAssertEqual(session.beginUtterance(), .blockedSecure)
        XCTAssertEqual(peer.selectCount, 0)
        XCTAssertEqual(peer.commandNames, [])
    }

    func testAnUnregisteredInputMethodIsNeverSelected() {
        peer.status = InputMethodStatus(bundleInstalled: false)
        let session = makeSession()
        XCTAssertEqual(session.beginUtterance(), .paste)
        XCTAssertEqual(peer.selectCount, 0, "no registration, no selection, no prompt")
    }

    func testAnAlreadySelectedSourceIsNotReselected() {
        peer.status.selected = true
        let session = makeSession()
        session.beginUtterance()
        XCTAssertEqual(peer.selectCount, 0)
    }

    // MARK: - idle and shutdown

    func testIdleClosesTheSessionAndGivesTheInputSourceBack() {
        let session = makeSession(idleTimeout: 20)
        session.beginUtterance()
        _ = session.commit("Hello. ")
        session.endUtterance()
        XCTAssertTrue(session.isSessionOpen)

        now = now.addingTimeInterval(5)
        session.tickIdle()
        XCTAssertTrue(session.isSessionOpen, "still warm")

        now = now.addingTimeInterval(30)
        session.tickIdle()
        XCTAssertFalse(session.isSessionOpen)
        XCTAssertEqual(peer.count(of: "end_session"), 1)
        XCTAssertEqual(peer.deselectCount, 1)
    }

    func testIdleCommitsWhateverWasStillMarked() {
        let session = makeSession(idleTimeout: 1)
        session.beginUtterance()
        session.streamPartial("dangling tail")

        now = now.addingTimeInterval(60)
        session.tickIdle()
        XCTAssertEqual(peer.snapshot.document, "dangling tail",
                       "endSession(commit: true) never abandons the user's words")
    }

    func testDiscardTailTakesTheProvisionalTextBackDown() {
        let session = makeSession()
        session.beginUtterance()
        session.streamPartial("half a th")
        XCTAssertEqual(peer.snapshot.marked, "half a th")

        session.discardTail()
        XCTAssertEqual(peer.snapshot.marked, "")
        XCTAssertEqual(peer.snapshot.document, "", "cancelling leaves the field as it was")
    }

    func testShutdownClosesAndDeselects() {
        let session = makeSession()
        session.beginUtterance()
        session.shutdown()
        XCTAssertFalse(session.isSessionOpen)
        XCTAssertEqual(peer.deselectCount, 1)
    }

    func testShutdownWithNoSessionIsHarmless() {
        let session = makeSession(enabled: false)
        session.shutdown()
        XCTAssertEqual(peer.deselectCount, 0)
        XCTAssertEqual(peer.commandNames, [])
    }
}
