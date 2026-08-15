import XCTest
import WispritKit

@testable import WispritCorrections

/// Every positive form here is a transcript the research probes actually
/// produced on this machine (SpeechTranscriber, macOS 26.5, M4, 13 probes over
/// 7 voices and 2 rates) — hyphenated, glued, space-broken and dot-separated.
final class LetterRunDetectorTests: XCTestCase {

    private let detector = LetterRunDetector()

    private func collapsed(_ text: String) -> [String] {
        detector.detect(in: text).map(\.collapsed)
    }

    func testCollapsesEveryObservedRunShape() {
        // hyphen-joined, the common SpeechTranscriber form
        XCTAssertEqual(collapsed("Actually, it's S-H-A-R-I-Q-U-E."), ["SHARIQUE"])
        // segmentation glue — letters are never lost, only mis-grouped
        XCTAssertEqual(collapsed("Capital S-HA-R-I-Q-U-E."), ["SHARIQUE"])
        XCTAssertEqual(collapsed("Correction, it's spelled KRZ-Y-S-Z-T-O-F."), ["KRZYSZTOF"])
        // space-broken, and space mixed with hyphens
        XCTAssertEqual(collapsed("It's S H A R I Q U E."), ["SHARIQUE"])
        XCTAssertEqual(collapsed("It's S H-A-R-I-Q-U-E."), ["SHARIQUE"])
        // dot-separated
        XCTAssertEqual(collapsed("It's S. H. A. R. I. Q. U. E."), ["SHARIQUE"])
        // a run with no trigger at all still detects
        XCTAssertEqual(collapsed("S-H-A-R-I-Q-U-E."), ["SHARIQUE"])
        // the residual false positive the research names — detected, but the
        // decision layer is what makes it harmless
        XCTAssertEqual(collapsed("We need to fix the J-S-O-N parser."), ["JSON"])
    }

    func testRejectsNonSpellings() {
        // digits break the run
        XCTAssertEqual(collapsed("COVID-19 numbers"), [])
        XCTAssertEqual(collapsed("The AB1 form"), [])
        XCTAssertEqual(collapsed("A-B-1-C"), [])
        // glued acronyms are single tokens, not runs
        XCTAssertEqual(collapsed("Fix the JSON parser and the URL handler in the API."), [])
        // ordinary all-caps text
        XCTAssertEqual(collapsed("NOT FOR SALE"), [])
        XCTAssertEqual(collapsed("URL AND API AND SO ON"), [])
        XCTAssertEqual(collapsed("U.S. GDP"), [])
        // uppercase is the invariant
        XCTAssertEqual(collapsed("it's s-h-a-r-i-q-u-e"), [])
        // two segments is an initialism, not a spelling
        XCTAssertEqual(collapsed("J-S"), [])
        // must not start mid-token
        XCTAssertEqual(collapsed("McDONALD-S-CORP"), [])
        XCTAssertEqual(collapsed("Hi, I'M A-B-C"), ["ABC"])
    }

    func testAllCapsNeighboursAreNotSwallowedIntoARun() {
        // The greedy scan must stop at "AND", not absorb it into the run.
        XCTAssertEqual(collapsed("URL AND API AND S-H-A-R-I-Q-U-E."), ["SHARIQUE"])
    }

    /// The ASR habitually writes the spelled word out again straight after the
    /// spelling. The parser used to follow the ". " into "Krzysztof", hit the
    /// lowercase "r", and `return nil` — discarding all NINE accumulated
    /// segments, so `decide` saw no run at all: the user's dictated spelling
    /// silently did nothing and the "K-R-Z-Y-S-Z-T-O-F." litter stayed in their
    /// text. The run has to end AT the word instead.
    func testARunEndsAtAFollowingWordInsteadOfBeingDiscarded() {
        XCTAssertEqual(
            collapsed("That's spelled K-R-Z-Y-S-Z-T-O-F. Krzysztof will join."), ["KRZYSZTOF"])
        XCTAssertEqual(collapsed("It's S-H-A-R-I-Q-U-E. Sharique is here."), ["SHARIQUE"])
        // Same fault through the dot-separated shape, where the ". " separator
        // is what carries the parser into the next word.
        XCTAssertEqual(
            collapsed("It's S. H. A. R. I. Q. U. E. Sharique is here."), ["SHARIQUE"])
        // The corpus clip (tts-stress-v1 sr-01, ref "The payload is JSON, not
        // YAML.") in the reading where the ASR puts a full stop after the run.
        XCTAssertEqual(collapsed("The payload is J-S-O-N. Not YAML."), ["JSON"])

        // The run stops before the word, so the splice can only ever touch the
        // letters — the word itself is not part of `raw`.
        let text = "That's spelled K-R-Z-Y-S-Z-T-O-F. Krzysztof will join."
        let run = try! XCTUnwrap(detector.detect(in: text).first)
        XCTAssertEqual(run.raw, "K-R-Z-Y-S-Z-T-O-F")
        XCTAssertEqual(String(Array(text)[run.range]), run.raw)
        XCTAssertFalse(run.isTail)
    }

    /// The half of that guard that must NOT loosen: with nothing accumulated
    /// behind it, the token itself is still rejected outright (the break falls
    /// through `minSegmentCount`). These are the same rows as
    /// `testRejectsNonSpellings`, restated as the regression they guard.
    func testTheTokenItselfIsStillRejectedWhenTheRunIsEmpty() {
        for text in ["COVID-19 numbers", "The AB1 form", "A-B-1-C", "McDONALD-S-CORP",
                     "The A-B1 form", "I'm on it"] {
            XCTAssertEqual(collapsed(text), [], text)
        }
    }

