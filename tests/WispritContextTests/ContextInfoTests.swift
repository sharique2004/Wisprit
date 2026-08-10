import XCTest
@testable import WispritContext

final class ContextInfoTests: XCTestCase {
    func testExtractorVersionIsStamped() {
        XCTAssertGreaterThanOrEqual(ContextInfo.extractorVersion, 1)
    }
}
