import CoreGraphics
import Foundation

/// A damped spring, integrated in fixed sub-steps so the result does not
/// depend on the frame rate.
///
/// Parameterised the way SwiftUI's `spring(response:dampingFraction:)` is:
/// `response` is the undamped period in seconds, `damping` the fraction of
/// critical. 1.0 never overshoots; 0.7 overshoots by ~4.6 %.
public struct NotchSpring: Equatable, Sendable {
    public var value: Double
    public var velocity: Double = 0
    public var target: Double
    public var response: Double
    public var damping: Double

    public init(_ value: Double, response: Double, damping: Double) {
        self.value = value
        self.target = value
        self.response = response
        self.damping = damping
    }

    /// Integrate `dt` seconds. A stall longer than 0.1 s is treated as 0.1 s:
    /// a frame clock that slept should resume motion, not teleport through it.
    public mutating func step(_ dt: Double) {
        guard dt > 0, response > 0 else { return }
        let stiffness = pow(2 * .pi / response, 2)
        let friction = 4 * .pi * damping / response
        var remaining = min(dt, 0.1)
        let h = 1.0 / 240.0
        while remaining > 1e-9 {
            let s = min(h, remaining)
            let accel = -stiffness * (value - target) - friction * velocity
            velocity += accel * s
            value += velocity * s
            remaining -= s
        }
    }

    public mutating func snap(to value: Double) {
        self.value = value
        target = value
        velocity = 0
    }

    public var isSettled: Bool { abs(value - target) < 0.002 && abs(velocity) < 0.02 }
}

/// The left wing's symbol, when it is not the tally dot.
public enum NotchGlyph: String, Equatable, Sendable, CaseIterable {
    /// Refining: the Apple Intelligence pass.
    case sparkle
    /// Missed: "didn't catch that".
    case question
    /// Too quiet: speak up.
    case faint
    /// Error.
    case exclamation
    /// Blocked by Secure Keyboard Entry.
    case lock

    /// SF Symbol name.
    public var symbolName: String {
        switch self {
        case .sparkle: return "sparkle"
        case .question: return "questionmark"
        case .faint: return "ear"
        case .exclamation: return "exclamationmark"
        case .lock: return "lock.fill"
        }
    }
}

/// The notch's colours. Every value is the **dark** side of a `Theme` token —
/// the body is pure black in both appearances, like the hardware it extends.
public enum NotchPalette {
    private static func dark(_ token: ColorToken) -> PillColor { PillColor(hex: token.dark) }

    /// The body. Pure black, not `studio`: it has to be indistinguishable from
    /// the camera housing it grows out of.
    public static let body = PillColor(0, 0, 0)
    /// Mic-orange. Only `listening(micLive: true)` may produce it.
    public static let hot = dark(Theme.Token.hot)
    public static let ink = dark(Theme.Token.studioInk)
    public static let muted = dark(Theme.Token.studioMuted)
    public static let positive = dark(Theme.Token.positive)
    public static let attention = dark(Theme.Token.attention)
    public static let critical = dark(Theme.Token.critical)
    public static let rim = PillColor(1, 1, 1)

    /// The glyph colour each result wears.
    public static func tint(for result: NotchResult) -> PillColor {
        switch result {
        case .success: return positive
        case .missed: return muted
        case .tooQuiet, .blockedSecure: return attention
        case .error: return critical
        }
    }
}

/// One frame, decided without AppKit. `NotchIndicatorView.apply` does nothing
/// but copy these numbers onto layers; tests and the offscreen renderer read
/// them directly.
public struct NotchFrame: Equatable, Sendable {
    public struct Bar: Equatable, Sendable {
        public var height: CGFloat
        public var color: PillColor
        public var alpha: Double
    }

    public struct Glyph: Equatable, Sendable {
        public var kind: NotchGlyph
        public var color: PillColor
        public var alpha: Double
        public var scale: Double
    }

    /// Body, panel-local. Top edge is always `layout.top`.
    public var bodyWidth: CGFloat = 0
    public var bodyHeight: CGFloat = 0
    /// Horizontal shake.
    public var offsetX: CGFloat = 0
    public var shoulder: CGFloat = 0
    public var bodyAlpha: Double = 0
    /// Increase Contrast rim.
    public var rimAlpha: Double = 0

    public var leftCenter: CGPoint = .zero
    public var rightCenter: CGPoint = .zero

