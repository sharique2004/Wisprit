import XCTest
@testable import WispritMacInput

/// Queue semantics the session depends on. The load-bearing property is that
/// `drainCancel()`/`pollInterrupt()` consume ONLY esc/cancel and leave
/// everything else queued in order — losing a queued press there means the
/// user's next dictation silently never starts.
final class HotkeyEventQueueTests: XCTestCase {

    private func q(_ kinds: [HotkeyEventKind]) -> HotkeyEventQueue {
        let queue = HotkeyEventQueue()
        for (i, k) in kinds.enumerated() { queue.put(HotkeyEvent(k, ts: Double(i))) }
        return queue
    }

    private func drain(_ queue: HotkeyEventQueue) -> [HotkeyEventKind] {
        var out: [HotkeyEventKind] = []
        while let ev = queue.getNowait() { out.append(ev.kind) }
        return out
    }

    // --- basic FIFO -----------------------------------------------------------

    func testFifoOrder() {
        let queue = q([.press, .release, .press])
        XCTAssertEqual(drain(queue), [.press, .release, .press])
        XCTAssertNil(queue.getNowait())
    }

    func testGetWithTimeoutReturnsNilWhenEmpty() {
        let queue = HotkeyEventQueue()
        let t0 = MonotonicClock.now()
        XCTAssertNil(queue.get(timeout: 0.05))
        XCTAssertGreaterThanOrEqual(MonotonicClock.now() - t0, 0.04)
    }

    func testGetWakesOnPut() {
        let queue = HotkeyEventQueue()
        let done = expectation(description: "got event")
        DispatchQueue.global().async {
            let ev = queue.get(timeout: 5)
            XCTAssertEqual(ev?.kind, .press)
            done.fulfill()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            queue.put(HotkeyEvent(.press))
        }
        wait(for: [done], timeout: 6)
    }

