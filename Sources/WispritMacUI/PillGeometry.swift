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
    /// An utterance that produced nothing — silence, a miss, a short tap.
    /// Kept as a state so existing palette/truncation switches stay exhaustive;
    /// the empty-utterance *path* is now a wiggle on `.idle`, not this case.
    case missed
    /// The Flow-style resting bar: a compact capsule that stays on screen
    /// between utterances. Expands into the waveform the moment you hold.
    case idle
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

    /// The body, at 92% (§1.7). This is the **opaque** alpha: what the pill
    /// wears when there is no blur underneath it (Reduce Transparency), and the
    /// number that guarantees it reads on white and on black.
    public static let body = dark(Theme.Token.studio)
    public static let bodyAlpha: Double = 0.92
    /// The error body.
    public static let alarmBody = dark(Theme.Token.studioAlarm)
    public static let alarmBodyAlpha: Double = 0.94
    /// The blocked-secure body: warm-black, not red-black. Nothing failed —
    /// the text is on the clipboard and there is one key to press.
    public static let attentionBody = dark(Theme.Token.studioAttention)

    // MARK: the material (NEW)

    /// The body alpha when the panel's `NSVisualEffectView` is doing the work
    /// underneath.
    ///
    /// The original note here — "no material: vibrancy over an unknown app's
    /// content is unpredictable" — was right about vibrancy and wrong about
    /// blur. A *tinted* blur is not unpredictable: the near-black tint still
    /// dominates the composite (0.76 of it), so the legibility argument holds
    /// exactly as before, and what the remaining 24% buys is the one thing a
    /// flat fill can never have — the desktop moving behind the glass. Flow is
    /// Electron-flat by necessity; this is the native answer to it.
    public static let bodyAlphaOverMaterial: Double = 0.76
    public static let alarmBodyAlphaOverMaterial: Double = 0.86

    /// The 1 pt rim: white @ 14%.
    public static let rim = PillColor(1, 1, 1)
    public static let rimAlpha = Theme.Token.studioStroke.alpha
    /// The rim as a **lit edge** rather than a flat hairline: bright where a
    /// light above the desktop would catch the top of the capsule, nearly gone
    /// underneath it.
    ///
    /// Same total edge light as the flat 14% it replaces — `(top + bottom) / 2
    /// == rimAlpha`, and `PillModelTests` holds it there. Redistributing the
    /// budget rather than spending more of it is the difference between an
    /// object that is lit and one that is merely outlined.
    public static let rimTopAlpha: Double = 0.26
    public static let rimBottomAlpha: Double = 0.02
    /// Increase Contrast: one solid, unmistakable edge instead of a lit one.
    public static let rimContrastAlpha: Double = 0.55
    /// The inner highlight riding just under the top of the rim — the 1 pt that
    /// makes the body read as a surface with thickness.
    public static let innerHighlightAlpha: Double = 0.08
    /// Hovering the resting bar brightens its edge. Deliberately not a scale:
    /// the hosting view clips to the panel, so a pill that grew on hover was
    /// having its own lift cut off at the sides.
    public static let rimHoverBoost: Double = 0.14
    /// The alarm rim flash — the error's arrival, without a shake.
    public static let alarmRimAlpha: Double = 0.70

    public static let ink = dark(Theme.Token.studioInk)
    public static let muted = dark(Theme.Token.studioMuted)
    /// Flow's waveform cream (`#FFFFEB`). Idle and silence sit on this,
    /// not gray — the bar has to read as a cream-on-black capsule.
    public static let cream = PillColor(hex: 0xFFFFEB)
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
        case .hidden, .prewarming, .finalizing, .refining, .missed, .idle: return muted
        }
    }

    /// The meter's own colour — three values, and the state decides.
    ///
    /// Cream at rest (idle, prewarming, the settled commit), mic-orange while
    /// the microphone is open, and muted grey while the pill is working. That
    /// last one is measured: on release Flow's cream bars dim to about 50 %
    /// grey as the capsule widens, and the dimming is half of what makes the
    /// release read as a handover rather than a pause.
    ///
    /// It resolves the *dark* tokens unconditionally, because the panel pins
    /// its appearance to `darkAqua` — the pill floats on its own near-black
    /// body whatever the Mac is set to.
    public static func meterTint(for state: PillState) -> PillColor {
        switch state {
        case .recording: return hot
        case .finalizing, .refining: return muted
        case .hidden, .prewarming, .success, .error, .blockedSecure, .missed, .idle:
            return cream
        }
    }

    /// Body fill and alpha. The two alarm states swap the near-black body for a
    /// *tinted* near-black — red for an error, warm for a block — which is the
    /// whole reason either one reads correctly before its text is parsed, and
    /// why they no longer share one body: a secure-input block is an
    /// instruction, not a failure.
    public static func bodyFill(for state: PillState) -> (color: PillColor, alpha: Double) {
        switch state {
        case .error: return (alarmBody, alarmBodyAlpha)
        case .blockedSecure: return (attentionBody, alarmBodyAlpha)
        case .hidden, .prewarming, .recording, .finalizing, .refining, .success, .missed, .idle:
            return (body, bodyAlpha)
        }
    }
}

