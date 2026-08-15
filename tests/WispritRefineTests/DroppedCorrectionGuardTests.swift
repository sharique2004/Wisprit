import XCTest
import WispritEval

@testable import WispritRefine

/// The cue's other edge.
///
/// `droppedContent` and `paraphrasedContent` both stand down when the input
/// carries a spoken self-correction, because resolving one is the model's job.
/// This guard is the check that the model actually DID it, and it is the only
/// guard in the chain whose repair happens downstream: the verbatim text still
/// carries the cue, and the deterministic resolver measurably resolves this
/// shape.
///
/// Everything here is grounded in production `utterance_detail`
/// (`~/.wisprit/history.sqlite`): #172 is the defect, #173–#177 are the same
/// utterance family that refine left alone and the resolver then got right —
/// which is why verbatim is the correct answer and not a consolation prize.
final class DroppedCorrectionGuardTests: XCTestCase {

    private func bounces(_ raw: String, _ refined: String) -> Bool {
        RefineGuards.droppedCorrection(raw: raw, refined: refined)
    }

    // MARK: - the measured defect

    /// Production utterance #172, verbatim. The model read "I mean today." as a
    /// hedge, deleted it, and kept "tomorrow" — the word the speaker was
    /// correcting. `ai=applied`, and "I was going to a hackathon tomorrow."
    /// went into the field on a day the user meant to say today.
    func testTheProductionCorrectionDeletionIsRejected() {
        let raw = "I was going to a hackathon tomorrow. I mean today."
        let refined = "I was going to a hackathon tomorrow."
        XCTAssertTrue(bounces(raw, refined))
        // …and why nothing else caught it: one content word is not a clause,
        // the shrink is unremarkable, and both content guards have already
        // stood down on the cue.
        XCTAssertTrue(RefineGuards.plausible(raw: raw, refined: refined))
        XCTAssertFalse(RefineGuards.droppedContent(raw: raw, refined: refined))
        XCTAssertFalse(RefineGuards.paraphrasedContent(raw: raw, refined: refined))
    }

    /// The same defect in the other direction (#176's raw, had refine deleted
    /// it) and across the other cue words, so the guard is keyed on the SHAPE
    /// and not on "i mean".
    func testTheSameShapeUnderEveryCueWord() {
        let cases: [(String, String)] = [
            ("Going to a hackathon tomorrow, I mean today.", "Going to a hackathon tomorrow."),
            ("I was planning on going for dinner with Vivek tonight. I mean, tomorrow morning.",
             "I was planning on going for dinner with Vivek tonight."),
            ("send the report to marketing sorry to finance", "Send the report to marketing."),
            ("lets meet on thursday no actually wednesday", "Let's meet on Thursday."),
            ("set the retry limit to three i meant five", "Set the retry limit to three."),
            ("move the standup to nine scratch that ten", "Move the stand-up to nine."),
        ]
        for (raw, refined) in cases {
            XCTAssertTrue(bounces(raw, refined), refined.debugDescription)
        }
    }

    // MARK: - the not-fire discipline (the expensive half)

    /// The model RESOLVING the correction is the whole point of rule 4 and must
    /// pass untouched. Every row is the correct output for a raw the guard sees
    /// as cued — including #177's shape, the coordinator's canary.
    func testAResolvedCorrectionPasses() {
        let resolved: [(String, String)] = [
            ("I was planning on going for dinner with Vivek tonight. I mean, tomorrow morning.",
             "I was planning on going for dinner with Vivek tomorrow morning."),
            ("I was going to a hackathon tomorrow. I mean today.",
             "I was going to a hackathon today."),
            ("I was going to a hackathon today, I mean tomorrow.",
             "I was going to a hackathon tomorrow."),
            ("send it to bob sorry to alice", "Send it to Alice."),
            ("send it to marketing sorry to finance", "Send it to finance."),
            ("lets meet on thursday no actually wednesday", "Let's meet on Wednesday."),
            ("let us move the stand up to half past nine no actually quarter past 10",
             "Let us move the stand-up to quarter past 10."),
            ("the board meeting is in september no actually october",
             "The board meeting is in October."),
            ("its you know basically a caching layer i mean a cache", "It's a cache."),
        ]
        for (raw, refined) in resolved {
            XCTAssertFalse(bounces(raw, refined), refined.debugDescription)
        }
    }

