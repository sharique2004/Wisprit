import Foundation
import CoreGraphics
#if canImport(AppKit)
import AppKit
#endif

/// The Wisprit mark: a tally dot and three voice bars.
///
/// It is the same picture the notch draws while you talk (the live dot on the
/// left, the bars on the right) and the one on the app icon, so the three
/// surfaces read as one product. Here it is drawn as the menu-bar glyph, in
/// code, on a whole-point grid:
///
///     ●  ▮ ▮ ▮      dot 6 pt · gap 4 · bars 2 pt on a 4 pt pitch
///                   bar heights 8 / 14 / 10, all centred on the 16 pt canvas
///
/// Every edge that is not a round cap lands on a whole point, and the canvas
/// height is even, so the status bar centres it on a whole point too. That is
/// what keeps it crisp at 1x as well as 2x, with no asset pipeline.
///
/// Each `MenuGlyph` is this mark with one part changed: the dot lights up,
/// becomes a `!` or a lock, the bars fall to the floor, or a slash strikes it
/// out. The geometry is pure so the tests can pin it; the AppKit half below
/// only turns primitives into paths.
public enum WispritMark {

    // MARK: metrics (points)

    /// 20 × 16: the width of the system's wide glyphs (battery, Wi-Fi), the
    /// height of its circular ones, inside the 22 pt menu-bar working area.
    public static let canvas = CGSize(width: 20, height: 16)
    public static let dotDiameter: CGFloat = 6
    /// Wider than the bar gap on purpose: the dot is the tally, the bars are
    /// the voice, and the notch keeps them apart the same way.
    public static let dotToBars: CGFloat = 4
    /// A filled 2 pt bar carries the optical weight of a 1.5 pt SF Symbols
    /// regular stroke.
    public static let barWidth: CGFloat = 2
    public static let barPitch: CGFloat = 4
    /// Speech-shaped, not symmetric: it rises, peaks, and falls short.
    public static let barHeights: [CGFloat] = [8, 14, 10]
    /// A bar at silence is a dot, exactly as in the pill and the notch.
    public static let floorHeight: CGFloat = 2

    static var midY: CGFloat { canvas.height / 2 }

    /// The dot at rest.
    public static var dotRect: CGRect {
        CGRect(x: 0, y: midY - dotDiameter / 2, width: dotDiameter, height: dotDiameter)
    }

    /// The bars at their resting heights.
    public static var barRects: [CGRect] { bars(heights: barHeights) }

    static func bars(heights: [CGFloat]) -> [CGRect] {
        heights.enumerated().map { index, height in
            CGRect(x: dotDiameter + dotToBars + CGFloat(index) * barPitch,
                   y: midY - height / 2, width: barWidth, height: height)
        }
    }

    // MARK: primitives

    /// One shape, painted in order. `erase` punches through everything drawn
    /// before it, which is how the `!`, the lock's shackle and the slash's
    /// gap are cut without a second image.
    public struct Primitive: Equatable, Sendable {
        public enum Shape: Equatable, Sendable {
            /// Fully rounded: radius is half the short side.
            case capsule
            case disc
            case roundedRect(radius: CGFloat)
            /// A round-capped stroke between two points.
            case line(from: CGPoint, to: CGPoint, width: CGFloat)
        }

        public enum Paint: Equatable, Sendable {
            /// The menu bar's foreground; the template colour.
            case ink
            /// The live dot. Only `.listening` ever uses it.
            case tally
            case erase
        }

        public var shape: Shape
        /// The shape's frame. For a line, its bounds including the caps.
        public var rect: CGRect
        public var paint: Paint

        public init(_ shape: Shape, _ rect: CGRect, _ paint: Paint = .ink) {
            self.shape = shape
            self.rect = rect
            self.paint = paint
        }

        static func line(from a: CGPoint, to b: CGPoint, width: CGFloat,
                         _ paint: Paint) -> Primitive {
            let half = width / 2
            let bounds = CGRect(x: min(a.x, b.x) - half, y: min(a.y, b.y) - half,
                                width: abs(a.x - b.x) + width, height: abs(a.y - b.y) + width)
            return Primitive(.line(from: a, to: b, width: width), bounds, paint)
        }
    }

    /// What the glyph is made of, in paint order.
    public static func primitives(for glyph: MenuGlyph) -> [Primitive] {
        let restingBars = barRects.map { Primitive(.capsule, $0) }
        switch glyph {
        case .ready:
            return [Primitive(.disc, dotRect)] + restingBars
        case .listening:
            return [Primitive(.disc, dotRect, .tally)] + restingBars
        case .working:
            let floor = bars(heights: barHeights.map { _ in floorHeight })
            return [Primitive(.disc, dotRect)] + floor.map { Primitive(.capsule, $0) }
        case .disabled:
            return [Primitive(.disc, dotRect)] + restingBars + slash
        case .needsSetup:
            return alertBadge + restingBars
        case .secureInput:
            return padlock + restingBars
        }
    }

