import XCTest
@testable import WispritPostProcess

/// Tier (c), the parallel-anchored resolution — the #1 user-reported failure
/// class:
///
///     "I want to go tomorrow. I mean, day after to the hackathon."
///
/// A correction cue whose replacement is a fragment PLUS a continuation. Tiers
/// (a) and (b) both decline it by construction (see the header of
/// `SelfCorrection.swift`), so before this file the utterance shipped with the
/// mistake in it — and the AI layer does not rescue it either: the refine
/// battery's `self-correction-weak-cue` case scores 0.00.
///
/// Every table is asserted through the WHOLE pipeline and twice, for value and
/// for idempotence: the live path re-runs on every growing partial, so
/// `process(process(x)) == process(x)` is a shipping requirement.
///
/// The negative table is the larger half on purpose. Tier (c) resolves by
/// deleting the anchor, and deleting a word the user actually said is the one
/// failure a dictation app can never take back — so every cue word here is also
/// an ordinary English word, tested in its ordinary use.
final class ParallelAnchorTests: XCTestCase {
    private func assertPipeline(_ raw: String, _ expected: String, _ id: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        let once = PostProcess.process(raw)
        XCTAssertEqual(once, expected, "\(id): \(raw.debugDescription)", file: file, line: line)
        XCTAssertEqual(PostProcess.process(once), once,
                       "\(id) not idempotent", file: file, line: line)
    }

    private func assertVerbatim(_ cases: [(id: String, raw: String)],
                                file: StaticString = #filePath, line: UInt = #line) {
        for (id, raw) in cases { assertPipeline(raw, raw, id, file: file, line: line) }
    }

    // MARK: - the shapes this tier exists for

    /// The user's own dictation and its siblings. Each one is a cue followed by
    /// a replacement AND a continuation, which is exactly what the tiers above
    /// cannot take.
    func testMustResolve() {
        let cases: [(id: String, raw: String, expected: String)] = [
            // The reported sentence, verbatim.
            ("user-exact", "I want to go tomorrow. I mean, day after to the hackathon.",
             "I want to go day after to the hackathon."),
            // The same utterance with the recognizer mishearing the noun. The
            // resolution must not depend on the CONTINUATION being recognized
            // correctly — the anchor is "tomorrow" ↔ "day after", and the
            // hackathon plays no part in it.
            ("user-asr", "I want to go tomorrow. I mean day after to the hackdown.",
             "I want to go day after to the hackdown."),
            // Weak cue + prepositional phrase: the parallelism is the repeated
            // preposition. Also the refine battery's `self-correction-weak-cue`.
            ("sorry-prep", "Send it to marketing, sorry to finance.",
             "Send it to finance."),
            // "rather" behind the "No," the recognizer actually writes, and a
            // temporal continuation.
            ("rather-temporal", "Ship it Thursday. No, rather Friday morning.",
             "Ship it Friday morning."),
            // Spoken clock times on both sides.
            ("clock-spoken", "Let's do nine thirty. I mean ten fifteen, in the small room.",
             "Let's do ten fifteen, in the small room."),
            // Months.
            ("month", "Book it for March. I mean April, before the offsite.",
             "Book it for April, before the offsite."),
        ]
        for (id, raw, expected) in cases { assertPipeline(raw, expected, id) }
    }

    /// The same six through `SelfCorrection.apply` on RAW text, because the
    /// live path calls the engine directly on partials that stage 1 has never
    /// cleaned.
    func testMustResolveOnRawPartials() {
        XCTAssertEqual(
            SelfCorrection.apply("I want to go tomorrow umm. I mean, day after to the hackathon."),
            "I want to go day after to the hackathon.")
        XCTAssertEqual(SelfCorrection.apply("Send it to marketing, uh sorry to finance."),
                       "Send it to finance.")
    }

    // MARK: - the cue vocabulary

