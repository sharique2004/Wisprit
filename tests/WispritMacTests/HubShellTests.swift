import XCTest
import WispritDictionary
import WispritIMProtocol
import WispritPersistence
@testable import WispritMac

/// The Hub shell's pure decisions — `docs/design/ui-redesign.md` §3.2 / §3.6.
///
/// Everything a sidebar or a settings group *decides* (which badge, which
/// status, which sections exist at all) is a function of values, so it is
/// asserted here rather than eyeballed in a screenshot.
final class HubShellTests: XCTestCase {

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

    private func items(_ facts: DoctorFacts) -> [SetupItem] {
        SetupChecklist.items(from: facts)
    }

    // MARK: - nav

    func testTheSidebarHasThreePagesOverTwoPinnedOnes() {
        XCTAssertEqual(WispritWindowModel.Tab.allCases.map(\.rawValue),
                       ["home", "dictionary", "insights", "setup", "settings"])
        XCTAssertEqual(WispritWindowModel.Tab.primary, [.home, .dictionary, .insights])
        XCTAssertEqual(WispritWindowModel.Tab.pinned, [.setup, .settings])
    }

    func testEveryTabNamesAnSFSymbolAndATitle() {
        for tab in WispritWindowModel.Tab.allCases {
            XCTAssertFalse(tab.title.isEmpty, "\(tab)")
            XCTAssertFalse(tab.symbol.isEmpty, "\(tab)")
            XCTAssertFalse(tab.symbol.contains(" "), "\(tab) — SF Symbol names have no spaces")
        }
    }

    // MARK: - the setup badge

    func testTheBadgeIsAbsentOnAHealthyChecklist() {
        XCTAssertNil(WispritWindowModel.setupBadge(items(facts())))
    }

    func testABlockingRowOutranksAWarning() {
        let broken = items(facts(accessibility: false))
        XCTAssertEqual(WispritWindowModel.setupBadge(broken), .blocking)
    }

    /// The doctor's Input-Monitoring leniency produces a `warn` on an essential
    /// row that does not block — exactly the state the ochre dot is for.
    func testAnEssentialWarningEarnsTheAttentionDot() {
        let lenient = items(facts(inputMonitoring: "undetermined"))
        XCTAssertTrue(lenient.contains { $0.isEssential && $0.mark == .warn })
        XCTAssertFalse(lenient.contains(where: \.isBlocking))
        XCTAssertEqual(WispritWindowModel.setupBadge(lenient), .attention)
    }

    /// An optional feature the user has not set up is not a warning. Badging
    /// the sidebar for one is how a permanent dot gets learned as noise.
    func testAnOptionalRowNeverBadgesTheSidebar() {
        let noLiveTyping = items(facts(liveTyping: false))
        XCTAssertTrue(noLiveTyping.contains { !$0.isEssential && $0.mark != .ok })
        XCTAssertNil(WispritWindowModel.setupBadge(noLiveTyping))
    }

    // MARK: - the sidebar footer

    func testListeningOutranksEveryOtherStatus() {
        // Even a broken checklist: if audio is open the dot is the tally, and
        // the tally never lies (§1.6).
        XCTAssertEqual(
            WispritWindowModel.sidebarStatus(sessionState: .recording,
                                             items: items(facts(accessibility: false)),
                                             dictationEnabled: false),
            .listening)
    }

    func testTheFooterRanksSetupOverTheMasterToggle() {
        XCTAssertEqual(
            WispritWindowModel.sidebarStatus(sessionState: .idle,
                                             items: items(facts(accessibility: false)),
                                             dictationEnabled: false),
            .needsSetup)
        XCTAssertEqual(
            WispritWindowModel.sidebarStatus(sessionState: .idle,
                                             items: items(facts()),
                                             dictationEnabled: false),
            .dictationOff)
        XCTAssertEqual(
            WispritWindowModel.sidebarStatus(sessionState: .idle,
                                             items: items(facts()),
                                             dictationEnabled: true),
            .ready)
    }

    /// A finalizing utterance is not a live microphone — the audio is already
    /// stopped — so the dot must not stay orange through the insert.
    func testOnlyRecordingIsListening() {
        for state in SessionController.State.allCases where state != .recording {
            XCTAssertEqual(
                WispritWindowModel.sidebarStatus(sessionState: state,
                                                 items: items(facts()),
                                                 dictationEnabled: true),
                .ready, "\(state)")
        }
    }

    func testEveryStatusHasALabel() {
        for status: WispritWindowModel.SidebarStatus in
            [.listening, .needsSetup, .dictationOff, .ready] {
            XCTAssertFalse(status.label.isEmpty, "\(status)")
        }
    }

    // MARK: - gated settings sections (§3.6)

