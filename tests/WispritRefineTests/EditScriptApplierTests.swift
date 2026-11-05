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

    /// High confidence drops a substitution that is not a dictionary term.
    /// The logging bucket is not this gate; the gate constant is.
    func testAHighConfidenceSubstitutionIsDroppedUnlessItIsAKnownTerm() {
        let runs = [TranscriptionConfidenceRun(utf16Location: 0, utf16Length: 64, confidence: 0.99)]
        let constraints = EditConstraints(runs: runs)
        let dropped = EditScriptApplier.apply(
            [.init(find: "get hub", replace: "GitHub")],
            to: "push it to get hub please",
            isKnownTerm: { _ in false },
            constraints: constraints)
        XCTAssertEqual(dropped.text, "push it to get hub please")
        XCTAssertEqual(dropped.dropped, 1)

        let kept = EditScriptApplier.apply(
            [.init(find: "in forge", replace: "InsForge")],
            to: "deploy it on in forge now",
            isKnownTerm: { $0.lowercased() == "insforge" },
            constraints: constraints)
        XCTAssertEqual(kept.text, "deploy it on InsForge now")
    }

    /// Filler deletion is unconditional, even when the span is entirely confident.
    func testAFillerDeletionIgnoresConfidence() {
        let runs = [TranscriptionConfidenceRun(utf16Location: 0, utf16Length: 64, confidence: 0.99)]
        let out = EditScriptApplier.apply(
            [.init(find: "um", replace: "")],
            to: "take um the second exit",
            isKnownTerm: { _ in false },
            constraints: EditConstraints(runs: runs))
        XCTAssertEqual(out.text, "take the second exit")
    }

    /// Agreement spans are untouchable. A disagreement is eligible when it
    /// fails the confidence gate, or when the reconciler would already accept it.
    func testAgreementSpansAreUntouchableAndDisagreementsAreGated() {
        let live = "Ping the in forge team about the timeline."
        let tokens = [
            TranscriptAgreement.Token(utf16: 0..<4, agreed: true),   // Ping
            TranscriptAgreement.Token(utf16: 9..<11, agreed: false), // in
            TranscriptAgreement.Token(utf16: 12..<17, agreed: false), // forge
        ]
        let agreement = TranscriptAgreement(
            tokens: tokens,
            accepted: [TranscriptAgreement.Accepted(find: "in forge", replacement: "InsForge")])
        let high = [TranscriptionConfidenceRun(utf16Location: 0, utf16Length: 64, confidence: 0.99)]
        let kept = EditScriptApplier.apply(
            [.init(find: "in forge", replace: "InsForge")],
            to: live,
            isKnownTerm: { _ in false },
            constraints: EditConstraints(runs: high, agreement: agreement))
        XCTAssertEqual(kept.text, "Ping the InsForge team about the timeline.")

        let blocked = EditScriptApplier.apply(
            [.init(find: "Ping", replace: "Ring")],
            to: live,
            isKnownTerm: { _ in true },
            constraints: EditConstraints(runs: high, agreement: agreement))
        XCTAssertEqual(blocked.text, live, "an agreement span is untouchable even for a known term")
    }

    /// A spelled run is not an edit opportunity, even if a peer would rather
    /// see the collapsed word.
    func testASpelledRunIsNotAnEditOpportunity() {
        let text = "The payload is J-S-O-N, not YAML."
        let out = EditScriptApplier.apply(
            [.init(find: "J-S-O-N", replace: "JSON")],
            to: text,
            isKnownTerm: { _ in true },
            constraints: EditConstraints(
                runs: [TranscriptionConfidenceRun(utf16Location: 0, utf16Length: 8, confidence: 0.1)],
                agreement: TranscriptAgreement(tokens: [], accepted: [
                    TranscriptAgreement.Accepted(find: "J-S-O-N", replacement: "JSON")
                ])))
        XCTAssertEqual(out.text, text)
        XCTAssertEqual(out.applied, 0)
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
