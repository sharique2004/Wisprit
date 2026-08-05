import XCTest
@testable import WispritMacUI

/// `WispritUI.callOnMain` — no windows, no AppKit objects, just the run-loop hop
/// every non-main thread uses to reach the pill and the menu.
final class MainThreadTests: XCTestCase {

    func testWorkRunsOnTheMainThread() {
        let done = expectation(description: "ran on main")
        DispatchQueue.global().async {
            WispritUI.callOnMain {
                XCTAssertTrue(Thread.isMainThread)
                done.fulfill()
            }
        }
        wait(for: [done], timeout: 2.0)
    }

    /// Ported 1:1 from `ui.call_on_main`: it always defers, even when the caller
    /// is already on the main thread, so a UI update can never re-enter its
    /// caller mid-mutation.
    func testAlwaysDefersEvenFromTheMainThread() {
        var ran = false
        let done = expectation(description: "deferred")
        WispritUI.callOnMain {
            ran = true
            done.fulfill()
        }
        XCTAssertFalse(ran, "callOnMain must not run inline")
        wait(for: [done], timeout: 2.0)
        XCTAssertTrue(ran)
    }

    func testOrderIsPreserved() {
        var order: [Int] = []
        let done = expectation(description: "all ran")
        for i in 0..<5 {
            WispritUI.callOnMain {
                order.append(i)
                if i == 4 { done.fulfill() }
            }
        }
        wait(for: [done], timeout: 2.0)
        XCTAssertEqual(order, [0, 1, 2, 3, 4])
    }
}
