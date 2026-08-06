import XCTest
import WispritIMProtocol
@testable import WispritMac

/// The window's checklist, driven entirely by fake `DoctorFacts` — every state
/// below would otherwise need a TCC grant revoked by hand.
///
/// The load-bearing property is that the window never invents a verdict: each
/// row's mark and required-ness come from the doctor check of the same label, so
/// these tests also pin "window agrees with `wisprit doctor`".
final class SetupChecklistTests: XCTestCase {

    private func green() -> DoctorFacts {
        var facts = DoctorFacts()
        facts.executablePath = "/Applications/Wisprit.app/Contents/MacOS/Wisprit"
        facts.accessibility = true
        facts.inputMonitoring = "granted"
        facts.postEventAccess = true
        facts.microphone = "granted"
        facts.speechOK = true
        facts.transcriberAvailable = true
        facts.speechDetail = "SpeechTranscriber ready for en_US"
        facts.requestedLocale = "en-US"
        facts.aiAvailable = true
        facts.configValid = true
        facts.dictionaryValid = true
        facts.imStaged = true
        facts.imStatus = InputMethodStatus(bundleInstalled: true, registered: true,
                                           enabled: true, selected: true,
                                           installedVersion: "2.0.0-dev",
                                           stagedVersion: "2.0.0-dev")
        facts.imReachable = true
        facts.liveTypingEnabled = true
        return facts
    }

    private func item(_ id: String, _ facts: DoctorFacts) -> SetupItem {
        let found = SetupChecklist.items(from: facts).first { $0.id == id }
        return found ?? SetupItem(id: id, title: "missing", mark: .bad,
                                  isRequired: true, summary: "", detail: "")
    }

    // MARK: - shape

    func testSevenRowsInReadingOrder() {
        XCTAssertEqual(SetupChecklist.items(from: green()).map(\.id), [
            SetupChecklist.microphoneID,
            SetupChecklist.inputMonitoringID,
            SetupChecklist.accessibilityID,
            SetupChecklist.postEventID,
            SetupChecklist.speechID,
            SetupChecklist.appleIntelligenceID,
            SetupChecklist.liveTypingID,
        ])
    }

    /// The regression this row exists for: the doctor emits `Post-event access`,
    /// `Secure Keyboard Entry` and `Live Typing bundle`, and the window used to
    /// drop all three — the first two being silent-failure modes, so the page
    /// could read "Ready — hold 🌐 to dictate" on a machine where every paste is
    /// thrown away. Nothing the doctor considers required may go unshown.
    func testEveryRequiredDoctorCheckReachesTheWindow() {
        var permutations: [DoctorFacts] = [green()]
        for accessibility in [true, false] {
            for monitoring in ["granted", "denied", "undetermined"] {
                for microphone in ["granted", "denied", "undetermined", "restricted"] {
                    for speech in [true, false] {
                        var facts = green()
                        facts.accessibility = accessibility
                        facts.inputMonitoring = monitoring
                        facts.microphone = microphone
                        facts.speechOK = speech
                        facts.postEventAccess = false
                        facts.secureInputActive = true
                        permutations.append(facts)
                    }
                }
            }
        }
        for facts in permutations {
            let shown = Set(SetupChecklist.items(from: facts).map(\.doctorLabel))
            for check in Doctor.report(from: facts).checks where check.isRequired {
                XCTAssertTrue(shown.contains(check.label),
                              "'\(check.label)' is required but no window row shows it")
            }
        }
    }

    /// `CGPreflightPostEventAccess` can be false while `AXIsProcessTrusted` is
    /// true — the grant binds at launch — and in that gap macOS drops every
    /// paste without an error anywhere. The row says so, and offers the relaunch
    /// that is the actual remedy.
    func testPostEventAccessIsShownWithTheRelaunchRemedy() {
        var facts = green()
        facts.postEventAccess = false
        let row = item(SetupChecklist.postEventID, facts)
        XCTAssertEqual(row.mark, .warn, "the mark is still the doctor's")
        XCTAssertTrue(row.isEssential, "no paste means no dictation")
        XCTAssertEqual(row.fix, .openAccessibilitySettings)
        XCTAssertEqual(row.secondaryFix, .relaunch)
        XCTAssertTrue(row.detail.contains("posted events will be dropped"),
                      "the doctor's own wording, verbatim")
        XCTAssertTrue(row.note?.contains("quit and reopen") ?? false)

        let healthy = item(SetupChecklist.postEventID, green())
        XCTAssertEqual(healthy.mark, .ok)
        XCTAssertEqual(healthy.fix, .none)
        XCTAssertEqual(healthy.secondaryFix, .none)
    }

