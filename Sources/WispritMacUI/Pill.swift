#if canImport(AppKit)
import AppKit
import SwiftUI
import WispritKit

/// The floating status indicator — the thin AppKit edge over `PillModel`.
///
/// Port of `wisprit/pill.py`: a tiny, borderless, non-activating `NSPanel` that
/// floats above every app (and full-screen spaces). Draggable; position
/// persists through an injected callback.
///
/// The panel, the drag contract and the deferred-action timer are unchanged;
/// what it hosts is not. The 26 pt dot is now the Tally — a capsule waveform
/// drawn by `PillSurface` in one `Canvas` (`ui-redesign.md` §2).
///
/// Every public method must be called on the main thread — the session routes
/// through `WispritUI.callOnMain`.
@MainActor
public final class Pill: NSObject, NSWindowDelegate {
    /// Everything the pill needs from the rest of the app, as closures, so this
    /// target imports no core module.
    public struct Configuration {
        /// The `pill_hidden` setting.
        public var isSuppressed: () -> Bool
        /// The persisted `pill_position` (`[x, y]`), or nil for the default
        /// bottom-centre placement.
        public var savedPosition: () -> CGPoint?
        /// Persist a user drag (`windowDidMove_` → `settings.set("pill_position", …)`).
        public var persistPosition: (CGPoint) -> Void

        public init(isSuppressed: @escaping () -> Bool = { false },
                    savedPosition: @escaping () -> CGPoint? = { nil },
                    persistPosition: @escaping (CGPoint) -> Void = { _ in }) {
            self.isSuppressed = isSuppressed
            self.savedPosition = savedPosition
            self.persistPosition = persistPosition
        }
    }

    private let log = WLog.logger("pill")
    private let config: Configuration
    private let model: PillModel
    private var panel: NSPanel?
    /// The frame the hosted SwiftUI view reads. Built once (§6.3).
    private let box = PillRenderBox()
    private var host: NSHostingView<PillSurface>?
    private var deferredTimer: Timer?
    /// Guards `windowDidMove` against our own frame changes — only a user drag
    /// may overwrite the persisted position.
    private var suppressMoveNotifications = false
    /// The last render `apply` consumed — the "from" side of every §2.5 frame
    /// transition decision.
    private var appliedRender: PillRender = .collapsed
    /// Frame animations in flight. `windowDidMove` must not mistake an
    /// animated frame for a user drag.
    private var frameAnimations = 0
    /// Invalidates a pending hide completion when a show interrupts the sink —
    /// the panel must not be ordered out from under a fresh utterance.
    private var hideGeneration = 0
    /// Where the user put the pill. The panel's actual origin can differ from
    /// this when the edge flip is holding it on screen (§2.6), and it must not
    /// be overwritten by that: shrink back and the pill returns to where it was
    /// dragged.
    private var preferredOrigin: CGPoint?

    public init(configuration: Configuration = Configuration()) {
        self.config = configuration
        self.model = PillModel(isSuppressed: configuration.isSuppressed)
        super.init()
        wireModel()
        build()
    }

    // MARK: - public state API (main thread)

    /// NEW — the key is down, audio has not started. Optional: a session that
    /// never calls it goes straight to `showRecording` exactly as before.
    public func showPrewarming() { model.showPrewarming() }
    public func showRecording() { model.showRecording() }
    public func updateLevel(_ level: Double) { model.updateLevel(level) }
    /// NEW — render the tail of the in-progress transcript while recording.
    public func livePartial(_ text: String) { model.livePartial(text) }
    /// NEW — flash a short message ("Learned Sharique").
    public func transientNotice(_ text: String) { model.transientNotice(text) }
    public func showFinalizing() { model.showFinalizing() }
    /// NEW — the Apple Intelligence cleanup pass is running.
    public func showRefining() { model.showRefining() }
    public func flashSuccess() { model.flashSuccess() }
    public func flashError(_ message: String = "") { model.flashError(message) }
    /// NEW — Secure Keyboard Entry blocked the insertion; the text is on the
    /// clipboard. Until the session adopts it, `flashError` carries the same
    /// message with the shorter error timing.
    public func flashBlockedSecure(_ message: String = PillGeometry.blockedSecureMessage) {
        model.flashBlockedSecure(message)
    }
    public func hide() { model.hide() }

    /// Current frame — exposed for the integration layer's diagnostics.
    public var currentRender: PillRender { model.render }

    // MARK: - construction

