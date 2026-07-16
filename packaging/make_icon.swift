// make_icon.swift — render Wisprit's app icon (a white mic on a teal gradient)
// to a .iconset directory of PNGs. The build script then runs `iconutil` on it.
//
//   swift make_icon.swift <output.iconset dir>

import AppKit
import Foundation

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("usage: make_icon.swift <iconset dir>\n".utf8))
    exit(2)
}
let outDir = args[1]
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

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
    let size = CGFloat(px)

    // Rounded-rect "squircle-ish" background with a teal→blue gradient.
    let inset = size * 0.08
    let rect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let radius = (size - 2 * inset) * 0.225
    let bg = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.20, green: 0.74, blue: 0.84, alpha: 1.0),   // #33bbd6-ish
        NSColor(calibratedRed: 0.11, green: 0.42, blue: 0.72, alpha: 1.0),
    ])!
    gradient.draw(in: bg, angle: -90)

    // White microphone glyph, centered, ~52% of the icon.
    let config = NSImage.SymbolConfiguration(pointSize: size * 0.52, weight: .semibold)
    if let mic = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let tinted = NSImage(size: mic.size)
        tinted.lockFocus()
        NSColor.white.set()
        let r = NSRect(origin: .zero, size: mic.size)
        mic.draw(in: r)
        r.fill(using: .sourceAtop)
        tinted.unlockFocus()
        let mw = mic.size.width, mh = mic.size.height
        let drawRect = NSRect(x: (size - mw) / 2, y: (size - mh) / 2, width: mw, height: mh)
        tinted.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1.0)
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
