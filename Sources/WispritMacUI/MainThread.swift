import Foundation

/// Main-thread discipline for the macOS shell.
///
/// Port of `wisprit/ui.py`:
///
/// ```python
/// def call_on_main(fn, *args):
///     NSOperationQueue.mainQueue().addOperationWithBlock_(lambda: fn(*args))
/// ```
///
/// Every `Pill` / `StatusMenu` method is main-thread-only (they touch AppKit).
/// The session thread, the ASR reader thread and the level ticker all reach the
/// UI through here. Like the Python original this **always defers** — even when
/// already on the main thread — so a UI update can never re-enter the caller
/// mid-mutation. Deferral costs one run-loop turn, which is far below the
/// ~1.26 s first-partial latency the pill is rendering anyway.
public enum WispritUI {
    /// Enqueue `work` on the main run loop.
    public static func callOnMain(_ work: @escaping @Sendable @MainActor () -> Void) {
        OperationQueue.main.addOperation {
            MainActor.assumeIsolated { work() }
        }
    }
}
