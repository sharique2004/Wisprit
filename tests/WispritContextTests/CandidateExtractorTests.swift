import XCTest

@testable import WispritContext

/// Fixture table for the extractor: the must-accepts are the terms context
/// exists to recover, the must-rejects are Wispr Flow's documented auto-add
/// failure ("sprint"/"deploy"), spelled-run junk, and the hard nevers.
final class CandidateExtractorTests: XCTestCase {

    private let lexicon = FixedLexicon(HighFrequencyWords.words)

    private func snapshot(before: String, selected: String = "",
                          after: String = "") -> ContextSnapshot {
        ContextSnapshot(bundleID: "com.apple.TextEdit", before: before,
                        selected: selected, after: after,
                        capturedAt: Date(), generation: 1)
    }

    private func terms(before: String, selected: String = "", after: String = "",
                       maxTerms: Int = CandidateExtractor.defaultMaxTerms) -> [String] {
        CandidateExtractor.candidates(
            in: snapshot(before: before, selected: selected, after: after),
            lexicon: lexicon, maxTerms: maxTerms
        ).map(\.term)
    }

    // MARK: - Must-accepts

    func testInteriorCapitalTokensAreAccepted() {
        XCTAssertEqual(terms(before: "we moved InsForge to the new plan "), ["InsForge"])
        XCTAssertEqual(terms(before: "open the SpeechAnalyzer session "), ["SpeechAnalyzer"])
    }

    func testCapitalizedNameMidSentenceIsAccepted() {
        XCTAssertEqual(terms(before: "so I told Sharique about it "), ["Sharique"])
    }

    func testCodeIdentifiersAreAccepted() {
        XCTAssertEqual(terms(before: "rename snake_case_name in the file "), ["snake_case_name"])
        XCTAssertEqual(terms(before: "the kebab-case flag "), ["kebab-case"])
        XCTAssertEqual(terms(before: "open config.yaml please "), ["config.yaml"])
    }

    func testLetterDigitMixesAreAccepted() {
        XCTAssertEqual(terms(before: "revenue for Q3 "), ["Q3"])
        let accepted = terms(before: "the M4 chip beat v2 today ")
        XCTAssertTrue(accepted.contains("M4"), "\(accepted)")
        XCTAssertTrue(accepted.contains("v2"), "\(accepted)")
    }

    func testPossessiveSuffixIsStripped() {
        XCTAssertEqual(terms(before: "it was Quixly's idea "), ["Quixly"])
    }

    func testSelectedTextSitsAtTheCursorWithFullWeight() {
        let candidates = CandidateExtractor.candidates(
            in: snapshot(before: "so we asked ", selected: "Quixly", after: " about it"),
            lexicon: lexicon)
        XCTAssertEqual(candidates.map(\.term), ["Quixly"])
        XCTAssertEqual(candidates.first?.weight, 1.0)
    }

    // MARK: - Must-rejects (the negative spec)

    func testCommonWordsNeverBecomeCandidates() {
        // Wispr's exact failure: lowercase, and capitalized mid-sentence too.
        XCTAssertEqual(terms(before: "we deploy the sprint board tomorrow "), [])
        XCTAssertEqual(terms(before: "ask the Deploy and Sprint people "), [])
    }

    func testSpelledRunJunkIsRejectedByPlausibility() {
        // "Sharhuue" carries the doubled-vowel tell the learn gate rejects on;
        // the extractor shares that classifier.
        XCTAssertEqual(terms(before: "say hi to Sharhuue for me "), [])
    }

    func testEmailsNeverBecomeBiasingTerms() {
        XCTAssertEqual(terms(before: "mail sharique.khatri@gmail.com the doc "), [])
        // Even a capitalized local part is skipped with its whole chunk.
        XCTAssertEqual(terms(before: "ping Sharique.Khatri@gmail.com now "), [])
    }

    func testUrlsAndBareDomainsNeverBecomeBiasingTerms() {
        XCTAssertEqual(terms(before: "read https://wisprflow.ai/media-kit later "), [])
        XCTAssertEqual(terms(before: "check wisprflow.ai for it "), [])
        XCTAssertEqual(terms(before: "see www.example.org for it "), [])
    }

