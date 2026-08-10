import Foundation
#if canImport(SwiftUI)
import SwiftUI
#endif

/// The Tally's geometry — `docs/design/ui-redesign.md` §2.2 and §7.
///
/// One component at three scales: 28 pt in the pill and inline in the practice
/// step, 44 pt in the onboarding mic test, and a degenerate single-bar 6 pt dot
/// in the Hub sidebar footer. Every dimension is derived from the height, which
/// is why the three scales look like the same instrument rather than three
/// meters that happen to share a colour.
public struct TallyMetrics: Equatable, Sendable {
    /// Bars at full width. A caller may draw fewer (the pill's compact meter);
    /// the field narrows with them.
    public var barCount: Int
    public var barWidth: Double
    public var barPitch: Double
    public var height: Double
    /// Full-scale bar height.
    public var peak: Double
    /// Silent bar height. `floor == barWidth` makes silence a perfect dot.
    public var floor: Double

    public init(barCount: Int, barWidth: Double, barPitch: Double,
                height: Double, peak: Double, floor: Double) {
        self.barCount = barCount
        self.barWidth = barWidth
        self.barPitch = barPitch
        self.height = height
        self.peak = peak
        self.floor = floor
    }

    /// The pill, and inline in the practice step.
    public static let pill = TallyMetrics(
        barCount: PillGeometry.barCount, barWidth: PillGeometry.barWidth,
        barPitch: PillGeometry.barPitch, height: PillGeometry.height,
        peak: PillGeometry.barPeak, floor: PillGeometry.barFloor)

    /// The pill sharing its capsule with a text tail.
    public static let pillCompact = TallyMetrics(
        barCount: PillGeometry.barCountCompact, barWidth: PillGeometry.barWidth,
        barPitch: PillGeometry.barPitch, height: PillGeometry.height,
        peak: PillGeometry.barPeak, floor: PillGeometry.barFloor)

    /// The onboarding mic test (§4.2 step 3).
    public static let micTest = TallyMetrics(
        barCount: 33, barWidth: 4, barPitch: 9, height: 44, peak: 22, floor: 4)

    /// The sidebar status dot: one bar, always at floor, tinted by state.
    public static let dot = TallyMetrics(
        barCount: 1, barWidth: 6, barPitch: 6, height: 6, peak: 6, floor: 6)

    /// Bars are fully-rounded capsules.
    public var cornerRadius: Double { barWidth / 2.0 }

    /// `n × pitch − width` — the trailing half-gap does not belong to the field.
    public func fieldWidth(count: Int) -> Double {
        guard count > 0 else { return 0 }
        return Double(count) * barPitch - barWidth
    }

    public var fieldWidth: Double { fieldWidth(count: barCount) }

    /// Bar height for a shaped 0…1 level: `floor + (peak − floor) × v`.
    public func barHeight(_ value: Double) -> Double {
        floor + (peak - floor) * PillGeometry.clampLevel(value)
    }

    /// `0.45 + 0.55 × v`, so silence recedes to dim dots and speech is full
    /// tint (§2.3).
    public func barAlpha(_ value: Double) -> Double {
        0.45 + 0.55 * PillGeometry.clampLevel(value)
    }

    /// One bar's rect, centred on the vertical midline and growing
    /// symmetrically up and down, with the whole field centred horizontally.
    public func barRect(index: Int, value: Double, count: Int, in size: CGSize) -> CGRect {
        let field = fieldWidth(count: count)
        let originX = (size.width - field) / 2.0 + Double(index) * barPitch
        let h = barHeight(value)
        return CGRect(x: originX, y: (size.height - h) / 2.0, width: barWidth, height: h)
    }
}

#if canImport(SwiftUI)
/// The signature component: a live capsule waveform, scrolling right-to-left,
/// collapsing to a row of perfect dots at silence.
///
/// **One `Canvas`, one draw pass, no view identity.** Fifteen `RoundedRectangle`
/// views re-identified at 20 Hz on the same main thread that carries the
/// CGEventTap is the one way this redesign could make dictation worse (§2.7).
///
/// There is no implicit animation on the bar heights either, and that is not an
/// omission: the level ticker delivers a frame every 50 ms, which *is* the
/// spec's 50 ms linear tick. Interpolating between frames would double the
/// draw rate to buy nothing the eye can see.
public struct TallyWaveform: View {
    /// Shaped 0…1 levels, oldest first — straight from `WaveformBuffer`.
    public var levels: [Double]
    public var metrics: TallyMetrics
    public var color: Color

    public init(levels: [Double], metrics: TallyMetrics = .pill, color: Color) {
        self.levels = levels
        self.metrics = metrics
        self.color = color
    }

    public var body: some View {
        Canvas(opaque: false, colorMode: .nonLinear, rendersAsynchronously: false) { context, size in
            for (index, value) in levels.enumerated() {
                let rect = metrics.barRect(index: index, value: value,
                                           count: levels.count, in: size)
                context.fill(Path(roundedRect: rect, cornerRadius: metrics.cornerRadius),
                             with: .color(color.opacity(metrics.barAlpha(value))))
            }
        }
        .frame(width: metrics.fieldWidth(count: levels.count), height: metrics.height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
#endif
