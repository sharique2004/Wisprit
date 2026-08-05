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
