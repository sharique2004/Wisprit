import XCTest
import WispritKit
@testable import WispritRefine

/// The edit-script backend's deterministic half
/// (docs/research/hearing-and-corrections.md, corrections A2). No model here:
/// what is under test is which repairs are ADMISSIBLE, because the whole point
/// of the backend is that paraphrase, obedience, and content deletion are
/// unrepresentable — provided this applier holds the line.
final class EditScriptApplierTests: XCTestCase {

    private func apply(_ edits: [EditScriptEdit], to text: String,
                       terms: Set<String> = []) -> EditScriptApplier.Outcome {
        EditScriptApplier.apply(edits, to: text) { word in
            terms.contains(word.lowercased())
        }
    }

    // MARK: - admissible repairs

    /// (d) A phonetically plausible mishear repair — the backend's bread and
    /// butter, admitted on the cage's own 0.60 paraphrase floor.
    func testAPhoneticMishearRepairLands() {
        let out = apply([.init(find: "get hub", replace: "GitHub")],
                        to: "push it to get hub please")
        XCTAssertEqual(out.text, "push it to GitHub please")
        XCTAssertEqual(out.applied, 1)
    }

    /// (c) The dictionary vouches for a repair the phonetics alone might not.
    func testAKnownTermRepairLands() {
        let out = apply([.init(find: "in forge", replace: "InsForge")],
                        to: "deploy it on in forge now", terms: ["insforge"])
        XCTAssertEqual(out.text, "deploy it on InsForge now")
    }

    /// (a) Filler deletion, with the adjacent space collapsed.
    func testAFillerDeletionLands() {
        let out = apply([.init(find: "um", replace: "")],
                        to: "take um the second exit")
        XCTAssertEqual(out.text, "take the second exit")
    }

    /// (a) Stutter deletion: the twin word sits immediately beside the span.
    func testAStutterDeletionLands() {
        let out = apply([.init(find: "i", replace: "")],
                        to: "i i think that works")
        XCTAssertEqual(out.text, "i think that works")
    }

    /// (b) Casing-only repair.
    func testACasingRepairLands() {
        let out = apply([.init(find: "iphone", replace: "iPhone")],
                        to: "my iphone is charging")
        XCTAssertEqual(out.text, "my iPhone is charging")
    }

    // MARK: - what gets dropped

    /// Content substitution: sounds nothing alike, no dictionary backing.
    /// This is the paraphrase the full-text backend could only catch after
    /// the fact, made unrepresentable.
    func testAContentSubstitutionIsDropped() {
        let out = apply([.init(find: "meeting", replace: "party")],
                        to: "cancel the meeting tonight")
        XCTAssertEqual(out.text, "cancel the meeting tonight")
        XCTAssertEqual(out.dropped, 1)
    }

    /// Content deletion: not a filler, not a stutter — dropped, whatever the
    /// model thought it was doing.
    func testAContentDeletionIsDropped() {
        let out = apply([.init(find: "tonight", replace: "")],
                        to: "cancel the meeting tonight")
        XCTAssertEqual(out.text, "cancel the meeting tonight")
    }

    /// An unanchored find is the model imagining a transcript.
    func testAnUnanchoredFindIsDropped() {
        let out = apply([.init(find: "get hub", replace: "GitHub")],
                        to: "push it to the repository")
        XCTAssertEqual(out.text, "push it to the repository")
        XCTAssertEqual(out.dropped, 1)
    }

    /// The find must sit on word boundaries — a substring inside a word is
    /// not a quote of the transcript.
    func testAMidWordAnchorIsRefused() {
        let out = apply([.init(find: "cat", replace: "kata")],
                        to: "the category is wrong")
        XCTAssertEqual(out.text, "the category is wrong")
    }

    /// More than four words of find is a rewrite wearing an edit's clothes.
    func testAnOversizedFindIsDropped() {
        let out = apply([.init(find: "cancel the meeting tonight please",
                               replace: "keep the meeting tonight please")],
                        to: "cancel the meeting tonight please and thanks")
        XCTAssertEqual(out.text, "cancel the meeting tonight please and thanks")
    }

    /// The edit budget: nine edits in, at most eight even considered.
    func testTheEditBudgetIsEnforced() {
        let edits = (0..<9).map { EditScriptEdit(find: "word\($0)", replace: "") }
        let out = apply(edits, to: "nothing here matches")
        XCTAssertEqual(out.applied, 0)
        XCTAssertEqual(out.dropped, 9)
    }

    /// A deletion of a word that merely EXISTS elsewhere is not a stutter —
    /// the twin must be adjacent.
    func testANonAdjacentTwinIsNotAStutter() {
        let out = apply([.init(find: "think", replace: "")],
                        to: "i think you should think again")
        XCTAssertEqual(out.text, "i think you should think again")
    }

    // MARK: - mechanics

    func testEditsApplySequentiallyAndFirstOccurrenceOnly() {
        let out = apply([
            .init(find: "um", replace: ""),
            .init(find: "get hub", replace: "GitHub"),
        ], to: "um push to get hub and get hub again")
        XCTAssertEqual(out.text, "push to GitHub and get hub again")
        XCTAssertEqual(out.applied, 2)
    }

    func testWhitespaceRelaxedAnchoring() {
        let out = apply([.init(find: "get  hub", replace: "GitHub")],
                        to: "push to get hub now")
        XCTAssertEqual(out.text, "push to GitHub now")
    }

    func testAnEmptyScriptIsANoOp() {
        let out = apply([], to: "already clean")
        XCTAssertEqual(out.text, "already clean")
        XCTAssertEqual(out.applied, 0)
        XCTAssertEqual(out.dropped, 0)
    }
}
