import XCTest
@testable import WispritMacUI

final class NotchOutlineTests: XCTestCase {

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
    func testTheContourMeetsTheScreenTopAndWrapsTheHousing() throws {
        let display = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let builtIn = screen(frame: display,
                             visibleMaxY: 949,
                             left: CGRect(x: 0, y: 950, width: 663.5, height: 32),
                             right: CGRect(x: 848.5, y: 950, width: 663.5, height: 32),
                             builtin: true)
        let placement = try XCTUnwrap(NotchOutlineGeometry.placement(screens: [builtIn], mainIndex: 0))
        XCTAssertTrue(placement.hugsNotch)
        XCTAssertEqual(placement.frame.maxY, 982, accuracy: 0.01)
        XCTAssertEqual(placement.frame.minY, 949, accuracy: 0.01)
        XCTAssertLessThan(placement.frame.minX, 663.5)
        XCTAssertGreaterThan(placement.frame.maxX, 848.5)

        let line = placement.centerline
        let top = placement.frame.height
        XCTAssertEqual(line.first?.y ?? -1, top, accuracy: 0.6)
        XCTAssertEqual(line.last?.y ?? -1, top, accuracy: 0.6)
        XCTAssertTrue(line.contains { $0.x < placement.frame.width * 0.2 && $0.y > top * 0.9 })
        XCTAssertTrue(line.contains { $0.x > placement.frame.width * 0.8 && $0.y > top * 0.9 })

        let minY = line.map(\.y).min() ?? 99
        XCTAssertLessThan(minY, 2.5)
        let floor = line.filter { $0.y < minY + 2 }
        let span = (floor.map(\.x).max() ?? 0) - (floor.map(\.x).min() ?? 0)
        XCTAssertGreaterThan(span, placement.frame.width * 0.45)
        XCTAssertNotEqual(placement.frame.width, CGFloat(PillGeometry.widthListening))
    }

    func testDisplayWithoutANotchHangsAContourFromTheTopEdge() throws {
        let external = screen(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                              visibleMaxY: 1056)
        let placement = try XCTUnwrap(NotchOutlineGeometry.placement(screens: [external], mainIndex: 0))
        XCTAssertFalse(placement.hugsNotch)
        XCTAssertEqual(placement.frame.maxY, 1080, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(placement.frame.minY, 1056)
        XCTAssertEqual(placement.frame.midX, 960, accuracy: 0.1)
        let innerWidth = placement.frame.width - NotchOutlineGeometry.sidePad * 2
        XCTAssertEqual(innerWidth, NotchOutlineGeometry.notchWidth, accuracy: 0.1)
        let top = placement.frame.height
        XCTAssertEqual(placement.centerline.first?.y ?? -1, top, accuracy: 0.6)
        XCTAssertEqual(placement.centerline.last?.y ?? -1, top, accuracy: 0.6)
        XCTAssertNotEqual(placement.frame.size,
                          CGSize(width: CGFloat(PillGeometry.widthListening),
                                 height: CGFloat(PillGeometry.height)))
    }

    func testANotchedBuiltInWinsOverAnExternalMainDisplay() {
        let external = screen(frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
                              visibleMaxY: 1056)
        let builtIn = screen(frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                             visibleMaxY: 949,
                             left: CGRect(x: 0, y: 950, width: 663.5, height: 32),
                             right: CGRect(x: 848.5, y: 950, width: 663.5, height: 32),
                             builtin: true)
        let placement = NotchOutlineGeometry.placement(screens: [external, builtIn], mainIndex: 0)
        XCTAssertEqual(placement?.hugsNotch, true)
        XCTAssertEqual(placement?.frame.midX ?? -1, 756, accuracy: 0.5)
        XCTAssertEqual(placement?.frame.maxY ?? -1, 982, accuracy: 0.01)
    }

    @MainActor
    func testShowOrdersTheOverlayAndHideRemovesIt() {
        let outline = NotchOutline()
        XCTAssertFalse(outline.isOnScreen)
        outline.show()
        XCTAssertTrue(outline.isOnScreen)
        outline.updateLevel(0.2)
        outline.hide()
        XCTAssertFalse(outline.isOnScreen)
        outline.show()
        XCTAssertTrue(outline.isOnScreen)
        outline.hide()
        XCTAssertFalse(outline.isOnScreen)
    }
}
