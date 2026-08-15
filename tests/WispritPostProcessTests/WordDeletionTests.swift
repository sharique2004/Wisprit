import XCTest
@testable import WispritPostProcess

// Word-deletion defects, measured through the shipping pipeline.
//
// Every sentence in `mustFix` below was run through the REAL
// `PostProcess.process(_:options:corrections:)` and came back SHORTER than it
// went in — a word (sometimes a clause) deleted from speech that carried no
// command and no correction. Each one is a stage firing on a literal use of its
// own trigger phrase: "no wait" the noun phrase, "scratch that" the transitive
// verb, "period" the noun, "new line" the object, "uh" inside "uh-oh", a
// grammatical doubled function word, a lowercase "may".
//
// The deletions are what makes a dictation app untrustworthy — the user cannot
// see them happen and only finds out when the sentence reads wrong later — so
// the contract here is the strongest one available: for a sentence with no
// directive in it, output == input, byte for byte.
//
// `mustKeep` is the other half of the same contract. The corrections these
// stages exist for are the product's core feature, so every guard added for
// `mustFix` is pinned against the correction shapes it must not disarm.

/// Cases where the native pipeline deliberately no longer matches the Python
/// `Goldens.swift` / `FuzzGoldens.swift` snapshot.
///
/// The generated files stay literal Python output — they are the differential
/// net for ICU-vs-`re` drift and hand-editing them would blind it. A behavior
/// the port deliberately CHANGED belongs here instead, one entry per raw input,
/// with the measurement that justifies it. Four entries, three defects.
enum MeasuredDivergences {
    static let outputs: [String: String] = [
        // Filler removal is word-bounded on `[\w-]` now, not `\w`: a hyphen
        // glues a word together, so "uh-oh"/"uh-huh" are words rather than a
        // hesitation plus a fragment. Python returned "-huh", which is not a
        // word in any language. (Defect: "Uh-oh that broke the build." ->
        // "-oh that broke the build.")
        "uh-huh": "uh-huh",
        // An all-caps filler token is an acronym, not a hesitation — the
        // recognizer writes hesitations as "um"/"Um". (Defect: "She
        // transferred to UH last fall." -> "She transferred to last fall.";
        // UH/UM are universities.)
        "UM Hello UH world": "UM Hello UH world",
        // The duplicate-collapse allowlist no longer contains the doubles that
        // are grammatical English: "in in" (particle + preposition) and "is is"
        // (the pseudo-cleft copula). (Defects: "Please hand it in in March." ->
        // "Please hand it in March."; "What it is is a resourcing problem." ->
        // "What it is a resourcing problem.")
        "in\nin  khatri\ngmail 123 museum": "in\nin khatri\ngmail 123 museum",
        "and io museum  . com hello and 123\nthe uhh  is is":
            "and io museum. com hello and 123\nthe is is",
    ]

    /// The expectation a parity fixture should be held to: the Python value,
    /// unless this table supersedes it.
    static func expectation(_ raw: String, _ python: String) -> String {
        outputs[raw] ?? python
    }
}

final class WordDeletionTests: XCTestCase {
    /// Sentences that must come back exactly as they went in.
    private let mustFix: [(id: String, raw: String)] = [
        // 1. "scratch that" as the transitive verb: "that" is a determiner on
        // "itch", and the leading "Don't" negates the imperative reading.
        ("scratch-idiom", "Don't scratch that itch, it'll get worse."),
        // 2-3. "no wait" as a noun phrase, both literal-use signals.
        ("no-wait-copula", "There is no wait at the DMV."),
        ("no-wait-object", "The clinic has no wait time today."),
        // 4. bare "may"/"march" are a modal and a verb, not a month pair.
        ("may-march", "He may actually march in the parade."),
        // 5-7. grammatical doubled function words.
        ("dup-in-in", "Please hand it in in March."),
        ("dup-on-on", "The show must go on on Friday."),
        ("dup-is-is", "What it is is a resourcing problem."),
        // 8-10. spoken punctuation names used as the nouns they also are.
        ("trailing-period-collocation", "We billed them for the trial period."),
        ("trailing-period-determiner", "Add a grace period"),
        ("trailing-question-quantifier", "She answered every question mark"),
        // 11-12. "new line"/"new paragraph" inside a noun phrase whose
        // determiner sits two words back.
        ("new-line-modifier", "We are launching a brand new line next quarter."),
        ("new-paragraph-modifier", "He started a whole new paragraph about pricing."),
        // 13-14. filler boundaries: a hyphen is not a word boundary, and an
        // all-caps token is an acronym.
        ("filler-hyphen", "Uh-oh that broke the build."),
        ("filler-acronym", "She transferred to UH last fall."),
        // 15. a cross-terminator marker with no restatement evidence: the
        // one-word span fused two sentences into garbage.
        ("cross-terminator-denial", "I finished the report. No, actually Jane finished it."),
        // Already correct before the fix; pinned so it stays that way.
        ("bare-no-answer", "Did we win? No. We lost by two votes."),
    ]

