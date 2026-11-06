#if canImport(AppKit)
import AppKit
import CoreGraphics

/// Where the listening outline sits, and the centerline it strokes.
///
/// The window's top edge is the top edge of the screen. The centerline runs
/// down the lit pixels beside the housing, around the bottom corners, across
/// the housing floor, and back up to the top edge. It does not cross the
/// camera, and it does not sit in the content area under the menu bar.
public struct NotchOutlinePlacement: Equatable, Sendable {
    public var frame: CGRect
    /// True when `frame` wraps a camera housing. False is the top-edge contour
    /// used when no display has a notch.
    public var hugsNotch: Bool
    /// Window-local points, y up. The first and last points lie on the top
    /// edge of `frame`.
    public var centerline: [CGPoint]

    public init(frame: CGRect, hugsNotch: Bool, centerline: [CGPoint]) {
        self.frame = frame
        self.hugsNotch = hugsNotch
        self.centerline = centerline
    }
}

/// One display, reduced to the numbers the placement decision needs.
public struct NotchScreen: Equatable, Sendable {
    public var frame: CGRect
    public var visibleFrame: CGRect
    public var auxiliaryTopLeft: CGRect?
    public var auxiliaryTopRight: CGRect?
    public var isBuiltin: Bool

    public init(frame: CGRect,
                visibleFrame: CGRect,
                auxiliaryTopLeft: CGRect?,
                auxiliaryTopRight: CGRect?,
                isBuiltin: Bool) {
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.auxiliaryTopLeft = auxiliaryTopLeft
        self.auxiliaryTopRight = auxiliaryTopRight
        self.isBuiltin = isBuiltin
    }
}

public enum NotchOutlineGeometry {
    /// Width of the contour on a display that has no notch.
    public static let notchWidth: CGFloat = 200
    /// Hairline. Black is this wide; the white wave is thinner and rides it.
    public static let strokeWidth: CGFloat = 2
    /// Lit pixels between the cutout and the inner edge of the stroke.
    public static let housingGap: CGFloat = 1.25
    /// Bottom corners of the housing. The stroke follows the same turn.
    public static let cornerRadius: CGFloat = 10

    /// Centerline distance from a vertical edge of the cutout.
    static var sideOffset: CGFloat { housingGap + strokeWidth / 2 }

    /// Room inside the window so the hairline is not clipped.
    static var sidePad: CGFloat { sideOffset + strokeWidth / 2 + 1.5 }

    /// Prefer a built-in display that actually has a notch. Otherwise the
    /// built-in screen, otherwise the main screen, otherwise the first.
    public static func placement(screens: [NotchScreen], mainIndex: Int?) -> NotchOutlinePlacement? {
        guard !screens.isEmpty else { return nil }
        if let notched = screens.first(where: { notchGap(on: $0) != nil }) {
            return placement(on: notched)
        }
        if let builtin = screens.first(where: \.isBuiltin) {
            return placement(on: builtin)
        }
        if let mainIndex, screens.indices.contains(mainIndex) {
            return placement(on: screens[mainIndex])
        }
        return placement(on: screens[0])
    }

    static func placement(on screen: NotchScreen) -> NotchOutlinePlacement {
        if let gap = notchGap(on: screen) {
            // The menu bar continues a sliver past the housing (1 pt on the
            // 14-inch MacBook). The hairline's lower half lives in that sliver.
            // Anything further is the content area, which this outline does
            // not enter.
            let sliver = max(0, gap.minY - screen.visibleFrame.maxY)
            let bottomExtension = min(strokeWidth / 2, sliver)
            let top = screen.frame.maxY
            let bottom = gap.minY - bottomExtension
            let frame = CGRect(x: gap.minX - sidePad,
                               y: bottom,
                               width: gap.width + sidePad * 2,
                               height: top - bottom)
            let cutout = CGRect(x: sidePad,
                                y: bottomExtension,
                                width: gap.width,
                                height: gap.height)
            return NotchOutlinePlacement(
                frame: frame,
                hugsNotch: true,
                centerline: centerline(around: cutout, frameHeight: frame.height))
        }
        return fallback(on: screen)
    }

