import XCTest
import WispritKit

@testable import WispritCorrections

/// The gate that stops the learn loop filling the dictionary with the ASR's own
/// confusion. Every merge case below is a REAL entry from
/// `~/.wisprit/dictionary.json`, written by the ungated loop.
final class LearnPlausibilityTests: XCTestCase {

    /// The dictionary as it stood when the junk was written: `Sharique` was
    /// already there, with `sharik` among its `hear` phrases.
    private let dictionary = [
        "Sharique", "Wisprit", "InsForge", "MeetingScribe", "Claude", "Anthropic", "MLX",
    ]

    // MARK: - merge

    /// The three live junk terms. Each was created on a single utterance where
    /// the user spelled S-H-A-R-I-Q-U-E, the ASR misread the LETTERS, and the
    /// loop wrote the misreading down as a canonical term with hear:["Sharik"].
    func testTheThreeRealJunkTermsAllMergeIntoSharique() {
        for junk in ["SHARHUUE", "SHAIKD", "SHARIQ"] {
            XCTAssertEqual(
                LearnPlausibility.classify(
                    collapsed: junk, antecedent: "Sharik", candidates: dictionary),
                .merge(into: "Sharique"),
                "\(junk) is Sharique mangled, not a fourth name for the same person")
        }
    }

    /// Two of them clear a direct rule; SHAIKD clears neither (0.725 phonetic,
    /// 0.500 orthographic) and is caught by the anchored rule instead — the
    /// ASR's own heard token, "Sharik", scores 0.957 against Sharique.
    func testEachJunkTermIsCaughtByTheRuleItsNumbersSay() {
        XCTAssertGreaterThanOrEqual(
            PhoneticScorer.score("SHARHUUE", "Sharique"), LearnPlausibility.mergeScore)
        XCTAssertGreaterThanOrEqual(
            PhoneticScorer.score("SHARIQ", "Sharique"), LearnPlausibility.mergeScore)

        XCTAssertLessThan(
            PhoneticScorer.score("SHAIKD", "Sharique"), LearnPlausibility.mergeScore)
        XCTAssertLessThan(
            1 - StringMetrics.normalizedLevenshtein("shaikd", "sharique"),
            LearnPlausibility.mergeSimilarity)
        // …so without the antecedent it is a believable new name, and with it
        // it is obviously the same event as the other two.
        XCTAssertEqual(
            LearnPlausibility.classify(collapsed: "SHAIKD", antecedent: "", candidates: dictionary),
            .quarantine(term: "SHAIKD"))
        XCTAssertEqual(
            LearnPlausibility.classify(
                collapsed: "SHAIKD", antecedent: "Sharik", candidates: dictionary),
            .merge(into: "Sharique"))
    }

    /// Merge is checked BEFORE the orthographic faults on purpose: SHARHUUE
    /// carries the "UU" that would reject it outright, but a correct answer is
    /// available, and handing the user "Sharique" beats telling them the
    /// spelling failed.
    func testMergeWinsOverAnOrthographicFault() {
        XCTAssertEqual(LearnPlausibility.fault(in: "SHARHUUE"), .implausibleDigraph)
        XCTAssertEqual(
            LearnPlausibility.classify(
                collapsed: "SHARHUUE", antecedent: "Sharik", candidates: dictionary),
            .merge(into: "Sharique"))
        XCTAssertEqual(
            LearnPlausibility.classify(
                collapsed: "SHARHUUE", antecedent: "Sharik", candidates: []),
            .reject(reason: .implausibleDigraph))
    }

    func testMergeReadsTheVocabularySource() {
        XCTAssertEqual(
            LearnPlausibility.classify(
                collapsed: "SHARIQ", antecedent: "Sharik",
                vocabulary: StubVocabulary(terms: dictionary)),
            .merge(into: "Sharique"))
        XCTAssertEqual(
            LearnPlausibility.classify(
                collapsed: "SHARIQ", antecedent: "Sharik", vocabulary: nil),
            .quarantine(term: "SHARIQ"))
    }

    /// The live incident of 2026-08-12: the user spelled A-L-I-X to correct
    /// "Alex", and the gate merged it into `WellX` — Double Metaphone codes
    /// ALIX, Alex, and WellX identically (ALKS), so every phonetic gate fires
    /// while the letters disagree almost everywhere. The spelled run must
    /// survive as a new name; the orthographic veto is what saves it.
    func testASpelledNewNameIsNotHijackedByAPhoneticTwin() {
        XCTAssertEqual(
            LearnPlausibility.classify(
                collapsed: "ALIX", antecedent: "Alex", candidates: dictionary + ["WellX"]),
            .quarantine(term: "ALIX"))

        // The numbers that made the hijack possible, pinned so a scorer change
        // that resurrects it fails loudly: phonetics clear the merge gate, the
        // letters fall below the veto floor, and the initials differ.
        XCTAssertGreaterThanOrEqual(
            PhoneticScorer.score("ALIX", "WellX"), LearnPlausibility.mergeScore)
        XCTAssertLessThan(
            1 - StringMetrics.normalizedLevenshtein("alix", "wellx"),
            LearnPlausibility.orthographicFloor)
    }

    /// Once the spelled name IS vocabulary, the next spelling of it must land
    /// on that entry, not the phonetic twin: the exact term outscores WellX.
    func testTheSpelledNameItselfWinsOnceLearned() {
        XCTAssertEqual(
            LearnPlausibility.classify(
                collapsed: "ALIX", antecedent: "Alex",
                candidates: dictionary + ["WellX", "ALIX"]),
            .merge(into: "ALIX"))
    }