    /// Ineligible hardware is structural: the group does not exist. Rendering a
    /// disabled toggle for a Mac that will never have the feature is the exact
    /// pattern the redesign retires.
    func testIneligibleHardwareRemovesTheAiGroupEntirely() {
        XCTAssertEqual(
            WindowSettings.appleIntelligenceGate(available: false,
                                                 reason: "deviceNotEligible"),
            .absent)
        XCTAssertEqual(
            WindowSettings.appleIntelligenceGate(
                available: false, reason: "FoundationModels unavailable in this build"),
            .absent)
    }

    func testAppleIntelligenceSwitchedOffCollapsesToOneRowWithAFix() {
        let gate = WindowSettings.appleIntelligenceGate(
            available: false, reason: "appleIntelligenceNotEnabled")
        guard case .fixable(let message, let title, let fix) = gate else {
            return XCTFail("a switch in System Settings is fixable, not absent")
        }
        XCTAssertEqual(fix, .openAppleIntelligenceSettings)
        XCTAssertEqual(title, "Open Apple Intelligence")
        XCTAssertTrue(message.contains("Apple Intelligence"))
    }

    func testAvailableAppleIntelligenceDrawsTheRealGroup() {
        XCTAssertEqual(WindowSettings.appleIntelligenceGate(available: true, reason: ""),
                       .available)
    }

    func testABuildWithNoInputMethodHasNoLiveTypingGroup() {
        XCTAssertEqual(WindowSettings.liveTypingGate(isStaged: false, mark: nil), .absent)
    }

    func testAnUninstalledInputMethodOffersTheEnableButtonInsteadOfADeadToggle() {
        let gate = WindowSettings.liveTypingGate(isStaged: true, mark: .bad)
        guard case .fixable(_, let title, let fix) = gate else {
            return XCTFail("installable is fixable")
        }
        XCTAssertEqual(fix, .enableLiveTyping)
        XCTAssertEqual(title, "Enable Live Typing…")

        // `warn` is still not a working input method.
        if case .available = WindowSettings.liveTypingGate(isStaged: true, mark: .warn) {
            XCTFail("a warn row must not present the real toggle")
        }
        XCTAssertEqual(WindowSettings.liveTypingGate(isStaged: true, mark: .ok), .available)
    }

    // MARK: - new settings surfaces

    func testTheEngineMenuOffersOnlyTheEnginesThatExist() {
        XCTAssertEqual(WindowSettings.EngineOption.allCases.map(\.rawValue),
                       ["auto", "apple_live"])
        // A hand-edited config naming an unbuilt engine reads as `auto` rather
        // than being offered back to the user as a working choice.
        XCTAssertEqual(WindowSettings.EngineOption.parse("mlx_whisper"), .auto)
        XCTAssertEqual(WindowSettings.EngineOption.parse("apple_live"), .appleLive)
    }

    func testTheHistoryLimitMenuSnapsAHandEditedValueToAnOfferedOne() {
        XCTAssertEqual(WindowSettings.clampHistoryLimit(1000), 1000)
        XCTAssertEqual(WindowSettings.clampHistoryLimit(900), 1000)
        XCTAssertEqual(WindowSettings.clampHistoryLimit(1), 100)
        XCTAssertEqual(WindowSettings.clampHistoryLimit(99999), 5000)
    }

    func testTheNewNumericRangesClampRatherThanReject() {
        XCTAssertEqual(WindowSettings.clampAiCleanupMaxWords(0), 100)
        XCTAssertEqual(WindowSettings.clampAiCleanupMaxWords(99999), 1000)
        XCTAssertEqual(WindowSettings.clampAiCleanupTimeout(0), 4000)
        XCTAssertEqual(WindowSettings.clampAiCleanupTimeout(99999), 30000)
        XCTAssertEqual(WindowSettings.clampFinalizeTimeout(0), 500)
        XCTAssertEqual(WindowSettings.clampFinalizeTimeout(99999), 5000)
        XCTAssertEqual(WindowSettings.clampKeyupGrace(-1), 0)
        XCTAssertEqual(WindowSettings.clampKeyupGrace(120), 120)
        XCTAssertEqual(WindowSettings.clampKeyupGrace(500), 500)
        XCTAssertEqual(WindowSettings.clampKeyupGrace(501), 500)
        XCTAssertEqual(WindowSettings.keyupGraceDefault, KeyupGraceSettings.defaultMs)
    }

    func testInputDevicePolicyFallsBackToWarn() {
        XCTAssertEqual(WindowSettings.InputDevicePolicyOption.allCases.map(\.rawValue),
                       ["warn", "prefer_builtin", "off"])
        XCTAssertEqual(WindowSettings.InputDevicePolicyOption.parse("prefer_builtin"),
                       .preferBuiltin)
        XCTAssertEqual(WindowSettings.InputDevicePolicyOption.parse("nonsense"), .warn)
        XCTAssertEqual(WindowSettings.InputDevicePolicyOption.warn.label, "Warn once")
        XCTAssertEqual(WindowSettings.InputDevicePolicyOption.preferBuiltin.label,
                       "Prefer built-in mic")
        XCTAssertEqual(WindowSettings.InputDevicePolicyOption.off.label, "Do nothing")
    }

