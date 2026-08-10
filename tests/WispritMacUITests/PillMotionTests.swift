import XCTest
@testable import WispritMacUI

/// The §2.5 transition table as assertions (FINAL-PLAN R13, native-feel §2.12
/// — "the largest spec/build gap"). Seven rows used to be hard cuts:
///
///   1. `hidden → prewarming`   90 ms ease-out fade + 4 pt rise
///   2. `prewarming → listening` 140 ms bar tint crossfade
///   3. width change             120 ms (spring 0.28 / 0.9)
///   4. `listening → finalizing` 120 ms desaturate…
///   5. …then the 6 ms × index staggered collapse
///   6. `finalizing → committed` 140 ms contraction (spring 0.22 / 0.86)
///   7. `any → hidden`           160 ms ease-in fade + 3 pt sink
///
/// The decisions are pure — `PillMotion` — so presence, duration and the
/// Reduce Motion contract ("durations survive; only motion goes") are unit
/// tests rather than screen recordings. The 20 Hz level path stays out of all
/// of it: a level tick changes neither visibility nor width, and the collapse
/// choreography runs on one animatable scalar over model-precomputed delays —
/// never 15 view identities.
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
        XCTAssertEqual(PillMotion.collapseStagger, 0.006)
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
            oldWidth: PillGeometry.widthCommitted, newWidth: PillGeometry.widthListening,
            newState: .hidden, reduceMotion: false)
        XCTAssertEqual(change.kind, .hide)
        XCTAssertEqual(change.duration, PillMotion.hideDuration)
        XCTAssertEqual(change.travel, PillMotion.hideSink)
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

    func testTheCommittedContractionHasItsOwnTiming() {
        let change = PillMotion.frameChange(
            wasVisible: true, isVisible: true,
            oldWidth: 260.5, newWidth: PillGeometry.widthCommitted,
            newState: .success, reduceMotion: false)
        XCTAssertEqual(change.kind, .contract)
        XCTAssertEqual(change.duration, PillMotion.committedDuration)
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
            oldWidth: 260.5, newWidth: 28, newState: .success, reduceMotion: true)
        XCTAssertEqual(contract.kind, .contract)
        XCTAssertFalse(contract.animatesFrame)

        let resize = PillMotion.frameChange(
            wasVisible: true, isVisible: true,
            oldWidth: 96, newWidth: 152.5, newState: .recording, reduceMotion: true)
        XCTAssertFalse(resize.animatesFrame)
    }

    // MARK: - the staggered collapse (rows 4–5)

    func testCollapseDelaysAreSixMillisecondsPerBar() {
        for index in 0..<PillGeometry.barCount {
            XCTAssertEqual(PillMotion.collapseDelay(forBar: index),
                           Double(index) * 0.006, accuracy: 1e-12)
        }
        XCTAssertEqual(
            PillMotion.collapseDuration(barCount: PillGeometry.barCount),
            PillMotion.collapseDelay(forBar: PillGeometry.barCount - 1)
                + PillMotion.collapseBarFall,
            accuracy: 1e-12)
    }

    func testCollapseProgressStaggersOldestFirst() {
        let count = PillGeometry.barCount
        XCTAssertEqual(PillMotion.collapseProgress(phase: 0, bar: 0, barCount: count), 0)
        XCTAssertEqual(PillMotion.collapseProgress(phase: 1, bar: count - 1, barCount: count), 1)
        // Midway, the left (oldest) bars are further down than the right
        // (newest) — the wipe reads left to right.
        let left = PillMotion.collapseProgress(phase: 0.5, bar: 0, barCount: count)
        let right = PillMotion.collapseProgress(phase: 0.5, bar: count - 1, barCount: count)
        XCTAssertGreaterThan(left, right)
        // And every bar lands exactly at floor by the end.
        for index in 0..<count {
            XCTAssertEqual(PillMotion.collapseProgress(phase: 1, bar: index, barCount: count), 1,
                           "bar \(index) must finish its fall")
        }
    }

    func testCollapseProgressIsClampedAndTotalCoversEveryBar() {
        let count = PillGeometry.barCount
        XCTAssertEqual(PillMotion.collapseProgress(phase: -1, bar: 3, barCount: count), 0)
        XCTAssertEqual(PillMotion.collapseProgress(phase: 2, bar: 3, barCount: count), 1)
        XCTAssertEqual(PillMotion.collapseProgress(phase: 1, bar: 0, barCount: 1), 1)
    }
}