    /// A restart is not a correction of a WORD, and the battery pins it: the
    /// speaker abandons the whole clause. Condition (c) is what saves these —
    /// the abandoned "highway" is gone from the reply, so there is no
    /// kept-wrong-word to report.
    func testAbandonedRestartsPass() {
        XCTAssertFalse(bounces(
            "we should take the highway actually you know what lets take the coast road",
            "Let's take the coast road."))
        XCTAssertFalse(bounces("ship the parser rewrite on friday no actually ship the "
                                   + "migration on tuesday",
                               "Ship the migration on Tuesday."))
    }

    /// While the cue is still standing the resolver can act, so there is
    /// nothing to protect — this is the path every one of #173–#177 took.
    func testAnUntouchedCueIsNotThisGuardsBusiness() {
        for (raw, refined) in [
            ("I was going to a hackathon today, I mean tomorrow.",
             "I was going to a hackathon today, I mean tomorrow."),
            ("I was going to Hatathon today. I mean tomorrow.",
             "I was going to Hatathon today. I mean tomorrow."),
            ("I want to meet vivague. No, actually I want it. Shariq.",
             "I want to meet Vivague. No, actually I want it. Shariq."),
        ] {
            XCTAssertFalse(bounces(raw, refined), refined.debugDescription)
        }
    }

    /// A deletion that took the corrected word with it is a clause drop, not a
    /// kept-wrong-word — `droppedContent`'s row, and reporting it here too would
    /// move a long-recorded outcome.
    func testADeletionThatTookBothSidesIsNotReportedHere() {
        XCTAssertFalse(bounces("I was going to a hackathon tomorrow. I mean today.",
                               "I was going."))
        XCTAssertFalse(bounces("we need to ship the retry policy on friday sorry on monday "
                                   + "and then review the migration script with the team",
                               "We need to ship."))
    }

    /// No cue, nothing to drop. The narrowing built for `droppedContent` is
    /// shared, so a literal "no"/"rather"/"as I said" cannot manufacture a
    /// correction that was never spoken.
    func testAnIncidentalCueWordCannotManufactureACorrection() {
        XCTAssertFalse(bounces("we should ship the retry policy on friday",
                               "We should ship the retry policy on Friday."))
        XCTAssertFalse(bounces("there is no way we can ship the retry policy before friday",
                               "There is no way we can ship the retry policy."))
        XCTAssertFalse(bounces("the rollout plan is rather aggressive so we should ship it",
                               "The rollout plan is rather aggressive."))
        XCTAssertFalse(bounces("as i said we should ship the retry policy before friday",
                               "We should ship the retry policy before Friday."))
    }

    /// The stem tolerance runs on both sides, so an inflected or recased
    /// replacement still counts as resolved. Tolerance may only ever SUPPRESS
    /// this guard.
    func testInflectedReplacementsStillCountAsResolved() {
        XCTAssertFalse(bounces("we should migrate the cluster i mean migrating the shards",
                               "We should be migrating the shards."))
        XCTAssertFalse(bounces("send the invite to viveque no actually shariq",
                               "Send the invite to Shariq."))
    }

    /// Every battery case that declares an ideal: this guard may never stand
    /// between the model and a case the eval harness scores.
    func testNoBatteryIdealIsBounced() {
        var checked = 0
        for testCase in RefineBattery.cases {
            guard let ideal = testCase.ideal else { continue }
            checked += 1
            XCTAssertFalse(bounces(testCase.input, ideal), testCase.id)
        }
        XCTAssertGreaterThan(checked, 0)
    }