    func testSelectionPolicyFallsBackToWarm() {
        XCTAssertEqual(WindowSettings.SelectionPolicyOption.parse("per_utterance"),
                       .perUtterance)
        XCTAssertEqual(WindowSettings.SelectionPolicyOption.parse("nonsense"), .warm)
    }
}

/// The pages the Settings page can now write, driven through the model against
/// a real temp config file.
@MainActor
final class SettingsPageWriteTests: XCTestCase {

    private var root: URL!
    private var settings: Settings!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wisprit-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        settings = Settings(path: root.appendingPathComponent("config.json"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeModel() -> WispritWindowModel {
        WispritWindowModel(settings: settings,
                           dictionary: DictionaryEditor(store: DictionaryStore(
                               path: root.appendingPathComponent("dictionary.json"))))
    }

    func testEveryNewSurfaceWritesItsExistingKey() {
        let model = makeModel()

        model.setLocale("en-GB")
        model.setEnsureSentencePeriod(true)
        model.setAiCleanupMaxWords(500)
        model.setAiCleanupTimeoutMs(9000)
        model.setImSelectionPolicy(.perUtterance)
        model.setHistoryLimit(500)
        model.setFinalizeTimeoutMs(2000)
        model.setEngine(.appleLive)
        model.setTerminalBundleIDs(["com.apple.Terminal"])

        let reread = Settings(path: settings.configPath)
        XCTAssertEqual(reread.locale, "en-GB")
        XCTAssertTrue(reread.ensureSentencePeriod)
        XCTAssertEqual(reread.aiCleanupMaxWords, 500)
        XCTAssertEqual(reread.aiCleanupTimeoutMs, 9000)
        XCTAssertEqual(reread.string(SettingsKey.imSelectionPolicy), "per_utterance")
        XCTAssertEqual(reread.historyLimit, 500)
        XCTAssertEqual(reread.finalizeTimeoutMs, 2000)
        XCTAssertEqual(reread.engine, "apple_live")
        XCTAssertEqual(reread.terminalBundleIDs, ["com.apple.Terminal"])
    }

    /// `keyup_grace_ms`, `input_device_policy`, `vocabulary_retro` live outside
    /// `Settings.defaults` (the `ContextSettings` string-key precedent). A
    /// visit to Settings still has to write them.
    func testStringKeyedEngineFeatureKeysWriteThrough() {
        let model = makeModel()
        XCTAssertEqual(model.keyupGraceMs, KeyupGraceSettings.defaultMs)
        XCTAssertEqual(model.inputDevicePolicy, .warn)
        XCTAssertTrue(model.vocabularyRetro)

        model.setKeyupGraceMs(200)
        model.setInputDevicePolicy(.off)
        model.setVocabularyRetro(false)

        let reread = Settings(path: settings.configPath)
        XCTAssertEqual(reread.int(KeyupGraceSettings.key), 200)
        XCTAssertEqual(reread.string(InputDevicePolicySettings.key), "off")
        XCTAssertFalse(VocabularyRetroSettings.isEnabled(reread))
        XCTAssertFalse(Set(Settings.defaults.keys).contains(KeyupGraceSettings.key))
        XCTAssertFalse(Set(Settings.defaults.keys).contains(InputDevicePolicySettings.key))
        XCTAssertFalse(Set(Settings.defaults.keys).contains(VocabularyRetroSettings.enabledKey))
    }

    /// The bundle-id list is free text. Blank entries and duplicates are dropped
    /// before the write, not after: the insertion ladder reads this list on
    /// every utterance.
    func testTheTerminalListRefusesBlanksAndDuplicates() {
        let model = makeModel()
        model.setTerminalBundleIDs(["com.apple.Terminal", "  ", "com.apple.Terminal",
                                    " io.alacritty "])
        XCTAssertEqual(model.terminalBundleIDs, ["com.apple.Terminal", "io.alacritty"])
    }

    /// "Reset its position" is disabled until the pill has actually been
    /// dragged, and writing `null` is what `Pill.restorePosition` reads as "no
    /// saved position".
    func testResettingThePillPositionWritesNull() {
        let model = makeModel()
        XCTAssertFalse(model.hasPillPosition)

        settings.setPillPosition(x: 100, y: 200)
        model.reloadSettings()
        XCTAssertTrue(model.hasPillPosition)

        model.resetPillPosition()
        XCTAssertFalse(model.hasPillPosition)
        XCTAssertNil(Settings(path: settings.configPath).pillPosition)
    }

    func testTheProbeTimestampIsWhatTheSetupFooterReads() async {
        let model = makeModel()
        XCTAssertNil(model.lastProbeAt, "nothing has been checked yet")
        await model.refreshFull()
        XCTAssertNotNil(model.lastProbeAt)
    }
}
