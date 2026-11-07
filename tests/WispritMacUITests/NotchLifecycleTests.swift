import XCTest
@testable import WispritMacUI

/// The notch's lifecycle — and above all, that it always turns off.
final class NotchLifecycleTests: XCTestCase {

    private typealias L = NotchLifecycle

    // MARK: - the utterance, end to end

    func testAFullUtteranceEndsHidden() {
        var life = L()
        XCTAssertEqual(life.phase, .hidden)
        life.receive(.prewarm, sequence: 1, at: 0)
        XCTAssertEqual(life.phase, .listening(micLive: false), "grey until the mic opens")
        life.receive(.record, sequence: 2, at: 0.05)
        XCTAssertEqual(life.phase, .listening(micLive: true))
        for tick in 0..<40 {
            life.receive(.level(0.2), sequence: UInt64(3 + tick), at: 0.1 + Double(tick) * 0.05)
        }
        XCTAssertEqual(life.level, 0.2, accuracy: 1e-9)
        life.receive(.processing(.finalizing), sequence: 50, at: 2.2)
        XCTAssertEqual(life.phase, .processing(.finalizing))
        XCTAssertEqual(life.level, 0, "no meter once the mic is closed")
        life.receive(.processing(.refining), sequence: 51, at: 2.4)
        XCTAssertEqual(life.phase, .processing(.refining))
        life.receive(.result(.success), sequence: 52, at: 3.5)
        XCTAssertEqual(life.phase, .result(.success))
        life.advance(to: 3.5 + L.dwell(for: .success) - 0.01)
        XCTAssertEqual(life.phase, .result(.success), "the beat holds for its dwell")
        life.advance(to: 3.5 + L.dwell(for: .success))
        XCTAssertEqual(life.phase, .collapsing)
        life.collapseSettled(at: 4.4)
        XCTAssertEqual(life.phase, .hidden)
    }

    func testDismissFoldsFromEveryVisiblePhase() {
        let openers: [[NotchSignal]] = [
            [.prewarm], [.prewarm, .record], [.processing(.finalizing)],
            [.processing(.refining)], [.result(.error)],
        ]
        for opener in openers {
            var life = L()
            for signal in opener { life.receive(signal, at: 0) }
            XCTAssertTrue(life.phase.isVisible)
            life.receive(.dismiss, at: 0.1)
            XCTAssertEqual(life.phase, .collapsing, "\(opener)")
            life.advance(to: 0.1 + L.collapseBudget)
            XCTAssertEqual(life.phase, .hidden, "the fold has a hard stop: \(opener)")
        }
    }

    func testDismissWhileHiddenIsANoOp() {
        var life = L()
        XCTAssertFalse(life.receive(.dismiss, at: 0))
        XCTAssertEqual(life.phase, .hidden)
    }

    // MARK: - watchdogs

    func testListeningWithoutLevelTicksFoldsAfterThreeSeconds() {
        var life = L()
        life.receive(.prewarm, at: 0)
        life.receive(.record, at: 0.05)
        life.advance(to: 0.05 + L.levelSilenceTimeout - 0.01)
        XCTAssertEqual(life.phase, .listening(micLive: true))
        life.advance(to: 0.05 + L.levelSilenceTimeout)
        XCTAssertEqual(life.phase, .collapsing, "the mic ticker stopped and nobody told us")
    }

    func testLevelTicksKeepAHeldKeyAliveIndefinitely() {
        var life = L()
        life.receive(.prewarm, at: 0)
        life.receive(.record, at: 0.05)
        var t = 0.1
        while t < 60 {
            life.receive(.level(0.01), at: t)
            life.advance(to: t)
            t += 0.05
        }
        XCTAssertEqual(life.phase, .listening(micLive: true), "a minute-long hold is fine")
    }

    func testAPrewarmThatNeverOpensTheMicFolds() {
        var life = L()
        life.receive(.prewarm, at: 0)
        life.advance(to: L.prewarmTimeout - 0.01)
        XCTAssertEqual(life.phase, .listening(micLive: false))
        life.advance(to: L.prewarmTimeout)
        XCTAssertEqual(life.phase, .collapsing)
    }

    func testProcessingWithoutAResultFoldsAndEachStageRestartsTheClock() {
        var life = L()
        life.receive(.processing(.finalizing), at: 0)
        life.receive(.processing(.refining), at: 10)
        life.advance(to: 10 + L.processingTimeout - 0.01)
        XCTAssertEqual(life.phase, .processing(.refining), "refine restarted the clock")
        life.advance(to: 10 + L.processingTimeout)
        XCTAssertEqual(life.phase, .collapsing)
    }

