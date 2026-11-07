// make_icon.swift — render Wisprit's app icon (the tally mark: a dot and three
// voice bars, studio-black on an ice tile) to a .iconset directory of PNGs.
// The build script then runs `iconutil` on it.
//
//   swift make_icon.swift <output.iconset dir>
//
// This is the no-Xcode FALLBACK. The source of truth is packaging/Wisprit.icon
// (Icon Composer: flat SVG layers that macOS 26 renders as Liquid Glass), which
// build_app.sh compiles with actool whenever Xcode is present. This file draws
// the same geometry in Core Graphics and fakes the glass with gradients, a rim
// and soft shadows, so a machine without actool still ships a premium icon
// rather than a flat one.
//
// Geometry mirrors Wisprit.icon/Assets/{dot,bars}.svg on the 1024 Icon
// Composer canvas, which is itself WispritMark (the menu-bar glyph) scaled
// by 35: dot 6, gap 4, bars 2 wide on a 4 pitch, heights 8 / 14 / 10, the
// whole mark nudged 0.6 units left of centre to sit on the optical centre.

import AppKit
import Foundation

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("usage: make_icon.swift <iconset dir>\n".utf8))
    exit(2)
}
let outDir = args[1]
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

// MARK: - geometry (Icon Composer canvas, 1024 pt, y down — as the SVGs)

let unit: CGFloat = 35
let markWidth: CGFloat = 20 * unit
let markLeft: CGFloat = 512 - markWidth / 2 - 0.6 * unit
let dot = CGRect(x: markLeft, y: 512 - 3 * unit, width: 6 * unit, height: 6 * unit)
let bars: [CGRect] = [8, 14, 10].enumerated().map { i, h in
    CGRect(x: markLeft + (10 + 4 * CGFloat(i)) * unit, y: 512 - h * unit / 2,
           width: 2 * unit, height: h * unit)
}

// MARK: - colours (sRGB, Theme.swift's studio family)

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
let tileTop = rgb(0xFFFFFF), tileBottom = rgb(0xD8DDE4)
let markTop = rgb(0x2E333B), markBottom = rgb(0x0E1013)

// MARK: - the macOS squircle

/// Apple's continuous-corner tile, approximated by a superellipse (n = 5),
/// which is within a pixel of the system mask at every iconset size.
func squircle(in r: CGRect) -> CGPath {
    let path = CGMutablePath()
    let n: CGFloat = 5, steps = 360
    let a = r.width / 2, b = r.height / 2
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = r.midX + a * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n)
        let y = r.midY + b * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n)
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

func capsule(_ r: CGRect) -> CGPath {
    let radius = min(r.width, r.height) / 2
    return CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

// MARK: - render

// (filename, pixel size) per Apple's iconset convention.
let variants: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

func render(_ px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let ns = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ns
    let cg = ns.cgContext
    let size = CGFloat(px)

    // The macOS icon grid: an 824/1024 tile centred in the frame, leaving
    // room for the system-style drop shadow.
    let inset = size * 100 / 1024
    let tile = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let tilePath = squircle(in: tile)
    let k = tile.width / 1024  // Icon Composer canvas → this tile

    // Canvas (y down) → this bitmap (y up), inside the tile. Below 64 px the
    // bars would fall under two pixels, so the mark runs a little larger.
    let boost: CGFloat = px <= 32 ? 1.12 : 1.0
    func place(_ r: CGRect) -> CGRect {
        let cx = (r.midX - 512) * boost, cy = (r.midY - 512) * boost
        let w = r.width * boost * k, h = r.height * boost * k
        return CGRect(x: tile.midX + cx * k - w / 2, y: tile.midY - cy * k - h / 2,
                      width: w, height: h)
    }

    // 1. Tile shadow, as the Dock draws under system icons.
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -size * 0.012), blur: size * 0.03,
                 color: rgb(0x000000, 0.30))
    cg.addPath(tilePath)
    cg.setFillColor(tileBottom)
    cg.fillPath()
    cg.restoreGState()

    // 2. Ice tile: white at the top falling to a cool grey.
    cg.saveGState()
    cg.addPath(tilePath)
    cg.clip()
    let tileGradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                  colors: [tileTop, tileBottom] as CFArray, locations: [0, 1])!
    cg.drawLinearGradient(tileGradient, start: CGPoint(x: 0, y: tile.maxY),
                          end: CGPoint(x: 0, y: tile.minY), options: [])

    // 3. The mark: studio-black glass. A soft contact shadow, a top-lit body
    //    gradient, and a hairline rim catching the light along the top.
    let parts: [CGPath] = [CGPath(ellipseIn: place(dot), transform: nil)] + bars.map { capsule(place($0)) }
    for part in parts {
        cg.saveGState()
        cg.setShadow(offset: CGSize(width: 0, height: -size * 0.010), blur: size * 0.025,
                     color: rgb(0x0E1013, 0.35))
        cg.addPath(part)
        cg.setFillColor(markBottom)
        cg.fillPath()
        cg.restoreGState()

        let box = part.boundingBox
        cg.saveGState()
        cg.addPath(part)
        cg.clip()
        let body = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: [markTop, markBottom] as CFArray, locations: [0, 1])!
        cg.drawLinearGradient(body, start: CGPoint(x: 0, y: box.maxY),
                              end: CGPoint(x: 0, y: box.minY), options: [])
        cg.restoreGState()

        if px >= 64 {
            cg.saveGState()
            cg.addPath(part)
            cg.clip()
            cg.addPath(part)
            cg.setStrokeColor(rgb(0xFFFFFF, 0.22))
            cg.setLineWidth(max(1, size * 0.004))
            cg.strokePath()
            cg.restoreGState()
        }
    }
    cg.restoreGState()

    // 4. Tile rim: a bright hairline inside the edge, the glass catching light.
    if px >= 64 {
        cg.saveGState()
        cg.addPath(tilePath)
        cg.clip()
        cg.addPath(tilePath)
        cg.setStrokeColor(rgb(0xFFFFFF, 0.9))
        cg.setLineWidth(size * 0.006)
        cg.strokePath()
        cg.restoreGState()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for (name, px) in variants {
    let rep = render(px)
    guard let data = rep.representation(using: .png, properties: [:]) else { continue }
    try? data.write(to: URL(fileURLWithPath: outDir).appendingPathComponent(name))
}
print("wrote \(variants.count) icon PNGs to \(outDir)")
