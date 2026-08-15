import Foundation
import WispritKit

/// Single-instance guard — `fcntl` `flock` on `~/.wisprit/wisprit.lock`.
///
/// Two instances would each install an event tap and each paste on every
/// release: the double-paste bug. The lock file is deliberately the **same**
/// one `wisprit/app.py` uses, so the native app and a still-installed Python
/// Wisprit are mutually exclusive across the two eras rather than fighting over
/// the keyboard.
///
/// The descriptor is held for the whole process lifetime (the lock is released
/// by the kernel on exit); `flock` is per open-file-description, so a second
/// `open` + `flock` — in this process or another — fails immediately.
public final class SingleInstanceLock: @unchecked Sendable {
    private let path: URL
    private var descriptor: Int32 = -1
    private let log = WLog.logger("app")

    public init(path: URL? = nil) {
        self.path = path ?? WispritPaths.stateDir.appendingPathComponent("wisprit.lock")
    }

    public var lockPath: URL { path }
    public var isHeld: Bool { descriptor >= 0 }

    #if DEBUG
    /// Test seam for the `FD_CLOEXEC` assertion. Debug-only and internal:
    /// nothing outside this guard's own tests has any business with the fd.
    var descriptorForTesting: Int32 { descriptor }
    #endif

    /// True when we got the lock; false when another Wisprit already holds it.
    public func acquire() -> Bool {
        guard descriptor < 0 else { return true }
        do {
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            // A state dir we cannot create is a bigger problem than a double
            // launch; let the app start and fail loudly elsewhere.
            log.error("cannot create state dir for the instance lock")
            return true
        }
        // O_CLOEXEC: `flock` belongs to the open-file-description, so any child
        // that inherited this fd would keep holding the lock after we exit. The
        // relaunch helper (`AppRelaunch.spawnHelper`) lives up to 10 s waiting
        // for us to die and then opens the bundle — inheriting would deadlock
        // the very relaunch it exists to perform. Foundation's `Process` closes
        // descriptors today; this makes it not depend on that.
        let fd = open(path.path, O_WRONLY | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            log.error("cannot open \(self.path.path, privacy: .public); skipping the single-instance guard")
            return true
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return false
        }
        descriptor = fd
        return true
    }

    /// Release early (tests, explicit shutdown). Exiting does this anyway.
    public func release() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }

    deinit { release() }
}
