import XCTest
import WispritIMProtocol

/// The generation counter is the safety interlock for the whole feature: it is
/// what guarantees an input method process that outlived its session cannot
/// write into the field the next session owns.
final class GenerationTests: XCTestCase {

    func testOnlyAStrictlyNewerGenerationOpensASession() {
        var gate = IMGenerationGate()
        XCTAssertEqual(gate.begin(5), .accept)
        XCTAssertEqual(gate.end(5), .accept)

        XCTAssertEqual(gate.begin(5), .rejectStale(current: 5), "replay")
        XCTAssertEqual(gate.begin(4), .rejectStale(current: 5), "rewind")
        XCTAssertEqual(gate.begin(6), .accept)
    }

    func testMidSessionCommandsMustMatchTheOpenGeneration() {
        var gate = IMGenerationGate()
        XCTAssertEqual(gate.admit(1), .rejectNoSession)

        _ = gate.begin(7)
        XCTAssertEqual(gate.admit(7), .accept)
        XCTAssertEqual(gate.admit(6), .rejectStale(current: 7))
        XCTAssertEqual(gate.admit(8), .rejectStale(current: 7))
    }

    func testEndingClosesTheDoor() {
        var gate = IMGenerationGate()
        _ = gate.begin(3)
        XCTAssertTrue(gate.isOpen)
        XCTAssertEqual(gate.end(3), .accept)
        XCTAssertFalse(gate.isOpen)
        XCTAssertEqual(gate.admit(3), .rejectNoSession)
    }

    func testEndingWithTheWrongGenerationLeavesTheSessionOpen() {
        var gate = IMGenerationGate()
        _ = gate.begin(3)
        XCTAssertEqual(gate.end(2), .rejectStale(current: 3))
        XCTAssertTrue(gate.isOpen, "a stale endSession must not close a live session")
    }

    func testAbandonClosesWithoutAMessage() {
        var gate = IMGenerationGate()
        _ = gate.begin(9)
        gate.abandon()
        XCTAssertFalse(gate.isOpen)
        XCTAssertEqual(gate.highWaterMark, 9, "the high-water mark still blocks a replay")
        XCTAssertEqual(gate.begin(9), .rejectStale(current: 9))
    }

    func testEvaluateRoutesEachCommandToTheRightDoor() {
        var gate = IMGenerationGate()
        XCTAssertEqual(gate.evaluate(.commitFinal(generation: 1, text: "x")), .rejectNoSession)
        XCTAssertEqual(gate.evaluate(.beginSession(generation: 1)), .accept)
        XCTAssertEqual(gate.evaluate(.updateVolatile(generation: 1, tail: "x")), .accept)
        XCTAssertEqual(gate.evaluate(.endSession(generation: 1, commit: true)), .accept)
        XCTAssertEqual(gate.evaluate(.updateVolatile(generation: 1, tail: "x")), .rejectNoSession)
    }

    func testCounterIsMonotonicAndSurvivesRelaunch() {
        let counter = IMGenerationCounter()
        let first = counter.next()
        let second = counter.next()
        XCTAssertGreaterThan(second, first)

        // A relaunch seeds from the clock, so the new process hands out numbers
        // above anything the previous one used.
        let relaunched = IMGenerationCounter()
        XCTAssertGreaterThan(relaunched.next(), first - 1)
        XCTAssertGreaterThan(relaunched.current, 0)
    }

    func testCounterIsThreadSafe() {
        let counter = IMGenerationCounter(seed: 0)
        let lock = NSLock()
        var seen: Set<UInt64> = []
        DispatchQueue.concurrentPerform(iterations: 500) { _ in
            let value = counter.next()
            lock.lock()
            seen.insert(value)
            lock.unlock()
        }
        XCTAssertEqual(seen.count, 500, "no two utterances may share a generation")
    }

    func testStaleDecisionsMapToAReportableDetail() {
        XCTAssertEqual(IMGenerationGate.detail(for: .rejectStale(current: 1)), .staleGeneration)
        XCTAssertEqual(IMGenerationGate.detail(for: .rejectNoSession), .noSession)
        XCTAssertEqual(IMGenerationGate.detail(for: .accept), .applied)
    }
}
