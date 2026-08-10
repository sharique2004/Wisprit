import XCTest
import WispritKit
@testable import WispritPostProcess

/// Spoken emoji directives — "fantastic work fire emoji" -> "fantastic work 🔥".
///
/// Post-Python stage, so there is no `Goldens.swift` entry to regenerate: the
/// golden files in this target are literal Python `process()` output and must
/// stay that way. Native-only behavior is pinned by hand-written tables here,
/// the precedent set by the other post-Python additions (the `has_letter_run`
/// bypass in WispritRefine, the spoken-spelling detector in WispritCorrections)
/// — both of which ship table-driven XCTest and no Python golden. The existing
/// goldens still guard this stage from the other direction: any of the 400 fuzz
/// cases or 122 curated cases that changed would fail, which is the proof that
/// the new stage is inert on speech that carries no directive.
final class EmojiCommandTests: XCTestCase {
    private func assertCases(_ cases: [(raw: String, expected: String)],
                             _ options: PostProcessOptions = PostProcessOptions(),
                             file: StaticString = #filePath, line: UInt = #line) {
        for (raw, expected) in cases {
            XCTAssertEqual(PostProcess.process(raw, options: options), expected,
                           "input: \(raw.debugDescription)", file: file, line: line)
        }
    }

    // MARK: - converts

    func testConvertsEveryNameInTheShippedTable() {
        for (name, glyph) in PostProcess.emojiTable {
            XCTAssertEqual(PostProcess.process("ship it \(name) emoji"), "ship it \(glyph)", name)
        }
    }

    func testConverts() {
        assertCases([
            // the headline case
            ("fantastic work fire emoji", "fantastic work 🔥"),
            // start of utterance (no preceding word at all)
            ("rocket emoji ship it", "🚀 ship it"),
            ("fire emoji", "🔥"),
            // end of utterance
            ("ship it rocket emoji", "ship it 🚀"),
            // multi-word names
            ("nice thumbs up emoji", "nice 👍"),
            ("nope thumbs down emoji", "nope 👎"),
            ("done check mark emoji", "done ✅"),
            ("failed cross mark emoji", "failed ❌"),
            ("thanks folded hands emoji", "thanks 🙏"),
            ("great idea light bulb emoji", "great idea 💡"),
            ("nailed it bullseye emoji", "nailed it 🎯"),
            // longest-first: the two-word name wins over its one-word prefix,
            // and over a one-word name that would otherwise absorb the leader.
            ("shipped one hundred emoji", "shipped 💯"),
            ("one hundred emoji", "💯"),
            ("love it red heart emoji", "love it ❤️"),
            // several in one utterance
            ("ship it rocket emoji and fire emoji", "ship it 🚀 and 🔥"),
            ("clap emoji clap emoji clap emoji", "👏 👏 👏"),
            ("nice thumbs up emoji great work fire emoji", "nice 👍 great work 🔥"),
            // punctuation adjacency — the directive is an in-place substitution,
            // so what surrounds it is untouched.
            ("great work fire emoji!", "great work 🔥!"),
            ("great work fire emoji.", "great work 🔥."),
            ("fire emoji, then ship", "🔥, then ship"),
            ("(party emoji)", "(🎉)"),
            ("shipped it — rocket emoji", "shipped it — 🚀"),
            // case-insensitive, like every other command (all-caps is the one
            // exception — see testSpelledRunsAreSkipped)
            ("Fire Emoji", "🔥"),
            ("nice Thumbs Up Emoji", "nice 👍"),
            ("well done Clap Emoji", "well done 👏"),
            // relaxed internal whitespace, like the dictionary's phrases
            ("nice thumbs  up emoji", "nice 👍"),
            ("nice thumbs up  emoji", "nice 👍"),
        ])
    }

    func testComposesWithTheOtherCommandsInTheSameStage() {
        assertCases([
            // the trailing-punctuation pass still sees its own words
            ("great work fire emoji period", "great work 🔥."),
            ("is it done check mark emoji question mark", "is it done ✅?"),
            // line breaks are inserted before the glyph substitution runs
            ("shipped rocket emoji new line next up", "shipped 🚀\nnext up"),
            // and the whitespace tidy cleans the seam afterwards
            ("shipped   rocket emoji   done", "shipped 🚀 done"),
        ])
    }

    func testComposesWithTheOtherPipelineStages() {
        assertCases([
            ("um great work uh fire emoji", "great work 🔥"),
            ("visit example dot com rocket emoji", "visit example.com 🚀"),
            // The stage-ordering case: "that" is both a determiner (the emoji
            // guard) and the self-correction marker. Because the directive runs
            // AFTER self-correction, the marker is resolved first and this is a
            // directive, not the noun phrase "that fire emoji".
            ("nope scratch that fire emoji", "🔥"),
            ("send the memo scratch that thumbs up emoji", "👍"),
            // ...and the noun phrase on its own is still protected.
            ("that fire emoji is overused", "that fire emoji is overused"),
        ])
    }

    /// The gaps in the directive are `[ \t]+`, never `\s+`, so it can never
    /// reach across a line break stage 4 just inserted.
    func testDirectiveNeverSpansAnInsertedLineBreak() {
        XCTAssertEqual(PostProcess.process("fire new line emoji"), "fire\nemoji")
        XCTAssertEqual(PostProcess.process("shipped it fire emoji new paragraph next"),
                       "shipped it 🔥\n\nnext")
    }

    // MARK: - must not convert

