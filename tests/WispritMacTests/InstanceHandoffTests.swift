import XCTest
import WispritKit
@testable import WispritMac

/// Second launch hands off instead of erroring.
///
/// All in-process: `flock` is per open-file-description (so two
/// `SingleInstanceLock`s in one test conflict exactly like two processes would),
/// and `CFMessagePortSendRequest` to a local port in the same process completes
/// synchronously. Neither trick needs a second app spawned, so the whole
/// decision procedure is testable at unit speed.
final class InstanceHandoffTests: XCTestCase {

    // MARK: - wire format

    func testRequestRoundTripsForEveryVerb() {
        var requests: [InstanceHandoff.Request] = [.window(nil), .setupGuide]
        requests += WispritWindowModel.Tab.allCases.map { .window($0) }

        for request in requests {
            let decoded = InstanceHandoff.Request(decoding: request.encoded)
            XCTAssertEqual(decoded, request, "\(request) did not survive the wire")
        }
    }

    func testEveryTabHasItsOwnEncoding() {
        let encodings = Set(WispritWindowModel.Tab.allCases.map { InstanceHandoff.Request.window($0).encoded })
        XCTAssertEqual(encodings.count, WispritWindowModel.Tab.allCases.count)
        // The two non-tab words must not be reachable as tab names either.
        XCTAssertFalse(encodings.contains(InstanceHandoff.Request.window(nil).encoded))
        XCTAssertFalse(encodings.contains(InstanceHandoff.Request.setupGuide.encoded))
    }

    func testDecodingIsTotal() {
        // An old instance meeting a new launcher is the routine case; a decoder
        // that guessed would open the wrong window.
        XCTAssertNil(InstanceHandoff.Request(decoding: Data()))
        XCTAssertNil(InstanceHandoff.Request(decoding: Data("garbage".utf8)))
        XCTAssertNil(InstanceHandoff.Request(decoding: Data("v2 show:home".utf8)))
        XCTAssertNil(InstanceHandoff.Request(decoding: Data("v1 show:".utf8)))
        XCTAssertNil(InstanceHandoff.Request(decoding: Data("v1 show:nosuchtab".utf8)))
        XCTAssertNil(InstanceHandoff.Request(decoding: Data("v1 quit".utf8)))
        XCTAssertNil(InstanceHandoff.Request(decoding: Data([0xFF, 0xFE, 0xFD])))
    }

    // MARK: - launch-verb mapping

    func testLaunchVerbsMapToRequests() {
        // Pinned because `.none → .window(nil)` is a judgement call: a bare
        // double-click means "show me the app", and `.window(nil)` routes to the
        // same `openWindow()` a Dock click does.
        XCTAssertEqual(InstanceHandoff.request(for: .none), .window(nil))
        XCTAssertEqual(InstanceHandoff.request(for: .setupGuide), .setupGuide)
        for tab in WispritWindowModel.Tab.allCases {
            XCTAssertEqual(InstanceHandoff.request(for: .page(tab)), .window(tab))
        }
    }

    // MARK: - port name

    func testPortNameIsDerivedFromTheStateDirectory() {
        let a = URL(fileURLWithPath: "/tmp/wisprit-a")
        let b = URL(fileURLWithPath: "/tmp/wisprit-b")

        XCTAssertEqual(InstanceHandoff.portName(stateDir: a), InstanceHandoff.portName(stateDir: a))
        XCTAssertNotEqual(InstanceHandoff.portName(stateDir: a), InstanceHandoff.portName(stateDir: b))
        XCTAssertTrue(InstanceHandoff.portName(stateDir: a).hasPrefix("com.wisprit.app.instance."))
        XCTAssertLessThan(InstanceHandoff.portName(stateDir: a).count, 128,
                          "bootstrap names have a length limit")
    }

    func testPortNameFollowsTheStateDirOverride() {
        // WISPRIT_STATE_DIR moves the lock; the port must move with it or a
        // throwaway instance answers handoffs meant for the installed app.
        let installed = InstanceHandoff.portName()
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wisprit-port-\(UUID().uuidString)")
        WispritPaths.overrideRoot = root
        defer { WispritPaths.overrideRoot = nil }

        XCTAssertNotEqual(InstanceHandoff.portName(), installed)
    }

    // MARK: - transport

    private func uniquePortName() -> String {
        // Not `portName()`: a test must never register the name a real running
        // Wisprit is listening on.
        "com.wisprit.test.handoff." + UUID().uuidString.prefix(12)
    }

    func testServerAndClientRoundTripInProcess() {
        let name = uniquePortName()
        var received: [InstanceHandoff.Request] = []
        let server = InstanceHandoffServer(name: name) { received.append($0) }
        XCTAssertTrue(server.start(on: CFRunLoopGetCurrent()))
        defer { server.stop() }

        let client = InstanceHandoffClient(name: name)
        XCTAssertTrue(client.requestShow(.window(.dictionary)))
        XCTAssertEqual(received, [.window(.dictionary)])

        XCTAssertTrue(client.requestShow(.setupGuide))
        XCTAssertEqual(received, [.window(.dictionary), .setupGuide])
    }

    func testClientReportsNoHandoffWhenNobodyIsListening() {
        // The foreign-holder case: nothing registered, so no ack, and the caller
        // must not mistake silence for success.
        XCTAssertFalse(InstanceHandoffClient(name: uniquePortName()).requestShow(.window(nil)))
    }

    func testSecondServerOnTheSameNameStandsDown() {
        let name = uniquePortName()
        let first = InstanceHandoffServer(name: name) { _ in }
        XCTAssertTrue(first.start(on: CFRunLoopGetCurrent()))
        defer { first.stop() }

        let second = InstanceHandoffServer(name: name) { _ in }
        XCTAssertFalse(second.start(on: CFRunLoopGetCurrent()))
    }

