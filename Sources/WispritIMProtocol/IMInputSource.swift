import Foundation

/// Registration, enabling and selection of the palette input source — as PURE
/// planning, never as an action.
///
/// Nothing in this file calls `TISRegisterInputSource`, `TISEnableInputSource`
/// or `TISSelectInputSource`. It takes a snapshot of the current input-source
/// state and returns the exact calls the MAIN APP's onboarding should make, plus
/// the text to show the user. Two reasons this is worth the indirection:
///
///  * `TISEnableInputSource` is what fires the system's *"<App> wants to activate
///    the third-party input method"* consent dialog. That is a change to the
///    user's system input configuration and it belongs in onboarding, once, with
///    the user watching — never on a hot path, never from a test.
///  * It makes the whole install/enable/select state machine unit-testable with
///    no side effects at all.
///
/// The app is the only caller that turns a `TISCall` into a real call.

// MARK: - Where the bundle lives

/// `TISRegisterInputSource` accepts bundles in `/Library/Input Methods/` or
/// `~/Library/Input Methods/` and nowhere else (TextInputSources.h). Per-user is
/// the right one: no admin rights, and it is also precisely why the input method
/// tier can never ship through the Mac App Store (2.4.5(ii)/(iv) forbid writing
/// into shared locations).
public struct IMInstallLayout: Sendable, Equatable {
    public var home: URL
    public var bundleName: String

    public init(home: URL, bundleName: String = WispritIMNaming.bundleName) {
        self.home = home
        self.bundleName = bundleName
    }

    public var inputMethodsDirectory: URL {
        home.appendingPathComponent("Library/Input Methods", isDirectory: true)
    }

    public var installedBundle: URL {
        inputMethodsDirectory.appendingPathComponent(bundleName, isDirectory: true)
    }

    /// Layout for the current user. Tests pass their own `home`.
    public static var user: IMInstallLayout {
        IMInstallLayout(home: realUserHome)
    }

