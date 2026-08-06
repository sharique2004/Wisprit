#if os(macOS)
import AppKit
import CoreGraphics
import Foundation
import WispritKit

/// Turns a `SetupFixKind` into the real system call behind it.
///
/// Two of these are the whole point of the window. `CGRequestListenEventAccess`
/// is what puts Wisprit into the Input Monitoring list at all — macOS never
/// raises that prompt for a listen-only tap on its own — and the relaunch is
/// what makes a granted Input Monitoring toggle actually take effect, because
/// the grant binds when the event tap is created.
///
/// Nothing here grants anything by itself: every path either raises Apple's own
/// prompt or opens the pane where the user decides.
@MainActor
public struct SetupFixRunner {
    /// The existing "Enable Live Typing…" onboarding, injected so this type does
    /// not reach into the app controller.
    public var enableLiveTyping: () -> Void
    public var relaunch: () -> Void

    public init(enableLiveTyping: @escaping () -> Void = {},
                relaunch: @escaping () -> Void = {}) {
        self.enableLiveTyping = enableLiveTyping
        self.relaunch = relaunch
    }

    public func run(_ kind: SetupFixKind) {
        switch kind {
        case .none:
            return
        case .requestMicrophone:
            // Apple's own prompt; only appears while the status is undetermined,
            // which is exactly when this fix is offered.
            Permissions.requestMicrophone()
        case .requestInputMonitoring:
            // Ask first (this is what lands the app in the list), then show the
            // list — the request alone never puts a toggle in front of the user.
            if !CGPreflightListenEventAccess() {
                CGRequestListenEventAccess()
            }
            open(kind.settingsURL)
        case .openAccessibilitySettings:
            // Raises the "wants to control this computer" dialog AND registers
            // the app in the list, so the pane it opens has a row to switch on.
            Permissions.requestAccessibilityPrompt()
            open(kind.settingsURL)
        case .openMicrophoneSettings, .openKeyboardSettings, .openAppleIntelligenceSettings:
            open(kind.settingsURL)
        case .enableLiveTyping:
            enableLiveTyping()
        case .relaunch:
            relaunch()
        }
    }

    private func open(_ urlString: String?) {
        guard let urlString, let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Quit and start again, as one action.
///
/// It cannot be done in-process: the single-instance lock is held until this
/// process exits, so the replacement is launched by a detached `open` that waits
/// for us to go away first. `open` (not `NSWorkspace`) because the launch has to
/// outlive the process asking for it.
public enum AppRelaunch {

    /// Seconds the helper waits before relaunching — long enough for
    /// `terminate()` to release the flock and for AppKit to finish quitting.
    public static let delaySeconds = 1

    /// The shell the helper runs. Exposed so the quoting is testable without
    /// actually restarting anything.
    public static func helperCommand(bundlePath: String, delay: Int = delaySeconds) -> String {
        "sleep \(delay); /usr/bin/open \(shellQuoted(bundlePath))"
    }

    static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Spawn the helper, then hand back to the caller to terminate. Returns
    /// false when the helper could not be spawned — in that case the caller must
    /// NOT quit, or the user is left with nothing running.
    @discardableResult
    public static func spawnHelper(bundlePath: String = Bundle.main.bundleURL.path) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", helperCommand(bundlePath: bundlePath)]
        do {
            try process.run()
            return true
        } catch {
            WLog.logger("window").error("could not spawn the relaunch helper")
            return false
        }
    }
}
#endif
