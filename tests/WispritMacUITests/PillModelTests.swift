import XCTest
@testable import WispritMacUI

/// Headless pill state-machine tests. `PillModel` owns every decision; the
/// NSPanel/NSView edge in `Pill.swift` owns nothing but drawing and a Timer, so
/// none of this needs a window server, an event tap or a TCC grant.
final class PillModelTests: XCTestCase {

    /// Recorder for the model's three output channels.
    private final class Sink {
        var frames: [PillRender] = []
        var scheduled: [(seconds: Double, action: PillDeferredAction)] = []
        var cancels = 0
        var last: PillRender { frames.last ?? .collapsed }
    }

    private func makeModel(suppressed: @escaping () -> Bool = { false }) -> (PillModel, Sink) {
        let sink = Sink()
        let model = PillModel(isSuppressed: suppressed)
        model.onRender = { sink.frames.append($0) }
        model.onSchedule = { sink.scheduled.append((seconds: $0, action: $1)) }
        model.onCancelSchedule = { sink.cancels += 1 }
        return (model, sink)
    }

    // MARK: - geometry & palette constants (pill.py, verbatim)

    func testPillGeometryMatchesPython() {
        XCTAssertEqual(PillGeometry.width, 26.0)
        XCTAssertEqual(PillGeometry.height, 26.0)
        XCTAssertEqual(PillGeometry.bottomMargin, 90.0)
        XCTAssertEqual(PillGeometry.haloAlpha, 0.28)
        XCTAssertEqual(PillGeometry.dotBaseRadius, 6.0)
        XCTAssertEqual(PillGeometry.dotLevelGain, 5.0)
        XCTAssertEqual(PillGeometry.successHideDelay, 0.6)
        XCTAssertEqual(PillGeometry.errorHideDelay, 1.6)
    }

    func testPaletteMatchesPython() {
        XCTAssertEqual(PillPalette.dot(for: .recording), PillColor(0.93, 0.26, 0.28))
        XCTAssertEqual(PillPalette.dot(for: .finalizing), PillColor(0.60, 0.62, 0.66))
        XCTAssertEqual(PillPalette.dot(for: .success), PillColor(0.30, 0.78, 0.45))
        XCTAssertEqual(PillPalette.dot(for: .error), PillColor(0.95, 0.66, 0.22))
        XCTAssertEqual(PillPalette.dot(for: .hidden), PillColor(0.6, 0.6, 0.6))
    }

    func testDotRadiusIsSixPlusLevelTimesFiveWithClamping() {
        XCTAssertEqual(PillGeometry.dotRadius(forLevel: 0.0), 6.0)
        XCTAssertEqual(PillGeometry.dotRadius(forLevel: 1.0), 11.0)
        XCTAssertEqual(PillGeometry.dotRadius(forLevel: 0.5), 8.5)
        XCTAssertEqual(PillGeometry.dotRadius(forLevel: -3.0), 6.0)     // max(0, …)
        XCTAssertEqual(PillGeometry.dotRadius(forLevel: 42.0), 11.0)    // min(1, …)
        XCTAssertEqual(PillGeometry.dotRadius(forLevel: .nan), 6.0)
    }

    // MARK: - state transitions

    func testShowRecordingGoesRedVisibleAndZeroLevel() {
        let (model, sink) = makeModel()
        model.updateLevel(0.8)
        model.showRecording()
        XCTAssertEqual(model.state, .recording)
        XCTAssertTrue(sink.last.isVisible)
        XCTAssertEqual(sink.last.dot, PillPalette.recording)
        XCTAssertEqual(sink.last.level, 0.0)
        XCTAssertEqual(sink.last.totalWidth, 26.0)
    }

