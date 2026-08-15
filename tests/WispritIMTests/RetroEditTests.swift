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
                      base: Int = 0,
                      anchor: Int? = nil) -> RetroEditPlan {
        RetroEditPlanner.plan(
            edit: IMEdit(replace: replace, with: with, utf16LocationInCommitted: anchor),
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
                                        newCommittedRange: NSRange(location: 6, length: 12),
                                        appliedUtf16LocationInCommitted: 3))
    }

    func testTakesTheLastOccurrenceInsideOurOwnRun() {
        // The rule when nobody says which one — unchanged, and load-bearing:
        // the spoken-spelling path means exactly "the most recent mention".
        let result = plan("fox", "cat",
                          committed: "a fox saw a fox", at: 0,
                          document: "a fox saw a fox")

        guard case .replace(let range, _, let newCommitted, _, let applied) = result else {
            return XCTFail("expected a replacement, got \(result)")
        }
        XCTAssertEqual(range, NSRange(location: 12, length: 3))
        XCTAssertEqual(newCommitted, "a fox saw a cat")
        XCTAssertEqual(applied, 12, "the fallback echoes where it landed too")
    }

    func testIgnoresOccurrencesOutsideOurRun() {
        // "fox" also appears in the user's own text before our run.
        let result = plan("fox", "cat",
                          committed: " and a fox", at: 11,
                          document: "the quick fox and a fox")

        guard case .replace(let range, _, _, _, _) = result else {
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

        guard case .replace(let range, _, _, let newRange, _) = result else {
            return XCTFail("expected a replacement, got \(result)")
        }
        XCTAssertEqual(range, NSRange(location: 103, length: 6))
        XCTAssertEqual(newRange, NSRange(location: 100, length: 12))
    }

    func testRelocatesWhenTheRunMovedButIsStillUnique() {
        let result = plan("Sharik", "Sharique",
                          committed: "Hi Sharik.", at: 0,          // stale offset
                          document: "typed above\nHi Sharik.")

        guard case .replace(let range, _, _, _, _) = result else {
            return XCTFail("expected a replacement, got \(result)")
        }
        XCTAssertEqual(range, NSRange(location: 15, length: 6))
    }

    // MARK: - anchoring: the occurrence the caller MEANT

    /// The defect, at the layer that caused it. One IM session spans several
    /// utterances, so "a fox saw a fox" is an ordinary committed run; before
    /// the anchor existed, an edit aimed at the FIRST fox could only ever
    /// rewrite the second.
    func testAnAnchoredEditFixesTheFirstOccurrenceNotTheLast() {
        let result = plan("fox", "cat",
                          committed: "a fox saw a fox", at: 0,
                          document: "a fox saw a fox",
                          anchor: 2)

        XCTAssertEqual(result, .replace(range: NSRange(location: 2, length: 3),
                                        text: "cat",
                                        newCommitted: "a cat saw a fox",
                                        newCommittedRange: NSRange(location: 0, length: 15),
                                        appliedUtf16LocationInCommitted: 2))
    }

    /// The anchor is relative to OUR RUN, never to the document — which is why
    /// it survives both of the things that move a run: the user typing above it
    /// and a client that hands back a slice starting somewhere else.
    func testTheAnchorSurvivesUserTypingAboveTheRunAndANonZeroWindowBase() {
        let result = plan("fox", "cat",
                          committed: "a fox saw a fox", at: 0,
                          document: "typed above\na fox saw a fox",
                          base: 100, anchor: 2)

        guard case .replace(let range, _, let newCommitted, let newRange, _) = result else {
            return XCTFail("expected a replacement, got \(result)")
        }
        XCTAssertEqual(range, NSRange(location: 114, length: 3),
                       "base 100 + run at 12 in the window + 2 inside the run")
        XCTAssertEqual(newCommitted, "a cat saw a fox")
        XCTAssertEqual(newRange, NSRange(location: 112, length: 15))
    }

    /// Every way an offset can be wrong, and the single answer to all of them:
    /// resolve it the way we did before anchors existed. A mirror that drifted
    /// from the input method's record must cost the user the old behaviour, not
    /// a rewrite of a word they meant to keep.
    func testAnOffsetTheRecordDoesNotBearOutFallsBackToTheLastOccurrence() {
        let committed = "a fox saw a fox"
        for (name, anchor) in [("points at the wrong characters", 1),
                               ("past the end of the record", 14),
                               ("wildly out of bounds", 9_000),
                               ("negative", -1)] {
            let result = plan("fox", "cat", committed: committed, at: 0,
                              document: committed, anchor: anchor)
            guard case .replace(let range, _, let newCommitted, _, let applied) = result else {
                return XCTFail("\(name): expected a replacement, got \(result)")
            }
            XCTAssertEqual(range, NSRange(location: 12, length: 3), name)
            XCTAssertEqual(newCommitted, "a fox saw a cat", name)
            XCTAssertEqual(applied, 12, "\(name): the echo names where it really landed")
        }
    }

    /// An anchored target that is not in the run at all is still
    /// `targetNotFound` — the anchor cannot conjure a match, only choose among
    /// real ones.
    func testAnAnchoredEditForAWordWeNeverCommittedStillAborts() {
        XCTAssertEqual(plan("Krzysztof", "Christopher",
                            committed: "Hi Sharik.", at: 0,
                            document: "Hi Sharik.", anchor: 3),
                       .abort(.targetNotFound))
    }

    /// The anchor is a hint about WHICH occurrence, never a licence to skip the
    /// liveness check: a field somebody else rewrote still aborts.
    func testAnAnchorDoesNotOverrideTheAbortDiscipline() {
        XCTAssertEqual(plan("fox", "cat", committed: "a fox saw a fox", at: 0,
                            document: "the user replaced everything", anchor: 2),
                       .abort(.fieldChanged))
        XCTAssertEqual(plan("fox", "cat", committed: "a fox saw a fox", at: 0,
                            document: "a fox saw a fox a fox saw a fox", anchor: 2),
                       .abort(.ambiguousRelocation))
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

        guard case .replace(let range, _, let newCommitted, _, let applied) = result else {
            return XCTFail("expected a replacement, got \(result)")
        }
        XCTAssertEqual(range, NSRange(location: 3, length: 6))
        XCTAssertEqual(newCommitted, "👋 Sharique")
        XCTAssertEqual(applied, 3)
    }

    /// The anchor crosses the wire in UTF-16, so a surrogate pair ahead of the
    /// target has to be counted as the two units it is. A grapheme-cluster
    /// count would arrive one short here and land the edit inside "Sharik"
    /// instead of on it — where the substring check would refuse it and the
    /// fallback would quietly fix the WRONG one of the two.
    func testASurrogatePairAheadOfTheTargetIsCountedInUTF16() {
        let committed = "👋 Sharik and Sharik"
        let result = plan("Sharik", "Sharique", committed: committed, at: 0,
                          document: committed, anchor: 3)

        guard case .replace(let range, _, let newCommitted, _, let applied) = result else {
            return XCTFail("expected a replacement, got \(result)")
        }
        XCTAssertEqual(range, NSRange(location: 3, length: 6))
        XCTAssertEqual(newCommitted, "👋 Sharique and Sharik", "the FIRST one")
        XCTAssertEqual(applied, 3)
    }
}
