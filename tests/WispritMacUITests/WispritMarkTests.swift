import XCTest
@testable import WispritMacUI
#if canImport(AppKit)
import AppKit
#endif

/// The menu-bar mark's geometry, pinned: whole-point edges (crisp at 1x and
/// 2x), a canvas the menu bar can centre on a whole point, and six states
/// that are visibly the same mark.
final class WispritMarkTests: XCTestCase {

    private func isWhole(_ v: CGFloat) -> Bool { v == v.rounded() }

    func testCanvasFitsTheMenuBarAndCentresOnAWholePoint() {
        let c = WispritMark.canvas
        XCTAssertLessThanOrEqual(c.height, 22, "the menu-bar working area is 22 pt")
        XCTAssertGreaterThanOrEqual(c.height, 16, "as tall as the system's own glyphs")
        XCTAssertTrue(isWhole(c.width) && isWhole(c.height))
        XCTAssertEqual(Int(c.height) % 2, 0,
                       "an even height centres on a whole point in a 22 or 24 pt bar")
    }

    /// Every straight edge on a whole point: the bars' sides and the dot's
    /// box. Only round caps are left to anti-aliasing, at either scale.
    func testRestingMarkSitsOnTheWholePointGrid() {
        let rects = [WispritMark.dotRect] + WispritMark.barRects
        for r in rects {
            XCTAssertTrue(isWhole(r.minX) && isWhole(r.maxX) && isWhole(r.minY) && isWhole(r.maxY),
                          "\(r)")
        }
        XCTAssertEqual(WispritMark.barRects.map(\.height), WispritMark.barHeights)
        XCTAssertEqual(WispritMark.barRects.map(\.width), [2, 2, 2])
        XCTAssertEqual(WispritMark.barRects.last?.maxX, WispritMark.canvas.width,
                       "no dead padding on the right")
        XCTAssertEqual(WispritMark.dotRect.minX, 0, "no dead padding on the left")
        XCTAssertEqual(WispritMark.barHeights.max(), WispritMark.canvas.height - 2,
                       "1 pt of air above and below the tallest bar, and no more")
    }

    /// The whole family is one picture: every glyph keeps the bars in the
    /// same columns, and every part stays on the canvas.
    func testEveryGlyphIsTheSameMarkWithOnePartChanged() {
        let columns = WispritMark.barRects.map(\.minX)
        let bounds = CGRect(origin: .zero, size: WispritMark.canvas)
        for glyph in MenuGlyph.allCases {
            let parts = WispritMark.primitives(for: glyph)
            // An erase outside the canvas cuts nothing, so only paint counts.
            for part in parts where part.paint != .erase {
                XCTAssertTrue(bounds.contains(part.rect), "\(glyph): \(part.rect) off canvas")
            }
            let barColumns = parts
                .filter { $0.shape == .capsule && $0.paint == .ink && $0.rect.width == 2 }
                .map(\.rect.minX)
            XCTAssertEqual(barColumns, columns, "\(glyph) moved its bars")
        }
    }

    /// The orange rule (§1.6), at the geometry level: only `.listening` paints
    /// with the tally colour, and it paints exactly the resting dot.
    func testOnlyListeningLightsTheTally() {
        for glyph in MenuGlyph.allCases {
            let lit = WispritMark.primitives(for: glyph).filter { $0.paint == .tally }
            if glyph == .listening {
                XCTAssertEqual(lit.map(\.rect), [WispritMark.dotRect])
            } else {
                XCTAssertTrue(lit.isEmpty, "\(glyph) lit the tally")
            }
        }
        XCTAssertEqual(
            WispritMark.primitives(for: .listening).map { $0.paint == .tally ? .ink : $0.paint },
            WispritMark.primitives(for: .ready).map(\.paint),
            "listening is the resting mark with the dot lit, nothing else")
    }

    func testWorkingDropsTheBarsToTheFloor() {
        let bars = WispritMark.primitives(for: .working).filter { $0.shape == .capsule }
        XCTAssertEqual(bars.map(\.rect.height), [2, 2, 2])
        for bar in bars { XCTAssertEqual(bar.rect.midY, WispritMark.canvas.height / 2) }
    }

    func testDisabledStrikesTheBarsAndSparesTheDot() {
        let parts = WispritMark.primitives(for: .disabled)
        let erase = parts.filter { $0.paint == .erase }
        XCTAssertEqual(erase.count, 1)
        guard let cut = erase.first, case let .line(a, b, width) = cut.shape else {
            return XCTFail("the slash is a cut line")
        }
        // Distance from the dot's centre to the cut's centre line, minus the
        // cut's half-width, must clear the dot's radius.
        let c = CGPoint(x: WispritMark.dotRect.midX, y: WispritMark.dotRect.midY)
        let dx = b.x - a.x, dy = b.y - a.y
        let t = max(0, min(1, ((c.x - a.x) * dx + (c.y - a.y) * dy) / (dx * dx + dy * dy)))
        let gap = hypot(c.x - (a.x + t * dx), c.y - (a.y + t * dy)) - width / 2
        XCTAssertGreaterThan(gap, WispritMark.dotDiameter / 2,
                             "the slash's gap must not nick the dot")
    }

