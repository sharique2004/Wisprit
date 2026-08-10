import XCTest
@testable import WispritEval

final class EvalInfoTests: XCTestCase {
    func testScorerVersionIsStamped() {
        XCTAssertGreaterThanOrEqual(EvalInfo.scorerVersion, 1)
    }
}