    /// The user's actual home directory, even from inside a sandbox.
    ///
    /// `FileManager.homeDirectoryForCurrentUser` returns the *container* in a
    /// sandboxed process (`~/Library/Containers/com.wisprit.im/Data`), and the
    /// input method is sandboxed — so asking it where `~/Library/Input Methods`
    /// is would give an answer TIS would never accept. The passwd database is
    /// unaffected by the sandbox.
    public static var realUserHome: URL {
        if let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir {
            let path = String(cString: directory)
            if !path.isEmpty { return URL(fileURLWithPath: path, isDirectory: true) }
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    /// True when this process cannot see the real home — i.e. file-existence
    /// checks under `~/Library/Input Methods` will read false whatever the truth.
    public static var isSandboxed: Bool {
        NSHomeDirectory() != realUserHome.path
    }
}

// MARK: - Observed state

/// A read-only snapshot of what the system thinks about our input source.
/// The app fills this in from `TISCreateInputSourceList` + `FileManager`; every
/// function below is a pure function of it.
public struct InputMethodStatus: Sendable, Equatable {
    /// `WispritIM.app` exists at the install location.
    public var bundleInstalled: Bool
    /// The source id shows up in `TISCreateInputSourceList(includeAllInstalled: true)`.
    public var registered: Bool
    /// `kTISPropertyInputSourceIsEnabled` — the once-per-machine consent.
    public var enabled: Bool
    /// `kTISPropertyInputSourceIsSelected` — cheap, no prompt, per session.
    public var selected: Bool
    /// `CFBundleVersion` of the installed bundle, if it could be read.
    public var installedVersion: String?
    /// `CFBundleVersion` of the bundle shipped inside `Wisprit.app`.
    public var stagedVersion: String?

    public init(bundleInstalled: Bool = false,
                registered: Bool = false,
                enabled: Bool = false,
                selected: Bool = false,
                installedVersion: String? = nil,
                stagedVersion: String? = nil) {
        self.bundleInstalled = bundleInstalled
        self.registered = registered
        self.enabled = enabled
        self.selected = selected
        self.installedVersion = installedVersion
        self.stagedVersion = stagedVersion
    }

    public var isStale: Bool {
        guard let installedVersion, let stagedVersion else { return false }
        return installedVersion != stagedVersion
    }
}

// MARK: - The calls

/// One system call the app should make, described exactly. `rendered` is what
/// goes in the log and in the doctor output, so a user can see precisely what
/// Wisprit did to their input sources.
public enum TISCall: Sendable, Equatable {
    /// Not a TIS call — copy the staged bundle into `~/Library/Input Methods/`.
    case installBundle(from: URL, to: URL)
    /// Remove a stale installed bundle before copying a new one.
    case removeInstalledBundle(at: URL)
    case registerInputSource(bundleURL: URL)
    /// PROMPTS THE USER. Onboarding only, exactly once.
    case enableInputSource(sourceID: String)
    /// Silent. Safe per session.
    case selectInputSource(sourceID: String)
    case deselectInputSource(sourceID: String)

    /// Does this call put a system dialog in front of the user?
    public var promptsUser: Bool {
        if case .enableInputSource = self { return true }
        return false
    }

    public var rendered: String {
        switch self {
        case .installBundle(let from, let to):
            return "cp -R \(from.path) \(to.path)"
        case .removeInstalledBundle(let at):
            return "rm -rf \(at.path)"
        case .registerInputSource(let url):
            return "TISRegisterInputSource(\(url.path))"
        case .enableInputSource(let id):
            return "TISEnableInputSource(\(id))"
        case .selectInputSource(let id):
            return "TISSelectInputSource(\(id))"
        case .deselectInputSource(let id):
            return "TISDeselectInputSource(\(id))"
        }
    }
}

// MARK: - Preflight

public enum IMPreflightVerdict: Sendable, Equatable {
    /// Registered, enabled, and selected — streaming is available right now.
    case ready
    /// Everything is in place but the source is not currently selected. Not an
    /// error: with `IMSelectionPolicy.perUtterance` this is the resting state.
    case notSelected
    case needsInstall
    case needsRegistration
    case needsEnable
    /// A newer `WispritIM.app` ships inside the app than the one installed.
    case needsUpdate(installed: String?, staged: String?)

    public var isUsable: Bool {
        switch self {
        case .ready, .notSelected: return true
        default: return false
        }
    }
}

public enum IMPreflight {
    /// Order matters: the first unmet precondition is the one to report, because
    /// fixing it is what unblocks the next check.
    public static func evaluate(_ status: InputMethodStatus) -> IMPreflightVerdict {
        if !status.bundleInstalled { return .needsInstall }
        if status.isStale { return .needsUpdate(installed: status.installedVersion, staged: status.stagedVersion) }
        if !status.registered { return .needsRegistration }
        if !status.enabled { return .needsEnable }
        return status.selected ? .ready : .notSelected
    }

    /// Doctor / onboarding copy. Exact, and honest about the one prompt.
    public static func remedy(for verdict: IMPreflightVerdict,
                              layout: IMInstallLayout = .user) -> String {
        switch verdict {
        case .ready:
            return "Live in-field streaming is ready."
        case .notSelected:
            return "Installed and enabled. Wisprit selects it when you start dictating."
        case .needsInstall:
            return "Install the input method: Wisprit copies WispritIM.app into "
                + "\(layout.inputMethodsDirectory.path). Use the menu bar icon ▸ "
                + "Enable Live Typing…"
        case .needsRegistration:
            return "WispritIM.app is in place but macOS has not registered it. "
                + "Use the menu bar icon ▸ Enable Live Typing… to re-register, "
                + "or log out and back in."
        case .needsEnable:
            return "macOS needs your permission to activate the Wisprit input method. "
                + "Wisprit will ask once; approve the dialog that says it wants to "
                + "activate a third-party input method. (You can also do it by hand in "
                + "System Settings ▸ Keyboard ▸ Input Sources.)"
        case .needsUpdate(let installed, let staged):
            return "A newer input method ships with this Wisprit "
                + "(installed \(installed ?? "unknown"), bundled \(staged ?? "unknown")). "
                + "Use the menu bar icon ▸ Enable Live Typing… to update."
        }
    }
}

// MARK: - Selection policy

/// When to hold the palette input source selected.
///
/// Research finding V8: an enabled-but-*unselected* palette input method is not
/// a resident process, so selecting it on Fn-down puts a process launch on the
/// latency-critical path. Palette sources are explicitly "zero or more" and
/// selecting one "has no effect on other input sources" (TextInputSources.h), so
/// keeping ours selected for the whole app session is legal, invisible (with
/// `ComponentInvisibleInSystemUI`), and removes both the launch tax and the
/// select→activateServer timing question. Apple's own Dictation uses the other
/// policy, which is why both exist here — the spike measures them.
public enum IMSelectionPolicy: String, Sendable, Equatable, CaseIterable {
    /// Select lazily on the first utterance, then keep the palette source
    /// selected between utterances (released after a 20 s idle timeout), so
    /// the IM process stays hot. Default.
    case warm
    /// Select on Fn-down, deselect on Fn-up. Mirrors `com.apple.inputmethod.ironwood`;
    /// pays a cold start on the first utterance after any idle period.
    case perUtterance

    public static let `default` = IMSelectionPolicy.warm
}

// MARK: - Plans

public struct IMPlan: Sendable, Equatable {
    public var calls: [TISCall]
    public var verdict: IMPreflightVerdict
    /// Copy for the user, when the plan needs their consent or their hands.
    public var userMessage: String?

    public init(calls: [TISCall], verdict: IMPreflightVerdict, userMessage: String? = nil) {
        self.calls = calls
        self.verdict = verdict
        self.userMessage = userMessage
    }

    public var promptsUser: Bool { calls.contains { $0.promptsUser } }
    public var isNoop: Bool { calls.isEmpty }
}

public enum IMOnboarding {
    /// The full install path: copy → register → enable. Returns only the steps
    /// that are actually missing, so re-running onboarding on a healthy install
    /// is a no-op and never re-prompts.
    ///
    /// - Parameter stagedBundle: `Wisprit.app/Contents/Library/InputMethods/WispritIM.app`.
    public static func plan(status: InputMethodStatus,
                            stagedBundle: URL,
                            layout: IMInstallLayout = .user,
                            sourceID: String = WispritIMNaming.inputSourceID) -> IMPlan {
        let verdict = IMPreflight.evaluate(status)
        var calls: [TISCall] = []
        let installed = layout.installedBundle

        switch verdict {
        case .ready, .notSelected:
            return IMPlan(calls: [], verdict: verdict, userMessage: nil)
        case .needsInstall:
            calls.append(.installBundle(from: stagedBundle, to: installed))
            calls.append(.registerInputSource(bundleURL: installed))
            calls.append(.enableInputSource(sourceID: sourceID))
        case .needsUpdate:
            calls.append(.removeInstalledBundle(at: installed))
            calls.append(.installBundle(from: stagedBundle, to: installed))
            calls.append(.registerInputSource(bundleURL: installed))
            // Enabling survives an in-place replacement; only re-enable if the
            // snapshot says it is not enabled.
            if !status.enabled { calls.append(.enableInputSource(sourceID: sourceID)) }
        case .needsRegistration:
            calls.append(.registerInputSource(bundleURL: installed))
            if !status.enabled { calls.append(.enableInputSource(sourceID: sourceID)) }
        case .needsEnable:
            calls.append(.enableInputSource(sourceID: sourceID))
        }

        return IMPlan(calls: calls,
                      verdict: verdict,
                      userMessage: IMPreflight.remedy(for: verdict, layout: layout))
    }

    /// What to call when Wisprit launches (or when the user turns live streaming
    /// on). Under `.warm` this selects the source once and leaves it selected.
    public static func startupPlan(status: InputMethodStatus,
                                   policy: IMSelectionPolicy = .default,
                                   sourceID: String = WispritIMNaming.inputSourceID) -> IMPlan {
        let verdict = IMPreflight.evaluate(status)
        guard verdict.isUsable else { return IMPlan(calls: [], verdict: verdict,
                                                    userMessage: IMPreflight.remedy(for: verdict)) }
        guard policy == .warm, !status.selected else {
            return IMPlan(calls: [], verdict: verdict)
        }
        return IMPlan(calls: [.selectInputSource(sourceID: sourceID)], verdict: verdict)
    }

    /// What to call on Fn-down. Empty under `.warm` when the source is already
    /// selected — which is the entire point of `.warm`.
    public static func sessionStartPlan(status: InputMethodStatus,
                                        policy: IMSelectionPolicy = .default,
                                        sourceID: String = WispritIMNaming.inputSourceID) -> IMPlan {
        let verdict = IMPreflight.evaluate(status)
        guard verdict.isUsable else { return IMPlan(calls: [], verdict: verdict,
                                                    userMessage: IMPreflight.remedy(for: verdict)) }
        if status.selected { return IMPlan(calls: [], verdict: verdict) }
        return IMPlan(calls: [.selectInputSource(sourceID: sourceID)], verdict: verdict)
    }

    /// What to call on Fn-up. Under `.warm`, nothing: staying selected is what
    /// keeps the IM process warm for the next utterance.
    public static func sessionEndPlan(status: InputMethodStatus,
                                      policy: IMSelectionPolicy = .default,
                                      sourceID: String = WispritIMNaming.inputSourceID) -> IMPlan {
        let verdict = IMPreflight.evaluate(status)
        guard policy == .perUtterance, status.selected else {
            return IMPlan(calls: [], verdict: verdict)
        }
        return IMPlan(calls: [.deselectInputSource(sourceID: sourceID)], verdict: verdict)
    }

    /// Uninstall, for the "turn live streaming off" switch. Deselect first, then
    /// remove the bundle; the source disappears from the enabled list with it.
    public static func uninstallPlan(status: InputMethodStatus,
                                     layout: IMInstallLayout = .user,
                                     sourceID: String = WispritIMNaming.inputSourceID) -> IMPlan {
        var calls: [TISCall] = []
        if status.selected { calls.append(.deselectInputSource(sourceID: sourceID)) }
        if status.bundleInstalled { calls.append(.removeInstalledBundle(at: layout.installedBundle)) }
        return IMPlan(calls: calls,
                      verdict: IMPreflight.evaluate(status),
                      userMessage: calls.isEmpty ? nil
                        : "Removing the Wisprit input method. Dictation keeps working; "
                        + "text is pasted when you finish speaking instead of appearing as you speak.")
    }
}
