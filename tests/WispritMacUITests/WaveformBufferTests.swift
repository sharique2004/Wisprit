import XCTest
@testable import WispritMacUI

/// The ring buffer and the Tally's geometry.
///
/// The buffer is now the **onboarding mic test's** meter rather than the
/// pill's — the pill breathes in place through `BarSynthesizer` instead of
/// scrolling — but its shaping curve is still the pill's (`shaped` is what
/// `BarSynthesizer.push` calls first), and the scroll semantics below are
/// still exactly what the mic test draws.
final class WaveformBufferTests: XCTestCase {

    // MARK: - shaping

    func testShapingConstants() {
        XCTAssertEqual(WaveformBuffer.levelReference, 0.22)
        XCTAssertEqual(WaveformBuffer.gamma, 0.7)
        XCTAssertEqual(WaveformBuffer.quantum, 1.0 / 64.0)
    }

    func testShapedIsClampedExpandedAndQuantised() {
        XCTAssertEqual(WaveformBuffer.shaped(0), 0)
        XCTAssertEqual(WaveformBuffer.shaped(-1), 0, "negative is silence")
        XCTAssertEqual(WaveformBuffer.shaped(.nan), 0, "NaN never reaches the frame maths")
        XCTAssertEqual(WaveformBuffer.shaped(.infinity), 0)
        XCTAssertEqual(WaveformBuffer.shaped(WaveformBuffer.levelReference), 1.0,
                       "a typical speech peak is full scale")
        XCTAssertEqual(WaveformBuffer.shaped(1.0), 1.0, "and anything louder clamps there")

        // Every value lands on the 1/64 grid, which is what makes the equality
        // comparison in `push` exact rather than approximate.
        for raw in stride(from: 0.0, through: 0.4, by: 0.01) {
            let shaped = WaveformBuffer.shaped(raw)
            let steps = shaped / WaveformBuffer.quantum
            XCTAssertEqual(steps, steps.rounded(), accuracy: 1e-9, "level \(raw)")
        }
    }

    /// The gamma is there to make quiet speech visible: the voiced floor sits
    /// at 0.01, which is ~5% of the reference and would otherwise be invisible.
    func testTheQuietEndIsExpanded() {
        let raw = 0.01 / WaveformBuffer.levelReference
        XCTAssertGreaterThan(WaveformBuffer.shaped(0.01), raw,
                             "a voiced floor must read louder than its linear share")
    }

    // MARK: - scroll semantics (§2.3 property 1)

    func testPushScrollsNewestToTheRight() {
        var buffer = WaveformBuffer(slots: 15)
        buffer.push(0.3)
        buffer.push(0.2)
        XCTAssertEqual(buffer.normalized.count, 15)
        XCTAssertEqual(buffer.normalized.last, WaveformBuffer.shaped(0.2))
        XCTAssertEqual(buffer.normalized[13], WaveformBuffer.shaped(0.3))
        XCTAssertEqual(buffer.normalized[12], 0, "and everything older is still at floor")
    }

    func testOldestSlotsFallOffTheLeft() {
        var buffer = WaveformBuffer(slots: 4)
        for level in [0.35, 0.30, 0.25, 0.20, 0.15] { buffer.push(level) }
        XCTAssertEqual(buffer.normalized,
                       [0.30, 0.25, 0.20, 0.15].map(WaveformBuffer.shaped))
    }

    // MARK: - silence is free (§2.3 property 2)

    /// The load-bearing one. Once the incoming level and every slot are at
    /// floor, `push` reports "nothing to redraw" and `PillModel` skips `emit`.
    func testSilenceOnASilentBufferIsAlwaysANoOp() {
        var buffer = WaveformBuffer(slots: 15)
        for _ in 0..<15 {
            XCTAssertFalse(buffer.push(0), "a silent push on a silent buffer must not redraw")
        }
        XCTAssertTrue(buffer.isSilent)
        XCTAssertEqual(buffer.normalized, Array(repeating: 0, count: 15))
    }

    /// A burst drains in exactly `slots` ticks — the scroll is real, so those
    /// frames are earned — and then silence is free again, forever.
    func testSilenceBecomesFreeOnceTheBurstScrollsOut() {
        var buffer = WaveformBuffer(slots: 15)
        buffer.push(0.4)
        var redraws = 0
        for _ in 0..<60 where buffer.push(0) { redraws += 1 }
        XCTAssertEqual(redraws, 15, "one per slot the burst had to cross")
        XCTAssertTrue(buffer.isSilent)
        XCTAssertFalse(buffer.push(0))
    }

