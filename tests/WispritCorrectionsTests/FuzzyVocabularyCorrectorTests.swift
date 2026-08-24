import XCTest
import WispritKit
@testable import WispritCorrections

/// The fuzzy layer over the exact dictionary pass
/// (docs/research/hearing-and-corrections.md, corrections A1).
///
/// The exact matcher is brittle by design — an inflection, a plural, a
/// re-spacing of a KNOWN mishear sails straight past it. This layer catches
/// those, and the tests here are mostly about what it must REFUSE: every veto
/// is a real incident shape (ALIX/WellX, "shark"/"Sharique") from the systems
/// whose calibrated floors it borrows.
final class FuzzyVocabularyCorrectorTests: XCTestCase {

    /// Identity base: these tests exercise the fuzzy pass alone. The real
    /// wiring puts `DictionaryStore` here, whose own tests own exact-match
    /// semantics.
    private struct IdentityBase: CorrectionApplying {
        func applyCorrections(to text: String) -> String { text }
    }

    /// A base that fixes one exact phrase — for the layering tests.
    private struct ReplacingBase: CorrectionApplying {
        func applyCorrections(to text: String) -> String {
            text.replacingOccurrences(of: "in forge", with: "InsForge")
        }
    }

    private let ordinary: Set<String> = [
        "the", "shark", "is", "here", "for", "and", "deploy", "to", "now",
        "ask", "about", "it", "tell", "meet", "sharks", "in", "forge", "was",
    ]

    private func corrector(
        _ entries: [FuzzyVocabularyCorrector.Entry],
        base: any CorrectionApplying = IdentityBase()
    ) -> FuzzyVocabularyCorrector {
        let ordinary = self.ordinary
        return FuzzyVocabularyCorrector(
            base: base,
            entries: { entries },
            isKnownTerm: { word in entries.contains { $0.term.lowercased() == word.lowercased() } },
            isOrdinaryWord: { ordinary.contains($0.lowercased()) })
    }

    private let sharique = FuzzyVocabularyCorrector.Entry(term: "Sharique", hears: ["Shariq"])
    private let insforge = FuzzyVocabularyCorrector.Entry(term: "InsForge", hears: ["in forge"])

    // MARK: - what it catches

    /// Tier 1, single token: an inflected form of a RECORDED mishear.
    func testAnInflectedHearPhraseIsRepaired() {
        let c = corrector([sharique])
        XCTAssertEqual(c.applyCorrections(to: "tell Shariqs about it"),
                       "tell Sharique about it")
    }

    /// Tier 1, window: a plural re-spelling of a multi-word hear phrase.
    func testAMultiWordHearNearMissIsRepaired() {
        let c = corrector([insforge])
        XCTAssertEqual(c.applyCorrections(to: "deploy to in forges now"),
                       "deploy to InsForge now")
    }

    /// Tier 2: no hear phrase recorded, but the token SOUNDS like the term and
    /// the letters do not veto it — the reconciler's "shreek"/"Sharique"
    /// garbled-but-real shape, on-path.
    func testAPhoneticNearMissOfATermIsRepaired() {
        let c = corrector([FuzzyVocabularyCorrector.Entry(term: "Sharique", hears: [])])
        XCTAssertEqual(c.applyCorrections(to: "ask Shreek about it"),
                       "ask Sharique about it")
    }

    func testPunctuationAroundTheTokenSurvives() {
        let c = corrector([sharique])
        XCTAssertEqual(c.applyCorrections(to: "meet Shariqs, tomorrow."),
                       "meet Sharique, tomorrow.")
    }

    // MARK: - what it refuses

    /// "shark" codes identically to "Sharique" (Double Metaphone XRK) and
    /// clears every phonetic bar — the ordinary-word veto is the ONLY thing
    /// between this layer and renaming the user's marine biology notes.
    func testAnOrdinaryWordIsNeverReplaced() {
        let c = corrector([sharique])
        XCTAssertEqual(c.applyCorrections(to: "the shark is here"),
                       "the shark is here")
        XCTAssertEqual(c.applyCorrections(to: "the sharks here"),
                       "the sharks here")
    }

    /// Two terms both clearing the floors for one token is not a coin flip —
    /// it is a refusal (the reconciler's `ambiguousTerm` rule).
    func testAnAmbiguousMatchIsRefused() {
        let c = corrector([
            FuzzyVocabularyCorrector.Entry(term: "Kalle", hears: []),
            FuzzyVocabularyCorrector.Entry(term: "Callie", hears: []),
        ])
        XCTAssertEqual(c.applyCorrections(to: "ask Kalli about it"),
                       "ask Kalli about it")
    }

    func testNumbersEmailsAndUrlsAreUntouchable() {
        let c = corrector([FuzzyVocabularyCorrector.Entry(term: "Sharique", hears: ["12345"])])
        XCTAssertEqual(c.applyCorrections(to: "call 12346 or x@sharq.dev or https://shariq.dev"),
                       "call 12346 or x@sharq.dev or https://shariq.dev")
    }

    /// Words that make up a canonical term are fenced off — without this, a
    /// multi-word term's own output could be re-matched on the next pass.
    func testAWordOfAKnownTermIsFencedOff() {
        let c = corrector([
            FuzzyVocabularyCorrector.Entry(term: "Neon Flow", hears: []),
            FuzzyVocabularyCorrector.Entry(term: "Neom", hears: ["neon"]),
        ])
        XCTAssertEqual(c.applyCorrections(to: "open Neon Flow settings"),
                       "open Neon Flow settings")
    }

    func testShortTokensAreSkipped() {
        let c = corrector([FuzzyVocabularyCorrector.Entry(term: "Iona", hears: ["Io"])])
        XCTAssertEqual(c.applyCorrections(to: "Io was busy"), "Io was busy")
    }

    /// Past the budget the fuzzy pass stands down entirely — the exact pass
    /// (the base) still runs. The live-partial path re-runs every second.
    func testTheFuzzyPassStandsDownPastTheBudget() {
        let c = corrector([sharique])
        let filler = String(repeating: "word ", count: 450)   // > 2000 chars
        let text = filler + "tell Shariqs about it"
        XCTAssertEqual(c.applyCorrections(to: text), text)
    }

    // MARK: - layering and idempotence

    /// The exact pass runs first and owns its spans; fuzzy only fills what it
    /// left. Here the base already fixed "in forge" — fuzzy must not touch the
    /// canonical replacement.
    func testTheExactPassRunsFirstAndItsOutputIsFencedOff() {
        let c = corrector([insforge], base: ReplacingBase())
        XCTAssertEqual(c.applyCorrections(to: "deploy to in forge now"),
                       "deploy to InsForge now")
    }

    /// `apply(apply(x)) == apply(x)` — the live-partial path's hard
    /// requirement, over every shape this suite exercises.
    func testTheWholeLayerIsIdempotent() {
        let c = corrector([sharique, insforge,
                           FuzzyVocabularyCorrector.Entry(term: "Neon Flow", hears: [])])
        for text in [
            "tell Shariqs about it",
            "deploy to in forges now",
            "ask Shreek about it",
            "the shark is here",
            "open Neon Flow settings",
            "meet Shariqs, tomorrow.",
        ] {
            let once = c.applyCorrections(to: text)
            XCTAssertEqual(c.applyCorrections(to: once), once, "not idempotent for: \(text)")
        }
    }
}
