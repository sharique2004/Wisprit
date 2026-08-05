import XCTest
import WispritKit

@testable import WispritCorrections

/// The three-way branch, exercised on the exact scenarios the research digest
/// names — including the two that must NOT produce an edit.
final class SpokenSpellingCorrectorTests: XCTestCase {

    private let corrector = SpokenSpellingCorrector()

    func testTriggerPlusCandidateRetroReplaces() {
        let action = corrector.decide(
            utterance: "Actually, it's S-H-A-R-I-Q-U-E.", previousUtterance: "Hi Shariq.")
        guard case .retroReplace(let target, let replacement, let suppress, let learn) = action
        else { return XCTFail("expected retroReplace, got \(action)") }
        XCTAssertEqual(target, "Shariq")
        XCTAssertEqual(replacement, "Sharique")
        XCTAssertEqual(
            String(Array("Actually, it's S-H-A-R-I-Q-U-E.")[suppress]),
            "Actually, it's S-H-A-R-I-Q-U-E")
        XCTAssertEqual(
            learn, LearnedTerm(term: "Sharique", heard: ["Shariq"], source: "spoken_spelling"))
    }

    /// Double Metaphone gives XR vs XRK and misses this outright; the
    /// Jaro-Winkler term carries it over 0.62 at 0.689.
    func testJaroWinklerRescuesTheCherieMisrecognition() {
        let action = corrector.decide(
            utterance: "No, no, it's spelled S-H-A-R-I-Q-U-E.",
            previousUtterance: "Please ping Cherie about the migration.")
        guard case .retroReplace(let target, let replacement, _, let learn) = action else {
            return XCTFail("expected retroReplace, got \(action)")
        }
        XCTAssertEqual(target, "Cherie")
        XCTAssertEqual(replacement, "Sharique")
        XCTAssertEqual(learn.heard, ["Cherie"])
    }

    /// The unfixable tail: the ASR heard "Cherie" for a spoken "Krzysztof", so
    /// the best candidate scores 0.383. Nothing may be retro-edited.
    func testMangledTargetYieldsNoCandidateAndNeverRetroDeletes() {
        let utterance = "No, no, it's spelled K-R-Z-Y-S-Z-T-O-F."
        let action = corrector.decide(
            utterance: utterance,
            previousUtterance: "Email Cherie about the roadmap.")
        guard case .insertLiterally(let word, let replace, let offer) = action else {
            return XCTFail("expected insertLiterally, got \(action)")
        }
        XCTAssertEqual(word, "KRZYSZTOF")
        // The replaced span is the RUN ONLY — the trigger phrase and everything
        // before it survive untouched.
        XCTAssertEqual(String(Array(utterance)[replace]), "K-R-Z-Y-S-Z-T-O-F")
        XCTAssertEqual(
            offer, LearnedTerm(term: "KRZYSZTOF", heard: [], source: "spoken_spelling"))
    }

    func testBareAcronymRunInsertsAndNeverRetroDeletes() {
        let utterance = "We need to fix the J-S-O-N parser."
        let action = corrector.decide(utterance: utterance)
        guard case .insertLiterally(let word, let replace, _) = action else {
            return XCTFail("expected insertLiterally, got \(action)")
        }
        XCTAssertEqual(word, "JSON")
        XCTAssertEqual(String(Array(utterance)[replace]), "J-S-O-N")
    }

    func testEveryRunShapeReachesTheSameDecision() {
        for spelling in [
            "S-H-A-R-I-Q-U-E", "S-HA-R-I-Q-U-E", "S H A R I Q U E",
            "S H-A-R-I-Q-U-E", "S. H. A. R. I. Q. U. E",
        ] {
            let action = corrector.decide(
                utterance: "Actually, it's \(spelling).", previousUtterance: "Hi Shariq.")
            guard case .retroReplace(let target, let replacement, _, _) = action else {
                return XCTFail("expected retroReplace for \(spelling), got \(action)")
            }
            XCTAssertEqual(target, "Shariq", spelling)
            XCTAssertEqual(replacement, "Sharique", spelling)
        }
    }