    /// The tally dot.
    public var dotDiameter: CGFloat = 0
    public var dotColor: PillColor = NotchPalette.muted
    public var dotAlpha: Double = 0
    public var haloDiameter: CGFloat = 0
    public var haloAlpha: Double = 0
    /// The tally ring: one ripple off the dot the instant the mic opens.
    public var ringDiameter: CGFloat = 0
    public var ringAlpha: Double = 0

    /// Warmth under the meter while the voice is up — live mic only.
    public var meterGlowAlpha: Double = 0

    /// Outgoing and incoming symbols (a crossfade has two).
    public var glyphs: [Glyph] = []
    /// The success check, drawn on as a stroke.
    public var checkProgress: Double = 0
    public var checkAlpha: Double = 0

    public var bars: [Bar] = []

    /// A soft glow behind both wings' content on alarm results.
    public var washColor: PillColor = NotchPalette.critical
    public var washAlpha: Double = 0

    /// Whether any element would be visible at all.
    public var isBlank: Bool { bodyAlpha < 0.001 || bodyWidth < 0.5 || bodyHeight < 0.5 }

    /// Every colour drawn with meaningful alpha this frame — what the orange
    /// rule is checked against.
    public var visibleColors: [PillColor] {
        var colors: [PillColor] = []
        if dotAlpha > 0.02 { colors.append(dotColor) }
        if haloAlpha > 0.02 { colors.append(dotColor) }
        if ringAlpha > 0.02 { colors.append(NotchPalette.hot) }
        if meterGlowAlpha > 0.02 { colors.append(NotchPalette.hot) }
        for glyph in glyphs where glyph.alpha > 0.02 { colors.append(glyph.color) }
        if checkAlpha > 0.02 { colors.append(NotchPalette.positive) }
        for bar in bars where bar.alpha > 0.02 { colors.append(bar.color) }
        if washAlpha > 0.02 { colors.append(washColor) }
        return colors
    }
}

/// Phase in, frames out.
///
/// Holds every spring the notch animates and knows each phase's pose. It is a
/// value with no clock: `step(to:…)` is handed the time, so the app drives it
/// from a display link, the tests from a loop, and the offscreen renderer from
/// a script — and all three see the same frames.
public struct NotchChoreography: Equatable, Sendable {

    // MARK: - timing (docs/design/notch-listening.md §Motion)

    /// Open: a little elastic, like the Dynamic Island — ~4 % overshoot —
    /// launched with a kick so the first 30 ms already move.
    public static let openResponse = 0.36
    public static let openDamping = 0.72
    public static let openKick = 3.2
    /// The tally ring's life.
    public static let ringDuration = 0.55
    /// Fold: no bounce, slightly quicker. Content leaves first.
    public static let foldResponse = 0.30
    public static let foldDamping = 1.0
    /// How long the fold waits for the content to fade before the body moves.
    public static let foldLead = 0.07
    /// Bars: lively but never jittery.
    public static let barResponse = 0.13
    public static let barDamping = 0.6
    /// Level envelope time constants.
    public static let attackTau = 0.035
    public static let releaseTau = 0.16
    /// Colour crossfades.
    public static let tintDuration = 0.18
    /// Silence still breathes: a slow swell travelling across the bars.
    public static let breathPeriod = 2.2
    public static let breathFloor = 0.05
    public static let breathDepth = 0.13
    /// The processing ripple.
    public static let finalizingPeriod = 1.05
    public static let refiningPeriod = 1.5

    public let layout: NotchLayout
    public var reduceMotion: Bool
    public var increaseContrast: Bool

    private var open = NotchSpring(0, response: openResponse, damping: openDamping)
    private var content = NotchSpring(0, response: 0.16, damping: 1)
    /// Reduce Motion's stand-in for the morph: the body cross-fades instead.
    private var fade = NotchSpring(0, response: 0.2, damping: 1)
    private var dotPresence = NotchSpring(0, response: 0.18, damping: 1)
    private var dotLive = NotchSpring(0, response: 0.16, damping: 1)
    private var dotScale = NotchSpring(1, response: 0.3, damping: 0.5)
    private var check = NotchSpring(0, response: 0.3, damping: 1)
    private var wash = NotchSpring(0, response: 0.22, damping: 1)
    private var bars: [NotchSpring]
    private var envelope: Double = 0

