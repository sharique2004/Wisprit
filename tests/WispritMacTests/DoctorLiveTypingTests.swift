import XCTest
import WispritIMProtocol
@testable import WispritMac

/// The three live-typing questions `wisprit doctor` now answers — registered?
/// enabled? bridge reachable? — and the rule that none of them can fail a
/// machine that dictates perfectly well by pasting.
final class DoctorLiveTypingTests: XCTestCase {

    /// A fully healthy machine, so the live-typing marks are the only variable.
    private func healthyFacts() -> DoctorFacts {
        var facts = DoctorFacts()
        facts.accessibility = true
        facts.inputMonitoring = "granted"
        facts.postEventAccess = true
        facts.microphone = "granted"
        facts.speechOK = true
        facts.aiAvailable = true
        facts.configValid = true
        facts.dictionaryValid = true
        facts.imStaged = true
        return facts
    }

    private func ready() -> InputMethodStatus {
        InputMethodStatus(bundleInstalled: true, registered: true, enabled: true,
                          selected: true, installedVersion: "2.0.0-dev",
                          stagedVersion: "2.0.0-dev")
    }

    // MARK: - registered / enabled

    func testReadyInputMethodIsGreen() {
        var facts = healthyFacts()
        facts.imStatus = ready()
        facts.imReachable = true
        let report = Doctor.report(from: facts)

        XCTAssertEqual(report.check(Doctor.liveTypingLabel)?.mark, .ok)
        XCTAssertTrue(report.check(Doctor.liveTypingLabel)?.detail
            .contains("registered and enabled") == true)
        XCTAssertTrue(report.isReady)
    }

    func testNotInstalledCarriesTheExactRemedy() {
        var facts = healthyFacts()
        facts.imStatus = InputMethodStatus(bundleInstalled: false)
        let check = Doctor.report(from: facts).check(Doctor.liveTypingLabel)

        XCTAssertEqual(check?.mark, .warn)
        XCTAssertTrue(check?.detail.contains("Library/Input Methods") == true, "\(check?.detail ?? "")")
        XCTAssertTrue(check?.detail.contains("registered: false") == true)
    }

    func testNotEnabledExplainsTheOneSystemPrompt() {
        var facts = healthyFacts()
        facts.imStatus = InputMethodStatus(bundleInstalled: true, registered: true, enabled: false)
        let check = Doctor.report(from: facts).check(Doctor.liveTypingLabel)

        XCTAssertEqual(check?.mark, .warn)
        XCTAssertTrue(check?.detail.contains("activate") == true,
                      "the user has to approve the activation dialog: \(check?.detail ?? "")")
        XCTAssertTrue(check?.detail.contains("System Settings ▸ Keyboard ▸ Input Sources") == true)
    }

    func testAStaleInstallAsksForAnUpdateRatherThanAReinstall() {
        var facts = healthyFacts()
        facts.imStatus = InputMethodStatus(bundleInstalled: true, registered: true, enabled: true,
                                           selected: false, installedVersion: "1.0.0",
                                           stagedVersion: "2.0.0-dev")
        let check = Doctor.report(from: facts).check(Doctor.liveTypingLabel)
        XCTAssertEqual(check?.mark, .warn)
        XCTAssertTrue(check?.detail.contains("newer input method") == true, "\(check?.detail ?? "")")
    }

    func testABuildWithNoStagedBundleSaysSoAndStillPasses() {
        var facts = healthyFacts()
        facts.imStaged = false
        facts.imStagedPath = "/tmp/Wisprit.app/Contents/Library/InputMethods/WispritIM.app"
        let report = Doctor.report(from: facts)
        let check = report.check(Doctor.liveTypingLabel)

        XCTAssertEqual(check?.mark, .warn)
        XCTAssertTrue(check?.detail.contains("scripts/build_app.sh") == true)
        XCTAssertTrue(check?.detail.contains("pastes at the end") == true)
        XCTAssertTrue(report.isReady, "live typing is optional; dictation still works")
    }

    // MARK: - the bridge