    /// Corrections and commands the guards must not disarm.
    private let mustKeep: [(id: String, raw: String, expected: String)] = [
        ("sc-01", "Let us meet on Thursday. No, actually Wednesday, after lunch.",
         "Let us meet on Wednesday, after lunch."),
        ("sc-02", "I want to have a meeting with Person X on Thursday. Um, no actually Friday.",
         "I want to have a meeting with Person X on Friday."),
        ("sc-03", "Let us move the stand up to half past nine. No, actually, quarter past 10.",
         "Let us move the stand up to quarter past 10."),
        ("sc-04", "The board meeting is in September. No, actually October.",
         "The board meeting is in October."),
        ("sc-05", "Set the retry limit to three. No, actually five.",
         "Set the retry limit to five."),
        // Real months, capitalized, adjacent to a marker: the shape the month
        // class exists for, and the one the ambiguity guard must not cost.
        ("sc-06", "Move the demo to Monday. No, actually Tuesday, "
            + "then push the release to March. Sorry, April.",
         "Move the demo to Tuesday, then push the release to April."),
        // A cross-terminator span with a bare replacement fragment.
        ("sc-07", "Send the invite to Viveque. No, actually, Shariq.",
         "Send the invite to Shariq."),
        // A cross-terminator CLAUSE restart — evidence is the shared opening.
        ("sc-08", "I need to email the vendor today. No, actually, I need to call them right now.",
         "I need to call them right now."),
        // Reported speech, not a correction.
        ("sc-09", "I said no, actually, and I stand by it.",
         "I said no, actually, and I stand by it."),
        // The genuine "scratch that" directive: a restatement clause follows
        // the marker, and no noun object.
        ("sc-10", "The header is wrong scratch that the footer is wrong.",
         "the footer is wrong."),
        ("sc-11", "Did we win? No. We lost by two votes.",
         "Did we win? No. We lost by two votes."),
    ]

    /// Command dictation, which is what every stage in `mustFix` is FOR.
    private let commands: [(id: String, raw: String, expected: String)] = [
        ("cmd-period", "send it now period", "send it now."),
        ("cmd-period-noun-leader", "that is the end period", "that is the end."),
        ("cmd-full-stop", "that is all full stop", "that is all."),
        ("cmd-question", "are you coming question mark", "are you coming?"),
        ("cmd-exclamation", "watch out exclamation point", "watch out!"),
        ("cmd-line", "first item new line second item", "first item\nsecond item"),
        ("cmd-line-next", "shipped it new line next up", "shipped it\nnext up"),
        ("cmd-paragraph", "intro new paragraph body", "intro\n\nbody"),
        ("cmd-no-wait", "send it to Bob no wait Alice", "send it to Alice"),
        ("cmd-no-wait-dup", "send it to Bob no wait to Alice", "send it to Alice"),
        ("cmd-no-wait-class", "meet at three no wait four pm", "meet at four pm"),
        ("cmd-scratch", "call him tomorrow scratch that today", "today"),
        ("cmd-scratch-clause", "draft the email scratch that write the memo", "write the memo"),
        ("cmd-scratch-chain", "first scratch that second scratch that third", "third"),
    ]