    /// The unoccupied gap between the two auxiliary menu-bar areas. Nil when
    /// this display has no notch. The rect's top is the top of those areas;
    /// the window that strokes it is pinned to the screen top separately.
    static func notchGap(on screen: NotchScreen) -> CGRect? {
        guard let left = screen.auxiliaryTopLeft, let right = screen.auxiliaryTopRight else {
            return nil
        }
        let gap = right.minX - left.maxX
        guard gap > 24, gap < 420 else { return nil }
        let depth = max(left.height, right.height)
        guard depth > 8, depth < 80 else { return nil }
        let top = max(left.maxY, right.maxY)
        guard abs(top - screen.frame.maxY) < 4 else { return nil }
        return CGRect(x: left.maxX, y: top - depth, width: gap, height: depth)
    }

    /// Same open contour, notch-width, hung from the top edge of the screen
    /// and kept inside the menu bar.
    private static func fallback(on screen: NotchScreen) -> NotchOutlinePlacement {
        let menu = screen.frame.maxY - screen.visibleFrame.maxY
        let height = menu > 8 ? min(menu, 26) : 22
        let frame = CGRect(x: screen.frame.midX - (notchWidth + sidePad * 2) / 2,
                           y: screen.frame.maxY - height,
                           width: notchWidth + sidePad * 2,
                           height: height)
        let cutout = CGRect(x: sidePad,
                            y: strokeWidth / 2,
                            width: notchWidth,
                            height: height - strokeWidth / 2)
        return NotchOutlinePlacement(
            frame: frame,
            hugsNotch: false,
            centerline: centerline(around: cutout, frameHeight: frame.height))
    }

    /// An open contour around `cutout`: top of the left side, down, around the
    /// bottom corners, across, and up to the top of the right side. `cutout`
    /// and the returned points are in the same y-up local space. The ends sit
    /// on `frameHeight`, which the caller has made the top of the screen.
    static func centerline(around cutout: CGRect, frameHeight: CGFloat) -> [CGPoint] {
        let leftX = cutout.minX - sideOffset
        let rightX = cutout.maxX + sideOffset
        let bottomY = max(strokeWidth / 2, cutout.minY)
        let topY = frameHeight
        let room = min((rightX - leftX) / 2 - 0.5, topY - bottomY - 0.5)
        let radius = min(cornerRadius, max(2, room))
        guard rightX - leftX > radius * 2 + 4, topY > bottomY + radius else {
            return [CGPoint(x: leftX, y: topY), CGPoint(x: rightX, y: topY)]
        }

        var points: [CGPoint] = []
        func add(_ point: CGPoint) {
            if let last = points.last, hypot(last.x - point.x, last.y - point.y) < 0.04 { return }
            points.append(point)
        }
        func segment(from start: CGPoint, to end: CGPoint) {
            let distance = hypot(end.x - start.x, end.y - start.y)
            let steps = max(1, Int((distance / 3).rounded(.up)))
            for step in 0...steps {
                let t = CGFloat(step) / CGFloat(steps)
                add(CGPoint(x: start.x + (end.x - start.x) * t,
                            y: start.y + (end.y - start.y) * t))
            }
        }
        func arc(center: CGPoint, from startAngle: CGFloat, to endAngle: CGFloat) {
            let steps = 8
            for step in 0...steps {
                let t = CGFloat(step) / CGFloat(steps)
                let angle = startAngle + (endAngle - startAngle) * t
                add(CGPoint(x: center.x + cos(angle) * radius,
                            y: center.y + sin(angle) * radius))
            }
        }

        segment(from: CGPoint(x: leftX, y: topY), to: CGPoint(x: leftX, y: bottomY + radius))
        arc(center: CGPoint(x: leftX + radius, y: bottomY + radius),
            from: .pi,
            to: .pi * 1.5)
        segment(from: CGPoint(x: leftX + radius, y: bottomY),
                to: CGPoint(x: rightX - radius, y: bottomY))
        arc(center: CGPoint(x: rightX - radius, y: bottomY + radius),
            from: .pi * 1.5,
            to: .pi * 2)
        segment(from: CGPoint(x: rightX, y: bottomY + radius), to: CGPoint(x: rightX, y: topY))
        return points
    }
}

/// Click-through hairline around the notch while Fn dictation is active.
///
/// The panel is non-activating and ignores mouse events. The black stroke is
/// the body. White beads travel along that same hairline, and the dictation
/// meter only changes their weight. Reduce Motion leaves both strokes still.
@MainActor
public final class NotchOutline {
    private var panel: NSPanel?
    private var wave: NotchWaveView?
    private var timer: Timer?
    private var targetLevel: CGFloat = 0
    private var screenObserver: NSObjectProtocol?

