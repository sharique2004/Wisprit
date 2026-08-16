import XCTest
@testable import WispritMacUI

/// Empty / too-quiet / nothing-heard: a graceful wiggle, never red, never a
/// banner. The session still calls `flashTooQuiet` / `flashMissed` with copy;
/// the pill ignores the words and shakes, then settles to idle.
final class PillTooQuietTests: XCTestCase {

    /// Kept as a literal on purpose: `SessionController` owns the words and this
    /// target cannot import it. Length is no longer a layout contract — the
    /// pill does not draw the line — but the session still sends it.
    private let copy = "Heard you, but too faint — speak up"

    func testTooQuietIsAWiggleWithNoBanner() {
        let model = PillModel()
        model.flashTooQuiet(copy)

        XCTAssertEqual(model.bubble, "", "no too-quiet banner")
        XCTAssertEqual(model.message, "")
        XCTAssertFalse(model.bubble.hasSuffix("…"))
        XCTAssertTrue(model.render.isShaking)
        XCTAssertEqual(model.state, .idle)
        XCTAssertTrue(model.isVisible)
    }

    func testItDoesNotBorrowTheAlarmWidthOrBody() {
        let model = PillModel()
        model.flashTooQuiet(copy)
        XCTAssertEqual(model.render.totalWidth, PillGeometry.widthListening)
        XCTAssertEqual(PillPalette.bodyFill(for: model.state).color, PillPalette.body)
        XCTAssertNotEqual(model.render.tint, PillPalette.critical)
        XCTAssertEqual(model.render.glyph, .none)
        XCTAssertEqual(model.render.hoverChrome, .none)
    }

    func testMissedAndTooQuietShareTheSameWiggleTiming() {
        final class Sink { var scheduled: [(seconds: Double, action: PillDeferredAction)] = [] }
        let sink = Sink()
        let model = PillModel()
        model.onSchedule = { sink.scheduled.append((seconds: $0, action: $1)) }
        model.flashTooQuiet(copy)

        XCTAssertEqual(sink.scheduled.count, 1)
        XCTAssertEqual(sink.scheduled.first?.seconds, PillMotion.shakeDuration)
        XCTAssertEqual(sink.scheduled.first?.action, .settle)
        XCTAssertLessThan(PillMotion.shakeDuration, 0.6,
                          "a password-field no, not a held error")
    }

    func testSuppressionIsHonoured() {
        let model = PillModel(isSuppressed: { true })
        model.flashTooQuiet(copy)
        XCTAssertEqual(model.bubble, "")
        XCTAssertFalse(model.isVisible)
        XCTAssertFalse(model.render.isShaking)
    }

    func testTheWiggleIsSmallAndSpringy() {
        XCTAssertEqual(PillMotion.shakeAmplitude, 7.0)
        XCTAssertEqual(PillMotion.shakeCycles, 3.0)
        XCTAssertEqual(PillMotion.shakeDuration, 0.42)
        XCTAssertGreaterThan(PillMotion.shakeDecay, 6,
                             "the last millimetre must die out, not slam")
        XCTAssertLessThan(PillMotion.shakeAmplitude, 12,
                          "password-field no, not a rumble")
    }
}