    /// A green checklist plus a warning the user can act on beats a green
    /// checklist alone: the hero stops claiming a flat "Ready" while an
    /// essential row is unproven, without disagreeing with the doctor's
    /// exit-code rule about what is actually broken.
    func testTheHeroNamesAnUnprovenEssentialRowInsteadOfClaimingReady() {
        var facts = green()
        facts.postEventAccess = false
        let items = SetupChecklist.items(from: facts)
        let summary = SetupChecklist.summary(items: items, hotkeyLabel: "🌐")
        XCTAssertEqual(summary.hero, .ready, "the doctor does not call this broken")
        XCTAssertTrue(summary.subhead.contains("Sending the paste keystroke"))
        XCTAssertTrue(summary.subhead.contains("without a word"))
    }

    /// Transient by nature: while a password field holds Secure Keyboard Entry
    /// macOS never delivers the dictation key, and no permission the user can
    /// grant changes that. A banner, not a row.
    func testSecureInputIsAnnouncedOnlyWhileItIsHeld() {
        XCTAssertNil(SetupChecklist.secureInputNotice(green()))
        var held = green()
        held.secureInputActive = true
        let notice = SetupChecklist.secureInputNotice(held)
        XCTAssertTrue(notice?.contains("password field") ?? false)
        XCTAssertTrue(notice?.contains("dictation key") ?? false)
        XCTAssertFalse(SetupChecklist.items(from: held)
                        .contains { $0.doctorLabel == "Secure Keyboard Entry" },
                       "it never becomes a permission row — there is nothing to grant")
    }

    func testEveryRowIsGreenOnAHealthyMachine() {
        let items = SetupChecklist.items(from: green())
        XCTAssertTrue(items.allSatisfy(\.isSatisfied))
        XCTAssertTrue(items.allSatisfy { $0.fix == .none })
        XCTAssertTrue(items.allSatisfy { $0.fixTitle.isEmpty })
    }

    /// The window must not disagree with the CLI. Every row borrows its mark and
    /// its required-ness from the doctor check of the same label.
    func testMarksAreBorrowedFromTheDoctorReport() {
        var facts = green()
        facts.accessibility = false
        facts.inputMonitoring = "denied"
        facts.microphone = "denied"
        facts.speechOK = false

        let report = Doctor.report(from: facts)
        let items = SetupChecklist.items(from: facts)

        XCTAssertEqual(items.first { $0.id == SetupChecklist.accessibilityID }?.mark,
                       report.check("Accessibility")?.mark)
        XCTAssertEqual(items.first { $0.id == SetupChecklist.inputMonitoringID }?.mark,
                       report.check("Input Monitoring")?.mark)
        XCTAssertEqual(items.first { $0.id == SetupChecklist.microphoneID }?.isRequired,
                       report.check("Microphone")?.isRequired)
        XCTAssertEqual(items.first { $0.id == SetupChecklist.speechID }?.mark,
                       report.check("SpeechTranscriber (on-device ASR)")?.mark)
    }

    /// The "optional" badge answers "can I dictate without this", NOT the
    /// doctor's exit-code rule — which calls a granted microphone not-required
    /// and drops Input Monitoring's required flag the moment Accessibility is
    /// on. Reading `isRequired` for that badge would label both optional.
    func testTheOptionalBadgeNeverLibelsAnEssentialPermission() {
        let items = SetupChecklist.items(from: green())
        let essential = items.filter(\.isEssential).map(\.id)
        XCTAssertEqual(essential, [SetupChecklist.microphoneID,
                                   SetupChecklist.inputMonitoringID,
                                   SetupChecklist.accessibilityID,
                                   SetupChecklist.postEventID,
                                   SetupChecklist.speechID])
        for id in [SetupChecklist.microphoneID, SetupChecklist.inputMonitoringID] {
            let row = item(id, green())
            XCTAssertFalse(row.isRequired, "the doctor's rule says not-required here")
            XCTAssertTrue(row.isEssential, "…but the window must not call it optional")
        }
    }

