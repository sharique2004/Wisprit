import XCTest
import WispritKit

@testable import WispritCorrections

/// The gate that decides whether the second engine's reading is allowed to
/// rewrite text the user is already looking at.
///
/// The table below is the whole contract: one row per gate, each one a sentence
/// the two engines could plausibly disagree about, and the verdict that
/// disagreement has to earn. The refusals matter more than the acceptance —
/// this planner's job is to say no to almost everything DictationTranscriber
/// thinks, and only ever say yes to a dictionary term it recovered.
final class VocabularyReconcilerTests: XCTestCase {

    private struct Case {
        let name: String
        let inserted: String
        let reconciled: String
        var termHits: [String: Int] = ["InsForge": 1]
        /// Canonical terms the dictionary already holds.
        var known: [String] = []
        /// `(replace, with)` for every edit expected, in order.
        var edits: [(String, String)] = []
        var refusal: VocabularyRetroRefusal?
        var limits = VocabularyReconciler.Limits()
    }

    private func run(_ testCase: Case, file: StaticString = #filePath, line: UInt = #line) {
        let known = Set(testCase.known.map { $0.lowercased() })
        let plan = VocabularyReconciler.plan(
            inserted: testCase.inserted,
            reconciled: testCase.reconciled,
            termHits: testCase.termHits,
            knownTerm: { known.contains($0.lowercased()) },
            limits: testCase.limits)

        XCTAssertEqual(plan.edits.map(\.replace), testCase.edits.map(\.0),
                       "\(testCase.name): replace", file: file, line: line)
        XCTAssertEqual(plan.edits.map(\.with), testCase.edits.map(\.1),
                       "\(testCase.name): with", file: file, line: line)
        XCTAssertEqual(plan.refusal, testCase.refusal,
                       "\(testCase.name): refusal", file: file, line: line)
        for edit in plan.edits {
            // The single hardest requirement on the output: `RetroEditPlanner`
            // searches the live document for `replace` LITERALLY, so anything
            // rebuilt from tokens rather than sliced out is simply never found.
            XCTAssertTrue(testCase.inserted.contains(edit.replace),
                          "\(testCase.name): \(edit.replace) is not a substring of the inserted text",
                          file: file, line: line)
            XCTAssertGreaterThanOrEqual(edit.score, testCase.limits.minScore,
                                        "\(testCase.name): score", file: file, line: line)
        }
    }

    // MARK: - the one thing it says yes to

