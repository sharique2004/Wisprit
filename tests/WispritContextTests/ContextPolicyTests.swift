import XCTest

@testable import WispritContext

final class ContextPolicyTests: XCTestCase {

    private let birth = Date(timeIntervalSince1970: 1_754_700_000)

    private func snapshot(bundleID: String = "com.apple.TextEdit",
                          capturedAt: Date? = nil) -> ContextSnapshot {
        ContextSnapshot(bundleID: bundleID, before: "hello", after: "world",
                        capturedAt: capturedAt ?? birth, generation: 1)
    }

    // MARK: - Kill switch

    func testKillSwitchParsing() {
        XCTAssertTrue(ContextEnvironment.isDisabled(in: ["WISPRIT_NO_CONTEXT": "1"]))
        XCTAssertTrue(ContextEnvironment.isDisabled(in: ["WISPRIT_NO_CONTEXT": "true"]))
        XCTAssertTrue(ContextEnvironment.isDisabled(in: ["WISPRIT_NO_CONTEXT": "TRUE"]))
        XCTAssertFalse(ContextEnvironment.isDisabled(in: ["WISPRIT_NO_CONTEXT": "0"]))
        XCTAssertFalse(ContextEnvironment.isDisabled(in: ["WISPRIT_NO_CONTEXT": ""]))
        XCTAssertFalse(ContextEnvironment.isDisabled(in: [:]))
    }

    func testKillSwitchOutranksEverySetting() {
        let enabled = ContextPolicy(enabled: true)
        XCTAssertEqual(enabled.refusalToCapture(bundleID: "com.apple.TextEdit",
                                                environment: ["WISPRIT_NO_CONTEXT": "1"]),
                       .killSwitch)
        // Even a policy that would refuse anyway reports the kill switch first.
        let disabled = ContextPolicy(enabled: false)
        XCTAssertEqual(disabled.refusalToCapture(bundleID: "com.apple.TextEdit",
                                                 environment: ["WISPRIT_NO_CONTEXT": "1"]),
                       .killSwitch)
    }

    // MARK: - Consent and exclusions

    func testDefaultPolicyIsOff() {
        XCTAssertEqual(ContextPolicy().refusalToCapture(bundleID: "com.apple.TextEdit",
                                                        environment: [:]),
                       .disabled)
    }

    func testEnabledPolicyAllowsAnOrdinaryApp() {
        XCTAssertNil(ContextPolicy(enabled: true)
            .refusalToCapture(bundleID: "com.apple.TextEdit", environment: [:]))
    }

    func testPasswordManagersAreExcludedByDefaultCaseInsensitively() {
        let policy = ContextPolicy(enabled: true)
        XCTAssertEqual(policy.refusalToCapture(bundleID: "com.1password.1Password",
                                               environment: [:]),
                       .excludedApp)
        XCTAssertEqual(policy.refusalToCapture(bundleID: "COM.APPLE.PASSWORDS",
                                               environment: [:]),
                       .excludedApp)
    }

    func testCustomExclusionsAreHonored() {
        let policy = ContextPolicy(enabled: true, excludedBundleIDs: ["com.Example.Secret"])
        XCTAssertEqual(policy.refusalToCapture(bundleID: "com.example.secret",
                                               environment: [:]),
                       .excludedApp)
        XCTAssertNil(policy.refusalToCapture(bundleID: "com.apple.textedit", environment: [:]))
    }

    // MARK: - Time budget

    func testCaptureIsStaleStrictlyAfterBudget() {
        let policy = ContextPolicy(enabled: true, captureBudget: 2.0)
        XCTAssertFalse(policy.isStale(startedAt: birth, now: birth.addingTimeInterval(2.0)),
                       "stale AFTER T+B, not at it")
        XCTAssertTrue(policy.isStale(startedAt: birth, now: birth.addingTimeInterval(2.001)))
    }

    func testRefusalToUseChecksStalenessAfterEverythingElse() {
        let policy = ContextPolicy(enabled: true, captureBudget: 2.0)
        let fresh = snapshot()
        XCTAssertNil(policy.refusalToUse(fresh, now: birth.addingTimeInterval(1.0),
                                         environment: [:]))
        XCTAssertEqual(policy.refusalToUse(fresh, now: birth.addingTimeInterval(3.0),
                                           environment: [:]),
                       .stale)
        // A stale snapshot in an excluded app reports the exclusion.
        let secret = snapshot(bundleID: "com.bitwarden.desktop")
        XCTAssertEqual(policy.refusalToUse(secret, now: birth.addingTimeInterval(3.0),
                                           environment: [:]),
                       .excludedApp)
        // And the kill switch beats both.
        XCTAssertEqual(policy.refusalToUse(secret, now: birth.addingTimeInterval(3.0),
                                           environment: ["WISPRIT_NO_CONTEXT": "1"]),
                       .killSwitch)
    }

    // MARK: - Char caps

    func testClampKeepsTheTextNearestTheCursor() {
        let policy = ContextPolicy(enabled: true, maxFieldChars: 5)
        let long = ContextSnapshot(bundleID: "com.apple.TextEdit",
                                   before: "abcdefghij", selected: "0123456789",
                                   after: "qrstuvwxyz", capturedAt: birth, generation: 1)
        let clamped = policy.clamped(long)
        XCTAssertEqual(clamped.before, "fghij", "before keeps its END")
        XCTAssertEqual(clamped.selected, "01234", "selected keeps its START")
        XCTAssertEqual(clamped.after, "qrstu", "after keeps its START")
        XCTAssertEqual(clamped.bundleID, long.bundleID)
        XCTAssertEqual(clamped.generation, long.generation)
    }

    func testClampLeavesShortFieldsAlone() {
        let policy = ContextPolicy(enabled: true)
        let short = snapshot()
        XCTAssertEqual(policy.clamped(short), short)
    }
}
