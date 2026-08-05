import XCTest
import WispritIMProtocol

/// The wire is the only thing two processes agree on. If it can drift, the input
/// method eventually writes something nobody asked for.
final class WireCodingTests: XCTestCase {

    private let commands: [IMCommandMessage] = [
        .beginSession(generation: 1),
        .updateVolatile(generation: 2, tail: "the quick bro"),
        .commitFinal(generation: 3, text: "The quick brown fox 👋"),
        .applyEdit(generation: 4, replace: "Sharik", with: "Sharique"),
        .endSession(generation: 5, commit: true),
        .endSession(generation: 6, commit: false),
    ]

    private let events: [IMEventMessage] = [
        .clientAcquired(generation: 1, IMClientCapabilities(supportsUnicode: true,
                                                            bundleID: "com.apple.TextEdit",
                                                            supportsDocumentAccess: true,
                                                            clientID: "abc")),
        .clientLost(generation: 2, reason: "deactivateServer"),
        .editResult(generation: 3, .applied(note: "Sharik → Sharique")),
        .editResult(generation: 4, .failed(.fieldChanged, note: "user typed")),
    ]

    func testEveryCommandSurvivesJSONRoundTrip() throws {
        for message in commands {
            let data = try JSONEncoder().encode(message)
            let decoded = try JSONDecoder().decode(IMCommandMessage.self, from: data)
            XCTAssertEqual(decoded, message)
        }
    }

    func testEveryEventSurvivesJSONRoundTrip() throws {
        for message in events {
            let data = try JSONEncoder().encode(message)
            let decoded = try JSONDecoder().decode(IMEventMessage.self, from: data)
            XCTAssertEqual(decoded, message)
        }
    }

    func testPayloadSurvivesSecureCodingRoundTrip() throws {
        for message in commands {
            let payload = try WispritIMPayload(command: message)
            let archived = try NSKeyedArchiver.archivedData(withRootObject: payload,
                                                            requiringSecureCoding: true)
            let restored = try XCTUnwrap(NSKeyedUnarchiver.unarchivedObject(
                ofClass: WispritIMPayload.self, from: archived))
            XCTAssertEqual(restored, payload)
            XCTAssertEqual(try restored.command(), message)
        }
    }

    func testEventPayloadSurvivesSecureCodingRoundTrip() throws {
        for message in events {
            let payload = try WispritIMPayload(event: message)
            let archived = try NSKeyedArchiver.archivedData(withRootObject: payload,
                                                            requiringSecureCoding: true)
            let restored = try XCTUnwrap(NSKeyedUnarchiver.unarchivedObject(
                ofClass: WispritIMPayload.self, from: archived))
            XCTAssertEqual(try restored.event(), message)
        }
    }

    func testPayloadIsSecureCoding() {
        XCTAssertTrue(WispritIMPayload.supportsSecureCoding)
    }

    func testAFutureWireVersionIsRefusedNotGuessedAt() throws {
        var message = IMCommandMessage.beginSession(generation: 1)
        message.wireVersion = WispritIMWire.version + 1
        let payload = try WispritIMPayload(command: message)

        XCTAssertThrowsError(try payload.command()) { error in
            XCTAssertEqual(error as? WispritIMPayload.DecodeError,
                           .unsupportedVersion(WispritIMWire.version + 1))
        }
    }

    func testACommandIsNotAnEvent() throws {
        let payload = try WispritIMPayload(command: .beginSession(generation: 1))
        XCTAssertThrowsError(try payload.event()) { error in
            XCTAssertEqual(error as? WispritIMPayload.DecodeError,
                           .wrongKind(expected: "event", got: "command"))
        }
    }

    func testGarbageIsRejected() {
        let payload = WispritIMPayload(wireVersion: WispritIMWire.version,
                                       kind: .command,
                                       json: Data("not json".utf8))
        XCTAssertThrowsError(try payload.command())
    }

    func testEditDetailsAreStableStringsBecauseTheyLandInMetrics() {
        XCTAssertEqual(IMEditDetail.allCases.map(\.rawValue).sorted(), [
            "ambiguousRelocation", "applied", "emptyEdit", "fieldChanged", "noClient",
            "noDocumentAccess", "noSession", "notSupported", "readFailed",
            "staleGeneration", "targetNotFound",
        ])
    }

    func testTierNamesAreStable() {
        XCTAssertEqual(IMDeliveryTier.allCases.map(\.rawValue),
                       ["marked_streaming", "commit_only", "unsupported"])
    }
}
