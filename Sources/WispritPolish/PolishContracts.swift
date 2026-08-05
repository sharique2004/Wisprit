import Foundation

/// The four transforms the "Polish Last" menu offers, replacing the Python
/// `wisprit/polish.py` MODES dict. Raw values are the Python keys byte-for-byte
/// ("clean" / "formal" / "casual" / "prompt") so a menu item's represented
/// object, a settings value, or a CLI argument written by the old build still
/// means the same thing after the cutover.
///
/// Unlike refine, polish is **opt-in**: the user deliberately picks a mode from
/// the menu, the source transcript is already safely in history and already
/// inserted, and the result lands on the clipboard. So the failure policy
/// inverts — refine falls back to verbatim, polish returns `.failure(reason:)`
/// and the caller shows the notice and leaves the clipboard untouched
/// (`polish.polish()` returned `(False, message)` for exactly this).
public enum PolishMode: String, Sendable, CaseIterable {
    case cleanUp = "clean"
    case makeFormal = "formal"
    case makeCasual = "casual"
    case asAIPrompt = "prompt"

    /// Menu title — `polish.MODE_LABELS`, verbatim.
    public var label: String {
        switch self {
        case .cleanUp: return "Clean up"
        case .makeFormal: return "Make formal"
        case .makeCasual: return "Make casual"
        case .asAIPrompt: return "As an AI prompt"
        }
    }

    /// Python tolerated an unknown mode by falling back to "clean"; keep that.
    public static func named(_ raw: String) -> PolishMode {
        PolishMode(rawValue: raw) ?? .cleanUp
    }
}

/// Why a polish request produced nothing usable. Every case carries a
/// user-facing `notice` in the register of the Python messages ("no transcript
/// to polish", "claude timed out", …), because the caller's only job on failure
/// is to show it and stop.
public enum PolishFailureKind: Sendable, Equatable {
    /// Nothing in history, or whitespace only.
    case empty
    /// Apple Intelligence off / assets missing / device unsupported.
    case unavailable(String)
    /// Past the word cap: input + output share one 4096-token context.
    case tooLong(Int)
    /// The model did not finish inside the budget.
    case timeout
    /// The caller asked to abandon the request.
    case cancelled
    /// Session setup failed (the in-process analogue of `spawn_failed`).
    case setupFailed(String)
    /// The model threw (guardrail violation, context overflow, rate limit, …).
    case modelError(String)
    /// The model produced nothing, or nothing survived laundering.
    case emptyOutput
    /// The model refused ("I'm sorry, I can't help with that") — measured on
    /// short or odd inputs.
    case refused
    /// The output is not plausibly a rewrite of the input: it answered the
    /// dictation, summarized it, or ran away.
    case implausible

    public var notice: String {
        switch self {
        case .empty: return "No transcript to polish yet."
        case .unavailable(let reason):
            return reason.isEmpty
                ? "Apple Intelligence is unavailable."
                : "Apple Intelligence is unavailable (\(reason))."
        case .tooLong(let cap): return "Transcript is too long to polish (\(cap)-word limit)."
        case .timeout: return "Polish timed out."
        case .cancelled: return "Polish cancelled."
        case .setupFailed: return "Could not start Apple Intelligence."
        case .modelError: return "Apple Intelligence could not polish that."
        case .emptyOutput: return "Apple Intelligence returned nothing."
        case .refused: return "Apple Intelligence declined to rewrite that."
        case .implausible: return "The rewrite did not look like the transcript — kept the original."
        }
    }
}

/// Outcome of one polish request. Success carries text that is safe to put on
/// the clipboard; failure carries the notice and the machine-readable kind.
public enum PolishResult: Sendable, Equatable {
    case success(String)
    case failure(reason: String, kind: PolishFailureKind)

    /// Build a failure from its kind, taking the standard notice text.
    public static func failure(_ kind: PolishFailureKind) -> PolishResult {
        .failure(reason: kind.notice, kind: kind)
    }

    public var text: String? {
        if case .success(let text) = self { return text }
        return nil
    }

    public var failureKind: PolishFailureKind? {
        if case .failure(_, let kind) = self { return kind }
        return nil
    }
}

/// Snapshotted per request so a live settings change lands without a restart —
/// the same discipline as `RefineConfiguration`. Non-positive numbers fall back
/// to the defaults.
public struct PolishConfiguration: Sendable, Equatable {
    /// Word cap. Polish reads whole transcripts out of history, and input +
    /// instructions + output share one 4096-token context; past this the
    /// request would be truncated rather than refused, which silently loses the
    /// tail of the user's text.
    public var maxWords: Int
    /// Hard ceiling per request. 30 s is `polish._TIMEOUT_S`; polish is a
    /// deliberate, off-path action, so it may wait far longer than refine's 12 s.
    public var timeoutMs: Int

    public init(maxWords: Int = 350, timeoutMs: Int = 30000) {
        self.maxWords = maxWords > 0 ? maxWords : 350
        self.timeoutMs = timeoutMs > 0 ? timeoutMs : 30000
    }
}

/// One availability probe. Same shape as `RefineAvailability` so the menu can
/// render both tri-states with one code path.
public struct PolishAvailability: Sendable, Equatable {
    public var available: Bool
    /// `String(describing: UnavailableReason)` when unavailable, "" otherwise.
    public var reason: String

    public init(available: Bool, reason: String = "") {
        self.available = available
        self.reason = available ? "" : reason
    }
}

/// Failures the generator raises.
public enum PolishError: Error, Equatable {
    case setupFailed(String)
    case generationFailed(String)
    case emptyResponse
    case unavailable(String)
}

/// The model behind the cage, so every guard is testable against a fake.
///
/// No `prewarm()`: polish has no press to prewarm on — the user picks a mode
/// from an already-open menu and the request starts immediately. One session
/// per request is still mandatory (a `LanguageModelSession` accumulates a
/// transcript, and mode instructions differ per request).
public protocol PolishGenerating: Sendable {
    func probe() async -> PolishAvailability
    /// Run one transcript through one mode's instructions.
    func generate(_ transcript: String, mode: PolishMode) async throws -> String
    /// Drop any live session (request abandoned, shutdown).
    func discard() async
}