    func testAStalledFrameClockStillReachesHiddenInOneAdvance() {
        var life = L()
        life.receive(.result(.success), at: 0)
        // Nothing ran for ten seconds (display asleep). One heartbeat later:
        life.advance(to: 10)
        XCTAssertEqual(life.phase, .hidden, "result → collapsing → hidden in a single catch-up")
    }

    // MARK: - staleness

    func testALevelTakenBeforeFinalizingCannotReopenListening() {
        var life = L()
        life.receive(.prewarm, sequence: 1, at: 0)
        life.receive(.record, sequence: 2, at: 0.05)
        life.receive(.processing(.finalizing), sequence: 10, at: 1)
        // Stamped 9 on the ticker thread, delivered after finalizing.
        XCTAssertFalse(life.receive(.level(0.8), sequence: 9, at: 1.01))
        XCTAssertEqual(life.phase, .processing(.finalizing))
        XCTAssertEqual(life.level, 0)
    }

    func testAStaleRecordAfterAHideCannotResurrectTheNotch() {
        var life = L()
        life.receive(.prewarm, sequence: 4, at: 0)
        life.receive(.dismiss, sequence: 6, at: 0.2)
        life.advance(to: 1)
        XCTAssertEqual(life.phase, .hidden)
        XCTAssertFalse(life.receive(.record, sequence: 5, at: 1.1))
        XCTAssertFalse(life.receive(.prewarm, sequence: 5, at: 1.1))
        XCTAssertEqual(life.phase, .hidden)
        // A genuinely new press is newer than the hide, and opens.
        life.receive(.prewarm, sequence: 7, at: 2)
        XCTAssertEqual(life.phase, .listening(micLive: false))
    }

    func testAResultFromThePreviousUtteranceCannotEndTheCurrentOne() {
        var life = L()
        life.receive(.prewarm, sequence: 10, at: 0)
        life.receive(.record, sequence: 11, at: 0.05)
        XCTAssertFalse(life.receive(.result(.success), sequence: 9, at: 0.1))
        XCTAssertFalse(life.receive(.dismiss, sequence: 8, at: 0.1))
        XCTAssertEqual(life.phase, .listening(micLive: true))
    }

    func testAStaleProcessingSignalCannotOutliveAResult() {
        var life = L()
        life.receive(.prewarm, sequence: 1, at: 0)
        life.receive(.result(.missed), sequence: 5, at: 1)
        XCTAssertFalse(life.receive(.processing(.refining), sequence: 4, at: 1.01))
        XCTAssertEqual(life.phase, .result(.missed))
    }

    func testLevelsNeverOpenAnything() {
        var life = L()
        XCTAssertFalse(life.receive(.level(1), at: 0))
        XCTAssertEqual(life.phase, .hidden)
        life.receive(.processing(.finalizing), at: 1)
        life.receive(.level(1), at: 1.1)
        XCTAssertEqual(life.phase, .processing(.finalizing))
        XCTAssertEqual(life.level, 0)
    }

    func testANewPressNeverInheritsTheOldOrange() {
        var life = L()
        life.receive(.prewarm, at: 0)
        life.receive(.record, at: 0.05)
        // The previous utterance never closed; a new press arrives.
        life.receive(.prewarm, at: 1)
        XCTAssertEqual(life.phase, .listening(micLive: false))
    }

    // MARK: - suppression and the session's own word

    func testSuppressIsImmediateFromAnywhere() {
        for opener: NotchSignal in [.prewarm, .record, .processing(.finalizing), .result(.error), .dismiss] {
            var life = L()
            life.receive(.prewarm, at: 0)
            life.receive(opener, at: 0.1)
            life.receive(.suppress, at: 0.2)
            XCTAssertEqual(life.phase, .hidden, "\(opener)")
            XCTAssertNil(life.deadline)
        }
    }

    func testSessionIdleFoldsALiveNotchAfterAShortGrace() {
        var life = L()
        life.receive(.prewarm, at: 0)
        life.receive(.record, at: 0.05)
        life.receive(.level(0.3), at: 0.5)
        life.receive(.sessionIdle, at: 1)
        XCTAssertEqual(life.phase, .listening(micLive: true))
        life.advance(to: 1 + L.sessionIdleGrace)
        XCTAssertEqual(life.phase, .collapsing, "idle session: no mic, so no orange")
    }

