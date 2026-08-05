import Foundation

/// Pill visual vocabulary — every constant here is transcribed from `pill.py`
/// (the numbers are load-bearing: the user has dragged this dot around for
/// months and any change reads as a different app).

/// Calibrated RGB triple, 0…1, matching `NSColor.colorWithCalibratedRed…`.
public struct PillColor: Equatable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double
    public init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }
}

/// The five pill states. `pill.py` keeps colours in `_COLORS` and reaches for a
/// neutral grey on any unknown key — `.hidden` is that neutral here.
public enum PillState: String, Equatable, Sendable, CaseIterable {
    case hidden
    case recording
    case finalizing
    case success
    case error
}

public enum PillPalette {
    /// `_COLORS` from pill.py, verbatim.
    public static let recording = PillColor(0.93, 0.26, 0.28)   // red
    public static let finalizing = PillColor(0.60, 0.62, 0.66)  // gray
    public static let success = PillColor(0.30, 0.78, 0.45)     // green
    public static let error = PillColor(0.95, 0.66, 0.22)       // amber
    /// `_COLORS.get(state, (0.6, 0.6, 0.6))` — also `_PillView`'s initial dot.
    public static let neutral = PillColor(0.6, 0.6, 0.6)

    public static func dot(for state: PillState) -> PillColor {
        switch state {
        case .recording: return recording
        case .finalizing: return finalizing
        case .success: return success
        case .error: return error
        case .hidden: return neutral
        }
    }
}

public enum PillGeometry {
    /// `PILL_W, PILL_H = 26.0, 26.0` — "just big enough to notice, never a text
    /// window".
    public static let width: Double = 26.0
    public static let height: Double = 26.0
    /// `_BOTTOM_MARGIN` for the default bottom-centre placement.
    public static let bottomMargin: Double = 90.0

    /// Halo: `NSMakeRect(1, 1, w - 2, h - 2)` at calibrated white 0.0 / alpha 0.28.
    public static let haloInset: Double = 1.0
    public static let haloAlpha: Double = 0.28
    /// Dot: `radius = 6.0 + level * 5.0`, filled at alpha 0.95.
    public static let dotBaseRadius: Double = 6.0
    public static let dotLevelGain: Double = 5.0
    public static let dotAlpha: Double = 0.95

    /// Auto-hide delays: `flash_success` 0.6 s, `flash_error` 1.6 s.
    public static let successHideDelay: Double = 0.6
    public static let errorHideDelay: Double = 1.6
    /// NEW — how long a `transientNotice` ("Learned Sharique") stays legible.
    /// Matched to the error flash: long enough to read two words, short enough
    /// that it is gone before the next utterance.
    public static let noticeDuration: Double = 1.6

    public static func dotRadius(forLevel level: Double) -> Double {
        dotBaseRadius + clampLevel(level) * dotLevelGain
    }

    /// `setLevel_` clamps with `max(0.0, min(1.0, float(level)))`; NaN is
    /// treated as silence rather than propagating into the frame maths.
    public static func clampLevel(_ level: Double) -> Double {
        guard level.isFinite else { return 0.0 }
        return max(0.0, min(1.0, level))
    }
}

/// Geometry of the transient text bubble that carries `livePartial` /
/// `transientNotice`. NEW surface — `pill.py`'s `update_partial` was an explicit
/// no-op, so this is a fresh design constrained to stay pill-shaped: the dot
/// never moves, the bubble grows to its right, and the width is quantised so a
/// per-word partial cannot make the window shiver.
public enum PillBubbleGeometry {
    /// Gap between the 26 pt dot square and the bubble.
    public static let gap: Double = 4.0
    /// Bubble height + corner radius (a capsule, vertically centred on the dot).
    public static let height: Double = 20.0
    public static var cornerRadius: Double { height / 2.0 }
    /// Horizontal text inset on each side.
    public static let textInset: Double = 7.0
    /// Advance of the 11 pt rounded system font, measured empirically. Only used
    /// for *sizing*; the text itself is truncated by the text system, so a small
    /// error can never clip mid-glyph, only leave a hair of padding.
    public static let characterWidth: Double = 6.5
    /// Widths snap to this step. Flicker control: partials arrive several times
    /// a second and an exact-fit width would resize the window on every word.
    public static let widthStep: Double = 8.0
    public static let minWidth: Double = 40.0
    public static let maxWidth: Double = 184.0

    /// Quantised bubble width for an `n`-character string. 0 characters means
    /// no bubble at all (the pill stays a 26×26 dot).
    public static func width(forCharacters n: Int) -> Double {
        guard n > 0 else { return 0 }
        let raw = 2 * textInset + Double(n) * characterWidth
        let stepped = (raw / widthStep).rounded(.up) * widthStep
        return min(maxWidth, max(minWidth, stepped))
    }

    /// Total panel width for a given bubble width.
    public static func totalWidth(bubbleWidth: Double) -> Double {
        bubbleWidth <= 0 ? PillGeometry.width : PillGeometry.width + gap + bubbleWidth
    }
}
