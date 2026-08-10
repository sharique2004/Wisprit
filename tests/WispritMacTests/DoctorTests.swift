import XCTest
import WispritIMProtocol
import WispritKit
import WispritPersistence
@testable import WispritMac

/// The doctor's judgement — marks, remedies, and the exit-code rule — built
/// from a plain facts value, so none of this needs a TCC grant.
final class DoctorTests: XCTestCase {

    private func green() -> DoctorFacts {
        var facts = DoctorFacts()
        facts.executablePath = "/Applications/Wisprit.app/Contents/MacOS/Wisprit"
        facts.accessibility = true
        facts.inputMonitoring = "granted"
        facts.postEventAccess = true
        facts.microphone = "granted"
        facts.secureInputActive = false
        facts.speechOK = true
        facts.transcriberAvailable = true
        facts.speechDetail = "SpeechTranscriber ready for en_US"
        facts.installedLocales = ["en_US"]
        facts.assetStatus = "supported"
        facts.aiAvailable = true
        facts.configValid = true
        facts.configPath = "/tmp/config.json"
        facts.dictionaryValid = true
        facts.dictionaryPath = "/tmp/dictionary.json"
        // Live typing is the optional Developer-ID rung 1: green means the
        // input method is installed, registered, enabled and answering.
        facts.imStaged = true
        facts.imStatus = InputMethodStatus(bundleInstalled: true, registered: true,
                                           enabled: true, selected: true,
                                           installedVersion: "2.0.0-dev",
                                           stagedVersion: "2.0.0-dev")
        facts.imReachable = true
        return facts
    }

    func testAllGreenIsReady() {
        let report = Doctor.report(from: green())
        XCTAssertTrue(report.isReady)
        XCTAssertTrue(report.checks.allSatisfy { $0.mark == .ok })
    }

    func testChecklistCoversEveryDoctorPySubject() {
        let report = Doctor.report(from: green())
        let labels = report.checks.map(\.label)
        XCTAssertEqual(labels, [
            "Accessibility",
            "Input Monitoring",
            "Post-event access",
            "Microphone",
            "Secure Keyboard Entry",
            "SpeechTranscriber (on-device ASR)",
            "AI cleanup (Apple Intelligence)",
            "Live Typing (input method)",
            "Live Typing bridge (XPC)",
            "Live Typing bundle",
            "config.json",
            "dictionary.json",
            "Parakeet models",
            "Dictation health",
            "Learned terms",
            "Accuracy eval baseline",
        ])
    }

    // MARK: - Parakeet models (path-based, warn-only)

    func testParakeetModelsNotDownloadedIsAGreenOptionalRow() {
        let report = Doctor.report(from: green())
        let check = report.check(Doctor.parakeetModelsLabel)
        XCTAssertEqual(check?.mark, .ok)
        XCTAssertEqual(check?.detail, "not downloaded (optional)")
        XCTAssertEqual(check?.isRequired, false)
    }

    func testParakeetModelsVerifiedNamesThePath() {
        var facts = green()
        facts.parakeetModels = "verified"
        facts.parakeetModelsPath = "/Users/x/.wisprit/models/parakeet"
        let check = Doctor.report(from: facts).check(Doctor.parakeetModelsLabel)
        XCTAssertEqual(check?.mark, .ok)
        XCTAssertTrue(check?.detail.contains("/Users/x/.wisprit/models/parakeet") == true)
    }

    func testParakeetModelsPartialWarnsButNeverFailsDoctor() {
        var facts = green()
        facts.parakeetModels = "partial"
        facts.parakeetModelsPath = "/Users/x/.wisprit/models/parakeet"
        let report = Doctor.report(from: facts)
        let check = report.check(Doctor.parakeetModelsLabel)
        XCTAssertEqual(check?.mark, .warn)
        XCTAssertTrue(check?.detail.contains("re-run the model download") == true)
        XCTAssertTrue(report.isReady, "an optional download can never fail doctor")
    }