    func testCloseUnblocksWaiterAndRefusesPuts() {
        let queue = HotkeyEventQueue()
        let done = expectation(description: "unblocked")
        DispatchQueue.global().async {
            XCTAssertNil(queue.get(timeout: 5))
            done.fulfill()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { queue.close() }
        wait(for: [done], timeout: 6)
        XCTAssertFalse(queue.put(HotkeyEvent(.press)))
    }

    /// Unbounded by default, matching Python's `queue.Queue()`.
    func testUnboundedByDefault() {
        let queue = HotkeyEventQueue()
        for _ in 0..<5_000 { XCTAssertTrue(queue.put(HotkeyEvent(.press))) }
        XCTAssertEqual(queue.count, 5_000)
        XCTAssertEqual(queue.dropped, 0)
    }

    func testCapacityDropsInsteadOfBlocking() {
        let queue = HotkeyEventQueue(capacity: 2)
        XCTAssertTrue(queue.put(HotkeyEvent(.press)))
        XCTAssertTrue(queue.put(HotkeyEvent(.release)))
        XCTAssertFalse(queue.put(HotkeyEvent(.esc)))
        XCTAssertEqual(queue.dropped, 1)
        XCTAssertEqual(drain(queue), [.press, .release])
    }

    // --- drainCancel ----------------------------------------------------------

    func testDrainCancelEmptyQueue() {
        XCTAssertFalse(HotkeyEventQueue().drainCancel())
    }

    func testDrainCancelConsumesEscAndCancelOnly() {
        let queue = q([.esc])
        XCTAssertTrue(queue.drainCancel())
        XCTAssertEqual(queue.count, 0)

        let queue2 = q([.cancel])
        XCTAssertTrue(queue2.drainCancel())
        XCTAssertEqual(queue2.count, 0)
    }

    /// The important one: a press that arrived during finalize must survive the
    /// cancel drain, in position, so it starts the next utterance.
    func testDrainCancelRequeuesOthersInOrder() {
        let queue = q([.press, .esc, .release, .cancel, .pasteLast])
        XCTAssertTrue(queue.drainCancel())
        XCTAssertEqual(drain(queue), [.press, .release, .pasteLast])
    }

    func testDrainCancelWithNoCancels() {
        let queue = q([.press, .release, .pasteLast])
        XCTAssertFalse(queue.drainCancel())
        XCTAssertEqual(drain(queue), [.press, .release, .pasteLast])
    }

    func testDrainCancelPreservesTimestamps() {
        let queue = HotkeyEventQueue()
        queue.put(HotkeyEvent(.press, ts: 11.5))
        queue.put(HotkeyEvent(.esc, ts: 12.0))
        XCTAssertTrue(queue.drainCancel())
        XCTAssertEqual(queue.getNowait()?.ts, 11.5)
    }

    // --- pollInterrupt --------------------------------------------------------

    func testPollInterruptNoneWhenNothingRelevant() {
        let queue = q([.release, .pasteLast])
        XCTAssertEqual(queue.pollInterrupt(), .none)
        XCTAssertEqual(drain(queue), [.release, .pasteLast])
    }

    func testPollInterruptHurryOnQueuedPress() {
        let queue = q([.press])
        XCTAssertEqual(queue.pollInterrupt(), .hurry)
        // The press is NOT consumed — it starts the next utterance.
        XCTAssertEqual(drain(queue), [.press])
    }

    func testPollInterruptCancelConsumesEsc() {
        let queue = q([.esc])
        XCTAssertEqual(queue.pollInterrupt(), .cancel)
        XCTAssertEqual(queue.count, 0)
    }

    /// Cancel wins over hurry when both are queued (the utterance is dead
    /// either way), and the press still survives for the next one.
    func testPollInterruptCancelBeatsHurry() {
        let queue = q([.press, .esc])
        XCTAssertEqual(queue.pollInterrupt(), .cancel)
        XCTAssertEqual(drain(queue), [.press])
    }

    func testPollInterruptIsRepeatable() {
        let queue = q([.press])
        XCTAssertEqual(queue.pollInterrupt(), .hurry)
        XCTAssertEqual(queue.pollInterrupt(), .hurry)
        XCTAssertEqual(queue.pollInterrupt(), .hurry)
        XCTAssertEqual(drain(queue), [.press])
    }

    // --- concurrency ----------------------------------------------------------

    /// Many tap-callback producers, one session consumer, plus concurrent
    /// drains — nothing may be lost or duplicated.
    func testConcurrentProducersAndDrain() {
        let queue = HotkeyEventQueue()
        let producers = 4
        let perProducer = 2_000
        let group = DispatchGroup()
        for _ in 0..<producers {
            DispatchQueue.global().async(group: group) {
                for _ in 0..<perProducer { queue.put(HotkeyEvent(.press)) }
            }
        }
        var seen = 0
        let consumer = DispatchWorkItem {
            while seen < producers * perProducer {
                if queue.getNowait() != nil { seen += 1 }
            }
        }
        DispatchQueue.global().async(execute: consumer)
        group.wait()
        XCTAssertEqual(consumer.wait(timeout: .now() + 30), .success)
        XCTAssertEqual(seen, producers * perProducer)
        XCTAssertEqual(queue.count, 0)
    }

    // --- hasPendingPress (R6's restore-window counter probe) -------------------

    func testHasPendingPressIsNonConsumingAndPressSpecific() {
        let queue = HotkeyEventQueue()
        XCTAssertFalse(queue.hasPendingPress)

        queue.put(HotkeyEvent(.esc, ts: 0))
        XCTAssertFalse(queue.hasPendingPress, "an esc is not a press")

        queue.put(HotkeyEvent(.press, ts: 1))
        XCTAssertTrue(queue.hasPendingPress)
        XCTAssertTrue(queue.hasPendingPress, "probing consumes nothing")
        XCTAssertEqual(queue.count, 2, "…and the queue is untouched")

        XCTAssertEqual(queue.getNowait()?.kind, .esc)
        XCTAssertEqual(queue.getNowait()?.kind, .press,
                       "the probed press still starts the next utterance in order")
        XCTAssertFalse(queue.hasPendingPress)
    }
}
