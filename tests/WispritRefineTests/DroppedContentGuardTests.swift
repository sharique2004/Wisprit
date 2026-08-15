import XCTest
@testable import WispritRefine

/// The content-loss detector (no Python counterpart). It exists because the
/// plausibility band's floor is a RATIO: at 0.4× a 24-word dictation may come
/// back ten words shorter and still be called plausible.
///
/// Measured on 200 LibriSpeech test-clean clips through the real pipeline: raw
/// ASR WER 2.68%, refined WER 3.59% — the cleanup stage made real speech 34%
/// relatively WORSE. The worst clip is pinned below.
///
/// The discriminator is measured over 254 refine outputs on two corpora
/// (LibriSpeech + tts-samantha): legitimate cleanups never lost more than 2
/// unique content words unless the speaker cued a self-correction; the damaging
/// outputs scored 3, 3, 3 and 9. So, as with the obedience detectors, every
/// expectation here is written from both sides — what must fire, and the more
/// expensive half, what must not.
final class DroppedContentGuardTests: XCTestCase {

    func testThresholdIsTheMeasuredSeparation() {
        XCTAssertEqual(RefineGuards.droppedContentThreshold, 3)
        XCTAssertEqual(RefineGuards.contentStemLength, 4)
    }

    // MARK: - the measured damage

    /// ls-5142-33396-0052, the worst clip of the 200: a whole trailing clause
    /// deleted, ten words gone, and the word-count band passed it.
    func testLibriSpeechBraceletClauseDropIsRejected() {
        let raw = "Here is a ring for sift, the friendly, and here is a bracelet and a sword "
            + "would not be ashamed to hang at your side."
        let refined = "Here is a ring for sift, the friendly, and here is a bracelet and a sword."
        // The band that let it through, pinned: this is the guard's whole reason
        // to exist, not an incidental second opinion.
        XCTAssertTrue(RefineGuards.plausible(raw: raw, refined: refined))
        XCTAssertTrue(RefineGuards.droppedContent(raw: raw, refined: refined))
    }

    /// The other shapes the corpus produced at loss ≥ 3: a dropped middle
    /// clause and a dropped trailing sentence, both inside the band.
    func testDroppedClausesAreRejected() {
        let cases: [(String, String)] = [
            ("we need to ship the retry policy before friday and then review the migration "
             + "script with the platform team on monday",
             "We need to ship the retry policy before Friday."),
            ("the quarterly numbers were up eleven percent in europe and down four percent "
             + "in the pacific region",
             "The quarterly numbers were up eleven percent in Europe."),
            ("she opened the window looked out at the garden and listened to the rain",
             "She opened the window."),
        ]
        for (raw, refined) in cases {
            XCTAssertTrue(RefineGuards.droppedContent(raw: raw, refined: refined),
                          refined.debugDescription)
        }
    }

    // MARK: - what must survive (the expensive half)

    /// Small paraphrase inside the measured tolerance. LibriSpeech
    /// ls-1272-128104-0004: the reply drops "for instance" and rephrases it as
    /// "such as" — loss 1, well under the threshold. Bouncing this would cost
    /// the product every legitimate cleanup on long speech.
    func testSmallParaphraseOnLongSpeechPasses() {
        let raw = "much later when a friend of his was preparing an edition of all his latin "
            + "works he remarked to his home circle if i had my way about it they would "
            + "republish only those of my books which have doctrine my galatians for instance"
        let refined = "Much later, when a friend of his was preparing an edition of all his "
            + "Latin works, he remarked to his home circle: if I had my way about it, they "
            + "would republish only those of my books which have doctrine, such as my Galatians."
        XCTAssertFalse(RefineGuards.droppedContent(raw: raw, refined: refined))
    }

    /// Prompt rule 4 in its own words: a cued self-correction legitimately
    /// deletes the abandoned half. Here half/past/nine — three content words,
    /// exactly at the threshold — go, and the cue is what says they should.
    func testCuedSelfCorrectionPasses() {
        let raw = "Let us move the stand up to half past nine. No, actually, quarter past 10."
        let refined = "Let us move the stand-up to quarter past 10."
        XCTAssertFalse(RefineGuards.droppedContent(raw: raw, refined: refined))
    }

    /// The prompt's own example.
    func testPromptSelfCorrectionExamplePasses() {
        XCTAssertFalse(RefineGuards.droppedContent(raw: "send it to bob sorry to alice",
                                                   refined: "send it to alice"))
    }

