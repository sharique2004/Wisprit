import XCTest
@testable import WispritPostProcess

/// The deterministic self-correction engine — "I want to have a meeting with
/// person x on Thursday umm no actually Friday" -> "… on Friday".
///
/// Post-Python behavior, so (like `EmojiCommandTests`) there is no golden to
/// regenerate: `Goldens.swift` / `FuzzGoldens.swift` stay literal Python output
/// and pin the *old* markers from the other direction — any of their 522 cases
/// that moved would fail, which is the proof that the new tiers are inert on
/// speech that carries no correction.
///
/// Every table below is asserted twice: once for the value, once for
/// idempotence. The live path re-runs the engine on each growing partial, so
/// `apply(apply(x)) == apply(x)` is a shipping requirement, not a nicety.
final class SelfCorrectionTests: XCTestCase {
    private func assertCases(_ cases: [(raw: String, expected: String)],
                             file: StaticString = #filePath, line: UInt = #line) {
        for (raw, expected) in cases {
            let once = SelfCorrection.apply(raw)
            XCTAssertEqual(once, expected, "input: \(raw.debugDescription)", file: file, line: line)
            XCTAssertEqual(SelfCorrection.apply(once), once,
                           "not idempotent: \(raw.debugDescription)", file: file, line: line)
        }
    }

    private func assertUntouched(_ cases: [String],
                                 file: StaticString = #filePath, line: UInt = #line) {
        assertCases(cases.map { ($0, $0) }, file: file, line: line)
    }

    // MARK: - the user's sentence

    func testTheRequestedSentence() {
        // Verbatim from the feature request, with the recognizer's misspelling
        // normalized (the misspelling family is covered separately below).
        let raw = "I want to have a meeting with person x on Thursday umm no actually Friday"
        XCTAssertEqual(PostProcess.process(raw),
                       "I want to have a meeting with person x on Friday")
        // ...and the trailing-period policy is untouched by the rewrite.
        XCTAssertEqual(PostProcess.process(raw, options: PostProcessOptions(ensureSentencePeriod: true)),
                       "I want to have a meeting with person x on Friday.")
        // The engine reaches the same answer on the RAW partial, before stage 1
        // has stripped anything — the live path never sees a cleaned string.
        XCTAssertEqual(SelfCorrection.apply(raw),
                       "I want to have a meeting with person x on Friday")
    }

    func testWithAndWithoutFillers() {
        assertCases([
            ("meeting on Thursday no actually Friday", "meeting on Friday"),
            ("meeting on Thursday umm no actually Friday", "meeting on Friday"),
            ("meeting on Thursday uh no actually Friday", "meeting on Friday"),
            ("meeting on Thursday no actually uh Friday", "meeting on Friday"),
            ("meeting on Thursday erm no umm actually erm Friday", "meeting on Friday"),
            // a filler is never the word a correction replaces
            ("meeting on Thursday umm no wait Friday", "meeting on Friday"),
        ])
    }

    // MARK: - tier (a): closed-class pairs

    func testEveryConnective() {
        for connective in ["no", "no wait", "no actually", "actually", "I mean",
                           "make that", "or rather", "sorry", "uh no", "umm no"] {
            let raw = "let's meet Thursday \(connective) Friday"
            XCTAssertEqual(SelfCorrection.apply(raw), "let's meet Thursday Friday".replacingOccurrences(
                of: "Thursday ", with: ""), connective)
        }
    }

    func testWeekdays() {
        assertCases([
            ("Monday no Tuesday", "Tuesday"),
            ("see you Wednesday actually Thursday", "see you Thursday"),
            ("ship it Friday make that Saturday", "ship it Saturday"),
            ("Sunday or rather Monday works", "Monday works"),
            // the recognizer's misspelling family is in the class too
            ("meeting on thuersay no actually Friday", "meeting on Friday"),
            ("meeting on wendsday umm no Thursday", "meeting on Thursday"),
        ])
    }

    func testMonths() {
        assertCases([
            ("due in March no actually April", "due in April"),
            ("due in Jan sorry Feb", "due in Feb"),
            ("shipping September I mean October", "shipping October"),
            ("May no June", "June"),
        ])
    }

