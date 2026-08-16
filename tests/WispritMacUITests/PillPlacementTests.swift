import XCTest
@testable import WispritMacUI

/// Edge orientation, clamping, and the canonical origin the settings file
/// already stores. Pure — no window server.
final class PillPlacementTests: XCTestCase {

    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

    func testLeftAndRightEdgesStandThePillUp() {
        XCTAssertEqual(PillScreenEdge.left.axis, .vertical)
        XCTAssertEqual(PillScreenEdge.right.axis, .vertical)
        XCTAssertEqual(PillScreenEdge.top.axis, .horizontal)
        XCTAssertEqual(PillScreenEdge.bottom.axis, .horizontal)
    }

    func testNearestEdgePicksTheClosestSide() {
        XCTAssertEqual(PillPlacement.nearestEdge(of: CGPoint(x: 10, y: 450), in: screen), .left)
        XCTAssertEqual(PillPlacement.nearestEdge(of: CGPoint(x: 1430, y: 450), in: screen), .right)
        XCTAssertEqual(PillPlacement.nearestEdge(of: CGPoint(x: 720, y: 890), in: screen), .top)
        XCTAssertEqual(PillPlacement.nearestEdge(of: CGPoint(x: 720, y: 10), in: screen), .bottom)
    }

    func testProximityReorientsOnlyNearAnEdge() {
        let left = PillPlacement.placement(center: CGPoint(x: 20, y: 450), in: screen)
        XCTAssertEqual(left.axis, .vertical)
        XCTAssertEqual(left.edge, .left)

        let right = PillPlacement.placement(center: CGPoint(x: 1420, y: 400), in: screen)
        XCTAssertEqual(right.axis, .vertical)
        XCTAssertEqual(right.edge, .right)

        let top = PillPlacement.placement(center: CGPoint(x: 700, y: 880), in: screen)
        XCTAssertEqual(top.axis, .horizontal)
        XCTAssertEqual(top.edge, .top)

        let bottom = PillPlacement.placement(center: CGPoint(x: 700, y: 20), in: screen)
        XCTAssertEqual(bottom.axis, .horizontal)
        XCTAssertEqual(bottom.edge, .bottom)

        let middle = PillPlacement.placement(center: CGPoint(x: 720, y: 450), in: screen)
        XCTAssertEqual(middle.axis, .horizontal)
        XCTAssertNil(middle.edge, "the middle of the screen is free-floating")
    }

    func testThresholdIsTheDockingDistance() {
        XCTAssertEqual(PillPlacement.dockThreshold, 48)
        let justInside = PillPlacement.placement(
            center: CGPoint(x: PillPlacement.dockThreshold, y: 450), in: screen)
        XCTAssertEqual(justInside.edge, .left)
        let justOutside = PillPlacement.placement(
            center: CGPoint(x: PillPlacement.dockThreshold + 1, y: 450), in: screen)
        XCTAssertNil(justOutside.edge)
        XCTAssertEqual(justOutside.axis, .horizontal)
    }

    func testPanelSizeSwapsForVertical() {
        XCTAssertEqual(PillPlacement.panelSize(long: 96, short: 28, axis: .horizontal),
                       CGSize(width: 96, height: 28))
        XCTAssertEqual(PillPlacement.panelSize(long: 96, short: 28, axis: .vertical),
                       CGSize(width: 28, height: 96))
    }

    func testCanonicalOriginPreservesTheListeningWidthContract() {
        let vertical = CGRect(x: 100, y: 200, width: 28, height: 96)
        let origin = PillPlacement.canonicalOrigin(for: vertical)
        XCTAssertEqual(origin.x, vertical.midX - PillGeometry.widthListening / 2)
        XCTAssertEqual(origin.y, vertical.midY - PillGeometry.height / 2)
    }

    func testClampKeepsTheCapsuleInsideTheVisibleFrame() {
        let visible = CGRect(x: 0, y: 80, width: 1440, height: 790) // Dock + menu bar
        let overflowing = CGRect(x: -20, y: 40, width: 96, height: 28)
        let clamped = PillPlacement.clamp(overflowing, to: visible, margin: 8)
        XCTAssertGreaterThanOrEqual(clamped.minX, visible.minX + 8)
        XCTAssertGreaterThanOrEqual(clamped.minY, visible.minY + 8)
        XCTAssertLessThanOrEqual(clamped.maxX, visible.maxX - 8)
        XCTAssertLessThanOrEqual(clamped.maxY, visible.maxY - 8)
        XCTAssertEqual(clamped.size, overflowing.size)
    }

    func testMeterGrowsTowardTheScreenCentre() {
        XCTAssertEqual(PillPlacement.meterRotation(edge: .left), 90)
        XCTAssertEqual(PillPlacement.meterRotation(edge: .right), -90)
        XCTAssertEqual(PillPlacement.meterRotation(edge: .top), 0)
        XCTAssertEqual(PillPlacement.meterRotation(edge: .bottom), 0)
        XCTAssertEqual(PillPlacement.meterRotation(edge: nil), 0)
    }

