import XCTest
import WispritContext
import WispritIMProtocol
import WispritPersistence
@testable import WispritMac

/// Phase 4's integration layer, driven with fakes: the capture coordinator's
/// whole life cycle (key-down post → asynchronous delivery → finalize drain),
/// the consent plan, the settings round-trips, and the wire plumbing on
/// `LiveTypingSession`. No TCC grant, no Mach port, no clock sleeps.
final class ContextCaptureTests: XCTestCase {

    // MARK: - fakes

    /// Closure-backed `AXContextReading`: the test decides whether a read
    /// starts and delivers the answers by hand, oldest first, whenever it
    /// likes — which is exactly how a slow serial reader looks from outside.
    final class FakeAXReader: AXContextReading, @unchecked Sendable {
        private let lock = NSLock()
        var busy = false
        private(set) var readCount = 0
        private var pending: [@Sendable (ContextFieldText?) -> Void] = []

        func read(_ completion: @escaping @Sendable (ContextFieldText?) -> Void) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !busy else { return false }
            readCount += 1
            pending.append(completion)
            return true
        }

        /// Answer the OLDEST outstanding read.
        func deliver(_ field: ContextFieldText?) {
            lock.lock()
            let handler = pending.isEmpty ? nil : pending.removeFirst()
            lock.unlock()
            handler?(field)
        }
    }

    /// A deterministic clock the test advances by hand.
    final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Date(timeIntervalSince1970: 1_000_000)
        var now: Date { lock.lock(); defer { lock.unlock() }; return value }
        func advance(_ seconds: TimeInterval) {
            lock.lock(); value = value.addingTimeInterval(seconds); lock.unlock()
        }
    }

    private final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: T
        init(_ value: T) { stored = value }
        var value: T {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }

    private func makeCapture(enabled: Bool = true,
                             bundleID: String = "com.apple.TextEdit",
                             secure: Bool = false,
                             environment: [String: String] = [:],
                             imGeneration: UInt64? = nil,
                             axReader: FakeAXReader? = FakeAXReader(),
                             clock: TestClock = TestClock())
        -> (ContextCapture, FakeAXReader?, Box<Bool>, TestClock) {
        let enabledBox = Box(enabled)
        let capture = ContextCapture(
            configuration: ContextCapture.Configuration(
                policy: { ContextPolicy(enabled: enabledBox.value) },
                maxTerms: { 24 },
                frontmostBundleID: { bundleID },
                secureInputActive: { secure },
                environment: environment,
                clock: { clock.now }),
            requestIMRead: { imGeneration },
            axReader: axReader,
            lexicon: FixedLexicon(["the", "meeting", "with", "about", "tomorrow"]))
        return (capture, axReader, enabledBox, clock)
    }

    // MARK: - default off

    /// The default install: no cycle, no reader touched, no metrics field.
    func testDisabledMeansNoCycleAtAll() {
        let (capture, ax, _, _) = makeCapture(enabled: false)
        capture.beginCapture()
        XCTAssertEqual(ax?.readCount, 0, "a disabled feature must not touch a reader")
        XCTAssertEqual(capture.finishCapture(), ContextOutcome(),
                       "status nil ⇒ the ctx field is never written")
    }

    /// `WISPRIT_NO_CONTEXT=1` outranks the consent flag.
    func testKillSwitchRefusesEvenWithConsentOn() {
        let (capture, ax, _, _) = makeCapture(environment: ["WISPRIT_NO_CONTEXT": "1"])
        capture.beginCapture()
        XCTAssertEqual(ax?.readCount, 0)
        XCTAssertEqual(capture.finishCapture().status, .off)
    }

    func testExcludedAppRefusesAtKeyDown() {
        let (capture, ax, _, _) = makeCapture(bundleID: "com.1password.1password")
        capture.beginCapture()
        XCTAssertEqual(ax?.readCount, 0, "password managers are never read")
        XCTAssertEqual(capture.finishCapture().status, .off)
    }

    func testSecureEventInputRefusesAtKeyDown() {
        let (capture, ax, _, _) = makeCapture(secure: true)
        capture.beginCapture()
        XCTAssertEqual(ax?.readCount, 0)
        XCTAssertEqual(capture.finishCapture().status, .off)
    }

    // MARK: - the AX path

    func testAXDeliveryBecomesReadWithExtractedTerms() {
        let (capture, ax, _, clock) = makeCapture()
        capture.beginCapture()
        clock.advance(0.05)
        ax?.deliver(ContextFieldText(before: "the meeting with Sharique about InsForge "))

        let outcome = capture.finishCapture()
        XCTAssertEqual(outcome.status, .read)
        XCTAssertEqual(outcome.terms, ["InsForge", "Sharique"],
                       "nearest-to-cursor first; common words rejected by the lexicon")
        XCTAssertEqual(outcome.captureMs ?? -1, 50, accuracy: 1,
                       "ctx_ms is key-down → arrival")
    }

    func testNothingArrivedIsLate() {
        let (capture, _, _, _) = makeCapture()
        capture.beginCapture()
        XCTAssertEqual(capture.finishCapture().status, .late)
    }

    func testBusyReaderIsRecordedAndNothingLandsLater() {
        let ax = FakeAXReader()
        ax.busy = true
        let (capture, _, _, _) = makeCapture(axReader: ax)
        capture.beginCapture()
        XCTAssertEqual(capture.finishCapture().status, .busy)
    }

    /// A reader that answers after its budget is caught — the `capturedAt`
    /// contract — while a long HOLD with a prompt reader is not.
    func testWedgedReaderIsStaleButALongHoldIsNot() {
        let (capture, ax, _, clock) = makeCapture()
        capture.beginCapture()
        clock.advance(6.0)  // reader answered after the 5 s budget
        ax?.deliver(ContextFieldText(before: "Sharique"))
        XCTAssertEqual(capture.finishCapture().status, .late)

        capture.beginCapture()
        clock.advance(0.05)  // prompt reader…
        ax?.deliver(ContextFieldText(before: "Sharique"))
        clock.advance(30.0)  // …then a thirty-second dictation
        XCTAssertEqual(capture.finishCapture().status, .read,
                       "a long utterance must not lose its context to its own length")
    }

    /// The answer for utterance N must never bias utterance N+1.
    func testDeliveryForAPreviousUtteranceIsDropped() {
        let (capture, ax, _, _) = makeCapture()
        capture.beginCapture()
        let stale = ax  // completion captured generation 1
        capture.beginCapture()  // generation 2 — supersedes
        stale?.deliver(ContextFieldText(before: "Sharique"))
        XCTAssertEqual(capture.finishCapture().status, .late,
                       "a snapshot stamped with an old generation is dropped at the door")
    }

    /// One consumption, then gone: the snapshot dies with the utterance.
    func testFinishDrainsTheSlot() {
        let (capture, ax, _, _) = makeCapture()
        capture.beginCapture()
        ax?.deliver(ContextFieldText(before: "Sharique"))
        XCTAssertEqual(capture.finishCapture().status, .read)
        XCTAssertEqual(capture.finishCapture(), ContextOutcome(),
                       "a second drain finds nothing — nothing is retained")
    }

    /// The setting flipped off mid-utterance: consent is re-checked at use.
    func testConsentRevokedMidUtteranceRefusesAtUse() {
        let (capture, ax, enabled, _) = makeCapture()
        capture.beginCapture()
        ax?.deliver(ContextFieldText(before: "Sharique"))
        enabled.value = false
        XCTAssertEqual(capture.finishCapture().status, .off)
    }

    // MARK: - the IM path

    func testIMSnapshotWithMatchingWireGenerationIsConsumed() {
        let (capture, ax, _, _) = makeCapture(imGeneration: 42, axReader: nil)
        capture.beginCapture()
        XCTAssertNil(ax)
        capture.deliverIMSnapshot(wireGeneration: 42,
                                  IMContextSnapshot.read(before: "ping Sharique re ",
                                                         selected: "", after: ""))
        let outcome = capture.finishCapture()
        XCTAssertEqual(outcome.status, .read)
        XCTAssertEqual(outcome.terms, ["Sharique"])
    }

    func testIMSnapshotWithWrongGenerationIsDropped() {
        let (capture, _, _, _) = makeCapture(imGeneration: 42, axReader: nil)
        capture.beginCapture()
        capture.deliverIMSnapshot(wireGeneration: 41,
                                  IMContextSnapshot.read(before: "Sharique", selected: "", after: ""))
        XCTAssertEqual(capture.finishCapture().status, .late)
    }

    /// A detail that is a reason, not a result, is the same as no answer.
    func testUnusableIMDetailIsNoSignal() {
        let (capture, _, _, _) = makeCapture(imGeneration: 42, axReader: nil)
        capture.beginCapture()
        capture.deliverIMSnapshot(wireGeneration: 42,
                                  IMContextSnapshot.unavailable(.noDocumentAccess))
        XCTAssertEqual(capture.finishCapture().status, .late)
    }

    /// When the IM rung serves the read, the AX reader is never touched.
    func testIMPathSkipsTheAXReader() {
        let (capture, ax, _, _) = makeCapture(imGeneration: 7)
        capture.beginCapture()
        XCTAssertEqual(ax?.readCount, 0)
    }

    // MARK: - LiveTypingSession wire plumbing

    func testRequestContextReadPostsTheOpenSessionsGeneration() {
        let peer = FakeIMPeer()
        let session = LiveTypingSession(
            peer: peer,
            counter: IMGenerationCounter(seed: 100),
            configuration: LiveTypingConfiguration(
                isEnabled: { true },
                frontmostBundleID: { "com.apple.TextEdit" }))
        session.beginUtterance()
        XCTAssertEqual(session.requestContextRead(), 101)
        XCTAssertEqual(peer.readNames, ["read_context"])
        XCTAssertEqual(peer.reads.first?.generation, 101,
                       "the read names the OPEN session, so the IM's gate can vouch for it")
    }

    func testRequestContextReadRefusesWithNoOpenSession() {
        let peer = FakeIMPeer()
        peer.refuseClient = true
        let session = LiveTypingSession(
            peer: peer,
            counter: IMGenerationCounter(seed: 100),
            configuration: LiveTypingConfiguration(
                isEnabled: { true },
                frontmostBundleID: { "com.apple.TextEdit" }))
        session.beginUtterance()
        XCTAssertNil(session.requestContextRead(),
                     "no live client ⇒ nil ⇒ the coordinator falls back to AX")
    }

    func testOnContextSnapshotForwardsOnlyContextSnapshots() {
        let peer = FakeIMPeer()
        let session = LiveTypingSession(peer: peer)
        let seen = SessionControllerTests.Recorder<UInt64>()
        session.onContextSnapshot { generation, _ in seen.append(generation) }

        peer.deliverContextSnapshot(generation: 9, before: "hello")
        XCTAssertEqual(seen.values, [9])
    }

    // MARK: - consent plan

    func testConsentPlanOnlyActsOnAccept() {
        XCTAssertEqual(ContextConsent.plan(accepted: false, axTrusted: false),
                       ContextConsent.Plan(enable: false, requestAccessibility: false),
                       "cancel does nothing — no flag, no prompt")
        XCTAssertEqual(ContextConsent.plan(accepted: true, axTrusted: true),
                       ContextConsent.Plan(enable: true, requestAccessibility: false),
                       "already trusted ⇒ no prompt")
        XCTAssertEqual(ContextConsent.plan(accepted: true, axTrusted: false),
                       ContextConsent.Plan(enable: true, requestAccessibility: true))
    }

    /// The sheet's three promises and the no-permission note, pinned so a copy
    /// edit is a deliberate act.
    func testConsentCopyStatesTheContract() {
        XCTAssertTrue(ContextConsent.whatIsRead.contains("near your cursor"))
        XCTAssertTrue(ContextConsent.neverRead.contains("other windows"))
        XCTAssertTrue(ContextConsent.neverRead.contains("screenshots"))
        XCTAssertTrue(ContextConsent.neverRead.contains("browser URLs"))
        XCTAssertTrue(ContextConsent.whereItGoes.contains("Nothing is stored"))
        XCTAssertTrue(ContextConsent.permissionNote.contains("no new permission"))
    }

    // MARK: - settings

    func testSettingsDefaultsAndRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wisprit-ctx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = Settings(path: dir.appendingPathComponent("config.json"))

        // Defaults: consent off, extractor cap, core exclusions, terminals ∪ IDEs.
        XCTAssertFalse(ContextSettings.isEnabled(settings))
        XCTAssertEqual(ContextSettings.maxTerms(settings), 24)
        XCTAssertEqual(ContextSettings.excludedBundleIDs(settings),
                       ContextPolicy.defaultExcludedBundleIDs)
        XCTAssertEqual(ContextSettings.verbatimBundleIDs(settings),
                       settings.terminalBundleIDs + ContextSettings.defaultIDEBundleIDs)

        // Round-trip through the file.
        ContextSettings.setEnabled(settings, true)
        settings.set(ContextSettings.maxTermsKey, 12)
        settings.set(ContextSettings.excludedBundleIDsKey, ["com.example.Private"])
        ContextSettings.setVerbatimBundleIDs(settings, ["com.apple.dt.Xcode"])

        let reread = Settings(path: settings.configPath)
        XCTAssertTrue(ContextSettings.isEnabled(reread))
        XCTAssertEqual(ContextSettings.maxTerms(reread), 12)
        XCTAssertEqual(ContextSettings.verbatimBundleIDs(reread), ["com.apple.dt.Xcode"])
        // User exclusions EXTEND the core list — a hand-edited config can add a
        // private app but can never re-admit a password manager.
        XCTAssertTrue(ContextSettings.excludedBundleIDs(reread).contains("com.example.private"))
        XCTAssertTrue(ContextSettings.excludedBundleIDs(reread)
            .isSuperset(of: ContextPolicy.defaultExcludedBundleIDs))
    }

    func testVerbatimAppMatchingIsCaseInsensitive() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wisprit-ctx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = Settings(path: dir.appendingPathComponent("config.json"))

        XCTAssertTrue(ContextSettings.isVerbatimApp(settings, bundleID: "com.apple.terminal"))
        XCTAssertTrue(ContextSettings.isVerbatimApp(settings, bundleID: "com.apple.dt.Xcode"))
        XCTAssertFalse(ContextSettings.isVerbatimApp(settings, bundleID: "com.apple.TextEdit"))
        XCTAssertFalse(ContextSettings.isVerbatimApp(settings, bundleID: nil))
    }

    /// Adding a terminal keeps it verbatim too — the default tracks the live
    /// terminal list until the user writes their own.
    func testVerbatimDefaultTracksTerminalEdits() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wisprit-ctx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = Settings(path: dir.appendingPathComponent("config.json"))

        settings.set(SettingsKey.terminalBundleIDs, ["com.example.myterm"])
        XCTAssertTrue(ContextSettings.isVerbatimApp(settings, bundleID: "com.example.myterm"))

        ContextSettings.setVerbatimBundleIDs(settings, ["com.apple.dt.Xcode"])
        XCTAssertFalse(ContextSettings.isVerbatimApp(settings, bundleID: "com.example.myterm"),
                       "an explicit list is the user's own — no silent union")
    }
}