    func testClockTimes() {
        assertCases([
            ("at 3 o'clock no actually 4 o'clock", "at 4 o'clock"),
            ("at three o'clock sorry four o'clock", "at four o'clock"),
            ("at 3:15 no 3:45", "at 3:45"),
            ("at 9am actually 10am", "at 10am"),
            ("at 9 am make that 10 pm", "at 10 pm"),
            ("half past three no actually half past four", "half past four"),
            ("quarter past two I mean quarter to three", "quarter to three"),
        ])
    }

    func testNumbersAndOrdinals() {
        assertCases([
            ("I need 3 no 4 copies", "I need 4 copies"),
            ("I need three no actually four copies", "I need four copies"),
            ("the total is ten sorry twelve", "the total is twelve"),
            ("chapter 3 make that 4", "chapter 4"),
            ("the 3rd or rather 4th", "the 4th"),
            ("the first actually second", "the second"),
            ("twenty one I mean twenty two", "twenty two"),
            ("in 2020 no actually 2021", "in 2021"),
            ("the twelfth sorry thirteenth", "the thirteenth"),
        ])
        // The two class members have to sit on either side of the connective:
        // a determiner in between is a different sentence shape, so verbatim.
        assertUntouched([
            "the 3rd or rather the 4th",
            "the first actually the second",
            "the twelfth sorry the thirteenth",
        ])
    }

    func testRelativeDays() {
        assertCases([
            ("let's do it today no actually tomorrow", "let's do it tomorrow"),
            ("tomorrow sorry tonight", "tonight"),
            ("yesterday I mean today", "today"),
        ])
    }

    // MARK: - tier (a): possessive date pairs

    func testPossessiveDatePairs() {
        // Verbatim from the bug report: "tonight's meeting? Actually,
        // tomorrow's meeting?" must come out as tomorrow's meeting alone.
        let raw = "Could you write an email saying that I'd be late for "
            + "tonight's meeting? Actually, tomorrow's meeting?"
        let fixed = "Could you write an email saying that I'd be late for "
            + "tomorrow's meeting?"
        XCTAssertEqual(PostProcess.process(raw), fixed)
        assertCases([
            (raw, fixed),
            ("tonight's meeting no actually tomorrow's meeting",
             "tomorrow's meeting"),
            ("I'll miss Monday's standup, no wait, Tuesday's standup",
             "I'll miss Tuesday's standup"),
            ("March's numbers sorry April's numbers", "April's numbers"),
            ("late for tonight's meeting. Actually, tomorrow's meeting.",
             "late for tomorrow's meeting."),
            // the recognizer punctuates the hesitation AND emits the curly
            // apostrophe — the live path sees exactly this
            ("late for tonight\u{2019}s meeting? Actually, tomorrow\u{2019}s meeting?",
             "late for tomorrow\u{2019}s meeting?"),
            // multi-word head, repeated verbatim on both sides
            ("skip tonight's team meeting, actually tomorrow's team meeting",
             "skip tomorrow's team meeting"),
            // the DATE classes may cross — a day corrects a day
            ("Friday's meeting no actually tomorrow's meeting",
             "tomorrow's meeting"),
            // a chain resolves through the fixpoint loop
            ("tonight's meeting no tomorrow's meeting no Friday's meeting",
             "Friday's meeting"),
            // fillers in the joint, as the live path sees them
            ("tonight's meeting umm no actually tomorrow's meeting",
             "tomorrow's meeting"),
        ])
        assertUntouched([
            // different head noun — ambiguous prose, verbatim
            "compare Monday's numbers, actually Friday's report is better",
            // no possessive (contraction reading) on the right side
            "tonight's meeting, no, tomorrow's fine",
            // 's as a contraction, no pair at all
            "tonight's the night",
            // "and actually" is prose, not a joint
            "I checked yesterday's numbers and actually today's numbers too",
        ])
    }

    // MARK: - tier (a): refusals

    func testCrossClassRefusals() {
        assertUntouched([
            // you cannot correct a weekday into a time, so this is ambiguous —
            // and the veto also stops the general "no actually" marker from
            // deleting "Thursday" behind tier (a)'s back.
            "Thursday no actually 3 o'clock",
            "Thursday I mean 3 o'clock",
            "Friday actually 4 o'clock",
            "March no actually Tuesday",
            "tomorrow sorry March",
            "3 o'clock actually Monday",
            "the 3rd no actually January",
        ])
    }

