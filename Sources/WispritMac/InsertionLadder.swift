import Foundation
import WispritIMProtocol
import WispritKit

/// The five-rung insertion ladder from `docs/research/apps-feasibility.md`.
///
///   1. `imStreaming`   — palette input method: underlined live tail + committed
///                        chunks, one undo step per chunk, works in terminals,
///                        needs neither Accessibility nor a posted keystroke.
///   2. `imCommit`      — an IM client exists but marked text misbehaved
///                        (Java/Swing, Qt, some games): no live tail, one
///                        `insertText:` at the end.
///   3. `paste`         — today's clipboard dance, byte-for-byte.
///   4. `typed`         — clipboard-hostile contexts (the terminal bundle ids).
///   5. `blockedSecure` — Secure Event Input, which defeats the IM tier too
///                        (TN2150) and every other rung with it.
///
/// Rungs 3–5 are `WispritMacInput.Inserter`'s existing cascade and it stays the
/// authority on them: it re-checks Secure Input and AX trust at the moment of
/// insertion, because both can change between the key-down that picked a tier and
/// the paste half a second later. What the ladder decides here is (a) whether the
/// input-method rungs are on the table at all and (b) what to write in
/// `metrics.log`, and it does that as a pure function so the whole policy is
/// testable with no TCC grant and no live text field.
public enum InsertionTier: String, Sendable, Equatable, CaseIterable {
    case imStreaming = "im_streaming"
    case imCommit = "im_commit"
    case paste
    // Raw values match `InsertResult.Method` so `metrics.log`'s `outcome` field
    // stays one vocabulary across the tiers.
    case typed = "type"
    case blockedSecure = "blocked_secure"

    /// 1…5, matching the ladder in the research doc.
    public var rung: Int {
        switch self {
        case .imStreaming: return 1
        case .imCommit: return 2
        case .paste: return 3
        case .typed: return 4
        case .blockedSecure: return 5
        }
    }

    /// True for the two rungs served by `WispritIM.app`.
    public var usesInputMethod: Bool { self == .imStreaming || self == .imCommit }
    /// Only rung 1 puts provisional text in the field while you speak — the pill
    /// bubble is suppressed exactly when this is true.
    public var streamsLiveTail: Bool { self == .imStreaming }

    /// The next rung down. Downgrading is always one step: a client that refused
    /// marked text may still accept a commit, and a client that refuses a commit
    /// can still be pasted into.
    public var lowered: InsertionTier {
        switch self {
        case .imStreaming: return .imCommit
        case .imCommit: return .paste
        case .paste: return .typed
        case .typed, .blockedSecure: return .blockedSecure
        }
    }

    /// Map an `IMDeliveryTier` (the input method's own vocabulary) onto the
    /// ladder. `.unsupported` means "not an IM rung at all".
    public static func fromDelivery(_ delivery: IMDeliveryTier) -> InsertionTier? {
        switch delivery {
        case .markedStreaming: return .imStreaming
        case .commitOnly: return .imCommit
        case .unsupported: return nil
        }
    }
}

/// Everything the ladder needs to know, sampled at key-down.
public struct InsertionContext: Sendable, Equatable {
    /// The `live_typing` setting. Off by default: the input-method tier only ever
    /// engages after the user has run onboarding and switched it on.
    public var liveTypingEnabled: Bool
    /// `IMPreflight.evaluate(status).isUsable` — installed, registered, enabled.
    public var inputMethodUsable: Bool
    /// The `WispritIM.app` process answered a message just now.
    public var inputMethodReachable: Bool
    /// What the input method reported about the focused field, or nil if it never
    /// got a client.
    public var capabilities: IMClientCapabilities?
    /// The worst verdict this bundle id has earned so far this launch.
    public var cachedVerdict: IMDeliveryTier?
    /// `Permissions.secureInput().active` — a hard stop for every rung.
    public var secureInputActive: Bool
    /// Frontmost application, for the terminal rung.
    public var frontmostBundleID: String?
    /// `terminal_bundle_ids` from settings.
    public var terminalBundleIDs: [String]

