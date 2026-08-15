import XCTest
@testable import WispritMacUI

/// The design tokens — `ui-redesign.md` §1.
///
/// A `Color` is opaque, so none of this asserts on one. It asserts on the hex
/// pairs the tokens are built from, which is where the two contracts worth
/// testing actually live: the contrast floors (§1.2) and the orange rule
/// (§1.6). Both are the kind of thing a well-meaning future diff breaks.
final class ThemeTests: XCTestCase {

    // MARK: - the palette itself

    func testSitePaletteIsTranscribedExactly() {
        XCTAssertEqual(Theme.Token.ground.light, 0xF5F6F8, "site --bg")
        XCTAssertEqual(Theme.Token.ink.light, 0x191C20, "site --ink")
        XCTAssertEqual(Theme.Token.inkSecondary.light, 0x5A626C, "site --muted")
        XCTAssertEqual(Theme.Token.hairline.light, 0xE3E6EA, "site --line")
        XCTAssertEqual(Theme.Token.hot.light, 0xF07818, "mic-orange")
        XCTAssertEqual(Theme.Token.hot.dark, 0xFF8A2B, "brightened; F07818 goes muddy on near-black")
    }

    func testTokenNamesAreUniqueAndComplete() {
        let names = Theme.Token.all.map(\.name)
        XCTAssertEqual(Set(names).count, names.count, "a duplicated token name is a silent override")
        XCTAssertEqual(Theme.Token.all.count, 25)
    }

    /// The pill floats over an unknown app's content, so its family must not
    /// move with the appearance (§1.2).
    func testTheStudioFamilyIsAppearanceIndependent() {
        for token in [Theme.Token.studio, Theme.Token.studioInk, Theme.Token.studioMuted,
                          Theme.Token.studioStroke, Theme.Token.studioAlarm,
                          Theme.Token.studioAttention] {
            XCTAssertEqual(token.light, token.dark, token.name)
            XCTAssertEqual(token.hex(dark: true), token.hex(dark: false), token.name)
        }
        XCTAssertEqual(Theme.Token.studioStroke.alpha, 0.14, "the pill's 1 pt rim")
    }

    // MARK: - the orange rule (§1.6)

    /// Every route to mic-orange goes through a `LiveSurface`, and every case
    /// of that enum is a surface that only exists while the mic is open.
    func testTheHotFamilyIsClosed() {
        XCTAssertEqual(Theme.Token.hotFamily.map(\.name), ["hot", "hotDeep", "hotText", "hotWash"])
        let hotHexes = Set(Theme.Token.hotFamily.flatMap { [$0.light, $0.dark] })
        for token in Theme.Token.all where !Theme.Token.hotFamily.contains(token) {
            XCTAssertFalse(hotHexes.contains(token.light), "\(token.name) borrows a hot value")
            XCTAssertFalse(hotHexes.contains(token.dark), "\(token.name) borrows a hot value")
        }
    }

    func testEverySanctionedSurfaceIsLiveAudio() {
        XCTAssertEqual(Set(LiveSurface.allCases.map(\.rawValue)), [
            "pillWaveform",        // the pill's meter while listening
            "menuBarRecording",    // the menu-bar icon while recording
            "sidebarStatusDot",    // the Hub's live status dot
            "micTestWaveform",     // onboarding's mic test
            "heldKeycap",          // the key is held, so the mic is open
            "liveTranscriptRow",   // the row being dictated right now
        ])
    }

    /// The corollary that keeps the tally meaningful: Doctor's warn colour is a
    /// dark ochre, 20° away from mic-orange, and it is never a fill.
    func testWarnIsOchreAndNotOrange() {
        XCTAssertEqual(Theme.Token.attention.light, 0xA16207)
        XCTAssertEqual(Theme.Token.attention.dark, 0xD9A441)
        XCTAssertNotEqual(Theme.Token.attention.light, Theme.Token.hot.light)
        XCTAssertGreaterThan(hue(Theme.Token.attention.light), hue(Theme.Token.hot.light),
                             "ochre sits further toward yellow — it is not a second orange")
    }

    // MARK: - the contrast contract (§1.2)

    func testInkContrastFloors() {
        XCTAssertGreaterThanOrEqual(contrast(Theme.Token.ink.light, Theme.Token.surface.light), 13)
        XCTAssertGreaterThanOrEqual(contrast(Theme.Token.ink.dark, Theme.Token.surface.dark), 13)
        XCTAssertGreaterThanOrEqual(contrast(Theme.Token.inkSecondary.light, Theme.Token.surface.light), 5.5)
        XCTAssertGreaterThanOrEqual(contrast(Theme.Token.inkSecondary.dark, Theme.Token.surface.dark), 5.5)
        // A 3:1 token: legal at 11 pt medium and above, illegal for body copy.
        XCTAssertGreaterThanOrEqual(contrast(Theme.Token.inkTertiary.light, Theme.Token.surface.light), 3)
        XCTAssertGreaterThanOrEqual(contrast(Theme.Token.inkTertiary.dark, Theme.Token.surface.dark), 3)
    }