    /// Mic hiss below the quantum is silence, not a redraw.
    func testSubQuantumNoiseDoesNotRedraw() {
        var buffer = WaveformBuffer(slots: 15)
        XCTAssertFalse(buffer.push(0.00001))
        XCTAssertTrue(buffer.isSilent)
    }

    func testCollapseReturnsEveryLotToFloor() {
        var buffer = WaveformBuffer(slots: 15)
        buffer.push(0.35)
        XCTAssertFalse(buffer.isSilent)
        buffer.collapse()
        XCTAssertTrue(buffer.isSilent)
        XCTAssertEqual(buffer.normalized, Array(repeating: 0, count: 15))
    }

    func testNewestReturnsTheCompactTail() {
        var buffer = WaveformBuffer(slots: 15)
        for level in stride(from: 0.05, through: 0.35, by: 0.05) { buffer.push(level) }
        XCTAssertEqual(buffer.newest(7), Array(buffer.normalized.suffix(7)))
        XCTAssertEqual(buffer.newest(99), buffer.normalized, "asking for more than exists is fine")
    }

    func testASlotCountBelowOneIsRefused() {
        XCTAssertEqual(WaveformBuffer(slots: 0).slotCount, 1)
    }
}

/// The Tally's three scales (§7) and its dot-collapse maths (§2.2).
final class TallyMetricsTests: XCTestCase {

    func testThePillScaleMatchesTheSpec() {
        let m = TallyMetrics.pill
        XCTAssertEqual(m.barCount, 10, "one field, in every state that has one")
        XCTAssertEqual(m.barWidth, 2.25)
        XCTAssertEqual(m.barPitch, 5.5)
        XCTAssertEqual(m.height, 28)
        XCTAssertEqual(m.peak, 14)
        XCTAssertEqual(m.floor, 2.25)
        XCTAssertEqual(m.fieldWidth, 51.75, "9 × 5.5 + 2.25 — the ink")
        // Bar width and peak are Flowbar.svg's ratios against our capsule.
        XCTAssertEqual(m.barWidth / m.height, 0.080, accuracy: 0.002)
        XCTAssertEqual(m.peak / m.height, 0.509, accuracy: 0.01)
        // The pitch answers to the *app* instead: its ten bars run at 0.056 of
        // the pill's width, and Wispr's own export uses a 41 % duty cycle.
        XCTAssertEqual(m.barPitch / PillGeometry.widthListening, 0.056, accuracy: 0.002)
        XCTAssertEqual(m.barWidth / m.barPitch, 0.41, accuracy: 0.01)
        XCTAssertEqual(m.fieldWidth / PillGeometry.widthListening, 0.56, accuracy: 0.03,
                       "the field has to fill the capsule the way the app's does")
    }

    func testTheMicTestScaleMatchesTheSpec() {
        let m = TallyMetrics.micTest
        XCTAssertEqual(m.barCount, 33)
        XCTAssertEqual(m.barWidth, 4)
        XCTAssertEqual(m.barPitch, 9)
        XCTAssertEqual(m.height, 44)
        XCTAssertEqual(m.peak, 22)
        XCTAssertEqual(m.floor, 4)
    }

    /// The degenerate case: the sidebar's 6 pt status dot is one bar of the
    /// same instrument.
    func testTheSidebarDotIsOneBar() {
        XCTAssertEqual(TallyMetrics.dot.barCount, 1)
        XCTAssertEqual(TallyMetrics.dot.height, 6)
        XCTAssertEqual(TallyMetrics.dot.barHeight(0), 6)
        XCTAssertEqual(TallyMetrics.dot.barHeight(1), 6)
    }

    /// Silence is a perfect dot — `floor == barWidth`, so a silent bar is a
    /// circle and not a stub. The single best detail in Wispr's pill.
    func testSilenceCollapsesToAPerfectDot() {
        for metrics in [TallyMetrics.pill, .micTest] {
            XCTAssertEqual(metrics.barHeight(0), metrics.barWidth, "\(metrics.height) pt scale")
            XCTAssertEqual(metrics.cornerRadius, metrics.barWidth / 2)
        }
    }

    func testBarHeightAndAlphaInterpolate() {
        let m = TallyMetrics.pill
        XCTAssertEqual(m.barHeight(1), 14)
        XCTAssertEqual(m.barHeight(0.5), 8.125)
        XCTAssertEqual(m.barHeight(-1), 2.25, "clamped, like every other level")
        XCTAssertEqual(m.barAlpha(0), 0.45, "silence recedes to dim dots")
        XCTAssertEqual(m.barAlpha(1), 1.0, "and speech is full tint")
    }

