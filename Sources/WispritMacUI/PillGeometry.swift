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
        guard n > 0 else { return 0 }
        let raw = 2 * textInset + Double(n) * characterWidth
        let stepped = (raw / widthStep).rounded(.up) * widthStep
        return min(maxWidth, max(minWidth, stepped))
    }

    /// Total panel width for a given tail width — `64.5 + w`.
    public static func totalWidth(tailWidth: Double) -> Double {
        tailWidth <= 0 ? PillGeometry.widthListening : chrome + tailWidth
    }
}
