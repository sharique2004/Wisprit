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
        XCTAssertEqual(PillGeometry.barCount, 10, "one field, everywhere")
        XCTAssertEqual(PillGeometry.barWidth, 2.25, "Flowbar's 0.080·h")
        XCTAssertEqual(PillGeometry.barPitch, 5.5, "the app's 0.056 of the pill width")
        XCTAssertEqual(PillGeometry.barPeak, 14.0)
        XCTAssertEqual(PillGeometry.barFloor, PillGeometry.barWidth,
                       "silence must be a perfect dot")
        XCTAssertEqual(PillGeometry.barFieldWidth,
                       Double(PillGeometry.barCount - 1) * PillGeometry.barPitch
                           + PillGeometry.barWidth)
        XCTAssertEqual(PillGeometry.barFieldWidth, TallyMetrics.pill.fieldWidth)
        XCTAssertEqual(PillGeometry.sideInset,
                       (PillGeometry.widthListening - PillGeometry.barFieldWidth) / 2)
    }

    /// The processing capsule is Flow's measured ×1.34, on the 8 pt grid, and
    /// wide enough for the dot row plus the spinner plus both insets.
    func testTheProcessingWidthFitsItsContents() {
        XCTAssertEqual(PillGeometry.widthProcessing, 128.0)
        XCTAssertEqual(PillGeometry.widthProcessing / PillGeometry.widthListening,
                       1.34, accuracy: 0.01, "Flow widens 107 → 143 px on release")
        XCTAssertEqual(PillGeometry.widthProcessing
                           .truncatingRemainder(dividingBy: PillTailGeometry.widthStep), 0)
        let needed = 2 * PillTailGeometry.textInset + PillGeometry.barFieldWidth
            + PillTailGeometry.spinnerAllowance
        XCTAssertGreaterThan(PillGeometry.widthProcessing, needed)
    }

    /// A patience line arriving during a wait must not slide under the
    /// spinner. The spinner is an overlay pinned to the trailing inset, so the
    /// width has to buy its room explicitly.
    func testAWaitWithCopyBuysRoomForItsSpinner() {
        let (model, sink) = makeModel()
        model.showRecording()
        model.showFinalizing()
        model.fireDeferred(.patience)
        let text = PillGeometry.finalizingPatienceMessage
        let tail = PillTailGeometry.width(forCharacters: text.count)
        XCTAssertEqual(sink.last.bubble, text)
        XCTAssertGreaterThanOrEqual(
            sink.last.totalWidth,
            PillTailGeometry.totalWidth(tailWidth: tail) + PillTailGeometry.spinnerAllowance,
            "the copy would render underneath the spinner")
        XCTAssertEqual(PillTailGeometry.spinnerAllowance,
                       PillTailGeometry.gap + PillGeometry.spinnerBox)
    }

    /// The timings are the one thing the user has felt for months.
    func testHideDelaysAreUnchangedAndTheNewOneIsLonger() {
        XCTAssertEqual(PillGeometry.successHideDelay, 0.6)
        XCTAssertEqual(PillGeometry.errorHideDelay, 1.6)
        XCTAssertEqual(PillGeometry.missedHideDelay, 0.9)
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

    /// Both alarm states tint the near-black body — and they tint it
    /// *differently*, which is the point. An error is red because something
    /// failed; a secure-input block is warm because nothing did, and telling
    /// the user "failure" before they have read "press ⌘⌃V" is telling them
    /// the wrong thing first.
    func testAlarmStatesSwapTheBodyAndABlockIsNotAnError() {
        let error = PillPalette.bodyFill(for: .error)
        XCTAssertEqual(error.color, PillPalette.alarmBody)
        XCTAssertEqual(error.alpha, 0.94)

        let blocked = PillPalette.bodyFill(for: .blockedSecure)
        XCTAssertEqual(blocked.color, PillPalette.attentionBody)
        XCTAssertEqual(blocked.alpha, 0.94)
        XCTAssertNotEqual(blocked.color, error.color, "a block must not read as a failure")

        XCTAssertEqual(PillPalette.bodyFill(for: .recording).color, PillPalette.body)
    }

    /// Over the panel's material the tint has to let some blur through, and
    /// under Reduce Transparency it has to stop counting on one. Both numbers
    /// live here so the two layers cannot drift apart.
    func testTheBodyHasAnOpaqueAlphaAndAGlassOne() {
        XCTAssertEqual(PillPalette.bodyAlpha, 0.92, "no blur underneath")
        XCTAssertLessThan(PillPalette.bodyAlphaOverMaterial, PillPalette.bodyAlpha,
                          "the blur is only visible if the tint lets it through")
        XCTAssertGreaterThan(PillPalette.bodyAlphaOverMaterial, 0.6,
                             "…and the tint still has to decide the reading")
        XCTAssertLessThan(PillPalette.alarmBodyAlphaOverMaterial, PillPalette.alarmBodyAlpha)
        XCTAssertGreaterThan(PillPalette.alarmBodyAlphaOverMaterial,
                             PillPalette.bodyAlphaOverMaterial,
                             "an alarm body carries more of its own colour")
    }

    /// The rim is a lit edge, not a flat hairline — and the flat value it
    /// replaced is still the honest average of the two ends.
    func testTheRimIsLitFromAbove() {
        XCTAssertGreaterThan(PillPalette.rimTopAlpha, PillPalette.rimBottomAlpha)
        XCTAssertEqual((PillPalette.rimTopAlpha + PillPalette.rimBottomAlpha) / 2,
                       PillPalette.rimAlpha, accuracy: 1e-9,
                       "the §1.2 studioStroke value, spread over the arc")
        XCTAssertGreaterThan(PillPalette.rimContrastAlpha, PillPalette.rimTopAlpha,
                             "Increase Contrast gets one solid edge")
    }

    /// The five original raw values are frozen — the session's state names and
    /// the older tests both ride on them.
    func testExistingStateRawValuesAreFrozen() {
        XCTAssertEqual(PillState.hidden.rawValue, "hidden")
        XCTAssertEqual(PillState.recording.rawValue, "recording")
        XCTAssertEqual(PillState.finalizing.rawValue, "finalizing")
        XCTAssertEqual(PillState.success.rawValue, "success")
        XCTAssertEqual(PillState.error.rawValue, "error")
        XCTAssertEqual(PillState.idle.rawValue, "idle")
        XCTAssertEqual(PillState.allCases.count, 10, "five original + five new")
    }

    // MARK: - state transitions

    /// The mini rest, by user directive: "extremely small" until the pill is
    /// actually listening or working. No meter fits inside 36×10, so rest is
    /// a bare sliver — the empty `bars` is the established no-meter contract.
    func testIdleIsTheMiniSliver() {
        let (model, sink) = makeModel()
        model.showIdle()
        XCTAssertEqual(model.state, .idle)
        XCTAssertTrue(sink.last.isVisible, "Flow stays on the desktop")
        XCTAssertEqual(sink.last.totalWidth, PillGeometry.widthMini)
        XCTAssertEqual(sink.last.height, PillGeometry.heightMini)
        XCTAssertEqual(sink.last.bars, [])
        XCTAssertEqual(sink.last.glyph, .none)
        XCTAssertEqual(sink.last.tint, PillPalette.muted)
        XCTAssertNotEqual(sink.last.tint, PillPalette.hot)
        XCTAssertEqual(PillPalette.bodyFill(for: .idle).color, PillPalette.body)
    }

    /// The consequence worth its own name: `idle → listening` is now a real
    /// expansion — the sliver grows into the listening capsule the moment the
    /// key goes down, and settles back on rest. Growth animates as a resize;
    /// the return shares the commit's contract timing (a going-to-rest move).
    func testIdleGrowsIntoListeningAndContractsBack() {
        let (model, sink) = makeModel()
        model.showIdle()
        let idle = sink.last
        model.showRecording()
        let listening = sink.last
        XCTAssertEqual(idle.totalWidth, PillGeometry.widthMini)
        XCTAssertEqual(listening.totalWidth, PillGeometry.widthListening)
        XCTAssertEqual(listening.height, PillGeometry.height)
        XCTAssertEqual(PillMotion.frameChange(
            wasVisible: true, isVisible: true,
            oldWidth: idle.totalWidth, newWidth: listening.totalWidth,
            newState: .recording, reduceMotion: false).kind, .resize)
        XCTAssertEqual(PillMotion.frameChange(
            wasVisible: true, isVisible: true,
            oldWidth: listening.totalWidth, newWidth: idle.totalWidth,
            newState: .idle, reduceMotion: false).kind, .contract)
    }

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
        XCTAssertEqual(sink.last.glyph, .none,
                       "no commit glyph — the inserted text is the confirmation")
        XCTAssertEqual(sink.last.totalWidth, PillGeometry.widthListening,
                       "the commit contracts back to the resting capsule, not to a circle")
        XCTAssertEqual(sink.last.bars, Array(repeating: 0, count: PillGeometry.barCount))
        XCTAssertEqual(PillPalette.meterTint(for: .success), PillPalette.cream,
                       "the dots brighten muted → cream on the way home")
        XCTAssertEqual(sink.scheduled.last?.seconds, 0.6)
        XCTAssertEqual(sink.scheduled.last?.action, .settle)

        model.fireDeferred(.settle)
        XCTAssertEqual(model.state, .idle)
        XCTAssertTrue(sink.last.isVisible, "the pill stays on the desktop")
        XCTAssertEqual(sink.last.totalWidth, PillGeometry.widthMini,
                       "the settle lands on the mini sliver, not the capsule")
        XCTAssertEqual(sink.last.glyph, .none)
    }

    /// The processing frame: one look for both waiting states, widened for the
    /// spinner, with the meter dimmed to grey and no glyph competing with it.
    func testProcessingIsOneWidenedDimmedLook() {
        for enter in [{ (m: PillModel) in m.showFinalizing() },
                      { (m: PillModel) in m.showRefining() }] {
            let (model, sink) = makeModel()
            model.showRecording()
            model.updateLevel(0.5)
            enter(model)
            XCTAssertEqual(sink.last.totalWidth, PillGeometry.widthProcessing, "\(model.state)")
            XCTAssertEqual(sink.last.glyph, .none, "the spinner is the chrome, not a symbol")
            XCTAssertEqual(sink.last.bars, Array(repeating: 0, count: PillGeometry.barCount))
            XCTAssertEqual(PillPalette.meterTint(for: model.state), PillPalette.muted)
        }
    }

    /// `finalizing → refining` must change nothing on screen: it is the same
    /// wait wearing a different label, and a stutter there reads as a hitch in
    /// the work.
    func testRefiningAfterFinalizingChangesNoFrame() {
        let (model, sink) = makeModel()
        model.showRecording()
        model.updateLevel(0.5)
        model.showFinalizing()
        var before = sink.last
        model.showRefining()
        var after = sink.last
        before.state = .finalizing
        after.state = .finalizing
        XCTAssertEqual(before, after, "only the label changed")
    }

    func testFlashErrorAutoHidesAfterOnePointSix() {
        let (model, sink) = makeModel()
        model.flashError("secure field — press ⌘⌃V to paste")
        XCTAssertEqual(model.state, .error)
        XCTAssertEqual(sink.last.tint, PillPalette.critical)
        XCTAssertEqual(sink.last.glyph, .warning)
        XCTAssertEqual(sink.scheduled.last?.seconds, 1.6)
        XCTAssertEqual(sink.scheduled.last?.action, .settle)
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

    func testRefiningKeepsTheMeterAndDropsTheSparklesGlyph() {
        let (model, sink) = makeModel()
        model.showRecording()
        model.showRefining()
        XCTAssertEqual(model.state, .refining)
        XCTAssertEqual(sink.last.glyph, .none,
                       "the spinner already says 'working'; the patience copy says which work")
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
        XCTAssertEqual(sink.scheduled.last?.action, .settle)
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

    func testFlashMissedIsQuietNotAnAlarm() {
        let (model, sink) = makeModel()
        model.showRecording()
        model.flashMissed("Didn't catch that")
        XCTAssertEqual(sink.last.state, .missed)
        XCTAssertEqual(sink.last.bubble, "Didn't catch that")
        XCTAssertEqual(sink.last.glyph, .none, "a miss is not a warning triangle")
        XCTAssertEqual(sink.last.tint, PillPalette.muted)
        XCTAssertEqual(PillPalette.bodyFill(for: .missed).color, PillPalette.body)
        XCTAssertEqual(sink.last.bars, Array(repeating: 0, count: PillGeometry.barCount),
                       "the waveform flattens to dots, the way Flow leaves")
        XCTAssertEqual(sink.scheduled.last?.seconds, PillGeometry.missedHideDelay)
        XCTAssertEqual(sink.scheduled.last?.action, .settle)
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
            "Microphone changed — try again",
            "Didn't catch that",
            "Hold the key while you speak",
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
                (state == .error || state == .blockedSecure || state == .missed) ? .tail : .head
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
        model.fireDeferred(.settle)

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

    // MARK: - the patience cue (the AUDIT-2026-08-14 pill copy decision)

    /// The audit left this open: a rescued utterance can spend seconds in
    /// `finalizing` while the batch pass re-transcribes the audio. The pill now
    /// names the wait instead of sitting there.
    func testFinalizingArmsThePatienceClock() {
        let (model, sink) = makeModel()
        model.showRecording()
        model.showFinalizing()
        XCTAssertEqual(sink.scheduled.last?.seconds, PillGeometry.patienceDelay)
        XCTAssertEqual(sink.scheduled.last?.action, .patience)
        XCTAssertEqual(model.bubble, "", "the wait itself stays clean")
    }

    func testPatienceNamesTheStageWithoutChangingIt() {
        let (model, sink) = makeModel()
        model.showRecording()
        model.showFinalizing()
        model.fireDeferred(.patience)
        XCTAssertEqual(model.state, .finalizing, "a cue is not a state change")
        XCTAssertEqual(sink.last.bubble, PillGeometry.finalizingPatienceMessage)
        XCTAssertEqual(sink.last.message, PillGeometry.finalizingPatienceMessage)
        XCTAssertTrue(sink.last.tailMuted, "notice styling: muted ink, no alarm body")
        XCTAssertEqual(sink.last.glyph, .none)
        XCTAssertEqual(PillPalette.bodyFill(for: .finalizing).color, PillPalette.body)
        XCTAssertGreaterThan(sink.last.totalWidth, PillGeometry.widthListening,
                             "the capsule opens for the copy")
    }

    /// Refine is a different wait and says so — the user is owed the name of
    /// the stage they are waiting on, not a generic "working".
    func testRefiningHasItsOwnPatienceCopy() {
        let (model, sink) = makeModel()
        model.showRecording()
        model.showRefining()
        XCTAssertEqual(sink.scheduled.last?.action, .patience)
        model.fireDeferred(.patience)
        XCTAssertEqual(sink.last.bubble, PillGeometry.refiningPatienceMessage)
        XCTAssertNotEqual(PillGeometry.refiningPatienceMessage,
                          PillGeometry.finalizingPatienceMessage)
        XCTAssertEqual(model.state, .refining)
    }

    /// Both strings have to survive the tail's character budget, or the pill
    /// would be reassuring the user with an ellipsis.
    func testPatienceCopyFitsTheTail() {
        for text in [PillGeometry.finalizingPatienceMessage,
                     PillGeometry.refiningPatienceMessage] {
            XCTAssertEqual(PartialTail.notice(text), text, "\"\(text)\" is clipped")
            let needed = 2 * PillTailGeometry.textInset
                + Double(text.count) * PillTailGeometry.characterWidth
            XCTAssertGreaterThanOrEqual(PillTailGeometry.width(forCharacters: text.count), needed)
        }
    }

    /// The result landing is what the cue was waiting for, so it takes the cue
    /// with it — and the settle after it leaves nothing behind.
    func testAResultClearsThePatienceCue() {
        let (model, sink) = makeModel()
        model.showRecording()
        model.showFinalizing()
        model.fireDeferred(.patience)
        XCTAssertFalse(model.bubble.isEmpty)

        model.flashSuccess()
        XCTAssertEqual(model.bubble, "")
        XCTAssertFalse(sink.last.tailMuted)
        XCTAssertEqual(sink.last.totalWidth, PillGeometry.widthListening)
    }

    /// It is a reassurance, never a replacement: anything the app actually had
    /// to say is already in the tail and stays there.
    func testPatienceDefersToCopyTheAppSupplied() {
        let (model, sink) = makeModel()
        model.showRecording()
        model.transientNotice("Learned Sharique")
        model.showFinalizing()
        model.transientNotice("Fixed 2")
        let frames = sink.frames.count
        model.fireDeferred(.patience)
        XCTAssertEqual(sink.frames.count, frames, "an occupied tail emits nothing")
        XCTAssertEqual(model.bubble, "Fixed 2")
    }

    func testPatienceNeverFiresOutsideTheWaitingStates() {
        for enter in [{ (m: PillModel) in m.showRecording() },
                      { (m: PillModel) in m.showIdle() },
                      { (m: PillModel) in m.flashSuccess() }] {
            let (model, sink) = makeModel()
            enter(model)
            let frames = sink.frames.count
            model.fireDeferred(.patience)
            XCTAssertEqual(sink.frames.count, frames, "\(model.state)")
            XCTAssertEqual(model.bubble, "")
        }
    }

    func testASuppressedPillArmsNoPatienceClock() {
        let (model, sink) = makeModel(suppressed: { true })
        model.showFinalizing()
        XCTAssertFalse(sink.scheduled.contains { $0.action == .patience })
        model.fireDeferred(.patience)
        XCTAssertTrue(sink.frames.isEmpty)
    }

    // MARK: - the release collapse

    /// There is no pre-collapse snapshot any more, and there does not need to
    /// be one: the meter's layers already hold the heights they are at, so the
    /// release is one retarget to floor and the render server plays the fall
    /// from wherever each bar happens to be. The model's `bars` go straight to
    /// floor, which is what every assertion here has always said.
    func testTheReleaseTakesEveryBarToFloorAtOnce() {
        let (model, sink) = makeModel()
        model.showRecording()
        model.updateLevel(0.5)
        XCTAssertFalse(sink.last.bars.allSatisfy { $0 == 0 })
        model.showFinalizing()
        XCTAssertEqual(sink.last.bars, Array(repeating: 0, count: PillGeometry.barCount),
                       "Flow's row drops as a unit — no stagger")
    }

    /// A fresh press starts from the dot row rather than from the last
    /// utterance's tail: the synthesizer's envelope and every jitter deadline
    /// are reset, so bar 3 does not inherit a height from a minute ago.
    func testAFreshPressStartsFromTheDotRow() {
        let (model, sink) = makeModel()
        model.showRecording()
        model.updateLevel(0.9)
        model.showFinalizing()
        model.fireDeferred(.settle)
        model.showRecording()
        XCTAssertEqual(sink.last.bars, Array(repeating: 0, count: PillGeometry.barCount))
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
        model.showIdle()
        XCTAssertTrue(sink.frames.isEmpty, "no frame should be emitted while pill_hidden")
        XCTAssertEqual(model.state, .hidden)
    }

    /// 1:1 with `flash_success`, which arms the settle timer even when
    /// `_show` no-opped.
    func testSuppressedFlashStillSchedulesSettle() {
        let (model, sink) = makeModel(suppressed: { true })
        model.flashSuccess()
        XCTAssertEqual(sink.scheduled.last?.seconds, 0.6)
        XCTAssertEqual(sink.scheduled.last?.action, .settle)
        XCTAssertTrue(sink.frames.isEmpty)
    }

    // MARK: - the meter

    /// The single biggest divergence from Flow, now fixed: **the bars do not
    /// scroll.** Frame-to-frame cross-correlation of the real app's listening
    /// waveform is 0.90 at lag 0 — the pattern stays in place and breathes.
    /// Here that is visible as a symmetric dome that grows with the voice
    /// instead of a value marching in from the right.
    func testUpdateLevelBreathesInPlaceAndNeverChangesVisibility() {
        let (model, sink) = makeModel()
        model.updateLevel(0.5)
        XCTAssertFalse(sink.last.isVisible)

        model.showRecording()
        for _ in 0..<6 { model.updateLevel(0.5) }
        let bars = sink.last.bars
        XCTAssertEqual(bars.count, PillGeometry.barCount)
        // Every bar carries the voice, and the middle carries more of it than
        // the ends — which is what makes it read as one instrument.
        XCTAssertTrue(bars.allSatisfy { $0 > 0 }, "no bar is left at floor while speaking")
        let middle = (bars[4] + bars[5]) / 2
        XCTAssertGreaterThan(middle, bars[0] * 1.3)
        XCTAssertGreaterThan(middle, bars[9] * 1.3)
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

    /// …and it converges, which is the half the exponential release could not
    /// do on its own.
    ///
    /// The envelope decays by `1 − release` a tick and would *never* reach
    /// zero, so a mid-dictation pause would emit sub-visible frames for
    /// minutes. The snap fixes that with a closed form: from the height one
    /// full-scale tick reaches (`attack`), it takes
    /// `⌈ln(quantum / attack) / ln(1 − release)⌉ = 12` ticks — 600 ms — to fall
    /// under one quantum, at which point it is set to exactly zero, the row
    /// lands on its dots, and every tick after that is free forever.
    func testSilenceBecomesFreeOnceTheEnvelopeDecays() {
        let (model, sink) = makeModel()
        model.showRecording()
        model.updateLevel(0.8)
        var emitted = 0
        for _ in 0..<(PillGeometry.barCount * 6) {
            let before = sink.frames.count
            model.updateLevel(0)
            if sink.frames.count > before { emitted += 1 }
        }
        let expected = Int((log(WaveformBuffer.quantum / BarSynthesizer.attack)
                            / log(1 - BarSynthesizer.release)).rounded(.up))
        XCTAssertEqual(emitted, expected, "the release is 600 ms and then it is over")
        XCTAssertLessThanOrEqual(Double(expected) * BarSynthesizer.tickInterval, 1.0)
        XCTAssertTrue(sink.last.bars.allSatisfy { $0 == 0 })
        let settled = sink.frames.count
        for _ in 0..<20 { model.updateLevel(0) }
        XCTAssertEqual(sink.frames.count, settled, "and then silence is free again")
    }

    /// A text tail no longer halves the meter: Flow keeps one field and grows
    /// the capsule around it, so the bars the user was watching do not
    /// rearrange themselves the moment a word arrives.
    func testTheMeterKeepsItsFieldWhenATailSharesTheCapsule() {
        let (model, sink) = makeModel()
        model.showRecording()
        model.updateLevel(0.6)
        let before = sink.last.bars
        XCTAssertEqual(before.count, PillGeometry.barCount)
        model.livePartial("hello there world")
        XCTAssertEqual(sink.last.bars, before, "the same ten bars, in the same places")
        XCTAssertGreaterThan(sink.last.totalWidth, PillGeometry.widthListening)
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
        // `12 + 40.25 + 8 + w + 12` — the chrome grew when the meter stopped
        // narrowing for a tail.
        XCTAssertEqual(PillTailGeometry.chrome, 84, "whole points: NSWindow snaps, SwiftUI does not")
        XCTAssertEqual(PillTailGeometry.totalWidth(tailWidth: PillTailGeometry.minWidth), 128)
        XCTAssertEqual(PillTailGeometry.totalWidth(tailWidth: PillTailGeometry.maxWidth), 280)
    }

    // MARK: - transientNotice

    func testNoticeFromIdleSettlesBackToTheBar() {
        let (model, sink) = makeModel()
        model.transientNotice("Learned Sharique")
        XCTAssertEqual(model.state, .success)
        XCTAssertTrue(sink.last.isVisible)
        XCTAssertEqual(sink.last.bubble, "Learned Sharique")
        XCTAssertEqual(sink.last.glyph, .sparkle, "a notice is a text row, not a check mark")
        XCTAssertEqual(sink.scheduled.last?.seconds, PillGeometry.noticeDuration)
        XCTAssertEqual(sink.scheduled.last?.action, .settle)

        model.fireDeferred(.settle)
        XCTAssertEqual(model.state, .idle)
        XCTAssertTrue(sink.last.isVisible)
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
