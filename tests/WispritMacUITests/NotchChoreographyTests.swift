import XCTest
@testable import WispritMacUI

/// The motion, as numbers: springs, poses, the orange rule, Reduce Motion.
final class NotchChoreographyTests: XCTestCase {

    private let layout = NotchGeometry.layout(on: .macBookPro14)

    /// Drives a lifecycle + choreography with cues at 120 fps; returns every
    /// frame with its time.
    private func run(_ cues: [(TimeInterval, NotchSignal)], until end: TimeInterval,
                     level: ((TimeInterval) -> Double)? = nil,
                     reduceMotion: Bool = false,
                     layout: NotchLayout? = nil) -> [(t: TimeInterval, frame: NotchFrame, phase: NotchPhase)] {
        var life = NotchLifecycle()
        var choreo = NotchChoreography(layout: layout ?? self.layout, reduceMotion: reduceMotion)
        var pending = cues
        var out: [(TimeInterval, NotchFrame, NotchPhase)] = []
        var nextLevel = 0.0
        var t = 0.0
        while t <= end {
            while let cue = pending.first, cue.0 <= t + 1e-9 {
                life.receive(cue.1, at: cue.0)
                pending.removeFirst()
            }
            if t >= nextLevel {
                nextLevel += 0.05
                if case .listening(micLive: true) = life.phase, let level {
                    life.receive(.level(level(t)), at: t)
                }
            }
            life.advance(to: t)
            let frame = choreo.step(to: t, lifecycle: life)
            if life.phase == .collapsing, choreo.isFolded { life.collapseSettled(at: t) }
            out.append((t, frame, life.phase))
            t += 1.0 / 120
        }
        return out
    }

    private let press: [(TimeInterval, NotchSignal)] = [(0, .prewarm), (0.05, .record)]

    private func speech(_ t: TimeInterval) -> Double { 0.12 + 0.1 * sin(t * 11) }

    private func isOrange(_ c: PillColor) -> Bool {
        let h = NotchPalette.hot
        return abs(c.r - h.r) + abs(c.g - h.g) + abs(c.b - h.b) < 0.3
    }

    // MARK: - springs

    func testASpringSettlesOnItsTargetWhateverTheFrameRate() {
        var at60 = NotchSpring(0, response: 0.3, damping: 0.7)
        var at144 = at60
        at60.target = 1
        at144.target = 1
        for _ in 0..<60 { at60.step(1.0 / 60) }
        for _ in 0..<144 { at144.step(1.0 / 144) }
        XCTAssertEqual(at60.value, at144.value, accuracy: 0.002, "frame-rate independent")
        XCTAssertTrue(at60.isSettled)
        XCTAssertEqual(at60.value, 1, accuracy: 0.002)
    }

    func testAnUnderdampedSpringOvershootsByTheExpectedAmount() {
        var spring = NotchSpring(0, response: NotchChoreography.openResponse,
                                 damping: NotchChoreography.openDamping)
        spring.target = 1
        var peak = 0.0
        for _ in 0..<240 { spring.step(1.0 / 240); peak = max(peak, spring.value) }
        XCTAssertGreaterThan(peak, 1.02, "a little elastic")
        XCTAssertLessThan(peak, 1.08, "never wobbly")
    }

    func testALongStallResumesRatherThanTeleporting() {
        var spring = NotchSpring(0, response: 0.3, damping: 1)
        spring.target = 1
        spring.step(5)
        XCTAssertLessThan(spring.value, 0.95, "one step covers at most 100 ms")
    }

    // MARK: - opening and folding

    func testTheBodyIsVisiblyOpenWithinAQuarterSecondAndNeverLeavesTheBand() {
        let frames = run(press, until: 0.8, level: speech)
        let at30 = frames.first { $0.t >= 0.03 }!.frame
        XCTAssertGreaterThan(at30.bodyWidth, layout.housing.width + 2, "moving by 30 ms")
        let at250 = frames.first { $0.t >= 0.25 }!.frame
        XCTAssertGreaterThan(at250.bodyWidth, layout.expanded.width * 0.97)
        for (_, frame, _) in frames {
            XCTAssertLessThanOrEqual(frame.bodyHeight, layout.band + 0.001, "inside the menu bar")
            let halfExtent = frame.bodyWidth / 2 + frame.shoulder + abs(frame.offsetX)
            XCTAssertLessThanOrEqual(layout.centerX + halfExtent, layout.frame.width,
                                     "the overshoot fits the panel")
        }
        let last = frames.last!.frame
        XCTAssertEqual(last.bodyWidth, layout.expanded.width, accuracy: 0.5)
        XCTAssertEqual(last.bodyHeight, layout.expanded.height, accuracy: 0.01)
    }

