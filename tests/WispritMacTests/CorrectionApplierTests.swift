import XCTest
import WispritCorrections
import WispritDictionary
import WispritKit
@testable import WispritMac

/// The pure directive→text transform. Offsets are CHARACTER offsets, so every
/// case here is written against `Array(text)` indices, matching `LetterRun`.
final class CorrectionApplierTests: XCTestCase {

    private func learned(_ term: String, _ heard: [String]) -> LearnedTerm {
        LearnedTerm(term: term, heard: heard, source: "spoken_spelling")
    }

    /// A learn the plausibility gate has cleared outright — what a merge into
    /// an already-known term produces. `pending: true` is the quarantined form.
    private func proposal(_ term: String, _ heard: [String],
                          pending: Bool = false) -> LearnProposal {
        LearnProposal(term: learned(term, heard), isPending: pending)
    }

    // MARK: - none

    func testNoneLeavesTextExactlyAsItArrived() {
        let outcome = CorrectionApplier.apply(.none, to: "  spaced   out  ")
        XCTAssertEqual(outcome.text, "  spaced   out  ", "no directive means no edit at all")
        XCTAssertNil(outcome.learn)
        XCTAssertNil(outcome.notice)
    }

    // MARK: - insertLiterally

    func testInsertLiterallyReplacesOnlyTheRun() {
        let text = "the payload is J-S-O-N"
        let runRange = text.count - 7 ..< text.count       // "J-S-O-N"
        let outcome = CorrectionApplier.apply(
            .insertLiterally(word: "JSON", replace: runRange,
                             offer: learned("JSON", [])), to: text)

        XCTAssertEqual(outcome.text, "the payload is JSON")
        XCTAssertNil(outcome.learn, "an offer is passive UI — v1 never learns from it")
        XCTAssertNil(outcome.notice)
    }

    func testInsertLiterallyNeverDeletesEarlierWords() {
        // The J-S-O-N regression: a literal insert must not touch "JSON" earlier
        // in the sentence, nor anything before the run.
        let text = "parse the JSON then spell J-S-O-N"
        let runRange = text.count - 7 ..< text.count
        let outcome = CorrectionApplier.apply(
            .insertLiterally(word: "JSON", replace: runRange,
                             offer: learned("JSON", [])), to: text)
        XCTAssertEqual(outcome.text, "parse the JSON then spell JSON")
    }

    // MARK: - tailReplace

    func testTailReplaceDropsTheRunAndRewritesTheAntecedent() {
        let text = "my name is Cherie S-H-A-R-I-Q-U-E"
        let runRange = text.count - 15 ..< text.count      // the spelled tail
        let outcome = CorrectionApplier.apply(
            .tailReplace(target: "Cherie", replacement: "Sharique",
                         suppress: runRange, learn: proposal("Sharique", ["Cherie"])),
            to: text)

        XCTAssertEqual(outcome.text, "my name is Sharique")
        XCTAssertEqual(outcome.learn?.term, "Sharique")
        XCTAssertNil(outcome.notice, "an in-utterance fix is visible; no notice needed")
        XCTAssertFalse(outcome.wasCrossUtterance)
    }

    // MARK: - retroReplace

    func testSameUtteranceRetroReplaceEditsBeforeInsertion() {
        let text = "email Cherie, actually it's S-H-A-R-I-Q-U-E"
        guard let directiveStart = text.range(of: "actually")
            .map({ text.distance(from: text.startIndex, to: $0.lowerBound) }) else {
            return XCTFail("fixture")
        }
        let outcome = CorrectionApplier.apply(
            .retroReplace(target: "Cherie", replacement: "Sharique",
                          suppress: directiveStart..<text.count,
                          learn: proposal("Sharique", ["Cherie"])),
            to: text)

        XCTAssertEqual(outcome.text, "email Sharique,")
        XCTAssertFalse(outcome.wasCrossUtterance)
        XCTAssertNil(outcome.notice)
        XCTAssertEqual(outcome.learn?.heard, ["Cherie"])
    }

