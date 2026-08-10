import Foundation

/// Pill visual vocabulary — `docs/design/ui-redesign.md` §2.2 and §2.4.
///
/// The `pill.py` constants that used to live here (a 26 × 26 dot whose radius
/// was `6 + level × 5`) are gone: the dot is replaced by a capsule waveform.
/// What survived the redesign survived on purpose — the auto-hide delays, the
/// 90 pt bottom margin, the level clamp and the 8 pt width quantisation are all
/// behaviour the user has lived with for months.

/// Calibrated RGB triple, 0…1. AppKit-free, so the pure target and the drawing
/// layer can share one palette.
public struct PillColor: Equatable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double
    public init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }

    /// `0xRRGGBB`, so the pill can source `Theme.Token` values directly.
    public init(hex: UInt32) {
        self.init(Double((hex >> 16) & 0xFF) / 255.0,
                  Double((hex >> 8) & 0xFF) / 255.0,
                  Double(hex & 0xFF) / 255.0)
    }
}

/// The pill's states.
///
/// The five original raw values are frozen — `PillModelTests` asserts on them
/// and the session's own state names ride alongside. §2.4 calls `recording`
/// *listening* and `success` *committed*; those are the design's words for the
/// same two states, and renaming the cases would buy nothing but a diff.
public enum PillState: String, Equatable, Sendable, CaseIterable {
    case hidden
    /// NEW — the key is down and audio has not started yet. Bars sit at floor,
    /// `studioMuted`, deliberately **not** orange: the mic is not open yet.
    case prewarming
    /// §2.4's `listening`.
    case recording
    case finalizing
    /// NEW — the Apple Intelligence cleanup pass is running.
    case refining
    /// §2.4's `committed`.
    case success
    case error
    /// NEW — the focused app holds Secure Keyboard Entry, so the text is on the
    /// clipboard instead of in the field.
    case blockedSecure
}

/// The pill's colours, sourced from `Theme` (§2.7: the `pill.py` calibrated
/// triples go).
///
/// Every value takes the **dark** side of its token. The pill is appearance
/// independent (§1.2/§1.7) — it floats over an unknown app's content on an
/// always-near-black body, and `#F07818` goes muddy there, which is exactly the
/// case the dark palette was tuned for.
public enum PillPalette {
    private static func dark(_ token: ColorToken) -> PillColor { PillColor(hex: token.dark) }

    /// The body, at 92% (§1.7). No material: vibrancy over an unknown app's
    /// content is unpredictable and the pill must read on white and on black.
    public static let body = dark(Theme.Token.studio)
    public static let bodyAlpha: Double = 0.92
    /// The error / blocked body.
    public static let alarmBody = dark(Theme.Token.studioAlarm)
    public static let alarmBodyAlpha: Double = 0.94
    /// The 1 pt rim: white @ 14%.
    public static let rim = PillColor(1, 1, 1)
    public static let rimAlpha = Theme.Token.studioStroke.alpha

    public static let ink = dark(Theme.Token.studioInk)
    public static let muted = dark(Theme.Token.studioMuted)
    public static let hot = dark(Theme.Token.hot)
    public static let critical = dark(Theme.Token.critical)
    public static let attention = dark(Theme.Token.attention)

    /// Text on the body, at 92% (§2.4).
    public static let textAlpha: Double = 0.92

    /// True only while the microphone is open. The orange rule (§1.6) in one
    /// predicate: this is the *only* state whose tint is `hot`.
    public static func isLive(_ state: PillState) -> Bool { state == .recording }

    /// The state's signature colour — the bars while listening, the glyph
    /// afterwards.
    public static func tint(for state: PillState) -> PillColor {
        switch state {
        case .recording: return hot
        case .success: return ink
        case .error: return critical
        case .blockedSecure: return attention
        case .hidden, .prewarming, .finalizing, .refining: return muted
        }
    }

    /// Body fill and alpha. The two alarm states swap the near-black body for a
    /// near-black *red* one, which is the whole reason an error reads as an
    /// error before its text is parsed.
    public static func bodyFill(for state: PillState) -> (color: PillColor, alpha: Double) {
        switch state {
        case .error, .blockedSecure: return (alarmBody, alarmBodyAlpha)
        default: return (body, bodyAlpha)
        }
    }
}

