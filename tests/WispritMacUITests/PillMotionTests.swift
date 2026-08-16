import XCTest
@testable import WispritMacUI

/// The transition table as assertions. The rows that used to be hard cuts:
///
///   1. `hidden → prewarming`    90 ms ease-out fade + 4 pt rise
///   2. `prewarming → listening` 140 ms bar tint crossfade
///   3. width change             120 ms (spring 0.28 / 0.9)
///   4. release → processing     120 ms: bars to floor *and* cream to muted
///   5. the meter's 20 Hz feed    200 ms linear tween per sample, at 60 fps
///   6. commit                   140 ms contraction back to the resting capsule
///   7. `any → hidden`           160 ms ease-in fade + 3 pt sink
///   8. a notice                 133 ms pop, 400 ms unfold, 250 ms fold
///
/// The decisions are pure — `PillMotion`, `PillMeterFrame` — so presence,
/// duration, curve and the Reduce Motion contract ("durations survive; only
/// motion goes") are unit tests rather than screen recordings.
///
/// Two whole families of assertion are gone from this file on purpose. The
/// staggered collapse and the thinking crest were both *our* inventions, and
/// frame measurement of the real Wispr Flow app says it does neither: its row
/// drops as a unit and it puts a spinner in the wait. Tests that pinned them
/// were pinning a design, not a behaviour users depend on.
final class PillMotionTests: XCTestCase {

    // MARK: - the spec's numbers, byte for byte

    func testSpecDurations() {
        XCTAssertEqual(PillMotion.appearDuration, 0.09)
        XCTAssertEqual(PillMotion.appearRise, 4.0)
        XCTAssertEqual(PillMotion.tintCrossfadeDuration, 0.14)
        XCTAssertEqual(PillMotion.desaturateDuration, 0.12)
        XCTAssertEqual(PillMotion.widthDuration, 0.12)
        XCTAssertEqual(PillMotion.widthSpringResponse, 0.28)
        XCTAssertEqual(PillMotion.widthSpringDamping, 0.9)
        XCTAssertEqual(PillMotion.committedDuration, 0.14)
        XCTAssertEqual(PillMotion.committedSpringResponse, 0.22)
        XCTAssertEqual(PillMotion.committedSpringDamping, 0.86)
        XCTAssertEqual(PillMotion.hideDuration, 0.16)
        XCTAssertEqual(PillMotion.hideSink, 3.0)
    }

    /// The meter's own row, and the reason the pill glides instead of ticking.
    ///
    /// 200 ms overlaps four 50 ms samples, so a bar is always mid-tween and
    /// never lands on a target and waits — and the tween is linear because both
    /// Flow artefacts are linear (their Lottie's handles are exactly linear;
    /// their web demo takes `element.animate`'s linear default). The ear's
    /// attack/release asymmetry lives in the envelope, not here.
    func testTheMeterTweenOutlivesItsSampleAndIsLinear() {
        XCTAssertEqual(PillMotion.meterTweenDuration, 0.20)
        XCTAssertGreaterThan(PillMotion.meterTweenDuration, BarSynthesizer.tickInterval * 3,
                             "a tween shorter than the feed would land and wait — that is a tick")
        XCTAssertTrue(PillMotion.meterTweenIsLinear)
    }

    /// The spinner: eight discrete 45° steps, ~880 ms a revolution, arriving
    /// just *after* the bars have dropped so the two read as cause and effect.
    func testTheSpinnerStepsEightTimesPerRevolution() {
        XCTAssertEqual(PillGeometry.spinnerTicks, 8)
        XCTAssertEqual(PillMotion.spinnerStepDuration, 0.11)
        XCTAssertEqual(PillMotion.spinnerRevolution, 0.88, accuracy: 1e-9,
                       "the measured ~880 ms of Flow's release spinner")
        XCTAssertGreaterThan(PillMotion.spinnerFadeInDelay, 0)
        XCTAssertLessThan(PillMotion.spinnerFadeOut, PillMotion.spinnerFadeIn,
                          "leaving is faster than arriving — the result is already here")
        XCTAssertLessThan(PillGeometry.spinnerMinAlpha, 1.0,
                          "graded around the circle, or a discrete step reads as blinking")
    }

    /// Wispr's toast timings, on our tail.
    func testTheToastUnfoldsSlowlyAndFoldsFast() {
        XCTAssertEqual(PillMotion.noticePopDuration, 0.133)
        XCTAssertEqual(PillMotion.noticeUnfoldDuration, 0.40)
        XCTAssertEqual(PillMotion.noticeFoldDuration, 0.25)
        XCTAssertLessThan(PillMotion.noticeFoldDuration, PillMotion.noticeUnfoldDuration,
                          "arriving is an event; leaving is housekeeping")
        // The unfold decelerates hard (its out-x is small, its in-y is 1); the
        // fold is its mirror and accelerates away.
        let unfold = PillMotion.Curve.unfold.control!
        let fold = PillMotion.Curve.fold.control!
        XCTAssertLessThan(unfold.0, 0.2)
        XCTAssertEqual(unfold.3, 1.0)
        XCTAssertGreaterThan(fold.0, unfold.0)
        XCTAssertEqual(fold.2, 1.0)
        XCTAssertNil(PillMotion.Curve.easeOut.control, "AppKit's own is exactly right")
    }

