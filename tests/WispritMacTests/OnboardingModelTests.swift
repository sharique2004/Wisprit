import XCTest
import WispritIMProtocol
@testable import WispritMac

/// The first-run wizard's step machine. Same discipline as the checklist: every
/// input is a value, so the "user has granted two of three permissions" states
/// are reachable in a test.
final class OnboardingModelTests: XCTestCase {

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

    // MARK: - ordering

    /// Two orderings are load-bearing (§4.2): the mic test sits straight after
    /// the grant it verifies, and the 🌐 key comes BEFORE Input Monitoring —
    /// a user whose 🌐 opens the emoji picker cannot pass `.tryIt` no matter
    /// what they grant, and it is the only step resolvable without a prompt.
    func testStepsAreOrderedToMinimiseRelaunches() {
        XCTAssertEqual(OnboardingStep.allCases,
                       [.welcome, .microphone, .micTest, .globeKey, .inputMonitoring,
                        .accessibility, .tryIt, .liveTyping])
    }

    func testWelcomeIsWhereAFreshRunStarts() {
        let state = inputs(facts(), welcome: false)
        XCTAssertEqual(OnboardingModel.firstIncomplete(state), .welcome)
    }

    func testItWalksForwardOnePermissionAtATime() {
        var state = inputs(facts(accessibility: false,
                                 inputMonitoring: "undetermined",
                                 microphone: "undetermined"))
        XCTAssertEqual(OnboardingModel.firstIncomplete(state), .microphone)

        state = inputs(facts(accessibility: false, inputMonitoring: "undetermined"),
                       micTestPassed: false)
        XCTAssertEqual(OnboardingModel.firstIncomplete(state), .micTest)

        state = inputs(facts(accessibility: false, inputMonitoring: "undetermined"),
                       globe: .showEmoji)
        XCTAssertEqual(OnboardingModel.firstIncomplete(state), .globeKey)

        state = inputs(facts(accessibility: false, inputMonitoring: "undetermined"))
        XCTAssertEqual(OnboardingModel.firstIncomplete(state), .inputMonitoring)

        state = inputs(facts(accessibility: false))
        XCTAssertEqual(OnboardingModel.firstIncomplete(state), .accessibility)

        state = inputs(facts(), didDictate: false)
        XCTAssertEqual(OnboardingModel.firstIncomplete(state), .tryIt)
    }

    /// The one thing TCC cannot answer: a granted microphone can still be a
    /// muted or wrong input. The step is not optional, and nothing past it is
    /// offered until the engine transcribes the user (R15 — evidence, not a
    /// level threshold).
    func testTheMicTestGatesOnTranscriptionEvidenceAndIsNotOptional() {
        XCTAssertFalse(OnboardingStep.micTest.isOptional)
        let silent = inputs(facts(), micTestPassed: false)
        XCTAssertFalse(OnboardingModel.isSatisfied(.micTest, silent))
        XCTAssertEqual(OnboardingModel.firstIncomplete(silent), .micTest)
        XCTAssertFalse(OnboardingModel.isComplete(silent))

        XCTAssertTrue(OnboardingModel.isSatisfied(.micTest, inputs(facts())))
    }

    /// "I use an external keyboard" resolves the 🌐 step by making it moot:
    /// there is no 🌐 press to intercept on the right ⌥ key.
    func testChoosingTheRightOptionHotkeySettlesTheGlobeKeyStep() {
        let stuck = inputs(facts(), globe: .showEmoji)
        XCTAssertFalse(OnboardingModel.isSatisfied(.globeKey, stuck))

        let switched = inputs(facts(), globe: .showEmoji, hotkey: .rightOption)
        XCTAssertTrue(OnboardingModel.isSatisfied(.globeKey, switched))
        XCTAssertNil(OnboardingModel.firstIncomplete(
            inputs(facts(), globe: .showEmoji, liveTypingSettled: true,
                   hotkey: .rightOption)))
    }