    func testBareActuallyAndSorryAreNotGeneralMarkers() {
        assertUntouched([
            // The whole reason "actually"/"sorry" are sandwich-only: they are
            // far too common in ordinary prose.
            "that's actually great",
            "I actually think Friday works",
            "she actually shipped it",
            "the meeting is actually on Friday",
            "sorry about the delay",
            "sorry I'm late for the Friday sync",
            "we actually moved it to Friday",
            // ...and a bare "no" is only a connective inside the sandwich.
            "no I disagree",
            "Friday no problem",
            "there is no meeting Friday",
        ])
    }

    func testHedgesAreNotCorrections() {
        assertUntouched([
            // "no actually" / "I mean" as conversational filler: the word in
            // front is a function word, so there is nothing to replace.
            "so I mean we should go",
            "yeah I mean it's fine",
            "what I mean is we should ship",
            "you know what I mean and then some",
            "well no actually that's fine",
            "but no actually we shipped it",
            // The say-family: a marker directly after a verb of saying means
            // the "no" was the thing said, not a correction cue.
            "I said no, actually, and I stand by it",
            "i said no actually and i stand by it",
            "she says no actually it depends",
        ])
        // The veto is leader-exact: reported speech whose CONTENT is corrected
        // still corrects — "said" is only a hedge when it touches the marker.
        assertCases([
            ("I said Bob no actually Alice", "I said Alice"),
            ("he said Thursday no actually Friday works", "he said Friday works"),
        ])
    }

    // MARK: - multi-correction

    func testMultiCorrectionReachesFixpoint() {
        assertCases([
            ("Tuesday no Wednesday no Thursday", "Thursday"),
            ("meet Tuesday no Wednesday no actually Thursday", "meet Thursday"),
            ("Monday no Tuesday no Wednesday no Thursday", "Thursday"),
            ("3 no 4 no 5 copies", "5 copies"),
            // two independent corrections in one utterance
            ("Monday no Tuesday at 3 o'clock no actually 4 o'clock",
             "Tuesday at 4 o'clock"),
        ])
    }

    // MARK: - casing, punctuation, spacing

    func testCasingIsPreserved() {
        assertCases([
            ("Thursday no actually Friday", "Friday"),
            ("thursday no actually friday", "friday"),
            ("Thursday no actually friday", "friday"),
            ("THURSDAY NO ACTUALLY FRIDAY", "FRIDAY"),
            ("Meeting Thursday no actually Friday", "Meeting Friday"),
        ])
    }

    func testPunctuationAdjacency() {
        assertCases([
            ("on Thursday, no actually, Friday", "on Friday"),
            ("on Thursday, no actually, Friday.", "on Friday."),
            ("on Thursday no actually Friday!", "on Friday!"),
            ("(Thursday no actually Friday)", "(Friday)"),
            ("on Thursday, umm, no actually, Friday?", "on Friday?"),
        ])
    }

    // MARK: - the pinned Python markers still behave

    func testLegacyMarkersAreUnchanged() {
        assertCases([
            ("meet at three no wait four pm", "meet at four pm"),
            ("send it to Bob no wait Alice", "send it to Alice"),
            ("send it to Bob no wait to Alice", "send it to Alice"),
            ("the total is ten no wait twelve dollars", "the total is twelve dollars"),
            ("call him tomorrow scratch that today", "today"),
            ("first scratch that second scratch that third", "third"),
            ("scratch that", ""),
            ("we need to to fix", "we need to fix"),
        ])
        assertUntouched(["please wait for me", "I can hardly wait", "she scratched the surface"])
    }

    func testNewGeneralMarkersUseTheLegacySpan() {
        // Same span decision as "no wait": the single word before the marker,
        // the marker, the joint whitespace — duplicate function word collapsed.
        assertCases([
            ("send it to Bob no actually Alice", "send it to Alice"),
            ("send it to Bob no actually to Alice", "send it to Alice"),
            ("send it to Bob I mean Alice", "send it to Alice"),
            ("I pushed it to production no actually to staging",
             "I pushed it to staging"),
            ("call Bob umm no actually Alice", "call Alice"),
        ])
    }

    // MARK: - inert on ordinary speech