    func testTheTable() {
        let cases: [Case] = [

            // A real dictionary term, misheard as two ordinary words by the live
            // engine and recovered by the biased one. This single row is the
            // entire reason the file exists.
            Case(name: "single-term fix",
                 inserted: "Ping the in forge team about the migration.",
                 reconciled: "Ping the InsForge team about the migration.",
                 edits: [("in forge", "InsForge")]),

            // A canonical term that is genuinely two words, misheard as two
            // different words. Gate 1 matches the block WHOLE, so both live
            // tokens go in one edit rather than becoming two half-corrections.
            Case(name: "multi-word term",
                 inserted: "Please email cherie catri about the invoice today",
                 reconciled: "Please email Sharique Khatri about the invoice today",
                 termHits: ["Sharique Khatri": 1],
                 edits: [("cherie catri", "Sharique Khatri")]),

            // Ranges are indices into the CHARACTER array, so an emoji sitting
            // immediately before the block cannot shift the slice — which a
            // UTF-16 offset would have done, by one, silently.
            Case(name: "unicode safety",
                 inserted: "Ping the 🚀 in forge team about the café today",
                 reconciled: "Ping the 🚀 InsForge team about the café today",
                 edits: [("in forge", "InsForge")]),

            // MARK: - refusals

            // Two different sentences. Nothing inside them is comparable, so
            // nothing inside them is actionable — including the block that would
            // otherwise have looked like a clean term recovery.
            Case(name: "wholly divergent",
                 inserted: "Ping the in forge team about the migration.",
                 reconciled: "InsForge shipped a new build on Tuesday.",
                 refusal: .divergent),

            // THE structural promise. The second engine dropped a word; dropping
            // it from the user's document is never a dictionary recovery, so
            // there is no threshold that could let this through.
            Case(name: "pure delete",
                 inserted: "Ping the InsForge team about the big migration.",
                 reconciled: "Ping the InsForge team about the migration.",
                 refusal: .pureDelete),

            // The mirror image: words the user never said do not get typed in
            // after the fact, however confident the second engine is.
            Case(name: "pure insert",
                 inserted: "Ping the InsForge team about the migration.",
                 reconciled: "Ping the InsForge team about the big migration.",
                 refusal: .pureInsert),

            // The two engines simply chose different words. That is a word
            // choice, not evidence, and word choices are not this pass's
            // business no matter how they align.
            Case(name: "non-dictionary block",
                 inserted: "Ping the InsForge team about the schedule.",
                 reconciled: "Ping the InsForge team about the timetable.",
                 refusal: .notADictionaryTerm),

            // The reconciled side IS a dictionary term, and the live side sounds
            // nothing like it (0.41). A biased engine that hears a term where a
            // different word was said is hallucinating its own bias.
            Case(name: "phonetically unrelated",
                 inserted: "Ping the migration team about the timeline.",
                 reconciled: "Ping the InsForge team about the timeline.",
                 refusal: .phoneticallyUnrelated),

            // The ALIX/WellX incident of 2026-08-12, arriving through the retro
            // channel instead of the learn gate: Double Metaphone codes Alex and
            // WellX identically (ALKS), so the biased pass "recovering" its own
            // contextual string scores 0.869 — over every other bar in this
            // file — while the letters agree almost nowhere (0.400). Accepting
            // it would rename the user's colleague in a document they are
            // already reading.
            Case(name: "phonetic twin of an ordinary word",
                 inserted: "Please email Alex about the invoice today",
                 reconciled: "Please email WellX about the invoice today",
                 termHits: ["WellX": 1],
                 refusal: .orthographicallyDistant),

            // The other half of the veto, and the reason it carries the learn
            // gate's matching-initial escape verbatim: "shreek" is a REAL hear
            // phrase of Sharique (tools/eval/fixtures/eval-dictionary.json) and
            // sits at 0.375, well under the floor. Only the shared 's' keeps
            // this recovery alive.
            Case(name: "garbled but same initial",
                 inserted: "Please email shreek about the invoice today",
                 reconciled: "Please email Sharique about the invoice today",
                 termHits: ["Sharique": 1],
                 edits: [("shreek", "Sharique")]),

            // Only the SPACING differs. DictationTranscriber's opinions about
            // whitespace are not evidence, and rewriting the user's document to
            // impose one is exactly the surprise that erodes trust.
            Case(name: "already correct",
                 inserted: "Ping the Ins Forge team about the migration.",
                 reconciled: "Ping the InsForge team about the migration.",
                 refusal: .alreadyCorrect),

            // "Sherry" and "Sharique" are two people. The live engine picked one,
            // the biased engine preferred the other, and they score 0.65 — over
            // the phonetic bar. The only thing standing between the user and a
            // renamed colleague is that Sherry is already in the dictionary.
            Case(name: "known term is never overwritten",
                 inserted: "Please email Sherry about the invoice today",
                 reconciled: "Please email Sharique about the invoice today",
                 termHits: ["Sharique": 1],
                 known: ["Sherry", "Sharique"],
                 refusal: .knownTerm),

            // Four live tokens score 0.91 against the term — comfortably over
            // every other bar. The length limit is what refuses it: at four words
            // a "misrecognition" is a rewrite.
            Case(name: "block longer than three tokens",
                 inserted: "Ping the in ess for j team about it today",
                 reconciled: "Ping the InsForge team about it today",
                 refusal: .blockTooLong),

            // At the very start of the text there is no context on the outside,
            // so the inside has to carry it — and here exactly one agreed token
            // separates this block from the next disagreement.
            Case(name: "not enough anchors at a text boundary",
                 inserted: "in forge team of the migration and the launch and the rest",
                 reconciled: "InsForge team for the migration and the launch and the rest",
                 refusal: .noAnchor),

            // The pass recovered no term at all, which is the common case: there
            // is then nothing this planner is permitted to propose.
            Case(name: "no term hits",
                 inserted: "Ping the in forge team about the migration.",
                 reconciled: "Ping the in forge team about the migration.",
                 termHits: [:],
                 refusal: .noTermHits),

            Case(name: "identical readings",
                 inserted: "Ping the InsForge team about the migration.",
                 reconciled: "Ping the InsForge team about the migration.",
                 refusal: .aligned),

            Case(name: "nothing was inserted",
                 inserted: "",
                 reconciled: "Ping the InsForge team about the migration.",
                 refusal: .noText),
        ]

        for testCase in cases { run(testCase) }
    }