public enum PillGeometry {
    /// §2.2. `height` is up from 26 to fit a legible meter; `radius` is h/2, so
    /// the pill is a full capsule.
    public static let height: Double = 28.0
    public static var radius: Double { height / 2.0 }
    /// The one capsule. Idle, listening and the compact-with-a-tail frame all
    /// share it — measured against the real Flow app, whose idle capsule and
    /// listening capsule are the *same* 107 px object and whose "idle dots" are
    /// simply its bars at floor. There is no idle geometry any more, which is
    /// also why `idle → listening` needs no frame change at all.
    public static let widthListening: Double = 96.0
    /// The processing capsule: ×1.34 of the listening one (Flow's measured
    /// 107 → 143 px), snapped to the 8 pt grid. Wide enough for the dot row to
    /// sit leading-aligned with the spinner at the trailing inset.
    public static let widthProcessing: Double = 128.0

    /// The mini rest. A user directive that overrides Flow-fidelity: at rest
    /// the pill must be "extremely small", growing only while it is actually
    /// listening or working. 36×10 is the smallest sliver that still reads as
    /// the pill (wider than tall, same capsule family) and survives as a drag
    /// target. The bar field cannot fit inside it, so the resting dots are
    /// gone — rest is a bare glass sliver, and `idle → prewarming` became a
    /// real expansion rather than Flow's colour crossfade.
    ///
    /// The *panel* does not shrink to this. Idle hover used to resize the
    /// `NSPanel` 36×10 → 96×28 around a moving origin, which slid the frame
    /// out from under the cursor, toggled `onHover`, and looped. The window
    /// stays at listening size; this is only the drawn capsule inside it.
    public static let widthMini: Double = 36.0
    public static let heightMini: Double = 10.0
    /// Recording chrome: Cancel (X) and confirm (✓) beside the ten-bar field.
    /// 2×12 inset + 2×20 buttons + 2×6 gaps + 51.75 field = 127.75, snapped
    /// to the 8 pt grid — the same 128 as the processing capsule, so
    /// listening-with-buttons → spinner is a colour change, not a resize.
    public static let chromeButton: Double = 20.0
    public static let chromeGap: Double = 6.0
    public static let widthChrome: Double = 128.0
    /// `_BOTTOM_MARGIN` for the default bottom-centre placement — unchanged.
    public static let bottomMargin: Double = 90.0
    /// §2.6 edge flip: keep this much clear of the screen's right edge.
    public static let edgeMargin: Double = 8.0

    /// The meter. Ten bars, everywhere — Flow uses one field and so do we.
    ///
    /// Bar width is `Flowbar.svg`'s 0.080·h and the peak is its 0.509·h. The
    /// **pitch is not** its 0.152·h, and that is a deliberate call between two
    /// disagreeing sources. Flowbar puts the field at 42 % of the capsule; the
    /// real macOS app, measured off video, runs its ten bars at 0.056 of the
    /// pill's width — 56 % of the capsule — and Wispr's own After Effects
    /// export uses a 41 % duty cycle (3.3 on 8.0). 5.5 pt satisfies both of
    /// those (41 % duty, 54 % field) and lands on whole pixels at 2×; the
    /// marketing SVG is the outlier, and the app is what the user compares us
    /// against.
    ///
    /// An *even* count on purpose: the dome below has no true centre bar and
    /// the measured envelope has a flat top, so an odd count would be inventing
    /// a spike the reference does not have.
    public static let barCount = 10
    public static let barWidth: Double = 2.25
    public static let barPitch: Double = 5.5
    /// `9 × 5.5 + 2.25` — the ink, first bar's left edge to last bar's right.
    public static let barFieldWidth: Double = 51.75
    /// 0.50·h.
    public static let barPeak: Double = 14.0
    /// `= barWidth`, so silence is a perfect dot. The single best detail in
    /// Wispr's pill, and it is kept.
    public static let barFloor: Double = 2.25
    /// `(96 − 51.75) / 2`.
    public static let sideInset: Double = 22.125

