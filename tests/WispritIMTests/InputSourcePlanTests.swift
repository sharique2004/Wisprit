import XCTest
import WispritIMProtocol

/// Registration/enable/select is planned here and executed by the main app. The
/// invariant these tests defend: the one call that prompts the user appears
/// exactly once, during onboarding, and never on the dictation path.
final class InputSourcePlanTests: XCTestCase {

    private let home = URL(fileURLWithPath: "/Users/tester")
    private var layout: IMInstallLayout { IMInstallLayout(home: home) }
    private var staged: URL {
        URL(fileURLWithPath: "/Applications/Wisprit.app/Contents/Library/InputMethods/WispritIM.app")
    }

    private var installedPath: String { "/Users/tester/Library/Input Methods/WispritIM.app" }

    // MARK: Paths

    func testTheBundleGoesWhereTISWillAcceptIt() {
        XCTAssertEqual(layout.inputMethodsDirectory.path, "/Users/tester/Library/Input Methods")
        XCTAssertEqual(layout.installedBundle.path, installedPath)
    }

    // MARK: Preflight ladder

    func testPreflightReportsTheFirstUnmetPrecondition() {
        XCTAssertEqual(IMPreflight.evaluate(InputMethodStatus()), .needsInstall)
        XCTAssertEqual(IMPreflight.evaluate(InputMethodStatus(bundleInstalled: true)),
                       .needsRegistration)
        XCTAssertEqual(IMPreflight.evaluate(InputMethodStatus(bundleInstalled: true, registered: true)),
                       .needsEnable)
        XCTAssertEqual(IMPreflight.evaluate(InputMethodStatus(bundleInstalled: true, registered: true,
                                                              enabled: true)),
                       .notSelected)
        XCTAssertEqual(IMPreflight.evaluate(InputMethodStatus(bundleInstalled: true, registered: true,
                                                              enabled: true, selected: true)),
                       .ready)
    }

    func testAStaleInstallIsReportedBeforeAnythingElse() {
        let status = InputMethodStatus(bundleInstalled: true, registered: true, enabled: true,
                                       selected: true,
                                       installedVersion: "1.0", stagedVersion: "2.0")
        XCTAssertEqual(IMPreflight.evaluate(status), .needsUpdate(installed: "1.0", staged: "2.0"))
        XCTAssertFalse(IMPreflight.evaluate(status).isUsable)
    }

    func testNotSelectedIsUsableBecauseSelectingIsCheapAndSilent() {
        XCTAssertTrue(IMPreflightVerdict.notSelected.isUsable)
        XCTAssertTrue(IMPreflightVerdict.ready.isUsable)
        XCTAssertFalse(IMPreflightVerdict.needsEnable.isUsable)
    }

    func testRemediesNameTheExactPlaceToGo() {
        XCTAssertTrue(IMPreflight.remedy(for: .needsInstall, layout: layout)
            .contains("/Users/tester/Library/Input Methods"))
        XCTAssertTrue(IMPreflight.remedy(for: .needsEnable)
            .contains("third-party input method"))
    }

    // MARK: Onboarding

    func testFirstRunPlansInstallRegisterEnableInThatOrder() {
        let plan = IMOnboarding.plan(status: InputMethodStatus(), stagedBundle: staged, layout: layout)

        XCTAssertEqual(plan.calls, [
            .installBundle(from: staged, to: layout.installedBundle),
            .registerInputSource(bundleURL: layout.installedBundle),
            .enableInputSource(sourceID: "com.wisprit.im"),
        ])
        XCTAssertTrue(plan.promptsUser)
        XCTAssertNotNil(plan.userMessage)
    }

    func testEnablingIsPlannedExactlyOnceAndOnlyWhenItIsMissing() {
        let plan = IMOnboarding.plan(
            status: InputMethodStatus(bundleInstalled: true, registered: true, enabled: true),
            stagedBundle: staged, layout: layout)
        XCTAssertTrue(plan.isNoop, "a healthy install must never re-prompt")
        XCTAssertFalse(plan.promptsUser)
    }