    /// `hot` is not a text colour and the palette proves it; `hotText` is the
    /// one that is.
    func testHotIsNeverTextAndHotTextIs() {
        XCTAssertLessThan(contrast(Theme.Token.hot.light, Theme.Token.surface.light), 3,
                          "hot on light is ~2.9:1 — never text")
        XCTAssertGreaterThanOrEqual(contrast(Theme.Token.hotText.light, Theme.Token.surface.light), 4.5)
        XCTAssertGreaterThanOrEqual(contrast(Theme.Token.hotText.dark, Theme.Token.surface.dark), 4.5)
    }

    func testStatusColoursAreLegible() {
        for token in [Theme.Token.positive, Theme.Token.attention, Theme.Token.critical] {
            XCTAssertGreaterThanOrEqual(contrast(token.light, Theme.Token.surface.light), 3,
                                        "\(token.name) light")
            XCTAssertGreaterThanOrEqual(contrast(token.dark, Theme.Token.surface.dark), 3,
                                        "\(token.name) dark")
        }
    }

    // MARK: - type, spacing, radii

    func testTypeScaleMatchesTheSpec() {
        XCTAssertEqual(Theme.Role.pageTitle.size, 22)
        XCTAssertEqual(Theme.Role.pageTitle.weight, .semibold)
        XCTAssertEqual(Theme.Role.body.size, 13)
        XCTAssertEqual(Theme.Role.caption.size, 11)
        XCTAssertEqual(Theme.Role.mono.family, .mono, "machine text")
        XCTAssertEqual(Theme.Role.monoEmph.size, 12)
    }

    /// The serif appears in exactly two situations: numerals, and the
    /// onboarding cover title. Nothing else may be `.serif`.
    func testOnlyNumeralsUseTheSerif() {
        let serifRoles = Theme.Role.all.filter { $0.family == .serif }.map(\.name)
        XCTAssertEqual(serifRoles, ["numeralXL", "numeralL"])
    }

    /// Outside the .app bundle the family is not installed and the system serif
    /// stands in — `swift run` must still render.
    func testSerifAlwaysResolves() {
        switch Theme.resolveSerif() {
        case .bundled(let family): XCTAssertEqual(family, Theme.serifFamilyName)
        case .systemFallback: break
        }
        XCTAssertEqual(Theme.serifFamilyName, "Instrument Serif")
    }

    func testSpacingIsOnTheFourPointGrid() {
        XCTAssertEqual(Theme.Space.scale, [2, 4, 8, 12, 16, 20, 24, 32, 40, 48, 64])
        for step in Theme.Space.scale {
            XCTAssertEqual(step.truncatingRemainder(dividingBy: 2), 0, "\(step) is off the grid")
        }
    }

    func testRadiiComeFromTheSevenValueSet() {
        XCTAssertEqual(Theme.Radius.scale, [3, 6, 8, 10, 12, 16, 18])
        XCTAssertEqual(Theme.Radius.card, 18, "the content card")
        XCTAssertEqual(Theme.Radius.capsule(height: PillGeometry.height), PillGeometry.radius)
    }

    func testChartRampIsInkAndReservesCriticalForEmpty() {
        XCTAssertEqual(Theme.chartRampAlphas, [1.0, 0.72, 0.52, 0.36, 0.24])
        XCTAssertEqual(Theme.chartRampAlphas.count, 5)
        XCTAssertEqual(Theme.chartEmptyAlpha, 0.55)
    }

    // MARK: - helpers

    /// WCAG 2.1 relative luminance.
    private func luminance(_ hex: UInt32) -> Double {
        func channel(_ raw: UInt32) -> Double {
            let c = Double(raw) / 255.0
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel((hex >> 16) & 0xFF)
             + 0.7152 * channel((hex >> 8) & 0xFF)
             + 0.0722 * channel(hex & 0xFF)
    }

    private func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let (l1, l2) = (luminance(a), luminance(b))
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    /// Hue in degrees, for the "ochre is not a second orange" check.
    private func hue(_ hex: UInt32) -> Double {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        let maxV = max(r, g, b), minV = min(r, g, b)
        let delta = maxV - minV
        guard delta > 0 else { return 0 }
        var h: Double
        if maxV == r { h = 60 * ((g - b) / delta) }
        else if maxV == g { h = 60 * (2 + (b - r) / delta) }
        else { h = 60 * (4 + (r - g) / delta) }
        return h < 0 ? h + 360 : h
    }
}