    /// The resting bar is not a scale of its own any more — it is this one at
    /// silence. That is the measured truth about Flow (idle capsule and
    /// listening capsule are the same 107 px object) and it is what removes a
    /// transition the pill never needed.
    func testTheRestingBarIsTheListeningMeterAtSilence() {
        let m = TallyMetrics.pill
        XCTAssertEqual(m.height, PillGeometry.height, "the capsule never changes height")
        XCTAssertEqual(m.floor, m.barWidth, "silence is still a perfect dot")
        XCTAssertEqual(m.barHeight(0), m.barWidth)
        XCTAssertLessThan(m.fieldWidth, PillGeometry.widthListening - 2 * Theme.Space.s8,
                          "the field has to sit inside the capsule")
    }

    // MARK: - pixel alignment (§2.2, crisp at every backing scale)

    /// Only the origin snaps. Rounding the width would take a 2.5 pt bar to
    /// 3 px on a 1× display and the pitch and centred field with it; rounding
    /// the height would quantise the waveform into 1 pt steps, which is the one
    /// dimension the eye is actually reading.
    func testOnlyTheFieldOriginSnapsToThePixelGrid() {
        let m = TallyMetrics.pill
        let size = CGSize(width: PillGeometry.widthListening, height: PillGeometry.height)
        for scale in [1.0, 2.0] {
            let rect = m.barRect(index: 0, value: 0.5, count: 10, in: size, displayScale: scale)
            XCTAssertEqual((rect.minX * scale).truncatingRemainder(dividingBy: 1), 0,
                           accuracy: 1e-9, "origin off the grid at \(scale)×")
            XCTAssertEqual(rect.width, m.barWidth, "the width is not rounded")
            XCTAssertEqual(rect.height, m.barHeight(0.5), "nor the height")
        }
        // The pitch survives the snap at every scale, which is what keeps the
        // field even. Snapping each bar separately would give 4, 4, 5, 4 here.
        for scale in [1.0, 2.0] {
            let first = m.barRect(index: 0, value: 0, count: 10, in: size, displayScale: scale)
            let second = m.barRect(index: 1, value: 0, count: 10, in: size, displayScale: scale)
            let last = m.barRect(index: 9, value: 0, count: 10, in: size, displayScale: scale)
            XCTAssertEqual(second.minX - first.minX, m.barPitch, "pitch at \(scale)×")
            XCTAssertEqual(last.minX - first.minX, 9 * m.barPitch, accuracy: 1e-9)
        }
    }

    /// No scale means no snapping — the geometry every other assertion here
    /// pins is the unsnapped geometry, and it has not moved.
    func testTheUnscaledSpellingIsUnchanged() {
        let m = TallyMetrics.pill
        let size = CGSize(width: PillGeometry.widthListening, height: PillGeometry.height)
        XCTAssertEqual(m.barRect(index: 3, value: 0.4, count: 10, in: size),
                       m.barRect(index: 3, value: 0.4, count: 10, in: size, displayScale: 0))
        XCTAssertEqual(TallyMetrics.pixelAligned(22.125, scale: 0), 22.125)
        XCTAssertEqual(TallyMetrics.pixelAligned(22.125, scale: 1), 22)
        XCTAssertEqual(TallyMetrics.pixelAligned(22.125, scale: 2), 22, "44.25 px → 44")
        XCTAssertEqual(TallyMetrics.pixelAligned(11.6, scale: 2), 11.5)
    }

    /// The field is centred, which is where §2.2's 11.75 pt side inset comes
    /// from — it is derived, not chosen.
    func testBarsAreCentredHorizontallyAndOnTheMidline() {
        let m = TallyMetrics.pill
        let size = CGSize(width: PillGeometry.widthListening, height: PillGeometry.height)
        let first = m.barRect(index: 0, value: 0, count: 10, in: size)
        XCTAssertEqual(first.minX, PillGeometry.sideInset)
        XCTAssertEqual(first.midY, size.height / 2)

        let last = m.barRect(index: 9, value: 1, count: 10, in: size)
        XCTAssertEqual(last.maxX, size.width - PillGeometry.sideInset, accuracy: 1e-9)
        XCTAssertEqual(last.midY, size.height / 2, "bars grow symmetrically up and down")
        XCTAssertEqual(last.height, m.peak)
    }
}
