#if canImport(AppKit)
import AppKit
import QuartzCore

/// A thread-safe sequence stamp. Callers take one on their own thread, at
/// call time, before hopping to main — which is what lets the lifecycle tell
/// a level tick that was *taken* before `showFinalizing` from one taken after.
public final class NotchSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    public init() {}

    public func next() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        value &+= 1
        return value
    }
}

/// States the preview hook can pin on screen for screenshots.
public enum NotchPreview: Equatable, Sendable {
    case prewarming
    case listening
    case processing(NotchProcessing)
    case result(NotchResult)
}

/// The living notch: a black body that grows sideways out of the camera
/// housing while you dictate, and folds back into it when you are done.
///
/// **Lifecycle.** All state lives in a `NotchLifecycle` value; this class only
/// feeds it signals and time and draws what it says. Two clocks drive it:
///
/// - a display link (60 fps cap) while visible — every frame steps the springs
///   and runs the lifecycle's deadlines;
/// - a 4 Hz heartbeat timer while visible — runs the same deadlines and the
///   `pill_hidden` probe even if the display link stalls (display asleep,
///   window occluded), so the fold and the watchdogs fire regardless.
///
/// Both are torn down the moment the phase is `.hidden`. Hidden costs nothing:
/// no timers, no display link, panel ordered out.
///
/// **Panel.** Click-through, non-activating, on every Space and beside
/// full-screen apps, one level above the menu bar so it may touch the screen
/// top. Exactly as tall as the menu-bar band.
@MainActor
public final class NotchIndicator {
    public typealias Clock = () -> TimeInterval

    private let isSuppressed: () -> Bool
    private let clock: Clock
    private var lifecycle = NotchLifecycle()
    private var choreography: NotchChoreography?
    private var panel: NSPanel?
    private var host: NotchHostView?
    private var tree: NotchLayerTree?
    private var layout: NotchLayout?
    private var displayLink: CADisplayLink?
    private var linkTarget: NotchLinkTarget?
    private var heartbeat: Timer?
    private var lastFrameAt: TimeInterval = 0
    private var observers: [NSObjectProtocol] = []
    private var previewFeed: Timer?

