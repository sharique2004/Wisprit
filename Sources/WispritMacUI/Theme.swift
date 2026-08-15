import Foundation
#if canImport(SwiftUI)
import SwiftUI
#endif
#if canImport(AppKit)
import AppKit
#endif

/// The design tokens — `docs/design/ui-redesign.md` §1, transcribed.
///
/// Two rules make this file worth reading:
///
/// 1. **Nothing in the UI may use a literal colour.** `Color.blue`, `.red`,
///    `.orange` and `.quaternary` are the old window's placeholders; every
///    surface now names a token here.
/// 2. **`hot` is load-bearing** (§1.6). The mic-orange family is only reachable
///    through `Theme.hot(_:)` and friends, each of which demands a
///    `LiveSurface` — and every case of that enum is a surface that exists only
///    while the microphone is open. A reviewer who sees orange anywhere else
///    rejects the diff; this makes "anywhere else" hard to write by accident.
///
/// The raw hex pairs live in `Theme.Token` as plain values rather than
/// `Color`s, because a `Color` is opaque: keeping the numbers in a value type
/// is what lets `WispritMacUITests` pin the palette (and the orange rule)
/// without a window server or an appearance.

// MARK: - tokens

/// One palette entry: the two hex values it resolves to, and the name §1 calls
/// it. `alpha` is only non-1 for the pill's rim (`#FFFFFF` @ 14%).
public struct ColorToken: Equatable, Hashable, Sendable {
    public let name: String
    public let light: UInt32
    public let dark: UInt32
    public let alpha: Double

    public init(_ name: String, light: UInt32, dark: UInt32, alpha: Double = 1.0) {
        self.name = name
        self.light = light
        self.dark = dark
        self.alpha = alpha
    }

    /// An appearance-independent token — the `studio*` family, which floats
    /// over arbitrary content and must read the same in both modes (§1.2).
    public init(_ name: String, both: UInt32, alpha: Double = 1.0) {
        self.init(name, light: both, dark: both, alpha: alpha)
    }

    /// The value for a given appearance. The pill reaches for `.dark`
    /// unconditionally — its ground is always near-black (§1.7).
    public func hex(dark isDark: Bool) -> UInt32 { isDark ? dark : light }
}

/// The five surfaces on which mic-orange is sanctioned (§1.6, plus §4.4's held
/// keycap and §1.1's live-row wash). Every one of them is live audio: the app
/// has a tally light, and the tally never lies.
public enum LiveSurface: String, Equatable, Sendable, CaseIterable {
    /// The pill's waveform while listening (§1.6 site 1).
    case pillWaveform
    /// The menu-bar icon while recording (§1.6 site 2).
    case menuBarRecording
    /// The Hub sidebar's status dot (§1.6 site 3).
    case sidebarStatusDot
    /// The onboarding mic test's bars (§1.6 site 3).
    case micTestWaveform
    /// A held `KeycapView` — the key is down, so the mic is open (§4.4).
    case heldKeycap
    /// The wash behind the transcript row currently being dictated (§1.1).
    case liveTranscriptRow
}

/// Which font a type role is drawn in. `Font` cannot be compared, so the roles
/// are declared as values and mapped to `Font` at the edge.
public enum TypeFamily: String, Equatable, Sendable {
    /// SF Pro Text / Display — `Font.system` picks the optical size itself.
    case system
    /// SF Mono. "This text was produced by a machine" (§1.4).
    case mono
    /// Instrument Serif, falling back to `.system(design: .serif)`.
    case serif
}

public enum TypeWeight: String, Equatable, Sendable {
    case light, regular, medium, semibold
}

/// One row of the §1.3 type scale.
public struct TypeRole: Equatable, Sendable {
    public let name: String
    public let size: Double
    public let weight: TypeWeight
    public let tracking: Double
    public let family: TypeFamily

    public init(_ name: String, size: Double, weight: TypeWeight = .regular,
                tracking: Double = 0, family: TypeFamily = .system) {
        self.name = name
        self.size = size
        self.weight = weight
        self.tracking = tracking
        self.family = family
    }
}

/// How `Theme.serif(_:)` resolved: the bundled family, or the system's serif
/// design. `swift run` outside the .app bundle takes the fallback and every
/// layout still holds (§1.3).
public enum SerifResolution: Equatable, Sendable {
    case bundled(String)
    case systemFallback
}