    func testFullUtteranceHappyPath() {
        let (model, sink) = makeModel()
        model.showRecording()
        model.updateLevel(0.4)
        model.showFinalizing()
        XCTAssertEqual(model.state, .finalizing)
        XCTAssertEqual(sink.last.dot, PillPalette.finalizing)
        XCTAssertEqual(sink.last.level, 0.0, "finalizing resets the level meter")

        model.flashSuccess()
        XCTAssertEqual(model.state, .success)
        XCTAssertEqual(sink.scheduled.last?.seconds, 0.6)
        XCTAssertEqual(sink.scheduled.last?.action, .hide)

        model.fireDeferred(.hide)
        XCTAssertEqual(model.state, .hidden)
        XCTAssertFalse(sink.last.isVisible)
    }

    func testFlashErrorAutoHidesAfterOnePointSix() {
        let (model, sink) = makeModel()
        model.flashError("secure field — press ⌘⌃V to paste")
        XCTAssertEqual(model.state, .error)
        XCTAssertEqual(sink.last.dot, PillPalette.error)
        XCTAssertEqual(sink.scheduled.last?.seconds, 1.6)
        XCTAssertEqual(sink.scheduled.last?.action, .hide)
    }

    /// `_show` cancels the pending auto-hide before recolouring — a new
    /// utterance must not be hidden by the previous one's timer.
    func testEveryShowCancelsThePendingHide() {
        let (model, sink) = makeModel()
        model.flashSuccess()
        let before = sink.cancels
        model.showRecording()
        XCTAssertGreaterThan(sink.cancels, before)
    }

    func testHideCancelsAndCollapses() {
        let (model, sink) = makeModel()
        model.showRecording()
        model.livePartial("hello there world")
        model.hide()
        XCTAssertEqual(model.state, .hidden)
        XCTAssertFalse(sink.last.isVisible)
        XCTAssertEqual(sink.last.bubble, "")
        XCTAssertEqual(sink.last.totalWidth, 26.0)
        XCTAssertGreaterThan(sink.cancels, 0)
    }

    // MARK: - pill_hidden suppression

    func testSuppressedPillNeverShowsOrRenders() {
        let (model, sink) = makeModel(suppressed: { true })
        model.showRecording()
        model.updateLevel(0.9)
        model.livePartial("some words here")
        model.showFinalizing()
        model.transientNotice("Learned Sharique")
        XCTAssertTrue(sink.frames.isEmpty, "no frame should be emitted while pill_hidden")
        XCTAssertEqual(model.state, .hidden)
    }

    /// 1:1 with `flash_success`, which calls `_schedule_hide` unconditionally
    /// even when `_show` no-opped.
    func testSuppressedFlashStillSchedulesHide() {
        let (model, sink) = makeModel(suppressed: { true })
        model.flashSuccess()
        XCTAssertEqual(sink.scheduled.last?.seconds, 0.6)
        XCTAssertTrue(sink.frames.isEmpty)
    }

    // MARK: - level meter

    func testUpdateLevelDoesNotChangeVisibilityAndSkipsUnchangedFrames() {
        let (model, sink) = makeModel()
        model.updateLevel(0.5)
        XCTAssertFalse(sink.last.isVisible)
        model.showRecording()
        let count = sink.frames.count
        model.updateLevel(0.5)
        XCTAssertEqual(sink.frames.count, count + 1)
        model.updateLevel(0.5)
        XCTAssertEqual(sink.frames.count, count + 1, "an unchanged level must not redraw")
        XCTAssertEqual(sink.last.dotRadius, 8.5)
    }

    // MARK: - livePartial (NEW)

    func testLivePartialOnlyRendersWhileRecording() {
        let (model, sink) = makeModel()
        model.livePartial("idle words")
        XCTAssertEqual(model.bubble, "")

        model.showRecording()
        model.livePartial("hello there world")
        XCTAssertEqual(model.bubble, "hello there world")
        XCTAssertTrue(sink.last.totalWidth > PillGeometry.width)

        model.showFinalizing()
        XCTAssertEqual(model.bubble, "", "the tail collapses when recording ends")
        model.livePartial("late arrival")
        XCTAssertEqual(model.bubble, "", "a late partial must not reopen the bubble")
    }