    /// The wings' content starts behind the housing and rides the edge out.
    func testContentSlidesOutFromBehindTheHousing() {
        let frames = run(press, until: 0.6, level: speech)
        let early = frames.first { $0.t >= 0.02 }!.frame
        XCTAssertLessThan(early.rightCenter.x, layout.housing.maxX)
        XCTAssertGreaterThan(early.leftCenter.x, layout.housing.minX)
        let open = frames.last!.frame
        XCTAssertGreaterThan(open.rightCenter.x - layout.bars.fieldWidth / 2, layout.housing.maxX,
                             "the whole meter clears the camera")
        XCTAssertLessThan(open.leftCenter.x + 4, layout.housing.minX)
    }

    func testTheFoldFinishesBeforeTheLifecyclesHardStop() {
        let frames = run(press + [(1, .dismiss)], until: 2, level: speech)
        let hidden = frames.first { $0.t > 1 && $0.phase == .hidden }
        XCTAssertNotNil(hidden)
        XCTAssertLessThan(hidden!.t - 1, NotchLifecycle.collapseBudget,
                          "the view settles the fold itself; the budget is only a backstop")
        let lastVisible = frames.last { $0.t > 1 && $0.phase == .collapsing }!.frame
        XCTAssertLessThan(lastVisible.bodyWidth, layout.housing.width + 6,
                          "folded back into the housing before ordering out")
    }

    // MARK: - the meter

    func testSpeechStandsTallerThanSilenceAndSilenceStillBreathes() {
        let silent = run(press, until: 4, level: { _ in 0 }).filter { $0.t > 1 }
        let loud = run(press, until: 4, level: speech).filter { $0.t > 1 }
        func mean(_ frames: [(t: TimeInterval, frame: NotchFrame, phase: NotchPhase)]) -> CGFloat {
            let all = frames.flatMap { $0.frame.bars.map(\.height) }
            return all.reduce(0, +) / CGFloat(all.count)
        }
        XCTAssertGreaterThan(mean(loud), mean(silent) * 1.8)
        let quietHeights = silent.flatMap { $0.frame.bars.map(\.height) }
        let spread = (quietHeights.max() ?? 0) - (quietHeights.min() ?? 0)
        XCTAssertGreaterThan(spread, 0.8, "silence moves")
        XCTAssertLessThan(quietHeights.max() ?? 0, layout.bars.height(0.3), "but stays low")
    }

    func testNeighbouringBarsAreNeverIdenticalWhileSpeaking() {
        let frame = run(press, until: 2.3, level: speech).last!.frame
        let heights = frame.bars.map(\.height)
        XCTAssertEqual(heights.count, layout.bars.count)
        XCTAssertGreaterThan(Set(heights.map { Int($0 * 10) }).count, 3)
    }

    // MARK: - the orange rule

    func testOrangeOnlyWhileTheMicIsLive() {
        let cues = press + [(2, .processing(.finalizing)), (2.6, .processing(.refining)),
                            (3.4, .result(.success))]
        let frames = run(cues, until: 4.4, level: speech)
        for (t, frame, phase) in frames {
            let orange = frame.visibleColors.contains(where: isOrange)
            switch phase {
            case .listening(micLive: false):
                XCTAssertFalse(orange, "prewarm is grey at \(t)")
            case .listening(micLive: true):
                if t > 0.3 { XCTAssertTrue(orange, "live is orange at \(t)") }
            case .processing, .result, .collapsing, .hidden:
                // The tint crossfade is 180 ms; after it, not a trace.
                if t > 2.25 { XCTAssertFalse(orange, "\(phase) at \(t) carries orange") }
            }
        }
    }

    func testAPrewarmThatNeverOpensTheMicIsNeverOrange() {
        let frames = run([(0, .prewarm)], until: 2)
        XCTAssertFalse(frames.contains { $0.frame.visibleColors.contains(where: isOrange) })
    }