    /// The empty-utterance path reports idle and *then* flashes the miss.
    func testAResultInsideTheIdleGraceWins() {
        var life = L()
        life.receive(.processing(.finalizing), at: 0)
        life.receive(.sessionIdle, at: 1)
        life.receive(.result(.missed), at: 1.01)
        life.advance(to: 1.5)
        XCTAssertEqual(life.phase, .result(.missed))
    }

    func testSessionIdleNeverCutsAResultShort() {
        var life = L()
        life.receive(.result(.success), at: 0)
        life.receive(.sessionIdle, at: 0.01)
        life.advance(to: 0.3)
        XCTAssertEqual(life.phase, .result(.success))
    }

    func testSessionIdleLeavesAPrewarmToItsOwnWatchdog() {
        // Key-down publishes the prewarm before the session leaves idle.
        var life = L()
        life.receive(.prewarm, at: 0)
        life.receive(.sessionIdle, at: 0.01)
        life.advance(to: 1)
        XCTAssertEqual(life.phase, .listening(micLive: false))
    }

    func testAnUnpromptedResultShowsAndFolds() {
        // ⌘⌃V paste-last succeeds with nothing on screen.
        var life = L()
        life.receive(.result(.success), at: 0)
        XCTAssertEqual(life.phase, .result(.success))
        life.advance(to: L.dwell(for: .success) + L.collapseBudget)
        XCTAssertEqual(life.phase, .hidden)
    }

    func testPinnedPreviewHasNoDeadlinesButStillFolds() {
        var life = L()
        life.pinned = true
        life.receive(.prewarm, at: 0)
        life.receive(.record, at: 0.05)
        XCTAssertNil(life.deadline)
        life.advance(to: 1000)
        XCTAssertEqual(life.phase, .listening(micLive: true))
        life.receive(.dismiss, at: 1000)
        life.advance(to: 1001)
        XCTAssertEqual(life.phase, .hidden, "a fold always finishes, pinned or not")
    }

    // MARK: - the termination property

    func testTheWorstCaseIsBounded() {
        XCTAssertEqual(L.worstCaseToHidden, L.processingTimeout + L.collapseBudget, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(L.worstCaseToHidden, 16)
    }

    /// Brute force: any sequence of signals — in any order, with any stamps,
    /// stale or not — followed by silence ends hidden within the bound.
    func testEverySignalSequenceTerminates() {
        var rng = SeededGenerator(seed: 0xD1C7A7E)
        let palette: [NotchSignal] = [
            .prewarm, .record, .level(0.2), .level(0), .processing(.finalizing),
            .processing(.refining), .result(.success), .result(.missed), .result(.tooQuiet),
            .result(.error), .result(.blockedSecure), .dismiss, .sessionIdle, .suppress,
        ]
        for _ in 0..<2000 {
            var life = L()
            var t = 0.0
            var seq: UInt64 = 0
            let count = Int(rng.uniform(1, 25))
            for _ in 0..<count {
                let signal = palette[Int(rng.uniform(0, Double(palette.count) - 0.001))]
                seq += 1
                // A third of calls arrive out of order or unstamped.
                let roll = rng.uniform(0, 1)
                let stamp: UInt64? = roll < 0.15 ? nil : (roll < 0.33 ? seq &- UInt64(rng.uniform(1, 4)) : seq)
                t += rng.uniform(0, 2)
                let changed = life.receive(signal, sequence: stamp, at: t)
                if changed, case .listening(micLive: true) = life.phase {
                    // The orange rule's machine half: only `record` lights it.
                    XCTAssertEqual(signal, .record)
                }
                life.advance(to: t)
            }
            life.advance(to: t + L.worstCaseToHidden + 0.001)
            XCTAssertEqual(life.phase, .hidden)
            XCTAssertNil(life.deadline)
        }
    }

    /// The same, but the frame clock only ever calls `advance` at 4 Hz — the
    /// heartbeat's rate — and the view never reports a settled fold.
    func testTheHeartbeatAloneTurnsItOff() {
        var life = L()
        life.receive(.prewarm, at: 0)
        life.receive(.record, at: 0.05)
        life.receive(.processing(.refining), at: 2)
        var t = 2.0
        while life.phase != .hidden && t < 40 {
            t += 0.25
            life.advance(to: t)
        }
        XCTAssertEqual(life.phase, .hidden)
        XCTAssertLessThanOrEqual(t, 2 + L.processingTimeout + L.collapseBudget + 0.25)
    }
}