public enum PillGeometry {
    /// §2.2. `height` is up from 26 to fit a legible meter; `radius` is h/2, so
    /// the pill is a full capsule.
    public static let height: Double = 28.0
    public static var radius: Double { height / 2.0 }
    /// The listening panel: aspect 3.43 : 1.
    public static let widthListening: Double = 96.0
    /// `committed` contracts to a circle.
    public static let widthCommitted: Double = 28.0
    /// `_BOTTOM_MARGIN` for the default bottom-centre placement — unchanged.
    public static let bottomMargin: Double = 90.0
    /// §2.6 edge flip: keep this much clear of the screen's right edge.
    public static let edgeMargin: Double = 8.0

    /// The meter (§2.2). Odd bar count, so there is a true centre bar.
    public static let barCount = 15
    public static let barWidth: Double = 2.5
    public static let barPitch: Double = 5.0
    /// `15 × 5.0 − 2.5`.
    public static let barFieldWidth: Double = 72.5
    /// 0.50·h.
    public static let barPeak: Double = 14.0
    /// `= barWidth`, so silence is a perfect dot. The single best detail in
    /// Wispr's pill, and it is kept.
    public static let barFloor: Double = 2.5
    /// `(96 − 72.5) / 2`.
    public static let sideInset: Double = 11.75
    /// Meter width when a text tail is present.
    public static let barCountCompact = 7
    /// `7 × 5.0 − 2.5`.
    public static let barFieldCompact: Double = 32.5

    /// Minimum panel width for the two alarm states, so a 40-character message
    /// is not squeezed into a listening-width capsule (§2.4).
    public static let errorMinWidth: Double = 140.0
    public static let blockedSecureMinWidth: Double = 180.0

    /// The live dead-mic cue (FINAL-PLAN R10, native-feel §2.5.2). A dead or
    /// muted microphone is knowable *during* the hold — the level ticker is
    /// already delivering zeros — so the pill says so while the user can still
    /// act, instead of as a posthumous flash.
    ///
    /// `deadMicFloor` is the 0.02 voiced floor in its one legitimate job
    /// (§1.1-T4d): a cheap heuristic whose false negative is harmless, because
    /// the trigger is amended by engine evidence — a partial suppresses and
    /// clears the cue, and so does a single voiced tick. The cue fires only
    /// after *more* than `deadMicTickCount` consecutive sub-floor ticks
    /// (40 × 50 ms = 2 s), which both reads as "after ~2 s" and keeps the
    /// 2-second silence window itself render-free — the zero-redraw silence
    /// invariant is measured over exactly that window.
    public static let deadMicFloor: Double = 0.02
    public static let deadMicTickCount = 40
    public static let deadMicMessage = "No audio — check mic"
    /// The message a `blockedSecure` flash carries when the session does not
    /// supply one.
    public static let blockedSecureMessage = "Secure input — ⌘⌃V to paste"
    /// Errors get a wider character budget than a live partial: the message is
    /// the whole point of the state (§2.7).
    public static let errorMessageCharacters = 40

    /// Auto-hide delays: `flash_success` 0.6 s, `flash_error` 1.6 s — unchanged.
    public static let successHideDelay: Double = 0.6
    public static let errorHideDelay: Double = 1.6
    /// How long a `transientNotice` ("Learned Sharique") stays legible.
    public static let noticeDuration: Double = 1.6
    /// NEW — a secure-input block asks the user to press a key combination, so
    /// it has to outlive an error flash.
    public static let blockedSecureHideDelay: Double = 2.6

    /// `setLevel_` clamps with `max(0.0, min(1.0, float(level)))`; NaN is
    /// treated as silence rather than propagating into the frame maths.
    public static func clampLevel(_ level: Double) -> Double {
        guard level.isFinite else { return 0.0 }
        return max(0.0, min(1.0, level))
    }
}

/// Geometry of the text tail that carries `livePartial`, `transientNotice` and
/// (new) the error message. Formerly `PillBubbleGeometry`.
///
/// The quantisation is the anti-flicker mechanism and is kept **verbatim**:
/// partials arrive several times a second and an exact-fit width would resize
/// the window on every word. Only the four dimensions changed, to match the
/// taller capsule (§2.7).
public enum PillTailGeometry {
    /// Between meter and text.
    public static let gap: Double = 8.0
    /// The tail shares the pill's height now — it is inside the capsule, not a
    /// second bubble beside it.
    public static let height: Double = 28.0
    public static var cornerRadius: Double { height / 2.0 }
    /// Leading and trailing text inset.
    public static let textInset: Double = 12.0
    /// Advance of the 11 pt font, measured empirically. Only used for *sizing*;
    /// the text itself is truncated by the text system, so a small error can
    /// never clip mid-glyph, only leave a hair of padding.
    public static let characterWidth: Double = 6.5
    /// Widths snap to this step.
    public static let widthStep: Double = 8.0
    public static let minWidth: Double = 44.0
    public static let maxWidth: Double = 196.0
    /// The alarm states' wider cap (FINAL-PLAN R9a, native-feel P3). The live
    /// tail's 196 pt cap is right for a scrolling partial and wrong for a
    /// diagnosis: §2.4 gives errors a 40-character budget, and 40 characters
    /// need `2 × 12 + 40 × 6.5 = 284` pt of text frame — under the old cap the
    /// copy was first char-clipped to 40, then truncated again to ~30 by the
    /// frame. 288 is the next `widthStep` multiple that fits the whole budget.
    public static let errorMaxWidth: Double = 288.0