    private var glyphCurrent: NotchGlyph?
    private var glyphPrevious: NotchGlyph?
    private var glyphMix = NotchSpring(1, response: 0.2, damping: 1)
    private var glyphPop = NotchSpring(1, response: 0.28, damping: 0.55)

    private var barColorFrom = NotchPalette.muted
    private var barColorTo = NotchPalette.muted
    private var barColorStart: TimeInterval = -1

    private var lastPhase: NotchPhase = .hidden
    private var lastGeneration = 0
    private var micOpenedAt: TimeInterval?
    private var phaseStart: TimeInterval = 0
    private var lastTime: TimeInterval?

    public init(layout: NotchLayout, reduceMotion: Bool = false, increaseContrast: Bool = false) {
        self.layout = layout
        self.reduceMotion = reduceMotion
        self.increaseContrast = increaseContrast
        self.bars = Array(repeating: NotchSpring(0, response: Self.barResponse, damping: Self.barDamping),
                          count: layout.bars.count)
    }

    /// True once a fold has finished: nothing left on screen.
    public var isFolded: Bool {
        let shape = reduceMotion ? fade.value : open.value
        return shape < 0.02 && content.value < 0.02 && lastPhase == .collapsing
    }

    /// How far open the body is, 0…1 (can briefly exceed 1 on the spring).
    public var openness: Double { reduceMotion ? fade.value : open.value }

    // MARK: - stepping

    /// Advance to `now` for the lifecycle's current state and return the frame.
    public mutating func step(to now: TimeInterval, lifecycle: NotchLifecycle) -> NotchFrame {
        let dt = lastTime.map { max(0, now - $0) } ?? 0
        lastTime = now
        if lifecycle.phase != lastPhase || lifecycle.generation != lastGeneration {
            transition(from: lastPhase, to: lifecycle.phase,
                       newUtterance: lifecycle.generation != lastGeneration, at: now)
            lastPhase = lifecycle.phase
            lastGeneration = lifecycle.generation
        }
        let t = now - phaseStart

        // The envelope: fast attack, slower release, frame-rate independent.
        let target = isListening ? WaveformBuffer.shaped(lifecycle.level) : 0
        let tau = target > envelope ? Self.attackTau : Self.releaseTau
        envelope += (target - envelope) * (dt > 0 ? 1 - exp(-dt / tau) : 0)
        if target == 0 && envelope < 0.002 { envelope = 0 }

        setTargets(at: now, t: t)
        open.step(dt); content.step(dt); fade.step(dt)
        dotPresence.step(dt); dotLive.step(dt); dotScale.step(dt)
        check.step(dt); wash.step(dt); glyphMix.step(dt); glyphPop.step(dt)
        for index in bars.indices { bars[index].step(dt) }
        if reduceMotion {
            open.snap(to: open.target)
            dotScale.snap(to: 1)
            glyphPop.snap(to: 1)
            for index in bars.indices { bars[index].snap(to: bars[index].target) }
        }
        return frame(at: now, t: t)
    }

    private var isListening: Bool {
        if case .listening = lastPhase { return true }
        return false
    }

    private mutating func transition(from old: NotchPhase, to new: NotchPhase,
                                     newUtterance: Bool, at now: TimeInterval) {
        phaseStart = now
        switch new {
        case .hidden:
            // Gone: everything back to rest so the next open starts folded.
            open.snap(to: 0); content.snap(to: 0); fade.snap(to: 0)
            dotPresence.snap(to: 0); dotLive.snap(to: 0); check.snap(to: 0); wash.snap(to: 0)
            for index in bars.indices { bars[index].snap(to: 0) }
            envelope = 0
            micOpenedAt = nil
            glyphCurrent = nil
            glyphPrevious = nil
            barColorFrom = NotchPalette.muted
            barColorTo = NotchPalette.muted
            barColorStart = -1
        case .listening(let live):
            if newUtterance { check.snap(to: 0); envelope = 0; micOpenedAt = nil }
            kickOpen(from: old)
            setGlyph(nil)
            retint(to: live ? NotchPalette.hot : NotchPalette.muted, at: now)
            if live, micOpenedAt == nil {
                // The tally comes on: the dot pops as it turns orange and
                // sends one ring out — "I can hear you", once per press.
                micOpenedAt = now
                if old != .hidden {
                    dotScale.value = 0.55
                    dotScale.velocity = 0
                }
            }
        case .processing(let stage):
            setGlyph(stage == .refining ? .sparkle : nil)
            retint(to: NotchPalette.ink, at: now)
            kickOpen(from: old)
        case .result(let kind):
            setGlyph(glyph(for: kind))
            retint(to: NotchPalette.tint(for: kind), at: now)
            check.snap(to: 0)
            if old == .hidden || old == .collapsing {
                kickOpen(from: old)
            } else if kind == .success {
                // A beat: the body breathes out a touch as the check lands.
                open.velocity += 0.9
            }
        case .collapsing:
            open.response = Self.foldResponse
            open.damping = Self.foldDamping
        }
    }

