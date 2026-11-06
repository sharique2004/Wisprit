import XCTest
@testable import WispritMacUI

/// Where the living notch sits, and the one rule that keeps it honest: the
/// panel is exactly the menu-bar band, so nothing it draws can cover a window.
final class NotchGeometryTests: XCTestCase {

    private func screen(frame: CGRect,
                        visibleMaxY: CGFloat,
                        left: CGRect? = nil,
                        right: CGRect? = nil,
                        builtin: Bool = false) -> NotchScreen {
        NotchScreen(frame: frame,
                    visibleFrame: CGRect(x: frame.minX,
                                         y: frame.minY,
                                         width: frame.width,
                                         height: visibleMaxY - frame.minY),
                    auxiliaryTopLeft: left,
                    auxiliaryTopRight: right,
                    isBuiltin: builtin)
    }

    /// The 14-inch built-in display: housing from y 950 to 982, menu bar
    /// continuing 1 pt below the housing to y 949.
    func testTheBodyHangsFromTheScreenTopAndStaysInTheMenuBar() throws {
        let layout = NotchGeometry.layout(on: NotchScreen.macBookPro14)
        XCTAssertTrue(layout.hugsNotch)
        XCTAssertEqual(layout.frame.maxY, 982, accuracy: 0.01, "top edge is the screen's top row")
        XCTAssertEqual(layout.frame.minY, 949, accuracy: 0.01, "and never below the menu bar")
        XCTAssertEqual(layout.band, 33, accuracy: 0.01)
        XCTAssertEqual(layout.frame.midX, 756, accuracy: 0.01, "centred on the housing")
        XCTAssertEqual(layout.housing.width, 185, accuracy: 0.01)
        XCTAssertEqual(layout.housing.maxY, layout.top, accuracy: 0.01)
        XCTAssertEqual(layout.expanded.width, 185 + NotchGeometry.wing * 2, accuracy: 0.01)
        XCTAssertEqual(layout.expanded.height, layout.band, accuracy: 0.01,
                       "open, the body takes the sliver under the housing too")
    }

    /// Folded, the body must be wholly behind the camera — narrower than the
    /// housing and no deeper — so the frame before `orderOut` shows nothing.
    func testTheFoldedBodyHidesBehindTheHousing() {
        let layout = NotchGeometry.layout(on: NotchScreen.macBookPro14)
        XCTAssertLessThan(layout.footprint.width, layout.housing.width)
        XCTAssertLessThanOrEqual(layout.footprint.height, layout.housing.height)
        XCTAssertGreaterThanOrEqual(layout.bottomRadius, 9,
                                    "a rounder corner than the housing's stays inside it")
    }

    func testTheWingsAreModest() {
        XCTAssertLessThanOrEqual(NotchGeometry.wing, 44,
                                 "wings cover menu-bar items next to the notch while out")
        let layout = NotchGeometry.layout(on: NotchScreen.macBookPro14)
        XCTAssertLessThan(layout.bars.fieldWidth, NotchGeometry.wing - 8,
                          "the meter fits its wing with room on both sides")
        XCTAssertLessThan(layout.bars.peak, layout.band - 10, "the meter never touches an edge")
    }

    func testADisplayWithoutANotchGetsACompactVirtualNotch() throws {
        let external = screen(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), visibleMaxY: 1056)
        let layout = try XCTUnwrap(NotchGeometry.layout(screens: [external], mainIndex: 0))
        XCTAssertFalse(layout.hugsNotch)
        XCTAssertEqual(layout.frame.maxY, 1080, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(layout.frame.minY, 1056, "inside the 24 pt menu bar")
        XCTAssertEqual(layout.frame.midX, 960, accuracy: 0.1)
        XCTAssertEqual(layout.footprint.height, 0, "it drops out of the top edge")
        XCTAssertLessThan(layout.expanded.width, 120, "no empty middle without a camera to avoid")
    }

    func testANotchedBuiltInWinsOverAnExternalMainDisplay() {
        let external = screen(frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080), visibleMaxY: 1056)
        let builtIn = screen(frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                             visibleMaxY: 949,
                             left: CGRect(x: 0, y: 950, width: 663.5, height: 32),
                             right: CGRect(x: 848.5, y: 950, width: 663.5, height: 32),
                             builtin: true)
        let layout = NotchGeometry.layout(screens: [external, builtIn], mainIndex: 0)
        XCTAssertEqual(layout?.hugsNotch, true)
        XCTAssertEqual(layout?.frame.midX ?? -1, 756, accuracy: 0.5)
        XCTAssertEqual(layout?.frame.maxY ?? -1, 982, accuracy: 0.01)
    }

    func testNoScreensNoLayout() {
        XCTAssertNil(NotchGeometry.layout(screens: [], mainIndex: nil))
    }

    /// The body path is flush with the top, as deep as asked, and — at the
    /// spring's overshoot plus the error shake — still inside the panel.
    func testTheBodyPathStaysInsideThePanelAtItsWidest() {
        for screen in [NotchScreen.macBookPro14, NotchScreen.external1080] {
            let layout = NotchGeometry.layout(on: screen)
            let widest = layout.footprint.width + (layout.expanded.width - layout.footprint.width) * 1.08
            let shake: CGFloat = 3.5
            let path = NotchGeometry.bodyPath(centerX: layout.centerX + shake, top: layout.top,
                                              width: widest, height: layout.expanded.height,
                                              bottomRadius: layout.bottomRadius,
                                              shoulder: layout.shoulderRadius)
            let box = path.boundingBoxOfPath
            XCTAssertEqual(box.maxY, layout.top, accuracy: 0.01, "flush with the screen top")
            XCTAssertGreaterThanOrEqual(box.minY, -0.01, "never below the band")
            XCTAssertGreaterThanOrEqual(box.minX, 0)
            XCTAssertLessThanOrEqual(box.maxX, layout.frame.width)
        }
    }

    func testDegenerateSizesDrawNothingRatherThanGarbage() {
        XCTAssertTrue(NotchGeometry.bodyPath(centerX: 10, top: 30, width: 0, height: 30,
                                             bottomRadius: 11, shoulder: 6).isEmpty)
        XCTAssertTrue(NotchGeometry.bodyPath(centerX: 10, top: 30, width: 100, height: 0,
                                             bottomRadius: 11, shoulder: 6).isEmpty)
        // A sliver: radii clamp instead of crossing.
        let sliver = NotchGeometry.bodyPath(centerX: 50, top: 30, width: 6, height: 3,
                                            bottomRadius: 11, shoulder: 6)
        XCTAssertFalse(sliver.isEmpty)
        XCTAssertGreaterThanOrEqual(sliver.boundingBoxOfPath.minY, 27 - 0.01)
    }
}
