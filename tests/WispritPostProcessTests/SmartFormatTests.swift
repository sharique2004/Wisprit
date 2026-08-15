import XCTest
@testable import WispritPostProcess

final class SmartFormatTests: XCTestCase {
    private let on = PostProcessOptions(smartFormatting: true)

    private func assertPipeline(_ raw: String, _ expected: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        let once = PostProcess.process(raw, options: on)
        XCTAssertEqual(once, expected, raw, file: file, line: line)
        XCTAssertEqual(PostProcess.process(once, options: on), once, "not idempotent: \(raw)",
                       file: file, line: line)
    }

    func testSpokenPunctuationMidUtterance() {
        assertPipeline("I can't wait to see you exclamation point Let's meet at seven period",
                       "I can't wait to see you! Let's meet at seven.")
        assertPipeline("When is reading club new line should be tomorrow",
                       "When is reading club\nshould be tomorrow")
        assertPipeline("see you comma then call me", "see you, then call me")
        assertPipeline("items colon one two three", "items: one two three")
        assertPipeline("range tilde 10", "range~ 10")
        assertPipeline("set it to 70 degrees celsius please", "set it to 70°C please")
        assertPipeline("acme trademark here", "acme™ here")
    }

    func testSpokenPunctuationRefusesNounPhrases() {
        for raw in ["let's talk about the comma splice problem",
                    "We billed them for the trial period.",
                    "She answered every question mark",
                    "the oxford comma is useful",
                    "north star guidance"] {
            XCTAssertEqual(PostProcess.process(raw, options: on), raw, raw)
        }
    }

    func testLineBreakAliases() {
        assertPipeline("hello next line world", "hello\nworld")
        assertPipeline("hello line break world", "hello\nworld")
        assertPipeline("intro start a new paragraph body", "intro\n\nbody")
        assertPipeline("hello skip a line please", "hello\nplease")
        XCTAssertEqual(PostProcess.process("the next line of business", options: on),
                       "the next line of business")
    }

    func testNumberedListsNeedVerbs() {
        assertPipeline(
            "My top goals this week are one finish the report two send the presentation",
            "My top goals this week are: 1. Finish the report 2. Send the presentation")
        assertPipeline(
            "we should first write the tests second ship the build third tell the team",
            "we should: 1. Write the tests\n2. Ship the build\n3. Tell the team")
        for raw in ["I have one meeting and two calls",
                    "the first time I saw it",
                    "one or two people, no more than that."] {
            XCTAssertEqual(PostProcess.process(raw, options: on), raw, raw)
        }
    }

    func testPressEnter() {
        let hello = PostProcess.processResult("Hello world press enter", options: on)
        XCTAssertEqual(hello.text, "Hello world")
        XCTAssertTrue(hello.pressEnter)

        let punctuated = PostProcess.processResult("Hello world. Press enter.", options: on)
        XCTAssertEqual(punctuated.text, "Hello world.")
        XCTAssertTrue(punctuated.pressEnter)

        let only = PostProcess.processResult("press enter", options: on)
        XCTAssertEqual(only.text, "")
        XCTAssertTrue(only.pressEnter)

        let mid = PostProcess.processResult("please press enter after you arrive", options: on)
        XCTAssertEqual(mid.text, "please press enter after you arrive")
        XCTAssertFalse(mid.pressEnter)
    }

    func testContextFitLowercasesMidSentence() {
        let options = PostProcessOptions(precedingText: "Can you look at this and",
                                         smartFormatting: true)
        XCTAssertEqual(PostProcess.process("Then send it over", options: options),
                       " then send it over")
        let start = PostProcessOptions(precedingText: "That is done.",
                                       smartFormatting: true)
        XCTAssertEqual(PostProcess.process("Then send it over", options: start),
                       "Then send it over")
    }

    func testMessagingDropsTrailingPeriod() {
        let options = PostProcessOptions(ensureSentencePeriod: true,
                                         frontmostBundleID: "com.tinyspeck.slackmacgap",
                                         smartFormatting: true)
        XCTAssertEqual(PostProcess.process("See you tomorrow", options: options),
                       "See you tomorrow")
        let mail = PostProcessOptions(ensureSentencePeriod: true,
                                      frontmostBundleID: "com.apple.mail",
                                      smartFormatting: true)
        XCTAssertEqual(PostProcess.process("See you tomorrow", options: mail),
                       "See you tomorrow.")
    }

    func testBacktrackStillRunsThroughThePipeline() {
        assertPipeline("Let's do coffee at 2 actually 3", "Let's do coffee at 3")
        assertPipeline("let's meet yesterday actually tomorrow",
                       "let's meet tomorrow")
        assertPipeline("send it to marketing sorry to finance",
                       "send it to finance")
        assertPipeline("meet Thursday wait Friday", "meet Friday")
        assertPipeline("let's meet yesterday, tomorrow", "let's meet tomorrow")
    }

    func testStarEmojiBeatsAsteriskWhenBothAreOn() {
        let options = PostProcessOptions(emojiCommands: true, smartFormatting: true)
        XCTAssertEqual(PostProcess.process("nice work star emoji", options: options),
                       "nice work ⭐")
    }
}
