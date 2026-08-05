import XCTest
@testable import WispritMacInput

/// The gesture logic, driven by synthetic `(keycode, flags)` observations —
/// no event tap, no TCC grant, no keystrokes. Every case here corresponds to a
/// branch of `hotkey.HotkeyListener._callback` / `_watchdog_loop`.
final class HotkeyStateMachineTests: XCTestCase {

    private func machine(_ trigger: TriggerKey = .fn) -> HotkeyStateMachine {
        HotkeyStateMachine(trigger: trigger)
    }

    private func emits(_ d: HotkeyDecision) -> [HotkeyEventKind] { d.emits }

    // --- Fn detection: keycode AND flag ---------------------------------------

    func testFnPressRequiresKeycodeAndFlag() {
        let m = machine()
        let d = m.handle(.flagsChanged(keycode: 63, flags: EventFlags.secondaryFn))
        XCTAssertEqual(emits(d), [.press])
        XCTAssertTrue(m.isTriggerDown)
        XCTAssertTrue(m.isArmed)
    }

    /// Hex bug #89: macOS sets the secondary-Fn flag on arrow/nav/F-keys with
    /// no physical Fn press. Flag-only detection would start dictation on ↑.
    func testFnFlagWithoutKeycode63IsIgnored() {
        let m = machine()
        for navKeycode: Int64 in [126, 125, 123, 124, 116, 121, 115, 119, 96, 122] {
            let d = m.handle(.flagsChanged(keycode: navKeycode, flags: EventFlags.secondaryFn))
            XCTAssertEqual(emits(d), [], "keycode \(navKeycode) must not arm dictation")
        }
        XCTAssertFalse(m.isTriggerDown)
    }

    /// The mirror image: keycode 63 without the Fn bit is a release edge, not a
    /// press. (Some layouts emit keycode 63 with other modifier bits set.)
    func testKeycode63WithoutFnFlagDoesNotPress() {
        let m = machine()
        let d = m.handle(.flagsChanged(keycode: 63, flags: EventFlags.command))
        XCTAssertEqual(emits(d), [])
        XCTAssertFalse(m.isTriggerDown)
    }

    func testPressReleaseCycle() {
        let m = machine()
        XCTAssertEqual(emits(m.handle(.flagsChanged(keycode: 63, flags: EventFlags.secondaryFn))), [.press])
        XCTAssertEqual(emits(m.handle(.flagsChanged(keycode: 63, flags: 0))), [.release])
        XCTAssertFalse(m.isTriggerDown)
        XCTAssertFalse(m.isArmed)
    }

    func testRepeatedFlagsChangedWhileHeldEmitsNothing() {
        let m = machine()
        _ = m.handle(.flagsChanged(keycode: 63, flags: EventFlags.secondaryFn))
        // Auto-repeat / another modifier joining: same "down" state, no new press.
        let d = m.handle(.flagsChanged(keycode: 63, flags: EventFlags.secondaryFn | EventFlags.shiftIshBit))
        XCTAssertEqual(emits(d), [])
    }

    func testReleaseWithoutPressEmitsNothing() {
        let m = machine()
        XCTAssertEqual(emits(m.handle(.flagsChanged(keycode: 63, flags: 0))), [])
    }

    // --- dirty chord ----------------------------------------------------------

    func testDirtyChordCancelsAndSilencesTheRelease() {
        let m = machine()
        XCTAssertEqual(emits(m.handle(.flagsChanged(keycode: 63, flags: EventFlags.secondaryFn))), [.press])
        // Fn+Left-Arrow: the gesture was a chord, not dictation.
        XCTAssertEqual(emits(m.handle(.keyDown(keycode: 123, flags: EventFlags.secondaryFn))), [.cancel])
        XCTAssertFalse(m.isArmed)
        XCTAssertTrue(m.isTriggerDown)
        // The eventual release must NOT emit — the utterance is already dead.
        XCTAssertEqual(emits(m.handle(.flagsChanged(keycode: 63, flags: 0))), [])
    }

    func testOnlyOneCancelPerChord() {
        let m = machine()
        _ = m.handle(.flagsChanged(keycode: 63, flags: EventFlags.secondaryFn))
        XCTAssertEqual(emits(m.handle(.keyDown(keycode: 123, flags: 0))), [.cancel])
        XCTAssertEqual(emits(m.handle(.keyDown(keycode: 124, flags: 0))), [])
    }