    /// A 45° stroke through the voice, with a 1 pt gap cut on both sides so it
    /// reads at menu-bar size (the SF `.slash` cut). It strikes the bars and
    /// leaves the dot whole: a slash that nicks the dot's rim only reads as
    /// damage, not as "off".
    static var slash: [Primitive] {
        let from = CGPoint(x: 7.5, y: canvas.height - 1.5)
        let to = CGPoint(x: canvas.width - 1, y: 3)
        return [Primitive.line(from: from, to: to, width: barWidth + 2, .erase),
                Primitive.line(from: from, to: to, width: barWidth, .ink)]
    }

    /// The dot grown to 8 pt with a `!` cut out of it. Same left edge and the
    /// same centre line as the dot, so the bars never move.
    static var alertBadge: [Primitive] {
        let d: CGFloat = 8
        let badge = CGRect(x: 0, y: midY - d / 2, width: d, height: d)
        let stem = CGRect(x: badge.midX - 0.75, y: midY - 0.25, width: 1.5, height: 3)
        let point = CGRect(x: badge.midX - 0.75, y: midY - 2.75, width: 1.5, height: 1.5)
        return [Primitive(.disc, badge),
                Primitive(.capsule, stem, .erase),
                Primitive(.disc, point, .erase)]
    }

    /// A padlock in the dot's slot: shackle (an outer rounded rect with the
    /// inside erased), then the body over its feet.
    static var padlock: [Primitive] {
        let body = CGRect(x: 0, y: 3, width: dotDiameter, height: 5.5)
        let shackleOuter = CGRect(x: 0.75, y: 6, width: 4.5, height: 6.5)
        let shackleInner = CGRect(x: 2, y: 6, width: 2, height: 5.25)
        return [Primitive(.roundedRect(radius: 2.25), shackleOuter),
                Primitive(.roundedRect(radius: 1), shackleInner, .erase),
                Primitive(.roundedRect(radius: 1.25), body)]
    }
}

#if canImport(AppKit)
extension WispritMark {

    /// The menu-bar image for `glyph`.
    ///
    /// Template for every state but `.listening` (the spec says which), so
    /// macOS tints it for whatever the menu bar sits on. The listening image
    /// carries its own colours: `ink` for the bars, resolved per appearance
    /// at draw time, and `tally` for the dot.
    public static func image(for spec: MenuIconSpec,
                             ink: NSColor = .black,
                             tally: NSColor = .systemOrange) -> NSImage {
        let parts = primitives(for: spec.glyph)
        let image = NSImage(size: canvas, flipped: false) { _ in
            draw(parts, ink: ink, tally: tally)
            return true
        }
        image.isTemplate = spec.isTemplate
        image.accessibilityDescription = spec.glyph.accessibilityLabel
        return image
    }

    /// Paints primitives into the current context, y-up, in points.
    public static func draw(_ parts: [Primitive], ink: NSColor, tally: NSColor) {
        guard let context = NSGraphicsContext.current else { return }
        for part in parts {
            context.saveGraphicsState()
            switch part.paint {
            case .ink: ink.set()
            case .tally: tally.set()
            case .erase:
                context.compositingOperation = .destinationOut
                NSColor.black.set()
            }
            path(for: part).fill()
            context.restoreGraphicsState()
        }
    }

    static func path(for part: Primitive) -> NSBezierPath {
        let r = part.rect
        switch part.shape {
        case .capsule:
            let radius = min(r.width, r.height) / 2
            return NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
        case .disc:
            return NSBezierPath(ovalIn: r)
        case .roundedRect(let radius):
            return NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
        case .line(let from, let to, let width):
            // A stroked line as a fillable outline, so erase and ink go
            // through the same fill path.
            let dx = to.x - from.x, dy = to.y - from.y
            let length = max(hypot(dx, dy), 0.001)
            let capsule = NSBezierPath(
                roundedRect: NSRect(x: -width / 2, y: -width / 2,
                                    width: length + width, height: width),
                xRadius: width / 2, yRadius: width / 2)
            var transform = AffineTransform(translationByX: from.x, byY: from.y)
            transform.rotate(byRadians: atan2(dy, dx))
            capsule.transform(using: transform)
            return capsule
        }
    }
}
#endif
