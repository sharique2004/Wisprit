import XCTest
import WispritIMProtocol

/// The transport itself, in one process: a named port, a real Mach round trip,
/// and the failure modes the app relies on to fall back cleanly.
final class PortTransportTests: XCTestCase {

    private var portName: String = ""
    private var server: WispritIMPortServer?

    override func setUp() {
        super.setUp()
        portName = "com.wisprit.test.\(UUID().uuidString.prefix(8))"
    }

    override func tearDown() {
        server?.stop()
        server = nil
        super.tearDown()
    }

    /// Sends from a background queue while the main run loop — where the port's
    /// source lives — is spun by `wait(for:)`.
    private func roundTrip(_ message: IMCommandMessage,
                           timeout: TimeInterval = 2.0) throws -> IMEventMessage? {
        let remote = WispritIMRemotePort(name: portName)
        let payload = try WispritIMPayload(command: message)
        let done = expectation(description: "reply")
        let box = Box()
        DispatchQueue.global().async {
            box.value = remote.send(payload, timeout: timeout)
            done.fulfill()
        }
        wait(for: [done], timeout: timeout + 1)
        return try box.value.map { try $0.event() }
    }

    func testAPayloadMakesItAcrossAndComesBack() throws {
        server = WispritIMPortServer(name: portName) { payload in
            guard let command = try? payload.command() else { return nil }
            guard case .commitFinal(let text) = command.command else { return nil }
            return try? WispritIMPayload(event: .editResult(generation: command.generation,
                                                            .applied(note: text)))
        }
        XCTAssertTrue(server!.start())

        let event = try roundTrip(.commitFinal(generation: 5, text: "hello"))

        XCTAssertEqual(event, .editResult(generation: 5, .applied(note: "hello")))
    }

    func testNoReplyIsNotAnError() throws {
        server = WispritIMPortServer(name: portName) { _ in nil }
        XCTAssertTrue(server!.start())

        XCTAssertNil(try roundTrip(.beginSession(generation: 1)))
    }

    func testSendingToNothingFailsFastInsteadOfHanging() throws {
        let remote = WispritIMRemotePort(name: portName)   // nobody listening
        XCTAssertFalse(remote.isAvailable)

        let started = Date()
        let payload = try WispritIMPayload(command: .beginSession(generation: 1))
        XCTAssertNil(remote.send(payload, timeout: 2.0))
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5,
                          "an absent input method must not stall the dictation path")
    }

    func testAvailabilityTracksTheServer() {
        let remote = WispritIMRemotePort(name: portName)
        XCTAssertFalse(remote.isAvailable)

        server = WispritIMPortServer(name: portName) { _ in nil }
        XCTAssertTrue(server!.start())
        XCTAssertTrue(remote.isAvailable)

        server?.stop()
        remote.invalidate()
        XCTAssertFalse(remote.isAvailable)
    }

    func testASecondServerCannotStealTheName() {
        server = WispritIMPortServer(name: portName) { _ in nil }
        XCTAssertTrue(server!.start())

        let impostor = WispritIMPortServer(name: portName) { _ in nil }
        XCTAssertFalse(impostor.start(),
                       "a second input method process must not fight over the field")
    }

    func testPostDoesNotWaitForAReply() throws {
        let received = expectation(description: "received")
        server = WispritIMPortServer(name: portName) { _ in
            received.fulfill()
            return nil
        }
        XCTAssertTrue(server!.start())

        let remote = WispritIMRemotePort(name: portName)
        let payload = try WispritIMPayload(command: .updateVolatile(generation: 1, tail: "tail"))
        DispatchQueue.global().async { XCTAssertTrue(remote.post(payload)) }

        wait(for: [received], timeout: 2)
    }

    private final class Box: @unchecked Sendable {
        var value: WispritIMPayload?
    }
}