    func testReachableBridgeNamesThePortItAnswersOn() {
        var facts = healthyFacts()
        facts.imStatus = ready()
        facts.imReachable = true
        let check = Doctor.report(from: facts).check(Doctor.liveTypingBridgeLabel)
        XCTAssertEqual(check?.mark, .ok)
        XCTAssertTrue(check?.detail.contains(WispritIMNaming.machServiceName) == true)
    }

    func testAnUnselectedSourceExplainsThatTheProcessStartsOnDemand() {
        var facts = healthyFacts()
        facts.imStatus = InputMethodStatus(bundleInstalled: true, registered: true,
                                           enabled: true, selected: false)
        let check = Doctor.report(from: facts).check(Doctor.liveTypingBridgeLabel)
        XCTAssertEqual(check?.mark, .warn)
        XCTAssertTrue(check?.detail.contains("not running right now") == true,
                      "an enabled-but-unselected palette IM is not a resident process")
        XCTAssertTrue(check?.detail.contains("re-run doctor") == true)
    }

    func testASelectedButSilentBridgeSendsTheUserToTheMenuItem() {
        var facts = healthyFacts()
        facts.imStatus = ready()
        facts.imReachable = false
        let check = Doctor.report(from: facts).check(Doctor.liveTypingBridgeLabel)
        XCTAssertEqual(check?.mark, .warn)
        XCTAssertTrue(check?.detail.contains("Enable Live Typing…") == true)
        XCTAssertTrue(check?.detail.contains("Dictation keeps working") == true)
    }

    func testTheBridgeIsNotCheckedBeforeTheInputMethodIsUsable() {
        var facts = healthyFacts()
        facts.imStatus = InputMethodStatus(bundleInstalled: false)
        let check = Doctor.report(from: facts).check(Doctor.liveTypingBridgeLabel)
        XCTAssertEqual(check?.mark, .warn)
        XCTAssertTrue(check?.detail.contains("install and enable") == true)
    }

    // MARK: - the installed bundle's identity keys

    func testInstalledBundlePlistViolationsAreReported() {
        var facts = healthyFacts()
        facts.imStatus = ready()
        facts.imReachable = true
        facts.imPlistViolations = ["InputMethodConnectionName must be exactly \"com.wisprit.im_Connection\""]
        let report = Doctor.report(from: facts)
        let check = report.check(Doctor.liveTypingBundleLabel)

        XCTAssertEqual(check?.mark, .bad)
        XCTAssertTrue(check?.detail.contains("InputMethodConnectionName") == true)
        XCTAssertTrue(check?.detail.contains("Enable Live Typing…") == true)
        XCTAssertTrue(report.isReady,
                      "a broken optional input method must not fail an otherwise healthy machine")
    }

    func testBundleCheckIsOmittedWhenNothingIsInstalled() {
        var facts = healthyFacts()
        facts.imStatus = InputMethodStatus(bundleInstalled: false)
        XCTAssertNil(Doctor.report(from: facts).check(Doctor.liveTypingBundleLabel))
    }

    // MARK: - invariants

    func testNoLiveTypingCheckIsEverRequired() {
        var facts = healthyFacts()
        facts.imStaged = false
        facts.imStatus = InputMethodStatus(bundleInstalled: true, registered: false, enabled: false)
        facts.imPlistViolations = ["broken"]
        let report = Doctor.report(from: facts)
        for label in [Doctor.liveTypingLabel, Doctor.liveTypingBridgeLabel,
                      Doctor.liveTypingBundleLabel] {
            XCTAssertEqual(report.check(label)?.isRequired, false, label)
        }
        XCTAssertTrue(report.isReady)
    }

    func testTheReportStillRendersWithTheNewRows() {
        var facts = healthyFacts()
        facts.imStatus = ready()
        let rendered = Doctor.report(from: facts).rendered()
        XCTAssertTrue(rendered.contains(Doctor.liveTypingLabel))
        XCTAssertTrue(rendered.contains(Doctor.liveTypingBridgeLabel))
        XCTAssertTrue(rendered.contains("READY"))
    }
}