    func testCandidateWithoutTriggerOnlyReplacesTheUtteranceTail() {
        // Antecedent in the same utterance, run at the tail → in-utterance fix.
        let tail = corrector.decide(utterance: "Ping Shariq, S-H-A-R-I-Q-U-E.")
        guard case .tailReplace(let target, let replacement, let suppress, _) = tail else {
            return XCTFail("expected tailReplace, got \(tail)")
        }
        XCTAssertEqual(target, "Shariq")
        XCTAssertEqual(replacement, "Sharique")
        XCTAssertEqual(
            String(Array("Ping Shariq, S-H-A-R-I-Q-U-E.")[suppress]), "S-H-A-R-I-Q-U-E")

        // Same signals but the run is mid-utterance → too weak to edit.
        let midway = corrector.decide(utterance: "Ping Shariq, S-H-A-R-I-Q-U-E, tomorrow.")
        guard case .insertLiterally = midway else {
            return XCTFail("expected insertLiterally, got \(midway)")
        }

        // Antecedent only in the PREVIOUS utterance and no trigger → the fix
        // would reach into already-committed text, so it must not happen.
        let crossUtterance = corrector.decide(
            utterance: "S-H-A-R-I-Q-U-E.", previousUtterance: "Hi Shariq.")
        guard case .insertLiterally = crossUtterance else {
            return XCTFail("expected insertLiterally, got \(crossUtterance)")
        }
    }

    func testTriggerWordsCannotWinTheMatch() {
        // "Correction" would otherwise be the nearest scoring token.
        let action = corrector.decide(
            utterance: "Correction, it's spelled S-H-A-R-I-Q-U-E.",
            previousUtterance: "Hi Shariq.")
        guard case .retroReplace(let target, _, _, _) = action else {
            return XCTFail("expected retroReplace, got \(action)")
        }
        XCTAssertEqual(target, "Shariq")
    }

    func testKnownTermIsNotADirective() {
        let aware = SpokenSpellingCorrector(vocabulary: StubVocabulary(terms: ["Sharique"]))
        XCTAssertEqual(
            aware.decide(utterance: "Actually, it's S-H-A-R-I-Q-U-E.", previousUtterance: "Hi Shariq."),
            .none)
    }

    /// Two directives in one utterance: the later one supersedes the earlier.
    func testLastRunWins() {
        let action = corrector.decide(
            utterance: "It's J-S-O-N, actually it's S-H-A-R-I-Q-U-E.",
            previousUtterance: "Hi Shariq.")
        guard case .retroReplace(let target, let replacement, _, _) = action else {
            return XCTFail("expected retroReplace, got \(action)")
        }
        XCTAssertEqual(target, "Shariq")
        XCTAssertEqual(replacement, "Sharique")
    }

    func testNoRunIsNoAction() {
        XCTAssertEqual(corrector.decide(utterance: "Please ping Shariq about the migration."), .none)
        XCTAssertEqual(corrector.decide(utterance: ""), .none)
    }

    func testRecaseFollowsTheAntecedent() {
        XCTAssertEqual(SpokenSpellingCorrector.recase("SHARIQUE", like: "Shariq"), "Sharique")
        XCTAssertEqual(SpokenSpellingCorrector.recase("SHARIQUE", like: "shariq"), "sharique")
        XCTAssertEqual(SpokenSpellingCorrector.recase("JSON", like: "JSN"), "JSON")
    }

    func testDecideIsPureAndFast() {
        let utterance = "No, no, it's spelled S-H-A-R-I-Q-U-E."
        let previous = "Please ping Cherie about the migration and the roadmap."
        let first = corrector.decide(utterance: utterance, previousUtterance: previous)
        for _ in 0..<50 {
            XCTAssertEqual(
                corrector.decide(utterance: utterance, previousUtterance: previous), first)
        }

        let iterations = 200
        let started = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iterations {
            _ = corrector.decide(utterance: utterance, previousUtterance: previous)
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - started
        let perCall = Double(elapsed) / Double(iterations) / 1_000_000
        XCTAssertLessThan(perCall, 1.0, "decide() took \(perCall) ms per call")
    }
}
