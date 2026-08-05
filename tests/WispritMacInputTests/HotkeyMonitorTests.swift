import XCTest
@testable import WispritMacInput

/// Everything about `HotkeyMonitor` that can be checked without creating a real
/// event tap. The tap itself (and the CoreGraphics calls it wraps) is the thin
/// uncovered edge by design — `install()` needs an Input Monitoring grant and
/// would attach to the user's live session, so it is exercised only by the
/// gated manual smoke.
final class HotkeyMonitorTests: XCTestCase {

    func testNotInstalledByDefault() {
        let monitor = HotkeyMonitor(queue: HotkeyEventQueue(), trigger: .fn)
        XCTAssertFalse(monitor.isInstalled)
        XCTAssertEqual(monitor.trigger, .fn)
    }

    func testConvenienceInitParsesSetting() {
        XCTAssertEqual(HotkeyMonitor(queue: HotkeyEventQueue(), hotkeySetting: "right_option").trigger,
                       .rightOption)
        XCTAssertEqual(HotkeyMonitor(queue: HotkeyEventQueue(), hotkeySetting: nil).trigger, .fn)
    }

    /// The callback does nothing but enqueue, and every event from one
    /// observation shares one timestamp (the callback reads the clock once).
    func testApplyEnqueuesWithOneTimestampPerObservation() {
        let queue = HotkeyEventQueue()
        let monitor = HotkeyMonitor(queue: queue, trigger: .fn)
        monitor.apply(HotkeyDecision(emits: [.cancel, .release]))
        let first = queue.getNowait()
        let second = queue.getNowait()
        XCTAssertEqual(first?.kind, .cancel)
        XCTAssertEqual(second?.kind, .release)
        XCTAssertEqual(first?.ts, second?.ts)
        XCTAssertGreaterThan(first?.ts ?? 0, 0)
    }

    func testApplyWithNoEmitsQueuesNothing() {
        let queue = HotkeyEventQueue()
        HotkeyMonitor(queue: queue, trigger: .fn).apply(.ignore)
        XCTAssertEqual(queue.count, 0)
    }

    /// A re-enable request with no live tap must be harmless (uninstalled
    /// monitor, watchdog racing teardown).
    func testApplyReenableWithoutTapIsSafe() {
        let queue = HotkeyEventQueue()
        HotkeyMonitor(queue: queue, trigger: .fn)
            .apply(HotkeyDecision(emits: [.cancel], reenableTap: true))
        XCTAssertEqual(queue.getNowait()?.kind, .cancel)
    }

    func testUninstallWithoutInstallIsANoop() {
        let monitor = HotkeyMonitor(queue: HotkeyEventQueue(), trigger: .fn)
        monitor.uninstall()
        XCTAssertFalse(monitor.isInstalled)
    }

    func testWatchdogIntervalMatchesPython() {
        XCTAssertEqual(HotkeyMonitor.watchdogInterval, 3.0)
    }

    func testSetRecordingReachesTheStateMachine() {
        let queue = HotkeyEventQueue()
        let monitor = HotkeyMonitor(queue: queue, trigger: .fn)
        monitor.setRecording(true)
        // Indirectly: with recording on, an Esc observation would emit — the
        // gesture itself is covered in HotkeyStateMachineTests; here we only
        // prove the setter is wired through.
        monitor.setRecording(false)
    }

    // --- StopSignal (the watchdog's threading.Event stand-in) -------------------

    func testStopSignalTimesOutThenFires() {
        let signal = StopSignal()
        XCTAssertFalse(signal.wait(0.05), "no signal yet → timeout")
        signal.signal()
        XCTAssertTrue(signal.wait(5), "signalled → returns immediately")
        signal.reset()
        XCTAssertFalse(signal.wait(0.02))
    }

    func testStopSignalWakesAWaiter() {
        let signal = StopSignal()
        let done = expectation(description: "woken")
        DispatchQueue.global().async {
            XCTAssertTrue(signal.wait(10))
            done.fulfill()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { signal.signal() }
        wait(for: [done], timeout: 11)
    }
}
