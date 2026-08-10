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

    private let reads: [IMReadMessage] = [
        .readContext(generation: 7),
        .readCommitted(generation: 8),
    ]

    private let snapshots: [IMSnapshotMessage] = [
        .contextSnapshot(generation: 1, before: "please fix the ", selected: "speling ",
                         after: "of Sharique 👋"),
        .contextSnapshot(generation: 2, IMContextSnapshot.unavailable(.noDocumentAccess)),
        .committedSnapshot(generation: 3, current: "Hi Sharique.", detail: .unchanged),
        .committedSnapshot(generation: 4, current: "", detail: .changed),
        .committedSnapshot(generation: 5, IMCommittedSnapshot.unavailable(.unknown)),
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

    // MARK: The read-back channel (wire v2)

    func testEveryReadAndSnapshotSurvivesSecureCodingRoundTrip() throws {
        for message in reads {
            let payload = try WispritIMPayload(read: message)
            let restored = try XCTUnwrap(WispritIMPayload(archived: XCTUnwrap(payload.archived())))
            XCTAssertEqual(try restored.read(), message)
        }
        for message in snapshots {
            let payload = try WispritIMPayload(snapshot: message)
            let restored = try XCTUnwrap(WispritIMPayload(archived: XCTUnwrap(payload.archived())))
            XCTAssertEqual(try restored.snapshot(), message)
        }
    }

    func testAReadIsNotACommandAndASnapshotIsNotAnEvent() throws {
        let read = try WispritIMPayload(read: .readContext(generation: 1))
        XCTAssertThrowsError(try read.command()) { error in
            XCTAssertEqual(error as? WispritIMPayload.DecodeError,
                           .wrongKind(expected: "command", got: "read"))
        }
        let snapshot = try WispritIMPayload(snapshot: .committedSnapshot(generation: 1,
                                                                         current: "",
                                                                         detail: .unknown))
        XCTAssertThrowsError(try snapshot.event()) { error in
            XCTAssertEqual(error as? WispritIMPayload.DecodeError,
                           .wrongKind(expected: "event", got: "snapshot"))
        }
    }

    func testEachChannelIsStampedWithTheVersionThatIntroducedIt() throws {
        // A v2 app must still be able to type through a v1 input method: only the
        // read channel is v2-only, so only the read channel degrades.
        XCTAssertEqual(WispritIMWire.version, 2)
        XCTAssertEqual(WispritIMWire.minimumSupportedVersion, 1)
        XCTAssertEqual(try WispritIMPayload(command: .beginSession(generation: 1)).wireVersion, 1)
        XCTAssertEqual(try WispritIMPayload(event: .clientLost(generation: 1, reason: "x")).wireVersion, 1)
        XCTAssertEqual(try WispritIMPayload(read: .readContext(generation: 1)).wireVersion, 2)
    }

    func testAKindThisBuildDoesNotKnowFailsToDecodeAtTheDoor() {
        // The v1-receiver case, from the other side: an archive whose `kind` is
        // not in this build's table produces no object at all, so a stale input
        // method does nothing rather than half-understanding a read.
        XCTAssertNil(WispritIMPayload.Kind(rawValue: "read_v3"))
        XCTAssertEqual(WispritIMPayload.Kind.read.rawValue, "read")
        XCTAssertEqual(WispritIMPayload.Kind.snapshot.rawValue, "snapshot")
    }

    func testTheContextWindowCapsAreFixedByTheProtocolNotTheCaller() {
        XCTAssertEqual(IMContextWindow.before, 400)
        XCTAssertEqual(IMContextWindow.after, 200)
        XCTAssertEqual(IMContextWindow.maxSpan, 600)
    }

    func testReadDetailsAreStableStringsBecauseTheyLandInMetrics() {
        XCTAssertEqual(IMReadDetail.allCases.map(\.rawValue).sorted(), [
            "changed", "noClient", "noDocumentAccess", "noSession", "read",
            "readFailed", "staleGeneration", "unchanged", "unknown",
        ])
        XCTAssertEqual(IMReadDetail.allCases.filter(\.isUsable), [.read, .unchanged])
    }

    func testReadNamesAreStable() {
        XCTAssertEqual(IMRead.context.name, "read_context")
        XCTAssertEqual(IMRead.committed.name, "read_committed")
        XCTAssertEqual(IMSnapshot.contextSnapshot(IMContextSnapshot(detail: .read)).name,
                       "context_snapshot")
        XCTAssertEqual(IMSnapshot.committedSnapshot(IMCommittedSnapshot(detail: .unknown)).name,
                       "committed_snapshot")
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
