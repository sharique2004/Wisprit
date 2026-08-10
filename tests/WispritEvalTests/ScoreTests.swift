import XCTest
@testable import WispritEval

/// Hand-checked alignments and rates. Every expectation here was computed by
/// hand from the Levenshtein table, not read back from the implementation.
final class ScoreTests: XCTestCase {

    // MARK: - alignment

    func testAlignmentCounts() {
        let cases: [(ref: [String], hyp: [String], hits: Int, sub: Int, del: Int, ins: Int)] = [
            (["the", "quick", "brown", "fox"], ["the", "quick", "brown", "fox"], 4, 0, 0, 0),
            (["a", "b", "c"], ["a", "x", "c"], 2, 1, 0, 0),
            (["a", "b", "c"], ["a", "c"], 2, 0, 1, 0),
            (["a", "c"], ["a", "b", "c"], 2, 0, 0, 1),
            // "abcd" → "axd": substitute b→x, delete c. Distance 2.
            (["a", "b", "c", "d"], ["a", "x", "d"], 2, 1, 1, 0),
            ([], ["a", "b"], 0, 0, 0, 2),
            (["a", "b"], [], 0, 0, 2, 0),
            ([], [], 0, 0, 0, 0),
        ]
        for c in cases {
            let ops = Score.align(ref: c.ref, hyp: c.hyp)
            let label = "\(c.ref) → \(c.hyp)"
            XCTAssertEqual(ops.hits, c.hits, "hits, \(label)")
            XCTAssertEqual(ops.sub, c.sub, "sub, \(label)")
            XCTAssertEqual(ops.del, c.del, "del, \(label)")
            XCTAssertEqual(ops.ins, c.ins, "ins, \(label)")
            XCTAssertEqual(ops.errors, c.sub + c.del + c.ins, "errors, \(label)")
        }
    }

    /// The alignment is what makes a bad number debuggable, so its shape is
    /// pinned too — in reference order, with the operand on each side.
    func testAlignmentPairs() {
        let ops = Score.align(ref: ["a", "b", "c", "d"], hyp: ["a", "x", "d"])
        XCTAssertEqual(ops.pairs, [
            AlignedPair(op: .hit, ref: "a", hyp: "a"),
            AlignedPair(op: .del, ref: "b", hyp: nil),
            AlignedPair(op: .sub, ref: "c", hyp: "x"),
            AlignedPair(op: .hit, ref: "d", hyp: "d"),
        ])
    }

    // MARK: - WER

    func testWordErrorRateOverAsrProfile() {
        let result = Score.wer(ref: "the cat sat on the mat", hyp: "the cat sat on a mat")
        XCTAssertEqual(result.refWords, 6)
        XCTAssertEqual(result.sub, 1)
        XCTAssertEqual(result.del, 0)
        XCTAssertEqual(result.ins, 0)
        XCTAssertEqual(result.errors, 1)
        XCTAssertEqual(result.rate, 1.0 / 6.0, accuracy: 1e-12)
    }

    /// The .asr profile is formatting-blind by construction: these pairs differ
    /// only in things the acoustic model never chose.
    func testFormattingIsFreeUnderAsrProfile() {
        let pairs = [
            ("Hello, world!", "hello world"),
            ("The meeting is at three fifteen.", "the meeting is at 3:15"),
            ("twenty three items", "23 items"),
            ("Send me an e-mail.", "send me an email"),
        ]
        for (ref, hyp) in pairs {
            XCTAssertEqual(Score.wer(ref: ref, hyp: hyp).errors, 0, "\(ref) / \(hyp)")
        }
        // …and the same pair is NOT free once formatting counts.
        XCTAssertGreaterThan(Score.wer(ref: "Hello, world!", hyp: "hello world",
                                       profile: .rendered).errors, 0)
    }

    func testEmptyReferenceHasNoDenominatorToHideBehind() {
        XCTAssertEqual(Score.wer(ref: "", hyp: "").rate, 0)
        // Inventing a sentence from silence is a total failure, not a 0% WER.
        XCTAssertEqual(Score.wer(ref: "", hyp: "hello there").rate, 1)
    }

