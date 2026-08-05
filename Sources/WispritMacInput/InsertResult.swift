import Foundation

/// Outcome of one insertion attempt. Port of `insert.InsertResult`; the raw
/// method strings are preserved because they are the `outcome` field in
/// `metrics.log` and the session branches on `blocked_secure`.
public struct InsertResult: Sendable, Equatable {
    public enum Method: String, Sendable, Equatable, CaseIterable {
        case paste
        case type
        case blockedSecure = "blocked_secure"
        case error
    }

    public let ok: Bool
    public let method: Method
    public let detail: String

    public init(ok: Bool, method: Method, detail: String = "") {
        self.ok = ok
        self.method = method
        self.detail = detail
    }
}

/// The per-call slice of `Settings` that insertion needs. Passed in rather than
/// read here, because `WispritMacInput` depends only on `WispritKit` — the
/// executable builds one of these from `Settings` at each insert, which is also
/// what makes a settings edit take effect on the very next utterance.
public struct InserterConfig: Sendable, Equatable {
    public var terminalBundleIDs: [String]
    /// Raw setting value; `effectiveRestoreDelayMs` applies the same validation
    /// as `insert.py` (`not a number or < 0` → the 500 ms default).
    public var pasteRestoreDelayMs: Double?

    public init(terminalBundleIDs: [String] = Inserter.defaultTerminalBundleIDs,
                pasteRestoreDelayMs: Double? = Double(Inserter.defaultRestoreDelayMs)) {
        self.terminalBundleIDs = terminalBundleIDs
        self.pasteRestoreDelayMs = pasteRestoreDelayMs
    }

    public var effectiveRestoreDelayMs: Double {
        guard let pasteRestoreDelayMs, pasteRestoreDelayMs >= 0, pasteRestoreDelayMs.isFinite else {
            return Double(Inserter.defaultRestoreDelayMs)
        }
        return pasteRestoreDelayMs
    }
}

/// Which of the three insertion paths a given situation selects. Pure, so the
/// cascade order is testable without a pasteboard or a TCC grant.
public enum InsertRoute: Sendable, Equatable {
    case emptyText
    /// Secure Keyboard Entry held by someone — never inject.
    case blockedSecure
    /// Accessibility not granted — posted events would be silently dropped.
    case notTrusted
    /// Frontmost bundle id is in `terminal_bundle_ids`.
    case typed(bundleID: String)
    case clipboard(bundleID: String?)
}
