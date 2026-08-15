import Foundation

/// Deterministic pseudo-random source for the bar jitter — SplitMix64.
///
/// Seeded and pure so the synthesis is a unit test rather than a screenshot:
/// the same seed and the same level sequence produce the same bars, forever.
public struct SeededGenerator: RandomNumberGenerator, Equatable, Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in `low…high`. 53 bits of mantissa, which is more resolution
    /// than a 2.25 pt bar can spend.
    public mutating func uniform(_ low: Double, _ high: Double) -> Double {
        let unit = Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
        return low + (high - low) * unit
    }
}

/// The level → bars synthesis, replacing the ring buffer's scroll in the pill.
///
/// **Why this exists.** Our meter used to scroll: one scalar at 20 Hz pushed
/// into a ring, newest on the right, oldest falling off the left. Frame-level
/// measurement of the real Wispr Flow app says that is the single biggest
/// divergence from it — Flow's bars *do not scroll*. Frame-to-frame spatial
/// cross-correlation of its listening waveform is 0.90 at lag 0 and 0.40–0.80
/// at ±1 bar: the pattern stays where it is and breathes. Two dictations,
/// 425 frames, and the same answer both times.
///
/// So the bars oscillate in place, and three things decide a bar's height:
///
/// 1. **One loudness envelope** shared by every bar — fast attack, slower
///    release — which is why Flow's bars rise and fall *together* with the
///    voice (high neighbour correlation in the same measurement).
/// 2. **A fixed centre-weighted dome**, `arch`, which is why the row reads as
///    one instrument and not ten meters: the measured per-bar time-means are
///    `[8.1, 10.8, 12.4, 13.6, 14.1, 14.4, 13.5, 12.6, 10.7, 8.3]` px — edges
///    at 56 % of centre, and that 0.56 is this file's `archFloor`.
/// 3. **Per-bar jitter** that only changes at its own deadline, so neighbouring
///    bars are never identical. Wispr's own After Effects export retargets each
///    bar to a new random height every 5 frames at 30 fps (166 ms) with linear
///    tweens between; `retargetMin…retargetMax` brackets that, and the 200 ms
///    linear tween in `PillMeterLayerView` *is* the tween between values.
///
/// **Silence is still free.** `push` returns nil once the envelope has snapped
/// to zero and the previous emit was already all-floor, exactly as the ring
/// buffer's `push` returned false — the main thread carries the CGEventTap and
/// an idle-but-visible pill must cost nothing. The snap is what makes that
/// reachable at all: an exponential release never *reaches* zero, so without it
/// a mid-dictation pause would emit sub-visible frames for minutes.
public struct BarSynthesizer: Equatable, Sendable {

    // MARK: - the tunable constants
    //
    // Fitted, not exact: the source video is 25 fps, which cannot resolve
    // sub-40 ms timing. They live here as named constants because the one
    // honest thing to say about them is that they are a tuning surface.

    /// Fraction of the gap closed on a rising tick — one tick is ~one attack.
    public static let attack = 0.75
    /// Fraction closed on a falling tick. τ ≈ 150 ms at 20 Hz, which matches
    /// the measured per-bar autocorrelation (0.86 at 40 ms → 0.33 at 120 ms).
    public static let release = 0.28
    /// Edge height as a share of centre height. Measured: 8.1/14.4 ≈ 0.56.
    public static let archFloor = 0.56
    /// Per-bar height multiplier, redrawn at each bar's own deadline.
    public static let jitterLow = 0.70
    public static let jitterHigh = 1.15
    /// Seconds between a bar's jitter retargets. Brackets Wispr's own 166 ms.
    public static let retargetMin = 0.13
    public static let retargetMax = 0.25
    /// `SessionController.levelTickInterval` — the cadence `push` assumes when
    /// it ages the deadlines. Passed explicitly by tests that want to prove the
    /// interval bounds.
    public static let tickInterval = 0.05

