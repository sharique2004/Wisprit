import XCTest
@testable import WispritMacInput

/// The two checks that need a real machine, real TCC grants, and a real focused
/// text field. Skipped unless `WISPRIT_MANUAL_INPUT=1`, because they post real
/// keystrokes and create a real event tap on the user's live session:
///
///     WISPRIT_MANUAL_INPUT=1 swift test \
///         --filter WispritMacInputTests.ManualSmokeTests \
///         --scratch-path /tmp/wisprit-build-WispritMacInput
///
/// Equivalent to `python -m wisprit.insert "text"` / `python -m wisprit.hotkey`.
final class ManualSmokeTests: XCTestCase {

    /// 3-second countdown, then insert into whatever is focused. Focus a text
    /// field (TextEdit, a browser field, Terminal) after starting it.
    func testManualInsertSmoke() throws {
        try XCTSkipUnless(ManualInputSmoke.isEnabled,
                          "set WISPRIT_MANUAL_INPUT=1 to run the real-insert smoke")
        let text = ProcessInfo.processInfo.environment["WISPRIT_MANUAL_TEXT"]
            ?? "Hello from Wisprit insert smoke."
        let result = ManualInputSmoke.insert(text: text)
        XCTAssertTrue(result.ok, "insert failed: \(result.method.rawValue) — \(result.detail)")
    }

    /// Installs a real listen-only tap for 10 s and prints the gesture events.
    /// Hold Fn, tap Fn+Arrow, press Esc, press ⌘⌃V and watch the stream.
    func testManualHotkeyListenSmoke() throws {
        try XCTSkipUnless(ManualInputSmoke.isEnabled,
                          "set WISPRIT_MANUAL_INPUT=1 to run the real-tap smoke")
        let seconds = Double(ProcessInfo.processInfo.environment["WISPRIT_MANUAL_SECONDS"] ?? "10") ?? 10
        let events = ManualInputSmoke.listenHotkey(seconds: seconds)
        XCTAssertNotNil(events, "tap creation failed — grant Input Monitoring")
    }

    /// Guard rail: the smoke helpers must stay inert in a normal test run.
    func testSmokeIsGatedOffByDefault() throws {
        try XCTSkipIf(ManualInputSmoke.isEnabled, "manual mode explicitly enabled")
        XCTAssertFalse(ManualInputSmoke.isEnabled)
        XCTAssertEqual(ManualInputSmoke.envVar, "WISPRIT_MANUAL_INPUT")
    }
}