    /// Everything around the text: `12 + 32.5 + 8 + w + 12` (§2.2).
    public static var chrome: Double {
        textInset + PillGeometry.barFieldCompact + gap + textInset
    }

    /// Quantised tail width for an `n`-character string. 0 characters means no
    /// tail at all (the pill stays a 96 pt capsule).
    ///
    /// Note that the clamps are deliberately *not* on the 8 pt grid: they are
    /// derived from the panel widths §2.2 names (108.5 and 260.5). Between them
    /// every width is a multiple of `widthStep`, which is what the flicker
    /// guarantee actually needs.
    public static func width(forCharacters n: Int) -> Double {
        width(forCharacters: n, cappedAt: maxWidth)
    }

    /// The alarm-state layout: same quantisation, wider cap, so the rendered
    /// frame fits every string the error character budget admits.
    public static func errorWidth(forCharacters n: Int) -> Double {
        width(forCharacters: n, cappedAt: errorMaxWidth)
    }

    private static func width(forCharacters n: Int, cappedAt cap: Double) -> Double {
        guard n > 0 else { return 0 }
        let raw = 2 * textInset + Double(n) * characterWidth
        let stepped = (raw / widthStep).rounded(.up) * widthStep
        return min(cap, max(minWidth, stepped))
    }

    /// Which end the text system may cut (FINAL-PLAN R9a). Head-truncation is
    /// right for a live tail — the newest words are the ones worth keeping —
    /// and wrong for a diagnosis, whose head *is* the diagnosis ("Didn't hear
    /// anything — …"). The alarm states truncate at the tail.
    public static func truncation(for state: PillState) -> PillTailTruncation {
        switch state {
        case .error, .blockedSecure: return .tail
        case .hidden, .prewarming, .recording, .finalizing, .refining, .success: return .head
        }
    }
}

/// AppKit-free spelling of `Text.truncationMode`, so the decision lives beside
/// the geometry and under test rather than inline in the view.
public enum PillTailTruncation: Equatable, Sendable {
    case head
    case tail
}

extension PillTailGeometry {
    /// Total panel width for a given tail width — `64.5 + w`.
    public static func totalWidth(tailWidth: Double) -> Double {
        tailWidth <= 0 ? PillGeometry.widthListening : chrome + tailWidth
    }
}

/// The §2.5 transition table, as numbers with names (FINAL-PLAN R13,
/// native-feel §2.12 — "the largest spec/build gap"). Everything here is
/// AppKit-free so the durations, the curve choices and the per-bar collapse
/// choreography are assertions, not vibes.
///
/// The split of labour the plan prescribes: the *panel frame* transitions
/// (appear fade+rise, width spring, committed contraction, hide sink) run
/// through `NSAnimationContext`/`animator()` in `Pill.apply`; the *drawn
/// surface* transitions (bar tint crossfade, desaturate, staggered collapse,
/// glyph crossfade) run through SwiftUI in `PillSurface`. The 20 Hz level path
/// animates nothing — the 50 ms tick *is* the spec's 50 ms linear row — and
/// silence still costs zero redraws.
public enum PillMotion {
    // MARK: §2.5 rows — durations and travel