    /// Above the menu bar, so the frame is allowed to touch the screen top.
    /// `.floating` is clamped to the visible frame and ends up under the notch.
    fileprivate static let overlayLevel = NSWindow.Level(
        rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 2)

    public init() {}

    /// True only while the overlay has been ordered on screen.
    public var isOnScreen: Bool { panel?.isVisible == true }

    public func show() {
        let panel = ensurePanel()
        place(panel)
        if panel.isVisible == false {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        }
        startWave()
    }

    public func hide() {
        timer?.invalidate()
        timer = nil
        targetLevel = 0
        wave?.amplitude = 0
        wave?.phase = 0
        panel?.orderOut(nil)
    }

    /// 0…1 from the dictation level ticker. Shaped the same way the old meter
    /// was, so quiet speech still moves the line. Does not open the mic.
    public func updateLevel(_ level: Double) {
        targetLevel = CGFloat(WaveformBuffer.shaped(level))
    }

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
        // AppKit then clamps the frame into the content area, so the stroke
        // lands under the housing. The level has to be set after that, high
        // enough to occupy the menu-bar band.
        panel.isFloatingPanel = true
        panel.level = Self.overlayLevel
        panel.becomesKeyOnlyIfNeeded = true
        panel.isExcludedFromWindowsMenu = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let wave = NotchWaveView(frame: panel.contentView?.bounds ?? .zero)
        wave.autoresizingMask = [.width, .height]
        panel.contentView = wave
        self.panel = panel
        self.wave = wave
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel, panel.isVisible else { return }
                self.place(panel)
            }
        }
        return panel
    }

    private func place(_ panel: NSPanel) {
        let screens = NSScreen.screens.map(NotchScreen.init(screen:))
        let mainIndex = NSScreen.screens.firstIndex { $0 == NSScreen.main }
        guard let placement = NotchOutlineGeometry.placement(screens: screens, mainIndex: mainIndex) else {
            return
        }
        panel.level = Self.overlayLevel
        panel.setFrame(placement.frame, display: true)
        // A level that cannot cover the menu bar is shoved downward by a full
        // window height. If that happened, step up and place it again.
        if panel.frame.maxY < placement.frame.maxY - 0.5 {
            panel.level = .popUpMenu
            panel.setFrame(placement.frame, display: true)
        }
        wave?.centerline = placement.centerline
    }

    private func startWave() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        guard let wave, panel?.isVisible == true else { return }
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        wave.reduceMotion = reduce
        if reduce {
            wave.phase = 0
            wave.amplitude = 0
        } else {
            // The white beads travel about 60 pt/s along the hairline. Level
            // only changes their weight, critically damped, so the contour
            // itself never bows off the housing.
            wave.phase += 60.0 / 30.0
            let lifted = 0.35 + targetLevel * 0.65
            let follow = 1 - exp(-1.0 / 30.0 / 0.08)
            wave.amplitude += (lifted - wave.amplitude) * follow
        }
        wave.needsDisplay = true
    }
}

private extension NotchScreen {
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

/// Black hairline for the body. The white wave is the same path: beads that
/// travel along it, thicker when the meter is up. The contour does not bow.
@MainActor
private final class NotchWaveView: NSView {
    var centerline: [CGPoint] = []
    /// Dash phase, in points, so the white beads move along the hairline.
    var phase: CGFloat = 0
    /// 0…1 weight of the white stroke. Zero under Reduce Motion, which draws
    /// a still white line instead.
    var amplitude: CGFloat = 0
    var reduceMotion = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.clear(bounds)
        guard centerline.count > 1 else { return }
        stroke(centerline, color: .black, width: NotchOutlineGeometry.strokeWidth, dashPhase: nil)
        if reduceMotion {
            stroke(centerline, color: .white, width: 1.2, dashPhase: nil)
        } else {
            let width = 1.15 + amplitude * 0.9
            stroke(centerline, color: .white, width: width, dashPhase: phase)
        }
    }

    private func stroke(_ points: [CGPoint], color: NSColor, width: CGFloat, dashPhase: CGFloat?) {
        let path = NSBezierPath()
        path.move(to: points[0])
        for point in points.dropFirst() { path.line(to: point) }
        path.lineWidth = width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        if let dashPhase {
            let pattern: [CGFloat] = [8, 10]
            pattern.withUnsafeBufferPointer { buffer in
                path.setLineDash(buffer.baseAddress, count: pattern.count, phase: dashPhase)
            }
        }
        color.setStroke()
        path.stroke()
    }
}
#endif