    private func assertPipeline(_ raw: String, _ expected: String, _ id: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        let once = PostProcess.process(raw)
        XCTAssertEqual(once, expected, "\(id): \(raw.debugDescription)", file: file, line: line)
        // The live path pastes what the pipeline returns and re-runs on the
        // next partial, so every fixture has to be a fixpoint.
        XCTAssertEqual(PostProcess.process(once), once,
                       "\(id) not idempotent", file: file, line: line)
    }

    func testMeasuredDeletionsAreGone() {
        for (id, raw) in mustFix { assertPipeline(raw, raw, id) }
    }

    func testCorrectionsStillCorrect() {
        for (id, raw, expected) in mustKeep { assertPipeline(raw, expected, id) }
    }

    func testCommandDictationStillWorks() {
        for (id, raw, expected) in commands { assertPipeline(raw, expected, id) }
    }
}

// MARK: - the guards, one at a time

/// Each defect's guard, exercised on the narrowest surface that shows it, so a
/// failure says WHICH rule moved rather than only that a sentence changed.
final class WordDeletionGuardTests: XCTestCase {
    func testScratchThatKeepsItsDirectiveAndDropsTheVerb() {
        // Literal: a negation, a modal, an infinitive or a nominative subject
        // in front of "scratch" means "that" introduces the object.
        for raw in ["Don't scratch that itch.",
                    "do not scratch that spot",
                    "never scratch that surface",
                    "you should not scratch that bite",
                    "I need to scratch that itch",
                    "he will scratch that off the list",
                    "we scratch that plan every year"] {
            XCTAssertEqual(SelfCorrection.apply(raw), raw, raw)
        }
        // Directive: utterance start, or the tail of the clause being retracted.
        XCTAssertEqual(SelfCorrection.apply("scratch that use the other one"),
                       "use the other one")
        XCTAssertEqual(SelfCorrection.apply("the header is wrong scratch that the footer is wrong"),
                       "the footer is wrong")
        XCTAssertEqual(SelfCorrection.apply("nope scratch that Tuesday"), "Tuesday")
        // A literal occurrence never becomes the cut point, but an earlier
        // directive still cuts.
        XCTAssertEqual(SelfCorrection.apply("draft the memo scratch that don't scratch that itch"),
                       "don't scratch that itch")
    }

    func testNoWaitLiteralVersusInterjection() {
        for raw in ["There is no wait at the DMV.",
                    "The clinic has no wait time today.",
                    "there was no wait for the ride",
                    "we have no wait list anymore"] {
            XCTAssertEqual(SelfCorrection.apply(raw), raw, raw)
        }
        // The parity contract, untouched.
        XCTAssertEqual(SelfCorrection.apply("send it to Bob no wait Alice"), "send it to Alice")
        XCTAssertEqual(SelfCorrection.apply("send it to Bob no wait to Alice"), "send it to Alice")
        XCTAssertEqual(SelfCorrection.apply("the total is ten no wait twelve dollars"),
                       "the total is twelve dollars")
        XCTAssertEqual(SelfCorrection.apply("Thursday no wait 3 o'clock"), "3 o'clock")
    }

    func testAmbiguousMonthsNeedMonthEvidence() {
        // Bare modal/verb readings are not class members any more.
        for raw in ["He may actually march in the parade.",
                    "we may sorry we might",
                    "they march no they walk",
                    "it will mar actually ruin the finish"] {
            XCTAssertEqual(SelfCorrection.apply(raw), raw, raw)
        }
        // Capitalization is the evidence dictated text carries.
        XCTAssertEqual(SelfCorrection.apply("due in March no actually April"), "due in April")
        XCTAssertEqual(SelfCorrection.apply("May no June"), "June")
        XCTAssertEqual(SelfCorrection.apply("push it to March. Sorry, April."), "push it to April.")
        // ...or an adjacent day number, which makes a lowercase month behave
        // exactly like the capitalized one — as a month on the right of a
        // joint, and as a date the bare-number class refuses to correct into.
        XCTAssertEqual(SelfCorrection.apply("ship in april no actually march 6"),
                       "ship in march 6")
        for (lower, upper) in [("the deadline is April 5 no actually march 6",
                                "the deadline is April 5 no actually March 6")] {
            XCTAssertEqual(SelfCorrection.apply(lower), lower)
            XCTAssertEqual(SelfCorrection.apply(upper), upper)
        }
        // The unambiguous names never needed evidence and still do not.
        XCTAssertEqual(SelfCorrection.apply("shipping september I mean october"),
                       "shipping october")
    }