    /// Springs back to the open tuning; from rest, with a launch velocity.
    private mutating func kickOpen(from old: NotchPhase) {
        open.response = Self.openResponse
        open.damping = Self.openDamping
        if old == .hidden || old == .collapsing, open.value < 0.5 {
            open.velocity = max(open.velocity, Self.openKick)
        }
    }

    private func glyph(for result: NotchResult) -> NotchGlyph? {
        switch result {
        case .success: return nil      // the drawn check
        case .missed: return .question
        case .tooQuiet: return .faint
        case .error: return .exclamation
        case .blockedSecure: return .lock
        }
    }

    private mutating func setGlyph(_ next: NotchGlyph?) {
        guard next != glyphCurrent else { return }
        glyphPrevious = glyphCurrent
        glyphCurrent = next
        glyphMix.snap(to: 0)
        glyphMix.target = 1
        if next != nil {
            glyphPop.value = 0.6
            glyphPop.velocity = 0
            glyphPop.target = 1
        }
    }

    private mutating func retint(to color: PillColor, at now: TimeInterval) {
        guard color != barColorTo else { return }
        barColorFrom = currentBarColor(at: now)
        barColorTo = color
        barColorStart = now
    }

    private func currentBarColor(at now: TimeInterval) -> PillColor {
        guard barColorStart >= 0 else { return barColorTo }
        let u = min(1, max(0, (now - barColorStart) / Self.tintDuration))
        return barColorFrom.mixed(with: barColorTo, smoothstep(u))
    }

    // MARK: - poses

    private mutating func setTargets(at now: TimeInterval, t: Double) {
        let n = bars.count
        switch lastPhase {
        case .hidden:
            open.target = 0; content.target = 0; fade.target = 0
        case .listening(let live):
            open.target = 1; content.target = 1; fade.target = 1
            dotPresence.target = 1
            dotLive.target = live ? 1 : 0
            dotScale.target = 1
            check.target = 0
            wash.target = 0
            for i in 0..<n { bars[i].target = listeningFraction(i, count: n, now: now) }
        case .processing(let stage):
            open.target = 1; content.target = 1; fade.target = 1
            dotPresence.target = stage == .refining ? 0 : 1
            dotLive.target = 0
            dotScale.target = stage == .refining ? 0.7 : 0.78
            check.target = 0
            wash.target = 0
            let period = stage == .refining ? Self.refiningPeriod : Self.finalizingPeriod
            for i in 0..<n { bars[i].target = rippleFraction(i, count: n, now: now, period: period) }
        case .result(let kind):
            open.target = 1; content.target = 1; fade.target = 1
            dotPresence.target = 0
            dotLive.target = 0
            check.target = kind == .success ? 1 : 0
            switch kind {
            case .error: wash.target = 0.34
            case .blockedSecure: wash.target = 0.2
            case .tooQuiet: wash.target = 0.12
            case .success, .missed: wash.target = 0
            }
            for i in 0..<n { bars[i].target = resultFraction(kind, i, count: n, t: t) }
        case .collapsing:
            // Content leaves first; the body follows `foldLead` later.
            content.target = 0
            fade.target = 0
            open.target = t >= Self.foldLead || content.value < 0.5 ? 0 : open.target
            for i in 0..<n { bars[i].target = 0 }
            wash.target = 0
        }
    }

