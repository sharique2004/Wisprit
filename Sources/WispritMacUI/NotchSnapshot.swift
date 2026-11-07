#if canImport(AppKit)
import AppKit
import ImageIO
import QuartzCore
import UniformTypeIdentifiers

/// The living notch, simulated and drawn offscreen.
///
/// Runs the real `NotchLifecycle` and `NotchChoreography` against a scripted
/// clock and draws the result with the real `NotchLayerTree`, so the design
/// PNGs, the pixel tests and the panel all come from one code path. No window
/// server, no screen-recording permission, deterministic to the pixel.
@MainActor
public enum NotchSnapshot {

    /// One scripted signal.
    public struct Cue: Sendable {
        public var at: TimeInterval
        public var signal: NotchSignal
        public init(_ at: TimeInterval, _ signal: NotchSignal) {
            self.at = at
            self.signal = signal
        }
    }

    public struct State {
        public var frame: NotchFrame
        public var lifecycle: NotchLifecycle
        public var choreography: NotchChoreography
    }

    /// The menu bar a frame is drawn over.
    public enum Backdrop: String, CaseIterable, Sendable {
        case dark
        case light
    }

    /// Play `cues` up to `time` at `fps`, feeding `level(t)` at the session's
    /// 20 Hz while the lifecycle is listening.
    public static func simulate(layout: NotchLayout,
                                cues: [Cue],
                                until time: TimeInterval,
                                level: ((TimeInterval) -> Double)? = nil,
                                reduceMotion: Bool = false,
                                increaseContrast: Bool = false,
                                fps: Double = 120) -> State {
        var lifecycle = NotchLifecycle()
        var choreography = NotchChoreography(layout: layout, reduceMotion: reduceMotion,
                                             increaseContrast: increaseContrast)
        var pending = cues.sorted { $0.at < $1.at }
        var frame = NotchFrame()
        var nextLevel: TimeInterval = 0
        let dt = 1 / fps
        var t: TimeInterval = 0
        while t <= time + 1e-9 {
            while let cue = pending.first, cue.at <= t + 1e-9 {
                lifecycle.receive(cue.signal, at: cue.at)
                pending.removeFirst()
            }
            if t + 1e-9 >= nextLevel {
                nextLevel += 0.05
                if case .listening(micLive: true) = lifecycle.phase, let level {
                    lifecycle.receive(.level(level(t)), at: t)
                }
            }
            lifecycle.advance(to: t)
            frame = choreography.step(to: t, lifecycle: lifecycle)
            if lifecycle.phase == .collapsing, choreography.isFolded {
                lifecycle.collapseSettled(at: t)
            }
            t += dt
        }
        return State(frame: frame, lifecycle: lifecycle, choreography: choreography)
    }

    /// Margins around the panel in a snapshot: room to see the menu bar it
    /// sits in and a strip of window content under the band it never enters.
    public static let marginX: CGFloat = 36
    public static let marginBelow: CGFloat = 26

    /// Draw one frame, over a menu bar, with the camera housing on top the way
    /// the glass would hide those pixels.
    public static func image(layout: NotchLayout, frame: NotchFrame,
                             backdrop: Backdrop?, scale: CGFloat = 2,
                             increaseContrast: Bool = false) -> CGImage? {
        let size = CGSize(width: layout.frame.width + marginX * 2,
                          height: layout.band + marginBelow)
        let width = Int((size.width * scale).rounded())
        let height = Int((size.height * scale).rounded())
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.scaleBy(x: scale, y: scale)

        if let backdrop { drawBackdrop(backdrop, layout: layout, size: size, in: ctx) }

        let tree = NotchLayerTree(layout: layout, scale: scale)
        tree.apply(frame)
        ctx.saveGState()
        ctx.translateBy(x: marginX, y: marginBelow)
        tree.root.render(in: ctx)
        ctx.restoreGState()

        if layout.hugsNotch, backdrop != nil {
            // The housing has no pixels. Whatever the panel drew under it is
            // invisible on the real machine, so it is invisible here too.
            let housing = layout.housing.offsetBy(dx: marginX, dy: marginBelow)
            ctx.addPath(NotchGeometry.bodyPath(centerX: housing.midX, top: housing.maxY,
                                               width: housing.width, height: housing.height,
                                               bottomRadius: 9, shoulder: 3))
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            ctx.fillPath()
        }
        return ctx.makeImage()
    }