    private func wireModel() {
        model.onRender = { [weak self] render in
            MainActor.assumeIsolated { self?.apply(render) }
        }
        model.onSchedule = { [weak self] seconds, action in
            MainActor.assumeIsolated { self?.schedule(seconds, action) }
        }
        model.onCancelSchedule = { [weak self] in
            MainActor.assumeIsolated { self?.cancelTimer() }
        }
    }

    /// `pill.py._build`, including its "running without a pill" fallback: if the
    /// panel cannot be made we keep answering every call and simply draw
    /// nothing, rather than taking dictation down with us.
    private func build() {
        let frame = NSRect(x: 0, y: 0, width: PillGeometry.widthListening, height: PillGeometry.height)
        let panel = NSPanel(contentRect: frame,
                            styleMask: [.nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.level = .statusBar                    // NSStatusWindowLevel
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.delegate = self

        let host = PillHostingView(rootView: PillSurface(box: box))
        host.frame = frame
        panel.contentView = host
        self.panel = panel
        self.host = host
        restorePosition()
    }

    /// `_restore_position`: persisted origin, else bottom-centre of the main
    /// screen with a 90 pt margin.
    ///
    /// §2.6 guard #1: a saved origin that is no longer inside any screen — a
    /// display was disconnected, or the resolution changed — falls back to the
    /// default placement rather than restoring an invisible panel.
    private func restorePosition() {
        guard let panel else { return }
        suppressMoveNotifications = true
        defer { suppressMoveNotifications = false }

        if let saved = config.savedPosition(), isOnScreen(saved) {
            preferredOrigin = saved
            panel.setFrameOrigin(saved)
            return
        }
        guard let screen = NSScreen.main else { return }
        let f = screen.frame
        let origin = NSPoint(x: f.origin.x + (f.size.width - PillGeometry.widthListening) / 2.0,
                             y: f.origin.y + PillGeometry.bottomMargin)
        preferredOrigin = origin
        panel.setFrameOrigin(origin)
    }

    private func isOnScreen(_ point: CGPoint) -> Bool {
        NSScreen.screens.contains { $0.visibleFrame.contains(point) }
    }

    /// §2.6 guard #2, the edge flip: growth is rightward only, so a pill parked
    /// near the right edge would grow off screen. Slide it left just far enough
    /// to stay on, and remember the user's own x so it comes back when the
    /// panel contracts.
    private func placedOrigin(width: Double) -> CGPoint {
        guard let anchor = preferredOrigin else { return panel?.frame.origin ?? .zero }
        guard let screen = NSScreen.screens.first(where: { $0.visibleFrame.contains(anchor) })
                ?? NSScreen.main else { return anchor }
        let limit = screen.visibleFrame.maxX - PillGeometry.edgeMargin - width
        let x = max(screen.visibleFrame.minX, min(anchor.x, limit))
        return CGPoint(x: x, y: anchor.y)
    }

    // MARK: - NSWindowDelegate

    public func windowDidMove(_ notification: Notification) {
        guard !suppressMoveNotifications, frameAnimations == 0, let panel else { return }
        preferredOrigin = panel.frame.origin
        config.persistPosition(panel.frame.origin)
    }

    // MARK: - rendering

    /// One render, one frame decision. The §2.5 panel-frame rows live here:
    /// appear fade + 4 pt rise (90 ms ease-out), width change (120 ms, the
    /// spec's near-critically-damped spring), the committed contraction
    /// (140 ms), and the hide fade + 3 pt sink (160 ms ease-in, order-out on
    /// completion). Under Reduce Motion the frame snaps and only the opacity
    /// fades survive — durations stay, motion goes. The 20 Hz level path never
    /// reaches this switch's animated arms: level ticks change no width.
    private func apply(_ render: PillRender) {
        guard let panel, let host else { return }
        let previous = appliedRender
        appliedRender = render

        let size = NSSize(width: render.totalWidth, height: render.height)
        // Grow rightwards only: the origin is the user's dragged position and
        // the pill must stay exactly where they put it — unless that would put
        // it off the right edge, which is what `placedOrigin` handles.
        let target = NSRect(origin: placedOrigin(width: render.totalWidth), size: size)
        let change = PillMotion.frameChange(
            wasVisible: previous.isVisible, isVisible: render.isVisible,
            oldWidth: previous.totalWidth, newWidth: render.totalWidth,
            newState: render.state,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)

        switch change.kind {
        case .appear:
            hideGeneration += 1                      // cancel any pending order-out
            box.render = render                      // content ready before the fade
            // A show that interrupts the hide sink resumes from wherever the
            // panel is — fading back up reads as one gesture, not a blink.
            let interruptedHide = panel.isVisible
            if !interruptedHide {
                setFrameDirect(panel, host,
                               change.animatesFrame ? target.offsetBy(dx: 0, dy: -change.travel)
                                                    : target)
                panel.alphaValue = 0
            } else if !change.animatesFrame {
                setFrameDirect(panel, host, target)
            }
            panel.orderFrontRegardless()
            animateFrame(duration: change.duration, timing: .easeOut) {
                panel.animator().alphaValue = 1
                if change.animatesFrame { panel.animator().setFrame(target, display: true) }
            }

        case .hide:
            // The content keeps its last visible frame while the panel sinks;
            // the hidden render lands once the panel is off screen.
            let sunk = panel.frame.offsetBy(dx: 0, dy: -change.travel)
            animateFrame(duration: change.duration, timing: .easeIn,
                         hideCompletion: hideGeneration) {
                panel.animator().alphaValue = 0
                if change.animatesFrame { panel.animator().setFrame(sunk, display: true) }
            }

        case .resize, .contract:
            box.render = render
            if change.animatesFrame {
                animateFrame(duration: change.duration, timing: .easeOut) {
                    panel.animator().setFrame(target, display: true)
                }
            } else {
                setFrameDirect(panel, host, target)
            }
            if render.isVisible { panel.orderFrontRegardless() }

        case .none:
            // A 20 Hz level tick lands here. Never touch the frame while an
            // animation is in flight — the animator already owns the target,
            // and a direct `setFrame` would snap the width mid-spring.
            if frameAnimations == 0, panel.frame != target {
                setFrameDirect(panel, host, target)
            }
            // One property write, not a hosting-view rebuild (§6.3).
            box.render = render
            if render.isVisible {
                panel.orderFrontRegardless()
            } else {
                panel.orderOut(nil)
            }
        }
    }

    private func setFrameDirect(_ panel: NSPanel, _ host: NSView, _ frame: NSRect) {
        suppressMoveNotifications = true
        panel.setFrame(frame, display: false)
        suppressMoveNotifications = false
        host.frame = NSRect(origin: .zero, size: frame.size)
    }

    /// `NSAnimationContext` around the panel's animator, with the drag guard
    /// held for the whole flight — an animated frame is not a user drag. The
    /// completion handler captures nothing but `self` (a main-actor class) and
    /// value types, so it crosses the Sendable boundary cleanly.
    private func animateFrame(duration: Double,
                              timing: CAMediaTimingFunctionName,
                              hideCompletion generation: Int? = nil,
                              _ changes: () -> Void) {
        frameAnimations += 1
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: timing)
            context.allowsImplicitAnimation = true
            changes()
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.frameAnimations -= 1
                if self.frameAnimations == 0, let panel = self.panel, let host = self.host {
                    // Settle the hosting view on the final content size.
                    host.frame = NSRect(origin: .zero, size: panel.frame.size)
                }
                if let generation { self.completeHide(ifCurrent: generation) }
            }
        })
    }

    /// The tail of the hide sink: order out, restore alpha for the next
    /// appear, and land the hidden render — unless a show interrupted the
    /// sink, in which case the newer generation owns the panel.
    private func completeHide(ifCurrent generation: Int) {
        guard hideGeneration == generation, let panel, let host else { return }
        panel.orderOut(nil)
        panel.alphaValue = 1
        let render = appliedRender
        box.render = render
        let size = NSSize(width: render.totalWidth, height: render.height)
        setFrameDirect(panel, host,
                       NSRect(origin: placedOrigin(width: render.totalWidth), size: size))
    }

    // MARK: - deferred actions (`_schedule_hide` / `_cancel_hide_timer`)

    private func schedule(_ seconds: Double, _ action: PillDeferredAction) {
        cancelTimer()
        deferredTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.deferredTimer = nil
                self.model.fireDeferred(action)
            }
        }
    }

    private func cancelTimer() {
        deferredTimer?.invalidate()
        deferredTimer = nil
    }
}

// MARK: - the drawn surface

/// The hosting view for `PillSurface`.
///
/// The only reason it is a subclass: `isMovableByWindowBackground` needs the
/// view under the cursor to say the drag belongs to the window, and a hosting
/// view full of interactive-by-default SwiftUI does not. The pill has no
/// controls, so every mouse-down on it is a drag (§7 — no cancel/confirm
/// buttons, releasing the key is confirm).
final class PillHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { true }
    override var isOpaque: Bool { false }

    required init(rootView: Content) {
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used — the pill is built in code")
    }
}
#endif