    /// Corpus WER is Σerrors/Σrefwords. A macro-average lets a one-word
    /// utterance outvote a ten-word one, which is exactly the distortion the
    /// scoreboard must not ship.
    func testMicroAverageIsNotMacroAverage() {
        let long = Score.wer(ref: "alpha bravo charlie delta echo foxtrot golf hotel india juliet",
                             hyp: "alpha bravo charlie delta echo foxtrot golf hotel india juliette")
        let short = Score.wer(ref: "yes", hyp: "no")
        XCTAssertEqual(long.refWords, 10)
        XCTAssertEqual(long.errors, 1)
        XCTAssertEqual(short.refWords, 1)
        XCTAssertEqual(short.errors, 1)

        let results = [long, short]
        XCTAssertEqual(Score.microAverage(results), 2.0 / 11.0, accuracy: 1e-12)
        XCTAssertEqual(Score.macroAverage(results), (0.1 + 1.0) / 2.0, accuracy: 1e-12)

        let total = Score.aggregate(results)
        XCTAssertEqual(total.errors, 2)
        XCTAssertEqual(total.refWords, 11)
        XCTAssertEqual(total.rate, Score.microAverage(results), accuracy: 1e-12)
    }

    // MARK: - CER

    func testCharacterErrorRateOverRenderedProfile() {
        // "Hello, world" (12) → "hello world": substitute H→h, delete ','.
        let result = Score.cer(ref: "Hello, world", hyp: "hello world")
        XCTAssertEqual(result.refChars, 12)
        XCTAssertEqual(result.sub, 1)
        XCTAssertEqual(result.del, 1)
        XCTAssertEqual(result.ins, 0)
        XCTAssertEqual(result.rate, 2.0 / 12.0, accuracy: 1e-12)
        XCTAssertEqual(Score.cer(ref: "same", hyp: "same").errors, 0)
    }

    // MARK: - term recall

    /// Whole-word semantics, copied from `VocabularyChannel.termHits`: a term is
    /// not recalled just because it is a prefix of something else.
    func testTermRecallIsWholeWord() {
        let recall = Score.termRecall(refTerms: ["InsForge", "Wisprit"],
                                      hyp: "we shipped InsForged to wisprit today")
        XCTAssertEqual(recall.found, ["Wisprit"])
        XCTAssertEqual(recall.missing, ["InsForge"])
        XCTAssertEqual(recall.hits, ["Wisprit": 1])
        XCTAssertEqual(recall.total, 2)
        XCTAssertEqual(recall.rate, 0.5, accuracy: 1e-12)
    }

    func testTermRecallRelaxesInterWordWhitespace() {
        let recall = Score.termRecall(refTerms: ["Wispr Flow"],
                                      hyp: "we compared wispr  flow yesterday")
        XCTAssertEqual(recall.found, ["Wispr Flow"])
        XCTAssertEqual(recall.hits["Wispr Flow"], 1)
    }

    func testTermRecallCountsRepeats() {
        let recall = Score.termRecall(refTerms: ["Wisprit"], hyp: "Wisprit and wisprit again")
        XCTAssertEqual(recall.hits["Wisprit"], 2)
        XCTAssertEqual(recall.rate, 1)
    }

    func testTermRecallWithNoExpectedTerms() {
        let recall = Score.termRecall(refTerms: [], hyp: "anything")
        XCTAssertEqual(recall.total, 0)
        XCTAssertEqual(recall.rate, 1)
    }

    // MARK: - zero edit

    func testZeroEditToleratesOnlyWhitespaceAndATrailingMark() {
        XCTAssertTrue(Score.isZeroEdit(ref: "Hello world.", hyp: "Hello world"))
        XCTAssertTrue(Score.isZeroEdit(ref: "Hello  world", hyp: "Hello world"))
        XCTAssertTrue(Score.isZeroEdit(ref: "Hello world", hyp: "Hello world!"))
        XCTAssertFalse(Score.isZeroEdit(ref: "Hello world", hyp: "hello world"))
        XCTAssertFalse(Score.isZeroEdit(ref: "Hello, world", hyp: "Hello world"))
        XCTAssertFalse(Score.isZeroEdit(ref: "Hello world", hyp: "Hello there"))
    }

    func testZeroEditRate() {
        let pairs = [(ref: "a.", hyp: "a"), (ref: "b", hyp: "b"), (ref: "c", hyp: "d")]
        XCTAssertEqual(Score.zeroEditRate(pairs), 2.0 / 3.0, accuracy: 1e-12)
        XCTAssertEqual(Score.zeroEditRate([]), 0)
    }
}