    /// Every recorded `tts-samantha` refine-on/dict-on output that changed its
    /// input — the matrix `docs/eval/BASELINE.json` pins byte-for-byte. Six of
    /// these are self-correction rows, so this is the densest not-fire evidence
    /// there is.
    func testNoRecordedTtsSamanthaOutputIsBounced() {
        let recorded: [(String, String)] = [
            ("We are moving the analytics tables to post grass sequel next sprint.",
             "We are moving the analytics tables to PostgreSQL next sprint."),
            ("How do I restart the post server on the Buntu?",
             "How do I restart the PostgreSQL server on Ubuntu?"),
            ("push the branch to get up and open a pool request.",
             "Push the branch to get up and open a pool request."),
            ("The Kubernitz cluster is running out of memory again.",
             "The Kubernetes cluster is running out of memory again."),
            ("Call me back at 430 on Tuesday.", "Call me back at 4:30 PM on Tuesday."),
            ("So basically we should probably migrate to the database.",
             "So basically, we should probably migrate to the database."),
            ("We, we, we should probably just just ship it.", "We should probably just ship it."),
            ("Let us meet on Thursday. No, actually Wednesday, after lunch.",
             "Let us meet on Wednesday, after lunch."),
            ("I was going. I was gonna say the retry policy needs work.",
             "I was going to say the retry policy needs work."),
            ("I want to have a meeting with Person X on Thursday. Um, no actually Friday.",
             "I want to have a meeting with Person X on Friday."),
            ("Let us move the stand up to half past nine. No, actually, quarter past 10.",
             "Let us move the stand-up to quarter past 10."),
            ("The board meeting is in September. No, actually October.",
             "The board meeting is in October."),
            ("Set the retry limit to three. No, actually five.", "Set the retry limit to five."),
            ("I want to meet vivague. No, actually I want it. Shariq.",
             "I want to meet Vivague. No, actually I want it. Shariq."),
            ("Send the invite to Viveque. No, actually, Shariq.", "Send the invite to Shariq."),
        ]
        for (raw, refined) in recorded {
            XCTAssertFalse(bounces(raw, refined), refined.debugDescription)
        }
    }

    // MARK: - the pieces

    /// The cue range is the cue's OWN words. The regex match reaches one
    /// character into the replacement to prove a correction has something to
    /// correct with, and slicing on that would eat the first letter of a
    /// one-word replacement — which is exactly #172's shape.
    func testTheCueRangeStopsAtTheCue() {
        let raw = "I was going to a hackathon tomorrow. I mean today."
        let range = try! XCTUnwrap(RefineGuards.firstSelfCorrectionCue(raw))
        XCTAssertEqual((raw as NSString).substring(with: range), "I mean")
        XCTAssertEqual((raw as NSString).substring(from: range.location + range.length),
                       " today.")
        XCTAssertNil(RefineGuards.firstSelfCorrectionCue("we should ship it on friday"))
        // The narrowing is shared with `droppedContent`, not re-implemented.
        XCTAssertNil(RefineGuards.firstSelfCorrectionCue("there is no way we can ship it"))
    }

    /// The replacement window is bounded: a correction replaces a phrase, not a
    /// clause. Three is past the longest in the measured family ("tomorrow
    /// morning", "quarter past ten") and short enough that a restart still
    /// lands inside it.
    func testTheReplacementWindowIsBounded() {
        XCTAssertEqual(RefineGuards.correctionReplacementWords, 3)
        // Inside the window, one surviving word is enough to call the
        // correction resolved — the tolerance runs in the safe direction.
        XCTAssertFalse(bounces("meet me at the office tomorrow i mean today at the cafe instead",
                               "Meet me at the office tomorrow at the cafe."))
        // Outside it, a stray later word does not rescue a correction whose
        // actual replacement ("today at noon") is gone while the superseded
        // "tomorrow" still stands.
        XCTAssertTrue(bounces("meet me at the office tomorrow i mean today at noon "
                                  + "downstairs instead",
                              "Meet me at the office tomorrow instead."))
    }

    func testTheGuardIsPureAndFast() {
        let raw = "I was going to a hackathon tomorrow. I mean today."
        let refined = "I was going to a hackathon tomorrow."
        for _ in 0..<50 { XCTAssertTrue(bounces(raw, refined)) }
        let started = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<200 { _ = bounces(raw, refined) }
        let perCall = Double(DispatchTime.now().uptimeNanoseconds - started) / 200 / 1_000_000
        XCTAssertLessThan(perCall, 2.0, "droppedCorrection took \(perCall) ms per call")
    }
}
