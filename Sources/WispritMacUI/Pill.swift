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
/// what it hosts is not. The 26 pt dot is a ten-bar capsule waveform: body,
/// rim, tail and glyphs drawn by `PillSurface`, and the meter itself by
/// `PillMeterLayerView`, whose `CALayer`s the render server tweens between the
/// 20 Hz level samples. Nothing in the level path touches SwiftUI.
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
    /// The glass under the body. A sibling of the hosting view rather than its
    /// parent, so Reduce Transparency can take the blur away without taking the
    /// pill with it, and capsule-masked so the window shadow hugs the pill's
    /// real silhouette (§2.2 — the pill is a capsule all the way down).
    private var glass: PillGlassView?
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

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    // MARK: - public state API (main thread)

    /// NEW — the key is down, audio has not started. Optional: a session that
    /// never calls it goes straight to `showRecording` exactly as before.
    public func showIdle() { model.showIdle() }
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
    public func flashMissed(_ message: String = PillGeometry.missedMessage) {
        model.flashMissed(message)
    }
    /// NEW — the marginal-audio miss: a `missed` body with the alarm states'
    /// width and dwell, because the copy is an instruction.
    public func flashTooQuiet(_ message: String) { model.flashTooQuiet(message) }
    /// NEW — Secure Keyboard Entry blocked the insertion; the text is on the
    /// clipboard. Until the session adopts it, `flashError` carries the same
    /// message with the shorter error timing.
    public func flashBlockedSecure(_ message: String = PillGeometry.blockedSecureMessage) {
        model.flashBlockedSecure(message)
    }
    public func hide() { model.hide() }

    /// Current frame — exposed for the integration layer's diagnostics.
    public var currentRender: PillRender { model.render }

    /// Where the panel is, in screen coordinates. Diagnostics only — and the
    /// one thing `Wisprit pill-demo` needs in order to aim a screenshot at the
    /// pill instead of at the whole desktop.
    public var frameOnScreen: CGRect? { panel?.frame }

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
        // The pill's ground is always near-black (§1.7), so pin the appearance
        // rather than inheriting the system's. Two things depend on it: the
        // `NSVisualEffectView` below picks the dark form of its material, and
        // the meter's tint crossfade — which resolves `hot` per appearance —
        // stops reaching for `#F07818` on a Light-mode Mac, where the palette
        // says plainly that it "goes muddy on near-black".
        panel.appearance = NSAppearance(named: .darkAqua)

        // Glass under paint. `PillSurface` draws a near-black tint at 76% over
        // this, so the desktop moves behind the pill and the tint still decides
        // the reading — the legibility argument the flat fill was defending is
        // unchanged, and what it buys is the one thing an Electron pill can
        // never have.
        //
        // The two are siblings rather than parent and child on purpose: Reduce
        // Transparency has to be able to take the glass away without taking the
        // pill with it, and `isHidden` on a superview hides everything under it.
        let content = PillPanelView(frame: NSRect(origin: .zero, size: frame.size))
        let glass = PillGlassView(frame: content.bounds)
        let host = PillHostingView(rootView: PillSurface(box: box))
        // Frame-driven, never content-driven. `PillSurface` fills whatever it
        // is given (see its `body`), so an `NSHostingView` that still consults
        // its intrinsic content size resolves "fill" as *unbounded* and draws
        // a capsule thousands of points wide — of which the panel shows the
        // flat middle. A rectangle, in other words, and one that only appears
        // once a width animation has been through.
        host.sizingOptions = []
        host.frame = content.bounds
        host.autoresizingMask = [.width, .height]
        content.addSubview(glass)
        content.addSubview(host)
        panel.contentView = content
        self.panel = panel
        self.host = host
        self.glass = glass
        applyTransparencyPreference()
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(accessibilityDisplayOptionsChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        restorePosition()
    }

    /// Reduce Transparency turns the glass off entirely; `PillSurface` reads the
    /// same system flag through `@Environment(\.accessibilityReduceTransparency)`
    /// and puts the body back to its opaque 92%, so the two layers can never
    /// disagree about whether there is a blur to tint.
    @objc private func accessibilityDisplayOptionsChanged() {
        MainActor.assumeIsolated { applyTransparencyPreference() }
    }

    private func applyTransparencyPreference() {
        glass?.isHidden = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
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
        // `preferredOrigin` is, by convention, where a LISTENING-width pill's
        // origin sits (`windowDidMove` normalizes whatever size was dragged).
        // Every other size is placed around that pill's centre, so the mini
        // sliver rests exactly under where the capsule will grow and a notice
        // unfolds from the middle instead of marching right.
        let centered = anchor.x + (PillGeometry.widthListening - width) / 2.0
        let limit = screen.visibleFrame.maxX - PillGeometry.edgeMargin - width
        let x = max(screen.visibleFrame.minX, min(centered, limit))
        return CGPoint(x: x, y: anchor.y)
    }

    // MARK: - NSWindowDelegate

    public func windowDidMove(_ notification: Notification) {
        guard !suppressMoveNotifications, frameAnimations == 0, let panel else { return }
        // Normalize to the listening-width origin whatever size was dragged —
        // dragging the mini sliver and dragging the full capsule must both
        // mean "the pill lives here". Keeps the persisted format (and every
        // position saved before the mini rest existed) unchanged.
        let normalized = CGPoint(
            x: panel.frame.origin.x + (panel.frame.width - PillGeometry.widthListening) / 2.0,
            y: panel.frame.origin.y)
        preferredOrigin = normalized
        config.persistPosition(normalized)
    }

    /// Every step of every width animation, including the ones AppKit drives
    /// on the animator's own clock. Two jobs, and both are shape correctness.
    ///
    /// **The hosting view must not lag the panel.** SwiftUI draws the capsule
    /// at the render's width; if the panel has already contracted past it, the
    /// capsule is clipped to a rectangle for the rest of the animation. Pinning
    /// the host here — rather than only in the completion handler — means the
    /// drawn shape is a capsule in every intermediate frame.
    ///
    /// **The window shadow must be re-derived.** A borderless window's shadow
    /// comes from its rendered alpha and is then cached; AppKit does not
    /// recompute it because the frame moved. One stale rectangular shadow and
    /// the pill stops being capsule-shaped — it paints the two corner regions
    /// the capsule leaves empty. `pill-demo` caught exactly that on a
    /// held-width `finalizing` and mid-unfold on a notice.
    public func windowDidResize(_ notification: Notification) {
        guard let panel, let host else { return }
        let size = panel.frame.size
        if host.frame.size != size { host.frame = NSRect(origin: .zero, size: size) }
        // Draw the capsule at the width the window *actually has*, right now.
        //
        // A panel-frame animation is driven by AppKit on its own clock, and
        // SwiftUI knows nothing about it: left alone it keeps drawing the
        // capsule at the render's final width while the window is still
        // travelling, and a wide capsule centred in a narrow panel loses both
        // caps to the clip — the pill spends the whole animation as a slab.
        // Feeding the live width back is what makes the two exact.
        //
        // It writes `box.render` at the display's rate, which sounds expensive
        // and is not: this only ever runs during a state transition. The 20 Hz
        // level path changes no width, so it never comes through here.
        if frameAnimations > 0, box.render.totalWidth != size.width {
            box.render.totalWidth = size.width
        }
        glass?.refreshMask()
        panel.invalidateShadow()
    }

    // MARK: - rendering

    /// One render, one frame decision. The panel-frame rows live here: appear
    /// fade + 4 pt rise (90 ms ease-out), width change (120 ms, or the toast's
    /// 400 ms unfold / 250 ms fold), the commit's contraction back to the
    /// resting capsule (140 ms), and the hide fade + 3 pt sink (160 ms ease-in,
    /// order-out on completion). Under Reduce Motion the frame snaps and only
    /// the opacity fades survive — durations stay, motion goes.
    ///
    /// The 20 Hz level path leaves on the first branch and never reaches the
    /// switch at all: a meter-only render goes straight to the layer view, so
    /// during dictation neither SwiftUI nor AppKit is asked to lay anything
    /// out. That branch is the CGEventTap's whole budget, and it is why the
    /// meter can afford to interpolate at 60 fps.
    private func apply(_ render: PillRender) {
        guard let panel, let host else { return }
        let previous = appliedRender
        appliedRender = render

        let size = NSSize(width: render.totalWidth, height: render.height)
        // Grow rightwards only: the origin is the user's dragged position and
        // the pill must stay exactly where they put it — unless that would put
        // it off the right edge, which is what `placedOrigin` handles.
        let target = NSRect(origin: placedOrigin(width: render.totalWidth), size: size)

        // The bypass. It still owes the `.none` arm's two non-drawing duties —
        // the frame correction and the order front/out — because those are
        // panel plumbing, not rendering, and dropping them would leave a pill
        // that never came back after a hide.
        if PillRender.isMeterOnly(previous, render), box.meterSink?(render) == true {
            if frameAnimations == 0, panel.frame != target {
                setFrameDirect(panel, host, target)
            }
            if render.isVisible { panel.orderFrontRegardless() } else { panel.orderOut(nil) }
            return
        }

        let change = PillMotion.frameChange(
            wasVisible: previous.isVisible, isVisible: render.isVisible,
            oldWidth: previous.totalWidth, newWidth: render.totalWidth,
            newState: render.state,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            notice: PillMotion.NoticeChange.between(previous, render))

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
            animateFrame(duration: change.duration, curve: change.curve) {
                panel.animator().alphaValue = 1
                if change.animatesFrame { panel.animator().setFrame(target, display: true) }
            }

        case .hide:
            // The content keeps its last visible frame while the panel sinks;
            // the hidden render lands once the panel is off screen.
            let sunk = panel.frame.offsetBy(dx: 0, dy: -change.travel)
            animateFrame(duration: change.duration, curve: change.curve,
                         hideCompletion: hideGeneration) {
                panel.animator().alphaValue = 0
                if change.animatesFrame { panel.animator().setFrame(sunk, display: true) }
            }

        case .resize, .contract:
            // Start the drawn capsule where the *window* is, not where it is
            // going: `windowDidResize` takes over from the first step, but the
            // first step has not happened yet, and one frame of slab is still
            // a frame of slab.
            if change.animatesFrame {
                var drawn = render
                drawn.totalWidth = panel.frame.width
                box.render = drawn
            } else {
                box.render = render
            }
            if change.animatesFrame {
                // The hosting view travels *with* the panel, in the same group
                // and on the same curve.
                //
                // Left to itself it does not: AppKit resizes it when the
                // animation lands, so for the length of the animation the
                // drawn capsule and the window disagree about how wide the pill
                // is. Both spellings of that disagreement are ugly and both
                // were photographed — a capsule centred in a narrower host has
                // *both* caps clipped and comes out a slab, and a capsule
                // narrower than the panel leaves bare glass beside it. Neither
                // is a thing SwiftUI can fix from inside; the two frames simply
                // have to move together.
                animateFrame(duration: change.duration, curve: change.curve) {
                    panel.animator().setFrame(target, display: true)
                }
            } else {
                setFrameDirect(panel, host, target)
            }
            if render.isVisible { panel.orderFrontRegardless() }

        case .none:
            // A state change that moved nothing the panel owns — the tint
            // crossfade at the end of `prewarming`, a glyph swap, a message.
            // (A level tick never gets here: the meter sink took it above.)
            // Never touch the frame while an animation is in flight — the
            // animator already owns the target, and a direct `setFrame` would
            // snap the width mid-spring.
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

    /// The one place a named curve becomes a real one.
    ///
    /// Two of the four are AppKit's own; the toast's unfold and fold are
    /// Wispr's measured beziers, and they are the reason this is a lookup
    /// rather than a `CAMediaTimingFunctionName` parameter. An unfold that
    /// leaves fast and arrives asymptotically is what makes a widening capsule
    /// read as *unfolding* rather than as growing.
    private static func timingFunction(_ curve: PillMotion.Curve) -> CAMediaTimingFunction {
        guard let c = curve.control else {
            return CAMediaTimingFunction(name: curve == .easeIn ? .easeIn : .easeOut)
        }
        return CAMediaTimingFunction(controlPoints: Float(c.0), Float(c.1),
                                     Float(c.2), Float(c.3))
    }

    private func setFrameDirect(_ panel: NSPanel, _ host: NSView, _ frame: NSRect) {
        suppressMoveNotifications = true
        panel.setFrame(frame, display: false)
        suppressMoveNotifications = false
        host.frame = NSRect(origin: .zero, size: frame.size)
        panel.invalidateShadow()
    }

    /// `NSAnimationContext` around the panel's animator, with the drag guard
    /// held for the whole flight — an animated frame is not a user drag. The
    /// completion handler captures nothing but `self` (a main-actor class) and
    /// value types, so it crosses the Sendable boundary cleanly.
    private func animateFrame(duration: Double,
                              curve: PillMotion.Curve,
                              hideCompletion generation: Int? = nil,
                              _ changes: () -> Void) {
        frameAnimations += 1
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = Pill.timingFunction(curve)
            context.allowsImplicitAnimation = true
            changes()
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.frameAnimations -= 1
                if self.frameAnimations == 0, let panel = self.panel, let host = self.host {
                    // Settle the hosting view on the final content size, and
                    // re-cut the glass: both the capsule mask and the window
                    // shadow are only correct once the frame has stopped.
                    host.frame = NSRect(origin: .zero, size: panel.frame.size)
                    // Hand the logical render back: the live width above is a
                    // travelling value, not the truth about the frame.
                    self.box.render = self.appliedRender
                    self.glass?.refreshMask()
                    panel.invalidateShadow()
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

/// The panel's content view: nothing but a transparent tray holding the glass
/// and the surface, and the same "every mouse-down is a drag" answer.
final class PillPanelView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
    override var isOpaque: Bool { false }
}

/// The blur under the body.
///
/// `.hudWindow` on `.behindWindow` is the material AppKit uses for its own
/// floating HUDs, which is exactly what this is; the capsule `maskImage` is
/// what keeps it from being a rectangle of frosted desktop behind a capsule of
/// paint — and, because the window shadow is derived from rendered alpha, is
/// also what keeps the shadow hugging the pill's real silhouette.
final class PillGlassView: NSVisualEffectView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        isEmphasized = false
        autoresizingMask = [.width, .height]
        maskImage = PillGlassView.capsuleMask(height: PillGeometry.height)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used — the pill is built in code")
    }

    /// Re-assert the mask on every resize.
    ///
    /// A layer `cornerRadius` is *not* an option here, however much tidier it
    /// would be: for a `.behindWindow` material the blur is composited by the
    /// window server rather than drawn into this view's layer, so the layer's
    /// own clipping does nothing and the glass comes back as a rectangle. The
    /// stretchable cap-inset image is the sanctioned way to shape one, and it
    /// wants re-asserting when the view changes size.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        refreshMask()
    }

    /// Assign the mask again.
    ///
    /// Assigning it *during* a frame animation does not stick — the window
    /// server is holding the blur region it had when the animation started —
    /// so `Pill` calls this again once the animation settles. Without that
    /// second call the glass stays a rectangle for the rest of the pill's life,
    /// which is a dark slab in the two corners the capsule leaves empty.
    func refreshMask() {
        maskImage = PillGlassView.capsuleMask(height: PillGeometry.height)
    }

    override var mouseDownCanMoveWindow: Bool { true }

    /// A resizable capsule: two end caps and one stretchable point between
    /// them, so every panel width gets the same true capsule without ever
    /// rebuilding the image.
    static func capsuleMask(height: Double) -> NSImage {
        let radius = height / 2
        let size = NSSize(width: radius * 2 + 1, height: height)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: 0, left: radius, bottom: 0, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
#endif