    /// Pins the `>=` in the similarity arm, alone. CHERIE sits EXACTLY on the
    /// 0.500 floor with a DIFFERENT initial (c ≠ s), so the initial escape
    /// cannot rescue it — a `>` would silently veto the very Cherie/Sharique
    /// rescue pair the PhoneticScorer doc comment is calibrated on.
    func testTheSimilarityFloorIsInclusive() {
        XCTAssertEqual(
            1 - StringMetrics.normalizedLevenshtein("cherie", "sharique"),
            LearnPlausibility.orthographicFloor, accuracy: 0.0001)
        XCTAssertEqual(
            LearnPlausibility.classify(
                collapsed: "CHERIE", antecedent: "Sharik", candidates: dictionary),
            .merge(into: "Sharique"))
    }

    /// Pins the first-letter escape, alone. SHIRK is the spelled run with its
    /// letters transposed by the ASR: similarity 0.375 is BELOW the floor, so
    /// only the matching initial keeps the merge alive — deleting the escape
    /// clause turns this into a junk quarantined term.
    func testAMatchingInitialRescuesAGarbledRunBelowTheFloor() {
        XCTAssertLessThan(
            1 - StringMetrics.normalizedLevenshtein("shirk", "sharique"),
            LearnPlausibility.orthographicFloor)
        XCTAssertEqual(
            LearnPlausibility.classify(
                collapsed: "SHIRK", antecedent: "Sharik", candidates: dictionary),
            .merge(into: "Sharique"))
    }

    /// An unrelated dictionary must not attract anything. Merging into the
    /// wrong term would put a word the user never said into their document,
    /// which is worse than learning a junk one.
    func testAnUnrelatedDictionaryAttractsNothing() {
        let unrelated = ["Wisprit", "InsForge", "MeetingScribe", "Claude", "MLX"]
        for junk in ["SHARHUUE", "SHAIKD", "SHARIQ", "KRZYSZTOF"] {
            XCTAssertNil(
                LearnPlausibility.mergeTarget(
                    for: junk, antecedent: "Sharik", candidates: unrelated),
                junk)
        }
    }

    // MARK: - reject

    func testHardOrthographicFaults() {
        let cases: [(String, LearnDecision.Reason)] = [
            ("SHRQZ", .noVowel),                            // no a/e/i/o/u/y at all
            ("SHARIIIQ", .repeatedLetter),                  // three of a letter running
            (String(repeating: "AB", count: 13), .tooLong), // 26 characters
            ("SHAR1QUE", .nonLetter),                       // a digit survived the collapse
            ("SHARHUUE", .implausibleDigraph),              // English does not write "uu"
        ]
        for (run, reason) in cases {
            XCTAssertEqual(
                LearnPlausibility.classify(collapsed: run, antecedent: "Shariq", candidates: []),
                .reject(reason: reason), run)
        }
    }

    func testTheLengthBoundIsInclusive() {
        let twentyFour = String(repeating: "ABABABABABAB", count: 2)
        XCTAssertEqual(twentyFour.count, LearnPlausibility.maxLength)
        XCTAssertNil(LearnPlausibility.fault(in: twentyFour))
        XCTAssertEqual(LearnPlausibility.fault(in: twentyFour + "C"), .tooLong)
    }

    /// `y` is a vowel for "does this have a vowel at all" but not for the
    /// digraph rule, and only DOUBLED vowels are judged there — mixed pairs are
    /// ordinary in real names, "ue" in Sharique itself included.
    func testVowelRulesDoNotRejectOrdinarySpellings() {
        for run in ["SHARIQUE", "MARIA", "FABIO", "JOSHUA", "SYZYGY", "SHAYNE", "AISHA"] {
            XCTAssertNil(LearnPlausibility.fault(in: run), run)
        }
    }

    // MARK: - quarantine

    /// The research digest's named hard case. Nine letters, four of them a
    /// consonant pile-up, and it must survive: there is deliberately no
    /// consonant-cluster rule, because a real person is called this.
    func testKrzysztofIsQuarantinedNotRejected() {
        XCTAssertEqual(
            LearnPlausibility.classify(
                collapsed: "KRZYSZTOF", antecedent: "Cherie", candidates: dictionary),
            .quarantine(term: "KRZYSZTOF"))
        XCTAssertEqual(
            LearnPlausibility.classify(
                collapsed: "KRZYSZTOF", antecedent: "", candidates: []),
            .quarantine(term: "KRZYSZTOF"))
    }

    func testABelievableNewNameIsQuarantined() {
        XCTAssertEqual(
            LearnPlausibility.classify(
                collapsed: "SHARIQUE", antecedent: "Shariq", candidates: []),
            .quarantine(term: "SHARIQUE"))
    }

    // MARK: - properties

    func testClassifyIsPureAndDeterministic() {
        let first = LearnPlausibility.classify(
            collapsed: "SHAIKD", antecedent: "Sharik", candidates: dictionary)
        for _ in 0..<50 {
            XCTAssertEqual(
                LearnPlausibility.classify(
                    collapsed: "SHAIKD", antecedent: "Sharik", candidates: dictionary),
                first)
        }
    }

    /// Ties go to the earliest candidate, which for `vocabularyTerms()` is the
    /// most-recently-useful term — so a merge never depends on set ordering.
    func testDuplicateCandidatesResolveToTheFirst() {
        XCTAssertEqual(
            LearnPlausibility.classify(
                collapsed: "SHARIQ", antecedent: "Sharik",
                candidates: ["Sharique", "sharique", "SHARIQUE"]),
            .merge(into: "Sharique"))
    }

    func testEmptyRunIsNeverLearned() {
        XCTAssertEqual(
            LearnPlausibility.classify(collapsed: "", antecedent: "Shariq", candidates: dictionary),
            .reject(reason: .noVowel))
    }
}