    // MARK: - the processing spinner

    /// Eight ticks around a ~12 pt box (0.45·h), stepping 45° every 110 ms —
    /// the measured ~880 ms per revolution of Flow's own release spinner.
    public static let spinnerTicks = 8
    public static let spinnerBox: Double = 12.0
    public static let spinnerTickWidth: Double = 1.5
    public static let spinnerTickLength: Double = 4.0
    /// Opacity of the dimmest tick; the brightest is 1.
    public static let spinnerMinAlpha: Double = 0.25

    /// Minimum panel width for the two alarm states, so a 40-character message
    /// is not squeezed into a listening-width capsule (§2.4).
    public static let errorMinWidth: Double = 140.0
    public static let blockedSecureMinWidth: Double = 180.0

    /// The live dead-mic cue (FINAL-PLAN R10, native-feel §2.5.2). A dead or
    /// muted microphone is knowable *during* the hold — the level ticker is
    /// already delivering zeros — so the pill says so while the user can still
    /// act, instead of as a posthumous flash.
    ///
    /// `deadMicFloor` is a cheap mute heuristic (§1.1-T4d). Quiet speech
    /// lives around 0.005–0.015 on the meter, so the floor sits under that
    /// — a false negative is harmless because a partial or a voiced tick
    /// still suppresses the cue. The cue fires only after *more* than
    /// `deadMicTickCount` consecutive sub-floor ticks (40 × 50 ms = 2 s).
    public static let deadMicFloor: Double = 0.005
    public static let deadMicTickCount = 40
    public static let deadMicMessage = "No sound yet"
    /// The message a `blockedSecure` flash carries when the session does not
    /// supply one.
    public static let blockedSecureMessage = "Secure input — ⌘⌃V to paste"
    /// Quiet empty-utterance copy. Not an alarm — Flow fades; we name it.
    public static let missedMessage = "Didn't catch that"
    public static let shortHoldMessage = "Hold the key while you speak"
    /// Errors get a wider character budget than a live partial: the message is
    /// the whole point of the state (§2.7).
    public static let errorMessageCharacters = 40

    /// Idle HUD fade: after this much idle (not recording, not hovered, not
    /// dragging) the pill goes fully transparent so it is not a distraction.
    /// 3 s sits in the 2–4 s band of macOS overlay chrome — past "I'm still
    /// looking at it", short of "why is that still there". The panel stays
    /// on screen as an invisible hit target; hover wakes it. Not a hide:
    /// `isVisible` stays true and the panel is not ordered out.
    public static let idleHideDelay: Double = 3.0

    /// Auto-hide delays: `flash_success` 0.6 s, `flash_error` 1.6 s — unchanged.
    public static let successHideDelay: Double = 0.6
    public static let errorHideDelay: Double = 1.6
    /// A miss fades faster than an alarm — Flow just leaves.
    public static let missedHideDelay: Double = 0.9
    /// How long a `transientNotice` ("Learned Sharique") stays legible.
    public static let noticeDuration: Double = 1.6
    /// NEW — a secure-input block asks the user to press a key combination, so
    /// it has to outlive an error flash.
    public static let blockedSecureHideDelay: Double = 2.6

    // MARK: - the patience cue (the AUDIT-2026-08-14 "pill copy decision")

