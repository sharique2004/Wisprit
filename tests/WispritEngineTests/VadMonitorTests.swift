import XCTest
import WispritKit
@testable import WispritEngine

/// The voice-activity witness's accounting (hearing tier 3), pinned without a
/// model: the scorer is scripted, and what is under test is that the monitor
/// is advisory to the bone — inert without a model, window-accurate with one,
/// and never anything but metadata.
final class VadMonitorTests: XCTestCase {

    final class ScriptedScorer: VadScoring, @unchecked Sendable {
        private let lock = NSLock()
        private let beginAnswer: Bool
        private var probabilities: [Double]
        private(set) var scoredWindows = 0

        init(begin: Bool = true, probabilities: [Double] = []) {
            self.beginAnswer = begin
            self.probabilities = probabilities
        }

        func begin() async -> Bool { beginAnswer }

        func score(window: Data) async -> Double? {
            lock.lock(); defer { lock.unlock() }
            scoredWindows += 1
            guard !probabilities.isEmpty else { return nil }
            return probabilities.removeFirst()
        }
    }

    private func window(_ count: Int = 1) -> Data {
        Data(count: VadMonitor.windowBytes * count)
    }

    private func waitUntil(_ deadline: TimeInterval = 2,
                           _ condition: @escaping () -> Bool) {
        let end = Date().addingTimeInterval(deadline)
        while !condition() && Date() < end {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertTrue(condition(), "condition not met within \(deadline)s")
    }

    func testInertWithoutAModel() {
        let monitor = VadMonitor(scorer: ScriptedScorer(begin: false))
        monitor.start()
        monitor.feed(window(3))
        monitor.stop()
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertNil(monitor.latestProbability)
        XCTAssertNil(monitor.firstSpeechMs)
        XCTAssertNil(monitor.speechRatio)
    }

    func testWindowAccounting() {
        let monitor = VadMonitor(scorer: ScriptedScorer(probabilities: [0.1, 0.9, 0.8]))
        monitor.start()
        monitor.feed(window(3))
        monitor.stop()

        waitUntil { monitor.speechRatio != nil && abs(monitor.speechRatio! - 2.0 / 3.0) < 0.001 }
        XCTAssertEqual(monitor.latestProbability, 0.8)
        XCTAssertNotNil(monitor.firstSpeechMs, "the second window crossed the threshold")
    }

    /// Chunks arrive at 100 ms granularity (3200 bytes); windows are 8192.
    /// The monitor accumulates across chunk boundaries.
    func testSubWindowChunksAccumulate() {
        let monitor = VadMonitor(scorer: ScriptedScorer(probabilities: [0.9]))
        monitor.start()
        let chunkBytes = Int(PcmFormat.chunkFrames) * PcmFormat.bytesPerFrame
        for _ in 0..<3 { monitor.feed(Data(count: chunkBytes)) }   // 9600 ≥ 8192
        monitor.stop()

        waitUntil { monitor.speechRatio == 1.0 }
        XCTAssertEqual(monitor.latestProbability, 0.9)
    }

    func testRestartResetsTheFacts() {
        let monitor = VadMonitor(scorer: ScriptedScorer(probabilities: [0.9, 0.1]))
        monitor.start()
        monitor.feed(window())
        monitor.stop()
        waitUntil { monitor.speechRatio == 1.0 }

        monitor.start()
        XCTAssertNil(monitor.latestProbability)
        XCTAssertNil(monitor.firstSpeechMs)
        XCTAssertNil(monitor.speechRatio)
        monitor.feed(window())
        monitor.stop()
        waitUntil { monitor.speechRatio == 0.0 }
        XCTAssertNil(monitor.firstSpeechMs, "the second utterance never crossed the threshold")
    }

    /// `stop()` closes rather than discards: windows already fed still score.
    func testStopDrainsTheTail() {
        let scorer = ScriptedScorer(probabilities: [0.9, 0.9])
        let monitor = VadMonitor(scorer: scorer)
        monitor.start()
        monitor.feed(window(2))
        monitor.stop()
        waitUntil { scorer.scoredWindows == 2 }
    }

    func testFeedBeforeStartIsANoOp() {
        let scorer = ScriptedScorer(probabilities: [0.9])
        let monitor = VadMonitor(scorer: scorer)
        monitor.feed(window())
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertEqual(scorer.scoredWindows, 0)
    }
}