    // MARK: - microphone

    func testUndeterminedMicrophoneAsksRatherThanSendingToSettings() {
        var facts = green()
        facts.microphone = "undetermined"
        let mic = item(SetupChecklist.microphoneID, facts)
        XCTAssertEqual(mic.mark, .warn)
        XCTAssertEqual(mic.fix, .requestMicrophone,
                       "an undetermined grant can still be prompted for in-process")
        XCTAssertFalse(mic.isRequired, "undetermined is not yet a failure")
    }

    func testDeniedMicrophoneCanOnlyBeFixedInSystemSettings() {
        var facts = green()
        facts.microphone = "denied"
        let mic = item(SetupChecklist.microphoneID, facts)
        XCTAssertEqual(mic.mark, .bad)
        XCTAssertTrue(mic.isRequired)
        XCTAssertEqual(mic.fix, .openMicrophoneSettings)
        XCTAssertEqual(mic.fix.settingsURL,
                       "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    // MARK: - input monitoring

    func testInputMonitoringCarriesTheRelaunchNuanceUntilGranted() {
        var facts = green()
        facts.inputMonitoring = "undetermined"
        let row = item(SetupChecklist.inputMonitoringID, facts)
        XCTAssertEqual(row.note, SetupChecklist.relaunchNote)
        XCTAssertTrue(row.note?.contains("only when an app launches") ?? false)
        XCTAssertEqual(row.fix, .requestInputMonitoring)
        XCTAssertEqual(row.secondaryFix, .relaunch,
                       "the relaunch is the second half of the fix, not a hint")
    }

    func testGrantedInputMonitoringDropsTheNoteAndBothButtons() {
        let row = item(SetupChecklist.inputMonitoringID, green())
        XCTAssertNil(row.note)
        XCTAssertEqual(row.fix, .none)
        XCTAssertEqual(row.secondaryFix, .none)
    }

    // MARK: - hero

    func testHeroIsCheckingBeforeTheFirstProbeLands() {
        let summary = SetupChecklist.summary(items: [], hotkeyLabel: "🌐", hasProbed: false)
        XCTAssertEqual(summary.hero, .checking)
    }

    func testHeroNamesTheConfiguredKey() {
        let items = SetupChecklist.items(from: green())
        XCTAssertEqual(SetupChecklist.summary(items: items, hotkeyLabel: "🌐").headline,
                       "Ready — hold 🌐 to dictate")
        XCTAssertEqual(SetupChecklist.summary(items: items,
                                              hotkeyLabel: SetupChecklist.hotkeyLabel("right_option")).headline,
                       "Ready — hold the right ⌥ key to dictate")
    }

    func testHeroCountsOnlyBlockingRows() {
        var facts = green()
        facts.aiAvailable = false          // optional
        facts.imStatus = InputMethodStatus()   // optional
        let ready = SetupChecklist.summary(items: SetupChecklist.items(from: facts),
                                           hotkeyLabel: "🌐")
        XCTAssertEqual(ready.hero, .ready,
                       "optional rows never make the app look broken")
        XCTAssertTrue(ready.subhead.contains("optional"))

        facts.accessibility = false
        facts.speechOK = false
        let broken = SetupChecklist.summary(items: SetupChecklist.items(from: facts),
                                            hotkeyLabel: "🌐")
        XCTAssertEqual(broken.hero, .needsSetup(blocking: 2))
        XCTAssertEqual(broken.headline, "Needs setup")
    }

    func testDictationOffIsReportedSeparatelyFromBrokenSetup() {
        let items = SetupChecklist.items(from: green())
        let summary = SetupChecklist.summary(items: items, hotkeyLabel: "🌐",
                                             dictationEnabled: false)
        XCTAssertEqual(summary.hero, .ready)
        XCTAssertEqual(summary.headline, "Dictation is off")
    }

    // MARK: - live typing

    func testLiveTypingIsNeverBlockingAndOffersTheExistingFlow() {
        var facts = green()
        facts.imStatus = InputMethodStatus()
        facts.imReachable = false
        let row = item(SetupChecklist.liveTypingID, facts)
        XCTAssertFalse(row.isRequired)
        XCTAssertFalse(row.isBlocking)
        XCTAssertEqual(row.fix, .enableLiveTyping)
    }

    /// Installed and registered is not the same as *on*. Green here means "words
    /// appear as you speak", and with `live_typing: false` they do not — the row
    /// used to claim otherwise because the setting was gathered and never read.
    func testLiveTypingIsNotGreenWhileTheSettingIsOff() {
        var facts = green()
        facts.liveTypingEnabled = false
        let row = item(SetupChecklist.liveTypingID, facts)
        XCTAssertTrue(row.isOff)
        XCTAssertFalse(row.isSatisfied, "it is not doing anything")
        XCTAssertEqual(row.fix, .enableLiveTyping)
        XCTAssertEqual(row.fixTitle, "Turn On Live Typing…")
        XCTAssertTrue(row.summary.contains("switched off"))

        // …and an off optional row is not a chore: the hero must not count it.
        let summary = SetupChecklist.summary(items: SetupChecklist.items(from: facts),
                                             hotkeyLabel: "🌐")
        XCTAssertEqual(summary.hero, .ready)
        XCTAssertFalse(summary.subhead.contains("optional"))
    }

    /// A half-finished update leaves an input method that registers, is selected
    /// and never receives a client. The doctor catches it as `Live Typing bundle`
    /// = bad; reading only the registration check painted that row green.
    func testABrokenLiveTypingBundleDragsTheRowDown() {
        var facts = green()
        facts.imPlistViolations = ["tsInputMethodCharacterRepertoireKey is missing"]
        let row = item(SetupChecklist.liveTypingID, facts)
        XCTAssertEqual(row.mark, .bad,
                       "the worst of the three Live Typing checks, not the first")
        XCTAssertFalse(row.isSatisfied)
        XCTAssertTrue(row.detail.contains("tsInputMethodCharacterRepertoireKey"))
        XCTAssertEqual(row.fix, .enableLiveTyping)
        XCTAssertFalse(row.isBlocking, "still never blocking — pasting works")
    }

    func testWorstMarkTakesTheMoreAlarmingOfTwo() {
        XCTAssertEqual(DoctorMark.worst(.ok, .bad), .bad)
        XCTAssertEqual(DoctorMark.worst(.bad, .ok), .bad)
        XCTAssertEqual(DoctorMark.worst(.ok, .warn), .warn)
        XCTAssertEqual(DoctorMark.worst(.warn, .bad), .bad)
        XCTAssertEqual(DoctorMark.worst(.ok, nil), .ok,
                       "a check that was not emitted is not evidence of anything")
    }

    // MARK: - fix routing

    func testOnlyPaneFixesCarryADeepLink() {
        XCTAssertNil(SetupFixKind.none.settingsURL)
        XCTAssertNil(SetupFixKind.requestMicrophone.settingsURL)
        XCTAssertNil(SetupFixKind.relaunch.settingsURL)
        XCTAssertNil(SetupFixKind.enableLiveTyping.settingsURL)
        for kind: SetupFixKind in [.openMicrophoneSettings, .requestInputMonitoring,
                                  .openAccessibilitySettings, .openKeyboardSettings,
                                  .openAppleIntelligenceSettings] {
            let url = kind.settingsURL
            XCTAssertNotNil(url, "\(kind) needs a pane to open")
            XCTAssertTrue(url?.hasPrefix("x-apple.systempreferences:") ?? false)
        }
    }

    func testRelaunchHelperQuotesThePath() {
        let command = AppRelaunch.helperCommand(bundlePath: "/Users/me/Wisprit's App.app",
                                                delay: 1)
        XCTAssertEqual(command, "sleep 1; /usr/bin/open '/Users/me/Wisprit'\\''s App.app'")
    }
}