    // MARK: - the per-utterance cap

    /// Three recoverable terms in one utterance. Two is already a lot of a
    /// user's paragraph to rewrite behind their back, so the third waits.
    func testAtMostTwoEditsPerUtterance() {
        let inserted = "We tested in forge then whisper it plus clawed on Monday morning "
            + "with the whole team today"
        let reconciled = "We tested InsForge then Wisprit plus Claude on Monday morning "
            + "with the whole team today"
        let hits = ["InsForge": 1, "Wisprit": 1, "Claude": 1]

        let capped = VocabularyReconciler.plan(
            inserted: inserted, reconciled: reconciled, termHits: hits, knownTerm: { _ in false })
        XCTAssertEqual(capped.edits.map(\.replace), ["in forge", "whisper it"])
        XCTAssertEqual(capped.edits.map(\.with), ["InsForge", "Wisprit"])
        XCTAssertNil(capped.refusal, "edits were accepted, so nothing was refused")

        // …and the third really was recoverable — the cap is a policy, not a
        // side effect of the third block failing a gate.
        let uncapped = VocabularyReconciler.plan(
            inserted: inserted, reconciled: reconciled, termHits: hits,
            knownTerm: { _ in false },
            limits: VocabularyReconciler.Limits(maxEdits: 3))
        XCTAssertEqual(uncapped.edits.map(\.with), ["InsForge", "Wisprit", "Claude"])
    }

    // MARK: - the gates as numbers

    func testThePhoneticBarIsTheAntecedentMatchersOwnThreshold() {
        XCTAssertEqual(VocabularyReconciler.Limits().minScore, AntecedentMatcher.threshold,
                       "one calibrated 'related' bar, used by both correction paths")
    }

    /// The refused rows above have to be refused for the reason claimed, not by
    /// accident of a bar they were never near.
    func testTheRefusedBlocksClearEveryGateExceptTheirOwn() {
        XCTAssertGreaterThanOrEqual(PhoneticScorer.score("sherry", "Sharique"),
                                    VocabularyReconciler.Limits().minScore,
                                    "the known-term row is refused by the dictionary, not the scorer")
        XCTAssertGreaterThanOrEqual(PhoneticScorer.score("in ess for j", "InsForge"),
                                    VocabularyReconciler.Limits().minScore,
                                    "the long-block row is refused by its length, not the scorer")
        XCTAssertLessThan(PhoneticScorer.score("migration", "InsForge"),
                          VocabularyReconciler.Limits().minScore)
    }

    // MARK: - the orthographic veto (commit 88668c5, ALIX/WellX)

    /// One floor for both places a dictionary term may overwrite a word the user
    /// actually said. The learn gate got this after the live incident; the retro
    /// channel is the same hazard through a different door, and a second copy of
    /// the number is a second thing to forget to move.
    func testTheOrthographicFloorIsTheLearnGatesOwn() {
        XCTAssertEqual(VocabularyReconciler.Limits().minSimilarity,
                       LearnPlausibility.orthographicFloor)
    }

    /// The numbers behind the "phonetic twin" row, pinned so a scorer change
    /// that resurrects the hijack fails loudly rather than quietly renaming
    /// somebody's colleague: phonetics clear every earlier gate, the letters
    /// fall below the floor, and the initials differ so the escape cannot
    /// rescue it. Mirrors `LearnPlausibilityTests`
    /// `testASpelledNewNameIsNotHijackedByAPhoneticTwin`.
    func testTheHijackClearsEveryGateExceptTheLetters() {
        XCTAssertGreaterThanOrEqual(PhoneticScorer.score("alex", "WellX"),
                                    VocabularyReconciler.Limits().minScore)
        XCTAssertLessThan(1 - StringMetrics.normalizedLevenshtein("alex", "wellx"),
                          VocabularyReconciler.Limits().minSimilarity)
        XCTAssertNotEqual("alex".first, "wellx".first)
    }