    /// Above the menu bar, so the frame is allowed to touch the screen top.
    /// `.floating` is clamped to the visible frame and ends up under the notch.
    static let overlayLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 2)

    public init(isSuppressed: @escaping () -> Bool = { false },
                clock: @escaping Clock = { CACurrentMediaTime() }) {
        self.isSuppressed = isSuppressed
        self.clock = clock
    }

    /// What is on screen, per the lifecycle.
    public var phase: NotchPhase { lifecycle.phase }

    /// True only while the panel is ordered on screen.
    public var isOnScreen: Bool { panel?.isVisible == true }

    /// The panel's frame, for demo screenshots.
    public var frameOnScreen: CGRect? { panel?.frame }

    // MARK: - signals

    /// Apply one session signal. `sequence` is the caller's stamp (see
    /// `NotchSequence`); nil means "now".
    public func receive(_ signal: NotchSignal, sequence: UInt64? = nil) {
        let now = clock()
        if case .level = signal {
            // 20 Hz. Stored for the next frame; no drawing, no settings read.
            // A level never opens anything, so it needs no suppression check.
            lifecycle.receive(signal, sequence: sequence, at: now)
            return
        }
        // `pill_hidden` wins over everything, including a result beat.
        let applied: NotchSignal = (signal != .suppress && isSuppressed()) ? .suppress : signal
        lifecycle.receive(applied, sequence: sequence, at: now)
        sync(at: now)
    }

    /// Listening, mic live. Kept for the preview and tests.
    public func show() { receive(.record) }
    public func updateLevel(_ level: Double) { receive(.level(level)) }
    /// Fold away (animated).
    public func hide() { receive(.dismiss) }
    /// Gone this instant, no animation.
    public func hideImmediately() { receive(.suppress) }

    /// Pin a state on screen for screenshots (`WISPRIT_PREVIEW_NOTCH`). No
    /// watchdogs, no dwell; listening gets a synthetic voice.
    public func preview(_ state: NotchPreview) {
        lifecycle.pinned = true
        previewFeed?.invalidate()
        previewFeed = nil
        switch state {
        case .prewarming:
            receive(.prewarm)
        case .listening:
            receive(.prewarm)
            receive(.record)
            let start = clock()
            let feed = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.receive(.level(NotchIndicator.syntheticSpeech(self.clock() - start)))
                }
            }
            RunLoop.main.add(feed, forMode: .common)
            previewFeed = feed
        case .processing(let stage):
            receive(.prewarm)
            receive(.processing(stage))
        case .result(let kind):
            receive(.prewarm)
            receive(.result(kind))
        }
    }

    /// A plausible speaking envelope, deterministic: a phrase contour with
    /// syllables on top. Shared by the preview and the demo.
    public static func syntheticSpeech(_ t: Double) -> Double {
        let phrase = 0.55 + 0.45 * sin(t * 1.7)
        let syllable = 0.5 + 0.5 * sin(t * 13.0)
        let pause = (t.truncatingRemainder(dividingBy: 3.2)) > 2.5 ? 0.05 : 1.0
        return max(0, min(1, 0.26 * phrase * (0.35 + 0.75 * syllable) * pause))
    }

    // MARK: - visibility

    private func sync(at now: TimeInterval) {
        if lifecycle.phase == .hidden {
            teardown()
            return
        }
        guard ensureVisible() else {
            // No screen to draw on: there is nothing to show, so there must be
            // nothing pending either.
            lifecycle.receive(.suppress, at: now)
            return
        }
        renderFrame(at: now)
    }

    /// Place, build and order the panel front. False when there is no screen.
    private func ensureVisible() -> Bool {
        let panel = ensurePanel()
        if !panel.isVisible || layout == nil {
            guard let placed = place(panel) else { return false }
            if choreography == nil || choreography?.layout != placed {
                choreography = NotchChoreography(layout: placed,
                                                 reduceMotion: Self.reduceMotion,
                                                 increaseContrast: Self.increaseContrast)
            }
            panel.alphaValue = 1
            panel.orderFrontRegardless()
            startClocks()
        }
        return true
    }

    private func teardown() {
        stopClocks()
        previewFeed?.invalidate()
        previewFeed = nil
        lifecycle.pinned = false
        panel?.orderOut(nil)
        // A fresh choreography next time: every open starts folded.
        if let layout {
            choreography = NotchChoreography(layout: layout,
                                             reduceMotion: Self.reduceMotion,
                                             increaseContrast: Self.increaseContrast)
        }
    }

    // MARK: - clocks

    private func startClocks() {
        if displayLink == nil, let host {
            let target = NotchLinkTarget(owner: self)
            let link = host.displayLink(target: target, selector: #selector(NotchLinkTarget.tick(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
            link.add(to: .main, forMode: .common)
            displayLink = link
            linkTarget = target
        }
        if heartbeat == nil {
            let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.beat() }
            }
            RunLoop.main.add(timer, forMode: .common)
            heartbeat = timer
        }
    }

    private func stopClocks() {
        displayLink?.invalidate()
        displayLink = nil
        linkTarget = nil
        heartbeat?.invalidate()
        heartbeat = nil
    }

    fileprivate func frameTick() {
        renderFrame(at: clock())
    }

    /// The heartbeat: suppression, deadlines, and a frame if the display link
    /// has gone quiet — so a fold always finishes and the panel always leaves.
    private func beat() {
        let now = clock()
        if lifecycle.phase != .hidden, isSuppressed() {
            lifecycle.receive(.suppress, at: now)
        }
        lifecycle.advance(to: now)
        if lifecycle.phase == .hidden {
            teardown()
        } else if now - lastFrameAt > 0.2 {
            renderFrame(at: now)
        }
    }

    private func renderFrame(at now: TimeInterval) {
        lastFrameAt = now
        lifecycle.advance(to: now)
        guard lifecycle.phase != .hidden, var choreo = choreography, let tree else {
            teardown()
            return
        }
        let frame = choreo.step(to: now, lifecycle: lifecycle)
        if lifecycle.phase == .collapsing, choreo.isFolded {
            choreography = choreo
            lifecycle.collapseSettled(at: now)
            teardown()
            return
        }
        choreography = choreo
        tree.apply(frame)
    }

    // MARK: - panel

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        // `isFloatingPanel` forces `.floating`, which sits under the menu bar.
        // AppKit then clamps the frame into the content area, so the body
        // lands under the housing. The level has to be set after that, high
        // enough to occupy the menu-bar band.
        panel.isFloatingPanel = true
        panel.level = Self.overlayLevel
        panel.becomesKeyOnlyIfNeeded = true
        panel.isExcludedFromWindowsMenu = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = NotchHostView(frame: panel.contentView?.bounds ?? .zero)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        self.panel = panel
        self.host = host

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel, panel.isVisible else { return }
                self.layout = nil
                _ = self.ensureVisible()
            }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.choreography?.reduceMotion = Self.reduceMotion
                self?.choreography?.increaseContrast = Self.increaseContrast
            }
        })
        return panel
    }

    @discardableResult
    private func place(_ panel: NSPanel) -> NotchLayout? {
        let screens = NSScreen.screens.map(NotchScreen.init(screen:))
        let mainIndex = NSScreen.screens.firstIndex { $0 == NSScreen.main }
        guard let placed = NotchGeometry.layout(screens: screens, mainIndex: mainIndex) else {
            return nil
        }
        panel.level = Self.overlayLevel
        panel.setFrame(placed.frame, display: false)
        // A level that cannot cover the menu bar is shoved downward by a full
        // window height. If that happened, step up and place it again.
        if panel.frame.maxY < placed.frame.maxY - 0.5 {
            panel.level = .popUpMenu
            panel.setFrame(placed.frame, display: false)
        }
        if layout != placed || tree == nil {
            let scale = NSScreen.screens.first { $0.frame.intersects(placed.frame) }?.backingScaleFactor ?? 2
            let tree = NotchLayerTree(layout: placed, scale: scale)
            host?.install(tree.root)
            self.tree = tree
        }
        layout = placed
        return placed
    }

    private static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private static var increaseContrast: Bool { NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast }
}

/// `CADisplayLink` retains its target; this breaks the cycle and keeps the
/// indicator free of `NSObject`.
private final class NotchLinkTarget: NSObject {
    weak var owner: NotchIndicator?

    init(owner: NotchIndicator) { self.owner = owner }

    @objc func tick(_ link: CADisplayLink) {
        MainActor.assumeIsolated { owner?.frameTick() }
    }
}

/// The panel's content: a layer host that never takes a click.
private final class NotchHostView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.masksToBounds = false
    }

    required init?(coder: NSCoder) { nil }

    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func install(_ root: CALayer) {
        layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
        root.frame = bounds
        layer?.addSublayer(root)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.sublayers?.forEach { $0.frame = bounds }
        CATransaction.commit()
    }
}

extension NotchScreen {
    @MainActor
    init(screen: NSScreen) {
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        let builtin = number.map { CGDisplayIsBuiltin($0.uint32Value) != 0 } ?? false
        self.init(frame: screen.frame,
                  visibleFrame: screen.visibleFrame,
                  auxiliaryTopLeft: screen.auxiliaryTopLeftArea,
                  auxiliaryTopRight: screen.auxiliaryTopRightArea,
                  isBuiltin: builtin)
    }
}
#endif
