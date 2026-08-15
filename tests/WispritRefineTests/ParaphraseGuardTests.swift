import XCTest
import WispritEval
import WispritKit

@testable import WispritRefine

/// The substitution/insertion guard — the failure every other guard in the
/// accept chain is structurally blind to.
///
/// Every MUST-BOUNCE row below is a real stage record from
/// `stages.ls-test-{clean,other}.apple_live.en-US.refine-on.dict-on.detail.jsonl`
/// that came back `ai="applied"` and made the transcript measurably WORSE
/// against the LibriSpeech reference. Every MUST-ACCEPT row is either a measured
/// legitimate repair from the same records, a `tts-samantha` record whose output
/// the BASELINE.json matrix pins, or a battery case. The Python replay oracle
/// (`scratchpad/simulate_guard.py`, variant FINAL at 0.60) flags exactly these
/// eight clip ids and nothing else — the two implementations are each other's
/// check, so a change here that does not also move the oracle is a bug.
final class ParaphraseGuardTests: XCTestCase {

    private func bounces(_ raw: String, _ refined: String) -> Bool {
        RefineGuards.paraphrasedContent(raw: raw, refined: refined)
    }

    // MARK: - the measured damage (8 clips, 16 of the 72 residual edits)

    /// The tidy-up substitution: an archaic-but-correct word swapped for its
    /// modern synonym. Three clips, the same edit, all against the reference.
    func testSynonymSubstitutionIsRejected() {
        XCTAssertTrue(bounces(  // ls-1995-1837-0003
            "The revelation of his love lighted and brightened slowly till it flamed like a "
                + "sunrise over him and left him in burning wonder.",
            "The revelation of his love lighted and brightened slowly until it flamed like a "
                + "sunrise over him and left him in burning wonder."))
        XCTAssertTrue(bounces(  // ls-2094-142345-0015
            "To all appearance, molly had got through her after dinner work in an exemplary "
                + "manner, had cleaned herself with great dispatch, and now came to ask "
                + "submissively if she should sit down to her spinning till milking time.",
            "To all appearance, Molly had got through her after-dinner work in an exemplary "
                + "manner, had cleaned herself with great dispatch, and now came to ask "
                + "submissively if she should sit down to her spinning until milking time."))
        XCTAssertTrue(bounces(  // ls-3538-163624-0012
            "But Sigurd waited till half of him had crawled over the pit, and then he thrust "
                + "the sword graham right into his very heart.",
            "But Sigurd waited until half of him had crawled over the pit, and then he thrust "
                + "the sword Graham right into his very heart."))
    }

    /// ls-2830-3979-0007, the marquee catch and the alignment tie-break canary.
    /// "my galatians for instance" → "such as my galatians" is an EXACT cost tie
    /// between four substitutions and two insertions plus two deletions. Only a
    /// backtrace that prefers the diagonal merges it into one scoreable region;
    /// the insertion/deletion path yields a pure-insertion region that is all
    /// stop words ("such", "as") next to a pure deletion, and both are skipped.
    /// If this row ever goes green while the others stay red, the alignment
    /// tie-break moved.
    func testAReshuffledClauseIsRejected() {
        XCTAssertTrue(bounces(
            "Much later, when a friend of his was preparing an edition of all his Latin works, "
                + "he remarked to his home circle. If I had my way about it, they would "
                + "republish only those of my books which have doctrine my Galatians, for "
                + "instance.",
            "Much later, when a friend of his was preparing an edition of all his Latin works, "
                + "he remarked to his home circle. If I had my way about it, they would "
                + "republish only those of my books which have doctrine, such as my Galatians."))
    }

    /// Re-inflection that changes who is doing what: a finite clause turned into
    /// a participle, and a proper noun turned into a verb.
    func testReinflectedClausesAreRejected() {
        XCTAssertTrue(bounces(  // ls-2414-128292-0027
            "They sleep quietly, they enjoy their new security.",
            "They sleep quietly, enjoying their new security."))
        XCTAssertTrue(bounces(  // ls-6930-81414-0024
            "My tongue refused to articulate my power of speech, left me.",
            "My tongue refused to articulate my power of speech, leaving me."))
        XCTAssertTrue(bounces(  // ls-3005-163389-0010
            "The crowd washed back sudden, and then broke all apart and went tearing off every "
                + "which way and buck Harkness. He heeled it after them, looking tolerable, "
                + "cheap.",
            "The crowd washed back suddenly, and then broke apart and went tearing off every "
                + "which way, bucking Harkness. He heeled it after them, looking tolerable, "
                + "cheap."))
    }

    /// ls-2094-142345-0045: the model moved the attribution, which the aligner
    /// reads as a deletion in one place and an INSERTION of a content word in
    /// another. Insertion is the half no other guard can see at all — nothing
    /// was lost, so `droppedContent` is silent by construction.
    func testAnInsertedContentWordIsRejected() {
        XCTAssertTrue(bounces("Oh sir, don't mention it said missus Poyser.",
                              "Oh sir, don't mention it. Missus Poyser said."))
        // …and the function-word half of the same rule: grammar cleanup may
        // insert freely.
        XCTAssertFalse(bounces("we should ship it friday", "We should ship it on Friday."))
    }

