import XCTest
@testable import WispritEngine

/// The classifier that made `outcome=empty` readable. Every row here is a shape
/// that appeared in production and could not be told from the others.
final class EmptyReasonTests: XCTestCase {

    private struct Case {
        var name: String
        var text = ""
        var timedOut = false
        var crashed = false
        var starved = false
        var peak: Float = 0
        var heldMs: Double = 2_000
        var shortHoldMs: Double = 1_000
        var expected: EmptyReason?
    }

    private func run(_ cases: [Case], file: StaticString = #filePath, line: UInt = #line) {
        for c in cases {
            let result = UtteranceResult(
                text: c.text, engine: "apple_live", finalizeMs: 100,
                timedOut: c.timedOut, crashed: c.crashed, starvedInput: c.starved,
                peakLevel: c.peak)
            XCTAssertEqual(
                EmptyReason.classify(result: result, heldMs: c.heldMs,
                                     shortHoldMs: c.shortHoldMs),
                c.expected, c.name, file: file, line: line)
        }
    }

    // MARK: text wins over every reason

    func testAResultWithTextHasNothingToExplain() {
        run([
            Case(name: "plain text", text: "hello world", expected: nil),
            Case(name: "text after a timeout", text: "as far as it got",
                 timedOut: true, expected: nil),
            Case(name: "text after a crash", text: "partial words",
                 crashed: true, expected: nil),
            Case(name: "whitespace only is empty", text: "   ", expected: .silent),
        ])
    }

    // MARK: priority

    func testTheMostCompleteExplanationWins() {
        run([
            Case(name: "crash outranks everything", timedOut: true, crashed: true,
                 starved: true, peak: 0.4, expected: .crashed),
            Case(name: "timeout outranks starvation", timedOut: true, starved: true,
                 peak: 0.4, expected: .timedOut),
            Case(name: "starvation outranks silence", starved: true, peak: 0,
                 heldMs: 300, expected: .starved),
            Case(name: "starvation outranks a loud hold", starved: true, peak: 0.4,
                 expected: .starved),
        ])
    }

    // MARK: the audio-level split

    func testInaudibleAudioSplitsByHowLongTheKeyWasHeld() {
        run([
            Case(name: "held long, said nothing", peak: 0, heldMs: 2_000, expected: .silent),
            Case(name: "fumbled tap", peak: 0, heldMs: 400, expected: .shortHold),
            Case(name: "room tone under the threshold", peak: 0.0199, heldMs: 2_000,
                 expected: .silent),
            Case(name: "exactly at the hold boundary is not short", peak: 0,
                 heldMs: 1_000, expected: .silent),
            Case(name: "custom short-hold budget", peak: 0, heldMs: 1_400,
                 shortHoldMs: 1_500, expected: .shortHold),
        ])
    }

    /// The residue: nothing benign applies, so the engine ate real speech.
    func testAudibleSpeechWithACleanFinishIsTheDefect() {
        run([
            Case(name: "at the voiced threshold", peak: 0.02, heldMs: 2_000,
                 expected: .producedNothing),
            Case(name: "normal speech", peak: 0.41, heldMs: 3_500,
                 expected: .producedNothing),
            Case(name: "loud but brief — the level gate decides first", peak: 0.41,
                 heldMs: 400, expected: .producedNothing),
        ])
    }

    /// The gate is the engine's own constant, not a copy that can drift.
    func testTheLevelGateIsTheEnginesVoicedThreshold() {
        let below = UtteranceResult(text: "", engine: "apple_live", finalizeMs: 40,
                                    peakLevel: SpeechAnalyzerEngine.voicedPeakThreshold.nextDown)
        let at = UtteranceResult(text: "", engine: "apple_live", finalizeMs: 40,
                                 peakLevel: SpeechAnalyzerEngine.voicedPeakThreshold)
        XCTAssertEqual(EmptyReason.classify(result: below, heldMs: 2_000), .silent)
        XCTAssertEqual(EmptyReason.classify(result: at, heldMs: 2_000), .producedNothing)
    }

    /// The engine sets `producedNothing` itself; the classifier must reach the
    /// same verdict from the raw fields, or offline replay would disagree with live.
    func testClassificationAgreesWithTheEnginesOwnFlag() {
        let engineSaid = UtteranceResult(
            text: "", engine: "apple_live", finalizeMs: 120, timedOut: false,
            crashed: false, starvedInput: false, peakLevel: 0.31, producedNothing: true)
        XCTAssertEqual(EmptyReason.classify(result: engineSaid, heldMs: 2_400),
                       .producedNothing)
    }

    // MARK: on-disk vocabulary

    func testRawValuesAreTheOnDiskVocabulary() {
        XCTAssertEqual(EmptyReason.allCases.map(\.rawValue),
                       ["timed_out", "crashed", "starved", "silent",
                        "short_hold", "produced_nothing"])
    }

    func testDefaultedFieldsKeepEveryOlderConstructionSiteHonest() {
        let legacy = UtteranceResult(text: "", engine: "none", finalizeMs: 0, timedOut: true)
        XCTAssertEqual(legacy.peakLevel, 0)
        XCTAssertFalse(legacy.producedNothing)
        XCTAssertEqual(EmptyReason.classify(result: legacy, heldMs: 2_000), .timedOut)
    }
}
