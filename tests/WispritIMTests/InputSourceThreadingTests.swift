import XCTest
import WispritIMProtocol

/// HIToolbox aborts the process if Text Input Sources run on two threads.
/// `status` has to be callable from the dictation session thread while the
/// menu timer is also sampling it on main.
final class InputSourceThreadingTests: XCTestCase {

    func testBackgroundStatusHopsToMainWithoutAborting() {
        let done = expectation(description: "background status")
        DispatchQueue.global(qos: .userInitiated).async {
            _ = InputSourceProbe.status()
            done.fulfill()
        }
        _ = InputSourceProbe.status()
        wait(for: [done], timeout: 3)
    }
}
