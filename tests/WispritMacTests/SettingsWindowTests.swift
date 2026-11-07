import Combine
import XCTest
import WispritDictionary
import WispritPersistence
@testable import WispritMac

/// The Settings window's pure decisions: the Language rule (the blank-picker
/// bug), what the Microphone pane says, and which changes need a restart.
final class SettingsLanguageTests: XCTestCase {

    private let english = Locale(identifier: "en_US")

    func testIdentifiersMatchAcrossSeparatorAndCase() {
        XCTAssertTrue(SettingsLanguage.matches("en-US", "en_US"))
        XCTAssertTrue(SettingsLanguage.matches("EN_us", "en-US"))
        XCTAssertTrue(SettingsLanguage.matches(" en_US ", "en-US"))
        XCTAssertTrue(SettingsLanguage.matches("zh_Hans_CN", "zh-hans-cn"))
        XCTAssertFalse(SettingsLanguage.matches("en-US", "en-GB"))
        XCTAssertFalse(SettingsLanguage.matches("en", "en-US"))
    }

    /// The bug: `config.json` says `en-US`, Speech lists `en_US`, and the
    /// picker selected nothing.
    func testTheStoredHyphenFormSelectsTheInstalledUnderscoreForm() {
        let options = SettingsLanguage.options(installed: ["en_US", "en_GB"],
                                               current: "en-US", display: english)
        let selected = SettingsLanguage.selection(current: "en-US", in: options)
        XCTAssertEqual(selected, "en-us")
        XCTAssertEqual(options.first { $0.id == selected }?.name, "English (United States)")
        XCTAssertTrue(options.allSatisfy(\.isInstalled))
        XCTAssertEqual(options.count, 2, "no phantom row for a value that is installed")
    }

    func testOptionsAreLocalizedNamesSortedByName() {
        let options = SettingsLanguage.options(installed: ["fr_FR", "en_US", "en_GB"],
                                               current: "en-US", display: english)
        XCTAssertEqual(options.map(\.name),
                       ["English (United Kingdom)", "English (United States)", "French (France)"])
    }

    /// What gets written: the hyphen form, which is what the shipped default,
    /// `wisprit eval`'s default and the eval cache key all use — and the row
    /// that matches the stored value carries the stored spelling.
    func testOptionValuesAreTheStoredFormat() {
        let options = SettingsLanguage.options(installed: ["en_US", "en_GB", "zh_Hans_CN"],
                                               current: "en-US", display: english)
        XCTAssertEqual(Set(options.map(\.value)), ["en-US", "en-GB", "zh-Hans-CN"])
        let legacy = SettingsLanguage.options(installed: ["en_US"], current: "en_US",
                                              display: english)
        XCTAssertEqual(legacy.map(\.value), ["en_US"],
                       "a hand-written underscore value is not rewritten by being shown")
    }

    func testChoosingTheStoredLanguageWritesNothing() {
        XCTAssertNil(SettingsLanguage.write(choosing: "en-US", current: "en-US"))
        XCTAssertNil(SettingsLanguage.write(choosing: "en_US", current: "en-US"))
        XCTAssertEqual(SettingsLanguage.write(choosing: "en_GB", current: "en-US"), "en-GB")
        XCTAssertEqual(SettingsLanguage.write(choosing: "zh_Hans_CN", current: "en-US"),
                       "zh-Hans-CN")
    }

    /// A stored value with no installed voice is still listed, so the picker
    /// shows what is configured instead of drawing blank.
    func testAnUninstalledStoredValueStaysListed() {
        let options = SettingsLanguage.options(installed: ["en_US"], current: "de-DE",
                                               display: english)
        XCTAssertEqual(options.count, 2)
        let selected = SettingsLanguage.selection(current: "de-DE", in: options)
        let row = options.first { $0.id == selected }
        XCTAssertEqual(row?.value, "de-DE")
        XCTAssertEqual(row?.name, "German (Germany)")
        XCTAssertEqual(row?.isInstalled, false)
    }

    func testDuplicateSpellingsCollapse() {
        let options = SettingsLanguage.options(installed: ["en_US", "en-US", "EN_us"],
                                               current: "en-US", display: english)
        XCTAssertEqual(options.count, 1)
    }