    func testLivePartialShowsOnlyTheTail() {
        let (model, _) = makeModel()
        model.showRecording()
        model.livePartial("the quick brown fox jumps over the lazy dog")
        XCTAssertEqual(model.bubble, "the lazy dog")
    }

    /// Flicker control #1: an identical tail emits no frame at all.
    func testUnchangedTailEmitsNoFrame() {
        let (model, sink) = makeModel()
        model.showRecording()
        model.livePartial("hello there")
        let count = sink.frames.count
        model.livePartial("hello there")
        model.livePartial("  hello   there  ")   // same words, different spacing
        XCTAssertEqual(sink.frames.count, count)
    }

    /// Flicker control #2 + #3: quantised, and monotone within an utterance.
    func testBubbleWidthIsQuantisedAndNeverShrinksMidUtterance() {
        let (model, _) = makeModel()
        model.showRecording()
        var widths: [Double] = []
        for text in ["so", "so I", "so I was", "so I was thinking", "so I was thinking about it"] {
            model.livePartial(text)
            widths.append(model.bubbleWidth)
        }
        XCTAssertEqual(widths, widths.sorted(), "width must be non-decreasing while recording")
        for w in widths {
            XCTAssertEqual(w.truncatingRemainder(dividingBy: PillBubbleGeometry.widthStep), 0,
                           "widths snap to the \(PillBubbleGeometry.widthStep) pt step")
            XCTAssertLessThanOrEqual(w, PillBubbleGeometry.maxWidth)
            XCTAssertGreaterThanOrEqual(w, PillBubbleGeometry.minWidth)
        }
        // A fresh press resets the floor.
        model.showRecording()
        XCTAssertEqual(model.bubbleWidth, 0)
    }

    func testBubbleWidthGeometry() {
        XCTAssertEqual(PillBubbleGeometry.width(forCharacters: 0), 0)
        XCTAssertEqual(PillBubbleGeometry.totalWidth(bubbleWidth: 0), 26.0)
        let w = PillBubbleGeometry.width(forCharacters: 12)
        XCTAssertEqual(PillBubbleGeometry.totalWidth(bubbleWidth: w),
                       26.0 + PillBubbleGeometry.gap + w)
        XCTAssertEqual(PillBubbleGeometry.width(forCharacters: 400), PillBubbleGeometry.maxWidth)
    }

    // MARK: - transientNotice (NEW)

    func testNoticeFromIdleIsAGreenFlashThatTakesThePillWithIt() {
        let (model, sink) = makeModel()
        model.transientNotice("Learned Sharique")
        XCTAssertEqual(model.state, .success)
        XCTAssertTrue(sink.last.isVisible)
        XCTAssertEqual(sink.last.bubble, "Learned Sharique")
        XCTAssertEqual(sink.scheduled.last?.seconds, PillGeometry.noticeDuration)
        XCTAssertEqual(sink.scheduled.last?.action, .hide)

        model.fireDeferred(.hide)
        XCTAssertEqual(model.state, .hidden)
        XCTAssertEqual(model.bubble, "")
    }

    func testNoticeMidUtteranceKeepsRecordingAndOnlyTheBubbleExpires() {
        let (model, sink) = makeModel()
        model.showRecording()
        model.transientNotice("Learned Sharique")
        XCTAssertEqual(model.state, .recording, "a notice must not end the utterance")
        XCTAssertEqual(sink.scheduled.last?.action, .clearNotice)

        model.fireDeferred(.clearNotice)
        XCTAssertEqual(model.bubble, "")
        XCTAssertTrue(model.isVisible)
        XCTAssertEqual(model.state, .recording)
    }

    func testEmptyNoticeIsIgnored() {
        let (model, sink) = makeModel()
        model.transientNotice("   ")
        XCTAssertTrue(sink.frames.isEmpty)
        XCTAssertEqual(model.state, .hidden)
    }

    func testClearNoticeWithNoBubbleIsANoOp() {
        let (model, sink) = makeModel()
        model.showRecording()
        let count = sink.frames.count
        model.fireDeferred(.clearNotice)
        XCTAssertEqual(sink.frames.count, count)
    }
}
