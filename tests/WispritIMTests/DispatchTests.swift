import XCTest
import WispritIMProtocol
@testable import WispritIM

/// The full path a real message takes: archived payload → decode → decide →
/// write to the field → encoded event back. Everything except the Mach port.
final class DispatchTests: XCTestCase {

    private func roundTrip(_ payload: WispritIMPayload) throws -> WispritIMPayload {
        let archived = try NSKeyedArchiver.archivedData(withRootObject: payload,
                                                        requiringSecureCoding: true)
        return try XCTUnwrap(NSKeyedUnarchiver.unarchivedObject(
            ofClass: WispritIMPayload.self, from: archived))
    }

    func testAWholeUtteranceArrivesAsPayloadsAndLandsInTheField() throws {
        let client = FakeClient()
        let session = IMStreamSession()
        session.clientAcquired(client)
        let generation: UInt64 = 100

        let script: [IMCommandMessage] = [
            .beginSession(generation: generation),
            .updateVolatile(generation: generation, tail: "hi shar"),
            .commitFinal(generation: generation, text: "Hi Sharik."),
            .applyEdit(generation: generation, replace: "Sharik", with: "Sharique"),
            .endSession(generation: generation, commit: true),
        ]

        var events: [IMEvent] = []
        for message in script {
            let payload = try roundTrip(WispritIMPayload(command: message))
            guard case .reply(let response) = IMDispatch.handle(payload, session: session) else {
                return XCTFail("payload should have decoded")
            }
            if let response { events.append(try roundTrip(response).event().event) }
        }

        XCTAssertEqual(client.document as String, "Hi Sharique.")
        XCTAssertEqual(events, [
            .clientAcquired(client.capabilities),
            .editResult(.applied(note: "Sharik → Sharique")),
        ])
    }

    func testBytesWeCannotReadChangeNothing() {
        let client = FakeClient()
        let session = IMStreamSession()
        session.clientAcquired(client)

        let junk = WispritIMPayload(wireVersion: WispritIMWire.version,
                                    kind: .command,
                                    json: Data([0x00, 0x01, 0x02]))
        let outcome = IMDispatch.handle(junk, session: session)

        guard case .undecodable = outcome else { return XCTFail("expected undecodable, got \(outcome)") }
        XCTAssertTrue(client.ops.isEmpty)
    }

    func testAnEventPayloadSentAsACommandIsRefused() throws {
        let session = IMStreamSession()
        let payload = try WispritIMPayload(event: .clientLost(generation: 1, reason: "x"))
        guard case .undecodable = IMDispatch.handle(payload, session: session) else {
            return XCTFail("an event is not a command")
        }
    }
}