    /// How long a wait may run silently before the pill says what it is waiting
    /// on.
    ///
    /// The audit left this open: "a rescued utterance can cost 3 s streaming
    /// plus a multi-second batch pass before text appears; pill copy for that
    /// state is a product decision." This is the decision. A normal finalize is
    /// 200–600 ms, so 1.4 s is comfortably past "it's just working" and well
    /// short of "it has hung" — the pill grows a quiet line of copy at exactly
    /// the moment the user starts to wonder, and not one beat sooner.
    ///
    /// It costs nothing when it never fires: one scheduled timer per stage,
    /// cancelled by the next state change, which is the same single-timer
    /// budget the auto-hides have always used.
    public static let patienceDelay: Double = 1.4
    /// The batch rescue is literally a second pass over the same audio, so the
    /// copy says that. Not "Processing…" (says nothing), not "Almost there"
    /// (a promise the pill cannot keep) — an honest description of the work.
    public static let finalizingPatienceMessage = "Taking a second listen"
    /// Refine's long tail. The user already knows this stage by its sparkles;
    /// the words only have to say it is still the same stage.
    public static let refiningPatienceMessage = "Still cleaning up"

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

    /// Everything around the text: `12 + 51.75 + 8 + w + 12`, rounded up to a
    /// whole point.
    ///
    /// The meter no longer narrows when a tail arrives — Flow keeps one field
    /// and grows the capsule around it — so this is the full bar field now.
    ///
    /// The rounding is not tidiness. `NSWindow` snaps its frame to the backing
    /// store's pixel grid and SwiftUI does not, so a 227.75 pt render becomes a
    /// 228 pt panel hosting a 227.75 pt capsule — and the quarter point of
    /// panel that the capsule does not cover is a hairline of un-tinted glass
    /// down one edge. Tail widths are already multiples of 8 and every floor
    /// width is a whole number, so rounding here is the one place that makes
    /// *every* panel width integral.
    public static var chrome: Double {
        (textInset + PillGeometry.barFieldWidth + gap + textInset).rounded(.up)
    }

