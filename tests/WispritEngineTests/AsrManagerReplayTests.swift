import XCTest
import WispritKit
@testable import WispritEngine

/// R7 — the retained-head replay at engine install (acoustic §3 fix 1).
///
/// The mic goes live before `AsrManager.begin` finishes installing the engine;
/// chunks arriving in that window used to reach only the retention buffer, so
/// on a cold start the head of the utterance silently vanished from the live
/// transcript. `begin` now splices the retained head into the engine inside
/// the feed lock, before the started flag flips. These tests pin the three
/// properties that make that safe: the head is replayed, nothing is fed twice,
/// and nothing is reordered. All coordination is via continuations — no sleeps.
final class AsrManagerReplayTests: XCTestCase {

    /// An engine whose `begin` parks until the test releases it — the
    /// deterministic stand-in for a slow cold-start install — and which
    /// records every `feed` it receives, in order.
    final class GatedEngine: AsrEngine, @unchecked Sendable {
        private let lock = UnfairLock()
        private var fed: [Data] = []
        private var beginEntered: (@Sendable () -> Void)?
        private var gate: CheckedContinuation<Void, Never>?
        private var gateOpen = false

        /// Fulfilled the moment `begin` is reached (before it parks).
        func onBeginEntered(_ handler: @escaping @Sendable () -> Void) {
            lock.lock(); beginEntered = handler; lock.unlock()
        }

        /// Let a parked `begin` proceed (or the next one pass straight through).
        func releaseBegin() {
            lock.lock()
            gateOpen = true
            let parked = gate
            gate = nil
            lock.unlock()
            parked?.resume()
        }

        var fedChunks: [Data] {
            lock.lock(); defer { lock.unlock() }
            return fed
        }

        var fedBytes: Data {
            lock.lock(); defer { lock.unlock() }
            var out = Data()
            for c in fed { out.append(c) }
            return out
        }

        func begin(onPartial: @escaping @Sendable (String) -> Void) async -> Bool {
            lock.lock(); let entered = beginEntered; lock.unlock()
            entered?()
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                lock.lock()
                if gateOpen { lock.unlock(); c.resume(); return }
                gate = c
                lock.unlock()
            }
            return true
        }

        func feed(pcm: Data) {
            lock.lock(); fed.append(pcm); lock.unlock()
        }

        func finalize() async -> UtteranceResult {
            UtteranceResult(text: "ok", engine: "gated", finalizeMs: 1)
        }

        func cancel() async {}
    }

    private func chunk(_ byte: UInt8, count: Int = 3_200) -> Data {
        Data(repeating: byte, count: count)   // 100 ms of 16 kHz mono Int16
    }

    /// The cold-start race, made deterministic: three chunks arrive while
    /// `begin` is still installing. At install they must reach the engine as
    /// the replayed head — before any post-install chunk, with no double-feed.
    func testDelayedBeginReplaysTheRetainedHeadOnceInOrder() async {
        let engine = GatedEngine()
        let manager = AsrManager(settings: AsrSettings(engine: .appleLive),
                                 primaryFactory: { _ in engine },
                                 batch: nil)

        let entered = expectation(description: "begin entered")
        engine.onBeginEntered { entered.fulfill() }
        let beginTask = Task { await manager.begin(onPartial: { _ in }) }
        await fulfillment(of: [entered], timeout: 5)

        // The head: fed while the install is parked. Retention only — the
        // engine must have seen nothing yet.
        let c1 = chunk(1), c2 = chunk(2), c3 = chunk(3)
        manager.feed(pcm: c1)
        manager.feed(pcm: c2)
        manager.feed(pcm: c3)
        XCTAssertTrue(engine.fedChunks.isEmpty,
                      "nothing reaches an engine that has not installed")

        engine.releaseBegin()
        await beginTask.value

        // Install replayed the head as one splice, in order.
        XCTAssertEqual(engine.fedChunks.count, 1, "the head is one order-preserving splice")
        XCTAssertEqual(engine.fedBytes, c1 + c2 + c3)

        // A live chunk after install is fed exactly once, after the replay.
        let c4 = chunk(4)
        manager.feed(pcm: c4)
        XCTAssertEqual(engine.fedChunks.count, 2)
        XCTAssertEqual(engine.fedBytes, c1 + c2 + c3 + c4,
                       "every byte exactly once, replay strictly before live")

        // Retention still holds the whole utterance for the off-path passes.
        let result = await manager.finalize()
        XCTAssertEqual(result.text, "ok")
        XCTAssertEqual(manager.lastRetained.pcm, c1 + c2 + c3 + c4)
    }

    /// Steady state — install completes before the first chunk. No splice is
    /// fabricated and every chunk is fed exactly once, exactly as before R7.
    func testSteadyStateFeedsLiveChunksOnceWithNoReplaySplice() async {
        let engine = GatedEngine()
        engine.releaseBegin()   // begin passes straight through
        let manager = AsrManager(settings: AsrSettings(engine: .appleLive),
                                 primaryFactory: { _ in engine },
                                 batch: nil)

        await manager.begin(onPartial: { _ in })
        let c1 = chunk(1), c2 = chunk(2)
        manager.feed(pcm: c1)
        manager.feed(pcm: c2)

        XCTAssertEqual(engine.fedChunks.count, 2, "no empty replay splice, no double-feed")
        XCTAssertEqual(engine.fedChunks, [c1, c2])
    }

    /// A failed install never replays: the audio stays in retention for the
    /// batch path, exactly the pre-R7 contract.
    func testFailedBeginLeavesTheHeadInRetentionOnly() async {
        final class RefusingEngine: AsrEngine, @unchecked Sendable {
            let fed = UnfairLock()
            nonisolated(unsafe) var sawFeed = false
            func begin(onPartial: @escaping @Sendable (String) -> Void) async -> Bool { false }
            func feed(pcm: Data) { fed.lock(); sawFeed = true; fed.unlock() }
            func finalize() async -> UtteranceResult {
                UtteranceResult(text: "", engine: "refusing", finalizeMs: 0)
            }
            func cancel() async {}
        }
        let engine = RefusingEngine()
        let manager = AsrManager(settings: AsrSettings(engine: .appleLive),
                                 primaryFactory: { _ in engine },
                                 batch: nil)

        await manager.begin(onPartial: { _ in })
        let c1 = chunk(9)
        manager.feed(pcm: c1)

        XCTAssertFalse(engine.sawFeed, "a refused engine is never fed")
        _ = await manager.finalize()
        XCTAssertEqual(manager.lastRetained.pcm, c1,
                       "the audio survives in retention for the batch path")
    }
}
