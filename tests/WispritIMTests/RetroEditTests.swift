import XCTest
import WispritIMProtocol
@testable import WispritIM

/// Range arithmetic in isolation. Every abort case here is a case where guessing
/// would have corrupted something the user wrote.
final class RetroEditTests: XCTestCase {

    private func plan(_ replace: String,
                      _ with: String,
                      committed: String,
                      at location: Int,
                      document: String,
                      base: Int = 0) -> RetroEditPlan {
        RetroEditPlanner.plan(
            edit: IMEdit(replace: replace, with: with),
            committed: committed,
            committedRange: NSRange(location: location, length: (committed as NSString).length),
            window: IMDocumentWindow(text: document, base: base))
    }

    func testFindsTheWordAtItsAbsoluteDocumentRange() {
        let result = plan("Sharik", "Sharique",
                          committed: "Hi Sharik.", at: 6,
                          document: "user: Hi Sharik.")

        XCTAssertEqual(result, .replace(range: NSRange(location: 9, length: 6),
                                        text: "Sharique",
                                        newCommitted: "Hi Sharique.",
                                        newCommittedRange: NSRange(location: 6, length: 12)))
    }

    func testTakesTheLastOccurrenceInsideOurOwnRun() {
        let result = plan("fox", "cat",
                          committed: "a fox saw a fox", at: 0,
                          document: "a fox saw a fox")

        guard case .replace(let range, _, let newCommitted, _) = result else {
            return XCTFail("expected a replacement, got \(result)")
        }
        XCTAssertEqual(range, NSRange(location: 12, length: 3))
        XCTAssertEqual(newCommitted, "a fox saw a cat")
    }

    func testIgnoresOccurrencesOutsideOurRun() {
        // "fox" also appears in the user's own text before our run.
        let result = plan("fox", "cat",
                          committed: " and a fox", at: 11,
                          document: "the quick fox and a fox")

        guard case .replace(let range, _, _, _) = result else {
            return XCTFail("expected a replacement, got \(result)")
        }
        XCTAssertEqual(range, NSRange(location: 20, length: 3))
    }

    func testHonoursTheWindowBaseWhenTheClientReturnsASlice() {
        // Chromium serves a cached window around the selection: the text we get
        // starts at document offset 100, so every offset must be biased by it.
        let result = plan("Sharik", "Sharique",
                          committed: "Hi Sharik.", at: 100,
                          document: "Hi Sharik.", base: 100)

        guard case .replace(let range, _, _, let newRange) = result else {
            return XCTFail("expected a replacement, got \(result)")
        }
        XCTAssertEqual(range, NSRange(location: 103, length: 6))
        XCTAssertEqual(newRange, NSRange(location: 100, length: 12))
    }

    func testRelocatesWhenTheRunMovedButIsStillUnique() {
        let result = plan("Sharik", "Sharique",
                          committed: "Hi Sharik.", at: 0,          // stale offset
                          document: "typed above\nHi Sharik.")

        guard case .replace(let range, _, _, _) = result else {
            return XCTFail("expected a replacement, got \(result)")
        }
        XCTAssertEqual(range, NSRange(location: 15, length: 6))
    }

    func testAbortsWhenTheRunIsGone() {
        XCTAssertEqual(plan("Sharik", "Sharique",
                            committed: "Hi Sharik.", at: 0,
                            document: "the user replaced everything"),
                       .abort(.fieldChanged))
    }

    func testAbortsWhenTheRunIsAmbiguous() {
        XCTAssertEqual(plan("Sharik", "Sharique",
                            committed: "Hi Sharik.", at: 99,
                            document: "Hi Sharik. Hi Sharik."),
                       .abort(.ambiguousRelocation))
    }

    func testAbortsWhenTheTargetWordIsNotInOurRun() {
        XCTAssertEqual(plan("Krzysztof", "Christopher",
                            committed: "Hi Sharik.", at: 0,
                            document: "Hi Sharik."),
                       .abort(.targetNotFound))
    }

    func testAbortsOnAnEmptyTarget() {
        XCTAssertEqual(plan("", "Sharique",
                            committed: "Hi Sharik.", at: 0,
                            document: "Hi Sharik."),
                       .abort(.emptyEdit))
    }

    func testAbortsWhenNothingHasBeenCommitted() {
        XCTAssertEqual(plan("Sharik", "Sharique",
                            committed: "", at: 0,
                            document: "Hi Sharik."),
                       .abort(.targetNotFound))
    }

    func testAbortsWhenTheDocumentCannotBeRead() {
        let result = RetroEditPlanner.plan(edit: IMEdit(replace: "a", with: "b"),
                                           committed: "a",
                                           committedRange: NSRange(location: 0, length: 1),
                                           window: nil)
        XCTAssertEqual(result, .abort(.readFailed))
    }

    func testEmojiAndAccentsKeepUTF16RangesHonest() {
        // "👋" is two UTF-16 units; a Character-based index here would be off by one
        // and would slice the surrogate pair in half.
        let result = plan("Sharik", "Sharique",
                          committed: "👋 Sharik", at: 0,
                          document: "👋 Sharik")

        guard case .replace(let range, _, let newCommitted, _) = result else {
            return XCTFail("expected a replacement, got \(result)")
        }
        XCTAssertEqual(range, NSRange(location: 3, length: 6))
        XCTAssertEqual(newCommitted, "👋 Sharique")
    }
}
