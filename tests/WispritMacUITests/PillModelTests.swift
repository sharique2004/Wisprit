import XCTest
@testable import WispritMacUI

/// Headless pill state-machine tests. `PillModel` owns every decision; the
/// NSPanel/NSHostingView edge in `Pill.swift` owns nothing but hosting and a
/// Timer, so none of this needs a window server, an event tap or a TCC grant.
///
/// The constants moved when the dot became a waveform (`ui-redesign.md` §2.2);
/// the *behaviour* — suppression, quantisation, monotone width, the auto-hide
/// timings — is the same contract it was under `pill.py` and is asserted the
/// same way.
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

    // MARK: - geometry (§2.2)

    func testPillGeometryMatchesTheSpec() {
        XCTAssertEqual(PillGeometry.height, 28.0)
        XCTAssertEqual(PillGeometry.radius, 14.0, "a full capsule: h/2")
        XCTAssertEqual(PillGeometry.widthListening, 96.0)
        XCTAssertEqual(PillGeometry.barCount, 15, "odd, so there is a true centre bar")
        XCTAssertEqual(PillGeometry.barWidth, 2.5)
        XCTAssertEqual(PillGeometry.barPitch, 5.0)
        XCTAssertEqual(PillGeometry.barPeak, 14.0)
        XCTAssertEqual(PillGeometry.barFloor, PillGeometry.barWidth,
                       "silence must be a perfect dot")
        XCTAssertEqual(PillGeometry.barFieldWidth,
                       Double(PillGeometry.barCount) * PillGeometry.barPitch - PillGeometry.barWidth)
        XCTAssertEqual(PillGeometry.barFieldCompact,
                       Double(PillGeometry.barCountCompact) * PillGeometry.barPitch - PillGeometry.barWidth)
        XCTAssertEqual(PillGeometry.sideInset,
                       (PillGeometry.widthListening - PillGeometry.barFieldWidth) / 2)
    }

    /// The timings are the one thing the user has felt for months.
    func testHideDelaysAreUnchangedAndTheNewOneIsLonger() {
        XCTAssertEqual(PillGeometry.successHideDelay, 0.6)
        XCTAssertEqual(PillGeometry.errorHideDelay, 1.6)
        XCTAssertEqual(PillGeometry.noticeDuration, 1.6)
        XCTAssertEqual(PillGeometry.bottomMargin, 90.0)
        XCTAssertEqual(PillGeometry.blockedSecureHideDelay, 2.6,
                       "a keystroke instruction has to outlive an error flash")
    }

    func testClampLevelStillTreatsNaNAsSilence() {
        XCTAssertEqual(PillGeometry.clampLevel(0.5), 0.5)
        XCTAssertEqual(PillGeometry.clampLevel(-3.0), 0.0)
        XCTAssertEqual(PillGeometry.clampLevel(42.0), 1.0)
        XCTAssertEqual(PillGeometry.clampLevel(.nan), 0.0)
        XCTAssertEqual(PillGeometry.clampLevel(.infinity), 0.0)
    }

    // MARK: - palette (§1.6, the orange rule)

    /// The pill takes the dark side of every token: its body is near-black in
    /// both appearances, which is exactly what the dark palette was tuned for.
    func testPaletteSourcesFromTheme() {
        XCTAssertEqual(PillPalette.hot, PillColor(hex: Theme.Token.hot.dark))
        XCTAssertEqual(PillPalette.ink, PillColor(hex: Theme.Token.studioInk.dark))
        XCTAssertEqual(PillPalette.muted, PillColor(hex: Theme.Token.studioMuted.dark))
        XCTAssertEqual(PillPalette.body, PillColor(hex: Theme.Token.studio.dark))
        XCTAssertEqual(PillPalette.bodyAlpha, 0.92)
    }

    /// The load-bearing rule: orange if and only if the microphone is open.
    func testOnlyTheListeningStateIsOrange() {
        for state in PillState.allCases {
            let isListening = (state == .recording)
            XCTAssertEqual(PillPalette.isLive(state), isListening, "\(state)")
            XCTAssertEqual(PillPalette.tint(for: state) == PillPalette.hot, isListening,
                           "\(state) must not borrow the tally colour")
        }
    }

    func testAlarmStatesSwapTheBody() {
        for state in [PillState.error, .blockedSecure] {
            let fill = PillPalette.bodyFill(for: state)
            XCTAssertEqual(fill.color, PillPalette.alarmBody, "\(state)")
            XCTAssertEqual(fill.alpha, 0.94)
        }
        XCTAssertEqual(PillPalette.bodyFill(for: .recording).color, PillPalette.body)
    }

    /// The five original raw values are frozen — the session's state names and
    /// the older tests both ride on them.
    func testExistingStateRawValuesAreFrozen() {
        XCTAssertEqual(PillState.hidden.rawValue, "hidden")
        XCTAssertEqual(PillState.recording.rawValue, "recording")
        XCTAssertEqual(PillState.finalizing.rawValue, "finalizing")
        XCTAssertEqual(PillState.success.rawValue, "success")
        XCTAssertEqual(PillState.error.rawValue, "error")
        XCTAssertEqual(PillState.allCases.count, 8, "five original + three new")
    }

    // MARK: - state transitions

    func testShowRecordingGoesOrangeVisibleAndZeroLevel() {
        let (model, sink) = makeModel()
        model.updateLevel(0.8)
        model.showRecording()
        XCTAssertEqual(model.state, .recording)
        XCTAssertTrue(sink.last.isVisible)
        XCTAssertEqual(sink.last.tint, PillPalette.hot)
        XCTAssertEqual(sink.last.level, 0.0)
        XCTAssertEqual(sink.last.totalWidth, PillGeometry.widthListening)
        XCTAssertEqual(sink.last.bars, Array(repeating: 0, count: PillGeometry.barCount),
                       "a fresh press starts from a row of dots")
    }

    func testFullUtteranceHappyPath() {
        let (model, sink) = makeModel()
        model.showRecording()
        model.updateLevel(0.4)
        model.showFinalizing()
        XCTAssertEqual(model.state, .finalizing)
        XCTAssertEqual(sink.last.tint, PillPalette.muted)
        XCTAssertEqual(sink.last.level, 0.0, "finalizing resets the level meter")
        XCTAssertEqual(sink.last.bars, Array(repeating: 0, count: PillGeometry.barCount),
                       "and collapses the waveform — a held one would be a lie")

        model.flashSuccess()
        XCTAssertEqual(model.state, .success)
        XCTAssertEqual(sink.last.glyph, .checkmark)
        XCTAssertEqual(sink.last.totalWidth, PillGeometry.widthCommitted,
                       "committed contracts to a circle")
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
        XCTAssertEqual(sink.last.tint, PillPalette.critical)
        XCTAssertEqual(sink.last.glyph, .warning)
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
        XCTAssertEqual(sink.last.message, "")
        XCTAssertEqual(sink.last.totalWidth, PillGeometry.widthListening)
        XCTAssertGreaterThan(sink.cancels, 0)
    }

    // MARK: - the three new states (§2.4)

    /// `prewarming` is deliberately not orange: the key is down but the mic is
    /// not open yet, and the tally never lies.
    func testPrewarmingIsMutedAndFullOfDots() {
        let (model, sink) = makeModel()
        model.showPrewarming()
        XCTAssertEqual(model.state, .prewarming)
        XCTAssertTrue(sink.last.isVisible)
        XCTAssertEqual(sink.last.tint, PillPalette.muted)
        XCTAssertNotEqual(sink.last.tint, PillPalette.hot)
        XCTAssertEqual(sink.last.bars, Array(repeating: 0, count: PillGeometry.barCount))
        XCTAssertEqual(sink.last.totalWidth, PillGeometry.widthListening)
        XCTAssertEqual(sink.last.glyph, .none)
    }

    /// The first level tick is what proves the mic is open, so it is what ends
    /// `prewarming` — even a silent one.
    func testFirstLevelTickEndsPrewarming() {
        let (model, sink) = makeModel()
        model.showPrewarming()
        let count = sink.frames.count
        model.updateLevel(0.0)
        XCTAssertEqual(model.state, .recording)
        XCTAssertEqual(sink.frames.count, count + 1, "the tint crossfade needs one frame")
        XCTAssertEqual(sink.last.tint, PillPalette.hot)
    }

    /// A session that never calls the new entry points behaves exactly as it
    /// did — that is what lets the pill land ahead of the session wiring.
    func testAppUnawareOfPrewarmingIsUnaffected() {
        let (model, sink) = makeModel()
        model.showRecording()
        model.updateLevel(0.5)
        XCTAssertEqual(model.state, .recording)
        XCTAssertEqual(sink.last.tint, PillPalette.hot)
    }

    func testRefiningKeepsTheMeterAndAddsTheSparklesGlyph() {
        let (model, sink) = makeModel()
        model.showRecording()
        model.showRefining()
        XCTAssertEqual(model.state, .refining)
        XCTAssertEqual(sink.last.glyph, .sparkles)
        XCTAssertEqual(sink.last.tint, PillPalette.muted)
        XCTAssertEqual(sink.last.bars.count, PillGeometry.barCount)
        XCTAssertEqual(sink.last.bars, Array(repeating: 0, count: PillGeometry.barCount))
    }

    func testBlockedSecureCarriesItsOwnMessageAndTiming() {
        let (model, sink) = makeModel()
        model.flashBlockedSecure()
        XCTAssertEqual(model.state, .blockedSecure)
        XCTAssertEqual(sink.last.glyph, .lock)
        XCTAssertEqual(sink.last.tint, PillPalette.attention)
        XCTAssertEqual(sink.last.message, PillGeometry.blockedSecureMessage)
        XCTAssertEqual(sink.last.bubble, PillGeometry.blockedSecureMessage)
        XCTAssertEqual(sink.scheduled.last?.seconds, PillGeometry.blockedSecureHideDelay)
        XCTAssertEqual(sink.scheduled.last?.action, .hide)
    }

    func testAlarmStatesHaveAFloorWidth() {
        let (short, shortSink) = makeModel()
        short.flashError("x")
        XCTAssertEqual(shortSink.last.totalWidth, PillGeometry.errorMinWidth)

        let (blocked, blockedSink) = makeModel()
        blocked.flashBlockedSecure("no")
        XCTAssertEqual(blockedSink.last.totalWidth, PillGeometry.blockedSecureMinWidth)
    }

    // MARK: - the retained error message (§2.7)

    /// The old `PillView` took the message and drew nothing with it. It is the
    /// difference between "something went wrong" and "here is what to do".
    func testErrorMessageIsRetainedAndRendered() {
        let (model, sink) = makeModel()
        model.flashError("secure field — press ⌘⌃V to paste")
        XCTAssertEqual(model.message, "secure field — press ⌘⌃V to paste")
        XCTAssertEqual(sink.last.message, model.message)
        XCTAssertEqual(sink.last.bubble, model.message)
        XCTAssertGreaterThan(sink.last.bubbleWidth, 0)
    }

    func testErrorMessageIsCappedAtFortyCharacters() {
        let (model, sink) = makeModel()
        model.flashError(String(repeating: "e", count: 120))
        XCTAssertEqual(sink.last.message.count, PillGeometry.errorMessageCharacters)
        XCTAssertTrue(sink.last.message.hasSuffix("…"))
    }

    func testASucceedingUtteranceClearsTheStaleMessage() {
        let (model, _) = makeModel()
        model.flashError("boom")
        model.showRecording()
        XCTAssertEqual(model.message, "")
        XCTAssertEqual(model.bubble, "")
    }

    // MARK: - error truncation (FINAL-PLAN R9a, native-feel P3)

    /// The bug this pins: errors got a 40-character budget but a 196 pt frame
    /// (~30 characters), so the copy was truncated twice and the user lost the
    /// diagnosis. Every string the session can flash must fit its frame.
    func testErrorLayoutFitsEveryEmptyFlashString() {
        // `SessionController.flashEmpty` / `flashError` copy, verbatim.
        let messages = [
            "Microphone delivered no audio",
            "Didn't hear anything — is the right mic selected?",
            "nothing recognized",
            "microphone unavailable",
            "insert failed",
            "paste failed",
            "no transcript to paste",
            PillGeometry.blockedSecureMessage,
        ]
        for text in messages {
            let (model, sink) = makeModel()
            model.flashError(text)
            let shown = sink.last.message
            XCTAssertLessThanOrEqual(shown.count, PillGeometry.errorMessageCharacters)
            let needed = 2 * PillTailGeometry.textInset
                + Double(shown.count) * PillTailGeometry.characterWidth
            XCTAssertGreaterThanOrEqual(sink.last.bubbleWidth, needed,
                                        "\"\(text)\" would render truncated twice")
        }
    }

    func testErrorWidthCapFitsTheFortyCharacterBudget() {
        XCTAssertEqual(PillTailGeometry.errorMaxWidth, 288.0,
                       "2 × 12 + 40 × 6.5 = 284, next widthStep multiple")
        let budget = PillGeometry.errorMessageCharacters
        let needed = 2 * PillTailGeometry.textInset
            + Double(budget) * PillTailGeometry.characterWidth
        XCTAssertGreaterThanOrEqual(PillTailGeometry.errorWidth(forCharacters: budget), needed)
        // The live tail keeps its narrower cap — a scrolling partial is not a
        // diagnosis — and below both caps the two layouts agree.
        XCTAssertEqual(PillTailGeometry.width(forCharacters: budget), PillTailGeometry.maxWidth)
        XCTAssertEqual(PillTailGeometry.errorWidth(forCharacters: 0), 0)
        XCTAssertEqual(PillTailGeometry.errorWidth(forCharacters: 12),
                       PillTailGeometry.width(forCharacters: 12))
    }

    func testBlockedSecureGetsTheErrorLayoutToo() {
        let (model, sink) = makeModel()
        model.flashBlockedSecure()
        let shown = sink.last.message
        let needed = 2 * PillTailGeometry.textInset
            + Double(shown.count) * PillTailGeometry.characterWidth
        XCTAssertGreaterThanOrEqual(sink.last.bubbleWidth, needed)
    }

    /// Head-truncation is right for a live tail (newest words win) and wrong
    /// for a diagnosis (the head *is* the diagnosis). The alarm states cut at
    /// the tail; everything else keeps the tail-of-speech behaviour.
    func testAlarmStatesTruncateAtTheTailEverythingElseAtTheHead() {
        for state in PillState.allCases {
            let expected: PillTailTruncation =
                (state == .error || state == .blockedSecure) ? .tail : .head
            XCTAssertEqual(PillTailGeometry.truncation(for: state), expected, "\(state)")
        }
    }

    // MARK: - the live dead-mic cue (FINAL-PLAN R10, amended trigger §1.1-T4)

    private func silentTicks(_ model: PillModel, _ count: Int) {
        for _ in 0..<count { model.updateLevel(0) }
    }

    /// ~2 s of sub-floor ticks with no engine evidence → a muted notice tail,
    /// while the user can still act on it — not a posthumous flash.
    func testTwoSecondsOfDeadMicShowsTheCue() {
        let (model, sink) = makeModel()
        model.showRecording()
        silentTicks(model, PillGeometry.deadMicTickCount)
        XCTAssertEqual(model.bubble, "", "the 2 s window itself stays clean")
        model.updateLevel(0)   // the first tick past the window
        XCTAssertEqual(model.state, .recording, "the cue is a notice, not a state change")
        XCTAssertEqual(sink.last.bubble, PillGeometry.deadMicMessage)
        XCTAssertEqual(sink.last.message, PillGeometry.deadMicMessage)
        XCTAssertTrue(sink.last.tailMuted, "notice styling: muted ink, no alarm body")
        XCTAssertEqual(sink.last.tint, PillPalette.hot,
                       "the mic is open, so the bars keep the tally colour")
        XCTAssertEqual(sink.last.glyph, .none)
    }

    /// The cue costs exactly one frame; the silence around it stays free —
    /// the zero-redraw invariant survives the cue.
    func testTheCueCostsOneFrameAndSilenceStaysFreeAfterIt() {
        let (model, sink) = makeModel()
        model.showRecording()
        silentTicks(model, PillGeometry.deadMicTickCount + 1)
        XCTAssertEqual(sink.last.bubble, PillGeometry.deadMicMessage)
        let settled = sink.frames.count
        silentTicks(model, 40)
        XCTAssertEqual(sink.frames.count, settled, "a shown cue must not re-emit")
    }

    func testAVoicedTickClearsTheCueAndDisarmsIt() {
        let (model, sink) = makeModel()
        model.showRecording()
        silentTicks(model, PillGeometry.deadMicTickCount + 1)
        XCTAssertEqual(model.bubble, PillGeometry.deadMicMessage)

        model.updateLevel(0.5)
        XCTAssertEqual(sink.last.bubble, "")
        XCTAssertEqual(sink.last.message, "")
        XCTAssertFalse(sink.last.tailMuted)
        // A channel that has produced voice is not dead: no re-fire this
        // utterance, however long the silence that follows.
        silentTicks(model, PillGeometry.deadMicTickCount * 3)
        XCTAssertEqual(model.bubble, "")
    }

    /// Engine evidence beats the proxy (§1.1-T4): one partial replaces the cue
    /// on screen and suppresses it for the rest of the utterance.
    func testAPartialClearsAndSuppressesTheCue() {
        let (model, sink) = makeModel()
        model.showRecording()
        silentTicks(model, PillGeometry.deadMicTickCount + 1)
        XCTAssertEqual(model.bubble, PillGeometry.deadMicMessage)

        model.livePartial("hello")
        XCTAssertEqual(sink.last.bubble, "hello")
        XCTAssertFalse(sink.last.tailMuted)
        XCTAssertEqual(sink.last.message, "")
    }

    func testAnEarlyPartialSuppressesTheCueEntirely() {
        let (model, sink) = makeModel()
        model.showRecording()
        model.livePartial("hi")
        silentTicks(model, PillGeometry.deadMicTickCount * 3)
        XCTAssertEqual(sink.last.bubble, "hi", "the tail stays a tail")
        XCTAssertFalse(sink.last.tailMuted)
    }

    func testEarlySpeechDisarmsTheCueForTheWholeUtterance() {
        let (model, _) = makeModel()
        model.showRecording()
        model.updateLevel(0.5)
        silentTicks(model, PillGeometry.deadMicTickCount * 3)
        XCTAssertEqual(model.bubble, "", "quiet-after-speech belongs to R15/R26, not a nag")
    }

    func testAFreshUtteranceRearmsTheCue() {
        let (model, sink) = makeModel()
        model.showRecording()
        model.updateLevel(0.5)          // disarmed for this utterance
        model.showFinalizing()
        model.fireDeferred(.hide)

        model.showRecording()           // next press
        silentTicks(model, PillGeometry.deadMicTickCount + 1)
        XCTAssertEqual(sink.last.bubble, PillGeometry.deadMicMessage)
    }

    func testTheCueNeverFiresOutsideRecording() {
        let (model, _) = makeModel()
        silentTicks(model, PillGeometry.deadMicTickCount * 2)
        XCTAssertEqual(model.bubble, "", "hidden pill: level ticks are diagnostics only")
        XCTAssertEqual(model.state, .hidden)
    }

    // MARK: - the staggered-collapse source (§2.5 row 6, FINAL-PLAN R13)

    /// The surface needs the levels the collapse starts from; the model's
    /// `bars` are already at floor — a held waveform would be a lie, and every
    /// assertion above stays true.
    func testFinalizingHandsTheSurfaceThePreCollapseBars() {
        let (model, sink) = makeModel()
        model.showRecording()
        model.updateLevel(0.5)
        model.showFinalizing()
        XCTAssertEqual(sink.last.bars, Array(repeating: 0, count: PillGeometry.barCount))
        XCTAssertEqual(sink.last.collapseFrom.count, PillGeometry.barCount)
        XCTAssertEqual(sink.last.collapseFrom.last, WaveformBuffer.shaped(0.5))

        model.showRefining()
        XCTAssertEqual(sink.last.collapseFrom, [],
                       "refining right after finalizing must not restart the choreography")
    }

    func testASilentReleaseHasNothingToCollapse() {
        let (model, sink) = makeModel()
        model.showRecording()
        model.showFinalizing()
        XCTAssertEqual(sink.last.collapseFrom, [])
    }

    func testTheCommitClearsTheCollapseSource() {
        let (model, sink) = makeModel()
        model.showRecording()
        model.updateLevel(0.7)
        model.showFinalizing()
        XCTAssertFalse(sink.last.collapseFrom.isEmpty)
        model.flashSuccess()
        XCTAssertEqual(sink.last.collapseFrom, [])
    }

    // MARK: - width held (§2.4)

    /// A pill that shrinks and regrows between "you stopped talking" and "here
    /// is the result" reads as two events, not one.
    func testFinalizingHoldsTheWidthTheUtteranceEarned() {
        let (model, sink) = makeModel()
        model.showRecording()
        model.livePartial("some long text here")
        let recording = sink.last.totalWidth
        XCTAssertGreaterThan(recording, PillGeometry.widthListening)

        model.showFinalizing()
        XCTAssertEqual(model.bubble, "", "the tail still collapses")
        XCTAssertEqual(sink.last.totalWidth, recording, "but the width it bought is held")
    }

    // MARK: - pill_hidden suppression

    func testSuppressedPillNeverShowsOrRenders() {
        let (model, sink) = makeModel(suppressed: { true })
        model.showPrewarming()
        model.showRecording()
        model.updateLevel(0.9)
        model.livePartial("some words here")
        model.showFinalizing()
        model.showRefining()
        model.transientNotice("Learned Sharique")
        model.flashBlockedSecure()
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

    // MARK: - the meter

    func testUpdateLevelScrollsTheWaveformAndNeverChangesVisibility() {
        let (model, sink) = makeModel()
        model.updateLevel(0.5)
        XCTAssertFalse(sink.last.isVisible)

        model.showRecording()
        model.updateLevel(0.5)
        XCTAssertEqual(sink.last.bars.last, WaveformBuffer.shaped(0.5))
        model.updateLevel(0.5)
        XCTAssertEqual(Array(sink.last.bars.suffix(2)),
                       [WaveformBuffer.shaped(0.5), WaveformBuffer.shaped(0.5)],
                       "an unchanged level still scrolls — that is what makes it a waveform")
    }

    /// The non-negotiable one: the main thread carries the CGEventTap, so an
    /// idle-but-visible pill must cost zero redraws (§2.3).
    func testSilenceCostsNoFrames() {
        let (model, sink) = makeModel()
        model.showRecording()
        let count = sink.frames.count
        for _ in 0..<40 { model.updateLevel(0) }
        XCTAssertEqual(sink.frames.count, count, "a silent pill must not redraw")
    }

    /// …and it converges: a loud burst drains through the buffer in at most
    /// `barCount` ticks and then silence is free again.
    func testSilenceBecomesFreeOnceTheBurstScrollsOut() {
        let (model, sink) = makeModel()
        model.showRecording()
        model.updateLevel(0.8)
        var emitted = 0
        for _ in 0..<(PillGeometry.barCount * 3) {
            let before = sink.frames.count
            model.updateLevel(0)
            if sink.frames.count > before { emitted += 1 }
        }
        XCTAssertLessThanOrEqual(emitted, PillGeometry.barCount)
        let settled = sink.frames.count
        for _ in 0..<20 { model.updateLevel(0) }
        XCTAssertEqual(sink.frames.count, settled)
    }

    /// A text tail halves the meter so the pill stays a pill.
    func testTheMeterGoesCompactWhenATailSharesTheCapsule() {
        let (model, sink) = makeModel()
        model.showRecording()
        model.updateLevel(0.6)
        XCTAssertEqual(sink.last.bars.count, PillGeometry.barCount)
        model.livePartial("hello there world")
        XCTAssertEqual(sink.last.bars.count, PillGeometry.barCountCompact)
        XCTAssertEqual(sink.last.bars.last, WaveformBuffer.shaped(0.6),
                       "the compact meter keeps the newest slots")
    }

    // MARK: - livePartial

    func testLivePartialOnlyRendersWhileRecording() {
        let (model, sink) = makeModel()
        model.livePartial("idle words")
        XCTAssertEqual(model.bubble, "")

        model.showRecording()
        model.livePartial("hello there world")
        XCTAssertEqual(model.bubble, "hello there world")
        XCTAssertTrue(sink.last.totalWidth > PillGeometry.widthListening)

        model.showFinalizing()
        XCTAssertEqual(model.bubble, "", "the tail collapses when recording ends")
        model.livePartial("late arrival")
        XCTAssertEqual(model.bubble, "", "a late partial must not reopen the tail")
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
    func testTailWidthIsQuantisedAndNeverShrinksMidUtterance() {
        let (model, _) = makeModel()
        model.showRecording()
        var widths: [Double] = []
        for text in ["so", "so I", "so I was", "so I was thinking", "so I was thinking about it"] {
            model.livePartial(text)
            widths.append(model.bubbleWidth)
        }
        XCTAssertEqual(widths, widths.sorted(), "width must be non-decreasing while recording")
        for w in widths {
            XCTAssertLessThanOrEqual(w, PillTailGeometry.maxWidth)
            XCTAssertGreaterThanOrEqual(w, PillTailGeometry.minWidth)
        }
        // A fresh press resets the floor.
        model.showRecording()
        XCTAssertEqual(model.bubbleWidth, 0)
    }

    /// The quantisation itself, retuned but not rewritten (§2.7). The clamps
    /// are deliberately off the 8 pt grid — they come from the panel widths
    /// §2.2 names — but everything between them is on it.
    func testTailGeometry() {
        XCTAssertEqual(PillTailGeometry.widthStep, 8.0)
        XCTAssertEqual(PillTailGeometry.minWidth, 44.0)
        XCTAssertEqual(PillTailGeometry.maxWidth, 196.0)
        XCTAssertEqual(PillTailGeometry.width(forCharacters: 0), 0)
        XCTAssertEqual(PillTailGeometry.width(forCharacters: 400), PillTailGeometry.maxWidth)

        let unclamped = PillTailGeometry.width(forCharacters: 12)
        XCTAssertEqual(unclamped.truncatingRemainder(dividingBy: PillTailGeometry.widthStep), 0)

        XCTAssertEqual(PillTailGeometry.totalWidth(tailWidth: 0), PillGeometry.widthListening)
        XCTAssertEqual(PillTailGeometry.totalWidth(tailWidth: PillTailGeometry.minWidth), 108.5)
        XCTAssertEqual(PillTailGeometry.totalWidth(tailWidth: PillTailGeometry.maxWidth), 260.5)
    }

    // MARK: - transientNotice

    func testNoticeFromIdleIsAFlashThatTakesThePillWithIt() {
        let (model, sink) = makeModel()
        model.transientNotice("Learned Sharique")
        XCTAssertEqual(model.state, .success)
        XCTAssertTrue(sink.last.isVisible)
        XCTAssertEqual(sink.last.bubble, "Learned Sharique")
        XCTAssertEqual(sink.last.glyph, .sparkle, "a notice is a text row, not a check mark")
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

    // MARK: - glyph mapping

    func testGlyphSymbolNames() {
        XCTAssertNil(PillGlyph.none.symbolName)
        XCTAssertEqual(PillGlyph.checkmark.symbolName, "checkmark")
        XCTAssertEqual(PillGlyph.warning.symbolName, "exclamationmark.triangle")
        XCTAssertEqual(PillGlyph.lock.symbolName, "lock.fill")
        XCTAssertEqual(PillGlyph.sparkles.symbolName, "sparkles")
        XCTAssertEqual(PillGlyph.sparkle.symbolName, "sparkle")
    }
}