    // MARK: - the expensive half: what must survive

    /// The phonetic exemption, and the reason it can never be tightened. These
    /// four scores are all one band. Two of them are the model REPAIRING the
    /// ASR; two are the model breaking it. No threshold separates them, so the
    /// guard keeps its hands off all four and ~13 of the 72 residual edits stay.
    func testPhoneticallyCloseSubstitutionsAreExempt() {
        // repairs — must survive
        XCTAssertFalse(bounces("can you right that down for me", "Can you write that down for me?"))
        XCTAssertFalse(bounces(  // ls-4852-28312-0027, a genuine fix
            "A courtyard was sparsely lit by a flaring torture, two showing a swinging sign "
                + "hung on a post.",
            "A courtyard was sparsely lit by a flaring torch, two showing a swinging sign "
                + "hung on a post."))
        // damage in the same band — knowingly let through
        XCTAssertFalse(bounces(  // ls-2830-3980-0023
            "These perverters of the righteousness of Christ resist the father and the son, "
                + "and the works of them both.",
            "These perverts of the righteousness of Christ resist the Father and the Son, "
                + "and the works of them both."))
        XCTAssertFalse(bounces(  // ls-7729-102255-0038
            "Atcheson, who had been haranguing the mob planted his two guns before the "
                + "building and trained them upon it.",
            "Atcheson, who had been harassing the mob, planted his two guns before the "
                + "building and trained them upon it."))
    }

    /// The threshold is a measured window, not a round number. Below 0.568 the
    /// marquee catch is lost; at 0.62 — the constant `AntecedentMatcher` uses
    /// and the one an implementer naturally reaches for — the real torture→torch
    /// repair is bounced. 0.60 is inside the only gap there is.
    func testTheSimilarityFloorSitsInTheMeasuredGap() {
        XCTAssertEqual(RefineGuards.paraphraseSimilarityFloor, 0.60, accuracy: 1e-9)
        XCTAssertEqual(PhoneticScorer.score("torture", "torch"), 0.6086, accuracy: 5e-4)
        XCTAssertEqual(
            PhoneticScorer.score("mygalatiansforinstance", "suchasmygalatians"), 0.5682,
            accuracy: 5e-4)
        XCTAssertLessThan(PhoneticScorer.score("mygalatiansforinstance", "suchasmygalatians"),
                          RefineGuards.paraphraseSimilarityFloor)
        XCTAssertGreaterThan(PhoneticScorer.score("torture", "torch"),
                             RefineGuards.paraphraseSimilarityFloor)
    }

    /// Multi-token merges are what a region comparison exists for. Every one of
    /// these is a paraphrase at the TOKEN level — a per-token variant of this
    /// guard bounces all four, which is why the naive shape was dead on arrival.
    func testMergesAndSplitsAreExempt() {
        let merges: [(String, String)] = [
            ("how do i um restart the post grass server on you bun to",
             "How do I restart the postgres server on Ubuntu?"),
            ("we are moving the analytics tables to post gres sequel next sprint",
             "We are moving the analytics tables to PostgreSQL next sprint."),
            ("i tested it on the i phone and the i pad", "I tested it on the iPhone and the iPad."),
            ("the workload is write heavy so we need better indexes",
             "The workload is write-heavy so we need better indexes."),
            // archaic orthography the LibriSpeech reference penalises and modern
            // dictation does not
            ("we will ship it to morrow and review it to day",
             "We will ship it tomorrow and review it today."),
        ]
        for (raw, refined) in merges {
            XCTAssertFalse(bounces(raw, refined), refined.debugDescription)
        }
    }

    /// ITN is the model's instructed job and has exactly this shape.
    func testInverseTextNormalizationIsExempt() {
        XCTAssertFalse(bounces("the quarterly numbers were up eleven percent",
                               "The quarterly numbers were up 11%."))
        XCTAssertFalse(bounces("call me back at 430 on tuesday", "Call me back at 4:30 PM on Tuesday."))
        XCTAssertFalse(bounces("um the total is three hundred twenty seven dollars",
                               "The total is $327."))
    }

    /// tts df-05, an `ai="applied"` record the BASELINE.json matrix pins: a
    /// restart the model collapsed. The region merges to (i, was, gonna) → (to),
    /// which fails equality, stem and phonetic tests outright — it is only
    /// accepted because the colloquial expansion turns "gonna" into "going to"
    /// and the reply still carries "going". Without that rescue this guard
    /// breaks a pinned baseline.
    func testARestartCollapseIsExempt() {
        XCTAssertFalse(bounces("I was going. I was gonna say the retry policy needs work.",
                               "I was going to say the retry policy needs work."))
        XCTAssertFalse(bounces("i was gonna ship it friday", "I was going to ship it Friday."))
    }