    /// A keyDown carrying the trigger's own keycode is not a chord.
    func testTriggerKeycodeKeyDownIsNotAChord() {
        let m = machine()
        _ = m.handle(.flagsChanged(keycode: 63, flags: EventFlags.secondaryFn))
        XCTAssertEqual(emits(m.handle(.keyDown(keycode: 63, flags: EventFlags.secondaryFn))), [])
        XCTAssertTrue(m.isArmed)
    }

    // --- Esc ------------------------------------------------------------------

    func testEscOnlyWhileRecording() {
        let m = machine()
        XCTAssertEqual(emits(m.handle(.keyDown(keycode: 53, flags: 0))), [])
        m.setRecording(true)
        XCTAssertEqual(emits(m.handle(.keyDown(keycode: 53, flags: 0))), [.esc])
        m.setRecording(false)
        XCTAssertEqual(emits(m.handle(.keyDown(keycode: 53, flags: 0))), [])
    }

    /// Esc pressed *during* the hold is a chord first — the cancel branch runs
    /// before the Esc branch, exactly as in the Python.
    func testEscDuringHoldIsAChordCancel() {
        let m = machine()
        m.setRecording(true)
        _ = m.handle(.flagsChanged(keycode: 63, flags: EventFlags.secondaryFn))
        XCTAssertEqual(emits(m.handle(.keyDown(keycode: 53, flags: 0))), [.cancel])
    }

    // --- ⌘⌃V paste-last --------------------------------------------------------

    func testCommandControlVEmitsPasteLast() {
        let m = machine()
        let d = m.handle(.keyDown(keycode: 9, flags: EventFlags.commandControl))
        XCTAssertEqual(emits(d), [.pasteLast])
    }

    func testPlainCommandVIsIgnored() {
        let m = machine()
        XCTAssertEqual(emits(m.handle(.keyDown(keycode: 9, flags: EventFlags.command))), [])
        XCTAssertEqual(emits(m.handle(.keyDown(keycode: 9, flags: EventFlags.control))), [])
        XCTAssertEqual(emits(m.handle(.keyDown(keycode: 9, flags: 0))), [])
    }

    /// Extra modifiers are fine — the test is "contains ⌘ and ⌃".
    func testCommandControlShiftVStillPastes() {
        let m = machine()
        let flags = EventFlags.commandControl | EventFlags.shiftIshBit
        XCTAssertEqual(emits(m.handle(.keyDown(keycode: 9, flags: flags))), [.pasteLast])
    }

    /// While the trigger is held, ⌘⌃V is a chord, not paste-last.
    func testCommandControlVDuringHoldIsAChord() {
        let m = machine()
        _ = m.handle(.flagsChanged(keycode: 63, flags: EventFlags.secondaryFn))
        XCTAssertEqual(emits(m.handle(.keyDown(keycode: 9, flags: EventFlags.commandControl))), [.cancel])
    }

    // --- tap disabled ---------------------------------------------------------

    func testTapDisabledMidHoldReenablesAndCancels() {
        for reason in [TapDisableReason.timeout, .userInput] {
            let m = machine()
            _ = m.handle(.flagsChanged(keycode: 63, flags: EventFlags.secondaryFn))
            let d = m.handle(.tapDisabled(reason: reason))
            XCTAssertTrue(d.reenableTap)
            XCTAssertEqual(d.emits, [.cancel], "\(reason)")
            XCTAssertFalse(m.isTriggerDown)
            XCTAssertFalse(m.isArmed)
        }
    }

    func testTapDisabledWhileIdleReenablesSilently() {
        let m = machine()
        let d = m.handle(.tapDisabled(reason: .timeout))
        XCTAssertTrue(d.reenableTap)
        XCTAssertEqual(d.emits, [])
    }

    /// Disarmed-but-held (a chord already cancelled) must not cancel twice.
    func testTapDisabledAfterChordDoesNotDoubleCancel() {
        let m = machine()
        _ = m.handle(.flagsChanged(keycode: 63, flags: EventFlags.secondaryFn))
        _ = m.handle(.keyDown(keycode: 123, flags: 0))
        let d = m.handle(.tapDisabled(reason: .timeout))
        XCTAssertEqual(d.emits, [])
        XCTAssertTrue(d.reenableTap)
    }

    // --- watchdog -------------------------------------------------------------

    func testWatchdogNoopWhileEnabled() {
        let m = machine()
        XCTAssertEqual(m.watchdogTick(tapEnabled: true), .ok)
    }

