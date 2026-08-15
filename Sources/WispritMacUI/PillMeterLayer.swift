import Foundation
#if canImport(AppKit)
import AppKit
import SwiftUI
#endif

/// One frame of meter state — the pure half of the 60 fps meter.
///
/// Everything the layer view needs, decided without AppKit so the decisions
/// (which tint, which duration, whether motion is allowed at all) are unit
/// tests rather than a screen recording. The view below does nothing but apply
/// one of these.
public struct PillMeterFrame: Equatable, Sendable {
    /// How a bar travels to its new height.
    public enum Curve: Equatable, Sendable {
        /// The level tween. Linear because both Wispr sources are linear —
        /// their Lottie's rect-size handles are (0.167, 0.167) → (0.833, 0.833)
        /// and their web demo takes `element.animate`'s linear default.
        case linear
        /// The release collapse: the row lands rather than stopping dead.
        case easeOut
    }

    /// Target heights, 0…1 shaped, one per bar, by *position* — bar `i` is
    /// bar `i` for the life of the pill. Empty means "no meter in this state".
    public var targets: [Double]
    public var tint: PillColor
    public var duration: Double
    public var curve: Curve
    /// False under Reduce Motion: the bars snap to their targets, the 20 Hz
    /// cadence survives, and nothing tweens. Durations survive, motion goes.
    public var animated: Bool
    /// Whether the processing spinner is running.
    public var spinning: Bool
    /// How long a tint change takes when one happens.
    public var tintDuration: Double

    public init(targets: [Double], tint: PillColor, duration: Double, curve: Curve,
                animated: Bool, spinning: Bool, tintDuration: Double) {
        self.targets = targets
        self.tint = tint
        self.duration = duration
        self.curve = curve
        self.animated = animated
        self.spinning = spinning
        self.tintDuration = tintDuration
    }

    /// The whole decision table, in one pure function.
    ///
    /// Both paths into the meter run through here — the 20 Hz sink that
    /// bypasses SwiftUI entirely, and the state-change path that arrives
    /// through `updateNSView` — so the two can never disagree about how a bar
    /// is supposed to move.
    public static func make(for render: PillRender, reduceMotion: Bool) -> PillMeterFrame {
        let live = (render.state == .prewarming || render.state == .recording)
        let processing = (render.state == .finalizing || render.state == .refining)
        return PillMeterFrame(
            targets: render.bars,
            tint: PillPalette.meterTint(for: render.state),
            // A live tick tweens over 200 ms and is overtaken by the next one
            // 50 ms later; a state change is a single, shorter, decisive move.
            duration: live ? PillMotion.meterTweenDuration : PillMotion.desaturateDuration,
            curve: live ? .linear : .easeOut,
            animated: !reduceMotion,
            spinning: processing && render.isVisible,
            tintDuration: live ? PillMotion.tintCrossfadeDuration : PillMotion.desaturateDuration)
    }
}

#if canImport(AppKit)

