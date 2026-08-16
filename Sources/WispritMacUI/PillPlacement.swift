import Foundation

/// Long axis of the capsule. Left/right docks stand the pill up; top/bottom
/// and free-floating keep it horizontal — the same rule native HUDs use, and
/// the one Wispr Flow's side-dock reflow follows (plus top, which Flow does
/// not offer and which we do).
public enum PillAxis: String, Equatable, Sendable {
    case horizontal
    case vertical
}

/// The screen edge the pill is sitting against, or would sit against.
public enum PillScreenEdge: String, Equatable, Sendable, CaseIterable {
    case top, bottom, left, right

    public var axis: PillAxis {
        switch self {
        case .left, .right: return .vertical
        case .top, .bottom: return .horizontal
        }
    }
}

/// Hover/recording chrome. Wispr Flow's documented Flow Bar controls:
/// idle hover expands the waveform capsule (click starts); during recording
/// the bar shows Cancel (X) and Stop/confirm (✓) beside the waveform.
public enum PillHoverChrome: String, Equatable, Sendable {
    case none
    case idle
    case recording
}

/// Pure placement maths — orientation, clamping, the canonical origin the
/// settings file already stores. AppKit-free so the edge rules are tests,
/// not a screen recording.
public enum PillPlacement {
    /// How close the pill centre must be to an edge before the capsule
    /// reorients. Wide enough to catch a drag into the Dock/menu-bar margin,
    /// tight enough that the middle of the screen stays a free-floating bar.
    public static let dockThreshold: Double = 48.0

    /// Distance from `point` to each edge of `screen`; the smallest wins.
    /// Ties break left, right, top, then bottom — matching the order a drag
    /// toward a corner most often means.
    public static func nearestEdge(of point: CGPoint, in screen: CGRect) -> PillScreenEdge {
        let left = point.x - screen.minX
        let right = screen.maxX - point.x
        let bottom = point.y - screen.minY
        let top = screen.maxY - point.y
        let nearest = min(left, right, bottom, top)
        if nearest == left { return .left }
        if nearest == right { return .right }
        if nearest == top { return .top }
        return .bottom
    }

    /// Orient from proximity. Inside `threshold` of an edge, take that edge's
    /// axis and remember the edge (so the waveform can grow toward the
    /// centre of the screen). Otherwise stay horizontal and undocked — the
    /// pill is draggable anywhere, not only onto drop zones.
    public static func placement(center: CGPoint, in screen: CGRect,
                                 threshold: Double = dockThreshold)
        -> (axis: PillAxis, edge: PillScreenEdge?) {
        let edge = nearestEdge(of: center, in: screen)
        let distance: Double
        switch edge {
        case .left: distance = center.x - screen.minX
        case .right: distance = screen.maxX - center.x
        case .top: distance = screen.maxY - center.y
        case .bottom: distance = center.y - screen.minY
        }
        if distance <= threshold {
            return (edge.axis, edge)
        }
        return (.horizontal, nil)
    }

    public static func panelSize(long: Double, short: Double, axis: PillAxis) -> CGSize {
        axis == .vertical
            ? CGSize(width: short, height: long)
            : CGSize(width: long, height: short)
    }

    /// Window size for a render. Idle rest draws a 36×10 sliver *inside* the
    /// listening-size panel so hover can expand the capsule without moving
    /// the window origin under the cursor — that origin-shift was the hover
    /// jiggle. Every other state sizes the panel to the drawn capsule.
    public static func hitSize(for render: PillRender) -> CGSize {
        if render.state == .idle && !render.isShaking {
            return panelSize(long: PillGeometry.widthListening,
                             short: PillGeometry.height,
                             axis: render.axis)
        }
        return panelSize(long: render.totalWidth, short: render.height, axis: render.axis)
    }

    /// Drawn capsule inside `panel`, pinned to the docked edge so growth
    /// runs toward the screen centre. Free-floating stays centred.
    public static func visualFrame(in panel: CGSize, visual: CGSize,
                                   edge: PillScreenEdge?) -> CGRect {
        let x: Double
        let y: Double
        switch edge {
        case .left:
            x = 0
            y = (panel.height - visual.height) / 2
        case .right:
            x = panel.width - visual.width
            y = (panel.height - visual.height) / 2
        case .top:
            x = (panel.width - visual.width) / 2
            y = panel.height - visual.height
        case .bottom:
            x = (panel.width - visual.width) / 2
            y = 0
        case nil:
            x = (panel.width - visual.width) / 2
            y = (panel.height - visual.height) / 2
        }
        return CGRect(x: x, y: y, width: visual.width, height: visual.height)
    }

    /// The origin a horizontal listening-width pill would have if it shared
    /// `frame`'s centre. This is the `[x, y]` `pill_position` has always
    /// stored; keeping it means a version that can stand up still restores
    /// where the user left a version that could not.
    public static func canonicalOrigin(for frame: CGRect) -> CGPoint {
        CGPoint(x: frame.midX - PillGeometry.widthListening / 2,
                y: frame.midY - PillGeometry.height / 2)
    }

    public static func frame(center: CGPoint, long: Double, short: Double,
                             axis: PillAxis) -> CGRect {
        let size = panelSize(long: long, short: short, axis: axis)
        return CGRect(x: center.x - size.width / 2,
                      y: center.y - size.height / 2,
                      width: size.width, height: size.height)
    }

    /// Keep the whole capsule on `visible` (the work area — Dock and menu bar
    /// already subtracted) with `margin` to spare. A pill larger than the
    /// inset is centred rather than overflowing one side.
    public static func clamp(_ frame: CGRect, to visible: CGRect,
                             margin: Double = PillGeometry.edgeMargin) -> CGRect {
        let inset = visible.insetBy(dx: margin, dy: margin)
        guard inset.width > 0, inset.height > 0 else { return frame }
        var x = frame.origin.x
        var y = frame.origin.y
        if frame.width >= inset.width {
            x = inset.midX - frame.width / 2
        } else {
            x = min(max(x, inset.minX), inset.maxX - frame.width)
        }
        if frame.height >= inset.height {
            y = inset.midY - frame.height / 2
        } else {
            y = min(max(y, inset.minY), inset.maxY - frame.height)
        }
        return CGRect(x: x, y: y, width: frame.width, height: frame.height)
    }

    /// Index of the screen whose visible frame (then full frame) contains
    /// `point`. Falls back to the nearest centre so a drag across a bezel
    /// still has a screen.
    public static func screenIndex(containing point: CGPoint,
                                   frames: [CGRect],
                                   visibleFrames: [CGRect]) -> Int? {
        for (index, visible) in visibleFrames.enumerated() where visible.contains(point) {
            return index
        }
        for (index, frame) in frames.enumerated() where frame.contains(point) {
            return index
        }
        var best: (Int, CGFloat)?
        for (index, frame) in frames.enumerated() {
            let dx = point.x - frame.midX
            let dy = point.y - frame.midY
            let distance = dx * dx + dy * dy
            if best == nil || distance < best!.1 { best = (index, distance) }
        }
        return best?.0
    }

    /// Degrees to rotate the (horizontally laid-out) meter so the bars grow
    /// toward the centre of the screen when the capsule is vertical.
    public static func meterRotation(edge: PillScreenEdge?) -> Double {
        switch edge {
        case .left: return 90
        case .right: return -90
        case .top, .bottom, nil: return 0
        }
    }
}
