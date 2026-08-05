import XCTest
@testable import WispritMacUI

/// Pure-logic tests for the live-partial tail. No windows, no run loop.
final class PartialTailTests: XCTestCase {

    func testEmptyAndWhitespaceOnlyYieldNothing() {
        XCTAssertEqual(PartialTail.tail(of: ""), "")
        XCTAssertEqual(PartialTail.tail(of: "   \n\t "), "")
    }

    func testKeepsLastThreeWordsByDefault() {
        XCTAssertEqual(
            PartialTail.tail(of: "the quick brown fox jumps over the lazy dog"),
            "the lazy dog")
    }

    func testShorterThanBudgetIsShownWhole() {
        XCTAssertEqual(PartialTail.tail(of: "hello there"), "hello there")
        XCTAssertEqual(PartialTail.tail(of: "hello"), "hello")
    }

    func testNewlinesAndRunsOfSpacesCollapse() {
        XCTAssertEqual(PartialTail.tail(of: "new\nparagraph   here"), "new paragraph here")
    }

    /// The engine feeds monotonically growing text; each successive tail must be
    /// a sensible window over the newest words.
    func testMonotonicGrowthWindowsForward() {
        let stream = ["one", "one two", "one two three", "one two three four"]
        let tails = stream.map { PartialTail.tail(of: $0) }
        XCTAssertEqual(tails, ["one", "one two", "one two three", "two three four"])
    }

    func testDropsLeadingWordsWhenOverCharacterBudget() {
        // Three words would be 30 chars; the oldest is dropped to fit 26.
        let t = PartialTail.tail(of: "alpha internationalisation beta")
        XCTAssertEqual(t, "internationalisation beta")
        XCTAssertLessThanOrEqual(t.count, PartialTail.defaultMaxCharacters)
    }

    func testSingleOverlongWordIsTruncatedHeadFirst() {
        let t = PartialTail.tail(of: "pneumonoultramicroscopicsilicovolcanoconiosis")
        XCTAssertEqual(t.count, PartialTail.defaultMaxCharacters)
        XCTAssertTrue(t.hasSuffix("…"))
        XCTAssertTrue(t.hasPrefix("pneumono"))
    }

    func testCustomBudgets() {
        XCTAssertEqual(PartialTail.tail(of: "a b c d e", maxWords: 2), "d e")
        XCTAssertEqual(PartialTail.tail(of: "a b c d e", maxWords: 0), "e")   // clamped to 1
    }

    func testNoticeFlattensAndClips() {
        XCTAssertEqual(PartialTail.notice("Learned Sharique"), "Learned Sharique")
        XCTAssertEqual(PartialTail.notice("Learned\n Sharique"), "Learned Sharique")
        let long = PartialTail.notice(String(repeating: "x", count: 80))
        XCTAssertEqual(long.count, PartialTail.defaultMaxCharacters)
        XCTAssertTrue(long.hasSuffix("…"))
    }
}