/// The meter, as ten `CALayer` capsules the render server animates.
///
/// **Why this is not a `Canvas` any more.** The level feed is 20 Hz and the
/// display is 60–120 Hz. Drawing one frame per sample is what made our pill
/// tick where Flow glides — and Flow's own code says so: their browser demo
/// samples every 50 ms and hands each sample to `element.animate({duration:
/// 300, fill: 'forwards'})`, so the compositor fills in the frames between.
/// This is that, in Core Animation.
///
/// **Why it is cheaper, not dearer.** Each tick reads the *presentation* height
/// of every bar, sets the model value to the new target, and adds one
/// `CABasicAnimation` from the former to the latter. Measured on this machine:
/// 12.9 µs per tick for ten bars — 0.026 % of one core at 20 Hz — against
/// ~95 µs to rasterise the same row on the CPU. Between ticks the process does
/// nothing at all; the render server interpolates out of process. The main
/// thread carries the CGEventTap, so that difference is the whole argument.
///
/// **Why reading `presentation()` matters.** It is what makes the motion
/// interruptible in the sense that counts here: a new target arriving mid-tween
/// starts from where the bar visibly *is*, not from where the last tween was
/// headed. Speech retargets these bars four times a second and never once
/// produces a jump.
public final class PillMeterLayerView: NSView {
    private var bars: [CALayer] = []
    private var applied: PillMeterFrame?
    private let metrics = TallyMetrics.pill

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.masksToBounds = false
        buildBars()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used — the pill is built in code")
    }

    public override var isFlipped: Bool { false }
    public override var mouseDownCanMoveWindow: Bool { true }
    public override var isOpaque: Bool { false }
    /// A status light, never a control.
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        layer?.contentsScale = scale
        for bar in bars { bar.contentsScale = scale }
    }

    private func buildBars() {
        guard let host = layer else { return }
        for _ in 0..<PillGeometry.barCount {
            let bar = CALayer()
            bar.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            bar.bounds = CGRect(x: 0, y: 0, width: metrics.barWidth, height: metrics.floor)
            bar.cornerRadius = metrics.cornerRadius
            bar.backgroundColor = PillMeterLayerView.cgColor(PillPalette.cream, alpha: metrics.barAlpha(0))
            // Risk 4 of the brief: `presentation()` is nil until the layer has
            // been committed once. Starting at floor means the fallback is the
            // dot row, which is also where every utterance begins — so the
            // worst case is no jump at all.
            host.addSublayer(bar)
            bars.append(bar)
        }
    }

    public override func layout() {
        super.layout()
        // Repositioning is not motion: a width change must not drag the bars
        // across the capsule over 250 ms of implicit animation.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // The field's origin snaps to the pixel grid; the pitch does not — see
        // `TallyMetrics.barRect`, which makes the same call for the mic test.
        let field = metrics.fieldWidth(count: bars.count)
        let originX = TallyMetrics.pixelAligned((bounds.width - field) / 2,
                                                scale: Double(window?.backingScaleFactor ?? 0))
        for (index, bar) in bars.enumerated() {
            bar.position = CGPoint(x: originX + Double(index) * metrics.barPitch
                                       + metrics.barWidth / 2,
                                   y: bounds.midY)
        }
        CATransaction.commit()
    }

    /// One meter frame. The only per-tick work the main thread does during
    /// dictation.
    public func apply(_ frame: PillMeterFrame) {
        guard !frame.targets.isEmpty else { return }
        let tintChanged = applied?.tint != frame.tint
        defer { applied = frame }

        for (index, bar) in bars.enumerated() {
            let value = index < frame.targets.count ? frame.targets[index] : 0
            let height = metrics.barHeight(value)
            let alpha = metrics.barAlpha(value)
            // The interruptible read: start from where the bar *is*, not from
            // where the last tween was going.
            let fromHeight = bar.presentation()?.bounds.height ?? bar.bounds.height
            let fromAlpha = bar.presentation()?.opacity ?? bar.opacity

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            bar.bounds.size.height = height
            bar.opacity = Float(alpha)
            if tintChanged || applied == nil {
                bar.backgroundColor = PillMeterLayerView.cgColor(frame.tint, alpha: 1)
            }
            CATransaction.commit()

            guard frame.animated else {
                bar.removeAnimation(forKey: "height")
                bar.removeAnimation(forKey: "alpha")
                continue
            }
            add(to: bar, key: "height", path: "bounds.size.height",
                from: fromHeight, to: height, frame: frame)
            add(to: bar, key: "alpha", path: "opacity",
                from: Double(fromAlpha), to: alpha, frame: frame)
            if tintChanged {
                let fade = CABasicAnimation(keyPath: "backgroundColor")
                fade.duration = frame.tintDuration
                fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                bar.add(fade, forKey: "tint")
            }
        }
    }

    private func add(to layer: CALayer, key: String, path: String,
                     from: Double, to: Double, frame: PillMeterFrame) {
        guard from != to else { return }
        let animation = CABasicAnimation(keyPath: path)
        animation.fromValue = from
        animation.toValue = to
        animation.duration = frame.duration
        animation.timingFunction = CAMediaTimingFunction(
            name: frame.curve == .linear ? .linear : .easeOut)
        layer.add(animation, forKey: key)
    }

    static func cgColor(_ color: PillColor, alpha: Double) -> CGColor {
        CGColor(srgbRed: color.r, green: color.g, blue: color.b, alpha: alpha)
    }
}