    func testOrdinarySpeechIsUntouched() {
        assertUntouched([
            "let's meet on Friday",
            "the meeting is Thursday and Friday",
            "I have three or four items",
            "Monday through Friday",
            "see you tomorrow",
            "March and April are busy",
            "we shipped it at 3 o'clock",
            "there is no way",
            "no, thank you",
            "I mean it",
            "make that many copies",
            // Prose that puts a connective next to a closed-class item without
            // ever making a correction — the shapes the guards exist for.
            "Sorry, I actually meant to send the Monday numbers, not the Friday ones.",
            "There is no way we ship before March, and honestly no reason to try.",
            "I have three meetings today, two tomorrow, and none on Wednesday.",
            "He actually said the deadline is the 15th, no exceptions.",
            "No, Tuesday is fine. I mean it.",
            "Actually, September was the best month we've had.",
            "The 3 pm slot is taken, so is the 4 pm one.",
            "One or two people, no more than that.",
            "I know what you mean about Friday afternoons.",
            "It's half past nine and no one is here.",
            "There were 21 no-shows in January.",
            "Say no to meetings after 5 pm.",
            "on Monday no one came",
            "we have no March deadline",
            "he said no three times",
            "I may no longer be available",
            // Bare markers with nothing to correct.
            "no", "actually", "sorry", "I mean", "Friday", "3 o'clock",
        ])
    }

    // MARK: - pipeline wiring

    func testStageRunsInThePipelineAtItsOldPosition() {
        // Fillers are stripped in stage 1, so by the time stage 5 runs the
        // joint is filler-free — the new tier has to work on both shapes.
        XCTAssertEqual(PostProcess.process("um meeting on Thursday umm no actually Friday"),
                       "meeting on Friday")
        // Stage 6 still sees a resolved sentence (the emoji ordering argument).
        XCTAssertEqual(PostProcess.process("ship it Thursday no actually Friday rocket emoji"),
                       "ship it Friday 🚀")
        // Stage 4's line break still lands before the correction is read.
        XCTAssertEqual(PostProcess.process("Thursday no actually Friday new line done"),
                       "Friday\ndone")
    }

    func testStageIsUnconditional() {
        // Self-correction has no settings key; the closed-class tier inherits
        // that, so it fires under every option combination.
        for options in [PostProcessOptions(),
                        PostProcessOptions(fillerRemoval: false),
                        PostProcessOptions(emojiCommands: false),
                        PostProcessOptions(ensureSentencePeriod: true, leadingSpace: .never)] {
            XCTAssertTrue(PostProcess.process("meeting Thursday no actually Friday",
                                              options: options).contains("Friday"))
            XCTAssertFalse(PostProcess.process("meeting Thursday no actually Friday",
                                               options: options).contains("Thursday"))
        }
    }

    // MARK: - deliberate boundaries, pinned so a change is visible

    func testLegacyMarkerIsExemptFromTheCrossClassVeto() {
        // "no wait" is the Python marker and its span is a parity contract, so
        // unlike "no actually" it still deletes across closed classes. The two
        // shapes sit side by side here on purpose.
        XCTAssertEqual(SelfCorrection.apply("Thursday no wait 3 o'clock"), "3 o'clock")
        XCTAssertEqual(SelfCorrection.apply("Thursday no actually 3 o'clock"),
                       "Thursday no actually 3 o'clock")
        // The legacy span itself, on a multi-token closed-class item: the
        // Python rule deleted one WORD, and so does this.
        XCTAssertEqual(SelfCorrection.apply("at 3 o'clock no wait Bob"), "at 3 Bob")
        XCTAssertEqual(SelfCorrection.apply("half past three no wait Bob"), "half past Bob")
    }

    func testClockTimesAndBareNumbersAreDifferentClasses() {
        // Conservative by construction: "4 pm" is a clock time and "3" is a
        // number, so this joint does not type-check and passes verbatim rather
        // than guessing. Verbatim-first — the classes are deliberately strict.
        assertUntouched([
            "at 3 no actually 4 pm",
            "March 3 no actually March 4",
        ])
    }

    // MARK: - contract

    func testEmptyAndTrivialInput() {
        XCTAssertEqual(SelfCorrection.apply(""), "")
        XCTAssertEqual(SelfCorrection.apply("   "), "   ")
        XCTAssertEqual(SelfCorrection.apply("Friday"), "Friday")
    }

    func testLiveBudget() {
        // Contract: <1 ms on a 200-character partial, because this runs on
        // every partial (~1/s) while the user is still speaking.
        let raw = String(repeating: "we should meet on Thursday umm no actually Friday and ",
                         count: 4)
        XCTAssertGreaterThan(raw.count, 200)
        _ = SelfCorrection.apply(raw)  // warm the lazily compiled patterns
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<10 { _ = SelfCorrection.apply(raw) }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 10_000_000
        XCTAssertLessThan(ms, 1)
    }

