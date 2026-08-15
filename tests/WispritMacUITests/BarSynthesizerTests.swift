import XCTest
@testable import WispritMacUI

/// The level → bars synthesis, which is where the pill stopped being a
/// scrolling ring buffer and started being Wispr Flow's breathing dome.
///
/// Everything here is measured against the real app: 10 bars that do not
/// scroll (frame-to-frame cross-correlation 0.90 at lag 0), a symmetric
/// centre-weighted envelope whose edges sit at 56 % of its centre, all bars
/// rising and falling together with loudness, and per-bar jitter on its own
/// clock. The synthesis is pure and seeded, so all of that is arithmetic.
final class BarSynthesizerTests: XCTestCase {

    private func speaking(_ synth: inout BarSynthesizer, ticks: Int = 8, level: Double = 0.3) {
        for _ in 0..<ticks { synth.push(level) }
    }

    // MARK: - the dome

    /// The amended arch (challenge-05 A1). `sin(π·i/(N−1))` puts the edges at
    /// *exactly* the measured 0.56 and gives the two middle bars a flat top,
    /// which is the shape the per-bar time-means describe
    /// (`[8.1, 10.8, 12.4, 13.6, 14.1, 14.4, 13.5, 12.6, 10.7, 8.3]` px).
    /// The obvious alternative — `sin(π·(i+½)/N)` — misses both: its edges land
    /// at 0.629 and its peak at 0.995.
    func testTheArchIsSymmetricWithMeasuredEdges() {
        let n = PillGeometry.barCount
        let arch = (0..<n).map { BarSynthesizer.arch($0, count: n) }
        for index in 0..<n {
            XCTAssertEqual(arch[index], arch[n - 1 - index], accuracy: 1e-12,
                           "bar \(index) must mirror bar \(n - 1 - index)")
        }
        XCTAssertEqual(arch[0], BarSynthesizer.archFloor, accuracy: 1e-12)
        XCTAssertEqual(arch[n - 1], BarSynthesizer.archFloor, accuracy: 1e-12)
        XCTAssertEqual(BarSynthesizer.archFloor, 0.56, "8.1 / 14.4 in the measured dome")
        let peak = arch.max() ?? 0
        XCTAssertGreaterThanOrEqual(peak, 0.98)
        XCTAssertLessThanOrEqual(peak, 1.0)
        // Monotone out from the middle: a dome, not a comb.
        for index in 1..<(n / 2) {
            XCTAssertGreaterThan(arch[index], arch[index - 1])
        }
    }

    func testADegenerateFieldHasNoDome() {
        XCTAssertEqual(BarSynthesizer.arch(0, count: 1), 1)
        XCTAssertEqual(BarSynthesizer.arch(5, count: 0), 1)
        // Out-of-range indices clamp rather than trap.
        XCTAssertEqual(BarSynthesizer.arch(99, count: 10),
                       BarSynthesizer.arch(9, count: 10))
    }

    /// The whole point of the rewrite, as an assertion: bar *i* is bar *i*.
    /// Under the old ring buffer a held level marched a value in from the
    /// right; here it settles into a standing shape.
    func testTheBarsDoNotScroll() {
        var synth = BarSynthesizer(barCount: PillGeometry.barCount, seed: 7)
        speaking(&synth, ticks: 30)
        let first = synth.values
        speaking(&synth, ticks: 1)
        let second = synth.values
        // Every bar stays within a jitter's distance of itself, and nothing
        // has moved one place to the left.
        for index in 0..<PillGeometry.barCount {
            XCTAssertEqual(second[index], first[index], accuracy: 0.5, "bar \(index) moved house")
        }
        let shiftedLeft = zip(first.dropFirst(), second).map { abs($0 - $1) }.reduce(0, +)
        let inPlace = zip(first, second).map { abs($0 - $1) }.reduce(0, +)
        XCTAssertLessThan(inPlace, shiftedLeft, "a scroll would fit the shifted comparison better")
    }

    // MARK: - the envelope