    #if canImport(AppKit)
    /// Rasterise at a backing scale and return RGBA bytes, row 0 at the top.
    private func raster(_ glyph: MenuGlyph, scale: Int,
                        ink: NSColor = .black, tally: NSColor = .orange) -> (w: Int, h: Int, px: [UInt8]) {
        let image = WispritMark.image(for: MenuIconSpec(glyph: glyph), ink: ink, tally: tally)
        let w = Int(WispritMark.canvas.width) * scale, h = Int(WispritMark.canvas.height) * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: w * 4, bitsPerPixel: 32)!
        rep.size = WispritMark.canvas
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: WispritMark.canvas))
        NSGraphicsContext.restoreGraphicsState()
        let bytes = Array(UnsafeBufferPointer(start: rep.bitmapData!, count: w * h * 4))
        return (w, h, bytes)
    }

    func testImagesAreTemplatesExceptListening() {
        for glyph in MenuGlyph.allCases {
            let image = WispritMark.image(for: MenuIconSpec(glyph: glyph))
            XCTAssertEqual(image.isTemplate, glyph != .listening, "\(glyph)")
            XCTAssertEqual(image.size, WispritMark.canvas)
            XCTAssertEqual(image.accessibilityDescription, glyph.accessibilityLabel)
        }
    }

    /// At 1x the first bar's two columns are solid through its middle and the
    /// columns either side are empty: the edges land on pixels, not between.
    func testBarsAreCrispAtOneX() {
        let r = raster(.ready, scale: 1)
        func alpha(_ x: Int, _ yFromTop: Int) -> UInt8 { r.px[(yFromTop * r.w + x) * 4 + 3] }
        let bar = WispritMark.barRects[1]
        let x0 = Int(bar.minX), mid = r.h / 2
        XCTAssertEqual(alpha(x0, mid), 255)
        XCTAssertEqual(alpha(x0 + 1, mid), 255)
        XCTAssertEqual(alpha(x0 - 1, mid), 0)
        XCTAssertEqual(alpha(x0 + 2, mid), 0)
    }

    func testBarsAreCrispAtTwoX() {
        let r = raster(.ready, scale: 2)
        func alpha(_ x: Int, _ yFromTop: Int) -> UInt8 { r.px[(yFromTop * r.w + x) * 4 + 3] }
        let x0 = Int(WispritMark.barRects[0].minX) * 2, mid = r.h / 2
        XCTAssertEqual((0..<4).map { alpha(x0 + $0, mid) }, [255, 255, 255, 255])
        XCTAssertEqual(alpha(x0 - 1, mid), 0)
        XCTAssertEqual(alpha(x0 + 4, mid), 0)
    }

    /// The listening image paints the dot in the tally colour and the bars in
    /// ink; no other image carries a colour of its own.
    func testListeningPaintsTheDotAndOnlyTheDot() {
        let r = raster(.listening, scale: 2, ink: .black,
                       tally: NSColor(srgbRed: 1, green: 0.5, blue: 0, alpha: 1))
        func rgb(_ x: Int, _ yFromTop: Int) -> (UInt8, UInt8, UInt8) {
            let i = (yFromTop * r.w + x) * 4
            return (r.px[i], r.px[i + 1], r.px[i + 2])
        }
        let dot = WispritMark.dotRect
        let centre = rgb(Int(dot.midX) * 2, r.h / 2)
        XCTAssertGreaterThan(centre.0, 200)
        XCTAssertLessThan(centre.2, 60)
        let bar = rgb(Int(WispritMark.barRects[1].minX) * 2 + 1, r.h / 2)
        XCTAssertEqual(bar.0, 0, "the bars stay ink")
    }

    /// The `!` and the lock's shackle are cut out of the shape, not drawn on
    /// top: the centre of the badge's stem is transparent.
    func testTheAlertIsKnockedOut() {
        let r = raster(.needsSetup, scale: 2)
        func alpha(_ x: Int, _ yFromTop: Int) -> UInt8 { r.px[(yFromTop * r.w + x) * 4 + 3] }
        // Stem centre: x = 4 pt, y = 9.25 pt up from the bottom.
        let x = 4 * 2, yUp = Int(9.25 * 2)
        XCTAssertEqual(alpha(x, r.h - 1 - yUp), 0)
        // The badge itself, just inside its left edge on the centre line.
        XCTAssertEqual(alpha(1 * 2, r.h / 2), 255)
    }
    #endif
}
