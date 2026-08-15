import XCTest
import WispritKit
@testable import WispritEngine

/// R33 — the pre-roll: audio captured between key-down and the `begin()` that
/// adopts it.
///
/// The defect these pin: `dispatch` only starts an utterance from IDLE, so a
/// press arriving while the previous one is still finalizing/refining/inserting
/// waits in the queue — 0.7–1.5 s typically, seconds on a batch rescue — and
/// until now the microphone did not open until that wait was over. Every word
/// spoken into it was simply never captured (11.6 % of presses land <3 s after
/// the previous one).
///
/// The fix opens the mic at key-down and lets the retention buffer hold the
/// pre-roll until `begin`'s existing head replay splices it into the analyzer.
/// What makes that safe is the arm gate, and these are its properties: the
/// pre-roll survives, the PREVIOUS utterance's snapshot does not see it, a late
/// arm is a harmless no-op, and a press landing while an utterance is still
/// recording is refused outright rather than half-served.
///
/// All coordination is via continuations. No sleeps, no microphone.
final class AsrPrerollTests: XCTestCase {

    /// Records every `feed`, and can park inside `finalize` so a test can act
    /// while the previous utterance is still finishing — the exact window a
    /// queued press lands in.
    final class RecordingEngine: AsrEngine, @unchecked Sendable {
        private let lock = UnfairLock()
        private var fed: [Data] = []
        private var finalizeEntered: (@Sendable () -> Void)?
        private var gate: CheckedContinuation<Void, Never>?
        private var gateOpen = true

        init(parkInFinalize: Bool = false) {
            gateOpen = !parkInFinalize
        }

        func onFinalizeEntered(_ handler: @escaping @Sendable () -> Void) {
            lock.lock(); finalizeEntered = handler; lock.unlock()
        }

        func releaseFinalize() {
            lock.lock()
            gateOpen = true
            let parked = gate
            gate = nil
            lock.unlock()
            parked?.resume()
        }

        var fedBytes: Data {
            lock.lock(); defer { lock.unlock() }
            var out = Data()
            for c in fed { out.append(c) }
            return out
        }

        var feedCount: Int { lock.lock(); defer { lock.unlock() }; return fed.count }

        func begin(onPartial: @escaping @Sendable (String) -> Void) async -> Bool { true }

        func feed(pcm: Data) { lock.lock(); fed.append(pcm); lock.unlock() }

        func finalize() async -> UtteranceResult {
            lock.lock(); let entered = finalizeEntered; lock.unlock()
            entered?()
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                lock.lock()
                if gateOpen { lock.unlock(); c.resume(); return }
                gate = c
                lock.unlock()
            }
            return UtteranceResult(text: "ok", engine: "recording", finalizeMs: 1)
        }

