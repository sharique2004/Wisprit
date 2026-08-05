import CoreGraphics
import Foundation

/// Hand-run smoke checks for the two things unit tests must never do: post real
/// events, and create a real event tap. Both are gated on
/// `WISPRIT_MANUAL_INPUT=1` so nothing here can fire during an ordinary
/// `swift test` run — the user runs these, deliberately, on their own machine.
///
/// Equivalent to `python -m wisprit.insert "text"` and `python -m wisprit.hotkey`.
///
///     WISPRIT_MANUAL_INPUT=1 swift test --filter WispritMacInputTests.ManualSmokeTests \
///         --scratch-path /tmp/wisprit-build-WispritMacInput
public enum ManualInputSmoke {
    public static let envVar = "WISPRIT_MANUAL_INPUT"

    public static var isEnabled: Bool {
        ProcessInfo.processInfo.environment[envVar] == "1"
    }

    /// Print the environment (frontmost app, secure input, AX trust), count
    /// down 3 seconds so the user can focus a text field, then insert.
    @discardableResult
    public static func insert(text: String = "Hello from Wisprit insert smoke.",
                              config: InserterConfig = InserterConfig(),
                              ports: InsertPorts = SystemInsertPorts(),
                              emit: (String) -> Void = { print($0) }) -> InsertResult {
        let inserter = Inserter(ports: ports)
        emit("frontmost app : \(ports.frontmostBundleID() ?? "unknown")")
        emit("secure input  : \(ports.secureInputEnabled() ? "ACTIVE — insertion will be blocked" : "off")")
        emit("accessibility : \(ports.accessibilityTrusted() ? "granted" : "NOT granted — posts would be dropped")")
        emit("\nInserting \"\(text)\" into the focused field in:")
        for i in [3, 2, 1] {
            emit("  \(i)...")
            ports.sleep(1.0)
        }
        let result = inserter.insert(text, config: config)
        emit("\n\(result.ok ? "OK" : "FAILED"): method=\(result.method.rawValue)"
             + (result.detail.isEmpty ? "" : " — \(result.detail)"))
        return result
    }

    /// Install a real listen-only tap on the CURRENT run loop (must be the main
    /// thread) and print gesture events for `seconds`. Returns the events seen,
    /// or nil if the tap could not be created (Input Monitoring not granted).
    @discardableResult
    public static func listenHotkey(trigger: TriggerKey = .fn,
                                    seconds: TimeInterval = 10,
                                    emit: (String) -> Void = { print($0) }) -> [HotkeyEvent]? {
        let queue = HotkeyEventQueue()
        let monitor = HotkeyMonitor(queue: queue, trigger: trigger)
        guard monitor.install() else {
            emit("FAILED to install hotkey tap. Grant Input Monitoring in System "
                 + "Settings → Privacy & Security → Input Monitoring, then retry.")
            return nil
        }
        monitor.setRecording(true)   // so Esc prints in smoke mode
        emit("Listening for '\(trigger.rawValue)' hold/release for \(Int(seconds))s…")

        var seen: [HotkeyEvent] = []
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            CFRunLoopRunInMode(.defaultMode, 0.1, true)
            while let ev = queue.getNowait() {
                seen.append(ev)
                emit(String(format: "  %10.3f  %@", ev.ts, ev.kind.rawValue))
            }
        }
        monitor.uninstall()
        return seen
    }
}