    /// …and the accepted rows really do clear it, on the letters or on the
    /// initial. Measured on the SQUEEZED forms, as GATE 4b measures: the second
    /// engine's spacing is not evidence, so "in forge" is compared as
    /// "inforge". The multi-word pair is the tightest row in the file — two
    /// misheard words, a different first letter, and 0.571 of the letters still
    /// agree.
    func testTheAcceptedRowsClearTheVetoOnLettersOrInitial() {
        let floor = VocabularyReconciler.Limits().minSimilarity
        XCTAssertGreaterThanOrEqual(
            1 - StringMetrics.normalizedLevenshtein("cheriecatri", "shariquekhatri"), floor,
            "a different initial means the letters have to carry it alone")
        XCTAssertGreaterThanOrEqual(
            1 - StringMetrics.normalizedLevenshtein("inforge", "insforge"), floor)
        // The escape row is under the floor and survives only on its initial.
        XCTAssertLessThan(1 - StringMetrics.normalizedLevenshtein("shreek", "sharique"), floor)
        XCTAssertEqual("shreek".first, "sharique".first)
    }

    /// Gate order is part of the contract. A block that fails BOTH similarity
    /// gates still reports `phoneticallyUnrelated` — the refusal this channel's
    /// metrics have counted since it shipped — so `orthographicallyDistant`
    /// means exactly one thing in a scoreboard: sounded right, spelled wrong.
    func testAnUnrelatedBlockStillReportsThePhoneticRefusal() {
        let limits = VocabularyReconciler.Limits()
        XCTAssertLessThan(PhoneticScorer.score("migration", "InsForge"), limits.minScore)
        XCTAssertLessThan(1 - StringMetrics.normalizedLevenshtein("migration", "insforge"),
                          limits.minSimilarity)
        let plan = VocabularyReconciler.plan(
            inserted: "Ping the migration team about the timeline.",
            reconciled: "Ping the InsForge team about the timeline.",
            termHits: ["InsForge": 1],
            knownTerm: { _ in false })
        XCTAssertEqual(plan.refusal, .phoneticallyUnrelated)
    }

    // MARK: - ambiguity

    /// Two canonical spellings that normalize to the same block. We genuinely
    /// cannot tell which one the user wants, and picking one at random is worse
    /// than leaving the text alone.
    func testTwoTermsWithTheSameNormalFormRefuseRatherThanGuess() {
        let plan = VocabularyReconciler.plan(
            inserted: "Ping the in forge team about the migration.",
            reconciled: "Ping the InsForge team about the migration.",
            termHits: ["InsForge": 1, "INSFORGE": 1],
            knownTerm: { _ in false })
        XCTAssertEqual(plan.refusal, .ambiguousTerm)
        XCTAssertTrue(plan.edits.isEmpty)
    }

    // MARK: - tokenizing

    func testTokenRangesSliceGraphemeClustersNotBytes() {
        // A decomposed é and an emoji ahead of the block: both are single
        // `Character`s, and the slice is taken in that unit.
        let inserted = "Cafe\u{301} 🚀 in forge opens today at the plaza"
        let plan = VocabularyReconciler.plan(
            inserted: inserted,
            reconciled: "Cafe\u{301} 🚀 InsForge opens today at the plaza",
            termHits: ["InsForge": 1],
            knownTerm: { _ in false })
        XCTAssertEqual(plan.edits.map(\.replace), ["in forge"])
        XCTAssertTrue(inserted.contains("in forge"))
    }

    func testNormalFormFoldsCasingPunctuationAndApostrophes() {
        XCTAssertEqual(VocabularyReconciler.Tokenizer.normalForm("It's — INS  Forge!"),
                       "its ins forge")
        XCTAssertEqual(VocabularyReconciler.Tokenizer.normalForm("It\u{2019}s"), "its",
                       "a curly apostrophe folds exactly like a straight one")
        XCTAssertEqual(VocabularyReconciler.Tokenizer.normalForm("  —  "), "")
    }
}