        func cancel() async {}
    }

    private func chunk(_ byte: UInt8, count: Int = 3_200) -> Data {
        Data(repeating: byte, count: count)   // 100 ms of 16 kHz mono Int16
    }

    private func manager(_ engines: [RecordingEngine]) -> AsrManager {
        let box = EngineQueue(engines)
        return AsrManager(settings: AsrSettings(engine: .appleLive),
                          primaryFactory: { _ in box.next() },
                          batch: nil)
    }

    /// Hands out one engine per `begin`, in order.
    final class EngineQueue: @unchecked Sendable {
        private let lock = UnfairLock()
        private var engines: [RecordingEngine]
        init(_ engines: [RecordingEngine]) { self.engines = engines }
        func next() -> RecordingEngine {
            lock.lock(); defer { lock.unlock() }
            return engines.isEmpty ? RecordingEngine() : engines.removeFirst()
        }
    }

    // MARK: - the fix

    /// The headline: a press arriving while utterance 1 is still finalizing
    /// arms the buffer, its speech accumulates, and utterance 2's engine is
    /// handed that audio as its head. Utterance 1's snapshot never sees a byte
    /// of it.
    func testPreRollSurvivesIntoTheNextUtteranceAndNotIntoThePreviousSnapshot() async {
        let first = RecordingEngine(parkInFinalize: true)
        let second = RecordingEngine()
        let manager = manager([first, second])

        await manager.begin(onPartial: { _ in })
        let spoken = chunk(1)
        manager.feed(pcm: spoken)

        let entered = expectation(description: "finalize entered")
        first.onFinalizeEntered { entered.fulfill() }
        let finalizing = Task { await manager.finalize() }
        await fulfillment(of: [entered], timeout: 5)

        // The queued press: arm, then the mic's chunks arrive while utterance 1
        // is still on the session thread.
        XCTAssertTrue(manager.armCapture(), "finalize has detached; the buffer is free to arm")
        let preRoll = chunk(2)
        manager.feed(pcm: preRoll)
        XCTAssertEqual(first.fedBytes, spoken,
                       "a pre-roll chunk must never reach the finalizing engine")

        first.releaseFinalize()
        _ = await finalizing.value
        XCTAssertEqual(manager.lastRetained.pcm, spoken,
                       "utterance 1's snapshot is exactly utterance 1's audio")

        // Utterance 2 begins — and its engine's first bytes are the pre-roll.
        await manager.begin(onPartial: { _ in })
        XCTAssertEqual(second.fedBytes, preRoll, "the head replay delivered the pre-roll")

        let live = chunk(3)
        manager.feed(pcm: live)
        XCTAssertEqual(second.fedBytes, preRoll + live, "and nothing was fed twice")
        _ = await manager.finalize()
        XCTAssertEqual(manager.lastRetained.pcm, preRoll + live,
                       "the retained utterance carries the head the user actually spoke")
    }

    /// The fast-flick window: a press landing while an utterance is still
    /// RECORDING. Arming is refused, so the caller never starts a second
    /// microphone session over the live one — which would reset the R4
    /// telemetry the session is about to read — and the live utterance's audio
    /// is untouched.
    func testArmIsRefusedWhileAnUtteranceIsStillRecording() async {
        let manager = manager([RecordingEngine()])
        await manager.begin(onPartial: { _ in })
        XCTAssertTrue(manager.isRecordingUtterance)
        let spoken = chunk(1)
        manager.feed(pcm: spoken)

        XCTAssertFalse(manager.armCapture(), "an utterance owns the microphone")

        manager.feed(pcm: chunk(2))
        _ = await manager.finalize()
        XCTAssertEqual(manager.lastRetained.pcm, spoken + chunk(2),
                       "the refused arm did not reset the live buffer")
    }

    /// Arming twice — two presses queued behind one busy pipeline — takes the
    /// first one's pre-roll, not the second's. One pre-roll, one utterance.
    func testASecondArmIsRefusedSoOnePreRollServesOneUtterance() async {
        let manager = manager([RecordingEngine()])
        XCTAssertTrue(manager.armCapture())
        let preRoll = chunk(7)
        manager.feed(pcm: preRoll)
        XCTAssertFalse(manager.armCapture(), "a second arm would discard the first's audio")

        await manager.begin(onPartial: { _ in })
        _ = await manager.finalize()
        XCTAssertEqual(manager.lastRetained.pcm, preRoll)
    }

    /// `startUtterance` clears the arm, so the utterance AFTER a pre-rolled one
    /// starts from an empty buffer like any other.
    func testTheArmIsConsumedByTheUtteranceThatAdoptsIt() async {
        let manager = manager([RecordingEngine(), RecordingEngine()])
        XCTAssertTrue(manager.armCapture())
        manager.feed(pcm: chunk(1))
        await manager.begin(onPartial: { _ in })
        _ = await manager.finalize()

        // No arm this time: the next begin resets, as it always did.
        manager.feed(pcm: chunk(2))          // stray tail chunk, no press behind it
        await manager.begin(onPartial: { _ in })
        let live = chunk(3)
        manager.feed(pcm: live)
        _ = await manager.finalize()
        XCTAssertEqual(manager.lastRetained.pcm, live,
                       "an unarmed begin still resets the buffer")
    }

    /// Esc, or a sub-debounce brush, takes the pre-roll with it: that audio
    /// belonged to an utterance the user threw away.
    func testCancelDisarmsAndDropsThePreRoll() async {
        let manager = manager([RecordingEngine()])
        XCTAssertTrue(manager.armCapture())
        manager.feed(pcm: chunk(1))
        await manager.cancel()

        await manager.begin(onPartial: { _ in })
        let live = chunk(2)
        manager.feed(pcm: live)
        _ = await manager.finalize()
        XCTAssertEqual(manager.lastRetained.pcm, live, "the cancelled pre-roll is gone")
    }

    /// The hand-off gate is on the PHASE, not on the started flag: during
    /// `await engine.finalize()` the flag is still up, and without this a
    /// pre-roll chunk would be handed to an engine that is mid-finalize. It
    /// happens to be harmless for `SpeechAnalyzerEngine`; this makes it
    /// harmless for every engine.
    func testAFinalizingEngineIsNeverFedRegardlessOfTheStartedFlag() async {
        let engine = RecordingEngine(parkInFinalize: true)
        let manager = manager([engine])
        await manager.begin(onPartial: { _ in })
        manager.feed(pcm: chunk(1))

        let entered = expectation(description: "finalize entered")
        engine.onFinalizeEntered { entered.fulfill() }
        let finalizing = Task { await manager.finalize() }
        await fulfillment(of: [entered], timeout: 5)

        XCTAssertEqual(engine.feedCount, 1)
        manager.feed(pcm: chunk(2))          // a late tap chunk, no arm at all
        XCTAssertEqual(engine.feedCount, 1, "nothing reaches a finalizing engine")

        engine.releaseFinalize()
        _ = await finalizing.value
    }
}
