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

    /// Everything the window polls now runs on a detached task and publishes
    /// back on the main actor, so a synchronous assert straight after the call
    /// would race it.
    private func settle(_ condition: @MainActor () -> Bool) async {
        var attempts = 0
        while !condition(), attempts < 300 {
            attempts += 1
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
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

        await model.refreshFast()

        XCTAssertEqual(model.summary.hero, .ready)
    }

    func testTheFastProbeIsInertBeforeTheFirstFullProbe() async {
        let counter = ProbeCounter()
        let model = WispritWindowModel(
            settings: settings,
            dictionary: DictionaryEditor(store: DictionaryStore(
                path: root.appendingPathComponent("dictionary.json"))),
            ports: WispritWindowModel.Ports(fastProbe: { counter.bump(); return $0 }))
        await model.refreshFast()
        XCTAssertEqual(counter.count, 0, "there is nothing to patch yet")
    }

    /// The window must add no main-thread work while the key is held: the hotkey
    /// tap, the pill and the live-typing stream all run there, and the Try-it
    /// card asks the user to dictate with this window open.
    func testTheTimerStopsForTheDurationOfADictation() async {
        let model = makeModel()
        await model.refreshFull()
        model.windowDidOpen()
        XCTAssertTrue(model.isPolling)

        model.noteSessionState(.recording)
        XCTAssertFalse(model.isPolling, "nothing polls while the key is down")

        model.noteSessionState(.finalizing)
        XCTAssertFalse(model.isPolling)

        model.noteSessionState(.idle)
        XCTAssertTrue(model.isPolling, "and it comes back on its own")
        model.stopPolling()
    }

    /// A closed window has nothing to keep up to date, so the end of a dictation
    /// must not quietly restart the timer behind it.
    func testAClosedWindowDoesNotResumePollingAfterADictation() async {
        let model = makeModel()
        await model.refreshFull()
        model.windowDidOpen()
        model.noteSessionState(.recording)
        model.windowDidClose()

        model.noteSessionState(.idle)

        XCTAssertFalse(model.isPolling)
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
        model.setKeyupGraceMs(80)
        model.setInputDevicePolicy(.preferBuiltin)
        model.setVocabularyRetro(false)

        let reread = Settings(path: settings.configPath)
        XCTAssertEqual(reread.hotkey, "right_option")
        XCTAssertEqual(reread.leadingSpace, "never")
        XCTAssertFalse(reread.aiCleanup)
        XCTAssertTrue(reread.pillHidden)
        XCTAssertFalse(reread.fillerRemoval)
        XCTAssertFalse(reread.historyEnabled)
        XCTAssertTrue(reread.bool(SettingsKey.liveTyping, or: false))
        XCTAssertFalse(reread.enabled)
        XCTAssertEqual(reread.int(KeyupGraceSettings.key), 80)
        XCTAssertEqual(reread.string(InputDevicePolicySettings.key), "prefer_builtin")
        XCTAssertFalse(VocabularyRetroSettings.isEnabled(reread))
    }

    func testStepperValuesAreClampedBeforeTheyReachDisk() {
        let model = makeModel()

        model.setHoldDebounceMs(99_999)
        model.setPasteRestoreDelayMs(0)
        model.setKeyupGraceMs(999)

        XCTAssertEqual(model.holdDebounceMs, WindowSettings.holdDebounceRange.upperBound)
        XCTAssertEqual(model.pasteRestoreDelayMs, WindowSettings.pasteRestoreRange.lowerBound)
        XCTAssertEqual(model.keyupGraceMs, WindowSettings.keyupGraceRange.upperBound)
        let reread = Settings(path: settings.configPath)
        XCTAssertEqual(reread.holdDebounceMs, WindowSettings.holdDebounceRange.upperBound)
        XCTAssertEqual(reread.pasteRestoreDelayMs, WindowSettings.pasteRestoreRange.lowerBound)
        XCTAssertEqual(reread.int(KeyupGraceSettings.key), WindowSettings.keyupGraceRange.upperBound)
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
        XCTAssertEqual(model.keyupGraceMs, WindowSettings.keyupGraceDefault)
        XCTAssertEqual(model.inputDevicePolicy, .warn)
        XCTAssertTrue(model.vocabularyRetro)
    }

    func testStringKeyedEngineFeatureKeysReloadFromAHandEditedFile() throws {
        try """
            {"keyup_grace_ms": 40, "input_device_policy": "off", "vocabulary_retro": false}
            """.write(to: settings.configPath, atomically: true, encoding: .utf8)
        let model = makeModel()

        model.reloadSettings()

        XCTAssertEqual(model.keyupGraceMs, 40)
        XCTAssertEqual(model.inputDevicePolicy, .off)
        XCTAssertFalse(model.vocabularyRetro)
    }

    // MARK: - history + dictation proof

    func testRecentsFeedTheTryItProof() async {
        let now = Date().timeIntervalSince1970
        let model = makeModel(recents: [
            HistoryEntry(id: 2, ts: now, text: "hello there", engine: "apple_live", durationMs: 320),
        ])
        model.windowDidOpen()
        model.stopPolling()
        await settle { model.recents.count == 1 }

        // The baseline is the newest entry at open, so an already-present
        // transcript is not mistaken for one the user just spoke.
        XCTAssertFalse(model.didDictate)
        XCTAssertEqual(model.recents.count, 1)

        model.noteDictationObserved()
        XCTAssertTrue(model.didDictate)
    }

    /// Reopening the window used to wipe the green "Dictation is working." line
    /// while the transcript that proved it was still listed underneath — and it
    /// silently un-proved the wizard's try-it step with it.
    func testReopeningTheWindowKeepsAProvenDictationProven() async {
        let model = makeModel()
        model.windowDidOpen()
        model.stopPolling()
        model.noteDictationObserved()
        XCTAssertTrue(model.didDictate)

        model.windowDidClose()
        model.windowDidOpen()
        model.stopPolling()

        XCTAssertTrue(model.didDictate, "closing a window does not un-prove anything")
    }

    /// Re-running the setup guide from the top IS a request to see it work
    /// again, so that one does re-arm the proof.
    func testRerunningTheSetupGuideAsksForAFreshDictation() async {
        let model = makeModel()
        await model.refreshFull()
        model.windowDidOpen()
        model.stopPolling()
        model.noteDictationObserved()

        model.beginOnboarding(resuming: false)

        XCTAssertFalse(model.didDictate)
        XCTAssertEqual(model.onboardingStep, .welcome)
    }

    // MARK: - the History page

    /// The page called "History" showed twenty rows while Purge deleted every
    /// one of the thousand the store keeps.
    func testHistoryPagesInsteadOfSilentlyStoppingAtThePreviewLimit() async {
        let rows = (0..<120).map {
            HistoryEntry(id: Int64(120 - $0), ts: Double(120 - $0),
                         text: "line \($0)", engine: "apple_live", durationMs: nil)
        }
        let model = makeModel(recents: rows)
        model.refreshRecents()
        model.loadHistory(reset: true)
        await settle { model.history.count == WispritWindowModel.historyPageSize }

        XCTAssertEqual(model.history.count, WispritWindowModel.historyPageSize)
        XCTAssertTrue(model.historyHasMore)
        await settle { model.recents.count == WispritWindowModel.recentsPreviewLimit }
        XCTAssertEqual(model.recents.count, WispritWindowModel.recentsPreviewLimit,
                       "the Status preview keeps its own, much smaller limit")

        model.loadMoreHistory()
        await settle { model.history.count == WispritWindowModel.historyPageSize * 2 }
        XCTAssertEqual(model.history.count, WispritWindowModel.historyPageSize * 2)

        model.loadMoreHistory()
        await settle { model.history.count == 120 }
        XCTAssertEqual(model.history.count, 120)
        XCTAssertFalse(model.historyHasMore, "the list ended because the history did")
    }

    /// "This cannot be undone" is fine; "20 entries" when it deletes 1000 is not.
    func testThePurgeWarningNeverClaimsACountItCannotSee() async {
        let rows = (0..<120).map {
            HistoryEntry(id: Int64(120 - $0), ts: Double(120 - $0),
                         text: "line \($0)", engine: "apple_live", durationMs: nil)
        }
        let model = makeModel(recents: rows)
        model.loadHistory(reset: true)
        await settle { model.history.count == WispritWindowModel.historyPageSize }

        XCTAssertTrue(model.historyDeletionWarning.contains("older than the 50 listed here"))
        XCTAssertFalse(model.historyDeletionWarning.contains("All 50"))

        model.loadMoreHistory()
        await settle { model.history.count == WispritWindowModel.historyPageSize * 2 }
        model.loadMoreHistory()
        await settle { model.history.count == 120 }
        XCTAssertTrue(model.historyDeletionWarning.contains("All 120 saved transcripts"))
    }

    /// The ladder already knows which apps refuse live text; the window has to
    /// stop promising streaming everywhere.
    func testTheLiveTypingFallbackListReachesTheWindow() async {
        let store = DictionaryStore(path: root.appendingPathComponent("dictionary.json"))
        let model = WispritWindowModel(
            settings: settings,
            dictionary: DictionaryEditor(store: store),
            ports: WispritWindowModel.Ports(
                fullProbe: { [snapshot = facts()] in snapshot },
                liveTypingFallbacks: {
                    [BundleVerdict(bundleID: "com.apple.Terminal", tier: .unsupported)]
                }))

        await model.refreshFull()

        XCTAssertEqual(model.liveTypingFallbacks.map(\.displayName), ["Terminal"])
        XCTAssertEqual(model.liveTypingFallbacks.first?.behaviour,
                       "pastes the finished text at the end")
        XCTAssertTrue(model.items.first { $0.id == SetupChecklist.liveTypingID }?
            .summary.contains("quietly pastes at the end") ?? false)
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
        XCTAssertEqual(model.onboardingStep, .micTest,
                       "the grant is green, but nothing has proved the input carries sound")

        model.noteMicTestPassed()
        XCTAssertEqual(model.onboardingStep, .accessibility,
                       "mic, the mic test, 🌐 and Input Monitoring are all settled")
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

    /// The wizard used to dismiss itself on the first tick where everything was
    /// satisfied, so an already-healthy machine got a panel that appeared and
    /// vanished — no "you're set up" anywhere, which reads as a glitch to
    /// exactly the audience this was built for.
    func testOnboardingLandsOnACompletionPageRatherThanVanishing() async {
        let model = makeModel()
        await model.refreshFull()
        model.beginOnboarding()
        model.acknowledgeWelcome()
        model.noteMicTestPassed()
        model.noteDictationObserved()

        XCTAssertTrue(model.isOnboarding, "the user has not seen a finish line yet")
        XCTAssertEqual(model.onboardingStep, OnboardingStep.allCases.last)
        XCTAssertTrue(model.isOnboardingComplete)
        XCTAssertFalse(Settings(path: settings.configPath)
            .bool(OnboardingSettings.completedKey, or: false),
                       "completion is what the Finish button writes, not a probe")

        model.finishOnboarding()

        XCTAssertFalse(model.isOnboarding)
        XCTAssertTrue(Settings(path: settings.configPath)
            .bool(OnboardingSettings.completedKey, or: false))
    }

    // MARK: - time-to-wow (R14)

    /// Capture box for the ports fired from the main actor.
    private final class PortRecorder: @unchecked Sendable {
        var onboardingRows: [(ms: Double, skipped: Int, relaunches: Int)] = []
        var purgedHistory = 0
        var purgedStores: [DataStoreID] = []
    }

    /// One row, once, on the first dictation of a fresh install — the delta
    /// from the very first launch, with the skips and relaunches that happened
    /// on the way (both persisted across the mandatory mid-onboarding
    /// relaunch, which is the cost the row measures).
    func testTimeToWowWritesOneRowOnTheFirstDictationEver() {
        let recorder = PortRecorder()
        func launch() -> WispritWindowModel {
            WispritWindowModel(
                settings: settings,
                dictionary: DictionaryEditor(
                    store: DictionaryStore(path: root.appendingPathComponent("dictionary.json"))),
                ports: WispritWindowModel.Ports(
                    writeOnboardingRow: { ms, skipped, relaunches in
                        recorder.onboardingRows.append((ms, skipped, relaunches))
                    }))
        }

        // Launch 1: the clock starts; the user skips two steps and quits.
        let first = launch()
        XCTAssertNotNil(settings.double(OnboardingSettings.firstLaunchKey))
        first.skipStep()
        first.skipStep()

        // Launch 2 (the Input Monitoring relaunch): the first dictation lands.
        let second = launch()
        XCTAssertEqual(settings.int(OnboardingSettings.relaunchCountKey, or: 0), 1)
        XCTAssertTrue(recorder.onboardingRows.isEmpty, "no dictation, no row")
        second.noteDictationObserved()

        XCTAssertEqual(recorder.onboardingRows.count, 1)
        XCTAssertEqual(recorder.onboardingRows[0].skipped, 2)
        XCTAssertEqual(recorder.onboardingRows[0].relaunches, 1)
        XCTAssertGreaterThanOrEqual(recorder.onboardingRows[0].ms, 0)

        // Once means once: another dictation, another relaunch — nothing.
        second.noteDictationObserved()
        let third = launch()
        third.noteDictationObserved()
        XCTAssertEqual(recorder.onboardingRows.count, 1)
        XCTAssertEqual(settings.int(OnboardingSettings.relaunchCountKey, or: 0), 1,
                       "the counters go quiet once the row is written")
    }

    /// An install that finished onboarding before the clock existed must never
    /// write a row — a delta measured from "whenever this build first ran" on
    /// a years-old install would be a lie with four digits.
    func testAnAlreadyOnboardedInstallNeverStartsTheClock() {
        settings.set(OnboardingSettings.completedKey, true)
        let recorder = PortRecorder()
        let model = WispritWindowModel(
            settings: settings,
            dictionary: DictionaryEditor(
                store: DictionaryStore(path: root.appendingPathComponent("dictionary.json"))),
            ports: WispritWindowModel.Ports(
                writeOnboardingRow: { ms, skipped, relaunches in
                    recorder.onboardingRows.append((ms, skipped, relaunches))
                }))
        XCTAssertNil(settings.double(OnboardingSettings.firstLaunchKey))
        model.noteDictationObserved()
        XCTAssertTrue(recorder.onboardingRows.isEmpty)
    }

    // MARK: - the data inventory (R17)

    private func makeInventoryModel(_ recorder: PortRecorder,
                                    stores: [DataStoreStatus] = []) -> WispritWindowModel {
        WispritWindowModel(
            settings: settings,
            dictionary: DictionaryEditor(
                store: DictionaryStore(path: root.appendingPathComponent("dictionary.json"))),
            ports: WispritWindowModel.Ports(
                purgeHistory: { recorder.purgedHistory += 1 },
                dataStores: { stores },
                purgeDataStore: { recorder.purgedStores.append($0) }))
    }

    func testTheInventoryPublishesWhatThePortReports() async {
        let row = DataStoreStatus(id: .metrics, title: "Usage metrics",
                                  summary: "timings", byteSize: 42,
                                  exists: true, deletable: true)
        let model = makeInventoryModel(PortRecorder(), stores: [row])
        XCTAssertTrue(model.dataStores.isEmpty, "nothing until asked")
        model.refreshDataInventory()
        await settle { model.dataStores == [row] }
        XCTAssertEqual(model.dataStores, [row])
    }

    /// Transcripts go through the history store's own purge (a live SQLite
    /// handle is not a file to unlink); settings never go anywhere; the rest
    /// is the app's file purge. Delete-everything is exactly the union — the
    /// one purge that reaches every store.
    func testPurgeRoutingAndTheOnePurgeThatReachesEveryStore() {
        let recorder = PortRecorder()
        let model = makeInventoryModel(recorder)

        model.purgeDataStore(.transcripts)
        XCTAssertEqual(recorder.purgedHistory, 1)
        XCTAssertTrue(recorder.purgedStores.isEmpty)

        model.purgeDataStore(.metrics)
        XCTAssertEqual(recorder.purgedStores, [.metrics])

        model.purgeDataStore(.settings)
        XCTAssertEqual(recorder.purgedStores, [.metrics], "settings are untouchable here")
        XCTAssertEqual(recorder.purgedHistory, 1)

        recorder.purgedStores = []
        recorder.purgedHistory = 0
        model.purgeAllData()
        XCTAssertEqual(recorder.purgedHistory, 1)
        XCTAssertEqual(Set(recorder.purgedStores),
                       Set(DataInventory.deletableClasses).subtracting([.transcripts]))
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

    // MARK: - learn proposals (Phase 5)

    /// The proposal surface end to end at the model level: the port's list is
    /// republished, the badge tracks it, Accept routes through the accept port
    /// and refreshes, Dismiss routes through the dismiss port. The store-side
    /// truths (threshold, dismissal-forever) are pinned in
    /// `PendingLearnStoreTests` and `SessionEditCaptureTests`.
    func testLearnProposalsPublishBadgeAndRouteTheDecisions() {
        let ledger = ProposalLedger()
        ledger.pending = [WispritWindowModel.LearnProposalRow(
            term: "Sharique", heard: ["Shariq"], count: 2)]
        let store = DictionaryStore(path: root.appendingPathComponent("dictionary.json"))
        let model = WispritWindowModel(
            settings: settings,
            dictionary: DictionaryEditor(store: store),
            ports: WispritWindowModel.Ports(
                learnProposals: { ledger.pending },
                acceptLearnProposal: { ledger.note("accept:\($0.term)"); ledger.pending = [] },
                dismissLearnProposal: { ledger.note("dismiss:\($0)"); ledger.pending = [] }))

        model.reloadDictionary()
        XCTAssertEqual(model.learnProposals.map(\.term), ["Sharique"])
        XCTAssertEqual(model.dictionaryBadge, .attention, "a waiting decision is a visible dot")

        model.acceptLearnProposal(model.learnProposals[0])
        XCTAssertEqual(ledger.actions, ["accept:Sharique"])
        XCTAssertEqual(model.learnProposals, [], "accept refreshes the list")
        XCTAssertNil(model.dictionaryBadge, "…and the badge goes with it")

        ledger.pending = [WispritWindowModel.LearnProposalRow(term: "InsForge", count: 2)]
        model.reloadDictionary()
        model.dismissLearnProposal(model.learnProposals[0])
        XCTAssertEqual(ledger.actions, ["accept:Sharique", "dismiss:InsForge"])
        XCTAssertNil(model.dictionaryBadge)
    }

    func testTheDictionaryBadgeModelIsPure() {
        XCTAssertNil(WispritWindowModel.dictionaryBadge(proposals: 0))
        XCTAssertEqual(WispritWindowModel.dictionaryBadge(proposals: 1), .attention)
        XCTAssertEqual(WispritWindowModel.dictionaryBadge(proposals: 7), .attention)
    }
}

/// `Ports`' learn-proposal closures are `@Sendable`; the recorder has to be too.
private final class ProposalLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [WispritWindowModel.LearnProposalRow] = []
    private var recorded: [String] = []
    var pending: [WispritWindowModel.LearnProposalRow] {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
    var actions: [String] { lock.lock(); defer { lock.unlock() }; return recorded }
    func note(_ action: String) { lock.lock(); recorded.append(action); lock.unlock() }
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

    func testBareWindowOpensTheSetupPage() {
        XCTAssertEqual(WispritMacMain.WindowLaunch.parse([]), .page(.setup))
        XCTAssertEqual(WispritMacMain.WindowLaunch.parse([""]), .page(.setup))
    }

    /// `setup` is the one exception, and it predates the page of that name: it
    /// has always opened the *guide*, which itself lands on the Setup page. See
    /// `testTheSetupGuideHasThreeObviousSpellings`.
    func testEveryTabIsAddressableByItsOwnName() {
        for tab in WispritWindowModel.Tab.allCases where tab != .setup {
            XCTAssertEqual(WispritMacMain.WindowLaunch.parse([tab.rawValue]), .page(tab))
            XCTAssertEqual(WispritMacMain.WindowLaunch.parse([tab.rawValue.uppercased()]),
                           .page(tab))
        }
    }

    /// The redesign renamed two pages. Both old spellings are in shell history
    /// and in a usage string people have read, so both keep working.
    func testTheRenamedPagesKeepTheirOldSpellings() {
        XCTAssertEqual(WispritMacMain.WindowLaunch.parse(["status"]), .page(.setup))
        XCTAssertEqual(WispritMacMain.WindowLaunch.parse(["HISTORY"]), .page(.home))
    }

    func testTheSetupGuideHasThreeObviousSpellings() {
        for name in ["setup", "onboarding", "guide"] {
            XCTAssertEqual(WispritMacMain.WindowLaunch.parse([name]), .setupGuide)
        }
    }

    func testAnUnknownPageFallsBackToSetupRatherThanFailing() {
        XCTAssertEqual(WispritMacMain.WindowLaunch.parse(["nonsense"]), .page(.setup))
    }
}