    /// Fast attack: one tick gets most of the way there, which is what makes a
    /// syllable land rather than swell.
    func testTheAttackArrivesInOneTick() {
        var synth = BarSynthesizer(barCount: PillGeometry.barCount, seed: 1)
        synth.push(1.0)
        let middle = synth.values[PillGeometry.barCount / 2]
        // The envelope is 0.75 after one tick; the dome and the jitter scale it.
        XCTAssertGreaterThanOrEqual(middle, 0.75 * 0.9 * BarSynthesizer.jitterLow)
        XCTAssertEqual(BarSynthesizer.attack, 0.75)
    }

    /// Slower release, τ ≈ 150 ms — the measured per-bar autocorrelation falls
    /// from 0.86 at 40 ms to 0.33 at 120 ms, which is that time constant.
    func testTheReleaseHasAHundredAndFiftyMillisecondTimeConstant() {
        let tau = -BarSynthesizer.tickInterval / log(1 - BarSynthesizer.release)
        XCTAssertGreaterThan(tau, 0.12)
        XCTAssertLessThan(tau, 0.18)
        XCTAssertLessThan(BarSynthesizer.release, BarSynthesizer.attack,
                          "release must be slower than attack, or speech reads as a strobe")
    }

    /// Loudness moves every bar at once — high neighbour correlation is the
    /// measured signature of Flow's waveform, and it is what makes ten bars
    /// read as one instrument rather than ten meters.
    func testEveryBarRisesWithLoudness() {
        var quiet = BarSynthesizer(barCount: PillGeometry.barCount, seed: 3)
        var loud = BarSynthesizer(barCount: PillGeometry.barCount, seed: 3)
        speaking(&quiet, ticks: 12, level: 0.02)
        speaking(&loud, ticks: 12, level: 0.3)
        for index in 0..<PillGeometry.barCount {
            XCTAssertGreaterThan(loud.values[index], quiet.values[index], "bar \(index)")
        }
    }

    // MARK: - the jitter

    func testJitterStaysInBoundsAndTargetsStayOnScale() {
        var synth = BarSynthesizer(barCount: PillGeometry.barCount, seed: 99)
        for tick in 0..<400 {
            let level = 0.05 + 0.3 * abs(sin(Double(tick) / 3))
            guard let targets = synth.push(level) else { continue }
            for value in targets {
                XCTAssertGreaterThanOrEqual(value, 0)
                XCTAssertLessThanOrEqual(value, 1)
            }
        }
        XCTAssertEqual(BarSynthesizer.jitterLow, 0.70)
        XCTAssertEqual(BarSynthesizer.jitterHigh, 1.15)
    }

    /// Neighbours must differ, or the dome is a smooth arc with no life in it.
    /// Wispr's own export retargets each bar independently every ~166 ms; ours
    /// brackets that with 130–250 ms deadlines.
    func testNeighbouringBarsAreNeverIdentical() {
        var synth = BarSynthesizer(barCount: PillGeometry.barCount, seed: 11)
        speaking(&synth, ticks: 20)
        let values = synth.values
        var distinct = 0
        for index in 1..<values.count where abs(values[index] - values[index - 1]) > 1e-9 {
            distinct += 1
        }
        XCTAssertEqual(distinct, values.count - 1, "a bar that matches its neighbour is a chart")
        XCTAssertGreaterThan(BarSynthesizer.retargetMin, 0.1)
        XCTAssertLessThan(BarSynthesizer.retargetMax, 0.3)
        XCTAssertLessThan(BarSynthesizer.retargetMin, BarSynthesizer.retargetMax)
    }

    /// Seeded and pure: the same seed and the same levels give the same bars.
    /// This is what makes `pill-demo`'s screenshots comparable between runs.
    func testTheSynthesisIsDeterministic() {
        var a = BarSynthesizer(barCount: PillGeometry.barCount, seed: 0xBEEF)
        var b = BarSynthesizer(barCount: PillGeometry.barCount, seed: 0xBEEF)
        for tick in 0..<60 {
            let level = 0.02 + 0.25 * abs(sin(Double(tick) / 4))
            XCTAssertEqual(a.push(level), b.push(level), "tick \(tick)")
        }
    }

    // MARK: - silence is free (the load-bearing one)

