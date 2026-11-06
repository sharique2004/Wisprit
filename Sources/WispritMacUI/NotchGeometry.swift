import CoreGraphics
import Foundation

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

extension NotchScreen {
    /// A 14-inch MacBook Pro's built-in display — the machine this was tuned
    /// on (measured: housing 185 × 32 pt, menu bar 1 pt deeper).
    public static let macBookPro14 = NotchScreen(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 80, width: 1512, height: 869),
        auxiliaryTopLeft: CGRect(x: 0, y: 950, width: 663.5, height: 32),
        auxiliaryTopRight: CGRect(x: 848.5, y: 950, width: 663.5, height: 32),
        isBuiltin: true)

    /// A 1080p external display with a 24 pt menu bar and no notch.
    public static let external1080 = NotchScreen(
        frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1056),
        auxiliaryTopLeft: nil, auxiliaryTopRight: nil, isBuiltin: false)
}

/// Where the living notch lives on one display, and every size it can take.
///
/// All `CGRect`/`CGPoint` values except `frame` are **panel-local, y up**: the
/// panel's top edge is the top edge of the screen, so `top == band` is the
/// screen's top row and nothing in here may go below `y = 0`, which is the
/// bottom of the menu-bar band. That single fact is the "never cover window
/// content" rule — the panel is exactly as tall as the band.
///
/// See `docs/design/notch-listening.md` for why the numbers are what they are.
public struct NotchLayout: Equatable, Sendable {
    /// The panel, in screen coordinates.
    public var frame: CGRect
    /// True when the panel wraps a camera housing. False is the virtual notch
    /// hung from the top centre of a display without one.
    public var hugsNotch: Bool
    /// Height of the menu-bar band the panel occupies. Also the local y of the
    /// screen's top edge.
    public var band: CGFloat
    /// The camera housing in local space (zero-width at the centre when there
    /// is none). The body is drawn under it too, where the display has no
    /// pixels — which is what makes the extension read as the notch itself.
    public var housing: CGRect
    /// Body size when fully open.
    public var expanded: CGSize
    /// Body size when folded away: strictly inside the housing on a notched
    /// display (so the last frame before `orderOut` is invisible), a zero-height
    /// sliver at the top edge otherwise.
    public var footprint: CGSize
    /// Bottom corner radius of the open body.
    public var bottomRadius: CGFloat
    /// The concave fillet where the body meets the top edge. Scaled by how
    /// far open the body is, so a folded body has square shoulders that sit
    /// behind the housing.
    public var shoulderRadius: CGFloat
    /// Distance from an outer edge of the body to the centre of that wing's
    /// content. Content rides the edge, so it slides out from behind the
    /// housing as the wing grows.
    public var contentInset: CGFloat
    public var bars: NotchBarMetrics

    public var centerX: CGFloat { housing.midX }
    public var top: CGFloat { band }
}

/// The right wing's meter.
public struct NotchBarMetrics: Equatable, Sendable {
    public var count: Int
    public var width: CGFloat
    public var pitch: CGFloat
    /// Silence is a row of dots: the floor is the bar's own width.
    public var floor: CGFloat
    public var peak: CGFloat

    public var fieldWidth: CGFloat { CGFloat(count - 1) * pitch + width }

    public init(count: Int, width: CGFloat, pitch: CGFloat, floor: CGFloat, peak: CGFloat) {
        self.count = count
        self.width = width
        self.pitch = pitch
        self.floor = floor
        self.peak = peak
    }

    /// Height for a 0…1 fraction of the meter's travel.
    public func height(_ fraction: Double) -> CGFloat {
        floor + (peak - floor) * CGFloat(min(max(fraction, 0), 1))
    }
}