/// The processing spinner: eight ticks stepping 45° every 110 ms.
///
/// A `CAReplicatorLayer` and one repeating discrete keyframe animation, which
/// means a wait of any length — a batch rescue can run for seconds — costs the
/// main thread exactly nothing after the first frame. It replaces the crest
/// wave that used to cross the dot row: that was the element the user judged
/// worst, and the real Flow app puts a spinner here.
public final class PillSpinnerLayerView: NSView {
    private let replicator = CAReplicatorLayer()
    private var running = false

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used — the pill is built in code")
    }

    public override var mouseDownCanMoveWindow: Bool { true }
    public override var isOpaque: Bool { false }
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func build() {
        guard let host = layer else { return }
        let box = PillGeometry.spinnerBox
        replicator.bounds = CGRect(x: 0, y: 0, width: box, height: box)
        replicator.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        replicator.instanceCount = PillGeometry.spinnerTicks
        replicator.instanceTransform = CATransform3DMakeRotation(
            2 * .pi / Double(PillGeometry.spinnerTicks), 0, 0, 1)
        // Graded around the circle: brightest at the head, dimmest behind it,
        // which is what makes a discrete step read as rotation rather than as
        // eight lights blinking.
        replicator.instanceAlphaOffset =
            Float(-(1 - PillGeometry.spinnerMinAlpha) / Double(PillGeometry.spinnerTicks - 1))
        replicator.opacity = 0

        let tick = CALayer()
        tick.bounds = CGRect(x: 0, y: 0,
                             width: PillGeometry.spinnerTickWidth,
                             height: PillGeometry.spinnerTickLength)
        tick.cornerRadius = PillGeometry.spinnerTickWidth / 2
        tick.backgroundColor = PillMeterLayerView.cgColor(PillPalette.muted, alpha: 1)
        // The tick's *outer* end sits on the box edge, so the eight of them
        // read as a ring rather than as a starburst crowded around the middle.
        tick.position = CGPoint(x: box / 2,
                                y: box - PillGeometry.spinnerTickLength / 2)
        replicator.addSublayer(tick)
        host.addSublayer(replicator)
    }

    public override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        replicator.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }

    public func setSpinning(_ spinning: Bool, animated: Bool) {
        guard spinning != running else { return }
        running = spinning

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        replicator.opacity = spinning ? 1 : 0
        CATransaction.commit()

        if spinning {
            let step = CAKeyframeAnimation(keyPath: "transform.rotation.z")
            let ticks = PillGeometry.spinnerTicks
            step.values = (0...ticks).map { 2 * Double.pi * Double($0) / Double(ticks) }
            step.calculationMode = .discrete
            step.duration = PillMotion.spinnerRevolution
            step.repeatCount = .greatestFiniteMagnitude
            // Reduce Motion still gets a spinner — it is a status light, and
            // the alternative is a state with nothing in it — but it holds one
            // still frame instead of stepping.
            if animated { replicator.add(step, forKey: "spin") }
            if animated {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0
                fade.toValue = 1
                fade.duration = PillMotion.spinnerFadeIn
                fade.beginTime = CACurrentMediaTime() + PillMotion.spinnerFadeInDelay
                fade.fillMode = .backwards
                replicator.add(fade, forKey: "fade")
            }
        } else {
            replicator.removeAnimation(forKey: "spin")
            guard animated else { return }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            fade.duration = PillMotion.spinnerFadeOut
            replicator.add(fade, forKey: "fade")
        }
    }
}

// MARK: - the SwiftUI edge

/// The meter inside `PillSurface`.
///
/// Two things happen in `makeNSView` and both are load-bearing: the view is
/// built exactly once, and it registers itself as `PillRenderBox.meterSink` so
/// that `Pill.apply` can hand it a level tick *without* writing the box — which
/// is what keeps the SwiftUI view tree completely inert during dictation.
public struct PillMeterView: NSViewRepresentable {
    private let frame: PillMeterFrame
    private let box: PillRenderBox

    public init(frame: PillMeterFrame, box: PillRenderBox) {
        self.frame = frame
        self.box = box
    }

    public final class Coordinator {
        let box: PillRenderBox
        init(box: PillRenderBox) { self.box = box }
    }

    public func makeCoordinator() -> Coordinator { Coordinator(box: box) }

    public func makeNSView(context: Context) -> PillMeterLayerView {
        let view = PillMeterLayerView(frame: .zero)
        view.apply(frame)
        context.coordinator.box.meterSink = { [weak view] render in
            guard let view else { return false }
            // Read the accessibility flag from the same system signal
            // `PillSurface` reads through the environment: this path never
            // touches SwiftUI, so it cannot inherit it.
            view.apply(PillMeterFrame.make(
                for: render,
                reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion))
            return true
        }
        return view
    }

    public func updateNSView(_ view: PillMeterLayerView, context: Context) {
        view.apply(frame)
    }

    public static func dismantleNSView(_ view: PillMeterLayerView, coordinator: Coordinator) {
        coordinator.box.meterSink = nil
    }
}

/// The spinner inside `PillSurface`.
public struct PillSpinnerView: NSViewRepresentable {
    private let spinning: Bool
    private let animated: Bool

    public init(spinning: Bool, animated: Bool) {
        self.spinning = spinning
        self.animated = animated
    }

    public func makeNSView(context: Context) -> PillSpinnerLayerView {
        let view = PillSpinnerLayerView(frame: .zero)
        view.setSpinning(spinning, animated: animated)
        return view
    }

    public func updateNSView(_ view: PillSpinnerLayerView, context: Context) {
        view.setSpinning(spinning, animated: animated)
    }
}
#endif