    func testNothingInstalledYetStillNamesTheSetting() {
        let options = SettingsLanguage.options(installed: [], current: "en-US", display: english)
        XCTAssertEqual(options.map(\.name), ["English (United States)"])
        XCTAssertEqual(SettingsLanguage.selection(current: "en-US", in: options), "en-us")
    }
}

final class MicrophoneCopyTests: XCTestCase {

    func testNoDeviceBeforeAndAfterTheProbe() {
        XCTAssertEqual(MicrophoneCopy.dictatingDevice(name: "", transport: "", narrowband: false,
                                                      headsetRisk: false, policy: .warn,
                                                      hasProbed: false).title, "Checking…")
        XCTAssertEqual(MicrophoneCopy.dictatingDevice(name: "", transport: "", narrowband: false,
                                                      headsetRisk: false, policy: .warn,
                                                      hasProbed: true).title, "No microphone found")
    }

    /// `prefer_builtin` pins the Mac mic only for a headset; the row has to
    /// name the mic that will actually dictate, not the system default.
    func testPreferBuiltinNamesTheMacMicWhileAHeadsetIsConnected() {
        let line = MicrophoneCopy.dictatingDevice(name: "AirPods Max", transport: "Bluetooth",
                                                  narrowband: false, headsetRisk: true,
                                                  policy: .preferBuiltin, hasProbed: true)
        XCTAssertEqual(line.title, "Mac microphone")
        XCTAssertTrue(line.help.contains("AirPods Max"))
    }

    func testHeadsetPolicyNamesTheHeadset() {
        for policy: WindowSettings.InputDevicePolicyOption in [.warn, .off] {
            let line = MicrophoneCopy.dictatingDevice(name: "AirPods Max", transport: "Bluetooth",
                                                      narrowband: true, headsetRisk: false,
                                                      policy: policy, hasProbed: true)
            XCTAssertEqual(line.title, "AirPods Max")
        }
    }

    /// A USB desk mic is never displaced, whatever the policy says.
    func testAnOrdinaryInputIsTheSystemInputUnderEveryPolicy() {
        for policy in WindowSettings.InputDevicePolicyOption.allCases {
            let line = MicrophoneCopy.dictatingDevice(name: "Yeti", transport: "USB",
                                                      narrowband: false, headsetRisk: false,
                                                      policy: policy, hasProbed: true)
            XCTAssertEqual(line.title, "Yeti")
            XCTAssertEqual(line.help, "USB · the input chosen in Sound settings.")
        }
        XCTAssertEqual(MicrophoneCopy.dictatingDevice(name: "MacBook Pro Microphone",
                                                      transport: "built-in", narrowband: false,
                                                      headsetRisk: false, policy: .warn,
                                                      hasProbed: true).help,
                       "Built-in · the input chosen in Sound settings.")
    }

    /// "Low" is the session advisory's own ceiling, so the window and the
    /// notch never disagree.
    func testVolumeUsesTheAdvisoryCeiling() {
        let ceiling: Float = 0.7
        XCTAssertEqual(MicrophoneCopy.volume(0.42, lowCeiling: ceiling).value, "42%")
        XCTAssertTrue(MicrophoneCopy.volume(0.42, lowCeiling: ceiling).isLow)
        XCTAssertFalse(MicrophoneCopy.volume(0.7, lowCeiling: ceiling).isLow)
        XCTAssertEqual(MicrophoneCopy.volume(1.0, lowCeiling: ceiling).value, "100%")
        let none = MicrophoneCopy.volume(nil, lowCeiling: ceiling)
        XCTAssertEqual(none.value, "—")
        XCTAssertFalse(none.isLow, "a device with no slider is not a low slider")
    }

    func testTheTestHintNamesTheConfiguredKey() {
        XCTAssertEqual(MicrophoneCopy.testHint(hotkey: .fn, notchShown: true),
                       "Hold 🌐 and speak. The notch shows your level.")
        XCTAssertTrue(MicrophoneCopy.testHint(hotkey: .rightOption, notchShown: true)
            .hasPrefix("Hold right ⌥"))
        XCTAssertFalse(MicrophoneCopy.testHint(hotkey: .fn, notchShown: false).contains("notch"))
    }
}

final class SettingsPaneTests: XCTestCase {