    /// Several images stacked top to bottom with a caption each.
    public static func sheet(_ rows: [(caption: String, image: CGImage)], scale: CGFloat = 2,
                             dark: Bool = true) -> CGImage? {
        guard let first = rows.first?.image else { return nil }
        let captionHeight: CGFloat = 22 * scale
        let gap: CGFloat = 10 * scale
        let width = rows.map(\.image.width).max() ?? first.width
        let height = rows.reduce(CGFloat(0)) { $0 + CGFloat($1.image.height) + captionHeight + gap } + gap
        guard let ctx = CGContext(data: nil, width: width, height: Int(height), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.setFillColor(dark ? CGColor(gray: 0.09, alpha: 1) : CGColor(gray: 0.96, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: height))
        var y = height - gap
        let ink = dark ? NSColor(white: 0.85, alpha: 1) : NSColor(white: 0.2, alpha: 1)
        for row in rows {
            y -= captionHeight
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            let font = NSFont.monospacedSystemFont(ofSize: 11 * scale, weight: .medium)
            NSAttributedString(string: row.caption, attributes: [.font: font, .foregroundColor: ink])
                .draw(at: CGPoint(x: 12 * scale, y: y + 5 * scale))
            NSGraphicsContext.restoreGraphicsState()
            y -= CGFloat(row.image.height)
            ctx.draw(row.image, in: CGRect(x: 0, y: y, width: CGFloat(row.image.width),
                                           height: CGFloat(row.image.height)))
            y -= gap
        }
        return ctx.makeImage()
    }

    public static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString,
                                                                1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }

    // MARK: - the backdrop

    /// A generic menu bar: wallpaper, the bar's tint, a menu title ending
    /// short of the housing, a status item just past it (which an open wing
    /// covers, honestly), and the top of a window below the band.
    private static func drawBackdrop(_ backdrop: Backdrop, layout: NotchLayout,
                                     size: CGSize, in ctx: CGContext) {
        let dark = backdrop == .dark
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let wallpaper = dark
            ? [CGColor(srgbRed: 0.06, green: 0.07, blue: 0.16, alpha: 1),
               CGColor(srgbRed: 0.17, green: 0.13, blue: 0.33, alpha: 1)]
            : [CGColor(srgbRed: 0.80, green: 0.87, blue: 0.95, alpha: 1),
               CGColor(srgbRed: 0.97, green: 0.90, blue: 0.82, alpha: 1)]
        if let gradient = CGGradient(colorsSpace: space, colors: wallpaper as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height),
                                   options: [])
        }
        let bandBottom = marginBelow
        ctx.setFillColor(dark ? CGColor(gray: 0, alpha: 0.22) : CGColor(gray: 1, alpha: 0.3))
        ctx.fill(CGRect(x: 0, y: bandBottom, width: size.width, height: layout.band))

        // The top of a window, under the band.
        let window = CGRect(x: 14, y: -12, width: size.width - 28, height: marginBelow - 2 + 12)
        ctx.addPath(CGPath(roundedRect: window, cornerWidth: 10, cornerHeight: 10, transform: nil))
        ctx.setFillColor(dark ? CGColor(gray: 0.16, alpha: 1) : CGColor(gray: 0.99, alpha: 1))
        ctx.fillPath()
        ctx.addPath(CGPath(roundedRect: window, cornerWidth: 10, cornerHeight: 10, transform: nil))
        ctx.setStrokeColor(dark ? CGColor(gray: 1, alpha: 0.12) : CGColor(gray: 0, alpha: 0.12))
        ctx.setLineWidth(0.5)
        ctx.strokePath()

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let ink = dark ? NSColor(white: 1, alpha: 0.9) : NSColor(white: 0, alpha: 0.85)
        let font = NSFont.systemFont(ofSize: 13, weight: .regular)
        let midY = bandBottom + layout.band / 2
        let housingLeft = marginX + (layout.hugsNotch ? layout.housing.minX : layout.centerX - layout.expanded.width / 2)
        let housingRight = marginX + (layout.hugsNotch ? layout.housing.maxX : layout.centerX + layout.expanded.width / 2)
        let menu = NSAttributedString(string: "Window   Help", attributes: [.font: font, .foregroundColor: ink])
        let menuSize = menu.size()
        menu.draw(at: CGPoint(x: housingLeft - 34 - menuSize.width, y: midY - menuSize.height / 2))
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [ink]))
        var x = housingRight + 24
        for name in ["circle.lefthalf.filled", "wifi", "battery.75percent"] {
            guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(config) else { continue }
            let s = symbol.size
            symbol.draw(in: CGRect(x: x, y: midY - s.height / 2, width: s.width, height: s.height))
            x += s.width + 16
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}
#endif
