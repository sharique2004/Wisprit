#if os(macOS)
import AppKit
import SwiftUI
import WispritKit

/// The window Wisprit never had.
///
/// Wisprit is an `LSUIElement` agent, so by default clicking it in Finder or the
/// Dock does *nothing visible* — the whole reason a running install read as
/// broken. This controller fixes that in two halves:
///
///  * it owns one real `NSWindow` hosting the SwiftUI shell, and
///  * the first time that window is asked for it flips the activation policy
///    from `.accessory` to `.regular`, so Wisprit gets a Dock icon and a ⌘-Tab
///    slot like any other app.
///
/// The flip is the important half: without it the window can be shown but never
/// focused properly, and ⌘-Tab still cannot find the app the user is looking at.
///
/// It is one-way for the rest of the session. Handing the policy back on close
/// looked tidier and made reopening impossible — macOS refuses to front a
/// process that has just stopped being an agent, so the window came up buried.
/// See `windowWillClose`.
@MainActor
public final class MainWindowController: NSObject, NSWindowDelegate {

    private let model: WispritWindowModel
    private var window: NSWindow?
    private let log = WLog.logger("window")

    public init(model: WispritWindowModel) {
        self.model = model
        super.init()
    }

    public var isVisible: Bool { window?.isVisible ?? false }

    /// Show the window, creating it on first use. Idempotent: a second click on
    /// the Dock icon just brings the existing window forward.
    public func show(tab: WispritWindowModel.Tab? = nil) {
        if let tab { model.selectedTab = tab }
        let flipped = becomeRegularApp()

        // Both branches raise the same way, and both wait out the policy flip.
        // Open-coding a single `makeKeyAndOrderFront` for the already-created
        // window is what left a reopened Wisprit sitting inactive behind
        // whatever the user had clicked away to — the normal case, since closing
        // the window is the normal thing to do. See `raise`.
        if let window {
            raise(window, afterPolicyChange: flipped)
            model.windowDidOpen()
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        // The window's identity is the app, not the page: Mission Control, the
        // Window menu and ⌘-Tab all show this string, and a window called
        // "Settings" is not the one the user is looking for. The title is set
        // and then hidden — the Hub draws its own header (§3.1).
        window.title = "Wisprit"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // The 52 pt band above the sidebar and the card is not chrome, so
        // dragging it moves the window like chrome would.
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 900, height: 600)
        window.delegate = self
        window.contentView = NSHostingView(rootView: HubShell(model: model))
        window.center()
        window.setFrameAutosaveName("WispritMainWindow")
        self.window = window

        raise(window, afterPolicyChange: flipped)
        model.windowDidOpen()
    }

    /// Open straight into the first-run wizard.
    public func showOnboarding() {
        show(tab: .setup)
        model.beginOnboarding()
    }

    public func close() {
        window?.performClose(nil)
    }