    func testPanesInToolbarOrder() {
        XCTAssertEqual(SettingsPane.allCases.map(\.title),
                       ["General", "Microphone", "Writing", "Privacy", "Advanced"])
        XCTAssertEqual(Set(SettingsPane.allCases.map(\.symbol)).count, SettingsPane.allCases.count)
    }

    func testTheLastPaneIsRestoredAndAnUnknownOneFallsBackToGeneral() {
        XCTAssertEqual(SettingsPane.restored(nil), .general)
        XCTAssertEqual(SettingsPane.restored("privacy"), .privacy)
        XCTAssertEqual(SettingsPane.restored("settings"), .general)
    }

    func testMillisecondSlidersSnapToTheirStep() {
        XCTAssertEqual(MillisecondRow.snap(137, to: 25), 125)
        XCTAssertEqual(MillisecondRow.snap(138, to: 25), 150)
        XCTAssertEqual(MillisecondRow.snap(121.4, to: 10), 120)
        XCTAssertEqual(MillisecondRow.snap(3.6, to: 0), 4)
    }

    func testRestartSentence() {
        XCTAssertEqual(LaunchTimeSettings.sentence([]), "")
        XCTAssertEqual(LaunchTimeSettings.sentence(["Language"]), "Language")
        XCTAssertEqual(LaunchTimeSettings.sentence(["Dictation key", "Language", "Speech engine"]),
                       "Dictation key, Language and Speech engine")
    }
}

/// The settings this window surfaces for the first time, driven through the
/// model against a real temp config file.
@MainActor
final class SettingsWindowModelTests: XCTestCase {

