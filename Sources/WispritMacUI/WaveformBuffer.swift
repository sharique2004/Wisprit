import Foundation

/// The scrolling peak buffer behind the Tally — `docs/design/ui-redesign.md` §2.3.
///
/// The engine gives **one scalar at 20 Hz** (`AudioPort.level`, ticked by
/// `SessionController.startLevelTicker` at `levelTickInterval = 0.05`). Fifteen
/// bars all bouncing to the same scalar looks like a toy, so the waveform
/// scrolls instead: a fixed-slot ring, newest on the right, oldest falling off
/// the left.
///
/// Two properties are load-bearing:
///
/// - **Perceptual shaping.** A raw peak of 0.35 is a typical speech peak and
///   the voiced floor is 0.02, so the interesting signal lives in the bottom
///   third. `shaped` normalises against the reference and expands the quiet end
///   with a 0.7 gamma, then quantises to 1/64 — a step small enough to be
///   invisible and large enough that mic hiss cannot produce a redraw.
/// - **Silence is free.** `push` returns `false` once the incoming level and
///   every slot are at floor, and `PillModel` skips `emit()` in that case. The
///   main thread carries the CGEventTap; an idle-but-visible pill must cost
///   zero redraws or this redesign makes dictation worse.
public struct WaveformBuffer: Equatable, Sendable {
    /// Typical speech peak; the voiced floor is 0.02.
    public static let levelReference = 0.35
    /// Perceptual expansion of the quiet end.
    public static let gamma = 0.7
    /// Below this a push is a no-op.
    public static let quantum = 1.0 / 64.0

    /// Shaped levels, oldest first. Always `count == slots`.
    private var values: [Double]

    public init(slots: Int) {
        values = Array(repeating: 0, count: max(1, slots))
    }

    /// 0…1 per slot, oldest first.
    public var normalized: [Double] { values }

    public var slotCount: Int { values.count }

    /// True when every slot is at floor — the dot row (§2.2's `barFloor`).
    public var isSilent: Bool { values.allSatisfy { $0 == 0 } }

    /// Shift left, append the shaped level.
    ///
    /// Returns `false` when the shaped value is identical to the previous
    /// newest slot **and** every slot is already at floor — i.e. there is
    /// nothing to redraw. In that case the buffer is left untouched (shifting
    /// zeros through zeros is the same buffer anyway), so a silent pill is a
    /// pure no-op all the way down.
    @discardableResult
    public mutating func push(_ level: Double) -> Bool {
        let value = WaveformBuffer.shaped(level)
        if value == values[values.count - 1] && isSilent { return false }
        values.removeFirst()
        values.append(value)
        return true
    }

    /// All slots → floor. `showFinalizing` calls this: recording is over, so a
    /// held waveform would be a lie.
    public mutating func collapse() {
        for index in values.indices { values[index] = 0 }
    }

    /// The newest `n` slots, for the compact 7-bar meter that shares the pill
    /// with a text tail (§2.2's `barCountCompact`).
    public func newest(_ n: Int) -> [Double] {
        guard n < values.count else { return values }
        return Array(values.suffix(max(0, n)))
    }

    /// `clamp01(pow(clamp01(l / 0.35), 0.7))`, quantised to 1/64.
    ///
    /// NaN and infinity are silence rather than propagating into the frame
    /// maths — the same contract `PillGeometry.clampLevel` has had since the
    /// Python.
    public static func shaped(_ level: Double) -> Double {
        let normalized = PillGeometry.clampLevel(level / levelReference)
        guard normalized > 0 else { return 0 }
        let expanded = PillGeometry.clampLevel(pow(normalized, gamma))
        return (expanded / quantum).rounded() * quantum
    }
}
