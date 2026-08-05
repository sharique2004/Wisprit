import CoreGraphics
import Foundation
import WispritKit

/// Global push-to-talk hotkey via a **listen-only** CGEventTap.
///
/// Watches `flagsChanged` for the trigger key (Fn by default, right-Option as
/// an alternate) and `keyDown` for Esc / ⌘⌃V / chord interrupts. Listen-only
/// means it never suppresses events, so it cannot cause the "swallowed
/// keystrokes" class of bug and does not break the system's own double-Fn
/// dictation.
///
/// Install on the **main thread**: the run-loop source is added to the current
/// CFRunLoop, which must be the main NSApplication loop.
///
/// The tap callback does nothing but ask `HotkeyStateMachine` what happened and
/// enqueue the result — no allocation-heavy work, no locks held across I/O, no
/// UI. A slow callback is exactly what earns `kCGEventTapDisabledByTimeout`.
public final class HotkeyMonitor: @unchecked Sendable {
    private let queue: HotkeyEventQueue
    private let machine: HotkeyStateMachine
    private let log = WLog.logger("hotkey")

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var runLoop: CFRunLoop?

    private var watchdog: Thread?
    private let watchdogStop = StopSignal()
    /// `hotkey.py`'s `self._watchdog_stop.wait(3.0)` cadence.
    public static let watchdogInterval: TimeInterval = 3.0

    public init(queue: HotkeyEventQueue, trigger: TriggerKey) {
        self.queue = queue
        self.machine = HotkeyStateMachine(trigger: trigger)
    }

    /// Convenience for the app: parse the `hotkey` setting string.
    public convenience init(queue: HotkeyEventQueue, hotkeySetting: String?) {
        self.init(queue: queue, trigger: TriggerKey.parse(hotkeySetting))
    }

    public var trigger: TriggerKey { machine.trigger }

    /// The session gates Esc with this (kept true through the refine stage).
    public func setRecording(_ recording: Bool) {
        machine.setRecording(recording)
    }

    public var isInstalled: Bool { tap != nil }

    // --- lifecycle ------------------------------------------------------------

    /// Create and enable the tap on the current (main) run loop.
    ///
    /// Returns false if the tap could not be created — which in practice means
    /// Input Monitoring was never granted. The caller surfaces an actionable
    /// permission error; it must NOT retry in a loop.
    @discardableResult
    public func install() -> Bool {
        guard tap == nil else { return true }
        if !Thread.isMainThread {
            // The run-loop source is added to the CURRENT CFRunLoop; on a
            // worker thread that run loop is usually never run, so the tap
            // would exist but never fire.
            log.error("install() called off the main thread — the tap's run-loop source will be orphaned")
        }
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let newTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: hotkeyTapCallback,
            userInfo: refcon)
        else {
            log.error("event tap creation failed — Input Monitoring likely not granted")
            return false
        }

        tap = newTap
        source = CFMachPortCreateRunLoopSource(nil, newTap, 0)
        runLoop = CFRunLoopGetCurrent()
        if let source, let runLoop {
            CFRunLoopAddSource(runLoop, source, .commonModes)
        }
        CGEvent.tapEnable(tap: newTap, enable: true)

        watchdogStop.reset()
        let thread = Thread { [weak self] in self?.watchdogLoop() }
        thread.name = "hotkey-watchdog"
        thread.start()
        watchdog = thread

        log.info("hotkey tap installed (trigger=\(self.machine.trigger.rawValue, privacy: .public))")
        return true
    }

    public func uninstall() {
        watchdogStop.signal()
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source, let runLoop {
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
        }
        tap = nil
        source = nil
        runLoop = nil
        watchdog = nil
        machine.reset()
    }

    // --- callback path (keep FAST) --------------------------------------------

    fileprivate func handleTap(type: CGEventType, event: CGEvent) {
        let input: TapInput
        switch type {
        case .tapDisabledByTimeout:
            input = .tapDisabled(reason: .timeout)
        case .tapDisabledByUserInput:
            input = .tapDisabled(reason: .userInput)
        case .flagsChanged:
            input = .flagsChanged(keycode: event.getIntegerValueField(.keyboardEventKeycode),
                                  flags: event.flags.rawValue)
        case .keyDown:
            input = .keyDown(keycode: event.getIntegerValueField(.keyboardEventKeycode),
                             flags: event.flags.rawValue)
        default:
            return
        }
        apply(machine.handle(input))
    }

    /// Internal (not private) so the enqueue plumbing is testable without a tap.
    func apply(_ decision: HotkeyDecision) {
        if decision.reenableTap, let tap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        guard !decision.emits.isEmpty else { return }
        let ts = MonotonicClock.now()
        for kind in decision.emits {
            queue.put(HotkeyEvent(kind, ts: ts))
        }
    }

    // --- watchdog -------------------------------------------------------------

    private func watchdogLoop() {
        while !watchdogStop.wait(HotkeyMonitor.watchdogInterval) {
            guard let tap else { continue }
            let decision = machine.watchdogTick(tapEnabled: CGEvent.tapIsEnabled(tap: tap))
            if decision.reenableTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            if decision.logGhostWarning {
                log.warning("""
                    event tap disabled; re-enabling. If this repeats, grant Input \
                    Monitoring to this binary in System Settings → Privacy & Security \
                    → Input Monitoring (run `wisprit doctor`).
                    """)
            }
            let ts = MonotonicClock.now()
            for kind in decision.emits {
                queue.put(HotkeyEvent(kind, ts: ts))
            }
        }
    }
}

/// C-convention trampoline. Listen-only taps ignore the return value; we hand
/// the event straight back, exactly like the Python callback's `return event`.
private let hotkeyTapCallback: CGEventTapCallBack = { _, type, event, refcon in
    if let refcon {
        Unmanaged<HotkeyMonitor>.fromOpaque(refcon)
            .takeUnretainedValue()
            .handleTap(type: type, event: event)
    }
    return Unmanaged.passUnretained(event)
}

/// `threading.Event`-alike: a waitable, settable flag for the watchdog loop.
/// `wait(_:)` returns true if the signal fired, false on timeout — the same
/// polarity as Python's `Event.wait(timeout)`.
final class StopSignal: @unchecked Sendable {
    private let cond = NSCondition()
    private var flagged = false

    func signal() {
        cond.lock()
        flagged = true
        cond.broadcast()
        cond.unlock()
    }

    func reset() {
        cond.lock()
        flagged = false
        cond.unlock()
    }

    func wait(_ timeout: TimeInterval) -> Bool {
        cond.lock(); defer { cond.unlock() }
        if flagged { return true }
        let deadline = Date().addingTimeInterval(timeout)
        while !flagged {
            if !cond.wait(until: deadline) { return false }
        }
        return true
    }
}