    // MARK: - the toast rows (8)

    /// App-authored copy unfolds; a live partial does not. The discriminator is
    /// `message`, which `livePartial` never sets — a partial grows word by word
    /// and would look absurd taking 400 ms per word.
    func testOnlyAuthoredCopyUnfolds() {
        var idle = PillRender.collapsed
        idle.isVisible = true
        var notice = idle
        notice.bubble = "Learned Sharique"
        notice.message = "Learned Sharique"
        notice.totalWidth = 200
        XCTAssertEqual(PillMotion.NoticeChange.between(idle, notice), .opening)
        XCTAssertEqual(PillMotion.NoticeChange.between(notice, idle), .closing)

        var partial = idle
        partial.bubble = "so I was"
        partial.totalWidth = 160
        XCTAssertEqual(PillMotion.NoticeChange.between(idle, partial), .none,
                       "a live partial is not a toast")

        let unfold = PillMotion.frameChange(
            wasVisible: true, isVisible: true, oldWidth: 96, newWidth: 200,
            newState: .recording, reduceMotion: false, notice: .opening)
        XCTAssertEqual(unfold.duration, PillMotion.noticeUnfoldDuration)
        XCTAssertEqual(unfold.curve, .unfold)

        let grow = PillMotion.frameChange(
            wasVisible: true, isVisible: true, oldWidth: 96, newWidth: 160,
            newState: .recording, reduceMotion: false, notice: .none)
        XCTAssertEqual(grow.duration, PillMotion.widthDuration)
        XCTAssertEqual(grow.curve, .easeOut)
    }

    /// A notice expiring is a fold, not a commit contraction — even though the
    /// state is `.success` and the width is shrinking, which is exactly the
    /// shape the contraction arm looks for.
    func testANoticeExpiringFoldsRatherThanContracting() {
        let change = PillMotion.frameChange(
            wasVisible: true, isVisible: true, oldWidth: 200, newWidth: 96,
            newState: .success, reduceMotion: false, notice: .closing)
        XCTAssertEqual(change.kind, .resize)
        XCTAssertEqual(change.duration, PillMotion.noticeFoldDuration)
        XCTAssertEqual(change.curve, .fold)
    }

    // MARK: - panel frame rows (1, 3, 6, 7)

    func testAppearFadesAndRises() {
        let change = PillMotion.frameChange(
            wasVisible: false, isVisible: true,
            oldWidth: PillGeometry.widthListening, newWidth: PillGeometry.widthListening,
            newState: .prewarming, reduceMotion: false)
        XCTAssertEqual(change.kind, .appear)
        XCTAssertEqual(change.duration, PillMotion.appearDuration)
        XCTAssertEqual(change.travel, PillMotion.appearRise)
        XCTAssertTrue(change.animatesFrame)
    }

    func testHideFadesAndSinks() {
        let change = PillMotion.frameChange(
            wasVisible: true, isVisible: false,
            oldWidth: PillGeometry.widthProcessing, newWidth: PillGeometry.widthListening,
            newState: .hidden, reduceMotion: false)
        XCTAssertEqual(change.kind, .hide)
        XCTAssertEqual(change.duration, PillMotion.hideDuration)
        XCTAssertEqual(change.travel, PillMotion.hideSink)
        XCTAssertEqual(change.curve, .easeIn)
    }

    /// One hide duration for every exit. The success path does *not* get a
    /// faster fade of its own, because with a persistent resting bar there is
    /// no success hide to retime: the pill settles, it does not leave.
    func testTheHideDurationIsTheSameForEveryExit() {
        for state in [PillState.success, .error, .missed, .hidden] {
            let change = PillMotion.frameChange(
                wasVisible: true, isVisible: false, oldWidth: 128, newWidth: 96,
                newState: state, reduceMotion: false)
            XCTAssertEqual(change.duration, PillMotion.hideDuration, "\(state)")
        }
    }

    func testTailGrowthSpringsTheWidth() {
        let change = PillMotion.frameChange(
            wasVisible: true, isVisible: true,
            oldWidth: 96, newWidth: 152.5,
            newState: .recording, reduceMotion: false)
        XCTAssertEqual(change.kind, .resize)
        XCTAssertEqual(change.duration, PillMotion.widthDuration)
        XCTAssertTrue(change.animatesFrame)
    }