    func testCrossUtteranceRetroReplaceLearnsAndNoticesInstead() {
        // The antecedent is NOT in this utterance — it is already committed to
        // some other app's text field, which v1 refuses to touch.
        let text = "actually it's S-H-A-R-I-Q-U-E"
        let outcome = CorrectionApplier.apply(
            .retroReplace(target: "Cherie", replacement: "Sharique",
                          suppress: 0..<text.count,
                          learn: proposal("Sharique", ["Cherie"])),
            to: text)

        XCTAssertEqual(outcome.text, "", "the whole directive is suppressed")
        XCTAssertTrue(outcome.wasCrossUtterance)
        XCTAssertEqual(outcome.notice, "Learned Sharique")
        XCTAssertEqual(outcome.learn?.term, "Sharique")
    }

    // MARK: - the plausibility gate

    /// A merge carries the EXISTING canonical spelling as both the replacement
    /// and the learn, so the dictionary gains a misrecognition rather than a
    /// rival term for the same name.
    func testMergeLearnsTheExistingTermAndNeedsNoProbation() {
        let text = "my name is Sharik S-H-A-R-H-U-U-E"
        let runRange = text.count - 15 ..< text.count
        let outcome = CorrectionApplier.apply(
            .tailReplace(target: "Sharik", replacement: "Sharique",
                         suppress: runRange, learn: proposal("Sharique", ["Sharik"])),
            to: text)

        XCTAssertEqual(outcome.text, "my name is Sharique",
                       "the user gets the spelling they approved, not the mangled run")
        XCTAssertEqual(outcome.learn?.term, "Sharique")
        XCTAssertEqual(outcome.learn?.heard, ["Sharik"])
        XCTAssertFalse(outcome.learnIsPending)
    }

    /// A quarantined learn still edits the visible text — the user just spelled
    /// it — but is flagged for `addPending`, so one utterance cannot mint a
    /// permanent term.
    func testQuarantinedLearnEditsTheTextButIsFlaggedPending() {
        let text = "my name is Cherie K-R-Z-Y-S-Z-T-O-F"
        let runRange = text.count - 17 ..< text.count
        let outcome = CorrectionApplier.apply(
            .tailReplace(target: "Cherie", replacement: "Krzysztof",
                         suppress: runRange, learn: proposal("Krzysztof", ["Cherie"], pending: true)),
            to: text)

        XCTAssertEqual(outcome.text, "my name is Krzysztof")
        XCTAssertEqual(outcome.learn?.term, "Krzysztof")
        XCTAssertTrue(outcome.learnIsPending, "one sighting is not evidence")
    }

    /// The rejected run: the directive goes, nothing is replaced, nothing is
    /// learned, and the user is told rather than handed the ASR's confusion.
    func testAbstainSuppressesTheDirectiveAndLearnsNothing() {
        let text = "email Cherie, actually it's S-H-R-Q-Z"
        guard let directiveStart = text.range(of: "actually")
            .map({ text.distance(from: text.startIndex, to: $0.lowerBound) }) else {
            return XCTFail("fixture")
        }
        let outcome = CorrectionApplier.apply(
            .abstain(suppress: directiveStart..<text.count, reason: .noVowel), to: text)

        XCTAssertEqual(outcome.text, "email Cherie,",
                       "the antecedent survives untouched — abstaining never edits")
        XCTAssertNil(outcome.learn)
        XCTAssertFalse(outcome.learnIsPending)
        XCTAssertEqual(outcome.notice, "Couldn't read that spelling")
        XCTAssertFalse(outcome.wasCrossUtterance)
    }

    /// A directive-only utterance that abstains inserts nothing at all, so the
    /// notice is the whole user-visible outcome.
    func testAbstainOnADirectiveOnlyUtteranceLeavesNothingToInsert() {
        let text = "Actually, it's S-H-R-Q-Z."
        let outcome = CorrectionApplier.apply(
            .abstain(suppress: 0..<(text.count - 1), reason: .noVowel), to: text)
        XCTAssertEqual(outcome.text, "")
        XCTAssertEqual(outcome.notice, "Couldn't read that spelling")
        XCTAssertNil(outcome.learn)
    }