    /// The main thread carries the CGEventTap. A silent pill must cost zero
    /// transactions, and the exponential release could never deliver that on
    /// its own — it approaches zero and never arrives. The snap is what makes
    /// the contract reachable.
    func testSilenceOnASilentSynthesizerIsAlwaysNil() {
        var synth = BarSynthesizer(barCount: PillGeometry.barCount, seed: 5)
        for _ in 0..<200 {
            XCTAssertNil(synth.push(0), "a silent push on a silent row must not redraw")
        }
        XCTAssertTrue(synth.isSilent)
    }

    /// After a burst, the release takes 12 ticks — 600 ms, the closed form
    /// `⌈ln(quantum/attack)/ln(1−release)⌉` — and every tick after that is
    /// free forever.
    func testSilenceBecomesFreeWithinOneSecondOfAnyBurst() {
        var synth = BarSynthesizer(barCount: PillGeometry.barCount, seed: 5)
        synth.push(1.0)
        var emits = 0
        for _ in 0..<200 where synth.push(0) != nil { emits += 1 }
        let expected = Int((log(WaveformBuffer.quantum / BarSynthesizer.attack)
                            / log(1 - BarSynthesizer.release)).rounded(.up))
        XCTAssertEqual(emits, expected)
        XCTAssertLessThanOrEqual(Double(emits) * BarSynthesizer.tickInterval, 1.0,
                                 "a pause must not emit for longer than a second")
        XCTAssertTrue(synth.isSilent)
        XCTAssertEqual(synth.values, Array(repeating: 0, count: PillGeometry.barCount),
                       "the last emitted frame is exactly the dot row")
    }

    /// A silent tick mutates nothing at all — not even a jitter deadline — so
    /// the seeded stream cannot depend on how long the user paused. Without
    /// this, two identical utterances would draw different bars because of the
    /// gap between them.
    func testAPauseDoesNotAdvanceTheJitterClock() {
        var short = BarSynthesizer(barCount: PillGeometry.barCount, seed: 42)
        var long = BarSynthesizer(barCount: PillGeometry.barCount, seed: 42)
        for _ in 0..<40 { short.push(0) }
        for _ in 0..<4_000 { long.push(0) }
        for _ in 0..<10 {
            XCTAssertEqual(short.push(0.3), long.push(0.3))
        }
    }

    func testResetReturnsEveryBarToFloor() {
        var synth = BarSynthesizer(barCount: PillGeometry.barCount, seed: 8)
        speaking(&synth)
        XCTAssertFalse(synth.isSilent)
        synth.reset()
        XCTAssertTrue(synth.isSilent)
        XCTAssertEqual(synth.values, Array(repeating: 0, count: PillGeometry.barCount))
        XCTAssertNil(synth.push(0), "and silence is free again immediately")
    }

    /// The shaping is the ring buffer's, unchanged — the reference, the gamma
    /// and the quantum are all still doing their jobs upstream of the dome, so
    /// quiet speech still moves the bars.
    func testQuietSpeechStillMovesTheBars() {
        var synth = BarSynthesizer(barCount: PillGeometry.barCount, seed: 2)
        for _ in 0..<10 { synth.push(0.01) }   // the voiced floor
        XCTAssertGreaterThan(synth.values[PillGeometry.barCount / 2], 0.05)
        XCTAssertFalse(synth.isSilent)
    }

    func testTheGeneratorIsUniformOverItsRange() {
        var rng = SeededGenerator(seed: 1234)
        var low = Double.infinity
        var high = -Double.infinity
        var sum = 0.0
        let count = 20_000
        for _ in 0..<count {
            let value = rng.uniform(0.7, 1.15)
            low = min(low, value)
            high = max(high, value)
            sum += value
        }
        XCTAssertGreaterThanOrEqual(low, 0.7)
        XCTAssertLessThanOrEqual(high, 1.15)
        XCTAssertEqual(sum / Double(count), 0.925, accuracy: 0.01)
    }
}

/// The meter's pure decision table, and the predicate that keeps SwiftUI out
/// of the 20 Hz path.
final class PillMeterFrameTests: XCTestCase {

    private func render(_ state: PillState, bars: [Double]? = nil) -> PillRender {
        var frame = PillRender.collapsed
        frame.isVisible = true
        frame.state = state
        frame.bars = bars ?? Array(repeating: 0.4, count: PillGeometry.barCount)
        return frame
    }