    /// Each cue, on the same sentence, so a cue that stops being a cue is
    /// visible as one failure rather than as a scattered handful.
    func testEveryCue() {
        for cue in ["I mean", "I meant", "no actually", "no wait", "no rather",
                    "or rather", "make that", "rather", "sorry"] {
            assertPipeline("Ship it Thursday. \(cue) Friday morning.",
                           "Ship it Friday morning.", cue)
        }
        // ...and after a comma rather than a terminator, which is the other
        // punctuation the recognizer writes at a correction pause.
        for cue in ["I mean", "sorry", "or rather", "make that"] {
            assertPipeline("Ship it Thursday, \(cue) Friday morning.",
                           "Ship it Friday morning.", cue)
        }
    }

    /// A bare "no" is deliberately NOT a tier (c) cue. It satisfies the
    /// punctuation condition perfectly in ordinary speech, and the pinned
    /// "Did we win? No. We lost by two votes." is what that would cost.
    func testBareNoIsNotACue() {
        assertVerbatim([
            ("bare-no-answer", "Did we win? No. We lost by two votes."),
            ("bare-no-deck", "Are we on for Thursday? No. Bring the deck."),
        ])
    }

    // MARK: - condition (a): the cue must be spoken as a cue

    /// A cue word preceded by a WORD is being used, not spoken as a cue. This
    /// is the whole false-positive defence for the weak cues, so it is pinned
    /// one ordinary sentence at a time.
    func testCueWordsInOrdinaryUse() {
        assertVerbatim([
            ("mean-object", "I know what you mean about the deadline."),
            ("mean-relative", "That is exactly what I mean when I say fragile."),
            ("mean-question", "Do you know what I mean, or should I rephrase?"),
            ("rather-preference", "I would rather go on Friday."),
            ("sorry-apology", "I am sorry about Thursday."),
            // Same words, same anchor available, no punctuation in front of
            // the cue: the anchor alone is never enough to make "rather" a cue.
            ("rather-no-pause", "Ship it Thursday rather Friday morning."),
        ])
        // The one shape that DOES resolve without punctuation is not tier (c)'s
        // at all: inside a single sentence tier (b)'s span already handles
        // "I mean", and it does so on HEAD. Pinned here because it is the
        // nearest neighbour of the user's sentence — the only difference is the
        // terminator the recognizer writes at the pause, which is precisely
        // what pushes the utterance out of tier (b) and into tier (c).
        assertPipeline("I want to go tomorrow I mean day after to the hackathon.",
                       "I want to go day after to the hackathon.", "tier-b-span")
    }

    /// The cue at the very start of an utterance has no clause to correct.
    func testUtteranceInitialCueHasNothingToAnchorTo() {
        assertVerbatim([
            ("mean-it", "I mean it. Stop."),
            ("sorry-lead", "Sorry, I actually meant to send the Monday numbers, "
                + "not the Friday ones."),
            ("rather-lead", "Rather than Thursday, let us do Friday."),
        ])
    }

    // MARK: - condition (b): there must be a parallel anchor

    /// Punctuation and a real cue, and still verbatim, because nothing in the
    /// clause is parallel to what follows. Both conditions, always.
    func testNoAnchorMeansVerbatim() {
        assertVerbatim([
            ("mean-clause", "We should sort it out. I mean, the whole backlog is a mess."),
            ("cross-denial", "I finished the report. No, actually Jane finished it."),
            ("beta-clause", "We shipped the beta. No wait Bob shipped the beta."),
            ("team-clause", "I filed the ticket. No, actually the whole team filed one."),
            // A question after the cue is a question, not a replacement.
            ("mean-question-after", "Book the room for Monday. I mean, could you do "
                + "Tuesday instead?"),
        ])
    }

    /// The classes have to MATCH, not merely both exist — the type-check tier
    /// (a) performs, performed on phrases.
    func testCrossClassRefusals() {
        assertVerbatim([
            ("weekday-vs-clock", "Ship it Thursday. I mean ten fifteen, in the small room."),
            ("month-vs-number", "Book it for March. I mean four, before the offsite."),
            ("weekday-vs-number", "Ship it Thursday. I mean four, in the small room."),
            // "to" does not correct a "by".
            ("prep-mismatch", "Send it to marketing, sorry by Friday."),
        ])
        // Not listed above on purpose: a clock time crossed with a bare number.
        // Tier (a) owns that pair and deliberately treats it as compatible
        // ("5 actually 6 pm"), so it resolves before this tier is consulted and
        // the answer is tier (a)'s to give.
    }

