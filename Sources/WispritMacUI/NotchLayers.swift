#if canImport(AppKit)
import AppKit
import QuartzCore

/// The notch as a handful of Core Animation layers, and nothing else.
///
/// Deliberately limited to what `CALayer.render(in:)` can draw — shape layers,
/// plain layers, gradients, images; no masks, no filters, no 3D transforms —
/// so the offscreen renderer that produces the design PNGs and the pixel tests
/// draws exactly what the panel shows.
@MainActor
final class NotchLayerTree {
    let root = CALayer()
    private let body = CAShapeLayer()
    private let rim = CAShapeLayer()
    private let washLeft = CAGradientLayer()
    private let washRight = CAGradientLayer()
    private let halo = CAGradientLayer()
    private let ring = CAShapeLayer()
    private let meterGlow = CAGradientLayer()
    private let dot = CALayer()
    private let glyphLayers = [CALayer(), CALayer()]
    private let check = CAShapeLayer()
    private var barLayers: [CALayer] = []

    private(set) var layout: NotchLayout
    private let scale: CGFloat
    private var appliedHalo: PillColor?
    private var appliedWash: PillColor?
    private var appliedImages: [CGImage?] = [nil, nil]

    init(layout: NotchLayout, scale: CGFloat) {
        self.layout = layout
        self.scale = scale
        root.bounds = CGRect(origin: .zero, size: layout.frame.size)
        root.anchorPoint = .zero
        root.position = .zero
        root.masksToBounds = false

        body.fillColor = CGColor(gray: 0, alpha: 1)
        body.strokeColor = nil
        rim.fillColor = nil
        rim.strokeColor = CGColor(gray: 1, alpha: 1)
        rim.lineWidth = 1
        rim.opacity = 0

        for wash in [washLeft, washRight] {
            wash.type = .radial
            wash.startPoint = CGPoint(x: 0.5, y: 0.5)
            wash.endPoint = CGPoint(x: 1, y: 1)
            wash.locations = [0, 0.55, 1]
            wash.opacity = 0
        }
        halo.type = .radial
        halo.startPoint = CGPoint(x: 0.5, y: 0.5)
        halo.endPoint = CGPoint(x: 1, y: 1)
        halo.locations = [0, 0.45, 1]
        halo.opacity = 0
        ring.fillColor = nil
        ring.lineWidth = 1.25
        ring.strokeColor = cgColor(NotchPalette.hot, 1)
        ring.opacity = 0
        meterGlow.type = .radial
        meterGlow.startPoint = CGPoint(x: 0.5, y: 0.5)
        meterGlow.endPoint = CGPoint(x: 1, y: 1)
        meterGlow.locations = [0, 0.5, 1]
        meterGlow.colors = [cgColor(NotchPalette.hot, 0.55), cgColor(NotchPalette.hot, 0.16),
                            cgColor(NotchPalette.hot, 0)]
        meterGlow.opacity = 0

        dot.opacity = 0
        for glyph in glyphLayers {
            glyph.contentsGravity = .resizeAspect
            glyph.opacity = 0
        }
        check.fillColor = nil
        check.lineWidth = 2.1
        check.lineCap = .round
        check.lineJoin = .round
        check.strokeColor = cgColor(NotchPalette.positive, 1)
        check.strokeEnd = 0
        check.opacity = 0

        for _ in 0..<layout.bars.count {
            let bar = CALayer()
            bar.cornerRadius = layout.bars.width / 2
            bar.opacity = 0
            barLayers.append(bar)
        }

        let all: [CALayer] = [body, rim, washLeft, washRight, meterGlow, halo, ring, dot]
            + glyphLayers + [check] + barLayers
        for layer in all {
            layer.contentsScale = scale
            layer.actions = NotchLayerTree.noActions
            root.addSublayer(layer)
        }
        root.contentsScale = scale
        root.actions = NotchLayerTree.noActions
    }

    /// Belt and braces with `setDisableActions`: these layers never animate
    /// implicitly. Every frame is a decision, not a tween.
    private static let noActions: [String: CAAction] = [
        "position": NSNull(), "bounds": NSNull(), "path": NSNull(), "opacity": NSNull(),
        "backgroundColor": NSNull(), "contents": NSNull(), "strokeEnd": NSNull(),
        "colors": NSNull(), "transform": NSNull(), "hidden": NSNull(),
    ]

    func apply(_ frame: NotchFrame) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let L = layout
        let cx = L.centerX + frame.offsetX
        body.path = NotchGeometry.bodyPath(centerX: cx, top: L.top,
                                           width: frame.bodyWidth, height: frame.bodyHeight,
                                           bottomRadius: L.bottomRadius, shoulder: frame.shoulder)
        body.opacity = Float(frame.bodyAlpha)
        if frame.rimAlpha > 0.001 {
            rim.path = NotchGeometry.rimPath(centerX: cx, top: L.top,
                                             width: frame.bodyWidth, height: frame.bodyHeight,
                                             bottomRadius: L.bottomRadius, shoulder: frame.shoulder)
        }
        rim.opacity = Float(frame.rimAlpha)

        // Alarm wash: kept inside each wing so it never glows past the body.
        if frame.washAlpha > 0.001 {
            if appliedWash != frame.washColor {
                let c = frame.washColor
                let colors = [cgColor(c, 1), cgColor(c, 0.35), cgColor(c, 0)]
                washLeft.colors = colors
                washRight.colors = colors
                appliedWash = c
            }
            let size = CGSize(width: max(0, (L.contentInset - 2) * 2), height: L.band - 4)
            washLeft.bounds = CGRect(origin: .zero, size: size)
            washRight.bounds = CGRect(origin: .zero, size: size)
            washLeft.position = frame.leftCenter
            washRight.position = frame.rightCenter
        }
        washLeft.opacity = Float(frame.washAlpha)
        washRight.opacity = Float(frame.washAlpha)

