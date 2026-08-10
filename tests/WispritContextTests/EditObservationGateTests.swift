import XCTest

@testable import WispritContext

/// Phase 5's six-rule classifier, both directions: the one shape that IS a
/// correction produces exactly one proposal, and every shape of ordinary
/// writing — appending, deleting, reflowing, rewording — produces nothing.
final class EditObservationGateTests: XCTestCase {

    private let lexicon = FixedLexicon(HighFrequencyWords.words)

    private func observe(_ committed: String, _ current: String,
                         knownTerm: (String) -> Bool = { _ in false }) -> EditObservation {
        EditObservationGate.observe(committed: committed, current: current,
                                    lexicon: lexicon, knownTerm: knownTerm)
    }

    // MARK: - The one accepted shape

    func testARealCorrectionProposesExactlyOneLearn() throws {
        let observation = observe("meeting with Sharik tomorrow",
                                  "meeting with Sharique tomorrow")
        XCTAssertNil(observation.refusal)
        let proposal = try XCTUnwrap(observation.proposal)
        XCTAssertEqual(proposal.replaced, "Sharik",
                       "the ASR's own misrecognition is the hear evidence")
        XCTAssertEqual(proposal.replacement, "Sharique")
        XCTAssertGreaterThanOrEqual(proposal.score, EditObservationGate.minScore)
        XCTAssertEqual(proposal.extractorVersion, ContextInfo.extractorVersion,
                       "proposals are stamped with the rules that produced them")
    }

    func testPunctuationAroundTheCorrectionDoesNotHideIt() {
        let observation = observe("say hi to Sharik, ok?", "say hi to Sharique, ok?")
        XCTAssertEqual(observation.proposal?.replacement, "Sharique")
    }

    // MARK: - Ordinary writing produces nothing

    func testTypingMoreTextIsNotACorrection() {
        let observation = observe("call me tomorrow",
                                  "call me tomorrow and bring the deck")
        XCTAssertNil(observation.proposal)
        XCTAssertEqual(observation.refusal, .insertion)
    }

    func testDeletingWordsIsNotACorrection() {
        let observation = observe("call me tomorrow morning", "call me tomorrow")
        XCTAssertNil(observation.proposal)
        XCTAssertEqual(observation.refusal, .deletion)
    }

    func testWhitespaceReflowReadsAsUnchanged() {
        let observation = observe("meeting with Sharik tomorrow",
                                  "meeting  with\nSharik tomorrow")
        XCTAssertNil(observation.proposal)
        XCTAssertEqual(observation.refusal, .unchanged)
    }

    func testAppSmartQuotesAndAutoCapitalizationReadAsUnchanged() {
        let observation = observe("don't forget it", "Don\u{2019}t forget it")
        XCTAssertEqual(observation.refusal, .unchanged)
    }

    /// Deliberate conservatism pinned: a case-ONLY edit is folded out by
    /// alignment and never learns (self-casing of known terms is the
    /// dictionary's job, not the flywheel's).
    func testCaseOnlyEditReadsAsUnchanged() {
        XCTAssertEqual(observe("we used insforge here", "we used InsForge here").refusal,
                       .unchanged)
    }

    func testScatteredEditsAreAReflowNotACorrection() {
        let observation = observe("Bob likes the red car", "Rob likes the blue car")
        XCTAssertNil(observation.proposal)
        XCTAssertEqual(observation.refusal, .reflow)
    }

    func testMultiTokenRewriteIsRefused() {
        let observation = observe("we saw Sharik go", "we saw Sha rik go")
        XCTAssertEqual(observation.refusal, .multiToken)
    }

    func testEmptySidesRefuseCleanly() {
        XCTAssertEqual(observe("", "hello there").refusal, .noText)
        XCTAssertEqual(observe("hello there", "").refusal, .noText)
        XCTAssertEqual(observe("", "").refusal, .noText)
    }

    // MARK: - The substitution gates

    func testRewordingIsPhoneticallyUnrelated() {
        let observation = observe("we saw Bob today", "we saw Zephyr today")
        XCTAssertNil(observation.proposal)
        XCTAssertEqual(observation.refusal, .phoneticallyUnrelated)
    }

    func testCommonWordReplacementIsNotACandidate() {
        // "spring" → "sprint" sounds alike and is EXACTLY the Wispr failure:
        // the lexicon stops it from ever becoming vocabulary.
        let observation = observe("fix the spring cycle", "fix the sprint cycle")
        XCTAssertNil(observation.proposal)
        XCTAssertEqual(observation.refusal, .notACandidate)
    }

    func testKnownTermsAreNotRelearned() {
        let observation = observe("meeting with Sharik tomorrow",
                                  "meeting with Sharique tomorrow",
                                  knownTerm: { $0 == "Sharique" })
        XCTAssertNil(observation.proposal)
        XCTAssertEqual(observation.refusal, .knownTerm)
    }

    // MARK: - Hard nevers

    func testHardNeversAreRejectedByTheSharedAcceptanceRules() {
        for never in ["bob@example.com",                        // email
                      "https://example.com/path",               // URL
                      "www.example.org",                        // schemeless URL
                      "example.com",                            // bare domain
                      "4155551",                                // 7-digit run
                      "AB12345678",                             // digit run inside a mix
                      "X" + String(repeating: "x", count: 40)]  // > 40 chars
        {
            XCTAssertFalse(CandidateExtractor.acceptsTerm(never, lexicon: lexicon), never)
        }
        for term in ["InsForge", "Sharique", "snake_case_name", "Q3", "MLX"] {
            XCTAssertTrue(CandidateExtractor.acceptsTerm(term, lexicon: lexicon), term)
        }
    }

    func testAnInsertedEmailNeverReachesTheProposal() {
        // The tokenizer skips the email chunk whole, so the diff reads as a
        // deletion — refused, nothing learned, nothing leaked.
        let observation = observe("mail foo now", "mail bob@example.com now")
        XCTAssertNil(observation.proposal)
    }
}