public enum Theme {

    // MARK: palette (§1.1 light / §1.2 dark)

    public enum Token {
        public static let ground = ColorToken("ground", light: 0xF5F6F8, dark: 0x131619)
        public static let groundRecessed = ColorToken("groundRecessed", light: 0xEDEFF3, dark: 0x0E1114)
        public static let surface = ColorToken("surface", light: 0xFFFFFF, dark: 0x1B1F24)
        public static let surfaceRaised = ColorToken("surfaceRaised", light: 0xFFFFFF, dark: 0x21262C)
        public static let fillSubtle = ColorToken("fillSubtle", light: 0xE7EAEE, dark: 0x23272D)
        public static let fillHover = ColorToken("fillHover", light: 0xEDEFF2, dark: 0x1E2126)
        public static let hairline = ColorToken("hairline", light: 0xE3E6EA, dark: 0x2A2F36)
        public static let hairlineStrong = ColorToken("hairlineStrong", light: 0xD4D8DD, dark: 0x3A4048)
        public static let ink = ColorToken("ink", light: 0x191C20, dark: 0xE9ECF0)
        public static let inkSecondary = ColorToken("inkSecondary", light: 0x5A626C, dark: 0x9AA3AD)
        public static let inkTertiary = ColorToken("inkTertiary", light: 0x8A929C, dark: 0x6C757F)
        public static let inkQuaternary = ColorToken("inkQuaternary", light: 0xB4BAC2, dark: 0x4A525B)

        /// LIVE ONLY (§1.6). Brightened on dark because `#F07818` goes muddy on
        /// near-black — which is also why the pill takes the dark value.
        public static let hot = ColorToken("hot", light: 0xF07818, dark: 0xFF8A2B)
        public static let hotDeep = ColorToken("hotDeep", light: 0xD4650E, dark: 0xF07818)
        /// The only orange allowed as *text* on light (≈5.2:1). `hot` itself is
        /// 2.9:1 and is never text.
        public static let hotText = ColorToken("hotText", light: 0xB4500A, dark: 0xFF9E4F)
        public static let hotWash = ColorToken("hotWash", light: 0xFDF6EF, dark: 0x2A1B0E)

        public static let positive = ColorToken("positive", light: 0x1F8A54, dark: 0x46C98A)
        /// Doctor `.warn` — a dark ochre, deliberately not amber-orange (§1.6).
        /// Glyph and text only, never a fill wider than 16 pt.
        public static let attention = ColorToken("attention", light: 0xA16207, dark: 0xD9A441)
        public static let critical = ColorToken("critical", light: 0xC4342B, dark: 0xFF6B5E)

        /// The pill body, in both appearances.
        public static let studio = ColorToken("studio", both: 0x0E1013)
        public static let studioInk = ColorToken("studioInk", both: 0xE8EAED)
        public static let studioMuted = ColorToken("studioMuted", both: 0x9AA3AD)
        /// The pill's 1 pt rim: `#FFFFFF` @ 14%.
        public static let studioStroke = ColorToken("studioStroke", both: 0xFFFFFF, alpha: 0.14)
        /// The error pill's body (§2.4) — not a §1.1 token, but it belongs with
        /// the studio family: same surface, same appearance-independence.
        public static let studioAlarm = ColorToken("studioAlarm", both: 0x2A1416)
        /// The **blocked-secure** pill's body: the same near-black shifted
        /// toward `attention` rather than `critical`.
        ///
        /// §2.4 gave the two alarm states one body, and looking at them side by
        /// side says that was one body too few. Nothing failed in a secure-input
        /// block — the text is on the clipboard and the user has one keystroke
        /// to press — so a red body is telling them the wrong thing before they
        /// have read a word of the right thing. Warm-black says "attention",
        /// which is what the ochre lock and the ochre rim on top of it also say.
        public static let studioAttention = ColorToken("studioAttention", both: 0x2A2214)

        /// Every token, for the invariants `ThemeTests` pins.
        public static let all: [ColorToken] = [
            ground, groundRecessed, surface, surfaceRaised, fillSubtle, fillHover,
            hairline, hairlineStrong, ink, inkSecondary, inkTertiary, inkQuaternary,
            hot, hotDeep, hotText, hotWash, positive, attention, critical,
            studio, studioInk, studioMuted, studioStroke, studioAlarm, studioAttention,
        ]