    /// Bring the window forward — and, when the app has just stopped being an
    /// agent, get LaunchServices to do the fronting.
    ///
    /// macOS will not let an app that was `.accessory` a moment ago activate
    /// *itself*: measured against the shipping bundle, the window appeared but
    /// the previously frontmost app kept the front on 3/3 tries, and it made no
    /// difference whether the request came in the same run-loop turn, one
    /// `DispatchQueue.main.async` later, or after a real delay. Keeping the
    /// `.regular` policy for the rest of the session (see `windowWillClose`) is
    /// what takes that flip off the reopen path entirely.
    ///
    /// One flip per session is left — the first time the user asks for the
    /// window — and for that one, asking the way the Dock asks does work:
    /// LaunchServices fronts a `.regular` app on request, whether or not it was
    /// already running (checked against a control app first). So a
    /// self-activation is attempted first, since it is free and it is enough
    /// whenever the policy did not move, and the LaunchServices bounce is the
    /// fallback for the flip.
    ///
    /// The `makeFirstResponder(nil)` is a separate promise this window makes:
    /// nothing inside it steals focus on open. AppKit scrolls an enclosing
    /// scroll view to reveal whatever becomes first responder, and the Status
    /// page's try-it `TextEditor` volunteering for the job is what scrolled the
    /// verdict and the permission rows off the top of the page.
    private func raise(_ window: NSWindow, afterPolicyChange flipped: Bool = false) {
        let bringForward: @MainActor () -> Void = {
            NSApp.unhide(nil)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(nil)
        }
        bringForward()
        DispatchQueue.main.async { MainActor.assumeIsolated { bringForward() } }
        guard flipped else { return }
        // Let LaunchServices catch up with the policy first. Asked in the same
        // turn as the flip it declines exactly like a self-activation does;
        // asked once the app is registered as `.regular` it fronts us, which is
        // the behaviour the control test pins.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.launchServicesSettleDelay) {
            MainActor.assumeIsolated {
                bringForward()
                // Deliberately not conditioned on `NSApp.isActive`: after a
                // declined activation the app still reports itself active while
                // another app owns the front, so that guard skips the one call
                // that works.
                self.askLaunchServicesToFrontUs()
            }
        }
    }

    /// How long LaunchServices needs before it will front a process that has
    /// just stopped being an agent. Measured, not guessed: at 0 s the request is
    /// declined every time.
    private static let launchServicesSettleDelay: TimeInterval = 0.25

    /// Guards against the obvious loop: the request below arrives back as a
    /// reopen, which calls `show` again.
    private var isAskingForFront = false

    /// Ask LaunchServices to bring this bundle forward — the same request the
    /// Dock makes on a click. By this point the policy is already `.regular`, so
    /// there is a Dock tile and an app to front; `createsNewApplicationInstance`
    /// stays false, so this is a fronting request and never a second Wisprit
    /// (the flock would refuse one anyway).
    private func askLaunchServicesToFrontUs() {
        guard !isAskingForFront else { return }
        isAskingForFront = true
        log.info("asking LaunchServices to front the window after the agent→app flip")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL,
                                           configuration: configuration) { [weak self] _, error in
            DispatchQueue.main.async {
                self?.isAskingForFront = false
                if let error {
                    self?.log.warning("could not ask LaunchServices to front the window: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    // MARK: - Activation policy

    /// `.regular` gives the Dock icon and the ⌘-Tab entry. `LSUIElement` in the
    /// Info.plist only sets the *initial* policy; changing it at runtime is
    /// supported and is what lets one binary be both an agent and an app.
    ///
    /// Returns whether the policy actually moved, because that is the thing an
    /// activation has to wait out.
    @discardableResult
    private func becomeRegularApp() -> Bool {
        guard NSApp.activationPolicy() != .regular else { return false }
        NSApp.setActivationPolicy(.regular)
        return true
    }

    // MARK: - NSWindowDelegate

    public func windowWillClose(_ notification: Notification) {
        model.windowDidClose()
        // Give the front back to whatever the user was in, but STAY a regular
        // app.
        //
        // Going back to `.accessory` here is what broke reopening. macOS will
        // not front a process that has just stopped being an agent — measured
        // against the shipping bundle, every route was declined: a same-turn
        // `activate`, a deferred one, a delayed one, `NSWorkspace.openApplication`
        // with `activates`, even a second `/usr/bin/open` two seconds later —
        // while the identical request against a Wisprit that had stayed
        // `.regular` was granted every time. So the window came up buried behind
        // whatever the user clicked away to, which is the exact "I clicked it and
        // nothing happened" this whole window exists to end.
        //
        // The cost is a Dock tile and a ⌘-Tab entry that outlive the window for
        // the rest of the session. That is the better half of the trade: both of
        // them reopen the window on a click, and Wisprit still launches as a
        // menu-bar agent and stays one until the user asks for the window.
        // `deactivate()` (not `hide`) yields the front — hiding would take the
        // dictation pill down with it.
        DispatchQueue.main.async {
            NSApp.deactivate()
        }
    }
}
#endif