    /// The probe reads the models dir BY PATH — the convention WispritParakeet's
    /// `ParakeetManifest` documents — because WispritMac does not link that
    /// target. Pin all three answers against real directories.
    func testParakeetModelsStateFromThePathConvention() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("parakeet-doctor-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        // Absent or empty dir: not downloaded.
        XCTAssertEqual(Doctor.parakeetModelsState(at: dir), "not_downloaded")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        XCTAssertEqual(Doctor.parakeetModelsState(at: dir), "not_downloaded")

        // Content without a valid marker: a torn download.
        try Data("bytes".utf8).write(to: dir.appendingPathComponent("weight.bin"))
        XCTAssertEqual(Doctor.parakeetModelsState(at: dir), "partial")
        try Data("not json".utf8).write(to: dir.appendingPathComponent("verified.json"))
        XCTAssertEqual(Doctor.parakeetModelsState(at: dir), "partial")

        // The store's marker: verified.
        try Data(#"{"manifest_version": 1}"#.utf8)
            .write(to: dir.appendingPathComponent("verified.json"))
        XCTAssertEqual(Doctor.parakeetModelsState(at: dir), "verified")
        // Anchored to the state dir, not a literal home path: tests may
        // override WispritPaths.overrideRoot, and the convention is
        // "<state dir>/models/parakeet" wherever the state dir is.
        XCTAssertEqual(Doctor.parakeetModelsDir.path,
                       WispritPaths.stateDir
                           .appendingPathComponent("models", isDirectory: true)
                           .appendingPathComponent("parakeet", isDirectory: true).path)
    }

    func testTheAccuracyRowsCanNeverFailADoctorRun() {
        // Every one of them reports on how dictation has been GOING. A machine
        // that has never been measured, or whose dictionary needs tidying, is
        // not a machine that cannot dictate.
        var facts = green()
        facts.metrics = metrics(total: 100, unexplained: 50)
        facts.learnedTerms = LearnedTermCleanup.Audit(
            examined: 3, suspects: [suspect("Sharhuue", .fold(into: "Sharique"))])
        facts.evalBaselinePath = "/repo/docs/eval/BASELINE.json"
        facts.evalBaselineOSBuild = "24F74"
        facts.osBuild = "25A123"
        let report = Doctor.report(from: facts)

        XCTAssertTrue(report.isReady)
        for label in ["Dictation health", "Learned terms", "Accuracy eval baseline"] {
            XCTAssertEqual(report.check(label)?.isRequired, false, label)
            XCTAssertNotEqual(report.check(label)?.mark, .bad, label)
        }
    }

    // MARK: - permissions

    func testMissingAccessibilityIsFatalAndNamesThePane() {
        var facts = green()
        facts.accessibility = false
        let report = Doctor.report(from: facts)

        let check = report.check("Accessibility")
        XCTAssertEqual(check?.mark, .bad)
        XCTAssertTrue(check?.detail.contains("System Settings ▸ Privacy & Security ▸ Accessibility") == true)
        XCTAssertFalse(report.isReady)
    }

    func testDeniedInputMonitoringIsNotFatalWhileAccessibilityIsGranted() {
        // IOHIDCheckAccess reads stale; Accessibility implies it in practice.
        var facts = green()
        facts.inputMonitoring = "denied"
        let report = Doctor.report(from: facts)

        XCTAssertEqual(report.check("Input Monitoring")?.mark, .bad)
        XCTAssertEqual(report.check("Input Monitoring")?.isRequired, false)
        XCTAssertTrue(report.isReady, "a stale Input Monitoring read must not block a working setup")
    }

    func testDeniedInputMonitoringIsFatalWhenAccessibilityIsAlsoMissing() {
        var facts = green()
        facts.accessibility = false
        facts.inputMonitoring = "denied"
        let report = Doctor.report(from: facts)

        XCTAssertEqual(report.check("Input Monitoring")?.isRequired, true)
        XCTAssertFalse(report.isReady)
    }

    func testUndeterminedInputMonitoringWarns() {
        var facts = green()
        facts.inputMonitoring = "undetermined"
        let report = Doctor.report(from: facts)
        XCTAssertEqual(report.check("Input Monitoring")?.mark, .warn)
    }

    func testUndeterminedMicrophoneWarnsButDeniedIsFatal() {
        var facts = green()
        facts.microphone = "undetermined"
        XCTAssertEqual(Doctor.report(from: facts).check("Microphone")?.mark, .warn)
        XCTAssertTrue(Doctor.report(from: facts).isReady)

        facts.microphone = "denied"
        let denied = Doctor.report(from: facts)
        XCTAssertEqual(denied.check("Microphone")?.mark, .bad)
        XCTAssertTrue(denied.check("Microphone")?.detail.contains("Privacy & Security ▸ Microphone") == true)
        XCTAssertFalse(denied.isReady)
    }

    func testMissingPostEventAccessWarnsWithTheRemedy() {
        var facts = green()
        facts.postEventAccess = false
        let report = Doctor.report(from: facts)
        let check = report.check("Post-event access")
        XCTAssertEqual(check?.mark, .warn)
        XCTAssertTrue(check?.detail.contains("posted events will be dropped") == true)
        XCTAssertTrue(report.isReady, "advisory only — Accessibility is the required gate")
    }

    func testActiveSecureInputWarnsAndExplainsWhoHoldsIt() {
        var facts = green()
        facts.secureInputActive = true
        let check = Doctor.report(from: facts).check("Secure Keyboard Entry")
        XCTAssertEqual(check?.mark, .warn)
        XCTAssertTrue(check?.detail.contains("password field or an app like Slack") == true)
    }

    // MARK: - speech

    func testSpeechFailureIsFatalAndCarriesTheFix() {
        var facts = green()
        facts.speechOK = false
        facts.speechDetail = "speech model for fr-FR is not installed (installed: en_US)"
        facts.speechFix = "Install it via AssetInventory.assetInstallationRequest(supporting:)"
        let report = Doctor.report(from: facts)

        let check = report.check("SpeechTranscriber (on-device ASR)")
        XCTAssertEqual(check?.mark, .bad)
        XCTAssertTrue(check?.detail.contains("is not installed") == true)
        XCTAssertTrue(check?.detail.contains("AssetInventory.assetInstallationRequest") == true)
        XCTAssertFalse(report.isReady)
    }

    func testAssetStatusIsReportedButNeverGates() {
        // Spike S1 q5: on a machine where transcription demonstrably works,
        // AssetInventory.status returns `.supported`, not `.installed`. Keying
        // the check on it would report a false failure.
        var facts = green()
        facts.assetStatus = "supported"
        let report = Doctor.report(from: facts)
        let check = report.check("SpeechTranscriber (on-device ASR)")

        XCTAssertEqual(check?.mark, .ok, "a `supported` asset status is a healthy machine")
        XCTAssertTrue(check?.detail.contains("advisory only") == true)
        XCTAssertTrue(check?.detail.contains("supported") == true)
        XCTAssertTrue(report.isReady)
    }

    // MARK: - AI

    func testUnavailableAppleIntelligenceWarnsButNeverBlocks() {
        var facts = green()
        facts.aiAvailable = false
        facts.aiReason = "appleIntelligenceNotEnabled"
        let report = Doctor.report(from: facts)

        let check = report.check("AI cleanup (Apple Intelligence)")
        XCTAssertEqual(check?.mark, .warn)
        XCTAssertTrue(check?.detail.contains("appleIntelligenceNotEnabled") == true)
        XCTAssertTrue(check?.detail.contains("Apple Intelligence & Siri") == true)
        XCTAssertTrue(report.isReady, "dictation degrades to the deterministic pipeline")
    }

    // MARK: - state files

    func testMissingStateFilesWarnWithTheirPaths() {
        var facts = green()
        facts.configValid = false
        facts.dictionaryValid = false
        let report = Doctor.report(from: facts)

        XCTAssertEqual(report.check("config.json")?.mark, .warn)
        XCTAssertTrue(report.check("config.json")?.detail.contains("/tmp/config.json") == true)
        XCTAssertTrue(report.check("dictionary.json")?.detail.contains("run once to create") == true)
        XCTAssertTrue(report.isReady)
    }

    // MARK: - rendering

    func testRenderedReportCarriesTheNonCheckableReminders() {
        let text = Doctor.report(from: green()).rendered()
        XCTAssertTrue(text.contains("Press 🌐 key to"))
        XCTAssertTrue(text.contains("Do Nothing"))
        XCTAssertTrue(text.contains("right_option"))
        XCTAssertTrue(text.contains("TCC permissions are granted to THIS binary"))
        XCTAssertTrue(text.contains("READY"))
        XCTAssertTrue(text.contains(WispritVersion.string))
    }

    func testRenderedReportSaysNotReadyWhenARequiredCheckFails() {
        var facts = green()
        facts.accessibility = false
        let text = Doctor.report(from: facts).rendered()
        XCTAssertTrue(text.contains("NOT READY"))
    }

    func testExecutablePathIsPrintedBecauseTCCIsPerBinary() {
        let text = Doctor.report(from: green()).rendered()
        XCTAssertTrue(text.contains("/Applications/Wisprit.app/Contents/MacOS/Wisprit"))
    }

    // MARK: - dictation health

    func testDictationHealthIsGreenBelowTheUnexplainedEmptyBar() {
        var facts = green()
        facts.metrics = metrics(total: 200, unexplained: 2)   // 1%
        let check = Doctor.report(from: facts).check(Doctor.dictationHealthLabel)

        XCTAssertEqual(check?.mark, .ok)
        XCTAssertTrue(check?.detail.contains("200 utterances") == true)
        XCTAssertTrue(check?.detail.contains("last 14 days") == true)
        XCTAssertTrue(check?.detail.contains("1.0%") == true)
    }

    func testDictationHealthWarnsAboveTheBarAndNamesTheCommand() {
        var facts = green()
        facts.metrics = metrics(total: 100, unexplained: 8)
        let report = Doctor.report(from: facts)
        let check = report.check(Doctor.dictationHealthLabel)

        XCTAssertEqual(check?.mark, .warn)
        XCTAssertTrue(check?.detail.contains("8.0%") == true)
        XCTAssertTrue(check?.detail.contains("Wisprit stats") == true)
        XCTAssertTrue(report.isReady, "a bad week of dictation is not a broken install")
    }

    func testDictationHealthSaysNoEvidenceRatherThanZeroPercent() {
        // The unprobed default and an empty window are both "nothing recorded",
        // and neither is a 0% failure rate to be reassured by.
        XCTAssertEqual(Doctor.report(from: green()).check(Doctor.dictationHealthLabel)?.mark, .ok)

        var facts = green()
        facts.metrics = metrics(total: 0, unexplained: 0)
        let check = Doctor.report(from: facts).check(Doctor.dictationHealthLabel)
        XCTAssertEqual(check?.mark, .ok)
        XCTAssertTrue(check?.detail.contains("no utterances recorded") == true)
    }

    // MARK: - learned terms

    func testLearnedTermsIsGreenWhenEveryLearnedSpellingIsPlausible() {
        var facts = green()
        facts.learnedTerms = LearnedTermCleanup.Audit(examined: 4, suspects: [])
        let check = Doctor.report(from: facts).check(Doctor.learnedTermsLabel)

        XCTAssertEqual(check?.mark, .ok)
        XCTAssertTrue(check?.detail.contains("4 learned by spelling") == true)
    }

    func testLearnedTermsSaysSoWhenNothingHasBeenLearnedAtAll() {
        let check = Doctor.report(from: green()).check(Doctor.learnedTermsLabel)
        XCTAssertEqual(check?.mark, .ok)
        XCTAssertTrue(check?.detail.contains("nothing learned by spelling yet") == true)
    }

    func testLearnedTermsWarnsListingTheSuspectsAndNamingTheFix() {
        var facts = green()
        facts.learnedTerms = LearnedTermCleanup.Audit(examined: 3, suspects: [
            suspect("Sharhuue", .fold(into: "Sharique")),
            suspect("Shaikd", .fold(into: "Sharique")),
            suspect("Zzzt", .quarantine(reason: "noVowel")),
        ])
        let report = Doctor.report(from: facts)
        let check = report.check(Doctor.learnedTermsLabel)

        XCTAssertEqual(check?.mark, .warn)
        XCTAssertTrue(check?.detail.contains("3 of 3") == true)
        XCTAssertTrue(check?.detail.contains("Sharhuue → Sharique") == true)
        XCTAssertTrue(check?.detail.contains("Zzzt (noVowel)") == true)
        XCTAssertTrue(check?.detail.contains(Doctor.cleanLearnedTermsTitle) == true)
        XCTAssertTrue(check?.detail.contains("dictionary.json.bak") == true,
                      "the remedy has to say the user's file is backed up first")
        XCTAssertTrue(report.isReady)
    }

    // MARK: - accuracy eval baseline

    // MARK: - context awareness (Phase 4)

    /// The row exists only when the user has opted in — a default-off feature
    /// has nothing to diagnose — and it can never fail a doctor run.
    func testContextAwarenessRowOnlyExistsWhenEnabled() {
        let off = Doctor.report(from: green())
        XCTAssertNil(off.check(Doctor.contextAwarenessLabel))

        var facts = green()
        facts.contextAwarenessEnabled = true
        let on = Doctor.report(from: facts)
        let row = on.check(Doctor.contextAwarenessLabel)
        XCTAssertNotNil(row)
        XCTAssertFalse(row?.isRequired ?? true, "warn-only by design")
    }

    /// Green facts serve both readers; the detail names which paths carry the
    /// reading, IM first (no permission needed).
    func testContextAwarenessNamesTheServingReaders() {
        var facts = green()
        facts.contextAwarenessEnabled = true
        facts.liveTypingEnabled = true
        let row = Doctor.report(from: facts).check(Doctor.contextAwarenessLabel)
        XCTAssertEqual(row?.mark, .ok)
        XCTAssertTrue(row?.detail.contains("input method") ?? false)
        XCTAssertTrue(row?.detail.contains("Accessibility") ?? false)
    }

    /// Enabled with no reader able to serve it is the one warn: no AX grant
    /// and no usable input method.
    func testContextAwarenessWarnsWhenNoReaderCanServe() {
        var facts = green()
        facts.contextAwarenessEnabled = true
        facts.accessibility = false
        facts.imStaged = false
        let row = Doctor.report(from: facts).check(Doctor.contextAwarenessLabel)
        XCTAssertEqual(row?.mark, .warn)
        XCTAssertTrue(row?.detail.contains("no reader") ?? false)
        XCTAssertTrue(row?.detail.contains("dictation itself is unaffected") ?? false)
    }

    /// AX granted alone is enough — the fallback path serves rungs 3–4.
    func testContextAwarenessIsGreenOnAccessibilityAlone() {
        var facts = green()
        facts.contextAwarenessEnabled = true
        facts.imStaged = false
        let row = Doctor.report(from: facts).check(Doctor.contextAwarenessLabel)
        XCTAssertEqual(row?.mark, .ok)
        XCTAssertTrue(row?.detail.contains("Accessibility") ?? false)
        XCTAssertFalse(row?.detail.contains("input method") ?? true)
    }

    func testNoEvalBaselineIsAnInfoRowNamingTheCommandThatWritesOne() {
        let check = Doctor.report(from: green()).check(Doctor.evalBaselineLabel)
        XCTAssertEqual(check?.mark, .ok, "a shipped copy has no repo and is not broken")
        XCTAssertTrue(check?.detail.contains("no eval baseline recorded") == true)
        XCTAssertTrue(check?.detail.contains(Doctor.evalRerunCommand) == true)
    }

    func testEvalBaselineRecordedOnThisBuildIsGreen() {
        var facts = green()
        facts.evalBaselinePath = "/repo/docs/eval/BASELINE.json"
        facts.evalBaselineOSBuild = "25A123"
        facts.osBuild = "25A123"
        let check = Doctor.report(from: facts).check(Doctor.evalBaselineLabel)

        XCTAssertEqual(check?.mark, .ok)
        XCTAssertTrue(check?.detail.contains("25A123") == true)
    }

    func testEvalBaselineFromAnOlderOSBuildWarnsWithTheRerunCommand() {
        var facts = green()
        facts.evalBaselinePath = "/repo/docs/eval/BASELINE.json"
        facts.evalBaselineOSBuild = "24F74"
        facts.osBuild = "25A123"
        let report = Doctor.report(from: facts)
        let check = report.check(Doctor.evalBaselineLabel)

        XCTAssertEqual(check?.mark, .warn)
        XCTAssertTrue(check?.detail.contains("24F74") == true)
        XCTAssertTrue(check?.detail.contains("25A123") == true)
        XCTAssertTrue(check?.detail.contains(Doctor.evalRerunCommand) == true)
        XCTAssertTrue(report.isReady, "a stale measurement is not a broken install")
    }

    func testEvalBaselineWithNoRecordedBuildCannotBeCalledStale() {
        var facts = green()
        facts.evalBaselinePath = "/repo/docs/eval/BASELINE.json"
        facts.osBuild = "25A123"
        let check = Doctor.report(from: facts).check(Doctor.evalBaselineLabel)

        XCTAssertEqual(check?.mark, .ok)
        XCTAssertTrue(check?.detail.contains("no os_build") == true)
    }

    func testOSBuildComparisonToleratesTheScoreboardsLongerSpelling() {
        // The scoreboard's own fixture records "26.0 (25A123)"; `sw_vers
        // -buildVersion` prints "25A123". Calling those two a regression would
        // make the row cry wolf on the machine that recorded the baseline.
        XCTAssertTrue(Doctor.osBuildMatches(recorded: "26.0 (25A123)", live: "25A123"))
        XCTAssertTrue(Doctor.osBuildMatches(recorded: "25A123", live: "25A123"))
        XCTAssertFalse(Doctor.osBuildMatches(recorded: "24F74", live: "25A123"))
        XCTAssertFalse(Doctor.osBuildMatches(recorded: "", live: "25A123"))
    }

    func testBuildTokenIsReadFromTheOSVersionStringSwVersAlsoPrints() {
        XCTAssertEqual(Doctor.buildToken(inOSVersionString: "Version 26.0 (Build 25A123)"),
                       "25A123")
        XCTAssertNil(Doctor.buildToken(inOSVersionString: "Version 26.0"))
    }

    func testTheBaselinesOSBuildIsFoundWhereverTheScoreboardRecordsIt() {
        // Searched by key, not decoded: the scoreboard owns that schema, and a
        // warn-only doctor row must not be what breaks when a field moves.
        XCTAssertEqual(Doctor.osBuild(inBaselineJSON: #"{"os_build": "25A123"}"#), "25A123")
        XCTAssertEqual(
            Doctor.osBuild(inBaselineJSON: #"{"records": [{"provenance": {"osBuild": "25A123"}}]}"#),
            "25A123")
        XCTAssertNil(Doctor.osBuild(inBaselineJSON: #"{"records": []}"#))
        XCTAssertNil(Doctor.osBuild(inBaselineJSON: "not json"))
    }

    // MARK: - fixtures

    /// Fixed clock: the rows are placed inside the doctor's 14-day window.
    private let now: Double = 1_775_000_000

    /// A summary built the way the real probe builds one — through the
    /// aggregator, over rows shaped like the ones metrics.log holds — so this
    /// test cannot disagree with `Wisprit stats` about what a rate is.
    private func metrics(total: Int, unexplained: Int) -> MetricsSummary {
        var rows: [JSONObject] = []
        for index in 0..<total {
            var row = JSONObject()
            row["ts"] = .double(now - 3600)
            if index < unexplained {
                row["outcome"] = .string("empty")
                row["empty_reason"] = .string("produced_nothing")
                row["peak_level"] = .double(0.2)     // audible
                row["held_ms"] = .double(2500)       // long enough to have said something
            } else {
                row["outcome"] = .string("paste")
            }
            rows.append(row)
        }
        return MetricsSummary.summarize(rows, window: MetricsWindow(days: 14), now: now)
    }

    private func suspect(_ term: String,
                         _ action: LearnedTermCleanup.Suspect.Action)
        -> LearnedTermCleanup.Suspect {
        LearnedTermCleanup.Suspect(term: term, hear: ["Sharik"], action: action)
    }
}