    /// The doctor is deliberately lenient here (Accessibility standing in for a
    /// stale `IOHIDCheckAccess` read). The wizard must not be: walking a user
    /// past an unproven Input Monitoring grant is the exact failure this whole
    /// window exists to prevent.
    func testInputMonitoringIsStricterThanTheDoctorLeniency() {
        let lenient = facts(accessibility: true, inputMonitoring: "undetermined")
        let row = SetupChecklist.items(from: lenient)
            .first { $0.id == SetupChecklist.inputMonitoringID }
        XCTAssertEqual(row?.mark, .warn)
        XCTAssertFalse(row?.isRequired ?? true, "doctor does not fail the run for this")
        XCTAssertFalse(OnboardingModel.isSatisfied(.inputMonitoring, inputs(lenient)),
                       "the wizard still stops here")
    }

    // MARK: - optional steps

    func testGlobeKeyIsOnlyClearWhenItIsProvablyDoNothing() {
        XCTAssertTrue(GlobeKeyUsage.doNothing.isClear)
        for usage: GlobeKeyUsage in [.showEmoji, .startDictation, .changeInputSource,
                                    .other(9), .unknown] {
            XCTAssertFalse(usage.isClear, "\(usage) leaves the key taken")
        }
    }

    func testGlobeKeyParsesTheHIToolboxIntegers() {
        XCTAssertEqual(GlobeKeyUsage.from(rawValue: 0), .doNothing)
        XCTAssertEqual(GlobeKeyUsage.from(rawValue: 1), .changeInputSource)
        XCTAssertEqual(GlobeKeyUsage.from(rawValue: 2), .showEmoji)
        XCTAssertEqual(GlobeKeyUsage.from(rawValue: 3), .startDictation)
        XCTAssertEqual(GlobeKeyUsage.from(rawValue: 7), .other(7))
        XCTAssertEqual(GlobeKeyUsage.from(rawValue: nil), .unknown)
    }

    func testOptionalStepsNeverBlockCompletion() {
        let state = inputs(facts(liveTyping: false), globe: .showEmoji)
        XCTAssertTrue(OnboardingModel.isComplete(state),
                      "🌐 and Live Typing are offered, never enforced")
        XCTAssertEqual(OnboardingModel.firstIncomplete(state), .globeKey,
                       "…but they are still the next thing shown")
    }

    func testSayingNoToLiveTypingSettlesIt() {
        var state = inputs(facts(liveTyping: false))
        XCTAssertFalse(OnboardingModel.isSatisfied(.liveTyping, state))
        state = inputs(facts(liveTyping: false), liveTypingSettled: true)
        XCTAssertTrue(OnboardingModel.isSatisfied(.liveTyping, state))
        XCTAssertNil(OnboardingModel.firstIncomplete(state))
    }

    // MARK: - progress + auto-open

    func testProgressGrowsMonotonicallyAsGrantsLand() {
        let none = OnboardingModel.progress(
            inputs(facts(accessibility: false, inputMonitoring: "denied",
                         microphone: "denied", liveTyping: false),
                   globe: .showEmoji, didDictate: false, welcome: false,
                   micTestPassed: false))
        let some = OnboardingModel.progress(
            inputs(facts(accessibility: false, liveTyping: false),
                   globe: .showEmoji, didDictate: false))
        let all = OnboardingModel.progress(inputs(facts(), liveTypingSettled: true))
        XCTAssertEqual(none, 0, accuracy: 0.001)
        XCTAssertGreaterThan(some, none)
        XCTAssertEqual(all, 1, accuracy: 0.001)
    }

    func testFirstRunAlwaysOpensTheWindow() {
        XCTAssertTrue(OnboardingModel.shouldAutoOpen(
            hasCompletedBefore: false, items: SetupChecklist.items(from: facts())))
    }

    func testAHealthyReturningLaunchStaysQuietInTheMenuBar() {
        XCTAssertFalse(OnboardingModel.shouldAutoOpen(
            hasCompletedBefore: true, items: SetupChecklist.items(from: facts())))
    }

    func testARevokedGrantReopensTheWindow() {
        let broken = SetupChecklist.items(from: facts(accessibility: false))
        XCTAssertTrue(OnboardingModel.shouldAutoOpen(hasCompletedBefore: true, items: broken))
    }

    func testAMissingOptionalDoesNotReopenTheWindow() {
        let items = SetupChecklist.items(from: facts(liveTyping: false))
        XCTAssertFalse(OnboardingModel.shouldAutoOpen(hasCompletedBefore: true, items: items))
    }
}