    /// End to end over the real corrector and the real store: the utterance
    /// that wrote "Sharhuue" into `~/.wisprit` must now leave the dictionary
    /// with one Sharique and correct "Sharik" the way it always did.
    func testTheLiveJunkUtteranceNoLongerMintsARivalTerm() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wisprit-gate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        WispritPaths.overrideRoot = root
        defer {
            WispritPaths.overrideRoot = nil
            try? FileManager.default.removeItem(at: root)
        }
        try #"""
        {"terms": [{"term": "Sharique", "hear": ["shariq", "sharik", "shreek"]}]}
        """#.write(to: WispritPaths.dictionaryPath, atomically: true, encoding: .utf8)

        let store = DictionaryStore()
        let corrector = SpokenSpellingCorrector(vocabulary: store)
        let utterance = "Actually, it's S-H-A-R-H-U-U-E."
        let outcome = CorrectionApplier.apply(
            corrector.decide(utterance: utterance, previousUtterance: "Hi Sharik."),
            to: utterance)

        XCTAssertEqual(outcome.learn?.term, "Sharique", "no fourth name for the same person")
        XCTAssertFalse(outcome.learnIsPending)
        store.add(try XCTUnwrap(outcome.learn))

        XCTAssertEqual(store.terms(), ["Sharique"])
        XCTAssertEqual(store.applyCorrections(to: "Hi Sharik how are you"),
                       "Hi Sharique how are you")
    }

    // MARK: - splicing primitives

    func testSpliceClampsOutOfBoundsRangesInsteadOfTrapping() {
        XCTAssertEqual(CorrectionApplier.splice("abc", 1..<99, with: "X"), "aX")
        XCTAssertEqual(CorrectionApplier.splice("abc", -5..<2, with: "X"), "Xc")
        XCTAssertEqual(CorrectionApplier.splice("abc", 5..<9, with: "X"), "abcX")
    }

    func testSpliceUsesCharacterOffsetsNotUTF16() {
        // An emoji is 2 UTF-16 units but 1 Character; the detector counts
        // Characters, so the splice must too.
        let text = "hi 👋 J-S-O-N"
        let outcome = CorrectionApplier.splice(text, 5..<text.count, with: "JSON")
        XCTAssertEqual(outcome, "hi 👋 JSON")
    }

    func testReplaceLastWordIsWholeWordAndCaseInsensitive() {
        XCTAssertEqual(
            CorrectionApplier.replaceLastWord("cherie", with: "Sharique", in: "hi Cherie"),
            "hi Sharique")
        XCTAssertNil(
            CorrectionApplier.replaceLastWord("her", with: "X", in: "another word"),
            "'her' inside 'another' is not a whole word")
        XCTAssertEqual(
            CorrectionApplier.replaceLastWord("a", with: "X", in: "a b a c"),
            "a b X c", "the LAST occurrence wins")
    }

    func testReplaceLastWordReturnsNilWhenAbsent() {
        XCTAssertNil(CorrectionApplier.replaceLastWord("Cherie", with: "Sharique",
                                                       in: "no antecedent here"))
    }

    // MARK: - tidy

    func testTidyCollapsesOnlyWhatTheRemovalCreated() {
        XCTAssertEqual(CorrectionApplier.tidy("email Sharique  ,"), "email Sharique,")
        XCTAssertEqual(CorrectionApplier.tidy("one  two"), "one two")
        XCTAssertEqual(CorrectionApplier.tidy("  padded  "), "padded")
        XCTAssertEqual(CorrectionApplier.tidy("keeps\nnewlines"), "keeps\nnewlines")
    }

    func testTidyDropsPunctuationOnlyDebris() {
        // "Actually, it's S-H-A-R-I-Q-U-E." suppresses everything but the stop.
        XCTAssertEqual(CorrectionApplier.tidy("."), "")
        XCTAssertEqual(CorrectionApplier.tidy(" , "), "")
        XCTAssertEqual(CorrectionApplier.tidy("ok."), "ok.", "real words survive")
    }

    func testDirectiveOnlyUtteranceLeavesNothingToInsert() {
        let text = "Actually, it's S-H-A-R-I-Q-U-E."
        let outcome = CorrectionApplier.apply(
            .retroReplace(target: "Cherie", replacement: "Sharique",
                          suppress: 0..<(text.count - 1),   // everything but the stop
                          learn: proposal("Sharique", ["Cherie"])),
            to: text)
        XCTAssertEqual(outcome.text, "")
        XCTAssertEqual(outcome.notice, "Learned Sharique")
    }
}
