import XCTest
@testable import WispritMacUI

/// The marginal-audio flash (2026-08-15) — the one piece of pill copy that is an
/// INSTRUCTION rather than a label, and therefore the one that must survive the
/// frame intact.
///
/// A plain `flashMissed` lays its text out with the live tail's 196 pt cap,
/// which fits about 26 characters: enough to render "Heard you, but too faint"
/// and cut off the part that tells the user what to do. That is worse than
/// saying nothing, so this state borrows the alarm layout (40-character budget,
/// wider cap) and the `blockedSecure` dwell — without borrowing the alarm.
final class PillTooQuietTests: XCTestCase {

    /// Kept as a literal on purpose: `SessionController` owns the words and this
    /// target cannot import it, so the copy's LENGTH is the contract under test.
    private let copy = "Heard you, but too faint — speak up"

    func testTheRemedyIsNotCutOff() {
        let model = PillModel()
        model.flashTooQuiet(copy)

        XCTAssertEqual(model.bubble, copy, "every word of it, ellipsis-free")
        XCTAssertFalse(model.bubble.hasSuffix("…"))
        XCTAssertEqual(model.message, copy)
    }

    /// Wider than any live tail can be — which is the whole reason this method
    /// exists rather than a `flashMissed` call with longer copy.
    func testItIsLaidOutWithTheAlarmStatesWidth() {
        let model = PillModel()
        model.flashTooQuiet(copy)
        XCTAssertGreaterThan(model.bubbleWidth, PillTailGeometry.maxWidth)
        XCTAssertEqual(model.bubbleWidth,
                       PillTailGeometry.errorWidth(forCharacters: copy.count))
    }

    /// A miss, not a fault: the `missed` body — muted ink, no glyph, no shake.
    func testItIsStillAMissAndNotAnAlarm() {
        let model = PillModel()
        model.flashTooQuiet(copy)
        XCTAssertEqual(model.state, .missed)
        XCTAssertTrue(model.isVisible)
    }

    /// Long enough to read a sentence and act on it. 0.9 s is the right dwell
    /// for two words and the wrong one for this.
    func testItStaysLongEnoughToActOn() {
        final class Sink { var scheduled: [(seconds: Double, action: PillDeferredAction)] = [] }
        let sink = Sink()
        let model = PillModel()
        model.onSchedule = { sink.scheduled.append((seconds: $0, action: $1)) }
        model.flashTooQuiet(copy)

        XCTAssertEqual(sink.scheduled.count, 1)
        XCTAssertEqual(sink.scheduled.first?.seconds, PillGeometry.blockedSecureHideDelay)
        XCTAssertEqual(sink.scheduled.first?.action, .settle)
        XCTAssertGreaterThan(PillGeometry.blockedSecureHideDelay, PillGeometry.missedHideDelay)
    }

    /// `pill_hidden` silences it exactly like every other state.
    func testSuppressionIsHonoured() {
        let model = PillModel(isSuppressed: { true })
        model.flashTooQuiet(copy)
        XCTAssertEqual(model.bubble, "")
        XCTAssertFalse(model.isVisible)
    }
}