        // Tally dot + halo.
        if appliedHalo != frame.dotColor {
            let c = frame.dotColor
            halo.colors = [cgColor(c, 0.9), cgColor(c, 0.32), cgColor(c, 0)]
            appliedHalo = c
        }
        halo.bounds = CGRect(x: 0, y: 0, width: frame.haloDiameter, height: frame.haloDiameter)
        halo.position = frame.leftCenter
        halo.opacity = Float(frame.haloAlpha)
        if frame.ringAlpha > 0.001 {
            let d = frame.ringDiameter
            ring.path = CGPath(ellipseIn: CGRect(x: frame.leftCenter.x - d / 2, y: frame.leftCenter.y - d / 2,
                                                 width: d, height: d), transform: nil)
        }
        ring.opacity = Float(frame.ringAlpha)
        if frame.meterGlowAlpha > 0.001 {
            let glowSize = CGSize(width: L.bars.fieldWidth + 18, height: L.band - 2)
            meterGlow.bounds = CGRect(origin: .zero, size: glowSize)
            meterGlow.position = frame.rightCenter
        }
        meterGlow.opacity = Float(frame.meterGlowAlpha)
        dot.bounds = CGRect(x: 0, y: 0, width: frame.dotDiameter, height: frame.dotDiameter)
        dot.cornerRadius = frame.dotDiameter / 2
        dot.position = frame.leftCenter
        dot.backgroundColor = cgColor(frame.dotColor, 1)
        dot.opacity = Float(frame.dotAlpha)

        // Symbols.
        for (index, layer) in glyphLayers.enumerated() {
            guard index < frame.glyphs.count else {
                layer.opacity = 0
                continue
            }
            let glyph = frame.glyphs[index]
            guard let image = NotchGlyphImages.image(glyph.kind, color: glyph.color, scale: scale) else {
                layer.opacity = 0
                continue
            }
            if appliedImages[index] !== image.cgImage {
                layer.contents = image.cgImage
                appliedImages[index] = image.cgImage
            }
            let s = CGFloat(max(0, glyph.scale))
            layer.bounds = CGRect(x: 0, y: 0, width: image.size.width * s, height: image.size.height * s)
            layer.position = frame.leftCenter
            layer.opacity = Float(glyph.alpha)
        }

        // The drawn check.
        if frame.checkAlpha > 0.001 {
            let c = frame.leftCenter
            let path = CGMutablePath()
            path.move(to: CGPoint(x: c.x - 4.6, y: c.y + 0.2))
            path.addLine(to: CGPoint(x: c.x - 1.5, y: c.y - 3.0))
            path.addLine(to: CGPoint(x: c.x + 4.8, y: c.y + 3.6))
            check.path = path
            check.strokeEnd = CGFloat(min(1, max(0, frame.checkProgress)))
        }
        check.opacity = Float(frame.checkAlpha)

        // The meter.
        let m = L.bars
        let originX = frame.rightCenter.x - m.fieldWidth / 2
        for (index, layer) in barLayers.enumerated() {
            guard index < frame.bars.count else { layer.opacity = 0; continue }
            let bar = frame.bars[index]
            let x = originX + CGFloat(index) * m.pitch
            layer.frame = CGRect(x: x, y: frame.rightCenter.y - bar.height / 2,
                                 width: m.width, height: bar.height)
            layer.backgroundColor = cgColor(bar.color, 1)
            layer.opacity = Float(bar.alpha)
        }
    }

    private func cgColor(_ c: PillColor, _ alpha: Double) -> CGColor {
        CGColor(srgbRed: CGFloat(c.r), green: CGFloat(c.g), blue: CGFloat(c.b), alpha: CGFloat(alpha))
    }
}

/// SF Symbols, rasterised once per (glyph, colour, scale).
@MainActor
enum NotchGlyphImages {
    struct Rendered {
        let cgImage: CGImage
        /// In points.
        let size: CGSize
    }

    private struct Key: Hashable {
        let glyph: NotchGlyph
        let r: Double, g: Double, b: Double
        let scale: CGFloat
    }

    private static var cache: [Key: Rendered] = [:]
    static let pointSize: CGFloat = 11

    static func image(_ glyph: NotchGlyph, color: PillColor, scale: CGFloat) -> Rendered? {
        let key = Key(glyph: glyph, r: color.r, g: color.g, b: color.b, scale: scale)
        if let hit = cache[key] { return hit }
        let tint = NSColor(srgbRed: color.r, green: color.g, blue: color.b, alpha: 1)
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight(glyph))
            .applying(NSImage.SymbolConfiguration(paletteColors: [tint]))
        guard let symbol = NSImage(systemSymbolName: glyph.symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return nil }
        let size = symbol.size
        let width = Int((size.width * scale).rounded(.up))
        let height = Int((size.height * scale).rounded(.up))
        guard width > 0, height > 0,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        symbol.draw(in: CGRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        guard let image = ctx.makeImage() else { return nil }
        let rendered = Rendered(cgImage: image,
                                size: CGSize(width: CGFloat(width) / scale, height: CGFloat(height) / scale))
        cache[key] = rendered
        return rendered
    }

    private static func weight(_ glyph: NotchGlyph) -> NSFont.Weight {
        switch glyph {
        case .sparkle: return .semibold
        case .question, .exclamation: return .heavy
        case .faint, .lock: return .semibold
        }
    }
}
#endif
