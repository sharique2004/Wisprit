import XCTest
@testable import WispritMacInput

/// Byte-for-byte parity with the Python this target ports. The expectations in
/// `GoldenFixtures.swift` were produced by running `wisprit/insert.py` and
/// `wisprit/hotkey.py` themselves (see the generator path in that file's
/// header), so a failure here is a genuine divergence, not a taste difference.
final class GoldenParityTests: XCTestCase {

    /// `insert._utf16_chunks(text, 20)`.
    func testChunkingMatchesPython() {
        XCTAssertFalse(Golden.chunkCases.isEmpty)
        for case_ in Golden.chunkCases {
            let swift = UnicodeChunker.chunks(case_.text)
            XCTAssertEqual(swift, case_.chunks,
                           "chunking diverged for \(case_.text.debugDescription)")
            XCTAssertEqual(swift.joined(), case_.text)
        }
    }

    /// `hotkey.HotkeyListener._callback`, replayed step by step. The Python was
    /// driven with synthetic CGEvents — no tap installed, nothing posted.
    func testGestureEmissionsMatchPython() {
        XCTAssertFalse(Golden.hotkeyCases.isEmpty)
        for case_ in Golden.hotkeyCases {
            let machine = HotkeyStateMachine(trigger: case_.trigger)
            machine.setRecording(case_.recording)
            var emitted: [HotkeyEventKind] = []
            for step in case_.steps {
                emitted.append(contentsOf: machine.handle(step).emits)
            }
            XCTAssertEqual(emitted, case_.emits, "gesture diverged for \"\(case_.name)\"")
        }
    }

    /// Every tap-disabled step must ask for a re-enable, which the Python does
    /// inline in the callback (`CGEventTapEnable(self._tap, True)`) and so
    /// cannot express as a queue emission.
    func testTapDisabledAlwaysRequestsReenable() {
        var seen = 0
        for case_ in Golden.hotkeyCases {
            let machine = HotkeyStateMachine(trigger: case_.trigger)
            for step in case_.steps {
                let decision = machine.handle(step)
                if case .tapDisabled = step {
                    XCTAssertTrue(decision.reenableTap, case_.name)
                    seen += 1
                } else {
                    XCTAssertFalse(decision.reenableTap, case_.name)
                }
            }
        }
        XCTAssertGreaterThanOrEqual(seen, 4)
    }
}
