import Foundation

/// One tap observation, reduced to the three facts the gesture logic needs.
/// The CGEvent itself never gets this far, which is the whole point: the state
/// machine is exercised in tests without an event tap, a TCC grant, or a
/// keystroke.
public enum TapInput: Sendable, Equatable {
    case flagsChanged(keycode: Int64, flags: UInt64)
    case keyDown(keycode: Int64, flags: UInt64)
    case tapDisabled(reason: TapDisableReason)
}

public enum TapDisableReason: String, Sendable, Equatable {
    /// `kCGEventTapDisabledByTimeout` — our callback was too slow.
    case timeout
    /// `kCGEventTapDisabledByUserInput` — the user (or the system) killed it.
    case userInput
}

/// What the caller must do with one observation.
public struct HotkeyDecision: Sendable, Equatable {
    /// Events to enqueue, in order.
    public var emits: [HotkeyEventKind]
    /// `CGEventTapEnable(tap, true)` — do this BEFORE enqueuing, as in Python.
    public var reenableTap: Bool

    public init(emits: [HotkeyEventKind] = [], reenableTap: Bool = false) {
        self.emits = emits
        self.reenableTap = reenableTap
    }

    public static let ignore = HotkeyDecision()
    static func emit(_ kind: HotkeyEventKind) -> HotkeyDecision { HotkeyDecision(emits: [kind]) }
}

/// What the 3-second watchdog must do this cycle.
public struct WatchdogDecision: Sendable, Equatable {
    public var reenableTap: Bool
    public var emits: [HotkeyEventKind]
    /// True only on the FIRST disabled cycle of a streak — a tap that keeps
    /// needing re-enabling is almost always a "ghost tap" (created but inert
    /// because Input Monitoring was never granted), and logging that every
    /// 3 seconds forever helps nobody.
    public var logGhostWarning: Bool

    public init(reenableTap: Bool = false, emits: [HotkeyEventKind] = [], logGhostWarning: Bool = false) {
        self.reenableTap = reenableTap
        self.emits = emits
        self.logGhostWarning = logGhostWarning
    }

    public static let ok = WatchdogDecision()
}

/// The push-to-talk gesture, as pure logic. Port of the decision half of
/// `hotkey.HotkeyListener` (`_callback` + `_watchdog_loop`); the CoreGraphics
/// half lives in `HotkeyMonitor`.
///
/// Gesture rules, all load-bearing:
///
/// - **Fn needs keycode 63 AND flag `0x800000`.** macOS sets the secondary-Fn
///   flag on arrow/nav/F-keys even when the physical Fn key was never touched,
///   so a flag-only test starts dictation on ↑ (Hex bug #89). Requiring the
///   flagsChanged keycode too makes that impossible.
/// - **Dirty chord**: any other keyDown while the trigger is held-and-armed
///   means the user meant Fn+Arrow, not dictation. Disarm and cancel. The
///   subsequent release edge is then silent (`wasArmed == false`).
/// - **Esc** is only emitted while the session says an utterance is live; the
///   session keeps `setRecording(true)` through the refine stage, so Esc stays
///   able to abort the longest stage in the pipeline.
/// - **⌘⌃V** (keycode 9 + command + control) is paste-last, but only when the
///   trigger is NOT down, so it can never be confused with a chord.
///
/// Thread-safe: the tap callback thread drives `handle`, the session thread
/// drives `setRecording`, the watchdog thread drives `watchdogTick`.
public final class HotkeyStateMachine: @unchecked Sendable {
    public let trigger: TriggerKey

    private let lock = InputLock()
    private var triggerDown = false
    private var armed = false
    private var recording = false
    /// Edge-tracking for the watchdog's once-per-streak ghost warning.
    private var watchdogWasOK = true

    public init(trigger: TriggerKey) {
        self.trigger = trigger
    }

    // --- session-facing state -------------------------------------------------

    /// The session tells us whether an utterance is in progress (gates Esc).
    public func setRecording(_ recording: Bool) {
        lock.withLock { self.recording = recording }
    }

    public var isRecording: Bool { lock.withLock { recording } }

    /// Introspection for tests and the doctor; not used by the gesture itself.
    public var isTriggerDown: Bool { lock.withLock { triggerDown } }
    public var isArmed: Bool { lock.withLock { armed } }

    // --- the gesture ----------------------------------------------------------

    public func handle(_ input: TapInput) -> HotkeyDecision {
        lock.withLock {
            switch input {
            case .tapDisabled:
                // Re-enable and reset the gesture so we can never get stuck
                // "recording" after the tap was cut out from under us.
                var emits: [HotkeyEventKind] = []
                if triggerDown && armed { emits.append(.cancel) }
                triggerDown = false
                armed = false
                return HotkeyDecision(emits: emits, reenableTap: true)

            case .flagsChanged(let keycode, let flags):
                guard keycode == trigger.keycode else { return .ignore }
                let nowDown = (flags & trigger.flagMask) != 0
                if nowDown && !triggerDown {
                    triggerDown = true
                    armed = true
                    return .emit(.press)
                }
                if !nowDown && triggerDown {
                    let wasArmed = armed
                    triggerDown = false
                    armed = false
                    return wasArmed ? .emit(.release) : .ignore
                }
                return .ignore

            case .keyDown(let keycode, let flags):
                // Global "paste last transcript": ⌘⌃V, only when idle (i.e. not
                // holding the trigger). Listen-only, so we never suppress it —
                // an app that binds ⌘⌃V still gets its keystroke.
                if keycode == KeyCodes.ansiV && !triggerDown {
                    if (flags & EventFlags.commandControl) == EventFlags.commandControl {
                        return .emit(.pasteLast)
                    }
                }
                // Chord interrupt: another key pressed during the trigger hold.
                if triggerDown && armed && keycode != trigger.keycode {
                    armed = false
                    return .emit(.cancel)
                }
                // Esc cancels an in-progress utterance.
                if keycode == KeyCodes.escape {
                    return recording ? .emit(.esc) : .ignore
                }
                return .ignore
            }
        }
    }

    // --- watchdog -------------------------------------------------------------

    /// One 3-second watchdog cycle. `tapEnabled` is `CGEventTapIsEnabled(tap)`.
    ///
    /// A silent disable may have swallowed the release edge, so the same reset
    /// the in-callback handler does happens here — otherwise the app sits in a
    /// permanent "recording" state with the mic on.
    public func watchdogTick(tapEnabled: Bool) -> WatchdogDecision {
        lock.withLock {
            if tapEnabled {
                watchdogWasOK = true
                return .ok
            }
            var decision = WatchdogDecision(reenableTap: true)
            if watchdogWasOK {
                decision.logGhostWarning = true
                if triggerDown && armed { decision.emits = [.cancel] }
                triggerDown = false
                armed = false
            }
            watchdogWasOK = false
            return decision
        }
    }

    /// Reset everything (uninstall / reinstall of the tap).
    public func reset() {
        lock.withLock {
            triggerDown = false
            armed = false
            watchdogWasOK = true
        }
    }
}