    func testServerIgnoresRequestsItCannotDecode() {
        let name = uniquePortName()
        var received: [InstanceHandoff.Request] = []
        let server = InstanceHandoffServer(name: name) { received.append($0) }
        XCTAssertTrue(server.start(on: CFRunLoopGetCurrent()))
        defer { server.stop() }

        let port = CFMessagePortCreateRemote(nil, name as CFString)
        XCTAssertNotNil(port)
        var reply: Unmanaged<CFData>?
        let status = CFMessagePortSendRequest(port, 0, Data("v9 nonsense".utf8) as CFData,
                                              1.0, 1.0,
                                              CFRunLoopMode.defaultMode.rawValue, &reply)
        XCTAssertEqual(status, Int32(kCFMessagePortSuccess))
        // A nil from the callback comes back as an EMPTY reply, not a missing
        // one — which is why the client compares against the ack bytes rather
        // than merely checking that something came back.
        let replyData = reply?.takeRetainedValue() as Data? ?? Data()
        XCTAssertNotEqual(replyData, InstanceHandoff.ackData, "garbage must get no ack")
        XCTAssertTrue(received.isEmpty)
    }

    // MARK: - arbitration

    /// Records what was sent and answers however the test says.
    private final class FakeSender: InstanceHandoffSending {
        var sent: [InstanceHandoff.Request] = []
        var ack: Bool
        init(ack: Bool) { self.ack = ack }
        func requestShow(_ request: InstanceHandoff.Request) -> Bool {
            sent.append(request)
            return ack
        }
    }

    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wisprit-handoff-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func lock() -> SingleInstanceLock {
        SingleInstanceLock(path: directory.appendingPathComponent("wisprit.lock"))
    }

    func testFreeLockMakesUsPrimaryWithoutTalkingToAnyone() {
        let sender = FakeSender(ack: true)
        var sleeps: [TimeInterval] = []
        let mine = lock()
        defer { mine.release() }

        let outcome = InstanceHandoff.arbitrate(lock: mine, request: .window(nil), client: sender,
                                                sleep: { sleeps.append($0) })

        XCTAssertEqual(outcome, .weArePrimary)
        XCTAssertTrue(mine.isHeld)
        XCTAssertTrue(sender.sent.isEmpty, "the primary must not send itself a handoff")
        XCTAssertTrue(sleeps.isEmpty, "the common case must not sleep at all")
    }

    func testHeldLockPlusAnAckHandsOffOnTheFirstTry() {
        let holder = lock()
        XCTAssertTrue(holder.acquire())
        defer { holder.release() }

        let sender = FakeSender(ack: true)
        var sleeps: [TimeInterval] = []
        let outcome = InstanceHandoff.arbitrate(lock: lock(), request: .window(.insights),
                                                client: sender, sleep: { sleeps.append($0) })

        XCTAssertEqual(outcome, .handedOff)
        XCTAssertEqual(sender.sent, [.window(.insights)])
        XCTAssertTrue(sleeps.isEmpty)
    }

    func testHeldLockWithNoAnswerIsAForeignHolder() {
        let holder = lock()
        XCTAssertTrue(holder.acquire())
        defer { holder.release() }

        let sender = FakeSender(ack: false)
        var sleeps: [TimeInterval] = []
        let outcome = InstanceHandoff.arbitrate(lock: lock(), request: .window(nil), client: sender,
                                                attempts: 4, interval: 0.05,
                                                sleep: { sleeps.append($0) })

        // The Python-era app, or a pre-handoff build: it holds the lock and will
        // never answer, and the toast is the honest outcome.
        XCTAssertEqual(outcome, .lockedByForeignProcess)
        XCTAssertEqual(sleeps, [0.05, 0.05, 0.05, 0.05])
        XCTAssertEqual(sender.sent.count, 5, "one send up front, then one per attempt")
    }

    func testLockFreedMidRetryMakesUsPrimary() {
        // The relaunch-teardown race: the outgoing instance still holds the lock
        // and its port is already gone, so neither branch wins on tick one.
        let holder = lock()
        XCTAssertTrue(holder.acquire())

        let sender = FakeSender(ack: false)
        var ticks = 0
        let mine = lock()
        defer { mine.release() }
        let outcome = InstanceHandoff.arbitrate(lock: mine, request: .setupGuide, client: sender,
                                                attempts: 10, interval: 0.01,
                                                sleep: { _ in
                                                    ticks += 1
                                                    if ticks == 3 { holder.release() }
                                                })

        XCTAssertEqual(outcome, .weArePrimary)
        XCTAssertEqual(ticks, 3)
        XCTAssertTrue(mine.isHeld)
    }

    func testArbitrationEndToEndWithARealPort() {
        // The whole path with no fakes in it: a held lock plus a live listener
        // resolves to a handoff carrying the right request.
        let holder = lock()
        XCTAssertTrue(holder.acquire())
        defer { holder.release() }

        let name = uniquePortName()
        var received: [InstanceHandoff.Request] = []
        let server = InstanceHandoffServer(name: name) { received.append($0) }
        XCTAssertTrue(server.start(on: CFRunLoopGetCurrent()))
        defer { server.stop() }

        let outcome = InstanceHandoff.arbitrate(lock: lock(), request: .window(.home),
                                                client: InstanceHandoffClient(name: name),
                                                sleep: { _ in XCTFail("should not have retried") })

        XCTAssertEqual(outcome, .handedOff)
        XCTAssertEqual(received, [.window(.home)])
    }
}