    func testUpdatingAnEnabledInstallDoesNotRePrompt() {
        let status = InputMethodStatus(bundleInstalled: true, registered: true, enabled: true,
                                       selected: true, installedVersion: "1.0", stagedVersion: "2.0")
        let plan = IMOnboarding.plan(status: status, stagedBundle: staged, layout: layout)

        XCTAssertEqual(plan.calls, [
            .removeInstalledBundle(at: layout.installedBundle),
            .installBundle(from: staged, to: layout.installedBundle),
            .registerInputSource(bundleURL: layout.installedBundle),
        ])
        XCTAssertFalse(plan.promptsUser)
    }

    func testRegistrationOnlyRepairIsMinimal() {
        let plan = IMOnboarding.plan(
            status: InputMethodStatus(bundleInstalled: true, enabled: true),
            stagedBundle: staged, layout: layout)
        XCTAssertEqual(plan.calls, [.registerInputSource(bundleURL: layout.installedBundle)])
    }

    // MARK: Session-time selection

    func testWarmPolicySelectsOnceAtStartupAndNeverAgain() {
        let installed = InputMethodStatus(bundleInstalled: true, registered: true, enabled: true)
        let startup = IMOnboarding.startupPlan(status: installed, policy: .warm)
        XCTAssertEqual(startup.calls, [.selectInputSource(sourceID: "com.wisprit.im")])

        var selected = installed
        selected.selected = true
        XCTAssertTrue(IMOnboarding.startupPlan(status: selected, policy: .warm).isNoop)
        XCTAssertTrue(IMOnboarding.sessionStartPlan(status: selected, policy: .warm).isNoop,
                      "Fn-down must not pay a process launch")
        XCTAssertTrue(IMOnboarding.sessionEndPlan(status: selected, policy: .warm).isNoop,
                      "staying selected is what keeps the IM process warm")
    }

    func testPerUtterancePolicySelectsAndDeselectsAroundEachHold() {
        let ready = InputMethodStatus(bundleInstalled: true, registered: true, enabled: true)
        XCTAssertTrue(IMOnboarding.startupPlan(status: ready, policy: .perUtterance).isNoop)
        XCTAssertEqual(IMOnboarding.sessionStartPlan(status: ready, policy: .perUtterance).calls,
                       [.selectInputSource(sourceID: "com.wisprit.im")])

        var selected = ready
        selected.selected = true
        XCTAssertEqual(IMOnboarding.sessionEndPlan(status: selected, policy: .perUtterance).calls,
                       [.deselectInputSource(sourceID: "com.wisprit.im")])
    }

    func testNoSessionPlanEverPromptsTheUser() {
        let states: [InputMethodStatus] = [
            InputMethodStatus(),
            InputMethodStatus(bundleInstalled: true),
            InputMethodStatus(bundleInstalled: true, registered: true),
            InputMethodStatus(bundleInstalled: true, registered: true, enabled: true),
            InputMethodStatus(bundleInstalled: true, registered: true, enabled: true, selected: true),
        ]
        for status in states {
            for policy in IMSelectionPolicy.allCases {
                XCTAssertFalse(IMOnboarding.startupPlan(status: status, policy: policy).promptsUser)
                XCTAssertFalse(IMOnboarding.sessionStartPlan(status: status, policy: policy).promptsUser)
                XCTAssertFalse(IMOnboarding.sessionEndPlan(status: status, policy: policy).promptsUser)
            }
        }
    }

    func testAnUnusableInstallPlansNothingAtSessionTime() {
        let notEnabled = InputMethodStatus(bundleInstalled: true, registered: true)
        let plan = IMOnboarding.sessionStartPlan(status: notEnabled)
        XCTAssertTrue(plan.isNoop)
        XCTAssertNotNil(plan.userMessage, "the app falls back to pasting and can say why")
    }

    // MARK: Uninstall

    func testUninstallDeselectsThenRemoves() {
        let status = InputMethodStatus(bundleInstalled: true, registered: true,
                                       enabled: true, selected: true)
        let plan = IMOnboarding.uninstallPlan(status: status, layout: layout)
        XCTAssertEqual(plan.calls, [
            .deselectInputSource(sourceID: "com.wisprit.im"),
            .removeInstalledBundle(at: layout.installedBundle),
        ])
    }

