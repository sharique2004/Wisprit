import XCTest
import WispritIMProtocol
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
        ])
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
}
