#if canImport(AppKit)
import AppKit
import WispritKit

/// The floating status indicator — the thin AppKit edge over `PillModel`.
///
/// Port of `wisprit/pill.py`: a tiny, borderless, non-activating `NSPanel` that
/// floats above every app (and full-screen spaces) as a minimal "Wisprit is
/// listening" dot. Draggable; position persists through an injected callback.
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
    private var view: PillView?
    private var deferredTimer: Timer?
    /// Guards `windowDidMove` against our own frame changes — only a user drag
    /// may overwrite the persisted position.
    private var suppressMoveNotifications = false

    public init(configuration: Configuration = Configuration()) {
        self.config = configuration
        self.model = PillModel(isSuppressed: configuration.isSuppressed)
        super.init()
        wireModel()
        build()
    }

    // MARK: - public state API (main thread)

    public func showRecording() { model.showRecording() }
    public func updateLevel(_ level: Double) { model.updateLevel(level) }
    /// NEW — render the tail of the in-progress transcript while recording.
    public func livePartial(_ text: String) { model.livePartial(text) }
    /// NEW — flash a short message ("Learned Sharique").
    public func transientNotice(_ text: String) { model.transientNotice(text) }
    public func showFinalizing() { model.showFinalizing() }
    public func flashSuccess() { model.flashSuccess() }
    public func flashError(_ message: String = "") { model.flashError(message) }
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
        let frame = NSRect(x: 0, y: 0, width: PillGeometry.width, height: PillGeometry.height)
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

        let view = PillView(frame: frame)
        panel.contentView = view
        self.panel = panel
        self.view = view
        restorePosition()
    }

    /// `_restore_position`: persisted origin, else bottom-centre of the main
    /// screen with a 90 pt margin.
    private func restorePosition() {
        guard let panel else { return }
        suppressMoveNotifications = true
        defer { suppressMoveNotifications = false }

        if let saved = config.savedPosition() {
            panel.setFrameOrigin(saved)
            return
        }
        guard let screen = NSScreen.main else { return }
        let f = screen.frame
        panel.setFrameOrigin(NSPoint(x: f.origin.x + (f.size.width - PillGeometry.width) / 2.0,
                                     y: f.origin.y + PillGeometry.bottomMargin))
    }

    // MARK: - NSWindowDelegate

    public func windowDidMove(_ notification: Notification) {
        guard !suppressMoveNotifications, let panel else { return }
        config.persistPosition(panel.frame.origin)
    }

    // MARK: - rendering

    private func apply(_ render: PillRender) {
        guard let panel, let view else { return }

        // Grow rightwards only: the origin is the user's dragged position and
        // the dot must stay exactly where they put it.
        let size = NSSize(width: render.totalWidth, height: render.height)
        if panel.frame.size != size {
            suppressMoveNotifications = true
            panel.setFrame(NSRect(origin: panel.frame.origin, size: size), display: false)
            suppressMoveNotifications = false
            view.frame = NSRect(origin: .zero, size: size)
        }

        view.render = render
        view.needsDisplay = true

        if render.isVisible {
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
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

/// `_PillView`: a halo, a level-reactive dot, and (new) a capsule bubble.
final class PillView: NSView {
    var render: PillRender = .collapsed

    override var isOpaque: Bool { false }
    override var mouseDownCanMoveWindow: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let w = PillGeometry.width
        let h = PillGeometry.height
        let inset = PillGeometry.haloInset

        // Faint translucent halo so the dot reads on any background.
        NSColor(calibratedWhite: 0.0, alpha: PillGeometry.haloAlpha).setFill()
        NSBezierPath(ovalIn: NSRect(x: inset, y: inset,
                                    width: w - 2 * inset, height: h - 2 * inset)).fill()

        // The dot itself grows subtly with input level while recording.
        let cx = w / 2.0, cy = h / 2.0
        let r = render.dotRadius
        NSColor(calibratedRed: render.dot.r, green: render.dot.g, blue: render.dot.b,
                alpha: PillGeometry.dotAlpha).setFill()
        NSBezierPath(ovalIn: NSRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)).fill()

        drawBubble()
    }

    private func drawBubble() {
        guard !render.bubble.isEmpty, render.bubbleWidth > 0 else { return }
        let bh = PillBubbleGeometry.height
        let rect = NSRect(x: PillGeometry.width + PillBubbleGeometry.gap,
                          y: (PillGeometry.height - bh) / 2.0,
                          width: render.bubbleWidth,
                          height: bh)
        NSColor(calibratedWhite: 0.0, alpha: PillGeometry.haloAlpha).setFill()
        NSBezierPath(roundedRect: rect,
                     xRadius: PillBubbleGeometry.cornerRadius,
                     yRadius: PillBubbleGeometry.cornerRadius).fill()

        let paragraph = NSMutableParagraphStyle()
        // Truncate the head: the newest words matter most.
        paragraph.lineBreakMode = .byTruncatingHead
        paragraph.alignment = .left
        let attributed = NSAttributedString(string: render.bubble, attributes: [
            .font: PillView.bubbleFont,
            .foregroundColor: NSColor(calibratedWhite: 1.0, alpha: 0.92),
            .paragraphStyle: paragraph,
        ])
        let lineHeight = attributed.size().height
        let textRect = NSRect(x: rect.minX + PillBubbleGeometry.textInset,
                              y: rect.midY - lineHeight / 2.0,
                              width: rect.width - 2 * PillBubbleGeometry.textInset,
                              height: lineHeight)
        attributed.draw(with: textRect, options: [.usesLineFragmentOrigin])
    }

    private static let bubbleFont: NSFont = {
        let base = NSFont.systemFont(ofSize: 11, weight: .medium)
        if let rounded = base.fontDescriptor.withDesign(.rounded) {
            return NSFont(descriptor: rounded, size: 11) ?? base
        }
        return base
    }()
}
#endif
