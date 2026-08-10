import Foundation

/// Hard kill switch, mirroring `LiveTypingEnvironment` (`WISPRIT_NO_IM=1`)
/// exactly: set `WISPRIT_NO_CONTEXT=1` and no context capture happens in this
/// process no matter what the settings say. The escape hatch for a machine
/// that must never read screen text — CI, a shared box, a demo.
public enum ContextEnvironment {
    /// Set `WISPRIT_NO_CONTEXT=1` to disable every context read in this process.
    public static var isDisabled: Bool {
        isDisabled(in: ProcessInfo.processInfo.environment)
    }

    /// Same rule against an explicit environment — what tests pass, since
    /// `ProcessInfo`'s dictionary is captured once per process.
    public static func isDisabled(in environment: [String: String]) -> Bool {
        let value = environment["WISPRIT_NO_CONTEXT"] ?? ""
        return value == "1" || value.lowercased() == "true"
    }
}

/// Why a capture (or a captured snapshot) was turned down. Raw values land in
/// metrics (`ctx:` field), so refusing has to be as readable as succeeding.
public enum ContextRefusal: String, Equatable, Sendable {
    /// `WISPRIT_NO_CONTEXT=1` — outranks every setting.
    case killSwitch
    /// The `context_awareness` consent toggle is off (the default).
    case disabled
    /// The frontmost app is on the exclusion list — password managers and
    /// secure-input contexts are never read, even with consent granted.
    case excludedApp
    /// The capture outlived its time budget; biasing this utterance with it
    /// would be biasing toward the past.
    case stale
}

/// The pure gate in front of every context read. Holds no platform state and
/// performs no IO: the session layer asks it "may I capture?" at key-down and
/// "may I still use this?" at finish, and it answers from its own fields plus
/// the clock values the caller hands in.
public struct ContextPolicy: Sendable, Equatable {

    /// Apps whose text is never read. Password managers plus the system's own
    /// credential surfaces; compared case-insensitively because bundle IDs in
    /// the wild are sloppier than the spec says.
    public static let defaultExcludedBundleIDs: Set<String> = [
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.apple.keychainaccess",
        "com.apple.loginwindow",
        "com.apple.passwords",
        "com.apple.securityagent",
        "com.bitwarden.desktop",
        "com.dashlane.dashlane",
        "com.lastpass.lastpassmacdesktop",
        "org.keepassxc.keepassxc",
    ]

    /// Consent flag, default OFF — flipped only by the deliberate-act consent
    /// flow, never by code.
    public var enabled: Bool
    /// Stored lowercased; `refusalToCapture` lowercases what it is given.
    public var excludedBundleIDs: Set<String>
    /// Seconds a capture stays usable: started at T, stale strictly after
    /// T + budget. Generous relative to a capture (~ms) so only a genuinely
    /// wedged reader ever trips it.
    public var captureBudget: TimeInterval
    /// Per-field character cap applied by `clamped(_:)`. 800 on each side of
    /// the cursor comfortably covers the 600-char extraction budget.
    public var maxFieldChars: Int

    public init(enabled: Bool = false,
                excludedBundleIDs: Set<String> = ContextPolicy.defaultExcludedBundleIDs,
                captureBudget: TimeInterval = 5.0,
                maxFieldChars: Int = 800) {
        self.enabled = enabled
        self.excludedBundleIDs = Set(excludedBundleIDs.map { $0.lowercased() })
        self.captureBudget = captureBudget
        self.maxFieldChars = maxFieldChars
    }

    // MARK: - Gating

    /// nil means "capture away". Checked in severity order: the kill switch
    /// outranks consent, consent outranks the app list.
    public func refusalToCapture(
        bundleID: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ContextRefusal? {
        if ContextEnvironment.isDisabled(in: environment) { return .killSwitch }
        if !enabled { return .disabled }
        if excludedBundleIDs.contains(bundleID.lowercased()) { return .excludedApp }
        return nil
    }

    /// A capture started at `startedAt` with this policy's budget is stale
    /// strictly after `startedAt + captureBudget`.
    public func isStale(startedAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(startedAt) > captureBudget
    }

    /// Use-time recheck: everything capture-time checked (settings can flip
    /// mid-utterance) plus staleness against the snapshot's own clock.
    public func refusalToUse(
        _ snapshot: ContextSnapshot,
        now: Date = Date(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ContextRefusal? {
        if let refusal = refusalToCapture(bundleID: snapshot.bundleID, environment: environment) {
            return refusal
        }
        if isStale(startedAt: snapshot.capturedAt, now: now) { return .stale }
        return nil
    }

    // MARK: - Clamping

    /// Character caps, cursor-anchored: `before` keeps its END, `selected` and
    /// `after` keep their STARTS — the text nearest the insertion point is the
    /// text worth extracting from. Grapheme-safe by construction (`Character`
    /// operations, never bytes).
    public func clamped(_ snapshot: ContextSnapshot) -> ContextSnapshot {
        var clamped = snapshot
        clamped.before = String(snapshot.before.suffix(maxFieldChars))
        clamped.selected = String(snapshot.selected.prefix(maxFieldChars))
        clamped.after = String(snapshot.after.prefix(maxFieldChars))
        return clamped
    }
}
