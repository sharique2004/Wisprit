import XCTest
import WispritIMProtocol
import WispritPersistence
@testable import WispritMac

/// The onboarding *sheet* — `docs/design/ui-redesign.md` §4.1/§4.2.
///
/// `OnboardingModelTests` pins the gates; this pins what the sheet does with
/// them: which card comes next, what the footer offers, and when the mic test
/// stops asking the user to say something. Every one of those is a pure
/// function of values, which is the whole reason they live outside the view.
final class OnboardingFlowTests: XCTestCase {

    // MARK: - fixtures (the `OnboardingModelTests` idiom)

    private func facts(accessibility: Bool = true,
                       inputMonitoring: String = "granted",
                       microphone: String = "granted",
                       liveTyping: Bool = true) -> DoctorFacts {
        var facts = DoctorFacts()
        facts.accessibility = accessibility
        facts.inputMonitoring = inputMonitoring
        facts.postEventAccess = true
        facts.microphone = microphone
        facts.speechOK = true
        facts.aiAvailable = true
        facts.imStaged = true
        if liveTyping {
            facts.imStatus = InputMethodStatus(bundleInstalled: true, registered: true,
                                               enabled: true, selected: true,
                                               installedVersion: "2.0.0-dev",
                                               stagedVersion: "2.0.0-dev")
            facts.imReachable = true
            facts.liveTypingEnabled = true
        }
        return facts
    }

    private func inputs(_ facts: DoctorFacts,
                        globe: GlobeKeyUsage = .doNothing,
                        didDictate: Bool = true,
                        welcome: Bool = true,
                        liveTypingSettled: Bool = false,
                        micTestPassed: Bool = true,
                        hotkey: WindowSettings.HotkeyOption = .fn) -> OnboardingInputs {
        OnboardingInputs(items: SetupChecklist.items(from: facts),
                         globeKey: globe,
                         didDictate: didDictate,
                         welcomeAcknowledged: welcome,
                         liveTypingSettled: liveTypingSettled,
                         micTestPassed: micTestPassed,
                         hotkey: hotkey)
    }

    /// Everything answered — the state the completion card needs.
    private var settled: OnboardingInputs { inputs(facts(), liveTypingSettled: true) }

    // MARK: - which card is next

    /// §4.2: the 🌐 step is skipped outright on the right ⌥ key. Navigation has
    /// to agree with the gate in *both* directions, or Back reveals a card
    /// Continue decided was moot.
    func testTheGlobeKeyCardIsNeverDrawnOnTheRightOptionKey() {
        let fn = inputs(facts(), globe: .showEmoji)
        let external = inputs(facts(), globe: .showEmoji, hotkey: .rightOption)

        XCTAssertFalse(OnboardingFlow.isSkipped(.globeKey, fn))
        XCTAssertTrue(OnboardingFlow.isSkipped(.globeKey, external))

        XCTAssertEqual(OnboardingFlow.next(after: .micTest, fn), .globeKey)
        XCTAssertEqual(OnboardingFlow.next(after: .micTest, external), .inputMonitoring)

        XCTAssertEqual(OnboardingFlow.previous(before: .inputMonitoring, fn), .globeKey)
        XCTAssertEqual(OnboardingFlow.previous(before: .inputMonitoring, external), .micTest)
    }

    /// The mic test sits between the grant it verifies and the 🌐 question
    /// (§4.2). The sheet walks that order, not the checklist's.
    func testTheCascadeWalksTheSpecOrder() {
        let state = inputs(facts())
        var visited: [OnboardingStep] = [.welcome]
        while let next = OnboardingFlow.next(after: visited[visited.count - 1], state) {
            visited.append(next)
        }
        XCTAssertEqual(visited,
                       [.welcome, .microphone, .micTest, .globeKey, .inputMonitoring,
                        .accessibility, .tryIt, .liveTyping])
    }

    func testBackIsDisabledOnlyOnTheFirstCard() {
        XCTAssertNil(OnboardingFlow.previous(before: .welcome, inputs(facts())))
        XCTAssertEqual(OnboardingFlow.previous(before: .microphone, inputs(facts())), .welcome)
    }

    /// nil is what the sheet turns into `finishOnboarding()` — the same contract
    /// `skipStep()` has at the last index.
    func testThereIsNoNinthStep() {
        XCTAssertNil(OnboardingFlow.next(after: .liveTyping, settled))
    }

    // MARK: - the footer