    /// A live tick tweens for 200 ms, linearly. Everything else is a single
    /// decisive 120 ms move.
    func testLiveTicksTweenAndStateChangesLand() {
        let live = PillMeterFrame.make(for: render(.recording), reduceMotion: false)
        XCTAssertEqual(live.duration, PillMotion.meterTweenDuration)
        XCTAssertEqual(live.curve, .linear)
        XCTAssertEqual(live.tint, PillPalette.hot)
        XCTAssertFalse(live.spinning)

        let release = PillMeterFrame.make(for: render(.finalizing, bars: []), reduceMotion: false)
        XCTAssertEqual(release.duration, PillMotion.desaturateDuration)
        XCTAssertEqual(release.curve, .easeOut)
    }

    /// Three tints and the state decides: cream at rest, orange while the mic
    /// is open, grey while the pill is working. The middle one is the orange
    /// rule (§1.6) and must hold for the meter exactly as it holds for the tint.
    func testTheMeterIsOrangeOnlyWhileTheMicIsOpen() {
        for state in PillState.allCases {
            let tint = PillPalette.meterTint(for: state)
            XCTAssertEqual(tint == PillPalette.hot, state == .recording, "\(state)")
            if state == .finalizing || state == .refining {
                XCTAssertEqual(tint, PillPalette.muted, "\(state) dims on release")
            }
        }
    }

    func testTheSpinnerRunsOnlyWhileWaitingAndVisible() {
        for state in PillState.allCases {
            let waiting = (state == .finalizing || state == .refining)
            XCTAssertEqual(PillMeterFrame.make(for: render(state), reduceMotion: false).spinning,
                           waiting, "\(state)")
        }
        var hidden = render(.finalizing)
        hidden.isVisible = false
        XCTAssertFalse(PillMeterFrame.make(for: hidden, reduceMotion: false).spinning)
    }

    /// Reduce Motion: the bars snap to their 20 Hz targets and nothing tweens.
    /// The durations, the cadence and the state's legibility all survive —
    /// only the motion between samples goes.
    func testReduceMotionSnapsTheBarsAndKeepsEverythingElse() {
        let moving = PillMeterFrame.make(for: render(.recording), reduceMotion: false)
        let still = PillMeterFrame.make(for: render(.recording), reduceMotion: true)
        XCTAssertTrue(moving.animated)
        XCTAssertFalse(still.animated)
        XCTAssertEqual(still.targets, moving.targets, "the meter still reads the voice")
        XCTAssertEqual(still.duration, moving.duration, "durations survive")
        XCTAssertEqual(still.tint, moving.tint)
        XCTAssertTrue(PillMeterFrame.make(for: render(.finalizing), reduceMotion: true).spinning,
                      "a still spinner is still a status light; a blank capsule is not")
    }

    // MARK: - the sink predicate (surface inertness)

    /// The contract that keeps dictation cheap: a render whose only delta is
    /// the meter never reaches SwiftUI.
    func testALevelOnlyRenderIsConsumedByTheMeter() {
        var before = render(.recording)
        var after = before
        after.bars = Array(repeating: 0.7, count: PillGeometry.barCount)
        after.level = 0.7
        XCTAssertTrue(PillRender.isMeterOnly(before, after))

        // …and the first tick of an utterance is not, because it ends
        // `prewarming`: the tint crossfade, the body and the accessibility
        // label all live in SwiftUI, and keying this on "the frame did not
        // move" would freeze the surface mid-arrival.
        before.state = .prewarming
        XCTAssertFalse(PillRender.isMeterOnly(before, after))
    }

    func testAnythingBesidesTheMeterReachesTheSurface() {
        let base = render(.recording)
        var wider = base
        wider.totalWidth = 160
        var tailed = base
        tailed.bubble = "so I was"
        var noticed = base
        noticed.message = "Learned Sharique"
        var glyphed = base
        glyphed.glyph = .warning
        var gone = base
        gone.isVisible = false
        var muted = base
        muted.tailMuted = true
        for candidate in [wider, tailed, noticed, glyphed, gone, muted] {
            XCTAssertFalse(PillRender.isMeterOnly(base, candidate),
                           "\(candidate.state) / \(candidate.totalWidth)")
        }
        // A state with no meter at all cannot be consumed by one.
        XCTAssertFalse(PillRender.isMeterOnly(base, render(.error, bars: [])))
    }
}