    /// Room the processing spinner needs at the trailing end, beside a tail.
    ///
    /// The spinner is an overlay pinned to the trailing inset, so it does not
    /// take part in the row's layout — but the copy must not run underneath it,
    /// and a patience line arriving during a wait is exactly when that would
    /// happen. One gap plus the spinner's box, added to the width the tail
    /// asked for.
    public static var spinnerAllowance: Double {
        gap + PillGeometry.spinnerBox
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
        case .error, .blockedSecure, .missed: return .tail
        case .hidden, .prewarming, .recording, .finalizing, .refining, .success, .idle: return .head
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
/// The split of labour: the *panel frame* transitions (appear fade+rise, width
/// spring, the commit's contraction back to the resting capsule, hide sink) run
/// through `NSAnimationContext`/`animator()` in `Pill.apply`; the *drawn
/// surface* transitions (body, rim, glyph, tail) run through SwiftUI in
/// `PillSurface`; and the *meter* runs through explicit Core Animation in
/// `PillMeterLayerView`, which is the one lane the 20 Hz level path touches.
///
/// That last split is the change this table exists for. The old note here said
/// interpolating between level ticks "would double the draw rate to buy nothing
/// the eye can see". Both halves are false. The eye plainly sees it — it is the
/// difference between Flow's glide and our tick, and it is what the user asked
/// for — and the cost goes *down*, not up: one 20 Hz `CATransaction` retargeting
/// ten layers measures 12.9 µs on this machine against ~95 µs for the `Canvas`
/// raster it replaces, and the render server then interpolates at the display's
/// own rate with no further process wakeups. The CGEventTap budget argues *for*
/// compositor-driven 60 fps, not against it.
public enum PillMotion {
    // MARK: §2.5 rows — durations and travel

    /// `hidden → prewarming`: 90 ms `.easeOut`, opacity + 4 pt rise.
    public static let appearDuration: Double = 0.09
    public static let appearRise: Double = 4.0
    /// `prewarming → listening`: 140 ms bar tint crossfade, `.easeInOut`.
    public static let tintCrossfadeDuration: Double = 0.14
    /// `listening → finalizing`: 120 ms. One duration doing two jobs at once,
    /// which is the point — the bars fall to floor *while* the cream dims to
    /// muted, as one event. Flow does not stagger the collapse and neither do
    /// we any more: its dot row drops as a unit inside two 40 ms frames.
    public static let desaturateDuration: Double = 0.12
    /// Width change (tail grows): 120 ms, `.spring(response: 0.28,
    /// dampingFraction: 0.9)` — damping 0.9 is a near-critically-damped
    /// spring, which the AppKit side approximates with an ease-out of the
    /// spring's response time.
    public static let widthDuration: Double = 0.12
    public static let widthSpringResponse: Double = 0.28
    public static let widthSpringDamping: Double = 0.9
    /// `processing → committed`: 140 ms, `.spring(response: 0.22,
    /// dampingFraction: 0.86)`. The panel contracts from whatever width the
    /// utterance earned back to the 96 pt resting capsule while the dots
    /// brighten muted → cream and the spinner fades out.
    ///
    /// **Deliberate deviation, not fidelity.** Flow's pill *vanishes* on commit
    /// — measured between two consecutive 40 ms frames, twice — with no glyph
    /// and no flash. Wisprit keeps the resting bar on the desktop instead,
    /// because that is the contract the user has lived with (`.settle` →
    /// `showIdle`) and because a pill that disappears has to be re-summoned by
    /// the next press. What we take from Flow is the *absence of a commit
    /// glyph*: the inserted text is the confirmation.
    public static let committedDuration: Double = 0.14
    public static let committedSpringResponse: Double = 0.22
    public static let committedSpringDamping: Double = 0.86
    /// `any → hidden`: 160 ms `.easeIn`, opacity + 3 pt sink.
    public static let hideDuration: Double = 0.16
    public static let hideSink: Double = 3.0

    // MARK: the arrival (NEW)

    /// The capsule springs up from 90% as the panel fades in.
    ///
    /// The 90 ms fade + 4 pt rise above is the *panel's* arrival and it stays
    /// exactly as specified; this is the *body's*, and it is what makes the
    /// pill feel like an object that came to the desktop rather than a bitmap
    /// that got switched on. It only ever scales **up to** 1, never past it —
    /// the hosting view clips to the panel, so overshoot would be sheared off.
    public static let appearScale: Double = 0.90
    public static let appearSpringResponse: Double = 0.26
    public static let appearSpringDamping: Double = 0.82

    // MARK: the meter's 60 fps (the whole point of this rewrite)

    /// How long one bar takes to reach a freshly arrived target.
    ///
    /// The level feed is 20 Hz and stays 20 Hz; each sample starts a tween
    /// toward the new height and the render server draws the frames in between.
    /// This is Wispr's own technique in both of their artefacts: their web demo
    /// calls `element.animate({duration: 300, fill: 'forwards'})` on every
    /// 50 ms sample, and their After Effects export retargets each bar every
    /// 166 ms. 200 ms overlaps four ticks, so a bar is always in motion and
    /// never lands on a target and waits.
    public static let meterTweenDuration: Double = 0.20

    /// The tween is **linear**, and that is a decision rather than a default.
    ///
    /// Both Flow sources are linear — the Lottie's rect-size keyframes carry
    /// (0.167, 0.167) → (0.833, 0.833) handles, which is exactly linear, and
    /// the web demo takes `element.animate`'s linear default. Easing here would
    /// double-count: the attack/release asymmetry the ear reads already lives
    /// in `BarSynthesizer`'s envelope coefficients, and an ease-out on top of
    /// it turns every syllable into a soft landing the voice did not make.
    public static let meterTweenIsLinear = true

    // MARK: the processing spinner (`finalizing` / `refining`)

    /// One 45° step per 110 ms — eight of them is the measured ~880 ms per
    /// revolution. Discrete, like every iOS spinner: it ticks, it does not
    /// sweep. Runs as one repeating `CAKeyframeAnimation` in the render server,
    /// so a wait of any length costs the main thread nothing at all.
    public static let spinnerStepDuration: Double = 0.11
    public static var spinnerRevolution: Double {
        spinnerStepDuration * Double(PillGeometry.spinnerTicks)
    }
    /// It arrives just after the bars have dropped, not with them: two events
    /// in 160 ms read as "the voice stopped, *then* the work started", which is
    /// the truth. Leaving is faster than arriving — the result is already here.
    public static let spinnerFadeIn: Double = 0.12
    public static let spinnerFadeInDelay: Double = 0.04
    public static let spinnerFadeOut: Double = 0.08

    // MARK: the toast unfold (`transientNotice`, and every app-authored line)

    /// Wispr's toast idiom, measured off their own Lottie and folded onto our
    /// tail rather than added as a second chrome element: the capsule pops, the
    /// width *unfolds* with heavy deceleration, holds, then folds back
    /// accelerating. Their numbers, our element.
    public static let noticePopDuration: Double = 0.133
    public static let noticeUnfoldDuration: Double = 0.40
    public static let noticeFoldDuration: Double = 0.25
    /// The unfold's bezier: leaves fast, arrives asymptotically (their measured
    /// out-x ≈ 0.16, in-y = 1). The fold is its mirror — accelerating away.
    public static let noticeUnfoldControl: (Double, Double, Double, Double) = (0.16, 0, 0.2, 1)
    public static let noticeFoldControl: (Double, Double, Double, Double) = (0.6, 0, 1, 1)
    /// How far the rim brightens as a notice lands. An edge-light pop, not a
    /// scale: the hosting view clips to the panel, so anything that grows past
    /// the capsule has its own pop sheared off at the sides.
    public static let noticeRimPop: Double = 0.18

    // MARK: idle presence (HUD fade)

    /// Fade the glass and the surface, never the panel frame. Short enough
    /// to feel like a HUD getting out of the way, long enough not to pop.
    /// Reduce Motion snaps (duration 0).
    public static let presenceDuration: Double = 0.28

    /// Mouse-exited is delayed this long, then re-tested against the panel
    /// frame. Filters a tracking-area flicker if one still lands; enter is
    /// instant.
    public static let hoverExitHysteresis: Double = 0.08

    /// Reduce Motion snaps the HUD fade; durations of real motion elsewhere
    /// survive. Presence is opacity-only, so the reduced form is a cut.
    public static func presenceFadeDuration(reduceMotion: Bool) -> Double {
        reduceMotion ? 0 : presenceDuration
    }

    // MARK: orientation morph & empty-state wiggle

    /// Left/right ↔ top/bottom: a short, interruptible morph — Apple's
    /// rotation spring (response 0.4, damping ~0.8) taken a hair snappier
    /// because the object is a 28 pt HUD, not a sheet.
    public static let orientationDuration: Double = 0.32
    public static let orientationSpringResponse: Double = 0.36
    public static let orientationSpringDamping: Double = 0.86

    /// Empty / nothing-heard: a macOS password-field "no". Small, springy,
    /// three decaying cycles, then idle. Not a rumble and not an alarm.
    public static let shakeAmplitude: Double = 7.0
    public static let shakeDuration: Double = 0.42
    public static let shakeCycles: Double = 3.0
    /// Exponential envelope so the last millimetre dies out instead of
    /// slamming into zero — the settle that makes it read as a spring.
    public static let shakeDecay: Double = 9.5

    // MARK: the commit (NEW)

    /// The check mark draws itself rather than fading in — 220 ms is the
    /// longest a stroke can take and still feel instantaneous.
    public static let checkDrawDuration: Double = 0.22
    /// How long the body and its edge take to cross into (and out of) the alarm
    /// palette. Replaces the 2 pt horizontal shake, which was both an alarm
    /// idiom the pill does not want and — because the hosting view clips to the
    /// panel — a shake that sliced 2 pt off its own capsule on every cycle.
    /// The edge stays tinted for the life of the state: a held signal is easier
    /// to read than a flash, and it never startles.
    public static let alarmRimDuration: Double = 0.20

    // MARK: the panel-frame decision

    /// The curve a frame change rides. Named rather than inlined at the AppKit
    /// edge so the toast's two beziers are assertions, not literals buried in
    /// a `switch`.
    public enum Curve: Equatable, Sendable {
        case easeOut
        case easeIn
        /// The toast unfold: leaves fast, arrives asymptotically.
        case unfold
        /// Its mirror — accelerating away.
        case fold

        /// Control points for the two custom curves; nil means "AppKit's named
        /// timing function is exactly right".
        public var control: (Double, Double, Double, Double)? {
            switch self {
            case .easeOut, .easeIn: return nil
            case .unfold: return PillMotion.noticeUnfoldControl
            case .fold: return PillMotion.noticeFoldControl
            }
        }
    }

    /// Whether app-authored copy is arriving in the tail, leaving it, or
    /// neither. A *live partial* is none of these: it grows word by word and
    /// wants the 120 ms width spring, while a notice, an error, a miss or a
    /// patience line is a toast and wants Wispr's 400 ms unfold.
    public enum NoticeChange: Equatable, Sendable {
        case none
        case opening
        case closing

        /// Derived from two renders. `message` is the discriminator because it
        /// is set by exactly the paths that author copy — and never by
        /// `livePartial`, which fills `bubble` alone.
        public static func between(_ old: PillRender, _ new: PillRender) -> NoticeChange {
            if old.bubble.isEmpty, !new.bubble.isEmpty, !new.message.isEmpty { return .opening }
            if !old.bubble.isEmpty, new.bubble.isEmpty, !old.message.isEmpty { return .closing }
            return .none
        }
    }

    /// What `Pill.apply` should do to the panel frame for one render change.
    /// Pure, so every row is a unit test.
    public struct FrameChange: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            case none
            /// Order front, fade 0 → 1, rise `travel` pt.
            case appear
            /// Fade 1 → 0, sink `travel` pt, order out on completion.
            case hide
            /// Animate `setFrame` to the new width.
            case resize
            /// The commit's contraction back to the resting capsule — same
            /// mechanism, its own timing.
            case contract
        }

        public var kind: Kind
        public var duration: Double
        /// Vertical travel in points. 0 under Reduce Motion — only motion goes.
        public var travel: Double
        /// Whether the frame itself animates. Reduce Motion snaps the frame but
        /// keeps the opacity fades — durations survive.
        public var animatesFrame: Bool
        public var curve: Curve

        public init(kind: Kind, duration: Double, travel: Double,
                    animatesFrame: Bool, curve: Curve = .easeOut) {
            self.kind = kind
            self.duration = duration
            self.travel = travel
            self.animatesFrame = animatesFrame
            self.curve = curve
        }
    }

