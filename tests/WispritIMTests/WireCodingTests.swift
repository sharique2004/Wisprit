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
        .applyEdit(generation: 9, replace: "fox", with: "cat", utf16LocationInCommitted: 2),
        .applyEdit(generation: 10, replace: "👋", with: "hi", utf16LocationInCommitted: 0),
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
        .editResult(generation: 9, .applied(note: "fox → cat",
                                            appliedUtf16LocationInCommitted: 2)),
        .editResult(generation: 10, .applied(note: "at the very start",
                                             appliedUtf16LocationInCommitted: 0)),
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

    // MARK: The retro-edit anchor, in both directions across an update window

    /// An old `WispritIM.app` in `~/Library/Input Methods` and a new app, or
    /// the reverse: only one of them has the anchor field, and both have to
    /// keep typing. These two types stand in for the older build's view.
    private struct LegacyEdit: Codable, Equatable {
        var replace: String
        var with: String
        var occurrence: String
    }

    private struct LegacyEditResult: Codable, Equatable {
        var ok: Bool
        var detail: String
        var note: String
    }

    /// OLD APP → NEW IM. The old build has no such property, so it emits
    /// exactly these bytes: no key at all. Pinning that the key is OMITTED
    /// rather than written as `null` is what makes this test the old encoder.
    func testAMessageWithoutAnAnchorOmitsTheKeyAndDecodesToNil() throws {
        let edit = IMEdit(replace: "Sharik", with: "Sharique")
        let json = try String(decoding: JSONEncoder().encode(edit), as: UTF8.self)
        XCTAssertFalse(json.contains("utf16LocationInCommitted"),
                       "an absent anchor puts nothing on the wire: \(json)")

        let decoded = try JSONDecoder().decode(IMEdit.self, from: Data(json.utf8))
        XCTAssertNil(decoded.utf16LocationInCommitted, "a missing key is 'no opinion', not an error")
        XCTAssertEqual(decoded, edit)

        let result = try JSONEncoder().encode(IMEditResult.applied(note: "x"))
        XCTAssertFalse(String(decoding: result, as: UTF8.self)
                           .contains("appliedUtf16LocationInCommitted"))
        XCTAssertNil(try JSONDecoder().decode(IMEditResult.self, from: result)
                         .appliedUtf16LocationInCommitted)
    }

    /// NEW APP → OLD IM. The extra key is dropped by a decoder that has never
    /// heard of it, so the stale input method still applies the edit — by the
    /// last occurrence, which is the behaviour it always had.
    func testAnOlderBuildDropsTheAnchorKeyInsteadOfFailingToDecode() throws {
        let anchored = try JSONEncoder().encode(
            IMEdit(replace: "fox", with: "cat", utf16LocationInCommitted: 2))
        XCTAssertEqual(try JSONDecoder().decode(LegacyEdit.self, from: anchored),
                       LegacyEdit(replace: "fox", with: "cat", occurrence: "last"))

        let echoed = try JSONEncoder().encode(
            IMEditResult.applied(note: "fox → cat", appliedUtf16LocationInCommitted: 2))
        XCTAssertEqual(try JSONDecoder().decode(LegacyEditResult.self, from: echoed),
                       LegacyEditResult(ok: true, detail: "applied", note: "fox → cat"))
    }

    /// The reason the anchor is a FIELD and not an `Occurrence` case, pinned so
    /// the next person to want "the first one" does not reach for the enum: a
    /// raw value an old build cannot represent throws at the door and fails the
    /// whole `applyEdit` closed on every stale install, while an added optional
    /// field degrades to the behaviour that build already had. Which is also
    /// why the write channel does not move.
    func testTheOccurrenceEnumStaysTheOneCaseOldInputMethodsKnow() {
        XCTAssertEqual(IMEdit.Occurrence.allCases.map(\.rawValue), ["last"])
        XCTAssertEqual(WispritIMWire.writeChannelVersion, 1,
                       "an additive optional field is not an incompatible change")
        XCTAssertEqual(try? WispritIMPayload(command: .applyEdit(
            generation: 1, replace: "fox", with: "cat",
            utf16LocationInCommitted: 2)).wireVersion, 1)
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
