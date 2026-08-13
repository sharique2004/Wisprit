// make_icon.swift — render Wisprit's app icon (the ice-white wave-mic mark on a
// black tile, from packaging/Wisprit.icon) to a .iconset directory of PNGs.
// The build script then runs `iconutil` on it.
//
//   swift make_icon.swift <output.iconset dir>
//
// Geometry mirrors packaging/Wisprit.icon/icon.json (the Icon Composer source of
// truth, kept alongside for a future Xcode/actool pipeline): flat black fill,
// glyph at 0.6 of the tile, nudged 57/1024pt down to sit on the optical center.

import AppKit
import Foundation

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("usage: make_icon.swift <iconset dir>\n".utf8))
    exit(2)
}
let outDir = args[1]
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let glyphURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Wisprit.icon/Assets/wisprit-compact-wave-mic-black-2048.png")
guard let glyphSource = NSImage(contentsOf: glyphURL) else {
    FileHandle.standardError.write(Data("make_icon.swift: missing \(glyphURL.path)\n".utf8))
    exit(1)
}

// The mark ships as black-on-alpha; tint it once to icon.json's fill
// (display-P3 0.917 / 0.939 / 1.0 — ice white).
let glyph = NSImage(size: glyphSource.size)
glyph.lockFocus()
let glyphRect = NSRect(origin: .zero, size: glyphSource.size)
glyphSource.draw(in: glyphRect)
NSColor(displayP3Red: 0.91669, green: 0.93871, blue: 1.0, alpha: 1.0).set()
glyphRect.fill(using: .sourceAtop)
glyph.unlockFocus()

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
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    let size = CGFloat(px)

    // Rounded-rect "squircle-ish" tile with the standard margins, flat black.
    let inset = size * 0.08
    let rect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let radius = (size - 2 * inset) * 0.225
    NSColor.black.set()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()

    // Glyph at 0.6 of the tile; icon.json's +57pt is downward on a 1024pt
    // canvas and AppKit's y axis points up, so subtract. At 16–32px the mark's
    // bars dissolve, so those sizes run the glyph larger than the manifest.
    let tile = size - 2 * inset
    let side = tile * (px <= 32 ? 0.78 : 0.6)
    let drawRect = NSRect(
        x: (size - side) / 2,
        y: (size - side) / 2 - tile * (57.0 / 1024.0),
        width: side, height: side)
    glyph.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1.0)

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for (name, px) in variants {
    let rep = render(px)
    guard let data = rep.representation(using: .png, properties: [:]) else { continue }
    try? data.write(to: URL(fileURLWithPath: outDir).appendingPathComponent(name))
}
print("wrote \(variants.count) icon PNGs to \(outDir)")