        /// The mic-orange family. Nothing outside `Theme.hot*(_:)` may name
        /// these, and those all demand a `LiveSurface`.
        public static let hotFamily: [ColorToken] = [hot, hotDeep, hotText, hotWash]
    }

    // MARK: type (§1.3)

    public enum Role {
        /// The one big number on a page.
        public static let numeralXL = TypeRole("numeralXL", size: 40, tracking: -0.4, family: .serif)
        /// Insights tile values.
        public static let numeralL = TypeRole("numeralL", size: 28, tracking: -0.2, family: .serif)
        public static let pageTitle = TypeRole("pageTitle", size: 22, weight: .semibold, tracking: -0.2)
        public static let sectionTitle = TypeRole("sectionTitle", size: 15, weight: .semibold)
        public static let rowTitle = TypeRole("rowTitle", size: 13, weight: .medium)
        public static let body = TypeRole("body", size: 13)
        public static let caption = TypeRole("caption", size: 11, tracking: 0.1)
        public static let captionEmph = TypeRole("captionEmph", size: 11, weight: .medium, tracking: 0.3)
        /// Machine text (§1.4) — the pill's live tail, latency readouts, paths.
        public static let mono = TypeRole("mono", size: 11, family: .mono)
        public static let monoEmph = TypeRole("monoEmph", size: 12, weight: .medium, family: .mono)

        public static let all: [TypeRole] = [
            numeralXL, numeralL, pageTitle, sectionTitle, rowTitle,
            body, caption, captionEmph, mono, monoEmph,
        ]
    }

    /// The serif ships as one file, one weight, and appears in exactly two
    /// situations: numerals, and the onboarding cover title (§1.3).
    public static let serifFamilyName = "Instrument Serif"

    /// Whether the bundled family is installed. Outside the .app bundle
    /// (`swift run`) it is not, and the system serif stands in.
    public static func resolveSerif() -> SerifResolution {
        #if canImport(AppKit)
        if NSFont(name: serifFamilyName, size: 12) != nil {
            return .bundled(serifFamilyName)
        }
        #endif
        return .systemFallback
    }

    // MARK: spacing, radii, sizing (§1.5)

    /// 4 pt grid; prefer 8 pt steps. Nothing outside `scale` may appear in a
    /// `padding` or `spacing`.
    public enum Space {
        public static let s2: Double = 2
        public static let s4: Double = 4
        public static let s8: Double = 8
        public static let s12: Double = 12
        public static let s16: Double = 16
        public static let s20: Double = 20
        public static let s24: Double = 24
        public static let s32: Double = 32
        public static let s40: Double = 40
        public static let s48: Double = 48
        public static let s64: Double = 64

        public static let scale: [Double] = [s2, s4, s8, s12, s16, s20, s24, s32, s40, s48, s64]
    }

    public enum Radius {
        /// Inline chips, badges.
        public static let chip: Double = 3
        /// Search fields, small buttons, sidebar selection.
        public static let control: Double = 6
        /// List rows, inner wells.
        public static let row: Double = 8
        public static let button: Double = 10
        /// Grouped blocks, sheet corners.
        public static let group: Double = 12
        public static let tile: Double = 16
        /// The content card.
        public static let card: Double = 18

        public static let scale: [Double] = [chip, control, row, button, group, tile, card]

        /// The pill, tokens, the sidebar status dot.
        public static func capsule(height: Double) -> Double { height / 2 }
    }

    public enum Size {
        /// macOS convention for a row-trailing icon button — not iOS's 44.
        public static let hitTarget: Double = 28
        public static let rowHeight: Double = 32
        /// A row that carries a description line.
        public static let rowHeightWithDescription: Double = 44
    }

    // MARK: charts (§3.5)

    /// A five-step ink ramp. Series are distinguished by ramp position and an
    /// always-visible label — never by hue. No orange, no categorical rainbow.
    public static let chartRampAlphas: [Double] = [1.0, 0.72, 0.52, 0.36, 0.24]
    /// Reserved for the `empty` segment, and for nothing else.
    public static let chartEmptyAlpha: Double = 0.55
}

// MARK: - SwiftUI edge

