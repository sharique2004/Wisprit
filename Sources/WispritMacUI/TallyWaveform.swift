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

    /// The pill — one field in every state it has one.
    ///
    /// The compact and idle variants are gone. They existed because the meter
    /// used to change size with the frame: fifteen bars alone, seven beside a
    /// tail, five larger dots at rest. Frame measurement of the real Flow app
    /// says it does none of that — its idle capsule and its listening capsule
    /// are the same object, and the "idle dots" are the listening bars at
    /// floor. One field is both simpler and more faithful, and it is why
    /// `idle → listening` now needs no geometry change at all.
    public static let pill = TallyMetrics(
        barCount: PillGeometry.barCount, barWidth: PillGeometry.barWidth,
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

    /// The ink: first bar's left edge to last bar's right edge.
    ///
    /// This used to read `n × pitch − width`, which is the same number *only*
    /// when a bar is exactly half its pitch — true of the old 2.5-on-5 meter
    /// and false of Flowbar's 53 % duty cycle (2.25 on 4.25), where it
    /// overstated the field by a quarter point and pushed the row off centre.
    /// `(n − 1) × pitch + width` is the measurement itself and is right at any
    /// duty cycle.
    public func fieldWidth(count: Int) -> Double {
        guard count > 0 else { return 0 }
        return Double(count - 1) * barPitch + barWidth
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
        barRect(index: index, value: value, count: count, in: size, displayScale: 0)
    }

    /// The same rect, with the **field's** origin snapped to the backing
    /// store's pixel grid.
    ///
    /// Three things deliberately do not snap. The width would round a 2.25 pt
    /// bar to 2 px on a 1× display and take the whole field's proportions with
    /// it. The height would quantise the waveform into 1 pt steps, which is the
    /// one dimension the eye is actually reading. And the *pitch* must not:
    /// snapping each bar's own origin — which is what this used to do — is
    /// invisible while the pitch is an integer and turns a 4.25 pt pitch into
    /// an uneven 4, 4, 5, 4 row the moment it is not. Snapping the field once
    /// buys the row a hard left edge and leaves every derived dimension exact.
    ///
    /// `displayScale <= 0` means "don't", which is what the four-argument
    /// spelling above passes — the geometry every test asserts is untouched.
    public func barRect(index: Int, value: Double, count: Int,
                        in size: CGSize, displayScale: Double) -> CGRect {
        let field = fieldWidth(count: count)
        let originX = TallyMetrics.pixelAligned((size.width - field) / 2.0, scale: displayScale)
            + Double(index) * barPitch
        let h = barHeight(value)
        return CGRect(x: originX, y: (size.height - h) / 2.0, width: barWidth, height: h)
    }

    /// Round a point value onto a backing-store pixel boundary.
    public static func pixelAligned(_ value: Double, scale: Double) -> Double {
        guard scale > 0, value.isFinite else { return value }
        return (value * scale).rounded() / scale
    }
}

#if canImport(SwiftUI)
/// A capsule waveform in one `Canvas` — the **onboarding mic test's** meter.
///
/// The pill no longer draws through this. Its meter is `PillMeterLayerView`,
/// ten `CALayer` capsules the render server tweens between 20 Hz samples,
/// because the note that used to live here — "interpolating between frames
/// would double the draw rate to buy nothing the eye can see" — turned out to
/// be wrong twice over: the eye sees it plainly (it is the difference between
/// Wispr Flow's glide and our tick) and the Core Animation path measures 12.9 µs
/// a tick against ~95 µs for this raster.
///
/// It stays exactly as it is for the mic test, where the meter is a large
/// scrolling history the user is asked to *look at* rather than a live status
/// light, where nothing is competing for the main thread, and where one
/// `Canvas` with no view identity is still the right answer.
public struct TallyWaveform: View {
    /// Shaped 0…1 levels, oldest first — straight from `WaveformBuffer`.
    public var levels: [Double]
    public var metrics: TallyMetrics
    public var color: Color
    /// The backing-store scale, so the bars land on whole pixels at 1× and 2×
    /// alike. Read from the environment rather than passed, because every call
    /// site would otherwise have to remember to.
    @Environment(\.displayScale) private var displayScale

    public init(levels: [Double], metrics: TallyMetrics = .pill, color: Color) {
        self.levels = levels
        self.metrics = metrics
        self.color = color
    }

    public var body: some View {
        Canvas(opaque: false, colorMode: .nonLinear, rendersAsynchronously: false) { context, size in
            for (index, value) in levels.enumerated() {
                let rect = metrics.barRect(index: index, value: value,
                                           count: levels.count, in: size,
                                           displayScale: Double(displayScale))
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
