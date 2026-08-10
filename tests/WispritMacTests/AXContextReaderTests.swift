import XCTest
@testable import WispritMac

/// The AX reader's testable half: the depth-1 serial discipline and the
/// UTF-16 window split. The four real AX calls stay inside the injected
/// `perform` closure and are exercised by hand, not by CI — exactly the
/// thin-adapter rule every TCC-gated surface in this app follows.
final class AXContextReaderTests: XCTestCase {

    /// A perform that parks until released, so the test can hold a read "in
    /// flight" for as long as it needs.
    private final class ParkedPerform: @unchecked Sendable {
        private let semaphore = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var count = 0

        var performCount: Int { lock.lock(); defer { lock.unlock() }; return count }

        func perform() -> ContextFieldText? {
            lock.lock(); count += 1; lock.unlock()
            semaphore.wait()
            return ContextFieldText(before: "hello ")
        }

        func release() { semaphore.signal() }
    }

    func testSecondReadWhileOneIsInFlightIsDroppedNotQueued() {
        let parked = ParkedPerform()
        let reader = AXContextReader(perform: { parked.perform() })
        let first = expectation(description: "first read completes")

        XCTAssertTrue(reader.read { _ in first.fulfill() })
        // Wait until the read is actually being served before poking it.
        let deadline = Date().addingTimeInterval(2)
        while parked.performCount < 1, Date() < deadline { usleep(2_000) }

        XCTAssertFalse(reader.read { _ in
            XCTFail("a dropped read must never call its completion")
        })

        parked.release()
        wait(for: [first], timeout: 2)
        XCTAssertEqual(parked.performCount, 1, "dropped means dropped — no deferred serve")
    }

    func testReaderRecoversAfterTheReadFinishes() {
        let parked = ParkedPerform()
        let reader = AXContextReader(perform: { parked.perform() })
        let first = expectation(description: "first")
        let second = expectation(description: "second")

        XCTAssertTrue(reader.read { field in
            XCTAssertEqual(field?.before, "hello ")
            first.fulfill()
        })
        parked.release()
        wait(for: [first], timeout: 2)

        XCTAssertTrue(reader.read { _ in second.fulfill() }, "depth 1, not once-only")
        parked.release()
        wait(for: [second], timeout: 2)
    }

    func testNilFromThePerformPassesThroughAsNoSignal() {
        let reader = AXContextReader(perform: { nil })
        let done = expectation(description: "completion")
        reader.read { field in
            XCTAssertNil(field)
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }

    // MARK: - the window split

    func testSplitAtUTF16Offsets() {
        let split = AXContextReader.split(window: "before[sel]after",
                                          selectionStart: 6, selectionLength: 5)
        XCTAssertEqual(split, ContextFieldText(before: "before", selected: "[sel]",
                                               after: "after"))
    }

    func testSplitWithBareCaret() {
        let split = AXContextReader.split(window: "hello world",
                                          selectionStart: 5, selectionLength: 0)
        XCTAssertEqual(split, ContextFieldText(before: "hello", selected: "",
                                               after: " world"))
    }

    /// Apps have answered shorter windows than asked; offsets clamp, never trap.
    func testSplitClampsOutOfRangeOffsets() {
        XCTAssertEqual(AXContextReader.split(window: "hi", selectionStart: 10,
                                             selectionLength: 5),
                       ContextFieldText(before: "hi", selected: "", after: ""))
        XCTAssertEqual(AXContextReader.split(window: "hi", selectionStart: -3,
                                             selectionLength: 1),
                       ContextFieldText(before: "", selected: "h", after: "i"))
    }
}
