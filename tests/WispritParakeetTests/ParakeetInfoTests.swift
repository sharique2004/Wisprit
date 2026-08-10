import XCTest
@testable import WispritParakeet

final class ParakeetInfoTests: XCTestCase {
    func testPinIsRecorded() {
        XCTAssertEqual(ParakeetInfo.fluidAudioRevision.count, 40)
    }
}