    /// Silence breathes; speech dances. Both in fractions of the bar's travel.
    private func listeningFraction(_ i: Int, count n: Int, now: Double) -> Double {
        if reduceMotion {
            return 0.2 * Self.arch(i, count: n)
        }
        let breath = Self.breathFloor + Self.breathDepth
            * (0.5 + 0.5 * sin(2 * .pi * now / Self.breathPeriod - Double(i) * 0.8))
        // Per-bar wobble from two incommensurate sines: alive at a steady
        // level, never periodic enough to read as a loop.
        let f1 = 2.1 + 0.53 * Double(i)
        let f2 = 3.3 + 0.71 * Double((i * 3) % max(1, n))
        let wobble = 0.5 + 0.5 * (0.6 * sin(2 * .pi * f1 * now + Double(i) * 1.7)
                                  + 0.4 * sin(2 * .pi * f2 * now + Double(i) * 0.6))
        let speech = envelope * Self.arch(i, count: n) * (0.32 + 0.68 * wobble)
        return breath + (1 - breath) * speech
    }

    /// A bright bump travelling left to right: "working", without orange.
    private func rippleFraction(_ i: Int, count n: Int, now: Double, period: Double) -> Double {
        if reduceMotion { return 0.18 }
        return 0.1 + 0.26 * ripple(i, count: n, now: now, period: period)
    }

    private func ripple(_ i: Int, count n: Int, now: Double, period: Double) -> Double {
        // The bump spends ~60 % of the period crossing the row, then rests.
        let phase = (now / period).truncatingRemainder(dividingBy: 1)
        let position = phase * 1.6 - 0.3
        let x = Double(i) / Double(max(1, n - 1))
        let d = (x - position) / 0.26
        return exp(-d * d)
    }

    private func resultFraction(_ kind: NotchResult, _ i: Int, count n: Int, t: Double) -> Double {
        if reduceMotion { return 0 }
        switch kind {
        case .success:
            // A nod: the row lifts together, staggered from the centre, then
            // settles to dots under the check.
            let centre = Double(n - 1) / 2
            let delay = abs(Double(i) - centre) * 0.03
            return t - delay < 0.14 ? 0.42 * Self.arch(i, count: n) : 0
        case .tooQuiet:
            return 0.1 * Self.arch(i, count: n)
        case .missed, .error, .blockedSecure:
            return 0
        }
    }

    /// The dome: edges at 56 % of the centre, as the pill's measured meter.
    public static func arch(_ index: Int, count: Int) -> Double {
        BarSynthesizer.arch(index, count: count)
    }

    /// Horizontal shake for the alarm beats: a decaying sine.
    static func shake(for phase: NotchPhase, t: Double) -> Double {
        guard case .result(let kind) = phase else { return 0 }
        let amplitude: Double
        let frequency: Double
        switch kind {
        case .error: amplitude = 3.5; frequency = 9
        case .missed: amplitude = 2.2; frequency = 7.5
        case .success, .tooQuiet, .blockedSecure: return 0
        }
        guard t >= 0, t < 0.5 else { return 0 }
        return amplitude * exp(-t / 0.15) * sin(2 * .pi * frequency * t)
    }

    // MARK: - the frame

