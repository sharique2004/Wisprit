import XCTest
import WispritKit
@testable import WispritEngine

/// The Phase-4 `extraTerms` seam on the vocabulary channel: pure term-list
/// plumbing, no analyzer. (The reconcile pass itself is covered by the
/// env-gated live batteries; what must hold everywhere is that the merge is
/// additive, deduplicated, and dictionary-first.)
final class VocabularyChannelTermsTests: XCTestCase {

    private struct FixedVocabulary: VocabularySource {
        var terms: [String]
        func vocabularyTerms() -> [String] { terms }
        func isKnownTerm(_ word: String) -> Bool { terms.contains(word) }
    }

    private func makeChannel(terms: [String], limit: Int? = nil) -> VocabularyChannel {
        VocabularyChannel(settings: AsrSettings(contextualTermLimit: limit),
                          vocabulary: FixedVocabulary(terms: terms))
    }

    func testNoExtrasIsByteIdenticalToBefore() {
        let channel = makeChannel(terms: ["InsForge", "Sharique"])
        XCTAssertEqual(channel.contextualTerms(), ["InsForge", "Sharique"])
        XCTAssertEqual(channel.contextualTerms(extra: []), ["InsForge", "Sharique"])
    }

    func testExtrasAppendAfterTheDictionary() {
        let channel = makeChannel(terms: ["InsForge"])
        XCTAssertEqual(channel.contextualTerms(extra: ["Kubernetes", "Q3"]),
                       ["InsForge", "Kubernetes", "Q3"])
    }

    /// The dictionary's casing wins: a term the user owns is never re-cased by
    /// what happened to be on screen.
    func testExtrasDedupeCaseInsensitivelyAgainstTheDictionary() {
        let channel = makeChannel(terms: ["InsForge"])
        XCTAssertEqual(channel.contextualTerms(extra: ["INSFORGE", "insforge", "Zed"]),
                       ["InsForge", "Zed"])
    }

    func testExtrasDedupeAmongThemselvesAndDropEmpties() {
        let channel = makeChannel(terms: [])
        XCTAssertEqual(channel.contextualTerms(extra: ["Zed", "", "zed", "Zed"]),
                       ["Zed"])
    }

    /// The cap protects the dictionary path; per-utterance extras ride after
    /// it. Two dozen context terms must never evict a dictionary term.
    func testTermLimitAppliesToTheDictionaryNotTheExtras() {
        let channel = makeChannel(terms: ["A1x", "B2x", "C3x"], limit: 2)
        XCTAssertEqual(channel.contextualTerms(extra: ["Zed"]),
                       ["A1x", "B2x", "Zed"])
    }

    /// `termHits` counts extras too — deliberately, because that is what lets
    /// the retro-correction planner act on a context term with zero new
    /// machinery.
    func testTermHitsCountsExtraTermsLikeAnyOther() {
        let hits = VocabularyChannel.termHits(in: "deployed to Kubernetes on InsForge",
                                              terms: ["InsForge", "Kubernetes", "Zed"])
        XCTAssertEqual(hits, ["InsForge": 1, "Kubernetes": 1])
    }
}