public enum NotchGeometry {
    /// Each wing's width beyond the housing. Modest on purpose: the wings
    /// cover menu-bar items next to the notch for as long as they are out.
    public static let wing: CGFloat = 40
    /// The virtual notch on a display without one: two wings and a seam.
    public static let compactGap: CGFloat = 10
    /// The fallback housing width, kept for the contour tests and for
    /// sizing the demo's capture rect.
    public static let notchWidth: CGFloat = 200
    public static let bottomRadius: CGFloat = 11
    public static let shoulderRadius: CGFloat = 6
    /// Room beyond the open body for the spring's overshoot and the error
    /// shake. The panel never resizes while it is up.
    public static let motionPad: CGFloat = 10

    public static let barCount = 7
    public static let barWidth: CGFloat = 2.4
    public static let barPitch: CGFloat = 4

    /// Prefer a built-in display that actually has a notch. Otherwise the
    /// built-in screen, otherwise the main screen, otherwise the first.
    public static func layout(screens: [NotchScreen], mainIndex: Int?) -> NotchLayout? {
        guard !screens.isEmpty else { return nil }
        if let notched = screens.first(where: { housing(on: $0) != nil }) {
            return layout(on: notched)
        }
        if let builtin = screens.first(where: \.isBuiltin) {
            return layout(on: builtin)
        }
        if let mainIndex, screens.indices.contains(mainIndex) {
            return layout(on: screens[mainIndex])
        }
        return layout(on: screens[0])
    }

    public static func layout(on screen: NotchScreen) -> NotchLayout {
        let menuBand = screen.frame.maxY - screen.visibleFrame.maxY
        if let gap = housing(on: screen) {
            // The menu bar continues a sliver past the housing (1 pt on the
            // 14-inch MacBook Pro). The body takes that sliver too, so the
            // silhouette is the body's own bottom edge everywhere and the
            // housing's corners are inside it, not poking out under it.
            let sliver = max(0, min(2, gap.minY - screen.visibleFrame.maxY))
            let band = gap.height + sliver
            let side = wing + shoulderRadius + motionPad
            let frame = CGRect(x: gap.minX - side,
                               y: screen.frame.maxY - band,
                               width: gap.width + side * 2,
                               height: band)
            let housing = CGRect(x: side, y: band - gap.height, width: gap.width, height: gap.height)
            return NotchLayout(
                frame: frame,
                hugsNotch: true,
                band: band,
                housing: housing,
                expanded: CGSize(width: gap.width + wing * 2, height: band),
                // Four points narrower than the housing, exactly as deep, with
                // a larger corner radius: the folded body is wholly behind the
                // camera, corners included — and never shallower than the
                // housing mid-morph, which would show the housing's own bottom
                // edge as a step under the wings.
                footprint: CGSize(width: max(0, gap.width - 4), height: gap.height),
                bottomRadius: bottomRadius,
                shoulderRadius: shoulderRadius,
                contentInset: wing / 2 + 1.5,
                bars: barMetrics(band: band))
        }
        // No housing: hang a compact virtual notch from the top centre, inside
        // the menu bar. Height is the bar's own, capped so a tall custom bar
        // does not grow a slab.
        let band = menuBand > 8 ? min(menuBand, 28) : 24
        let width = wing * 2 + compactGap
        let side = shoulderRadius + motionPad
        let frame = CGRect(x: screen.frame.midX - width / 2 - side,
                           y: screen.frame.maxY - band,
                           width: width + side * 2,
                           height: band)
        let housing = CGRect(x: frame.width / 2, y: 0, width: 0, height: band)
        return NotchLayout(
            frame: frame,
            hugsNotch: false,
            band: band,
            housing: housing,
            expanded: CGSize(width: width, height: band),
            footprint: CGSize(width: width * 0.45, height: 0),
            bottomRadius: min(bottomRadius, band / 2 - 1),
            shoulderRadius: min(shoulderRadius, band / 4),
            contentInset: (width - compactGap) / 4 + 2,
            bars: barMetrics(band: band))
    }