    /// Reading the welcome card IS doing it, so it never offers a Skip the user
    /// could take instead.
    func testWelcomeOnlyEverOffersContinue() {
        XCTAssertEqual(OnboardingFlow.trailing(.welcome, inputs(facts(), welcome: false)),
                       .advance)
        XCTAssertEqual(OnboardingFlow.trailing(.welcome, inputs(facts())), .advance)
    }

    func testASettledStepContinuesAndAnOpenOneOffersSkip() {
        XCTAssertEqual(OnboardingFlow.trailing(.accessibility, inputs(facts())), .advance)
        XCTAssertEqual(
            OnboardingFlow.trailing(.accessibility, inputs(facts(accessibility: false))),
            .skip)
    }

    /// The one disabled trailing control in the cascade. The mic test is not
    /// `isOptional`, so its Skip cannot come from the step — it is earned by six
    /// seconds of silence, and until then Continue is dead (§4.2).
    func testTheMicTestBlocksContinueUntilItHearsSomethingOrGivesUp() {
        let silent = inputs(facts(), micTestPassed: false)
        XCTAssertEqual(OnboardingFlow.trailing(.micTest, silent), .blocked)
        XCTAssertEqual(OnboardingFlow.trailing(.micTest, silent, micTestStalled: true), .skip)
        XCTAssertEqual(OnboardingFlow.trailing(.micTest, inputs(facts())), .advance)
    }

    /// §4.3 lives inside step 8, and it needs both halves: the optional question
    /// answered, and every required step actually done. "You're set." over a
    /// missing Accessibility grant is the one lie this window exists to prevent.
    func testTheCompletionCardNeedsTheWholeCascadeNotJustTheLastAnswer() {
        XCTAssertTrue(OnboardingFlow.showsCompletion(.liveTyping, settled))
        XCTAssertEqual(OnboardingFlow.trailing(.liveTyping, settled), .finish)
        XCTAssertEqual(OnboardingFlow.trailingTitle(.finish), "Open Wisprit")

        let unanswered = inputs(facts(liveTyping: false))
        XCTAssertFalse(OnboardingFlow.showsCompletion(.liveTyping, unanswered))

        let broken = inputs(facts(accessibility: false), liveTypingSettled: true)
        XCTAssertFalse(OnboardingFlow.showsCompletion(.liveTyping, broken),
                       "a skipped permission must not be congratulated")
        XCTAssertNotEqual(OnboardingFlow.trailing(.liveTyping, broken), .finish)
    }

    /// A skipped step's segment is filled, because the gate says it is
    /// satisfied — the rail never shows a hole for a question nobody was asked.
    func testTheRailHasOneSegmentPerStepAndMirrorsTheGates() {
        let external = inputs(facts(), globe: .showEmoji, liveTypingSettled: true,
                              hotkey: .rightOption)
        let segments = OnboardingFlow.segments(external)
        XCTAssertEqual(segments.count, OnboardingStep.allCases.count)
        XCTAssertEqual(segments, OnboardingStep.allCases.map {
            OnboardingModel.isSatisfied($0, external)
        })
        XCTAssertTrue(segments.allSatisfy { $0 })

        let fresh = inputs(facts(accessibility: false, inputMonitoring: "undetermined",
                                 microphone: "undetermined", liveTyping: false),
                           globe: .showEmoji, didDictate: false, welcome: false,
                           micTestPassed: false)
        XCTAssertEqual(OnboardingFlow.segments(fresh).filter { $0 }.count, 0)
    }
}

// MARK: - the mic test

/// Step 3's measurement — the only gate in the cascade that no TCC read can
/// stand in for.
final class MicTestStateTests: XCTestCase {

    /// The threshold is *the engine's*, reused rather than restated (§4.2). A
    /// mic test that passed below the transcriber's voiced floor would wave
    /// through inputs that then produce nothing but empty transcripts.
    func testThePassLevelIsTheEngineSVoicedFloor() {
        XCTAssertEqual(MicTestState.passLevel, MetricsSummary.voicedPeakThreshold)
    }

    func testAVoicedPeakPassesOnceAndStaysPassed() {
        var state = MicTestState()
        XCTAssertEqual(state.phase, .waiting)
        XCTAssertFalse(state.tick(level: 0.001, interval: 0.05))

        XCTAssertTrue(state.tick(level: MicTestState.passLevel, interval: 0.05),
                      "the boundary itself passes")
        XCTAssertTrue(state.hasPassed)
        XCTAssertEqual(state.caption, "Heard you.")

        XCTAssertFalse(state.tick(level: 0.9, interval: 0.05), "it only fires once")
        for _ in 0..<3 { state.tick(level: 0, interval: MicTestState.stallAfter) }
        XCTAssertTrue(state.hasPassed, "a passed test does not un-pass in silence")
        XCTAssertFalse(state.offersSkip)
    }

