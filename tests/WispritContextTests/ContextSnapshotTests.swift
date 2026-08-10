import XCTest

@testable import WispritContext

/// Snapshots flow through session logging and metrics plumbing; if one is ever
/// interpolated into a log line, the user's document must not go with it.
final class ContextSnapshotTests: XCTestCase {

    private let snapshot = ContextSnapshot(
        bundleID: "com.apple.TextEdit",
        before: "SENTINEL-BEFORE correct horse battery staple",
        selected: "SENTINEL-SELECTED hunter2",
        after: "SENTINEL-AFTER my ssn is 078-05-1120",
        capturedAt: Date(timeIntervalSince1970: 1_754_700_000),
        generation: 7)

    func testDescriptionNeverContainsFieldText() {
        for rendered in [String(describing: snapshot), String(reflecting: snapshot)] {
            XCTAssertFalse(rendered.contains("SENTINEL"), rendered)
            XCTAssertFalse(rendered.contains("hunter2"), rendered)
            XCTAssertFalse(rendered.contains("staple"), rendered)
            XCTAssertFalse(rendered.contains("078-05-1120"), rendered)
        }
    }

    func testDescriptionKeepsShapeAndBookkeeping() {
        let rendered = String(describing: snapshot)
        XCTAssertTrue(rendered.contains("com.apple.TextEdit"), rendered)
        XCTAssertTrue(rendered.contains("44 chars"), rendered)  // before
        XCTAssertTrue(rendered.contains("generation: 7"), rendered)
    }
}