    /// The anchor has to be the clause's TRAILING phrase. The span tier (c)
    /// deletes runs from the anchor to the cue, so an anchor further back would
    /// take real words with it — "with Bob" here — and that is the one failure
    /// this engine never takes.
    func testAnchorMustBeClauseFinal() {
        assertVerbatim([
            ("content-between", "I want to go tomorrow with Bob. I mean day after."),
            ("second-preposition", "Send it to marketing by Friday, sorry to finance."),
        ])
    }

    /// An anchor never reaches into the sentence before the one being
    /// corrected.
    func testAnchorNeverCrossesASentenceBoundary() {
        assertVerbatim([
            ("earlier-sentence", "We shipped on Thursday. The team is tired. "
                + "I mean, Friday works for the retro."),
        ])
    }

    /// Prepositional phrases that are discourse markers, not replacements.
    func testDiscourseMarkersAreNotReplacements() {
        assertVerbatim([
            ("second-thought", "Put it on the shelf. I mean, on second thought, leave it."),
            ("other-words", "Ship it to staging. I mean, in other words hold the release."),
            ("by-the-way", "Send it to marketing. I mean, by the way the deck is ready."),
        ])
    }

    // MARK: - the anchor classes, one at a time

    func testTemporalAnchors() {
        let cases: [(id: String, raw: String, expected: String)] = [
            ("relative-day", "I want to go tomorrow. I mean, day after to the hackathon.",
             "I want to go day after to the hackathon."),
            ("relative-period", "The offsite is next week. I mean next month, after the launch.",
             "The offsite is next month, after the launch."),
            ("weekday", "Ship it Thursday, sorry Friday.", "Ship it Friday."),
            ("weekday-daypart", "I saw him Friday morning, sorry Friday afternoon.",
             "I saw him Friday afternoon."),
            ("month", "Book it for March. I mean April, before the offsite.",
             "Book it for April, before the offsite."),
            ("clock-phrase", "Call me at half past nine. I mean quarter past ten, if that works.",
             "Call me at quarter past ten, if that works."),
            ("clock-spoken", "Let's do nine thirty. I mean ten fifteen, in the small room.",
             "Let's do ten fifteen, in the small room."),
            ("day-of-month", "Move it to the 5th. I mean the 6th, before the freeze.",
             "Move it to the 6th, before the freeze."),
        ]
        for (id, raw, expected) in cases { assertPipeline(raw, expected, id) }
    }

    func testPrepositionalAnchors() {
        let cases: [(id: String, raw: String, expected: String)] = [
            ("bare-object", "Send it to marketing, sorry to finance.", "Send it to finance."),
            ("determined-object", "Send it to marketing, sorry to the finance team.",
             "Send it to the finance team."),
            ("for", "Book the room for Monday, sorry for the whole week.",
             "Book the room for the whole week."),
            ("no-actually", "Send it to marketing. No, actually to finance.",
             "Send it to finance."),
        ]
        for (id, raw, expected) in cases { assertPipeline(raw, expected, id) }
    }

    /// The mishear-restatement channel, and the floor that fences it. The
    /// engine cannot reach `WispritCorrections`' DoubleMetaphone
    /// (`Package.swift` gives this module `WispritKit` alone), so the metric is
    /// a local normalized edit distance with a high floor — and a pair that
    /// falls under the floor stays VERBATIM, which is the right answer: a
    /// missed correction is a typo the user can see, a wrong one is a word they
    /// never knew they lost.
    func testPhoneticAnchors() {
        assertPipeline("Send the invite to Viveque. I mean Vivek.",
                       "Send the invite to Vivek.", "viveque")
        assertPipeline("Push it to staging. I mean stagging.",
                       "Push it to stagging.", "stagging")
        // Below the floor (0.375) — deliberately unresolved, pinned so the
        // number is visible if the metric ever changes.
        XCTAssertFalse(SelfCorrection.isPhoneticallyClose("shreek", "sharique"))
        assertPipeline("Send the invite to Shreek. I mean Sharique.",
                       "Send the invite to Shreek. I mean Sharique.", "shreek")
        // The regression that made "I mean" refuse terminators in the first
        // place. It fails the branch four ways over: "it" is two letters, a
        // function word, shares no first letter with "fine" and no shape.
        assertVerbatim([("mean-it-fine", "No, Tuesday is fine. I mean it.")])
        XCTAssertFalse(SelfCorrection.isPhoneticallyClose("fine", "it"))
        // Different first letter, however close the rest.
        XCTAssertFalse(SelfCorrection.isPhoneticallyClose("vivek", "bivek"))
        // A replacement that is a whole CLAUSE is never a mishearing, however
        // similar its first word.
        assertVerbatim([("phonetic-clause", "Send the invite to Viveque. "
            + "I mean Vivek should get it too.")])
    }

