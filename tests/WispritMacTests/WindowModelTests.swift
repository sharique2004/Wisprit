import XCTest
import WispritDictionary
import WispritIMProtocol
import WispritKit
import WispritPersistence
@testable import WispritMac

/// The window's state model, driven by fake probes and a temp config file.
///
/// No AppKit, no TCC, no `~/.wisprit`: `Ports` is the only way the model reaches
/// the system, so every transition here is reproducible.
@MainActor
final class WindowModelTests: XCTestCase {

    private var root: URL!
    private var settings: Settings!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wisprit-window-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        settings = Settings(path: root.appendingPathComponent("config.json"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func facts(accessibility: Bool = true,
                       inputMonitoring: String = "granted",
                       microphone: String = "granted",
                       speech: Bool = true) -> DoctorFacts {
        var facts = DoctorFacts()
        facts.accessibility = accessibility
        facts.inputMonitoring = inputMonitoring
        facts.postEventAccess = true
        facts.microphone = microphone
        facts.speechOK = speech
        facts.aiAvailable = true
        facts.imStaged = true
        facts.imStatus = InputMethodStatus(bundleInstalled: true, registered: true,
                                           enabled: true, selected: true,
                                           installedVersion: "2.0.0-dev",
                                           stagedVersion: "2.0.0-dev")
        facts.imReachable = true
        facts.liveTypingEnabled = true
        return facts
    }

    private func makeModel(facts probed: DoctorFacts? = nil,
                           globe: GlobeKeyUsage = .doNothing,
                           recents: [HistoryEntry] = [],
                           onFix: @escaping (SetupFixKind) -> Void = { _ in })
        -> WispritWindowModel {
        let store = DictionaryStore(path: root.appendingPathComponent("dictionary.json"))
        let snapshot = probed ?? facts()
        return WispritWindowModel(
            settings: settings,
            dictionary: DictionaryEditor(store: store),
            ports: WispritWindowModel.Ports(
                fullProbe: { snapshot },
                fastProbe: { $0 },
                globeKey: { globe },
                recents: { limit in Array(recents.prefix(limit)) },
                copy: { _ in },
                performFix: onFix))
    }

    // MARK: - probing

    func testHeroStaysCheckingUntilTheFirstProbeLands() async {
        let model = makeModel()
        XCTAssertEqual(model.summary.hero, .checking)
        XCTAssertFalse(model.hasProbed)

        await model.refreshFull()

        XCTAssertTrue(model.hasProbed)
        XCTAssertEqual(model.summary.hero, .ready)
        XCTAssertEqual(model.items.count, 7)
    }

    func testABrokenGrantMakesTheHeroSayNeedsSetup() async {
        let model = makeModel(facts: facts(accessibility: false, microphone: "denied"))
        await model.refreshFull()

        XCTAssertEqual(model.summary.hero, .needsSetup(blocking: 2))
        XCTAssertEqual(model.items.first { $0.id == SetupChecklist.accessibilityID }?.fix,
                       .openAccessibilitySettings)
    }

    /// The 2-second tick is the reason a grant flipped in System Settings shows
    /// up without reopening the window.
    func testTheFastProbeRepublishesTheChecklist() async {
        let missing = facts(accessibility: false)
        let model = WispritWindowModel(
            settings: settings,
            dictionary: DictionaryEditor(store: DictionaryStore(
                path: root.appendingPathComponent("dictionary.json"))),
            ports: WispritWindowModel.Ports(
                fullProbe: { missing },
                fastProbe: { base in
                    // What `Doctor.refreshingPermissions` does after the user
                    // flips the toggle in System Settings: same snapshot, one
                    // permission re-read.
                    var granted = base
                    granted.accessibility = true
                    return granted
                }))
        await model.refreshFull()
        XCTAssertEqual(model.summary.hero, .needsSetup(blocking: 1))

        model.refreshFast()

        XCTAssertEqual(model.summary.hero, .ready)
    }

    func testTheFastProbeIsInertBeforeTheFirstFullProbe() {
        let counter = ProbeCounter()
        let model = WispritWindowModel(
            settings: settings,
            dictionary: DictionaryEditor(store: DictionaryStore(
                path: root.appendingPathComponent("dictionary.json"))),
            ports: WispritWindowModel.Ports(fastProbe: { counter.bump(); return $0 }))
        model.refreshFast()
        XCTAssertEqual(counter.count, 0, "there is nothing to patch yet")
    }

    // MARK: - fixes

    func testFixIsRoutedToThePortAndNoopsWhenThereIsNothingToDo() async {
        let box = FixBox()
        let model = makeModel(onFix: { box.record($0) })

        model.fix(.none)
        XCTAssertTrue(box.kinds.isEmpty, "a green row's button never fires anything")

        model.fix(.requestInputMonitoring)
        XCTAssertEqual(box.kinds, [.requestInputMonitoring])
    }

    // MARK: - settings

    func testSettingsWritesLandInTheConfigFile() {
        let model = makeModel()

        model.setHotkey(.rightOption)
        model.setLeadingSpace(.never)
        model.setAiCleanup(false)
        model.setPillHidden(true)
        model.setFillerRemoval(false)
        model.setHistoryEnabled(false)
        model.setLiveTypingEnabled(true)
        model.setDictationEnabled(false)

        let reread = Settings(path: settings.configPath)
        XCTAssertEqual(reread.hotkey, "right_option")
        XCTAssertEqual(reread.leadingSpace, "never")
        XCTAssertFalse(reread.aiCleanup)
        XCTAssertTrue(reread.pillHidden)
        XCTAssertFalse(reread.fillerRemoval)
        XCTAssertFalse(reread.historyEnabled)
        XCTAssertTrue(reread.bool(SettingsKey.liveTyping, or: false))
        XCTAssertFalse(reread.enabled)
    }

    func testStepperValuesAreClampedBeforeTheyReachDisk() {
        let model = makeModel()

        model.setHoldDebounceMs(99_999)
        model.setPasteRestoreDelayMs(0)

        XCTAssertEqual(model.holdDebounceMs, WindowSettings.holdDebounceRange.upperBound)
        XCTAssertEqual(model.pasteRestoreDelayMs, WindowSettings.pasteRestoreRange.lowerBound)
        let reread = Settings(path: settings.configPath)
        XCTAssertEqual(reread.holdDebounceMs, WindowSettings.holdDebounceRange.upperBound)
        XCTAssertEqual(reread.pasteRestoreDelayMs, WindowSettings.pasteRestoreRange.lowerBound)
    }

    /// The Live Typing row reads the setting through `DoctorFacts`, which only a
    /// full probe refills — so flipping the switch has to patch the snapshot, or
    /// the Status row keeps saying "off" for up to sixteen seconds after the
    /// user turned it on.
    func testTurningLiveTypingOnClearsTheOffRowWithoutWaitingForAProbe() async {
        var off = facts()
        off.liveTypingEnabled = false          // the shipping default
        let model = makeModel(facts: off)
        await model.refreshFull()
        XCTAssertTrue(model.items.first { $0.id == SetupChecklist.liveTypingID }?.isOff ?? false)

        model.setLiveTypingEnabled(true)

        let row = model.items.first { $0.id == SetupChecklist.liveTypingID }
        XCTAssertFalse(row?.isOff ?? true)
        XCTAssertTrue(row?.isSatisfied ?? false)
    }

    /// Secure Keyboard Entry is the state where a fully green checklist still
    /// cannot dictate, so the window says so — and says nothing before the first
    /// probe, when it has no idea either way.
    func testSecureInputIsAnnouncedOnlyOnceAProbeHasSeenIt() async {
        var held = facts()
        held.secureInputActive = true
        let model = makeModel(facts: held)
        XCTAssertNil(model.secureInputNotice, "nothing has been probed yet")

        await model.refreshFull()

        XCTAssertNotNil(model.secureInputNotice)
        XCTAssertTrue(model.secureInputNotice?.contains("password field") ?? false)
    }

    func testChangingTheHotkeyRewordsTheHeroImmediately() async {
        let model = makeModel()
        await model.refreshFull()
        XCTAssertEqual(model.summary.headline, "Ready — hold 🌐 to dictate")

        model.setHotkey(.rightOption)

        XCTAssertEqual(model.summary.headline, "Ready — hold the right ⌥ key to dictate")
    }

    func testTheSettingsTabAddsNoNewConfigKeys() {
        let known = Set(Settings.defaults.keys)
        for key in WindowSettings.writtenKeys {
            XCTAssertTrue(known.contains(key),
                          "\(key) would be a new key — the tab may only write existing ones")
        }
    }

    func testAHandEditedConfigIsRereadNotOverwritten() throws {
        try "{\"hotkey\": \"right_option\", \"hold_debounce_ms\": 275}\n"
            .write(to: settings.configPath, atomically: true, encoding: .utf8)
        let model = makeModel()

        model.reloadSettings()

        XCTAssertEqual(model.hotkey, .rightOption)
        XCTAssertEqual(model.holdDebounceMs, 275)
    }

    // MARK: - history + dictation proof

    func testRecentsFeedTheTryItProof() {
        let now = Date().timeIntervalSince1970
        let model = makeModel(recents: [
            HistoryEntry(id: 2, ts: now, text: "hello there", engine: "apple_live", durationMs: 320),
        ])
        model.windowDidOpen()
        model.stopPolling()

        // The baseline is the newest entry at open, so an already-present
        // transcript is not mistaken for one the user just spoke.
        XCTAssertFalse(model.didDictate)
        XCTAssertEqual(model.recents.count, 1)

        model.noteDictationObserved()
        XCTAssertTrue(model.didDictate)
    }

    // MARK: - onboarding

    func testFirstRunAutoOpensAndResolvesToTheFirstMissingThing() async {
        let model = makeModel(facts: facts(accessibility: false))
        await model.refreshFull()

        XCTAssertTrue(model.shouldAutoOpenWindow, "onboarding_completed is unset")
        model.beginOnboarding()
        XCTAssertTrue(model.isOnboarding)
        XCTAssertEqual(model.onboardingStep, .welcome)

        model.acknowledgeWelcome()
        XCTAssertEqual(model.onboardingStep, .accessibility,
                       "mic and Input Monitoring are already granted")
    }

    func testFinishingPersistsCompletionSoTheNextLaunchStaysQuiet() async {
        let model = makeModel()
        await model.refreshFull()
        model.beginOnboarding()
        model.finishOnboarding()

        XCTAssertFalse(model.isOnboarding)
        XCTAssertFalse(model.shouldAutoOpenWindow)
        let reread = Settings(path: settings.configPath)
        XCTAssertTrue(reread.bool(OnboardingSettings.completedKey, or: false))
    }

    func testClosingWithoutFinishingResumesWhereTheUserStopped() async {
        let model = makeModel(facts: facts(accessibility: false))
        await model.refreshFull()
        model.beginOnboarding()
        model.goToStep(.accessibility)
        model.dismissOnboarding()

        XCTAssertFalse(model.isOnboarding)
        XCTAssertTrue(model.shouldAutoOpenWindow, "still not completed")

        model.beginOnboarding()
        XCTAssertEqual(model.onboardingStep, .accessibility)
    }

    func testTheWizardNeverJumpsBackwards() async {
        let model = makeModel(facts: facts(accessibility: false), globe: .showEmoji)
        await model.refreshFull()
        model.beginOnboarding()
        model.goToStep(.liveTyping)

        await model.refreshFull()   // accessibility is still missing

        XCTAssertEqual(model.onboardingStep, .liveTyping,
                       "a late probe must not yank the user back mid-page")
    }

    func testOnboardingClosesItselfOnceEverythingIsSatisfied() async {
        let model = makeModel()
        await model.refreshFull()
        model.beginOnboarding()
        model.acknowledgeWelcome()
        model.noteDictationObserved()

        XCTAssertFalse(model.isOnboarding, "nothing left to ask about")
        XCTAssertTrue(Settings(path: settings.configPath)
            .bool(OnboardingSettings.completedKey, or: false))
    }

    // MARK: - dictionary tab

    func testDictionaryEditsRepublishAndFilter() {
        let model = makeModel()
        model.saveTerm(original: nil, term: "InsForge", hear: ["in forge"])
        model.saveTerm(original: nil, term: "Sharique", hear: ["Cherie"])

        XCTAssertEqual(model.dictionaryRows.map(\.term), ["InsForge", "Sharique"])

        model.dictionarySearch = "cherie"
        XCTAssertEqual(model.filteredDictionaryRows.map(\.term), ["Sharique"])

        model.dictionarySearch = ""
        model.deleteTerm("InsForge")
        XCTAssertEqual(model.dictionaryRows.map(\.term), ["Sharique"])
    }
}

/// Main-actor-isolated recorder; `Ports.performFix` is not `Sendable`, so a
/// plain captured var would need an escape hatch.
@MainActor
private final class FixBox {
    private(set) var kinds: [SetupFixKind] = []
    func record(_ kind: SetupFixKind) { kinds.append(kind) }
}

/// `Ports.fastProbe` is `@Sendable`, so the call counter has to be one too.
private final class ProbeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func bump() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

/// `Wisprit window …` argument parsing — the spelling users type is pinned here
/// rather than in a bare string comparison inside `main`.
final class WindowLaunchArgumentTests: XCTestCase {

    func testBareWindowOpensTheStatusPage() {
        XCTAssertEqual(WispritMacMain.WindowLaunch.parse([]), .page(.status))
        XCTAssertEqual(WispritMacMain.WindowLaunch.parse([""]), .page(.status))
    }

    func testEveryTabIsAddressableByItsOwnName() {
        for tab in WispritWindowModel.Tab.allCases {
            XCTAssertEqual(WispritMacMain.WindowLaunch.parse([tab.rawValue]), .page(tab))
            XCTAssertEqual(WispritMacMain.WindowLaunch.parse([tab.rawValue.uppercased()]),
                           .page(tab))
        }
    }

    func testTheSetupGuideHasThreeObviousSpellings() {
        for name in ["setup", "onboarding", "guide"] {
            XCTAssertEqual(WispritMacMain.WindowLaunch.parse([name]), .setupGuide)
        }
    }

    func testAnUnknownPageFallsBackToStatusRatherThanFailing() {
        XCTAssertEqual(WispritMacMain.WindowLaunch.parse(["nonsense"]), .page(.status))
    }
}
