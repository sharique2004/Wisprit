import XCTest
import WispritIMProtocol
@testable import WispritIM

/// Live checks the user runs by hand. They touch the real input-source database
/// and write into the real focused window, so an ordinary `swift test` skips
/// every one of them.
///
///     ./scripts/build_im.sh --visible
///     WISPRIT_MANUAL_IM=1 swift test --filter WispritIMTests.ManualIMTests \
///         --scratch-path /tmp/wisprit-build-WispritIM
///
/// See `ManualIMSmoke` for the full four-step walkthrough.
final class ManualIMTests: XCTestCase {

    /// Read-only. Prints where the install stands and which calls would fix it.
    func testReport() throws {
        try XCTSkipUnless(ManualIMSmoke.isEnabled, "set \(ManualIMSmoke.envVar)=1")
        #if os(macOS)
        _ = ManualIMSmoke.report()
        #endif
    }

    /// Copies the bundle into `~/Library/Input Methods` and registers it.
    /// Needs the second opt-in as well — this one changes system state.
    func testInstallAndRegister() throws {
        try XCTSkipUnless(ManualIMSmoke.registrationAllowed,
                          "set \(ManualIMSmoke.envVar)=1 and \(ManualIMSmoke.registerEnvVar)=1")
        #if os(macOS)
        XCTAssertTrue(ManualIMSmoke.installAndRegister())
        #endif
    }

    /// The real thing: streams a live tail, two commits and a retroactive
    /// correction into whatever field is focused. Have TextEdit in front.
    func testLoopback() throws {
        try XCTSkipUnless(ManualIMSmoke.isEnabled, "set \(ManualIMSmoke.envVar)=1")
        #if os(macOS)
        XCTAssertTrue(ManualIMSmoke.loopback())
        #endif
    }

    /// Transport-only: launch our own `WispritIM.app`, ping it over the named
    /// port, kill it. Touches no input source, types nothing, and is the
    /// end-to-end proof that the sandbox `mach-register` exception and the port
    /// name actually let the two processes meet.
    func testPortPing() throws {
        try XCTSkipUnless(ManualIMSmoke.isEnabled, "set \(ManualIMSmoke.envVar)=1")
        #if os(macOS)
        let binary = ManualIMSmoke.stagedBundle().appendingPathComponent("Contents/MacOS/WispritIM")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: binary.path),
                          "run ./scripts/build_im.sh first")

        let process = Process()
        process.executableURL = binary
        try process.run()
        defer { process.terminate() }
        Thread.sleep(forTimeInterval: 1.0)

        let client = WispritIMClient { _ in }
        defer { client.invalidate() }
        let pong = client.ping(timeout: 5.0)

        XCTAssertEqual(pong?.wireVersion, WispritIMWire.version,
                       "no answer on \(WispritIMNaming.machServiceName)")
        if let pong {
            print("port round trip: \(String(format: "%.2f", pong.roundTrip * 1000)) ms")
        }
        #endif
    }

    /// The manual gates themselves are worth an unconditional test: a regression
    /// that made these default to "on" would let CI reconfigure a developer's
    /// input sources.
    func testManualPathsAreOffByDefault() {
        let environment = ProcessInfo.processInfo.environment
        if environment[ManualIMSmoke.envVar] == nil {
            XCTAssertFalse(ManualIMSmoke.isEnabled)
            XCTAssertFalse(ManualIMSmoke.registrationAllowed)
        }
        if environment[ManualIMSmoke.registerEnvVar] == nil {
            XCTAssertFalse(ManualIMSmoke.registrationAllowed,
                           "installing must need its own explicit opt-in")
        }
    }
}
