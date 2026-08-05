import XCTest
import WispritKit
@testable import WispritRefine

/// The NEW bypass (no Python counterpart). Cases are the shapes SpeechTranscriber
/// actually produced in the research probes, not invented ones:
/// docs/research/apps-feasibility.md §"Spelling corrections" and the
/// correction-detection digest (31 `say`-synthesized probes, macOS 26.5, M4).
///
/// Why it exists: measured, the model turns `Actually, it's S-H-A-R-I-Q-U-E.`
/// into `Actually, it's Sharifue.` — non-deterministically. A spelled run must
/// never reach the model.
final class LetterRunGuardTests: XCTestCase {

    private struct FakeVocabulary: VocabularySource {
        let terms: [String]
        func vocabularyTerms() -> [String] { terms }
        func isKnownTerm(_ word: String) -> Bool {
            terms.contains { $0.compare(word, options: .caseInsensitive) == .orderedSame }
        }
    }

    /// Measured ITN output forms. The stable invariant is UPPERCASE, not the
    /// hyphen: separators observed were hyphens, spaces, periods, and none.
    func testDetectsMeasuredRunShapes() {
        let observed = [
            "Actually, it's S-H-A-R-I-Q-U-E.",
            "Let's spell J-O-H-N.",
            "Correction, it's spelled KRZ-Y-S-Z-T-O-F.",
            "S-H-A-R-I-Q-U-E.",
            "S-HA-R-I-Q-U-E.",             // mis-segmented glue
            "S H-A-R-I-Q-U-E",             // space broken
            "Actually, it's SHIRIQUE.",    // running-phoneme spelling, glued
            "no no it's spelled S-H-R-I-Q-U-E",
            "C-A-E-L-U-M",
        ]
        for text in observed {
            XCTAssertTrue(RefineGuards.hasLetterRun(text), text)
        }
    }

    /// Ordinary dictation must still reach the model — the bypass is a safety
    /// valve, not a general off switch.
    func testIgnoresOrdinaryDictation() {
        let clean = [
            "um so basically we should uh probably migrate the the data base",
            "how do i um restart the post grass server on you bun to",
            "Tell me a joke about cats.",
            "We shipped PostgreSQL and MySQL on Friday.",
            // 2- and 3-letter acronyms glue without hyphens and stay below the
            // threshold (measured: "U. R. L. … A. P. I." → "URL … API").
            "check the URL and the API",
            "OK we are done",
            "I said no",
            "A B C",                       // single letters, nothing collapses to ≥3
        ]
        for text in clean {
            XCTAssertFalse(RefineGuards.hasLetterRun(text), text)
        }
    }

    /// Deliberately liberal: a genuinely spelled-out acronym also bypasses.
    /// Skipping cleanup costs polish; refining a spelled run costs the user's
    /// name. The dictionary can buy the cleanup back.
    func testKnownAcronymsDoNotForceTheBypass() {
        let vocab = FakeVocabulary(terms: ["JSON", "Sharique"])
        // A glued all-caps token is formally identical to an acronym, so the
        // dictionary can buy the cleanup back.
        XCTAssertTrue(RefineGuards.hasLetterRun("we serialize the JSON payload"))
        XCTAssertFalse(RefineGuards.hasLetterRun("we serialize the JSON payload",
                                                 vocabulary: vocab))
        // Separators mean the letters were dictated one by one. That bypasses
        // even for a known word — the model corrupts the RUN, not the entry.
        XCTAssertTrue(RefineGuards.hasLetterRun("the J-S-O-N payload", vocabulary: vocab))
        XCTAssertTrue(RefineGuards.hasLetterRun("it's S-H-A-R-I-Q-U-E", vocabulary: vocab))
    }

    /// Digits break a run, which is what keeps COVID-19 and AB1 out.
    func testDigitsBreakTheRun() {
        XCTAssertFalse(RefineGuards.hasLetterRun("we got AB1 2 C back"))
        XCTAssertFalse(RefineGuards.hasLetterRun("COVID-19 rules"))
    }
}