    func testScreenIndexPrefersVisibleFrameThenNearest() {
        let frames = [CGRect(x: 0, y: 0, width: 1440, height: 900),
                      CGRect(x: 1440, y: 0, width: 1920, height: 1080)]
        let visible = [CGRect(x: 0, y: 80, width: 1440, height: 790),
                       CGRect(x: 1440, y: 0, width: 1920, height: 1080)]
        XCTAssertEqual(PillPlacement.screenIndex(containing: CGPoint(x: 100, y: 400),
                                                 frames: frames, visibleFrames: visible), 0)
        XCTAssertEqual(PillPlacement.screenIndex(containing: CGPoint(x: 2000, y: 100),
                                                 frames: frames, visibleFrames: visible), 1)
        XCTAssertEqual(PillPlacement.screenIndex(containing: CGPoint(x: 5000, y: 0),
                                                 frames: frames, visibleFrames: visible), 1)
    }

    func testClampKeepsAVerticalCapsuleInsideTheVisibleFrame() {
        let visible = CGRect(x: 0, y: 80, width: 1440, height: 790)
        let overflowing = CGRect(x: -10, y: 50, width: 28, height: 128)
        let clamped = PillPlacement.clamp(overflowing, to: visible, margin: 8)
        XCTAssertGreaterThanOrEqual(clamped.minX, visible.minX + 8)
        XCTAssertGreaterThanOrEqual(clamped.minY, visible.minY + 8)
        XCTAssertLessThanOrEqual(clamped.maxY, visible.maxY - 8)
        XCTAssertEqual(clamped.size, overflowing.size)
    }

    func testIdleHitSizeStaysAtListeningSizeWhetherHoveredOrNot() {
        var rest = PillRender.collapsed
        rest.isVisible = true
        rest.state = .idle
        rest.totalWidth = PillGeometry.widthMini
        rest.height = PillGeometry.heightMini
        let hit = PillPlacement.hitSize(for: rest)
        XCTAssertEqual(hit, CGSize(width: PillGeometry.widthListening, height: PillGeometry.height))

        var hovered = rest
        hovered.isHovered = true
        hovered.totalWidth = PillGeometry.widthListening
        hovered.height = PillGeometry.height
        XCTAssertEqual(PillPlacement.hitSize(for: hovered), hit)

        rest.axis = .vertical
        rest.dockEdge = .left
        XCTAssertEqual(PillPlacement.hitSize(for: rest),
                       CGSize(width: PillGeometry.height, height: PillGeometry.widthListening))
    }

    func testCollapsedVisualSitsInsideTheIdleHitFrame() {
        let edges: [PillScreenEdge?] = [nil, .top, .bottom, .left, .right]
        for edge in edges {
            var render = PillRender.collapsed
            render.isVisible = true
            render.state = .idle
            render.axis = edge?.axis ?? .horizontal
            render.dockEdge = edge
            render.totalWidth = PillGeometry.widthMini
            render.height = PillGeometry.heightMini
            let hit = PillPlacement.hitSize(for: render)
            let visual = PillPlacement.panelSize(
                long: render.totalWidth, short: render.height, axis: render.axis)
            let rect = PillPlacement.visualFrame(in: hit, visual: visual, edge: edge)
            XCTAssertTrue(CGRect(origin: .zero, size: hit).contains(rect),
                          "visual must stay inside hit for \(String(describing: edge))")
        }
    }

    func testVisualFramePinsToTheDockedEdge() {
        let panel = CGSize(width: 96, height: 28)
        let visual = CGSize(width: 36, height: 10)
        let bottom = PillPlacement.visualFrame(in: panel, visual: visual, edge: .bottom)
        XCTAssertEqual(bottom.minY, 0)
        XCTAssertEqual(bottom.midX, panel.width / 2, accuracy: 0.01)

        let top = PillPlacement.visualFrame(in: panel, visual: visual, edge: .top)
        XCTAssertEqual(top.maxY, panel.height)
        XCTAssertEqual(top.midX, panel.width / 2, accuracy: 0.01)

        let side = CGSize(width: 28, height: 96)
        let sliver = CGSize(width: 10, height: 36)
        let left = PillPlacement.visualFrame(in: side, visual: sliver, edge: .left)
        XCTAssertEqual(left.minX, 0)
        XCTAssertEqual(left.midY, side.height / 2, accuracy: 0.01)

        let right = PillPlacement.visualFrame(in: side, visual: sliver, edge: .right)
        XCTAssertEqual(right.maxX, side.width)
        XCTAssertEqual(right.midY, side.height / 2, accuracy: 0.01)

        let free = PillPlacement.visualFrame(in: panel, visual: visual, edge: nil)
        XCTAssertEqual(free.midX, panel.width / 2, accuracy: 0.01)
        XCTAssertEqual(free.midY, panel.height / 2, accuracy: 0.01)
    }
}