#if canImport(SwiftUI)
extension Color {
    /// §6.2 — a dynamic `NSColor`, not an `@Environment(\.colorScheme)` branch
    /// in a view body. The pill's AppKit layer and the Hub's SwiftUI layer read
    /// the same token, and an appearance change costs no view invalidation.
    public init(light: UInt32, dark: UInt32, alpha: Double = 1.0) {
        #if canImport(AppKit)
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light, alpha: alpha)
        })
        #else
        self.init(hex: light, alpha: alpha)
        #endif
    }

    public init(_ token: ColorToken) {
        self.init(light: token.light, dark: token.dark, alpha: token.alpha)
    }

    /// Non-AppKit fallback, and the explicit-appearance path the pill uses.
    public init(hex: UInt32, alpha: Double = 1.0) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255.0,
                  green: Double((hex >> 8) & 0xFF) / 255.0,
                  blue: Double(hex & 0xFF) / 255.0,
                  opacity: alpha)
    }
}

extension Theme {
    public static var ground: Color { Color(Token.ground) }
    public static var groundRecessed: Color { Color(Token.groundRecessed) }
    public static var surface: Color { Color(Token.surface) }
    public static var surfaceRaised: Color { Color(Token.surfaceRaised) }
    public static var fillSubtle: Color { Color(Token.fillSubtle) }
    public static var fillHover: Color { Color(Token.fillHover) }
    public static var hairline: Color { Color(Token.hairline) }
    public static var hairlineStrong: Color { Color(Token.hairlineStrong) }
    public static var ink: Color { Color(Token.ink) }
    public static var inkSecondary: Color { Color(Token.inkSecondary) }
    public static var inkTertiary: Color { Color(Token.inkTertiary) }
    public static var inkQuaternary: Color { Color(Token.inkQuaternary) }
    public static var positive: Color { Color(Token.positive) }
    public static var attention: Color { Color(Token.attention) }
    public static var critical: Color { Color(Token.critical) }
    public static var studio: Color { Color(Token.studio) }
    public static var studioInk: Color { Color(Token.studioInk) }
    public static var studioMuted: Color { Color(Token.studioMuted) }
    public static var studioStroke: Color { Color(Token.studioStroke) }

    /// Mic-orange. The `LiveSurface` argument is the whole point: there is no
    /// way to spell this without naming a surface that only exists while the
    /// microphone is open (§1.6).
    public static func hot(_ surface: LiveSurface) -> Color { Color(Token.hot) }
    /// Pressed/hover state of a `hot` fill.
    public static func hotDeep(_ surface: LiveSurface) -> Color { Color(Token.hotDeep) }
    /// The only orange legible as text on light.
    public static func hotText(_ surface: LiveSurface) -> Color { Color(Token.hotText) }
    /// The tint behind a live row.
    public static func hotWash(_ surface: LiveSurface) -> Color { Color(Token.hotWash) }

    /// §1.3, resolved. Tracking is applied by the caller with `.tracking(_:)`
    /// because it is a modifier, not part of a `Font`.
    public static func font(_ role: TypeRole) -> Font {
        switch role.family {
        case .system:
            return .system(size: role.size, weight: weight(role.weight))
        case .mono:
            return .system(size: role.size, weight: weight(role.weight), design: .monospaced)
        case .serif:
            return serif(role.size)
        }
    }

    /// The serif, or the system's serif design when the family is not bundled.
    public static func serif(_ size: Double) -> Font {
        switch resolveSerif() {
        case .bundled(let family): return .custom(family, size: size)
        case .systemFallback: return .system(size: size, design: .serif)
        }
    }

    /// The five-step ink ramp, ready to fill with.
    public static var chartRamp: [Color] {
        chartRampAlphas.map { ink.opacity($0) }
    }

    /// The `empty` segment's reserved colour.
    public static var chartEmpty: Color { critical.opacity(chartEmptyAlpha) }

    private static func weight(_ w: TypeWeight) -> Font.Weight {
        switch w {
        case .light: return .light
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        }
    }
}
#endif

#if canImport(AppKit)
extension NSColor {
    /// `0xRRGGBB` in sRGB. The site's hex values are sRGB, so this must not be
    /// the calibrated space `pill.py` used.
    public convenience init(hex: UInt32, alpha: Double = 1.0) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255.0,
                  green: CGFloat((hex >> 8) & 0xFF) / 255.0,
                  blue: CGFloat(hex & 0xFF) / 255.0,
                  alpha: CGFloat(alpha))
    }
}
#endif