    func testDuplicateCollapseOnlyTouchesUngrammaticalDoubles() {
        for raw in ["Please hand it in in March.",
                    "The show must go on on Friday.",
                    "What it is is a resourcing problem.",
                    "what it was was a mistake",
                    "she is very very good at it"] {
            XCTAssertEqual(SelfCorrection.apply(raw), raw, raw)
        }
        // The artifact the rule exists for.
        XCTAssertEqual(SelfCorrection.apply("we need to to fix"), "we need to fix")
        XCTAssertEqual(SelfCorrection.apply("go to the the store"), "go to the store")
        XCTAssertEqual(SelfCorrection.apply("I pushed it to production no wait to staging"),
                       "I pushed it to staging")
    }

    func testTrailingPunctuationNounPhraseGuard() {
        for raw in ["We billed them for the trial period.",
                    "Add a grace period",
                    "there is a notice period",
                    "She answered every question mark",
                    "he ended it with a full stop",
                    "she drew the exclamation point"] {
            XCTAssertEqual(PostProcess.process(raw), raw, raw)
        }
        // A bare spoken name is still the word, never the mark.
        XCTAssertEqual(PostProcess.process("period"), "period")
    }

    func testLineBreakDeterminerLookbackIsTwoWords() {
        for raw in ["We are launching a brand new line next quarter.",
                    "He started a whole new paragraph about pricing.",
                    "that is an entirely new line of work",
                    "the new line that we drew"] {
            XCTAssertEqual(PostProcess.process(raw), raw, raw)
        }
        XCTAssertEqual(PostProcess.process("first line new line second line"),
                       "first line\nsecond line")
        XCTAssertEqual(PostProcess.process("shipped rocket emoji new line next up"),
                       "shipped 🚀\nnext up")
    }

    func testFillerBoundariesAndAcronyms() {
        XCTAssertEqual(PostProcess.process("Uh-oh that broke the build."),
                       "Uh-oh that broke the build.")
        XCTAssertEqual(PostProcess.process("uh-huh, that works"), "uh-huh, that works")
        XCTAssertEqual(PostProcess.process("She transferred to UH last fall."),
                       "She transferred to UH last fall.")
        XCTAssertEqual(PostProcess.process("UM and UH are both universities"),
                       "UM and UH are both universities")
        // ...and the hesitation the stage is actually for, in every case the
        // recognizer emits it in.
        XCTAssertEqual(PostProcess.process("um hello world"), "hello world")
        XCTAssertEqual(PostProcess.process("Um, hello world"), "hello world")
        XCTAssertEqual(PostProcess.process("he said um, and then uh, nothing"),
                       "he said and then nothing")
    }

    func testCrossTerminatorSpanNeedsAFragment() {
        // A whole clause after the marker is a new sentence, not a replacement
        // word: leaving it verbatim is the only safe answer.
        for raw in ["I finished the report. No, actually Jane finished it.",
                    "We shipped the beta. No wait Bob shipped the beta.",
                    "I filed the ticket. No, actually the whole team filed one."] {
            XCTAssertEqual(SelfCorrection.apply(raw), raw, raw)
        }
        // A bare fragment IS a replacement word.
        XCTAssertEqual(SelfCorrection.apply("I want to meet Vivek. No, actually Sharique"),
                       "I want to meet Sharique")
        XCTAssertEqual(SelfCorrection.apply("Ship it to staging. No, actually production."),
                       "Ship it to production.")
        // Two tokens qualify when the first opens a noun phrase.
        XCTAssertEqual(SelfCorrection.apply("Send it to Bob. No, actually the vendor."),
                       "Send it to the vendor.")
        // Inside one sentence nothing changed — the span is the Python span.
        XCTAssertEqual(SelfCorrection.apply("send it to Bob no actually Alice"),
                       "send it to Alice")
    }
}