    /// Same contract as `droppedContent`: rule 4 is the one transform that
    /// legitimately rewrites, and it is always cued.
    func testCuedSelfCorrectionsAreExempt() {
        XCTAssertFalse(bounces("lets meet on thursday no actually wednesday",
                               "Let's meet on Wednesday."))
        XCTAssertFalse(bounces("send it to marketing sorry to finance", "Send it to finance."))
        XCTAssertFalse(bounces("we should take the highway actually you know what lets take "
                                   + "the coast road",
                               "Let's take the coast road."))
    }

    /// Function-word churn is the stage's core job and is indistinguishable from
    /// grammar cleanup, so it is skipped wholesale.
    func testFunctionWordChurnIsExempt() {
        XCTAssertFalse(bounces("um so basically we should uh probably migrate the the data base",
                               "So basically, we should probably migrate the database."))
        XCTAssertFalse(bounces("we we we should probably just just ship it",
                               "We should probably just ship it."))
        XCTAssertFalse(bounces("uh yeah so um i think that like we should you know just ship "
                                   + "the thing",
                               "I think we should just ship the thing."))
    }

    /// Pure deletions belong to `droppedContent`. Counting them here too would
    /// move rows that guard has been reporting since it landed.
    func testPureDeletionsBelongToTheOtherGuard() {
        let raw = "we need to ship the retry policy before friday and then review the migration "
            + "script with the platform team on monday"
        let refined = "We need to ship the retry policy before Friday."
        XCTAssertFalse(bounces(raw, refined))
        XCTAssertTrue(RefineGuards.droppedContent(raw: raw, refined: refined))
    }

    /// Every recorded `tts-samantha` refine-on/dict-on output that CHANGED its
    /// input. `docs/eval/BASELINE.json` pins this matrix byte-for-byte, so a
    /// bounce here is a baseline break — and the replay measured zero.
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

    /// Every battery case that declares an ideal output: the guard may never
    /// stand between the model and a case the eval harness scores. (The verbatim
    /// cases, where `ideal == input`, pass trivially — that is the point.)
    func testNoBatteryIdealIsBounced() {
        var checked = 0
        for testCase in RefineBattery.cases {
            guard let ideal = testCase.ideal else { continue }
            checked += 1
            XCTAssertFalse(bounces(testCase.input, ideal), testCase.id)
        }
        XCTAssertGreaterThan(checked, 0, "the battery must still carry ideals to check")
    }

    // MARK: - the pieces

    /// The colloquial map is closed and its failure direction is verbatim, which
    /// is the safe one — but the map is what the restart rescue runs on, so its
    /// contents are load-bearing rather than decorative.
    func testColloquialExpansionCoversTheRestartShapes() {
        for word in ["gonna", "wanna", "gotta", "kinda", "sorta", "outta", "lemme", "gimme",
                     "dunno", "cause", "cuz"] {
            XCTAssertNotNil(RefineGuards.colloquialExpansions[word], word)
        }
        XCTAssertEqual(RefineGuards.expandColloquial(["i", "was", "gonna", "ship"]),
                       ["i", "was", "going", "to", "ship"])
    }

    /// Region grouping, stated directly rather than inferred from verdicts — the
    /// rest of this file depends on it.
    func testContiguousEditsFormOneRegion() {
        let regions = RefineGuards.alignedRegions(
            ["my", "galatians", "for", "instance"], ["such", "as", "my", "galatians"])
        XCTAssertEqual(regions.count, 1)
        XCTAssertEqual(regions[0].0, ["my", "galatians", "for", "instance"])
        XCTAssertEqual(regions[0].1, ["such", "as", "my", "galatians"])
        // Matches close a region; a later edit opens a new one.
        let split = RefineGuards.alignedRegions(["a", "cat", "on", "a", "mat"],
                                                ["a", "dog", "on", "a", "rug"])
        XCTAssertEqual(split.count, 2)
    }

    /// Separators are dropped so a merge reads as an identity.
    func testCollapseDropsSeparators() {
        XCTAssertEqual(RefineGuards.collapse(["write", "heavy"]), "writeheavy")
        XCTAssertEqual(RefineGuards.collapse(["write-heavy"]), "writeheavy")
        XCTAssertEqual(RefineGuards.collapse(["don't"]), "dont")
        XCTAssertEqual(RefineGuards.collapse(["don\u{2019}t"]), "dont")
    }

    /// The guard is pure and cheap enough to sit in the accept chain: the
    /// alignment is O(n²) in tokens, bounded by `maxWords`, against a model call
    /// measured in seconds.
    func testTheGuardIsPureAndFast() {
        let raw = String(repeating: "the quarterly numbers were up eleven percent in europe ",
                         count: 12)
        let refined = String(repeating: "The quarterly numbers were up 11% in Europe. ", count: 12)
        let first = bounces(raw, refined)
        for _ in 0..<20 { XCTAssertEqual(bounces(raw, refined), first) }

        let started = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<20 { _ = bounces(raw, refined) }
        let perCall = Double(DispatchTime.now().uptimeNanoseconds - started) / 20 / 1_000_000
        XCTAssertLessThan(perCall, 25.0, "paraphrasedContent took \(perCall) ms per call")
    }
}