    /// `hidden → prewarming`: 90 ms `.easeOut`, opacity + 4 pt rise.
    public static let appearDuration: Double = 0.09
    public static let appearRise: Double = 4.0
    /// `prewarming → listening`: 140 ms bar tint crossfade, `.easeInOut`.
    public static let tintCrossfadeDuration: Double = 0.14
    /// `listening → finalizing`: 120 ms desaturate (`.easeIn`), then the
    /// staggered collapse below.
    public static let desaturateDuration: Double = 0.12
    /// Width change (tail grows): 120 ms, `.spring(response: 0.28,
    /// dampingFraction: 0.9)` — damping 0.9 is a near-critically-damped
    /// spring, which the AppKit side approximates with an ease-out of the
    /// spring's response time.
    public static let widthDuration: Double = 0.12
    public static let widthSpringResponse: Double = 0.28
    public static let widthSpringDamping: Double = 0.9
    /// `finalizing → committed`: 140 ms, `.spring(response: 0.22,
    /// dampingFraction: 0.86)`; the panel contracts 260.5 → 28 pt while the
    /// checkmark crossfades in.
    public static let committedDuration: Double = 0.14
    public static let committedSpringResponse: Double = 0.22
    public static let committedSpringDamping: Double = 0.86
    /// `any → hidden`: 160 ms `.easeIn`, opacity + 3 pt sink.
    public static let hideDuration: Double = 0.16
    public static let hideSink: Double = 3.0

    // MARK: the staggered collapse (§2.4 `finalizing`, §2.5 row 6)

    /// 6 ms × index — precomputed here, in the model layer, because the spec's
    /// alternative (15 view identities each carrying `.delay(i × 6ms)`) is the
    /// one way this redesign could make dictation worse (§2.7).
    public static let collapseStagger: Double = 0.006
    /// How long one bar takes to fall to floor once its turn comes.
    public static let collapseBarFall: Double = 0.12

    public static func collapseDelay(forBar index: Int) -> Double {
        Double(max(0, index)) * collapseStagger
    }

    /// Full choreography length: the last bar's delay plus its fall.
    public static func collapseDuration(barCount: Int) -> Double {
        collapseDelay(forBar: max(0, barCount - 1)) + collapseBarFall
    }

    /// Per-bar progress (0 = full height, 1 = at floor) for a global phase
    /// 0…1 driven by one animatable scalar. One `Canvas`, one animation, no
    /// per-bar view identity.
    public static func collapseProgress(phase: Double, bar index: Int, barCount: Int) -> Double {
        let total = collapseDuration(barCount: barCount)
        guard total > 0, collapseBarFall > 0 else { return 1 }
        let clamped = min(1.0, max(0.0, phase))
        let elapsed = clamped * total - collapseDelay(forBar: index)
        return min(1.0, max(0.0, elapsed / collapseBarFall))
    }

    // MARK: the panel-frame decision

    /// What `Pill.apply` should do to the panel frame for one render change.
    /// Pure, so the seven-rows-present claim is a unit test.
    public struct FrameChange: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            case none
            /// Order front, fade 0 → 1, rise `travel` pt.
            case appear
            /// Fade 1 → 0, sink `travel` pt, order out on completion.
            case hide
            /// Animate `setFrame` to the new width.
            case resize
            /// The committed contraction — same mechanism, its own timing.
            case contract
        }

        public var kind: Kind
        public var duration: Double
        /// Vertical travel in points. 0 under Reduce Motion — only motion goes.
        public var travel: Double
        /// Whether the frame itself animates. Reduce Motion snaps the frame
        /// (the committed contraction becomes the SwiftUI crossfade alone) but
        /// keeps the opacity fades — durations survive.
        public var animatesFrame: Bool

        public init(kind: Kind, duration: Double, travel: Double, animatesFrame: Bool) {
            self.kind = kind
            self.duration = duration
            self.travel = travel
            self.animatesFrame = animatesFrame
        }
    }

    public static func frameChange(wasVisible: Bool, isVisible: Bool,
                                   oldWidth: Double, newWidth: Double,
                                   newState: PillState,
                                   reduceMotion: Bool) -> FrameChange {
        if isVisible && !wasVisible {
            return FrameChange(kind: .appear, duration: appearDuration,
                               travel: reduceMotion ? 0 : appearRise,
                               animatesFrame: !reduceMotion)
        }
        if !isVisible && wasVisible {
            return FrameChange(kind: .hide, duration: hideDuration,
                               travel: reduceMotion ? 0 : hideSink,
                               animatesFrame: !reduceMotion)
        }
        if isVisible && oldWidth != newWidth {
            let contracting = (newState == .success && newWidth < oldWidth)
            return FrameChange(kind: contracting ? .contract : .resize,
                               duration: contracting ? committedDuration : widthDuration,
                               travel: 0,
                               animatesFrame: !reduceMotion)
        }
        return FrameChange(kind: .none, duration: 0, travel: 0, animatesFrame: false)
    }
}