    /// Every cue form, on a deletion that would otherwise fire. The cue check
    /// runs on the INPUT: what the speaker said is what makes a big deletion
    /// legitimate, never what the model handed back.
    func testEveryCueSuppressesTheGuard() {
        let refined = "Ship the migration on Tuesday."
        let cued = [
            "ship the parser rewrite on friday no actually ship the migration on tuesday",
            "ship the parser rewrite on friday sorry ship the migration on tuesday",
            "ship the parser rewrite on friday i mean ship the migration on tuesday",
            "ship the parser rewrite on friday i meant ship the migration on tuesday",
            "ship the parser rewrite on friday scratch that ship the migration on tuesday",
            "ship the parser rewrite on friday or rather ship the migration on tuesday",
            "ship the parser rewrite on friday make that ship the migration on tuesday",
            "ship the parser rewrite on friday i said ship the migration on tuesday",
            "ship the parser rewrite on friday actually ship the migration on tuesday",
            "ship the parser rewrite on friday no ship the migration on tuesday",
        ]
        for raw in cued {
            XCTAssertFalse(RefineGuards.droppedContent(raw: raw, refined: refined),
                           raw.debugDescription)
        }
        // …and the same deletion with no cue at all is exactly what the guard is
        // for, so the cases above are testing the cue and nothing else.
        XCTAssertTrue(RefineGuards.droppedContent(
            raw: "ship the parser rewrite on friday and ship the migration on tuesday",
            refined: refined))
    }

    /// A cue in the REPLY is not a cue: the model may not license its own
    /// deletion.
    func testCueOnlyCountsInTheInput() {
        XCTAssertTrue(RefineGuards.droppedContent(
            raw: "ship the parser rewrite on friday and ship the migration on tuesday",
            refined: "Actually, ship the migration on Tuesday."))
    }

    /// The everyday transforms the stage exists to do. None may cost a word.
    func testOrdinaryCleanupPasses() {
        let clean: [(String, String)] = [
            // disfluency / restart
            ("I was going. I was gonna say the retry policy needs work.",
             "I was going to say the retry policy needs work."),
            // filler removal + ITN
            ("um can you send me the uh the q three report by friday",
             "Can you send me the Q3 report by Friday?"),
            ("um so basically we should uh probably migrate the the data base",
             "So basically we should probably migrate the database."),
            ("uh yeah so um i think that like we should you know just ship the thing",
             "I think we should just ship the thing."),
            ("we we we should probably just just ship it", "We should probably just ship it."),
            ("remind me to uh call the dentist tomorrow at 3pm",
             "Remind me to call the dentist tomorrow at 3 PM."),
            ("so we shipped it the tests passed and uh i will return the call",
             "We shipped it; the tests passed and I will return the call."),
            ("whats um seventeen times twenty three", "What's seventeen times twenty-three?"),
        ]
        for (raw, refined) in clean {
            XCTAssertFalse(RefineGuards.droppedContent(raw: raw, refined: refined),
                           refined.debugDescription)
        }
    }

    /// Inflection and ITN rewrites are not losses — the stem tolerance is what
    /// keeps the guard off the model's actual job.
    func testWordFormsAreNotLosses() {
        // founded/found, walk/walking, database/data base, eleven percent/11%.
        XCTAssertFalse(RefineGuards.droppedContent(
            raw: "he founded the company and started walk to work every morning after "
                + "the data base was migrated",
            refined: "He found the company and started walking to work every morning after "
                + "the database was migrated."))
    }

    /// Function words are excluded before counting, so a cleanup that reshuffles
    /// them wholesale is never mistaken for a clause drop. Excluding them can
    /// only make the guard more permissive, which is the safe direction.
    func testFunctionWordChurnIsNotLoss() {
        XCTAssertFalse(RefineGuards.droppedContent(
            raw: "and so it is that we would not have been able to do it at all in the end",
            refined: "We could not do it in the end."))
        XCTAssertTrue(RefineGuards.contentLossStopWords.isSuperset(of: RefineGuards.leadFillers))
        for word in ["the", "a", "an", "and", "or", "but", "of", "to", "in", "on", "at",
                     "is", "are", "was", "were", "be", "been", "i", "you", "he", "she",
                     "it", "we", "they", "this", "that", "these", "those", "with", "for",
                     "as", "not", "don't", "it's"] {
            XCTAssertTrue(RefineGuards.contentLossStopWords.contains(word), word)
        }
    }

    /// Loss is a MULTISET difference: a repeated word that comes back once is a
    /// real loss, not a free pass. (Three distinct repeats, so this fires.)
    func testRepeatedWordsAreCountedAsAMultiset() {
        XCTAssertTrue(RefineGuards.droppedContent(
            raw: "bring the red folder the green folder and the blue folder plus the tape "
                + "the tape and the stapler the stapler",
            refined: "Bring the red folder, the tape and the stapler."))
    }

    /// An empty reply belongs to `plausible`, which runs first and owns the
    /// long-recorded `implausible` row.
    func testEmptyReplyIsNotThisGuardsFailure() {
        XCTAssertFalse(RefineGuards.droppedContent(
            raw: "the quarterly numbers were up eleven percent", refined: ""))
        XCTAssertFalse(RefineGuards.droppedContent(raw: "", refined: ""))
    }
}