    func testWatchdogLogsOncePerStreakAndAlwaysReenables() {
        let m = machine()
        let first = m.watchdogTick(tapEnabled: false)
        XCTAssertTrue(first.reenableTap)
        XCTAssertTrue(first.logGhostWarning)

        // A persistently inert ("ghost") tap must not log every 3 seconds.
        for _ in 0..<5 {
            let d = m.watchdogTick(tapEnabled: false)
            XCTAssertTrue(d.reenableTap)
            XCTAssertFalse(d.logGhostWarning)
        }
        // Recovery re-arms the edge.
        XCTAssertEqual(m.watchdogTick(tapEnabled: true), .ok)
        XCTAssertTrue(m.watchdogTick(tapEnabled: false).logGhostWarning)
    }

    /// A silent disable may have swallowed the release edge; the watchdog must
    /// reset the gesture or the app sits in a permanent "recording" state.
    func testWatchdogCancelsAStuckHold() {
        let m = machine()
        _ = m.handle(.flagsChanged(keycode: 63, flags: EventFlags.secondaryFn))
        let d = m.watchdogTick(tapEnabled: false)
        XCTAssertEqual(d.emits, [.cancel])
        XCTAssertFalse(m.isTriggerDown)
        XCTAssertFalse(m.isArmed)
        // Subsequent cycles in the same streak emit nothing.
        XCTAssertEqual(m.watchdogTick(tapEnabled: false).emits, [])
    }

    // --- right-Option trigger --------------------------------------------------

    func testRightOptionPressRelease() {
        let m = machine(.rightOption)
        XCTAssertEqual(emits(m.handle(.flagsChanged(keycode: 61, flags: EventFlags.alternate))), [.press])
        XCTAssertEqual(emits(m.handle(.flagsChanged(keycode: 61, flags: 0))), [.release])
    }

    func testRightOptionIgnoresLeftOptionKeycode() {
        let m = machine(.rightOption)
        XCTAssertEqual(emits(m.handle(.flagsChanged(keycode: 58, flags: EventFlags.alternate))), [])
    }

    /// PORTED BUG (see `TriggerKey.flagMask`): `maskAlternate` is set by either
    /// Option key, so releasing right-Option while left-Option is still held
    /// leaves the flag set and the release edge is never seen. `hotkey.py`
    /// behaves identically; this test pins the behavior so a future fix is a
    /// deliberate contract change, not an accident.
    func testRightOptionMaskingBugIsPortedAsIs() {
        let m = machine(.rightOption)
        // Left-Option already held (flag set, keycode 58 — ignored above).
        _ = m.handle(.flagsChanged(keycode: 58, flags: EventFlags.alternate))
        // Right-Option down: press fires.
        XCTAssertEqual(emits(m.handle(.flagsChanged(keycode: 61, flags: EventFlags.alternate))), [.press])
        // Right-Option up while left is still down: the flag is STILL set, so
        // no release edge is produced — the gesture sticks.
        XCTAssertEqual(emits(m.handle(.flagsChanged(keycode: 61, flags: EventFlags.alternate))), [])
        XCTAssertTrue(m.isTriggerDown)
        // It unsticks only when the flag finally clears.
        XCTAssertEqual(emits(m.handle(.flagsChanged(keycode: 61, flags: 0))), [.release])
    }

    // --- trigger parsing -------------------------------------------------------

    func testTriggerParsing() {
        XCTAssertEqual(TriggerKey.parse("fn"), .fn)
        XCTAssertEqual(TriggerKey.parse("right_option"), .rightOption)
        XCTAssertEqual(TriggerKey.parse(nil), .fn)
        XCTAssertEqual(TriggerKey.parse("garbage"), .fn)
        XCTAssertEqual(TriggerKey.fn.keycode, 63)
        XCTAssertEqual(TriggerKey.fn.flagMask, 0x800000)
        XCTAssertEqual(TriggerKey.rightOption.keycode, 61)
        XCTAssertEqual(TriggerKey.rightOption.flagMask, 0x80000)
    }

    // --- concurrency ------------------------------------------------------------

    /// `setRecording` (session thread) races the callback thread by design.
    func testRecordingFlagIsThreadSafe() {
        let m = machine()
        let flip = expectation(description: "flips")
        let feed = expectation(description: "feeds")
        DispatchQueue.global().async {
            for i in 0..<20_000 { m.setRecording(i % 2 == 0) }
            flip.fulfill()
        }
        DispatchQueue.global().async {
            for _ in 0..<20_000 { _ = m.handle(.keyDown(keycode: 53, flags: 0)) }
            feed.fulfill()
        }
        wait(for: [flip, feed], timeout: 30)
    }
}

private extension EventFlags {
    /// `kCGEventFlagMaskShift`, used only as "some other modifier" in tests.
    static let shiftIshBit: UInt64 = 0x0002_0000
}
