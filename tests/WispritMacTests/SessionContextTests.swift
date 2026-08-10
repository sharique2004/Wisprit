import XCTest
import WispritEngine
import WispritKit
import WispritMacInput
@testable import WispritMac

/// The session's whole contract with Phase-4 context, pinned with fakes:
/// capture begins at key-down, is drained exactly once at finalize (never
/// awaited — the port's API cannot block by construction), feeds the
/// vocabulary channel for THIS utterance only, rides the metrics row as three
/// additive fields, and persists nothing anywhere.
final class SessionContextTests: XCTestCase {

    // MARK: - lifecycle

    func testCaptureBeginsAtKeyDownAndDrainsAtFinalize() {
        let context = FakeContext()
        let h = SessionControllerTests.Harness(context: context)

        h.session.dispatch(HotkeyEvent(.press, ts: 0))
        XCTAssertEqual(context.beginCount, 1, "capture starts at key-down, with prewarm")
        XCTAssertEqual(context.finishCount, 0, "…and is not consumed before finalize")

        h.session.dispatch(HotkeyEvent(.release, ts: 1.0))
        XCTAssertEqual(context.finishCount, 1, "one drain per utterance")
    }

    /// The debounce discard and the Esc abort both drain the slot, so a
    /// snapshot can never survive into the next utterance.
    func testDiscardPathsStillDrainTheCapture() {
        let context = FakeContext()
        let h = SessionControllerTests.Harness(context: context)

        h.session.dispatch(HotkeyEvent(.press, ts: 0))
        h.session.dispatch(HotkeyEvent(.release, ts: 0.05))  // sub-debounce brush
        XCTAssertEqual(context.finishCount, 1)

        h.session.dispatch(HotkeyEvent(.press, ts: 10))
        h.session.dispatch(HotkeyEvent(.esc, ts: 10.5))
        XCTAssertEqual(context.finishCount, 2)
        XCTAssertEqual(h.metrics.records.count, 0,
                       "neither discard writes a metrics row — unchanged")
    }

    // MARK: - the payoff path

    /// Terms reach the vocabulary channel for the utterance they were read
    /// for: the existing reconcile → retro-correction machinery consumes them
    /// with nothing new in between.
    func testTermsReachTheVocabularyChannelForThisUtterance() {
        let context = FakeContext()
        context.outcome = ContextOutcome(status: .read,
                                         terms: ["InsForge", "Sharique"],
                                         captureMs: 12)
        let h = SessionControllerTests.Harness(reconcile: true, context: context)
        h.asr.result = UtteranceResult(text: "ping insforge", engine: "apple_live",
                                       finalizeMs: 100)

        h.utterance()

        let deadline = Date().addingTimeInterval(2)
        while h.asr.reconcileTally < 1, Date() < deadline { usleep(5_000) }
        XCTAssertEqual(h.asr.reconcileExtraTerms, [["InsForge", "Sharique"]])
    }

    /// The next utterance starts clean: no terms bleed across.
    func testTermsDoNotBleedIntoTheNextUtterance() {
        let context = FakeContext()
        context.outcome = ContextOutcome(status: .read, terms: ["InsForge"], captureMs: 5)
        let h = SessionControllerTests.Harness(reconcile: true, context: context)

        h.utterance()
        h.utterance()  // FakeContext hands out its script once, like the real slot

        let deadline = Date().addingTimeInterval(2)
        while h.asr.reconcileTally < 2, Date() < deadline { usleep(5_000) }
        // The two reconciles land on detached tasks, so compare as a multiset:
        // exactly one carried the terms, exactly one carried none.
        XCTAssertEqual(h.asr.reconcileExtraTerms.sorted { $0.count > $1.count },
                       [["InsForge"], []])
    }

    /// A late snapshot biases nothing — the reconcile runs with no extras.
    func testLateCaptureFeedsNothing() {
        let context = FakeContext()
        context.outcome = ContextOutcome(status: .late)
        let h = SessionControllerTests.Harness(reconcile: true, context: context)

        h.utterance()

        let deadline = Date().addingTimeInterval(2)
        while h.asr.reconcileTally < 1, Date() < deadline { usleep(5_000) }
        XCTAssertEqual(h.asr.reconcileExtraTerms, [[]])
    }

    // MARK: - metrics

    func testConsumedSnapshotRidesTheUtteranceRow() {
        let context = FakeContext()
        context.outcome = ContextOutcome(status: .read,
                                         terms: ["InsForge", "Sharique"],
                                         captureMs: 12.5)
        let h = SessionControllerTests.Harness(context: context)

        h.utterance()

        let row = h.metrics.last
        XCTAssertEqual(row?.ctx, "read")
        XCTAssertEqual(row?.ctxMs, 12.5)
        XCTAssertEqual(row?.ctxTerms, 2)
    }

    func testLateCaptureIsRecordedWithoutTermCount() {
        let context = FakeContext()
        context.outcome = ContextOutcome(status: .late)
        let h = SessionControllerTests.Harness(context: context)

        h.utterance()

        let row = h.metrics.last
        XCTAssertEqual(row?.ctx, "late")
        XCTAssertNil(row?.ctxMs)
        XCTAssertNil(row?.ctxTerms, "a term count only means something for a consumed snapshot")
    }

    /// No port, or a port whose feature is off: the fields stay absent, so the
    /// stream a pre-Phase-4 build wrote remains a byte-prefix of this one.
    func testNoContextMeansNoFields() {
        let h = SessionControllerTests.Harness()
        h.utterance()
        let row = h.metrics.last
        XCTAssertNil(row?.ctx)
        XCTAssertNil(row?.ctxMs)
        XCTAssertNil(row?.ctxTerms)

        let off = FakeContext()  // scripted outcome stays ContextOutcome()
        let h2 = SessionControllerTests.Harness(context: off)
        h2.utterance()
        XCTAssertNil(h2.metrics.last?.ctx)
    }

    // MARK: - nothing persisted

    /// Context terms never touch the dictionary: no learn, no pending entry.
    /// (`recordUse` is separately inert for unknown terms in the real store —
    /// pinned in `DictionaryStore` tests; here the session must not add any.)
    func testContextTermsNeverReachTheDictionary() {
        let context = FakeContext()
        context.outcome = ContextOutcome(status: .read,
                                         terms: ["InsForge", "Sharique"],
                                         captureMs: 3)
        let h = SessionControllerTests.Harness(reconcile: true, context: context)

        h.utterance()

        let deadline = Date().addingTimeInterval(2)
        while h.asr.reconcileTally < 1, Date() < deadline { usleep(5_000) }
        XCTAssertTrue(h.vocabulary.learned.isEmpty)
        XCTAssertTrue(h.vocabulary.pending.isEmpty)
    }
}