    private var root: URL!
    private var configURL: URL!
    private var settings: Settings!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wisprit-settings-window-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        configURL = root.appendingPathComponent("config.json")
        settings = Settings(path: configURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeModel(installedLocales: [String] = ["en_US", "en_GB"]) -> WispritWindowModel {
        var facts = DoctorFacts()
        facts.installedLocales = installedLocales
        let probed = facts
        return WispritWindowModel(
            settings: settings,
            dictionary: DictionaryEditor(store: DictionaryStore(
                path: root.appendingPathComponent("dictionary.json"))),
            ports: WispritWindowModel.Ports(fullProbe: { probed }))
    }

    private func reread() -> Settings { Settings(path: configURL) }

    private func configText() -> String {
        (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
    }

    func testNewlySurfacedSwitchesPersist() {
        let model = makeModel()
        XCTAssertTrue(model.emojiCommands)
        XCTAssertTrue(model.identityExpansion)
        XCTAssertFalse(model.soundCues)
        XCTAssertTrue(model.historyDetail)
        XCTAssertTrue(model.adaptiveGrace)
        XCTAssertEqual(model.captureBackend, .hal)

        model.setEmojiCommands(false)
        model.setIdentityExpansion(false)
        model.setSoundCues(true)
        model.setHistoryDetail(false)
        model.setAdaptiveGrace(false)
        model.setCaptureBackend(.engine)

        let disk = reread()
        XCTAssertFalse(disk.emojiCommands)
        XCTAssertFalse(disk.identityExpansion)
        XCTAssertTrue(SoundCueSettings.isEnabled(disk))
        XCTAssertFalse(HistoryDetailSettings.isEnabled(disk))
        XCTAssertFalse(KeyupGraceAdaptiveSettings.isEnabled(disk))
        XCTAssertEqual(CaptureBackendSettings.backend(disk), .engine)
        XCTAssertFalse(model.emojiCommands)
        XCTAssertEqual(model.captureBackend, .engine)
    }

    /// No stored mirror means SwiftUI only re-reads if the setter says so.
    func testSettersAnnounceTheChange() {
        let model = makeModel()
        var fired = 0
        let token = model.objectWillChange.sink { fired += 1 }
        model.setEmojiCommands(false)
        model.setCaptureBackend(.engine)
        XCTAssertGreaterThanOrEqual(fired, 2)
        token.cancel()
    }

    func testAnUnknownCaptureBackendReadsAsTheDefault() {
        settings.set(CaptureBackendSettings.key, "bogus")
        XCTAssertEqual(makeModel().captureBackend, .hal)
    }

    func testChoosingTheSameLanguageWritesNothingAndAnotherWritesTheHyphenForm() async {
        let model = makeModel()
        await model.refreshFull()
        XCTAssertEqual(SettingsLanguage.selection(current: model.locale, in: model.languageOptions),
                       "en-us", "the default en-US selects the installed en_US")
        let before = configText()
        model.chooseLanguage("en_US")
        model.chooseLanguage("en-US")
        XCTAssertEqual(configText(), before)
        XCTAssertEqual(model.locale, "en-US")

        model.chooseLanguage("en-GB")
        XCTAssertEqual(model.locale, "en-GB")
        XCTAssertEqual(reread().locale, "en-GB")
    }

    func testRestoreDefaultTuningResetsOnlyTheAdvancedKnobs() {
        let model = makeModel()
        XCTAssertTrue(model.isTuningAtDefaults)
        model.setHotkey(.rightOption)
        model.setHoldDebounceMs(300)
        model.setKeyupGraceMs(200)
        model.setAdaptiveGrace(false)
        model.setFinalizeTimeoutMs(3000)
        model.setPasteRestoreDelayMs(900)
        model.setAiCleanupMaxWords(600)
        model.setAiCleanupTimeoutMs(20000)
        model.setEngine(.appleLive)
        model.setCaptureBackend(.engine)
        model.setImSelectionPolicy(.perUtterance)
        XCTAssertFalse(model.isTuningAtDefaults)

        model.restoreDefaultTuning()

        XCTAssertTrue(model.isTuningAtDefaults)
        let disk = reread()
        XCTAssertEqual(disk.holdDebounceMs, 150)
        XCTAssertEqual(KeyupGraceSettings.milliseconds(disk), 120)
        XCTAssertTrue(KeyupGraceAdaptiveSettings.isEnabled(disk))
        XCTAssertEqual(disk.finalizeTimeoutMs, 1500)
        XCTAssertEqual(disk.pasteRestoreDelayMs, 500)
        XCTAssertEqual(disk.aiCleanupMaxWords, 350)
        XCTAssertEqual(disk.aiCleanupTimeoutMs, 12000)
        XCTAssertEqual(disk.engine, "auto")
        XCTAssertEqual(CaptureBackendSettings.backend(disk), .hal)
        XCTAssertEqual(disk.string(SettingsKey.imSelectionPolicy), "warm")
        XCTAssertEqual(disk.hotkey, "right_option", "the dictation key is not a tuning knob")
    }

    func testRestoringDefaultsThatAreAlreadyDefaultWritesNothing() {
        let model = makeModel()
        let before = configText()
        model.restoreDefaultTuning()
        XCTAssertEqual(configText(), before)
    }

    // MARK: - restart notice

    func testLaunchTimeChangesAreReportedAndClearWhenUndone() {
        let model = makeModel()
        let session = SettingsSession(model: model, openSetup: {})
        XCTAssertEqual(session.pendingRestart, [])

        model.setHotkey(.rightOption)
        XCTAssertEqual(session.pendingRestart, ["Dictation key"])
        model.setKeyupGraceMs(200)
        model.setHistoryDetail(false)
        XCTAssertEqual(session.pendingRestart,
                       ["Dictation key", "Keep listening after release", "Save what was heard"])

        model.setHotkey(.fn)
        model.setKeyupGraceMs(120)
        model.setHistoryDetail(true)
        XCTAssertEqual(session.pendingRestart, [], "back where it launched: nothing to restart for")
    }

    /// Settings the app re-reads per dictation never ask for a restart.
    func testLiveSettingsNeverAskForARestart() {
        let model = makeModel()
        let session = SettingsSession(model: model, openSetup: {})
        model.setFillerRemoval(false)
        model.setEmojiCommands(false)
        model.setHoldDebounceMs(300)
        model.setPasteRestoreDelayMs(900)
        model.setCaptureBackend(.engine)
        model.setDualCapture(false)
        model.setInputDevicePolicy(.preferBuiltin)
        model.setSoundCues(true)
        XCTAssertEqual(session.pendingRestart, [])
    }

    /// The same language in the other spelling, or an explicit default for a
    /// string-keyed setting, is not a change.
    func testEquivalentValuesAreNotChanges() {
        let model = makeModel()
        let session = SettingsSession(model: model, openSetup: {})
        model.setLocale("en_US")
        settings.set(KeyupGraceSettings.key, 120)
        settings.set(KeyupGraceAdaptiveSettings.key, true)
        XCTAssertEqual(session.pendingRestart, [])
    }
}