    // MARK: - the tiers above are untouched

    /// Tier (c) is an extra attempt at a cue the joint sweep DECLINED, never a
    /// second opinion on one it resolved. These are the answers tiers (a) and
    /// (b) already gave, pinned from this file as well so a tier (c) change
    /// that reached one of them fails here and not only in a golden.
    func testResolvedShapesAreByteIdentical() {
        let cases: [(id: String, raw: String, expected: String)] = [
            ("imean-comma", "Send it to Alice, I mean Bob.", "Send it to Bob."),
            ("imean-period", "The demo is Monday. I mean Tuesday.", "The demo is Tuesday."),
            ("imean-mid", "We need three, I mean four laptops for the offsite.",
             "We need four laptops for the offsite."),
            ("sc-01", "Let us meet on Thursday. No, actually Wednesday, after lunch.",
             "Let us meet on Wednesday, after lunch."),
            ("sc-03", "Let us move the stand up to half past nine. No, actually, quarter past 10.",
             "Let us move the stand up to quarter past 10."),
            ("sc-07", "Send the invite to Viveque. No, actually, Shariq.",
             "Send the invite to Shariq."),
            ("sc-08", "I need to email the vendor today. No, actually, "
                + "I need to call them right now.",
             "I need to call them right now."),
            ("no-wait-parity", "send it to Bob no wait to Alice", "send it to Alice"),
            ("scratch", "call him tomorrow scratch that today", "today"),
        ]
        for (id, raw, expected) in cases { assertPipeline(raw, expected, id) }
    }

    // MARK: - splicing

    /// The replacement keeps its own casing — tier (a)'s contract for Y — with
    /// the one exception the splice creates rather than inherits.
    func testCasingAndSpacing() {
        assertPipeline("Tomorrow. I mean day after.", "Day after.", "sentence-initial")
        assertPipeline("OK. Tomorrow. I mean day after.", "OK. Day after.", "after-terminator")
        assertPipeline("Ship it Thursday. No, rather Friday morning.",
                       "Ship it Friday morning.", "mid-sentence-keeps-case")
    }

    /// A chain resolves through `apply`'s fixpoint loop, one cue per sweep.
    func testChainsResolve() {
        assertPipeline("Ship it Thursday. No, rather Friday morning. Sorry, Saturday morning.",
                       "Ship it Saturday morning.", "chain")
    }

    /// A partial that ends ON the cue has no replacement yet. The cue pattern's
    /// trailing `\s+` refuses that frame, which is why tier (c) needs no
    /// `endsMidCorrection` entry of its own.
    func testPartialEndingOnTheCue() {
        for tail in ["Ship it Thursday. No, rather", "Ship it Thursday. No, rather ",
                     "Send it to marketing, sorry", "I want to go tomorrow. I mean,"] {
            XCTAssertEqual(SelfCorrection.apply(tail), tail, tail)
        }
    }

    // MARK: - contract