    func testEveryFixtureIsIdempotentUnderTheFullPipeline() {
        // The live path pastes what the pipeline returns and may re-run on a
        // longer partial that starts with it.
        for raw in ["meeting on Thursday umm no actually Friday",
                    "Tuesday no Wednesday no Thursday",
                    "Thursday no actually 3 o'clock",
                    "send it to Bob no wait to Alice",
                    "so I mean we should go"] {
            let once = PostProcess.process(raw)
            XCTAssertEqual(PostProcess.process(once), once, raw)
        }
    }
}

// MARK: - real recognizer punctuation (the eval harness's blocking finding)

extension SelfCorrectionTests {
    /// SpeechAnalyzer punctuates the hesitation: the pause before the
    /// correction ends the "sentence" with a period, and the connective itself
    /// arrives as "No, actually". The tts corpus never produced the bare
    /// comma-only form the first implementation matched.
    func testPunctuatedJointsFromRealRecognizerOutput() {
        assertCases([
            ("I want to have a meeting with person x on Thursday, umm. No, actually Friday.",
             "I want to have a meeting with person x on Friday."),
            ("Let's do it at half past nine. No, actually quarter past ten.",
             "Let's do it at quarter past ten."),
            ("Ship it in September, uh, sorry October.",
             "Ship it in October."),
            ("We need three. No, five copies.",
             "We need five copies."),
        ])
    }

    /// Sentence boundaries that merely LOOK like joints stay verbatim: the
    /// widened gap must not let a correction reach across a real sentence.
    func testPunctuationWideningDoesNotCrossRealSentences() {
        assertUntouched([
            "We shipped it. No, I disagree with the approach.",
            "That is done. Actually, we should ship Friday.",
            "It works. Sorry about the noise earlier.",
        ])
    }

    // MARK: - the mid-correction tail probe (live display deferral)

    func testEndsMidCorrectionDetectsAnUnfinishedJoint() {
        for tail in ["I want to meet on thursday umm no actually",
                     "let's do Thursday no",
                     "the deadline is Friday I mean",
                     "on Thursday, umm. No, actually",
                     "on Thursday no actually, um"] {
            XCTAssertTrue(SelfCorrection.endsMidCorrection(tail),
                          "should defer: \(tail.debugDescription)")
        }
    }

    func testEndsMidCorrectionLeavesOrdinaryTailsAlone() {
        for tail in ["we went to the casino",
                     "there is no vacancy at the casino tonight",
                     "meet me on Friday",
                     "on thursday umm no actually friday",
                     ""] {
            XCTAssertFalse(SelfCorrection.endsMidCorrection(tail),
                           "should not defer: \(tail.debugDescription)")
        }
    }
}

// MARK: - the v2.2.0 live failure: clause restarts and the narrowed veto

extension SelfCorrectionTests {
    /// The field report, verbatim: "I want to meet Vivek, no actually I want
    /// it Sharique" came out as two sentences and nothing collapsed. The user
    /// restated the clause, so the restart replaces it wholesale — on the raw
    /// dictated shape and on the punctuated shape the recognizer emitted.
    func testTheLiveFailureSentence() {
        assertCases([
            // the raw dictated shape
            ("I want to meet Vivek, no actually I want it Sharique",
             "I want it Sharique"),
            ("I want to meet Vivek no actually I want it Sharique",
             "I want it Sharique"),
            // the ASR-punctuated shape v2.2.0 actually emitted
            ("I want to meet Vivek. No, actually I want it Sharique.",
             "I want it Sharique."),
        ])
        // ...and through the full pipeline.
        XCTAssertEqual(PostProcess.process("I want to meet Vivek. No, actually I want it Sharique."),
                       "I want it Sharique.")
    }

    /// The adjacent name swap needed no new mechanism — pinned so it stays.
    func testNameSwapAdjacents() {
        assertCases([
            ("meet Vivek no actually Sharique", "meet Sharique"),
            ("meet Vivek no wait Sharique", "meet Sharique"),
            ("meet Vivek umm no actually Sharique", "meet Sharique"),
        ])
    }

