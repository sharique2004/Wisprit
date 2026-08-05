import XCTest
import WispritKit
@testable import WispritMac

/// The double-paste guard. `flock` is per open-file-description, so a second
/// `open` + `flock` fails even inside one process — which is exactly what makes
/// this testable without spawning a second app.
final class SingleInstanceTests: XCTestCase {

    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wisprit-lock-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func lock() -> SingleInstanceLock {
        SingleInstanceLock(path: directory.appendingPathComponent("wisprit.lock"))
    }

    func testFirstAcquireSucceeds() {
        let first = lock()
        XCTAssertTrue(first.acquire())
        XCTAssertTrue(first.isHeld)
        first.release()
    }

    func testSecondAcquireIsRefusedWhileTheFirstIsHeld() {
        let first = lock()
        XCTAssertTrue(first.acquire())
        defer { first.release() }

        let second = lock()
        XCTAssertFalse(second.acquire(), "two instances would each paste on every release")
        XCTAssertFalse(second.isHeld)
    }

    func testLockIsReusableAfterRelease() {
        let first = lock()
        XCTAssertTrue(first.acquire())
        first.release()

        let second = lock()
        XCTAssertTrue(second.acquire())
        second.release()
    }

    func testAcquireIsIdempotentForTheHolder() {
        let held = lock()
        XCTAssertTrue(held.acquire())
        XCTAssertTrue(held.acquire())
        held.release()
    }

    func testDefaultPathIsTheSameFileThePythonEraLocks() {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wisprit-lockpath-\(UUID().uuidString)")
        WispritPaths.overrideRoot = root
        defer {
            WispritPaths.overrideRoot = nil
            try? FileManager.default.removeItem(at: root)
        }

        XCTAssertEqual(SingleInstanceLock().lockPath.lastPathComponent, "wisprit.lock")
        XCTAssertEqual(SingleInstanceLock().lockPath.deletingLastPathComponent().path,
                       root.path)
    }
}
