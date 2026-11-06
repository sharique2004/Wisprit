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

    // MARK: - real-speech false triggers (docs/eval/AUDIT-2026-11-06.md)

    /// A shared opening word carried the whole-window score: on LibriSpeech
    /// the shipped layer turned every one of these into a dictionary term.
    /// Each window must now align word by word with its hear phrase.
    func testACommonOpeningWordNoLongerCarriesAWindowMatch() {
        // The production lexicon knows these as words; the single-token tier
        // is vetoed by it, so what is under test here is the WINDOW tier,
        // which consults no lexicon at all.
        let lexicon: Set<String> = [
            "you", "can", "come", "and", "nail", "me", "up", "in", "the", "coffin", "no",
            "did", "not", "hear", "bell", "so", "take", "him", "with", "teach", "stay",
            "here", "pick", "any", "route", "want", "tonight", "he", "walked", "across",
            "land", "she", "looked", "at", "man", "dawn", "this", "was", "end", "of", "it",
            "then", "thought", "home", "went", "well", "to", "even", "if", "rains", "we",
            "go", "very", "good", "said", "duke", "a", "tolerable", "some", "ways", "they",
            "were", "forming", "ranks", "can't",
        ]
        let entries: [FuzzyVocabularyCorrector.Entry] = [
            FuzzyVocabularyCorrector.Entry(term: "Ubuntu", hears: ["you bun to", "you bantu"]),
            FuzzyVocabularyCorrector.Entry(term: "De Anza", hears: ["de anza", "the anza"]),
            FuzzyVocabularyCorrector.Entry(term: "Anthropic", hears: ["and thropic"]),
            FuzzyVocabularyCorrector.Entry(term: "hackathon", hears: ["hacker thought"]),
            FuzzyVocabularyCorrector.Entry(term: "WellX", hears: ["well x", "well ex"]),
            FuzzyVocabularyCorrector.Entry(term: "EventKit", hears: ["event kit"]),
            FuzzyVocabularyCorrector.Entry(term: "Verilog", hears: ["very log"]),
            FuzzyVocabularyCorrector.Entry(term: "InsForge", hears: ["ins forge", "in forge"]),
        ]
        let c = FuzzyVocabularyCorrector(
            base: IdentityBase(),
            entries: { entries },
            isKnownTerm: { word in entries.contains { $0.term.lowercased() == word.lowercased() } },
            isOrdinaryWord: { lexicon.contains($0.lowercased()) })
        for sentence in [
            "You can come and nail me up in the coffin.",
            "No, did you not hear the bell?",
            "So take him with you and teach him.",
            "You can't stay here.",
            "Pick any route you want tonight.",
            "He walked across the land.",
            "She looked at the man and the dawn.",
            "And this was the end of it.",
            "Then he thought of home.",
            "It went well to the end.",
            "Even if it rains, we go.",
            "Very good, said the duke.",
            "A tolerable man in some ways.",
            "They were in forming ranks.",
        ] {
            XCTAssertEqual(c.applyCorrections(to: sentence), sentence)
        }
    }

    /// The near-misses the window tier exists for still land.
    func testAWordByWordNearMissStillRepairs() {
        let c = corrector([
            FuzzyVocabularyCorrector.Entry(term: "Wisprit", hears: ["whisper it"]),
            FuzzyVocabularyCorrector.Entry(term: "InsForge", hears: ["ins forge"]),
        ])
        XCTAssertEqual(c.applyCorrections(to: "open wisper it now"), "open Wisprit now")
        XCTAssertEqual(c.applyCorrections(to: "deploy to ins forges now"), "deploy to InsForge now")
    }

    /// The lexicon lists base forms; an inflection of an ordinary word is
    /// still an ordinary word. "remained" used to clear the veto and match the
    /// recorded hear "remain" (→ "RamAIn"); "sharks" only stayed safe in the
    /// test above because the test lexicon lists the plural.
    func testAnInflectionOfAnOrdinaryWordIsNeverReplaced() {
        let lexicon: Set<String> = ["the", "remain", "shark", "letter", "verse", "stamp", "interest"]
        let c = FuzzyVocabularyCorrector(
            base: IdentityBase(),
            entries: {[
                FuzzyVocabularyCorrector.Entry(term: "RamAIn", hears: ["remain", "ram main"]),
                FuzzyVocabularyCorrector.Entry(term: "Sharique", hears: ["Shariq"]),
                FuzzyVocabularyCorrector.Entry(term: "Letta", hears: ["letter", "leta"]),
                FuzzyVocabularyCorrector.Entry(term: "Vercel", hears: ["versell"]),
                FuzzyVocabularyCorrector.Entry(term: "Intrsekt", hears: ["intersect"]),
            ]},
            isKnownTerm: { _ in false },
            isOrdinaryWord: { lexicon.contains($0.lowercased()) })
        for sentence in [
            "The guests remained silent.",
            "the sharks circled",
            "She read the letters twice.",
            "He recited the verses.",
            "They stamped the forms.",
            "Their interests differ.",
        ] {
            XCTAssertEqual(c.applyCorrections(to: sentence), sentence)
        }
        // A genuine inflected mishear of a TERM is untouched by the veto.
        XCTAssertEqual(c.applyCorrections(to: "tell Shariqs about it"), "tell Sharique about it")
    }

    func testInflectionStemsCoverTheRegularSuffixes() {
        let stems = { FuzzyVocabularyCorrector.inflectionStems($0) }
        XCTAssertTrue(stems("remained").contains("remain"))
        XCTAssertTrue(stems("letters").contains("letter"))
        XCTAssertTrue(stems("carried").contains("carry"))
        XCTAssertTrue(stems("stopped").contains("stop"))
        XCTAssertTrue(stems("making").contains("make"))
        XCTAssertTrue(stems("sarah's").contains("sarah"))
        XCTAssertTrue(stems("quickly").contains("quick"))
        XCTAssertTrue(stems("shreek").isEmpty)
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