    public static func frameChange(wasVisible: Bool, isVisible: Bool,
                                   oldWidth: Double, newWidth: Double,
                                   newState: PillState,
                                   reduceMotion: Bool,
                                   notice: NoticeChange = .none,
                                   oldHeight: Double = -1,
                                   newHeight: Double = -1) -> FrameChange {
        if isVisible && !wasVisible {
            return FrameChange(kind: .appear, duration: appearDuration,
                               travel: reduceMotion ? 0 : appearRise,
                               animatesFrame: !reduceMotion, curve: .easeOut)
        }
        if !isVisible && wasVisible {
            return FrameChange(kind: .hide, duration: hideDuration,
                               travel: reduceMotion ? 0 : hideSink,
                               animatesFrame: !reduceMotion, curve: .easeIn)
        }
        let heightChanged = oldHeight >= 0 && newHeight >= 0 && oldHeight != newHeight
        let swapped = oldHeight >= 0 && newHeight >= 0
            && oldWidth == newHeight && oldHeight == newWidth
            && oldWidth != newWidth
        if isVisible && swapped {
            return FrameChange(kind: .resize, duration: orientationDuration,
                               travel: 0, animatesFrame: !reduceMotion, curve: .easeOut)
        }
        if isVisible && (oldWidth != newWidth || heightChanged) {
            // The commit is the one shrink with its own name: the pill is
            // returning to rest, not resizing for content. The settle into the
            // mini idle sliver is the same going-to-rest move, so it shares
            // the contract timing rather than the content-resize timing.
            // Vertical docks shrink along height instead of width.
            if (newState == .success || newState == .idle)
                && notice != .closing
                && (newWidth < oldWidth || (oldHeight >= 0 && newHeight >= 0 && newHeight < oldHeight)) {
                return FrameChange(kind: .contract, duration: committedDuration,
                                   travel: 0, animatesFrame: !reduceMotion, curve: .easeOut)
            }
            switch notice {
            case .opening:
                return FrameChange(kind: .resize, duration: noticeUnfoldDuration,
                                   travel: 0, animatesFrame: !reduceMotion, curve: .unfold)
            case .closing:
                return FrameChange(kind: .resize, duration: noticeFoldDuration,
                                   travel: 0, animatesFrame: !reduceMotion, curve: .fold)
            case .none:
                return FrameChange(kind: .resize, duration: widthDuration,
                                   travel: 0, animatesFrame: !reduceMotion, curve: .easeOut)
            }
        }
        return FrameChange(kind: .none, duration: 0, travel: 0, animatesFrame: false)
    }
}