    /// The commit contracts from the processing capsule back to the resting
    /// one — 128 → 96, not 260.5 → 28. There is no check mark waiting at the
    /// end of it any more; the pill simply goes quiet where it started.
    func testTheCommittedContractionHasItsOwnTiming() {
        let change = PillMotion.frameChange(
            wasVisible: true, isVisible: true,
            oldWidth: PillGeometry.widthProcessing, newWidth: PillGeometry.widthListening,
            newState: .success, reduceMotion: false)
        XCTAssertEqual(change.kind, .contract)
        XCTAssertEqual(change.duration, PillMotion.committedDuration)
        XCTAssertEqual(change.curve, .easeOut)
    }

    /// A success that *grows* (a green notice row) is a resize, not the
    /// contraction — the contraction is specifically 260.5 → 28.
    func testAGrowingSuccessIsAResizeNotAContraction() {
        let change = PillMotion.frameChange(
            wasVisible: true, isVisible: true,
            oldWidth: 96, newWidth: 172.5,
            newState: .success, reduceMotion: false)
        XCTAssertEqual(change.kind, .resize)
    }

    /// The row that must stay missing: a level tick changes neither
    /// visibility nor width, so it never reaches an animated arm.
    func testALevelTickAnimatesNothing() {
        let change = PillMotion.frameChange(
            wasVisible: true, isVisible: true,
            oldWidth: 96, newWidth: 96,
            newState: .recording, reduceMotion: false)
        XCTAssertEqual(change.kind, .none)
        XCTAssertEqual(change.duration, 0)
    }

    // MARK: - Reduce Motion: durations survive, motion goes

    func testReduceMotionDropsTravelButKeepsTheFades() {
        let appear = PillMotion.frameChange(
            wasVisible: false, isVisible: true,
            oldWidth: 96, newWidth: 96, newState: .prewarming, reduceMotion: true)
        XCTAssertEqual(appear.kind, .appear)
        XCTAssertEqual(appear.duration, PillMotion.appearDuration, "the fade survives")
        XCTAssertEqual(appear.travel, 0, "the rise goes")
        XCTAssertFalse(appear.animatesFrame)

        let hide = PillMotion.frameChange(
            wasVisible: true, isVisible: false,
            oldWidth: 96, newWidth: 96, newState: .hidden, reduceMotion: true)
        XCTAssertEqual(hide.duration, PillMotion.hideDuration)
        XCTAssertEqual(hide.travel, 0)
        XCTAssertFalse(hide.animatesFrame)
    }

    /// §2.5: under Reduce Motion `committed` cross-fades instead of
    /// contracting — the frame snaps (the glyph crossfade in `PillSurface`
    /// carries the transition), and width changes snap likewise.
    func testReduceMotionSnapsTheFrame() {
        let contract = PillMotion.frameChange(
            wasVisible: true, isVisible: true,
            oldWidth: 128, newWidth: 96, newState: .success, reduceMotion: true)
        XCTAssertEqual(contract.kind, .contract)
        XCTAssertFalse(contract.animatesFrame)

        let resize = PillMotion.frameChange(
            wasVisible: true, isVisible: true,
            oldWidth: 96, newWidth: 152.5, newState: .recording, reduceMotion: true)
        XCTAssertFalse(resize.animatesFrame)
    }

    // MARK: - the arrival (NEW)

    /// The body springs up to meet the panel's fade. It may never overshoot 1:
    /// the hosting view clips to the panel, so a pill that grew past its own
    /// frame would have the overshoot sheared off at the sides — which is the
    /// bug the old hover scale and error shake both had.
    func testTheArrivalSpringNeverOvershootsItsPanel() {
        XCTAssertLessThan(PillMotion.appearScale, 1.0)
        XCTAssertGreaterThan(PillMotion.appearScale, 0.8, "a pop, not a zoom")
        XCTAssertGreaterThanOrEqual(PillMotion.appearSpringDamping, 0.8,
                                    "damping under 0.8 would overshoot past 1")
        XCTAssertLessThan(PillMotion.appearSpringResponse, 0.35,
                          "the pill has to be there the instant the key goes down")
    }

    func testOrientationMorphIsAShortSpringNotASnap() {
        XCTAssertEqual(PillMotion.orientationDuration, 0.32)
        XCTAssertEqual(PillMotion.orientationSpringDamping, 0.86, accuracy: 1e-9)
        XCTAssertGreaterThan(PillMotion.orientationSpringDamping, 0.8)
        let change = PillMotion.frameChange(
            wasVisible: true, isVisible: true,
            oldWidth: 128, newWidth: 28,
            newState: .recording, reduceMotion: false,
            oldHeight: 28, newHeight: 128)
        XCTAssertEqual(change.kind, .resize)
        XCTAssertEqual(change.duration, PillMotion.orientationDuration)
        XCTAssertTrue(change.animatesFrame)
        let reduced = PillMotion.frameChange(
            wasVisible: true, isVisible: true,
            oldWidth: 128, newWidth: 28,
            newState: .recording, reduceMotion: true,
            oldHeight: 28, newHeight: 128)
        XCTAssertFalse(reduced.animatesFrame, "Reduce Motion snaps the morph")
    }
}
