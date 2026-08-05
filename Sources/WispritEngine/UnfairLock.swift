import Foundation
import os

/// Minimal `os_unfair_lock` wrapper.
///
/// Not `NSLock`: its `lock()`/`unlock()` are annotated unavailable-from-async
/// (an error under the Swift 6 language mode), and `PcmChunkQueue` genuinely
/// needs the lock handed across a `withCheckedContinuation` boundary. Also the
/// cheapest thing available on the audio-callback path, which is the whole point.
final class UnfairLock: @unchecked Sendable {
    private let pointer: os_unfair_lock_t

    init() {
        pointer = .allocate(capacity: 1)
        pointer.initialize(to: os_unfair_lock())
    }

    deinit {
        pointer.deinitialize(count: 1)
        pointer.deallocate()
    }

    func lock() { os_unfair_lock_lock(pointer) }
    func unlock() { os_unfair_lock_unlock(pointer) }

    @inline(__always)
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        os_unfair_lock_lock(pointer)
        defer { os_unfair_lock_unlock(pointer) }
        return try body()
    }
}