    private func frame(at now: TimeInterval, t: Double) -> NotchFrame {
        var f = NotchFrame()
        let L = layout
        let shape = reduceMotion ? max(0, min(1, fade.value > 0.001 ? 1 : 0)) : open.value
        let clamped = min(max(shape, 0), 1)
        f.bodyWidth = L.footprint.width + (L.expanded.width - L.footprint.width) * CGFloat(shape)
        f.bodyHeight = L.footprint.height + (L.expanded.height - L.footprint.height) * CGFloat(clamped)
        f.bodyHeight = min(f.bodyHeight, L.band)
        f.shoulder = L.shoulderRadius * CGFloat(clamped)
        f.bodyAlpha = reduceMotion ? fade.value : (shape > 0.001 ? 1 : 0)
        f.offsetX = reduceMotion ? 0 : CGFloat(Self.shake(for: lastPhase, t: t))
        f.rimAlpha = increaseContrast ? 0.5 * f.bodyAlpha * clamped : 0

        // Content rides the edges: on a notched display it slides out from
        // behind the housing as the wing grows.
        let cx = L.centerX + f.offsetX
        let midY = L.top - (L.hugsNotch ? L.expanded.height : f.bodyHeight) / 2
        f.leftCenter = CGPoint(x: cx - f.bodyWidth / 2 + L.contentInset, y: midY)
        f.rightCenter = CGPoint(x: cx + f.bodyWidth / 2 - L.contentInset, y: midY)
        let reveal = reduceMotion ? fade.value : smoothstep((shape - 0.3) / 0.5)
        let contentAlpha = content.value * reveal

        // The tally dot and its halo.
        let live = dotLive.value
        f.dotColor = NotchPalette.muted.mixed(with: NotchPalette.hot, live)
        f.dotDiameter = 8 * CGFloat(max(0, dotScale.value))
        f.dotAlpha = contentAlpha * dotPresence.value * (0.75 + 0.25 * live)
        f.haloAlpha = contentAlpha * dotPresence.value * live * (0.16 + 0.6 * envelope)
        f.haloDiameter = 12 + 14 * CGFloat(envelope)
        if let opened = micOpenedAt, isListening, !reduceMotion {
            let u = (now - opened) / Self.ringDuration
            if u >= 0, u < 1 {
                let eased = 1 - pow(1 - u, 3)
                f.ringDiameter = 8 + 18 * CGFloat(eased)
                f.ringAlpha = contentAlpha * 0.75 * (1 - u) * (1 - u)
            }
        }
        if case .listening(micLive: true) = lastPhase {
            f.meterGlowAlpha = contentAlpha * 0.5 * smoothstep(envelope * 1.6)
        }

        // Symbols.
        let pop = max(0, glyphPop.value)
        if let previous = glyphPrevious, glyphMix.value < 0.999 {
            f.glyphs.append(NotchFrame.Glyph(kind: previous, color: color(for: previous),
                                             alpha: contentAlpha * (1 - glyphMix.value), scale: 1))
        }
        if let current = glyphCurrent {
            var alpha = contentAlpha * glyphMix.value
            var scale = pop
            if current == .sparkle && !reduceMotion {
                // Refining: the sparkle glints in time with the ripple.
                let glint = ripple(1, count: 3, now: now, period: Self.refiningPeriod)
                alpha *= 0.72 + 0.28 * glint
                scale *= 0.92 + 0.12 * glint
            }
            f.glyphs.append(NotchFrame.Glyph(kind: current, color: color(for: current),
                                             alpha: alpha, scale: scale))
        }
        f.checkProgress = check.value
        f.checkAlpha = contentAlpha * min(1, check.value * 3)

        // The meter.
        let barColor = currentBarColor(at: now)
        let metrics = L.bars
        f.bars = bars.enumerated().map { index, spring in
            let fraction = min(max(spring.value, 0), 1.2)
            var alpha: Double
            switch lastPhase {
            case .listening(let micLive):
                // Quiet is dimmer, not just shorter: silence reads as a
                // receding row of embers, speech as full orange.
                alpha = micLive ? 0.5 + 0.5 * min(1, fraction * 1.6 + envelope * 0.4) : 0.45
            case .processing(let stage):
                let period = stage == .refining ? Self.refiningPeriod : Self.finalizingPeriod
                let bump = reduceMotion
                    ? 0.5 + 0.5 * sin(2 * .pi * now / 1.6)
                    : ripple(index, count: bars.count, now: now, period: period)
                alpha = 0.34 + 0.6 * bump
            case .result(let kind):
                alpha = kind == .success ? 0.9 : 0.7
            case .collapsing, .hidden:
                alpha = 0.6
            }
            if increaseContrast { alpha = max(alpha, 0.9) }
            return NotchFrame.Bar(height: metrics.height(fraction), color: barColor,
                                  alpha: alpha * contentAlpha)
        }

        f.washColor = washColor
        f.washAlpha = wash.value * contentAlpha
        return f
    }

    private var washColor: PillColor {
        if case .result(let kind) = lastPhase { return NotchPalette.tint(for: kind) }
        return NotchPalette.critical
    }

    private func color(for glyph: NotchGlyph) -> PillColor {
        switch glyph {
        case .sparkle: return NotchPalette.ink
        case .question: return NotchPalette.ink
        case .faint: return NotchPalette.attention
        case .exclamation: return NotchPalette.critical
        case .lock: return NotchPalette.attention
        }
    }
}

func smoothstep(_ x: Double) -> Double {
    let u = min(1, max(0, x))
    return u * u * (3 - 2 * u)
}

extension PillColor {
    /// Linear blend in sRGB; good enough for a 180 ms crossfade.
    public func mixed(with other: PillColor, _ amount: Double) -> PillColor {
        let u = min(1, max(0, amount))
        return PillColor(r + (other.r - r) * u, g + (other.g - g) * u, b + (other.b - b) * u)
    }
}
