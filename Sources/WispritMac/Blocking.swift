import Foundation

/// Bridge from the synchronous session thread into async core APIs.
///
/// `session.py` runs one dedicated worker thread that calls audio / ASR /
/// refine / postprocess / insert **synchronously**, which is what makes the
/// stages naturally serialized and the state machine readable. The Swift core
/// exposes the slow stages as `async`, so the port keeps the thread and blocks
/// it here instead of restructuring the machine around a Task.
///
/// Safe because the caller is never the main thread and never a cooperative
/// executor thread: the work runs on a detached task on the concurrency pool
/// while a plain pthread waits. Calling this from the main thread would deadlock
/// any operation that hops to `@MainActor`, so don't.
func runBlocking<T: Sendable>(_ operation: @escaping @Sendable () async -> T) -> T {
    let box = ResultBox<T>()
    let semaphore = DispatchSemaphore(value: 0)
    Task.detached(priority: .userInitiated) {
        box.set(await operation())
        semaphore.signal()
    }
    semaphore.wait()
    return box.take()
}

private final class ResultBox<T>: @unchecked Sendable {
    private var value: T?
    private let lock = NSLock()
    func set(_ newValue: T) { lock.lock(); value = newValue; lock.unlock() }
    func take() -> T {
        lock.lock(); defer { lock.unlock() }
        guard let value else { fatalError("runBlocking completed without a value") }
        return value
    }
}

/// `threading.Event`-alike used by the level ticker: `wait(_:)` returns true
/// when the flag fired, false on timeout — Python's polarity.
final class StopFlag: @unchecked Sendable {
    private let condition = NSCondition()
    private var flagged = false

    func signal() {
        condition.lock(); flagged = true; condition.broadcast(); condition.unlock()
    }

    func reset() {
        condition.lock(); flagged = false; condition.unlock()
    }

    var isSignalled: Bool {
        condition.lock(); defer { condition.unlock() }
        return flagged
    }

    func wait(_ timeout: TimeInterval) -> Bool {
        condition.lock(); defer { condition.unlock() }
        if flagged { return true }
        let deadline = Date().addingTimeInterval(timeout)
        while !flagged {
            if !condition.wait(until: deadline) { return false }
        }
        return true
    }
}