    /// "It's spelled V-I-V-E-K I think" collapsed to "VIVEKI": the pronoun was
    /// absorbed as the sixth letter, so the name would have been inserted and
    /// learned as "Viveki" and the real word "I" eaten. A hyphen-spelled run
    /// that switches to a bare space is the tell.
    func testAStandaloneWordIsNotAbsorbedAsTheNextLetter() {
        XCTAssertEqual(collapsed("It's spelled V-I-V-E-K I think"), ["VIVEK"])
        XCTAssertEqual(collapsed("Spell that A-B-C A word"), ["ABC"])
        // Dot-delimited runs carry the same tell.
        XCTAssertEqual(collapsed("It's V.I.V.E.K I think"), ["VIVEK"])
    }

    /// …and the shapes that must keep absorbing. A run separated ONLY by spaces
    /// has no switch to notice, and a dot-separated run's spaces are not bare —
    /// both of these are research-probe transcripts, letter "I" included.
    func testSpaceAndDotSpelledRunsStillAbsorbTheirOwnLetters() {
        XCTAssertEqual(collapsed("It's S H A R I Q U E."), ["SHARIQUE"])
        XCTAssertEqual(collapsed("It's S. H. A. R. I. Q. U. E."), ["SHARIQUE"])
        XCTAssertEqual(collapsed("It's S H-A-R-I-Q-U-E."), ["SHARIQUE"])
        // A capital that opens ANOTHER delimited run is a letter, not a word.
        XCTAssertEqual(collapsed("It's spelled V-I-V-E-K A-N-A-N-D"), ["VIVEKANAND"])
    }

    func testKnownTermsAreNotDirectives() {
        let vocabulary = StubVocabulary(terms: ["JSON"])
        let aware = LetterRunDetector(vocabulary: vocabulary)
        XCTAssertTrue(aware.detect(in: "Fix the J-S-O-N parser.").isEmpty)
        XCTAssertEqual(aware.detect(in: "It's S-H-A-R-I-Q-U-E.").first?.collapsed, "SHARIQUE")
    }

    func testTriggerIsDetectedButNeverRequired() {
        for phrase in [
            "Actually, it's S-H-A-R-I-Q-U-E.",
            "No, no, S-H-A-R-I-Q-U-E.",
            "Correction, S-H-A-R-I-Q-U-E.",
            "It's spelled S-H-A-R-I-Q-U-E.",
            "Spell that S-H-A-R-I-Q-U-E.",
            "I mean S-H-A-R-I-Q-U-E.",
            "Sorry, it's S-H-A-R-I-Q-U-E.",
        ] {
            XCTAssertNotNil(detector.detect(in: phrase).first?.trigger, phrase)
        }
        // "that's spelled" comes back from the ASR as "Let's spell" — a
        // mis-transcription must not authorise a retro-edit, so bare "spell"
        // is deliberately not a trigger.
        XCTAssertNil(detector.detect(in: "Let's spell J-O-N.").first?.trigger)
        XCTAssertNil(detector.detect(in: "S-H-A-R-I-Q-U-E.").first?.trigger)
        // still detected without one
        XCTAssertEqual(detector.detect(in: "Let's spell J-O-N.").first?.collapsed, "JON")
    }

    func testTriggerWindowIsBounded() {
        let far = "Actually " + String(repeating: "x", count: 60) + " S-H-A-R-I-Q-U-E."
        XCTAssertNil(detector.detect(in: far).first?.trigger)
    }

    func testNearestTriggerAnchorsTheDirective() {
        let text = "No, no, it's spelled S-H-A-R-I-Q-U-E."
        let run = try! XCTUnwrap(detector.detect(in: text).first)
        XCTAssertEqual(run.trigger, "it's spelled")
        XCTAssertEqual(String(Array(text)[run.directiveRange]), "it's spelled S-H-A-R-I-Q-U-E")
    }

    func testRangesAndTailFlag() {
        let text = "Actually, it's S-H-A-R-I-Q-U-E."
        let run = try! XCTUnwrap(detector.detect(in: text).first)
        XCTAssertEqual(run.raw, "S-H-A-R-I-Q-U-E")
        XCTAssertEqual(String(Array(text)[run.range]), run.raw)
        XCTAssertEqual(String(Array(text)[run.directiveRange]), "Actually, it's S-H-A-R-I-Q-U-E")
        XCTAssertTrue(run.isTail)
        XCTAssertTrue(run.isDelimited)

        let midway = try! XCTUnwrap(
            detector.detect(in: "It's S-H-A-R-I-Q-U-E not the other one.").first)
        XCTAssertFalse(midway.isTail)
    }

    func testContainsLetterRunGuard() {
        // What the refine stage must bypass on — it turns "S-H-A-R-I-Q-U-E"
        // into "Sharifue" deterministically.
        XCTAssertTrue(detector.containsLetterRun("Actually, it's S-H-A-R-I-Q-U-E."))
        XCTAssertFalse(detector.containsLetterRun("Please ping Shariq about the migration."))
    }
}

struct StubVocabulary: VocabularySource {
    let terms: [String]
    func vocabularyTerms() -> [String] { terms }
    func isKnownTerm(_ word: String) -> Bool {
        terms.contains { $0.compare(word, options: .caseInsensitive) == .orderedSame }
    }
}