    func testMustNotConvert() {
        let untouched = [
            // "emoji" is REQUIRED: a bare name is just a word.
            "the building is on fire",
            "we shipped the rocket today",
            "she has a big heart",
            "check the logs",
            "one hundred percent agree",
            "party at my place",
            "eyes on the prize",
            // determiner guards — the user is talking ABOUT the emoji
            "the fire emoji",
            "a heart emoji",
            "an eyes emoji",
            "that fire emoji",
            "this rocket emoji",
            "my favourite is the fire emoji",
            "send me the thumbs up emoji",
            "one heart emoji",
            "the one hundred emoji",
            // interrogatives / demonstratives
            "which fire emoji",
            "what heart emoji",
            "those party emoji",
            // prepositions — "emoji" is the object of the sentence
            "a post about fire emoji",
            "reply with thumbs up emoji",
            "she asked for check mark emoji",
            "the docs on warning emoji",
            // "which emoji" has no table name in front of "emoji" at all, so it
            // is not even a candidate match.
            "which emoji did you mean",
            "what emoji is that",
            // plural is a noun, not a directive
            "fire emojis are overused",
            // the name has to be a whole spoken word
            "campfire emoji",
            "re-fire emoji",
            // a name that is not in the curated table stays put
            "unicorn emoji",
            "banana emoji",
            "question mark emoji",
        ]
        for raw in untouched {
            XCTAssertEqual(PostProcess.process(raw), raw, "input: \(raw.debugDescription)")
        }
    }

    func testEveryDeterminerFromTheLineBreakGuardAlsoGuardsTheEmojiDirective() {
        for determiner in ["a", "an", "the", "this", "that", "another", "each", "every", "one",
                           "my", "your", "our", "his", "her", "their", "its", "some", "any", "no"] {
            let raw = "\(determiner) fire emoji"
            XCTAssertEqual(PostProcess.process(raw), raw, determiner)
        }
    }

    func testSpelledRunsAreSkipped() {
        // Assertion, not a workhorse: post-corrections a spelled run should
        // never reach the pipeline. Uppercase is the invariant the rest of the
        // app keys on (README "Detection is a regex, not a model").
        for raw in ["F-I-R-E emoji", "S-T-A-R emoji", "FIRE EMOJI",
                    "it is S-M-I-L-E emoji", "nice THUMBS UP EMOJI"] {
            XCTAssertEqual(PostProcess.process(raw), raw, raw)
        }
        // ...while ordinary mixed-case speech in the same shape still converts.
        XCTAssertEqual(PostProcess.process("it is Fire emoji"), "it is 🔥")
    }

    // MARK: - the gate

    func testStageIsGatedByEmojiCommands() {
        let off = PostProcessOptions(emojiCommands: false)
        assertCases([
            ("fantastic work fire emoji", "fantastic work fire emoji"),
            ("ship it rocket emoji and fire emoji", "ship it rocket emoji and fire emoji"),
        ], off)
        // Everything else in the stage keeps working with the gate off.
        assertCases([
            ("first line new line second line", "first line\nsecond line"),
            ("are you coming question mark", "are you coming?"),
        ], off)
    }

    func testDefaultIsOnAndTheSettingsKeyIsEmojiCommands() {
        XCTAssertTrue(PostProcessOptions().emojiCommands)
        XCTAssertTrue(PostProcessOptions { _ in nil }.emojiCommands)
        let settings: [String: Any] = ["emoji_commands": false]
        XCTAssertFalse(PostProcessOptions { settings[$0] }.emojiCommands)
        XCTAssertEqual(PostProcessOptions { settings[$0] },
                       PostProcessOptions(emojiCommands: false))
    }

    // MARK: - the table itself

    func testShippedTableIsTheCuratedThirtyThree() {
        XCTAssertEqual(PostProcess.emojiTable.count, 33)
        XCTAssertEqual(PostProcess.emojiTable.map(\.name), [
            "fire", "thumbs up", "thumbs down", "heart", "red heart", "rocket",
            "check mark", "check", "cross mark", "laughing", "joy", "party",
            "tada", "eyes", "hundred", "one hundred", "clap", "folded hands",
            "pray", "thinking", "smile", "wink", "sob", "skull", "warning",
            "star", "sparkles", "muscle", "wave", "salute", "handshake",
            "light bulb", "bullseye",
        ])
        // Names are the lookup keys: lowercase, single-spaced, unique.
        for (name, _) in PostProcess.emojiTable {
            XCTAssertEqual(name, PostProcess.normalizedEmojiName(name), name)
        }
        XCTAssertEqual(Set(PostProcess.emojiTable.map(\.name)).count, 33)
        // Synonyms deliberately share a glyph.
        XCTAssertEqual(Set(PostProcess.emojiTable.map(\.glyph)).count, 27)
    }

    /// Every name whose *last* word is itself a name must resolve to the longer
    /// one — the property the longest-first alternation exists to guarantee.
    func testLongerNamesWinOverTheirTrailingSingleWordName() {
        let single = Set(PostProcess.emojiTable.map(\.name).filter { !$0.contains(" ") })
        for (name, glyph) in PostProcess.emojiTable
        where name.contains(" ") && single.contains(String(name.split(separator: " ").last!)) {
            XCTAssertEqual(PostProcess.process("say \(name) emoji"), "say \(glyph)", name)
        }
    }

    func testLatencyBudgetHoldsWithTheNewStage() {
        let raw = String(repeating: "fantastic work fire emoji and the rocket emoji ", count: 40)
        let start = DispatchTime.now().uptimeNanoseconds
        _ = PostProcess.process(raw)
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        XCTAssertLessThan(ms, 20)
    }
}