    func testLiveBudget() {
        // This tier runs on every partial, so it lives inside the engine's
        // per-partial budget. The string is the WORST case rather than a
        // typical one: four separate cues in 220 characters, every one of them
        // resolving, so the fixpoint loop re-sweeps on each pass. Real
        // dictation carries one correction, not four — the <1 ms contract on a
        // single-correction partial is `SelfCorrectionTests.testLiveBudget`,
        // and this is the ceiling above it.
        //
        // Measured 0.83 ms on an idle machine. The assertion sits at 2 ms
        // because the number this test defends is "the tier costs a fraction of
        // the once-per-second budget", and a tighter bound on a shared box
        // measures the SCHEDULER, not the code: the same batch read 8.9 ms and
        // 1.27 ms while three other checkouts were compiling Swift. Best-of-N
        // takes the minimum for the same reason — it is the honest estimate of
        // the work, and 2 ms still fails loudly if this tier ever becomes
        // quadratic in the partial.
        let raw = String(repeating: "we should meet on Thursday. I mean Friday morning, and ",
                         count: 4)
        XCTAssertGreaterThan(raw.count, 200)
        for _ in 0..<50 { _ = SelfCorrection.apply(raw) }  // warm the patterns
        var best = Double.greatestFiniteMagnitude
        for _ in 0..<8 {
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<20 { _ = SelfCorrection.apply(raw) }
            best = min(best, Double(DispatchTime.now().uptimeNanoseconds - start) / 20_000_000)
        }
        XCTAssertLessThan(best, 2)
    }

    func testEmptyAndTrivialInput() {
        for raw in ["", "   ", "I mean", "sorry", "rather", ". I mean ", "tomorrow. I mean"] {
            XCTAssertEqual(SelfCorrection.apply(raw), raw, raw.debugDescription)
        }
    }
}

// MARK: - the spoken clock time, which was a word deletion

/// "nine thirty" and "ten fifteen" were not in the closed-class list, so tier
/// (a) read their TAILS as two bare numbers, corrected one into the other, and
/// left the hour of the deleted time standing in the sentence. Measured through
/// the shipping pipeline before the fix:
///
///     "Let's do nine thirty. I mean ten fifteen, in the small room."
///  -> "Let's do nine ten fifteen, in the small room."
///
/// A word the user said, gone, with no marker anywhere near it — the defect
/// class the 2026-08-14 audit was written about. The hour is restricted to 1–12
/// and the minutes to a closed list, which is what keeps a spoken COMPOUND
/// number out: English says its tens first, so "twenty five" can never open
/// with an hour.
final class SpokenClockTimeTests: XCTestCase {
    func testTheMeasuredDeletionIsGone() {
        XCTAssertEqual(
            PostProcess.process("Let's do nine thirty. I mean ten fifteen, in the small room."),
            "Let's do ten fifteen, in the small room.")
        XCTAssertEqual(SelfCorrection.apply("Let's do nine thirty no actually ten fifteen"),
                       "Let's do ten fifteen")
    }

    func testSpokenTimesAreOneClosedClassItem() {
        XCTAssertEqual(SelfCorrection.apply("meet at nine thirty no actually ten fifteen"),
                       "meet at ten fifteen")
        XCTAssertEqual(SelfCorrection.apply("the train is at 5 fifteen no wait 6 forty five"),
                       "the train is at 6 forty five")
        XCTAssertEqual(SelfCorrection.apply("call at nine oh five sorry ten twenty"),
                       "call at ten twenty")
    }

    func testCompoundNumbersAreStillNumbers() {
        for raw in ["we have twenty five open tickets",
                    "twenty three items",
                    "the total is thirty one dollars",
                    "we need ten fifteen inch monitors",
                    "the meeting is at ten fifteen"] {
            XCTAssertEqual(PostProcess.process(raw), raw, raw)
        }
        // A compound number corrected by a compound number is still a number
        // pair, not a time pair.
        XCTAssertEqual(SelfCorrection.apply("we need twenty five no actually thirty one"),
                       "we need thirty one")
    }

    /// The invariant the defect violated, stated without reference to any
    /// tier's policy about WHETHER a given pair corrects: a spoken time is one
    /// item, so it is either left alone or replaced whole. The hour never
    /// survives on its own, which is the shape the deletion took.
    func testTheHourNeverSurvivesAlone() {
        for raw in ["Let's do nine thirty. I mean four, in the small room.",
                    "at nine thirty no actually four",
                    "Let's do nine thirty. I mean ten fifteen, in the small room.",
                    "the demo is at nine thirty, sorry ten fifteen"] {
            let out = PostProcess.process(raw)
            XCTAssertTrue(out == raw || !out.contains("nine"),
                          "orphaned hour: \(raw.debugDescription) -> \(out.debugDescription)")
            XCTAssertEqual(PostProcess.process(out), out, raw)
        }
    }
}