    func testDigitRunsAreRejected() {
        XCTAssertEqual(terms(before: "my number is 4155551 now "), [])       // 7-digit run
        XCTAssertEqual(terms(before: "the ticket was AB12345678 sadly "), []) // run inside a mix
        XCTAssertEqual(terms(before: "call 415-555-0134 first "), [])         // phone shape
    }

    func testAllCapsRules() {
        // MLX survives (initialisms need no vowel); ASAP is stoplisted; AAAA
        // trips the repeated-letter fault; NEVER is a shouted lexicon word.
        XCTAssertEqual(terms(before: "the MLX port and an ASAP reply plus AAAA spam and NEVER more "),
                       ["MLX"])
        // Nine letters is beyond the ALLCAPS band.
        XCTAssertEqual(terms(before: "the KRZYSZTOF constant here "), [])
    }

    func testSentenceInitialCapitalizationProvesNothing() {
        // Window-start and after-period capitals are skipped; mid-sentence is kept.
        XCTAssertEqual(terms(before: "Quixly came home. We saw Marnix."), ["Marnix"])
    }

    func testAbbreviationsAndHyphenatedProseAreRejected() {
        XCTAssertEqual(terms(before: "see e.g. the notes "), [])
        XCTAssertEqual(terms(before: "a well-known fact "), [])
    }

    func testShortAndOverlongTokensAreRejected() {
        XCTAssertEqual(terms(before: "ab Xy cd "), [])
        XCTAssertEqual(terms(before: "the Q\(String(repeating: "x", count: 40)) thing "), [])
    }

    // MARK: - Ranking

    func testRanksByProximityToTheCursor() {
        XCTAssertEqual(
            terms(before: "we met Zorblatt yesterday and then Quixly ",
                  after: " while Marnix waited"),
            ["Quixly", "Marnix", "Zorblatt"])
    }

    func testFrequencyBreaksDistanceTies() {
        let candidates = CandidateExtractor.candidates(
            in: snapshot(before: "so Quixly said hi and Quixly ", after: " Marnix stayed"),
            lexicon: lexicon)
        XCTAssertEqual(candidates.map(\.term), ["Quixly", "Marnix"])
        XCTAssertGreaterThan(candidates[0].weight, candidates[1].weight,
                             "the repeat earns a frequency bonus")
    }

    func testMaxTermsCapKeepsTheNearest() {
        let window = (1...30).map { "ZX\($0)" }.joined(separator: " ")
        XCTAssertEqual(terms(before: "so it was ", after: " \(window)", maxTerms: 5),
                       ["ZX1", "ZX2", "ZX3", "ZX4", "ZX5"])
    }

    func testOrderingIsDeterministic() {
        let make = {
            self.terms(before: "we met Zorblatt and Quixly near InsForge ",
                       after: " with Marnix and snake_case_name and Q3")
        }
        let first = make()
        for _ in 0..<10 { XCTAssertEqual(make(), first) }
    }

    // MARK: - Performance

    /// Budget is <1 ms on ~600 chars; asserted generously at <10 ms so CI
    /// never flakes, with the measured number printed for the report.
    func testExtractionSpeedOn600Chars() {
        let sentence = "The meeting with InsForge about the Q3 deploy went well "
            + "and Sharique said the sprint board looked fine. "
        let before = String(repeating: sentence, count: 6)  // ≈630 chars
        let snap = snapshot(before: before)
        _ = CandidateExtractor.candidates(in: snap, lexicon: lexicon)  // warm

        let iterations = 100
        let start = DispatchTime.now()
        for _ in 0..<iterations {
            _ = CandidateExtractor.candidates(in: snap, lexicon: lexicon)
        }
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
        let average = seconds / Double(iterations)
        print(String(format: "CandidateExtractor: %.3f ms average on %d chars",
                     average * 1000, before.count))
        XCTAssertLessThan(average, 0.010)
    }
}