    func testSilenceOffersSkipOnlyAfterTheFullSixSeconds() {
        var state = MicTestState()
        state.tick(level: 0, interval: MicTestState.stallAfter - 0.1)
        XCTAssertEqual(state.phase, .waiting)
        XCTAssertFalse(state.offersSkip)
        XCTAssertEqual(state.caption, "Waiting for sound…")

        state.tick(level: 0, interval: 0.1)
        XCTAssertEqual(state.phase, .stalled)
        XCTAssertTrue(state.offersSkip)
        XCTAssertTrue(state.caption.contains("Sound ▸ Input"))
    }

    /// Giving up is not final: a user who was fixing their input device in
    /// another window and comes back talking still passes.
    func testAStalledTestStillPassesIfSoundArrivesLate() {
        var state = MicTestState()
        state.tick(level: 0, interval: MicTestState.stallAfter)
        XCTAssertEqual(state.phase, .stalled)
        XCTAssertTrue(state.tick(level: 0.4, interval: 0.05))
        XCTAssertTrue(state.hasPassed)
    }

    /// An input that will not open has nothing to wait for, so the user is not
    /// made to sit out six seconds before Skip appears.
    func testAnInputThatWillNotOpenSkipsTheWait() {
        var state = MicTestState()
        state.noteCaptureFailed()
        XCTAssertEqual(state.phase, .stalled)
        XCTAssertTrue(state.offersSkip)
        XCTAssertTrue(state.levels.allSatisfy { $0 == 0 })
    }

    func testTheBarsAreTheMicTestFieldAndSilenceIsADotRow() {
        var state = MicTestState()
        XCTAssertEqual(state.levels.count, 33, "§4.2's 33-bar field")
        XCTAssertTrue(state.levels.allSatisfy { $0 == 0 })

        state.tick(level: 0.5, interval: 0.05)
        XCTAssertGreaterThan(state.levels[state.levels.count - 1], 0,
                             "newest sample is on the right")
        XCTAssertEqual(state.levels[0], 0, "and it scrolls in from there")
    }

    /// A dead input can hand back garbage; garbage is silence, never a pass.
    func testNonsenseLevelsAreSilence() {
        var state = MicTestState()
        XCTAssertFalse(state.tick(level: .nan, interval: 0.05))
        XCTAssertFalse(state.tick(level: -1, interval: 0.05))
        XCTAssertEqual(state.phase, .waiting)
        XCTAssertTrue(state.levels.allSatisfy { $0 == 0 })
    }
}

// MARK: - the capture behind it

/// The probe's contract is a privacy contract: the input opens when the card
/// appears and is closed by the time it leaves, whatever happened in between.
@MainActor
final class OnboardingMicProbeTests: XCTestCase {

    private final class Recorder {
        var starts = 0
        var stops = 0
        var passes = 0
        var level: Double = 0
        var opens = true

        func source() -> OnboardingMicProbe.Source {
            OnboardingMicProbe.Source(start: { self.starts += 1; return self.opens },
                                      stop: { self.stops += 1 },
                                      level: { self.level })
        }
    }

    func testItOpensTheInputNotifiesOnceAndAlwaysClosesIt() async {
        let recorder = Recorder()
        recorder.level = 0.4
        let probe = OnboardingMicProbe(source: recorder.source)

        let task = Task { @MainActor in
            await probe.run { recorder.passes += 1 }
        }
        var waited = 0
        while recorder.passes == 0 && waited < 400 {
            try? await Task.sleep(for: .milliseconds(10))
            waited += 1
        }
        task.cancel()
        _ = await task.value

        XCTAssertEqual(recorder.starts, 1)
        XCTAssertEqual(recorder.passes, 1, "the cascade is told exactly once")
        XCTAssertEqual(recorder.stops, 1, "the mic indicator goes dark on the way out")
        XCTAssertTrue(probe.state.hasPassed)
    }

    /// `start()` returning false means nothing was opened — and `MicCapture`
    /// unwinds its own tap in that case, which is why `SessionController` does
    /// not call `stop()` there either. Mirror it, do not "improve" it.
    func testAnInputThatWillNotOpenIsReportedImmediately() async {
        let recorder = Recorder()
        recorder.opens = false
        let probe = OnboardingMicProbe(source: recorder.source)

        await probe.run { recorder.passes += 1 }

        XCTAssertEqual(recorder.starts, 1)
        XCTAssertEqual(recorder.stops, 0)
        XCTAssertEqual(recorder.passes, 0)
        XCTAssertTrue(probe.state.offersSkip)
    }
}