    public init(liveTypingEnabled: Bool = false,
                inputMethodUsable: Bool = false,
                inputMethodReachable: Bool = false,
                capabilities: IMClientCapabilities? = nil,
                cachedVerdict: IMDeliveryTier? = nil,
                secureInputActive: Bool = false,
                frontmostBundleID: String? = nil,
                terminalBundleIDs: [String] = []) {
        self.liveTypingEnabled = liveTypingEnabled
        self.inputMethodUsable = inputMethodUsable
        self.inputMethodReachable = inputMethodReachable
        self.capabilities = capabilities
        self.cachedVerdict = cachedVerdict
        self.secureInputActive = secureInputActive
        self.frontmostBundleID = frontmostBundleID
        self.terminalBundleIDs = terminalBundleIDs
    }
}

public enum InsertionLadder {

    /// Pick the highest rung the context actually supports.
    public static func tier(_ context: InsertionContext) -> InsertionTier {
        // Secure Event Input routes keystrokes straight to the focused app and
        // breaks input methods as well as event taps. Nothing above rung 5 is
        // reachable, and pretending otherwise would silently drop the text.
        if context.secureInputActive { return .blockedSecure }

        if let imTier = inputMethodTier(context) { return imTier }

        if let bundleID = context.frontmostBundleID,
           context.terminalBundleIDs.contains(bundleID) {
            return .typed
        }
        return .paste
    }

    /// Rungs 1–2, or nil when the input method is not on the table.
    static func inputMethodTier(_ context: InsertionContext) -> InsertionTier? {
        guard context.liveTypingEnabled,
              context.inputMethodUsable,
              context.inputMethodReachable
        else { return nil }

        // A cached `commitOnly` verdict is what makes the downgrade sticky: this
        // bundle already proved it cannot hold marked text, so we never flash a
        // broken live tail at the user a second time.
        let healthy = (context.cachedVerdict ?? .markedStreaming) == .markedStreaming
        let decided = IMDeliveryTier.decide(capabilities: context.capabilities,
                                            markedTextHealthy: healthy)
        // Worst-of: a fresh probe never promotes a bundle above its cached floor.
        let effective = worst(decided, context.cachedVerdict)
        return InsertionTier.fromDelivery(effective)
    }

    /// `markedStreaming` > `commitOnly` > `unsupported`.
    public static func rank(_ tier: IMDeliveryTier) -> Int {
        switch tier {
        case .markedStreaming: return 2
        case .commitOnly: return 1
        case .unsupported: return 0
        }
    }

    static func worst(_ lhs: IMDeliveryTier, _ rhs: IMDeliveryTier?) -> IMDeliveryTier {
        guard let rhs else { return lhs }
        return rank(rhs) < rank(lhs) ? rhs : lhs
    }
}

/// One app's learned delivery verdict, in a shape the window can render.
///
/// Deliberately not `BundleCapabilityCache.Entry`: a view has no use for the
/// timestamp, and a value type with no reference to the cache is what lets the
/// list cross into the UI without carrying the lock with it.
public struct BundleVerdict: Sendable, Equatable, Identifiable {
    public var bundleID: String
    public var tier: IMDeliveryTier
    public var reason: String

    public var id: String { bundleID }

    public init(bundleID: String, tier: IMDeliveryTier, reason: String = "") {
        self.bundleID = bundleID
        self.tier = tier
        self.reason = reason
    }

    /// The last path component of a bundle id is the closest thing to an app
    /// name available without asking LaunchServices — "com.microsoft.VSCode"
    /// reads as "VSCode".
    public var displayName: String {
        bundleID.split(separator: ".").last.map(String.init) ?? bundleID
    }

    /// What actually happens in this app now, in the user's terms.
    public var behaviour: String {
        switch tier {
        case .markedStreaming: return "types as you speak"
        case .commitOnly: return "types in chunks, without the live preview"
        case .unsupported: return "pastes the finished text at the end"
        }
    }
}

/// Per-bundle-id memory of what the input method managed to do in each app.
///
/// Monotone by design: a verdict only ever gets worse within one launch. An app
/// that refused marked text once will refuse it again, and re-probing costs the
/// user a visible flicker each time. `forget` exists for the case where the
/// verdict really can change — a relaunched target app, or a user asking for a
/// re-probe from Doctor.
public final class BundleCapabilityCache: @unchecked Sendable {

