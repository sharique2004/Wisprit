import Foundation

/// One gesture edge produced by the event tap. Mirrors `hotkey.HotkeyEvent`
/// (`kind`, `ts`) — the raw string values are kept so metrics/logs read the
/// same as the Python app's.
public enum HotkeyEventKind: String, Sendable, Equatable, CaseIterable {
    /// Trigger key went down (the session enforces `hold_debounce_ms`).
    case press
    /// Trigger key came up while still armed.
    case release
    /// The gesture was a chord, or the tap died mid-hold — discard the utterance.
    case cancel
    /// Esc while the session says an utterance is in progress.
    case esc
    /// Global ⌘⌃V — re-insert the last transcript.
    case pasteLast = "paste_last"
}

public struct HotkeyEvent: Sendable, Equatable {
    public let kind: HotkeyEventKind
    /// `MonotonicClock.now()` at the moment the tap callback saw the edge.
    public let ts: Double

    public init(_ kind: HotkeyEventKind, ts: Double = MonotonicClock.now()) {
        self.kind = kind
        self.ts = ts
    }
}

/// What a queued event means to a *running* refine stage. Mirrors
/// `session._refine_interrupt()`'s `None | "cancel" | "hurry"`.
///
/// Deliberately a local type: `WispritMacInput` depends only on `WispritKit`,
/// so it cannot name `WispritRefine.InterruptSignal`. The executable maps
/// `.cancel → .cancel`, `.hurry → .hurry`, `.none → .none` — the cases line up
/// one-to-one.
public enum HotkeyInterrupt: String, Sendable, Equatable {
    case none
    case cancel
    case hurry
}