    /// The dome. Symmetric, floor at both ends, flat-topped in the middle.
    ///
    /// `sin(π·i/(N−1))` rather than `sin(π·(i+½)/N)`: with an even bar count
    /// there is no true centre bar, and the measured dome has a flat top
    /// (`…14.1, 14.4, 13.5…`) rather than a single spike. This spelling puts
    /// the edges at exactly `archFloor` and the maximum at 0.993 across the two
    /// middle bars, which is that shape.
    public static func arch(_ index: Int, count: Int) -> Double {
        guard count > 1 else { return 1 }
        let i = min(max(0, index), count - 1)
        return archFloor + (1 - archFloor) * sin(.pi * Double(i) / Double(count - 1))
    }

    // MARK: - state

    public let barCount: Int
    /// Shared loudness envelope, 0…1 in shaped units.
    private var envelope: Double = 0
    /// Per-bar multiplier and the seconds left before it is redrawn.
    private var jitter: [Double]
    private var deadline: [Double]
    private var rng: SeededGenerator
    /// Whether the last thing this synthesizer emitted was the dot row. The
    /// second half of the silence-is-free predicate.
    private var lastWasFloor = true
    /// The last emitted targets, so the model can render without re-deriving.
    public private(set) var values: [Double]

    public init(barCount: Int = PillGeometry.barCount, seed: UInt64 = 0x5715_9EED) {
        let n = max(1, barCount)
        self.barCount = n
        self.jitter = Array(repeating: 1, count: n)
        self.deadline = Array(repeating: 0, count: n)
        self.values = Array(repeating: 0, count: n)
        self.rng = SeededGenerator(seed: seed)
    }

    /// True when every bar is at floor — the dot row.
    public var isSilent: Bool { values.allSatisfy { $0 == 0 } }

    /// One 20 Hz level sample in, one set of bar targets out — or nil when
    /// there is nothing to redraw.
    ///
    /// The shaping is the ring buffer's, unchanged: `/0.22` reference, 0.7
    /// gamma, quantised to 1/64. What changes is only what the shaped value
    /// *does* once it is here.
    @discardableResult
    public mutating func push(_ level: Double, tick: Double = BarSynthesizer.tickInterval) -> [Double]? {
        let v = WaveformBuffer.shaped(level)
        envelope += (v > envelope ? BarSynthesizer.attack : BarSynthesizer.release) * (v - envelope)
        // The snap. Without it the release asymptote never reaches zero and a
        // pause would emit 20 Hz transactions of sub-visible targets for the
        // rest of the utterance. One quantum is already below the smallest
        // height difference the meter can draw.
        if v == 0 && envelope < WaveformBuffer.quantum { envelope = 0 }

        guard envelope > 0 else {
            // Silence mutates nothing — not even the jitter deadlines — so the
            // seeded stream is independent of how long the user paused.
            let emitted = !lastWasFloor
            values = Array(repeating: 0, count: barCount)
            lastWasFloor = true
            return emitted ? values : nil
        }

        advanceJitter(by: tick)
        values = (0..<barCount).map { index in
            let raw = envelope * BarSynthesizer.arch(index, count: barCount) * jitter[index]
            return min(1, max(0, raw))
        }
        lastWasFloor = false
        return values
    }

    /// A fresh utterance (or a release): every bar back to floor.
    ///
    /// The generator itself is deliberately *not* reseeded — two consecutive
    /// utterances should not wear the same jitter — but the deadlines are, so
    /// the first voiced tick of a press redraws every bar at once.
    public mutating func reset() {
        envelope = 0
        values = Array(repeating: 0, count: barCount)
        jitter = Array(repeating: 1, count: barCount)
        deadline = Array(repeating: 0, count: barCount)
        lastWasFloor = true
    }

    /// Age every deadline; redraw the bars whose turn has come.
    private mutating func advanceJitter(by tick: Double) {
        for index in 0..<barCount {
            deadline[index] -= tick
            guard deadline[index] <= 0 else { continue }
            jitter[index] = rng.uniform(BarSynthesizer.jitterLow, BarSynthesizer.jitterHigh)
            deadline[index] = rng.uniform(BarSynthesizer.retargetMin, BarSynthesizer.retargetMax)
        }
    }
}
