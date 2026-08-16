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

    /// The relative-time class, once its determiner forms became names rather
    /// than a bare word plus a stranded modifier. Any member anchors any other
    /// member: a daypart phrase corrects a bare day, a period corrects a day,
    /// a day corrects a period.
    func testRelativeTimeAnchors() {
        let cases: [(id: String, raw: String, expected: String)] = [
            // The reported pair — the one that shipped unresolved.
            ("tonight-last-night", "I slept badly tonight. I mean last night.",
             "I slept badly last night."),
            ("daypart", "The demo is this morning. I mean this afternoon.",
             "The demo is this afternoon."),
            ("period-to-day", "Ship it next week. I mean tomorrow.", "Ship it tomorrow."),
            ("day-to-period", "Ship it tomorrow. I mean next week.", "Ship it next week."),
            ("daypart-to-day", "Let's talk this evening. I mean tomorrow, after the standup.",
             "Let's talk tomorrow, after the standup."),
            ("weekend", "See you this weekend. I mean next weekend.", "See you next weekend."),
            // Already resolving before the vocabulary grew, pinned so the
            // rewrite of the probe is visible if it takes one away.
            ("period", "The offsite is next week. I mean next month, after the launch.",
             "The offsite is next month, after the launch."),
            ("day-after", "I want to go tomorrow. I mean, day after to the hackathon.",
             "I want to go day after to the hackathon."),
            ("day-after-tomorrow", "Let's meet the day after tomorrow. "
                + "I mean the day before yesterday.",
             "Let's meet the day before yesterday."),
        ]
        for (id, raw, expected) in cases { assertPipeline(raw, expected, id) }
    }

    /// The compound-versus-modifier line, pinned from both sides.
    ///
    /// A relative time is a NAME plus an optional same-slot MODIFIER, and the
    /// two live in different places on purpose. "last night" is a name — "last"
    /// is not a time on its own, so the phrase does not come apart and it is a
    /// member of the closed class. "tomorrow morning" is a name plus a
    /// modifier — "tomorrow" is the member and "morning" narrows the same slot
    /// — so it is NOT a second entry in the class, and row 177 resolves through
    /// the path it always did: the anchor is "tonight" ↔ "tomorrow", and
    /// "morning" rides along because the splice keeps the whole post-cue tail.
    ///
    /// The chain is what makes the modifier's one home matter. `anchorWeekdayRx`
    /// has carried an optional daypart since it shipped, so the WEEKDAY
    /// spelling of a chained correction has always resolved; the relative-day
    /// spelling did not, because its probe had no such suffix — measured
    /// "Dinner tomorrow morning. Sorry, tomorrow evening.", both dates left in.
    /// One suffix, both day classes, no third handling.
    func testDaypartIsAModifierNotASecondName() {
        // Row 177, verbatim from `utterance_detail` — the behavior this rule
        // may not change.
        assertPipeline("I was planning on going for dinner with Vivek tonight. "
            + "I mean, tomorrow morning.",
                       "I was planning on going for dinner with Vivek tomorrow morning.",
                       "row-177")
        // The same shape once more, so the pin is not a single sentence.
        assertPipeline("Dinner tonight. I mean, tomorrow evening.", "Dinner tomorrow evening.",
                       "daypart-tail")
        // The chain: the first cue's own OUTPUT has to classify for the second
        // cue to find an anchor, which is what the daypart suffix is for.
        assertPipeline("Dinner tonight. I mean, tomorrow morning. Sorry, tomorrow evening.",
                       "Dinner tomorrow evening.", "relative-chain")
        // The weekday spelling of the same chain, which already worked — the
        // two day classes now behave alike.
        assertPipeline("Ship it Thursday. No, rather Friday morning. Sorry, Saturday morning.",
                       "Ship it Saturday morning.", "weekday-chain")
        // The cue-less tier's own modifier list is untouched: the survivor may
        // still carry a daypart or a clock tail and still count as bare.
        assertPipeline("I was planning on going for dinner tomorrow, today morning.",
                       "I was planning on going for dinner today morning.", "bare-daypart")
        assertPipeline("dinner tomorrow, today at six.", "dinner today at six.", "bare-clock")
    }

    /// The fences that keep the widened vocabulary honest. Two temporals in a
    /// sentence are ordinary English far more often than they are a
    /// correction, and every rule that could reach these has to decline.
    func testRelativeTimeMustNotFire() {
        assertVerbatim([
            // Two temporals with a conjunction and a clause between them.
            ("conjunction", "I did not sleep well last night and I am tired today."),
            // Separate clauses, with content after each — not touching, not
            // bare, not clause-final.
            ("separate-clauses", "Last night was rough. This morning is worse."),
            // Plurals are not class members.
            ("plurals", "I work mornings and nights."),
            // A daypart that belongs to the phrase after it, not before it.
            ("every-night", "We meet every night this week."),
            ("since", "I have not seen him since last night."),
            ("this-week-prose", "This week has been hard."),
            ("list", "We meet this week and next week."),
            // A cue, a pause, and still no parallel: the replacement is a
            // clause, not a restatement.
            ("no-anchor", "I slept badly last night. I mean, the whole week was bad."),
        ])
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

    // MARK: - production

    /// Tonight's live dictation session, `~/.wisprit/history.sqlite`
    /// `utterance_detail` rows 171-179, replayed end to end.
    ///
    /// This is the only table in the file whose inputs nobody wrote: they are
    /// what a person actually said into the microphone, with the recognizer's
    /// own spelling ("Hatathon") and its own punctuation left exactly as
    /// recorded. Five resolved on the night; two did not, and both are fixed
    /// here — so the whole session is pinned together, the wins as regression
    /// cover for the fixes.
    func testTonightsProductionUtterances() {
        let session: [(row: Int, raw: String, expected: String)] = [
            // 171 — the cue behind an interjection. Shipped as "…today.
            // tomorrow.": the span read "Oh" as the word being corrected,
            // deleted it with the cue, and left BOTH dates in the sentence.
            (171, "I was thinking of going to Hackathon today. Oh, I mean tomorrow.",
             "I was thinking of going to Hackathon tomorrow."),
            (172, "I was going to a hackathon tomorrow. I mean today.",
             "I was going to a hackathon today."),
            (173, "I was going to a hackathon today, I mean tomorrow.",
             "I was going to a hackathon tomorrow."),
            (174, "I was going to Hatathon today. I mean tomorrow.",
             "I was going to Hatathon tomorrow."),
            (175, "I was going to a hackathon today, I mean tomorrow.",
             "I was going to a hackathon tomorrow."),
            (176, "Going to a hackathon tomorrow, I mean today.",
             "Going to a hackathon today."),
            (177, "I was planning on going for dinner with Vivek tonight. I mean, tomorrow morning.",
             "I was planning on going for dinner with Vivek tomorrow morning."),
            // 179 — no cue at all. The recognizer never transcribed it, so
            // the parallelism is the only evidence in the sentence.
            (179, "I was planning on going for dinner tomorrow, today morning.",
             "I was planning on going for dinner today morning."),
        ]
        for (row, raw, expected) in session {
            assertPipeline(raw, expected, "utterance \(row)")
        }
        // Rows from the same session that carry no correction, verbatim.
        assertVerbatim([
            (170, "Okay, testing, dictation now with a new bill."),
            (178, "I was..."),
            (180, "This is what the test showed based on everything that, you know, I usually "
                + "kind of talk about, but yeah, it's not working. Fix it."),
        ].map { (id: "utterance \($0.0)", raw: $0.1) })
    }

    /// `utterance_detail` row 189 — one utterance carrying TWO corrections of
    /// the same class, and the reason the relative-time vocabulary had to grow.
    ///
    /// The hackathon correction resolved on the night; the sleep one did not,
    /// and the cause was in the lexicon rather than in any tier's logic: "last
    /// night" was not a member of ANY temporal class, so `leadingClass` found
    /// no class for the replacement and `anchorStart` correctly declined. The
    /// utterance shipped with both dates in it.
    ///
    /// Pinned as the whole sentence, because the two cues resolve on separate
    /// passes of `apply`'s fixpoint loop and the second one reads what the
    /// first one produced.
    func testProductionRow189() {
        assertPipeline(
            "I was thinking of going for a harkathon tomorrow. I mean, today, but I did "
                + "not end up going because, uh, I did not sleep very well tonight. "
                + "I mean last night. And because of that, I was feeling tired.",
            "I was thinking of going for a harkathon today, but I did not end up going "
                + "because, I did not sleep very well last night. And because of that, "
                + "I was feeling tired.",
            "utterance 189")
        // The second correction on its own, so a regression names the half
        // that broke rather than the whole paragraph.
        assertPipeline("I did not sleep very well tonight. I mean last night.",
                       "I did not sleep very well last night.", "utterance 189 second cue")
    }

    /// A correction is spoken the moment the speaker notices the mistake, and
    /// noticing has its own vocabulary. The cue may sit behind up to two of
    /// them; the pause still has to be there, and the anchor still has to
    /// exist.
    func testCueSurvivesAnInterjection() {
        for lead in ["Oh,", "Oh", "Ah,", "Well,", "Hmm,", "um,", "Oh, well,"] {
            assertPipeline("I was going to a hackathon today. \(lead) I mean tomorrow.",
                           "I was going to a hackathon tomorrow.", lead)
        }
        // The interjection is not itself correctable content — this is what
        // stops the span consuming the cue before this tier can read it.
        assertVerbatim([
            ("oh-no-anchor", "I was thinking about it. Oh, I mean the whole backlog is a mess."),
            ("oh-literal", "Oh, I mean it. Stop."),
            ("well-literal", "Well, I know what you mean about the deadline."),
        ])
    }

    // MARK: - cue-less parallels

    /// The recognizer drops the spoken cue often enough that production hit it
    /// on the first night. Two touching temporals of the same class, a pause
    /// between them and nothing else, the second one bare and ending the
    /// clause: the later phrase wins.
    func testBareParallelRestatement() {
        let cases: [(id: String, raw: String, expected: String)] = [
            ("production-179", "I was planning on going for dinner tomorrow, today morning.",
             "I was planning on going for dinner today morning."),
            ("terminator", "I was thinking of going to hackathon today. tomorrow.",
             "I was thinking of going to hackathon tomorrow."),
            ("weekday", "let's meet Monday, Tuesday.", "let's meet Tuesday."),
            ("slot-modifier", "dinner tomorrow, today at six.", "dinner today at six."),
            ("month", "the offsite is in March, April.", "the offsite is in April."),
        ]
        for (id, raw, expected) in cases { assertPipeline(raw, expected, id) }
    }

    /// The fences, one shape each. Every one of these is ordinary English that
    /// the rule must leave alone — a list, a range, a new clause, an
    /// enumeration, or emphasis.
    func testBareParallelMustNotFire() {
        assertVerbatim([
            // A conjunction between them: a list, not a restatement.
            ("and", "today and tomorrow"),
            ("or", "today or tomorrow"),
            ("nor", "we meet Monday nor Tuesday"),
            // A range.
            ("to", "Monday to Friday"),
            ("through", "Monday through Wednesday"),
            ("until", "the deadline is Monday until Friday"),
            // The second temporal opens a new clause.
            ("new-clause", "We shipped today. Tomorrow we rest."),
            ("new-clause-2", "I went yesterday, tomorrow I'll fly"),
            // Content after the survivor — not bare, not clause-final. This is
            // the guard that keeps the sentence its subject.
            ("clause-end", "the meeting is at nine, ten people are coming"),
            // Three or more is an enumeration.
            ("enumeration", "Monday, Tuesday, Wednesday"),
            ("enumeration-numbers", "35, 36, 37"),
            ("enumeration-list", "I can do today, tomorrow and Friday"),
            ("enumeration-oxford", "office hours are Monday, Tuesday, and Thursday"),
            // Identical phrases are emphasis, not restatement.
            ("macbeth", "tomorrow, tomorrow, and tomorrow"),
            ("repeat", "see you tomorrow, tomorrow."),
            // Numbers are outside the rule on purpose: a two-element number
            // list at a clause end is ordinary enumeration.
            ("numbers", "I'll take 3, 4."),
            // No pause at all.
            ("no-pause", "see you tomorrow today"),
        ])
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
