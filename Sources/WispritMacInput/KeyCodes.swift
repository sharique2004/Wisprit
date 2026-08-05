import Foundation

/// Virtual keycodes and event-flag masks, ported verbatim from
/// `wisprit/runtime.py`'s "Hotkey" and "Insertion" blocks. Kept as plain
/// integers (not `CGKeyCode`/`CGEventFlags`) so the state machine is pure
/// Foundation and testable without CoreGraphics.
public enum KeyCodes {
    /// `kVK_Function` — the keycode carried by the *physical* Fn key's
    /// flagsChanged event. Gating on this (and not on the flag alone) is what
    /// keeps arrow/nav/F-keys from misfiring dictation (Hex bug #89).
    public static let function: Int64 = 63
    public static let rightOption: Int64 = 61
    public static let escape: Int64 = 53
    public static let ansiV: Int64 = 9
}

/// `CGEventFlags` bit values. Duplicated as raw constants for the same reason
/// as `KeyCodes` — the decision logic must not need CoreGraphics.
public enum EventFlags {
    /// `kCGEventFlagMaskSecondaryFn`.
    public static let secondaryFn: UInt64 = 0x0080_0000
    /// `kCGEventFlagMaskAlternate` — set by EITHER Option key (see
    /// `TriggerKey.rightOption`'s documented masking bug).
    public static let alternate: UInt64 = 0x0008_0000
    /// `kCGEventFlagMaskCommand`.
    public static let command: UInt64 = 0x0010_0000
    /// `kCGEventFlagMaskControl`.
    public static let control: UInt64 = 0x0004_0000
    /// The ⌘⌃ pair required by the global paste-last shortcut.
    public static let commandControl: UInt64 = command | control
}

/// Which physical key arms dictation. Mirrors the `hotkey` setting
/// (`"fn"` | `"right_option"`).
public enum TriggerKey: String, Sendable, CaseIterable {
    case fn
    case rightOption = "right_option"

    /// Parse a settings value; anything unrecognized falls back to `.fn`,
    /// exactly like `hotkey.py`'s `if hotkey == "right_option": … else: fn`.
    public static func parse(_ raw: String?) -> TriggerKey {
        (raw == TriggerKey.rightOption.rawValue) ? .rightOption : .fn
    }

    public var keycode: Int64 {
        switch self {
        case .fn: return KeyCodes.function
        case .rightOption: return KeyCodes.rightOption
        }
    }

    /// The modifier bit that must be SET for "trigger is down".
    ///
    /// PORTED BUG (deliberate, not a deviation): for
    /// `.rightOption` the mask is `kCGEventFlagMaskAlternate`, which macOS
    /// sets for *either* Option key. Holding left-Option and then tapping
    /// right-Option therefore reports "still down" on the release edge and the
    /// gesture sticks until left-Option is also released. `hotkey.py` has this
    /// same behavior; it is ported as-is rather than silently fixed, because a
    /// fix would diverge from the Python contract this port is measured
    /// against. (`.fn` is unaffected: the Fn bit has exactly one source.)
    public var flagMask: UInt64 {
        switch self {
        case .fn: return EventFlags.secondaryFn
        case .rightOption: return EventFlags.alternate
        }
    }
}

/// `time.monotonic()` equivalent. `CLOCK_UPTIME_RAW` is what CPython uses for
/// `time.monotonic()` on Darwin (mach_absolute_time), so timestamps compare
/// like-for-like with the Python session's debounce arithmetic.
public enum MonotonicClock {
    public static func now() -> Double {
        Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000_000.0
    }
}