    // MARK: - results

    func testResultsWearTheirColours() {
        for kind in NotchResult.allCases {
            let frames = run(press + [(1, .processing(.finalizing)), (1.4, .result(kind))],
                             until: 1.75, level: speech)
            let frame = frames.last!.frame
            let tint = NotchPalette.tint(for: kind)
            XCTAssertTrue(frame.bars.allSatisfy { $0.color == tint }, "\(kind) bars")
            switch kind {
            case .success:
                XCTAssertGreaterThan(frame.checkProgress, 0.95, "the check has drawn on")
                XCTAssertGreaterThan(frame.checkAlpha, 0.9)
            case .missed, .tooQuiet, .error, .blockedSecure:
                XCTAssertEqual(frame.glyphs.last?.color, kind == .missed ? NotchPalette.ink : tint)
                XCTAssertGreaterThan(frame.glyphs.last?.alpha ?? 0, 0.9)
            }
        }
    }

    func testOnlyMissAndErrorShake() {
        for kind in NotchResult.allCases {
            let frames = run(press + [(1, .result(kind))], until: 1.9)
            let during = frames.filter { $0.t >= 1 && $0.t < 1.3 }.map { abs($0.frame.offsetX) }.max() ?? 0
            let after = frames.filter { $0.t > 1.55 }.map { abs($0.frame.offsetX) }.max() ?? 0
            if kind == .error || kind == .missed {
                XCTAssertGreaterThan(during, 1, "\(kind) shakes its head")
            } else {
                XCTAssertEqual(during, 0, "\(kind) holds still")
            }
            XCTAssertEqual(after, 0, accuracy: 0.001, "\(kind) settles")
        }
    }

    // MARK: - accessibility

    func testReduceMotionCrossFadesAndHoldsTheRowStill() {
        let frames = run(press, until: 2, level: speech, reduceMotion: true)
        let widths = Set(frames.filter { $0.frame.bodyAlpha > 0 }.map { Int($0.frame.bodyWidth) })
        XCTAssertEqual(widths.count, 1, "no morph: the body fades in at full size")
        let alphas = frames.map(\.frame.bodyAlpha)
        XCTAssertTrue(alphas.contains { $0 > 0.2 && $0 < 0.8 }, "it cross-fades")
        let rows = frames.filter { $0.t > 0.5 }.map { $0.frame.bars.map(\.height) }
        XCTAssertEqual(Set(rows.map { $0.map { Int($0 * 100) } }).count, 1, "the bars do not move")
        XCTAssertTrue(frames.allSatisfy { $0.frame.offsetX == 0 })
        XCTAssertTrue(frames.allSatisfy { $0.frame.ringAlpha == 0 }, "no ripple ring")
    }

    func testReduceMotionStillShowsTheVoiceAsBrightness() {
        let frames = run(press, until: 3, level: { t in t < 1.5 ? 0 : 0.2 }, reduceMotion: true)
        let quiet = frames.first { $0.t >= 1.4 }!.frame.haloAlpha
        let loud = frames.first { $0.t >= 2.5 }!.frame.haloAlpha
        XCTAssertGreaterThan(loud, quiet + 0.1)
    }

    func testIncreaseContrastDrawsARim() {
        var life = NotchLifecycle()
        var choreo = NotchChoreography(layout: layout, increaseContrast: true)
        life.receive(.prewarm, at: 0)
        var frame = NotchFrame()
        for i in 0...60 { frame = choreo.step(to: Double(i) / 60, lifecycle: life) }
        XCTAssertGreaterThan(frame.rimAlpha, 0.3)
    }

    // MARK: - no notch

    func testTheVirtualNotchDropsFromTheTopEdge() {
        let flat = NotchGeometry.layout(on: .external1080)
        let frames = run(press, until: 0.8, level: speech, layout: flat)
        XCTAssertEqual(frames.first!.frame.bodyHeight, 0, accuracy: 0.5)
        XCTAssertEqual(frames.last!.frame.bodyHeight, flat.band, accuracy: 0.01)
        XCTAssertGreaterThan(frames.last!.frame.leftCenter.x, flat.centerX - flat.expanded.width / 2)
        XCTAssertLessThan(frames.last!.frame.rightCenter.x, flat.centerX + flat.expanded.width / 2)
    }
}