    func testUninstallOnACleanMachineIsANoop() {
        XCTAssertTrue(IMOnboarding.uninstallPlan(status: InputMethodStatus(), layout: layout).isNoop)
    }

    // MARK: Rendering (this is what the user sees in the log)

    func testCallsRenderAsTheLiteralCallsMade() {
        XCTAssertEqual(TISCall.enableInputSource(sourceID: "com.wisprit.im").rendered,
                       "TISEnableInputSource(com.wisprit.im)")
        XCTAssertEqual(TISCall.selectInputSource(sourceID: "com.wisprit.im").rendered,
                       "TISSelectInputSource(com.wisprit.im)")
        XCTAssertEqual(TISCall.registerInputSource(bundleURL: layout.installedBundle).rendered,
                       "TISRegisterInputSource(\(installedPath))")
    }

    func testOnlyEnableIsMarkedAsPrompting() {
        XCTAssertTrue(TISCall.enableInputSource(sourceID: "x").promptsUser)
        for call: TISCall in [.selectInputSource(sourceID: "x"),
                              .deselectInputSource(sourceID: "x"),
                              .registerInputSource(bundleURL: layout.installedBundle),
                              .installBundle(from: staged, to: layout.installedBundle),
                              .removeInstalledBundle(at: layout.installedBundle)] {
            XCTAssertFalse(call.promptsUser, "\(call.rendered) must be silent")
        }
    }

    // MARK: Tier decisions

    func testTierLadder() {
        let full = IMClientCapabilities(supportsUnicode: true, bundleID: "com.apple.TextEdit",
                                        supportsDocumentAccess: true)
        XCTAssertEqual(IMDeliveryTier.decide(capabilities: full), .markedStreaming)
        XCTAssertEqual(IMDeliveryTier.decide(capabilities: full, markedTextHealthy: false), .commitOnly)
        XCTAssertEqual(IMDeliveryTier.decide(capabilities: nil), .unsupported)

        var noUnicode = full
        noUnicode.supportsUnicode = false
        XCTAssertEqual(IMDeliveryTier.decide(capabilities: noUnicode), .unsupported)
    }

    func testRetroEditNeedsDocumentAccess() {
        let chrome = IMClientCapabilities(supportsUnicode: true, bundleID: "com.google.Chrome",
                                          supportsDocumentAccess: false)
        XCTAssertEqual(IMDeliveryTier.decide(capabilities: chrome), .markedStreaming)
        XCTAssertFalse(IMDeliveryTier.supportsRetroEdit(chrome))
        XCTAssertFalse(IMDeliveryTier.supportsRetroEdit(nil))
    }

    func testTiersAgreeOnWhatTheyDo() {
        XCTAssertTrue(IMDeliveryTier.markedStreaming.streamsLiveTail)
        XCTAssertFalse(IMDeliveryTier.commitOnly.streamsLiveTail)
        XCTAssertTrue(IMDeliveryTier.commitOnly.acceptsCommits)
        XCTAssertFalse(IMDeliveryTier.unsupported.acceptsCommits)
    }
}

/// The sandbox changes what `~` means, and the input method is sandboxed.
final class InstallLayoutTests: XCTestCase {

    func testTheRealHomeIsUsedNotTheSandboxContainer() {
        let home = IMInstallLayout.realUserHome.path
        XCTAssertTrue(home.hasPrefix("/Users/") || home.hasPrefix("/var/"), "got \(home)")
        XCTAssertFalse(home.contains("/Library/Containers/"),
                       "TISRegisterInputSource only accepts ~/Library/Input Methods — "
                       + "a container path would silently never register")
    }

    func testUserLayoutPointsAtTheOnlyDirectoryTISAccepts() {
        XCTAssertEqual(IMInstallLayout.user.inputMethodsDirectory.path,
                       IMInstallLayout.realUserHome.path + "/Library/Input Methods")
        XCTAssertEqual(IMInstallLayout.user.installedBundle.lastPathComponent, "WispritIM.app")
    }
}