    public struct Entry: Sendable, Equatable {
        public var tier: IMDeliveryTier
        public var reason: String
        public var updatedAt: Date

        public init(tier: IMDeliveryTier, reason: String = "", updatedAt: Date = Date()) {
            self.tier = tier
            self.reason = reason
            self.updatedAt = updatedAt
        }
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private let log = WLog.logger("live-typing")

    public init() {}

    public func verdict(for bundleID: String?) -> IMDeliveryTier? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        lock.lock(); defer { lock.unlock() }
        return entries[bundleID]?.tier
    }

    public func entry(for bundleID: String) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        return entries[bundleID]
    }

    /// Every app the ladder has learned cannot take live text, newest first.
    ///
    /// Read-only, and the reason it exists is honesty: the window used to promise
    /// "types into the field as you speak" unconditionally, while this cache was
    /// quietly recording the apps where that had already stopped being true. The
    /// user who dictated into one of them concluded the feature was broken.
    public func downgraded() -> [BundleVerdict] {
        lock.lock(); defer { lock.unlock() }
        return entries
            .filter { $0.value.tier != .markedStreaming }
            .sorted { $0.value.updatedAt > $1.value.updatedAt }
            .map { BundleVerdict(bundleID: $0.key, tier: $0.value.tier, reason: $0.value.reason) }
    }

    /// Record an observation. Never promotes: the stored verdict is the worst one
    /// seen so far.
    @discardableResult
    public func observe(_ tier: IMDeliveryTier, for bundleID: String?,
                        reason: String = "", now: Date = Date()) -> IMDeliveryTier? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        lock.lock(); defer { lock.unlock() }
        let effective = InsertionLadder.worst(tier, entries[bundleID]?.tier)
        let previous = entries[bundleID]?.tier
        entries[bundleID] = Entry(tier: effective,
                                  reason: effective == tier ? reason : (entries[bundleID]?.reason ?? ""),
                                  updatedAt: now)
        if previous != effective {
            log.info("""
                \(bundleID, privacy: .public): delivery tier \
                \(previous?.rawValue ?? "unknown", privacy: .public) → \
                \(effective.rawValue, privacy: .public)\
                \(reason.isEmpty ? "" : " (\(reason))", privacy: .public)
                """)
        }
        return effective
    }

    /// The client refused `setMarkedText:` — live tail off, commits still fine.
    @discardableResult
    public func downgradeMarkedText(for bundleID: String?, reason: String) -> IMDeliveryTier? {
        observe(.commitOnly, for: bundleID, reason: reason)
    }

    /// The client refused `insertText:`, lost us, or never supported Unicode —
    /// the whole input-method tier is off for this app.
    @discardableResult
    public func downgradeToPaste(for bundleID: String?, reason: String) -> IMDeliveryTier? {
        observe(.unsupported, for: bundleID, reason: reason)
    }

    /// Translate an edit/commit failure into the right downgrade. Details that
    /// describe a *transient* condition (a stale generation, a field the user
    /// changed under us) deliberately do NOT poison the cache.
    @discardableResult
    public func downgrade(for bundleID: String?, detail: IMEditDetail,
                          note: String = "") -> IMDeliveryTier? {
        switch detail {
        case .notSupported:
            return downgradeMarkedText(for: bundleID, reason: note.isEmpty ? "marked text refused" : note)
        case .noClient:
            return downgradeToPaste(for: bundleID, reason: note.isEmpty ? "no IMK client" : note)
        case .noDocumentAccess:
            // Retro-edits are off here, but streaming and commits are unaffected.
            return verdict(for: bundleID)
        case .applied, .staleGeneration, .readFailed, .targetNotFound, .fieldChanged,
             .ambiguousRelocation, .emptyEdit, .noSession:
            return verdict(for: bundleID)
        }
    }

    public func forget(_ bundleID: String) {
        lock.lock(); entries.removeValue(forKey: bundleID); lock.unlock()
    }

    public func removeAll() {
        lock.lock(); entries.removeAll(); lock.unlock()
    }

    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return entries.count
    }
}
