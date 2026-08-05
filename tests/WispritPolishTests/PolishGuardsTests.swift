import XCTest
@testable import WispritPolish

/// The new half of the cage — the guards that have no Python ancestor, because
/// polish's failure policy is the inverse of refine's: a doubtful rewrite must
/// be DETECTED and reported, not silently swapped for the original.
final class PolishGuardsTests: XCTestCase {

    // MARK: - launder = strip wrappers ∘ sanitize ∘ strip wrappers

    func testLaunderPeelsFenceAndMetaParagraph() {
        let raw = "```\nLet me rewrite:\n\nThe deck is ready.\n```"
        XCTAssertEqual(PolishGuards.launder(raw), "The deck is ready.")
    }

    func testLaunderPeelsEchoedTagPair() {
        // The model sometimes echoes the delimiter it was handed.
        XCTAssertEqual(PolishGuards.launder("<transcript>The deck is ready.</transcript>"),
                       "The deck is ready.")
    }

    func testLaunderUnwrapsQuotesRevealedByTheMetaStrip() {
        let raw = "Here's the corrected version:\n\n\"The deck is ready.\""
        XCTAssertEqual(PolishGuards.launder(raw), "The deck is ready.")
    }

    func testLaunderLeavesCleanTextAlone() {
        let clean = "Could you please send me the deck when you have a moment?"
        XCTAssertEqual(PolishGuards.launder(clean), clean)
    }

    func testLaunderKeepsLegitimateMultiParagraphOutput() {
        let email = "Hello,\n\nPlease wait for the report.\n\nThank you."
        XCTAssertEqual(PolishGuards.launder(email), email)
    }

    // MARK: - refusal

    func testRefusalsAreDetected() {
        let refusals = [
            "I'm sorry, but I can't help with that.",
            "I am sorry — I cannot rewrite this text.",
            "Sorry, I'm unable to assist with that request.",
            "Unfortunately I can not complete this rewrite.",
            "As an AI language model, I don't have the ability to do that.",
            "I cannot rewrite content that is not appropriate.",
        ]
        for text in refusals {
            XCTAssertTrue(PolishGuards.refused(text), "missed refusal: \(text)")
        }
    }

    func testDictatedApologiesAreNotRefusals() {
        // The single most likely false positive: the SPEAKER apologizing. A
        // formal rewrite of "um so sorry i missed your call" legitimately opens
        // with an apology and must survive.
        let genuine = [
            "Sorry I missed your call earlier — let's sync tomorrow.",
            "I'm sorry about the delay; the numbers took longer than expected.",
            "I am sorry that I could not attend the review yesterday.",
            "Unfortunately the build broke again and I will look at it tonight.",
            "Sorry, can we push the meeting to Thursday?",
        ]
        for text in genuine {
            XCTAssertFalse(PolishGuards.refused(text), "false refusal: \(text)")
        }
    }

    // MARK: - plausibility

    func testCleanUpDelegatesToTheRefineBand() {
        // Identity-preserving mode: same measured band as the on-path stage.
        let raw = "um so basically we should uh probably migrate the database"
        XCTAssertTrue(PolishGuards.plausible(
            raw: raw, polished: "So basically we should probably migrate the database.",
            mode: .cleanUp))
        XCTAssertFalse(PolishGuards.plausible(raw: raw, polished: "Migrate it.", mode: .cleanUp))
    }

    func testFormalMayInflateSpeechButNotRunAway() {
        let raw = "hey can u send me that deck thing whenever ur free"   // 10 words
        XCTAssertTrue(PolishGuards.plausible(
            raw: raw,
            polished: "Could you please send me the deck when you have a moment?",
            mode: .makeFormal))
        // A whole invented letter is the runaway failure mode.
        let letter = String(repeating: "Dear colleague, I hope this message finds you well. ",
                            count: 8)
        XCTAssertFalse(PolishGuards.plausible(raw: raw, polished: letter, mode: .makeFormal))
    }

    func testCasualMayShortenButNotSummarizeAway() {
        let raw = "i would like to request that we postpone the meeting until thursday"
        XCTAssertTrue(PolishGuards.plausible(
            raw: raw, polished: "Can we push the meeting to Thursday?", mode: .makeCasual))
        XCTAssertFalse(PolishGuards.plausible(raw: raw, polished: "Sure.", mode: .makeCasual))
    }

    func testAIPromptMayRestructure() {
        let raw = "um can you like write me a python script that renames all the files "
            + "in a folder to lowercase"
        XCTAssertTrue(PolishGuards.plausible(
            raw: raw,
            polished: "Write a Python script that renames every file in a folder to lowercase.",
            mode: .asAIPrompt))
        // Restructuring into a short bullet list is legitimate.
        XCTAssertTrue(PolishGuards.plausible(
            raw: raw,
            polished: "Write a Python script that:\n- walks a folder\n- renames every file to "
                + "lowercase\n- leaves directories untouched",
            mode: .asAIPrompt))
        // Answering the prompt (writing the script) is not.
        let script = String(repeating: "import os\nfor name in os.listdir(path):\n"
                            + "    os.rename(name, name.lower())\n", count: 10)
        XCTAssertFalse(PolishGuards.plausible(raw: raw, polished: script, mode: .asAIPrompt))
    }

    func testAssistantOpenerIsRejectedInEveryMode() {
        let raw = "can you send me the q3 report by friday"
        for mode in PolishMode.allCases {
            XCTAssertFalse(PolishGuards.plausible(
                raw: raw, polished: "Sure, here's the report you asked for.", mode: mode),
                "\(mode.rawValue) accepted an assistant reply")
        }
    }

    func testSpeakerOwnOpenerSurvivesTheAssistantCheck() {
        // "Here is the plan" is a normal thing to dictate; the opener check
        // only fires when the model INVENTED the opener.
        let raw = "here is the plan we ship on friday and announce on monday"
        XCTAssertTrue(PolishGuards.plausible(
            raw: raw,
            polished: "Here is the plan: we ship on Friday and announce on Monday.",
            mode: .makeFormal))
    }

    func testEmptyOutputIsNeverPlausible() {
        for mode in PolishMode.allCases {
            XCTAssertFalse(PolishGuards.plausible(raw: "some words here", polished: "   ",
                                                  mode: mode))
        }
    }

    func testShortInputsGetSmallGrowthSlack() {
        // "thank you" must never come back as a paragraph in any mode.
        let raw = "thank you"
        let paragraph = "Thank you very much for your time today. I really appreciate all of "
            + "the effort that you and the wider team have put into this project."
        for mode in PolishMode.allCases {
            XCTAssertFalse(PolishGuards.plausible(raw: raw, polished: paragraph, mode: mode),
                           "\(mode.rawValue) let a two-word input balloon")
        }
        XCTAssertTrue(PolishGuards.plausible(raw: raw, polished: "Thank you.", mode: .makeFormal))
    }
}
