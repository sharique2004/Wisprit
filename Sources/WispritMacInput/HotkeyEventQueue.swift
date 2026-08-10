import Foundation
import WispritKit

/// The hand-off between the event-tap callback thread and the session thread —
/// the Swift equivalent of the `queue.Queue` that `hotkey.py` puts into and
/// `session.py` gets from.
///
/// Why this lives here and not in the session: `drainCancel()` and
/// `pollInterrupt()` are queue *semantics* (consume cancels, re-queue everything
/// else in order), and getting them wrong loses a queued press. They are ported
/// from `session._drain_cancel()` / `session._refine_interrupt()` and tested
/// here so the executable only has to call them.
///
/// Thread-safe for many producers and one consumer.
public final class HotkeyEventQueue: @unchecked Sendable {
    private let cond = NSCondition()
    private var storage: [HotkeyEvent] = []
    private var closed = false
    private let capacity: Int
    private var droppedCount = 0
    private let log = WLog.logger("hotkey")

    /// - Parameter capacity: `0` means unbounded, matching Python's
    ///   `queue.Queue()` default. A positive capacity makes `put` drop (and
    ///   log) like the `queue.Full` branch in `hotkey._emit`.
    public init(capacity: Int = 0) {
        self.capacity = max(0, capacity)
    }

    /// Events dropped because the queue was full, since construction.
    public var dropped: Int {
        cond.lock(); defer { cond.unlock() }
        return droppedCount
    }

    public var count: Int {
        cond.lock(); defer { cond.unlock() }
        return storage.count
    }

    /// Non-blocking enqueue. Returns false if the event was dropped (queue full
    /// or closed) — the callback path must never block on a full queue.
    @discardableResult
    public func put(_ event: HotkeyEvent) -> Bool {
        cond.lock()
        if closed {
            cond.unlock()
            return false
        }
        if capacity > 0 && storage.count >= capacity {
            droppedCount += 1
            cond.unlock()
            log.warning("hotkey event queue full; dropping \(event.kind.rawValue, privacy: .public)")
            return false
        }
        storage.append(event)
        cond.signal()
        cond.unlock()
        return true
    }

    /// Blocking dequeue with a timeout, mirroring `self._events.get(timeout=0.25)`
    /// in the session loop. Returns nil on timeout or once closed and drained.
    public func get(timeout: TimeInterval) -> HotkeyEvent? {
        cond.lock(); defer { cond.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while storage.isEmpty && !closed {
            if !cond.wait(until: deadline) { return nil }
        }
        if storage.isEmpty { return nil }
        return storage.removeFirst()
    }

    /// Non-consuming probe: is a press already waiting? Read by the session at
    /// the end of the paste rung's clipboard-restore window — the one-line
    /// counter R6 ships so the rejected skip-restore-on-re-press idea (R34,
    /// §1.1-T5) has a measured firing rate instead of a hunch. Nothing is
    /// dequeued; the press still starts the next utterance in order.
    public var hasPendingPress: Bool {
        cond.lock(); defer { cond.unlock() }
        return storage.contains { $0.kind == .press }
    }

    /// Non-blocking dequeue.
    public func getNowait() -> HotkeyEvent? {
        cond.lock(); defer { cond.unlock() }
        return storage.isEmpty ? nil : storage.removeFirst()
    }

    /// True (consuming them) if any esc/cancel events are queued. Every other
    /// event stays queued **in order**, so a press that arrived during finalize
    /// still starts the next utterance. Port of `session._drain_cancel()`.
    ///
    /// Done under a single lock rather than Python's get-loop-then-put-back, so
    /// an event enqueued by the tap mid-drain cannot be reordered ahead of the
    /// events being re-queued. Same outcome, no interleaving window.
    public func drainCancel() -> Bool {
        cond.lock(); defer { cond.unlock() }
        var cancelled = false
        var others: [HotkeyEvent] = []
        others.reserveCapacity(storage.count)
        for ev in storage {
            if ev.kind == .esc || ev.kind == .cancel {
                cancelled = true
            } else {
                others.append(ev)
            }
        }
        storage = others
        return cancelled
    }

    /// Polled ~20×/s by the refine stage. Consumes esc/cancel (the utterance is
    /// being aborted anyway) and leaves everything else queued in order; a
    /// queued press additionally yields `.hurry` so the next dictation is not
    /// stuck behind the model. Port of `session._refine_interrupt()`.
    ///
    /// `.cancel` wins over `.hurry` when both are queued, exactly as in Python.
    public func pollInterrupt() -> HotkeyInterrupt {
        cond.lock(); defer { cond.unlock() }
        var cancelled = false
        var press = false
        var others: [HotkeyEvent] = []
        others.reserveCapacity(storage.count)
        for ev in storage {
            if ev.kind == .esc || ev.kind == .cancel {
                cancelled = true
            } else {
                if ev.kind == .press { press = true }
                others.append(ev)
            }
        }
        storage = others
        if cancelled { return .cancel }
        if press { return .hurry }
        return .none
    }

    /// Wake any waiting consumer and refuse further puts (app teardown).
    public func close() {
        cond.lock()
        closed = true
        cond.broadcast()
        cond.unlock()
    }

    /// Test/reset helper: drop everything queued.
    public func clear() {
        cond.lock()
        storage.removeAll()
        cond.unlock()
    }
}