    /// The narrowed sentence-boundary veto: a "no"-anchored marker may cross
    /// ONE terminator, because the ASR punctuates the pause before a
    /// correction and a "No," after a period is a correction cue, not prose.
    func testNoAnchoredMarkersMayCrossOneSentenceTerminator() {
        assertCases([
            ("I want to meet Vivek. No, actually Sharique", "I want to meet Sharique"),
            ("I want to meet Vivek. No wait Sharique", "I want to meet Sharique"),
            ("Ship it to staging. No, actually production.", "Ship it to production."),
        ])
        // "I mean" keeps the FULL veto — it is the hedge that caused the
        // original regression, and it never reaches across a sentence.
        assertUntouched([
            "No, Tuesday is fine. I mean it.",
            "The build is green. I mean the tests pass.",
        ])
        // A bare "no" is not a general marker, before or after a period.
        assertUntouched([
            "We shipped it. No, I disagree with the approach.",
        ])
    }

    /// The clause-restart repair on arbitrary words: B re-begins the clause,
    /// so B replaces it, verbatim — casing, tail length and all.
    func testClauseRestarts() {
        assertCases([
            // pronoun restart
            ("he wants tea no actually he wants coffee", "he wants coffee"),
            // longer restart, longer tail
            ("I'll take the 9am flight no wait I'll take the noon train instead",
             "I'll take the noon train instead"),
            ("we should ship the build on Monday no wait we should ship it on Wednesday",
             "we should ship it on Wednesday"),
            // shorter tail than the clause it replaces
            ("send the report to the whole team no actually send it to Bob",
             "send it to Bob"),
            // one shared token is evidence when it is a non-lexicon content
            // word — a name, exactly what no closed class can cover
            ("Sharique leads no actually Sharique follows", "Sharique follows"),
            // the restart is kept verbatim, including its casing
            ("Let's meet on Thursday. No, actually let's meet on Friday",
             "let's meet on Friday"),
        ])
    }

    /// Tier (a) runs first and still wins its cases: a correction that is also
    /// a same-class pair resolves identically through either mechanism —
    /// Thursday is gone and Friday survives, adjacent or restated.
    func testRestartThatIsAlsoASameClassPair() {
        XCTAssertEqual(SelfCorrection.apply("Let's meet on Thursday. No, actually Friday"),
                       "Let's meet on Friday")
        XCTAssertEqual(SelfCorrection.apply("Let's meet on Thursday. No, actually let's meet on Friday"),
                       "let's meet on Friday")
    }

    /// No shared re-beginning, no clause repair — the evidence requirement is
    /// what keeps wholesale deletion safe on arbitrary content. The
    /// single-word span still applies under its existing rules.
    func testNoRestartEvidenceMeansNoClauseRepair() {
        assertCases([
            ("send it to Bob no actually to Alice", "send it to Alice"),
            ("call Bob umm no actually Alice", "call Alice"),
        ])
        assertUntouched([
            // "No," opening a genuine new sentence that shares only an
            // incidental pronoun prefix with the clause before it: a lone
            // pronoun is not restart evidence, and a clause opener after the
            // marker is a denial, not a replacement word.
            "I finished the report. No, actually I think we should celebrate.",
            "We tried it. No, actually we were lucky it compiled at all.",
        ])
    }

    /// "I mean" repairs a restart only INSIDE its sentence, and never a hedge.
    func testIMeanClauseRepairStaysInsideTheSentence() {
        assertCases([
            ("I want tea I mean I want coffee", "I want coffee"),
        ])
        assertUntouched([
            "what I mean is we should go",
            "I want tea. I mean I want coffee.",
        ])
    }

    /// Across a terminator, "no wait" loses its parity exemptions: Python's
    /// comma-only gap never crossed one, so parity says nothing there and the
    /// cross-class and hedge vetoes apply exactly as they do to "no actually".
    func testCrossTerminatorNoWaitLosesItsParityExemptions() {
        assertUntouched([
            // cross-class veto
            "Thursday. No wait 3 o'clock",
            // hedge-leader veto — and the tokenizer never reads "wait staff"
            // as prose: "no wait" IS matched as a marker here, and the veto on
            // the leader "it" is what keeps the sentence whole.
            "I like it. No wait staff were available.",
        ])
        // Adjacent, the Python-parity contract is untouched.
        XCTAssertEqual(SelfCorrection.apply("Thursday no wait 3 o'clock"), "3 o'clock")
    }
}