    static func barMetrics(band: CGFloat) -> NotchBarMetrics {
        NotchBarMetrics(count: barCount,
                        width: barWidth,
                        pitch: barPitch,
                        floor: barWidth,
                        peak: max(barWidth * 2, min(17, band - 12)))
    }

    /// The unoccupied gap between the two auxiliary menu-bar areas. Nil when
    /// this display has no notch.
    static func housing(on screen: NotchScreen) -> CGRect? {
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

    // MARK: - the body

    /// The body's outline: flush with the top edge, concave shoulders where it
    /// meets that edge, straight flanks, smooth bottom corners.
    ///
    /// `width` and `height` are the body proper; the shoulders flare outside
    /// `width` at the top. Radii are clamped so any size from a zero sliver to
    /// a spring overshoot draws a valid, non-self-intersecting path.
    public static func bodyPath(centerX: CGFloat, top: CGFloat,
                                width: CGFloat, height: CGFloat,
                                bottomRadius: CGFloat, shoulder: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let w = max(0, width)
        let h = max(0, height)
        guard w > 0.5, h > 0.5 else { return path }
        let left = centerX - w / 2
        let right = centerX + w / 2
        let bottom = top - h
        let rb = max(0, min(bottomRadius, w / 2, h * 0.9))
        let rs = max(0, min(shoulder, h - rb, w / 4))
        // Corner handles: 0.62 of the radius rather than the circle's 0.552
        // pulls each corner toward a squircle — the curvature eases in rather
        // than starting at full turn, which is what makes an Apple corner read
        // as moulded rather than drawn with a compass.
        let k: CGFloat = 0.62

        path.move(to: CGPoint(x: left - rs, y: top))
        if rs > 0 {
            path.addCurve(to: CGPoint(x: left, y: top - rs),
                          control1: CGPoint(x: left - rs + rs * k, y: top),
                          control2: CGPoint(x: left, y: top - rs + rs * k))
        }
        path.addLine(to: CGPoint(x: left, y: bottom + rb))
        path.addCurve(to: CGPoint(x: left + rb, y: bottom),
                      control1: CGPoint(x: left, y: bottom + rb - rb * k),
                      control2: CGPoint(x: left + rb - rb * k, y: bottom))
        path.addLine(to: CGPoint(x: right - rb, y: bottom))
        path.addCurve(to: CGPoint(x: right, y: bottom + rb),
                      control1: CGPoint(x: right - rb + rb * k, y: bottom),
                      control2: CGPoint(x: right, y: bottom + rb - rb * k))
        path.addLine(to: CGPoint(x: right, y: top - rs))
        if rs > 0 {
            path.addCurve(to: CGPoint(x: right + rs, y: top),
                          control1: CGPoint(x: right, y: top - rs + rs * k),
                          control2: CGPoint(x: right + rs - rs * k, y: top))
        }
        path.closeSubpath()
        return path
    }

    /// The silhouette minus its top edge — the Increase Contrast rim. Open, so
    /// the stroke does not draw a line along the screen's top row.
    public static func rimPath(centerX: CGFloat, top: CGFloat,
                               width: CGFloat, height: CGFloat,
                               bottomRadius: CGFloat, shoulder: CGFloat) -> CGPath {
        let closed = bodyPath(centerX: centerX, top: top, width: width, height: height,
                              bottomRadius: bottomRadius, shoulder: shoulder)
        // Same outline without `closeSubpath`: rebuild by walking the elements.
        let open = CGMutablePath()
        closed.applyWithBlock { element in
            let e = element.pointee
            switch e.type {
            case .moveToPoint: open.move(to: e.points[0])
            case .addLineToPoint: open.addLine(to: e.points[0])
            case .addQuadCurveToPoint: open.addQuadCurve(to: e.points[1], control: e.points[0])
            case .addCurveToPoint: open.addCurve(to: e.points[2], control1: e.points[0], control2: e.points[1])
            case .closeSubpath: break
            @unknown default: break
            }
        }
        return open
    }
}
