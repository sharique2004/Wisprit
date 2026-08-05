import Foundation
import os

/// Minimal `os_unfair_lock` wrapper (same rationale as `WispritEngine`'s, which
/// this target cannot import: cross-module coupling goes through `WispritKit`
/// only). Used on the event-tap callback path, where the cost of a lock matters
/// — a slow callback is what earns you `kCGEventTapDisabledByTimeout`.
final class InputLock: @unchecked Sendable {
    private let pointer: os_unfair_lock_t

    init() {
        pointer = .allocate(capacity: 1)
        pointer.initialize(to: os_unfair_lock())
    }

    deinit {
        pointer.deinitialize(count: 1)
        pointer.deallocate()
    }

    @inline(__always)
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        os_unfair_lock_lock(pointer)
        defer { os_unfair_lock_unlock(pointer) }
        return try body()
    }
}
