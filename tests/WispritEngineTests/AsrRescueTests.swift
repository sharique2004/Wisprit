import XCTest
import WispritKit
@testable import WispritEngine

/// The batch-rescue policy: which streaming failures get the retained PCM
/// re-read, which reading wins, and — the line that must never move — which
/// results are left alone.
///
/// Production (494 utterances) had 14.4 % empty and 25 timeouts, every one of
/// them `chars=0`, while the whole utterance sat unread in `PcmRetentionBuffer`
/// because the rescue trigger was `crashed` alone. These tests pin the wider
/// trigger set AND the silence exemption that survives it: a silent
/// push-to-talk must still insert nothing (b0a763f).
///
/// No speech model is involved. The streaming engine is `FakeAsrEngine` and the
/// batch engine is a counting double, so what is under test is the POLICY.
final class AsrRescueTests: XCTestCase {

    private func manager(_ result: UtteranceResult,
                         batchText: String?) -> (AsrManager, CountingBatch) {
        let batch = CountingBatch(text: batchText)
        let engine = FakeAsrEngine(script: .init(result: result))
        return (AsrManager(settings: AsrSettings(),
                           primaryFactory: { _ in engine },
                           batch: FilteredBatchTranscriber(batch)), batch)
    }

    /// One second of audio — enough that `runBatch`'s non-empty guard passes.
    private func pcm(_ seconds: Double = 1) -> Data {
        Data(count: Int(seconds * PcmFormat.sampleRate) * PcmFormat.bytesPerFrame)
    }

    private func finalize(_ result: UtteranceResult,
                          batchText: String?) async -> (UtteranceResult, CountingBatch) {
        let (m, batch) = manager(result, batchText: batchText)
        await m.begin { _ in }
        m.feed(pcm: pcm())
        return (await m.finalize(), batch)
    }

    // MARK: - triggers

    func testCrashIsRescued() async {
        let (r, batch) = await finalize(
            .init(text: "", engine: "apple_live", finalizeMs: 40, crashed: true),
            batchText: "the words the user actually said")
        XCTAssertEqual(batch.calls, 1)
        XCTAssertEqual(r.text, "the words the user actually said")
        XCTAssertEqual(r.engine, "counting")
        XCTAssertTrue(r.rescued)
        XCTAssertTrue(r.crashed, "the streaming engine still failed and the row must say so")
    }

    /// The 25 production timeouts, all `chars=0`. Under the old policy every one
    /// of them returned empty with the audio unread.
    func testTimeoutWithNoTextIsRescued() async {
        let (r, batch) = await finalize(
            .init(text: "", engine: "apple_live", finalizeMs: 1500, timedOut: true, peakLevel: 0.4),
            batchText: "recovered from the retained audio")
        XCTAssertEqual(batch.calls, 1)
        XCTAssertEqual(r.text, "recovered from the retained audio")
        XCTAssertTrue(r.rescued)
        XCTAssertTrue(r.timedOut, "metrics must still count the streaming timeout")
        XCTAssertEqual(r.peakLevel, 0.4, "the streaming session's acoustics survive the rescue")
    }

    func testProducedNothingIsRescued() async {
        let (r, batch) = await finalize(
            .init(text: "", engine: "apple_live", finalizeMs: 90,
                  peakLevel: 0.5, producedNothing: true),
            batchText: "audible speech in, words out")
        XCTAssertEqual(batch.calls, 1)
        XCTAssertEqual(r.text, "audible speech in, words out")
        XCTAssertTrue(r.rescued)
        XCTAssertTrue(r.producedNothing)
    }

    /// A clean finish the engine did not label itself: empty text over audio
    /// that was loud enough to be speech is the same defect by another route.
    func testCleanEmptyResultOverVoicedAudioIsRescued() async {
        let (r, batch) = await finalize(
            .init(text: "", engine: "apple_live", finalizeMs: 70, peakLevel: 0.3),
            batchText: "it was speech after all")
        XCTAssertEqual(batch.calls, 1)
        XCTAssertEqual(r.text, "it was speech after all")
        XCTAssertTrue(r.rescued)
    }

    // MARK: - the line that must not move

    func testSilenceIsNeverRescued() async {
        let (r, batch) = await finalize(
            .init(text: "", engine: "apple_live", finalizeMs: 45, peakLevel: 0.0),
            batchText: "Thank you.")
        XCTAssertEqual(batch.calls, 0, "a silent push-to-talk must not even run the batch engine")
        XCTAssertEqual(r.text, "")
        XCTAssertFalse(r.rescued)
    }

    /// Room tone, not speech: still below `voicedPeakThreshold`, still exempt.
    func testNearSilenceBelowTheVoicedThresholdIsNeverRescued() async {
        let quiet = SpeechAnalyzerEngine.voicedPeakThreshold - 0.001
        let (r, batch) = await finalize(
            .init(text: "", engine: "apple_live", finalizeMs: 45, peakLevel: quiet),
            batchText: "so.")
        XCTAssertEqual(batch.calls, 0)
        XCTAssertEqual(r.text, "")
    }

    func testASuccessfulUtteranceIsUntouched() async {
        let (r, batch) = await finalize(
            .init(text: "hello there", engine: "apple_live", finalizeMs: 80, peakLevel: 0.6),
            batchText: "should never be consulted")
        XCTAssertEqual(batch.calls, 0)
        XCTAssertEqual(r.text, "hello there")
        XCTAssertEqual(r.engine, "apple_live")
        XCTAssertFalse(r.rescued)
    }

    // MARK: - timeout with partial text: whichever read more of the utterance

    func testTimeoutWithPartialPrefersTheLongerBatchReading() async {
        let (r, batch) = await finalize(
            .init(text: "the deadline cut this", engine: "apple_live",
                  finalizeMs: 1500, timedOut: true, peakLevel: 0.5),
            batchText: "the deadline cut this sentence off halfway through")
        XCTAssertEqual(batch.calls, 1)
        XCTAssertEqual(r.text, "the deadline cut this sentence off halfway through",
                       "a timeout's partial is a truncation, not a result")
        XCTAssertTrue(r.rescued)
        XCTAssertEqual(r.engine, "counting")
    }

    func testTimeoutWithPartialKeepsStreamingWhenTheBatchReadLess() async {
        let (r, batch) = await finalize(
            .init(text: "a full sentence that finished in time", engine: "apple_live",
                  finalizeMs: 1500, timedOut: true, peakLevel: 0.5),
            batchText: "a full sentence")
        XCTAssertEqual(batch.calls, 1, "the batch pass still runs — only its text loses")
        XCTAssertEqual(r.text, "a full sentence that finished in time")
        XCTAssertEqual(r.engine, "apple_live")
        XCTAssertFalse(r.rescued, "the rescue may add words, never lose them")
    }

    /// Equal word counts are a tie, and a tie goes to the text the user has
    /// already watched appear in the field.
    func testEqualWordCountsKeepTheStreamingText() async {
        let (r, _) = await finalize(
            .init(text: "hello there world", engine: "apple_live",
                  finalizeMs: 1500, timedOut: true, peakLevel: 0.5),
            batchText: "Hello, there world!")
        XCTAssertEqual(r.text, "hello there world")
    }

    func testAFailedBatchPassLeavesTheStreamingResultExactlyAsItWas() async {
        let streaming = UtteranceResult(text: "as far as it got", engine: "apple_live",
                                        finalizeMs: 1500, timedOut: true, peakLevel: 0.5)
        let (r, batch) = await finalize(streaming, batchText: nil)
        XCTAssertEqual(batch.calls, 1)
        XCTAssertEqual(r, streaming, "nil from the batch engine changes nothing at all")
    }

    /// The hallucination filter still sits between the two: a batch pass that
    /// returns a stock caption phrase counts as having returned nothing.
    func testHallucinatedBatchTextCannotWinTheComparison() async {
        let (r, _) = await finalize(
            .init(text: "", engine: "apple_live", finalizeMs: 1500, timedOut: true, peakLevel: 0.5),
            batchText: "Thanks for watching!")
        XCTAssertEqual(r.text, "", "a hallucination must never be inserted, rescue or not")
        XCTAssertFalse(r.rescued)
    }

    // MARK: - the comparison itself

    func testWordCountIgnoresCaseAndPunctuation() {
        XCTAssertEqual(AsrManager.wordCount("Hello, world!"), 2)
        XCTAssertEqual(AsrManager.wordCount("hello world"), 2)
        XCTAssertEqual(AsrManager.wordCount("  "), 0)
        XCTAssertEqual(AsrManager.wordCount("one-two three"), 3, "a hyphen splits, in both engines equally")
        XCTAssertEqual(AsrManager.wordCount("It's fine."), 3, "an apostrophe splits too — only the count matters")
    }

    func testNeedsRescueIsPurePolicy() {
        let silent = UtteranceResult(text: "", engine: "apple_live", finalizeMs: 40)
        XCTAssertFalse(AsrManager.needsRescue(silent))
        XCTAssertTrue(AsrManager.needsRescue(
            UtteranceResult(text: "", engine: "apple_live", finalizeMs: 40, timedOut: true)))
        XCTAssertTrue(AsrManager.needsRescue(
            UtteranceResult(text: "partial", engine: "apple_live", finalizeMs: 40, timedOut: true)))
        XCTAssertFalse(AsrManager.needsRescue(
            UtteranceResult(text: "all good", engine: "apple_live", finalizeMs: 40, peakLevel: 0.9)))
    }
}

/// The rescue budget is generous by design, and the shape of that generosity is
/// worth pinning: it is a ceiling for a wedged analyzer, not a latency target.
final class AppleBatchBudgetTests: XCTestCase {

    private func bytes(seconds: Double) -> Int {
        Int(seconds * PcmFormat.sampleRate) * PcmFormat.bytesPerFrame
    }

    func testShortUtterancesGetTheFloor() {
        XCTAssertEqual(AppleBatchTranscriber.budgetSeconds(forAudioBytes: bytes(seconds: 0.5)),
                       AppleBatchTranscriber.minimumBudgetSeconds, accuracy: 1e-9)
        XCTAssertEqual(AppleBatchTranscriber.budgetSeconds(forAudioBytes: 0),
                       AppleBatchTranscriber.minimumBudgetSeconds, accuracy: 1e-9)
    }

    func testLongUtterancesScaleWithTheAudio() {
        // 10 s of audio → 15 s, comfortably past the ~35× realtime the eval
        // harness measures for unpaced feeding.
        XCTAssertEqual(AppleBatchTranscriber.budgetSeconds(forAudioBytes: bytes(seconds: 10)),
                       15.0, accuracy: 1e-6)
    }

    func testTheFloorWinsUntilTheAudioIsWorthMore() {
        let crossover = AppleBatchTranscriber.minimumBudgetSeconds
            / AppleBatchTranscriber.budgetRealtimeMultiple
        XCTAssertEqual(AppleBatchTranscriber.budgetSeconds(forAudioBytes: bytes(seconds: crossover)),
                       AppleBatchTranscriber.minimumBudgetSeconds, accuracy: 1e-6)
    }

    func testTheDefaultBatchEngineIsARealOneAndNotTheStub() async {
        // The regression that made this whole path a no-op: the manager shipped
        // with a batch engine that always returned nil.
        XCTAssertEqual(FilteredBatchTranscriber(AppleBatchTranscriber()).name, "apple_batch")
        XCTAssertNotEqual(AppleBatchTranscriber.engineName, WhisperKitBatchStub().name)
    }
}

/// The ownership protocol between the deadline-bounded caller and the unbounded
/// session task, which is what keeps a rescue's SETUP inside the budget.
///
/// A live probe stalled `prepareToAnalyze` for over five minutes with another
/// `SpeechAnalyzer` process active — and setup is exactly the phase a rescue
/// enters right after the speech stack failed and was hard-torn-down. Bounding
/// it means the session may still be running when the caller has left, so the
/// only question that matters is who tears the analyzer down. Tested against a
/// stand-in class: this is a race, not an ASR question.
final class BatchSessionHandoffTests: XCTestCase {

    private func idleCollector() -> Task<Void, Never> { Task {} }

    func testTheCallerOwnsWhatASessionRegisteredInTime() {
        let handoff = BatchSessionHandoff<NSObject>()
        let analyzer = NSObject()
        XCTAssertTrue(handoff.adopt(analyzer: analyzer, collector: idleCollector()))
        XCTAssertTrue(handoff.isLive)

        let orphan = handoff.abandon()
        XCTAssertIdentical(orphan.analyzer, analyzer, "the deadline takes what it must destroy")
        XCTAssertNotNil(orphan.collector)
        XCTAssertFalse(handoff.isLive)
        XCTAssertNil(handoff.take(), "and the session must not destroy it a second time")
    }

    func testASessionThatFinishesSetupAfterTheDeadlineOwnsWhatItBuilt() {
        let handoff = BatchSessionHandoff<NSObject>()
        let orphan = handoff.abandon()   // deadline fires while setup is still running
        XCTAssertNil(orphan.analyzer, "setup had not built one yet — nothing to destroy")

        XCTAssertFalse(handoff.adopt(analyzer: NSObject(), collector: idleCollector()),
                       "a late analyzer must not be silently handed to a caller that has gone")
    }

    func testTheSessionSideTakesOwnershipExactlyOnce() {
        let handoff = BatchSessionHandoff<NSObject>()
        let analyzer = NSObject()
        XCTAssertTrue(handoff.adopt(analyzer: analyzer, collector: idleCollector()))
        XCTAssertIdentical(handoff.take()?.analyzer, analyzer)
        XCTAssertNil(handoff.take(), "one owner, one teardown")
    }

    /// The whole point, end to end: a setup that takes far longer than the
    /// budget must not hold the caller, and must clean up after itself when it
    /// eventually wakes.
    func testASlowSetupNeitherBlocksTheCallerNorLeaksItsAnalyzer() async {
        let handoff = BatchSessionHandoff<NSObject>()
        let done = Signal()
        let selfCleaned = Signal()
        let budget = 0.2

        let session = Task.detached {
            // Stands in for `prepareToAnalyze` refusing to return.
            try? await Task.sleep(nanoseconds: 600_000_000)
            if !handoff.adopt(analyzer: NSObject(), collector: Task {}) {
                selfCleaned.fire()   // the session destroys what it built
            }
            done.fire()
        }

        let t0 = Date()
        let completed = await done.wait(timeout: budget, deadlineFrom: t0)
        let waited = Date().timeIntervalSince(t0)
        XCTAssertFalse(completed, "a wedged setup must lose the race, not win the wait")
        XCTAssertLessThan(waited, budget + 0.2, "the caller leaves at the budget")

        XCTAssertNil(handoff.abandon().analyzer)
        await session.value
        let cleaned = await selfCleaned.wait(timeout: 1.0, deadlineFrom: Date())
        XCTAssertTrue(cleaned, "the late session must destroy the analyzer nobody is waiting for")
    }
}

/// Everything `finalize` decides about an utterance AFTER the analyzer has had
/// its say: what counts as a dead session, and what of the volatile window is
/// worth salvaging. Pure predicates, so no speech model is involved.
final class FinalizeSalvageTests: XCTestCase {

    // MARK: - the tail salvage overlap test

    /// The measured data-loss bug: `text.contains(tail)` suppressed the append
    /// whenever the trailing volatile happened to be a word said earlier. On the
    /// timeout/crash path those are the only words left.
    func testARepeatedWordAsTheTailIsStillAppended() {
        let text = "and then the meeting moved"
        XCTAssertTrue(text.contains("and"), "precondition: the old containment test suppressed this")
        XCTAssertEqual(TranscriptText.appendingTail("and", to: text),
                       "and then the meeting moved and",
                       "‘and’ appearing earlier must not swallow a genuinely new ‘and’")
    }

    func testANameSaidTwiceIsNotSwallowed() {
        XCTAssertEqual(TranscriptText.appendingTail("Sharique", to: "tell Sharique that"),
                       "tell Sharique that Sharique")
    }

    /// The case the containment test got right, and which the suffix test must
    /// keep getting right: the volatile is the tail already written down.
    func testAnAlreadyWrittenTailIsNotDuplicated() {
        XCTAssertEqual(TranscriptText.appendingTail("halfway through",
                                                    to: "the sentence cut halfway through"),
                       "the sentence cut halfway through")
    }

    func testSuffixMatchingIgnoresPunctuationAndCase() {
        XCTAssertTrue(TranscriptText.isSuffix("halfway through", of: "It cut Halfway, through."))
        XCTAssertFalse(TranscriptText.isSuffix("through halfway", of: "it cut halfway through"),
                       "word ORDER still matters — a suffix is a suffix")
    }

    func testAnEmptyTailChangesNothing() {
        XCTAssertEqual(TranscriptText.appendingTail("   ", to: "some text"), "some text")
        XCTAssertEqual(TranscriptText.appendingTail("first words", to: ""), "first words")
    }

    // MARK: - what counts as a dead session

    func testLoudAudioWithNoFinalsIsADeadSession() {
        XCTAssertTrue(SpeechAnalyzerEngine.producedNothing(
            finals: [], lastPartial: "", starved: false, peakLevel: 0.5))
    }

    /// The quiet-microphone case: under the meter's threshold, but the analyzer
    /// itself emitted words — which is better evidence of speech than the meter.
    func testAVolatileIsSpeechEvidenceEvenBelowTheVoicedThreshold() {
        XCTAssertTrue(SpeechAnalyzerEngine.producedNothing(
            finals: [], lastPartial: "quietly spoken words",
            starved: false, peakLevel: 0.001),
            "a low-gain mic must not cost the user their utterance")
    }

    func testSilenceIsStillNotADeadSession() {
        XCTAssertFalse(SpeechAnalyzerEngine.producedNothing(
            finals: [], lastPartial: "", starved: false, peakLevel: 0.0),
            "digital silence yields no volatiles and peak 0 — neither witness fires")
    }

    func testStarvationIsTheCaptureSidesFaultNotTheEngines() {
        XCTAssertFalse(SpeechAnalyzerEngine.producedNothing(
            finals: [], lastPartial: "something", starved: true, peakLevel: 0.9))
    }

    func testAnyRealFinalMeansTheSessionWorked() {
        XCTAssertFalse(SpeechAnalyzerEngine.producedNothing(
            finals: ["it said something"], lastPartial: "", starved: false, peakLevel: 0.5))
        XCTAssertTrue(SpeechAnalyzerEngine.producedNothing(
            finals: ["   "], lastPartial: "", starved: false, peakLevel: 0.5),
            "a whitespace-only final is not a result")
    }

    /// The end-to-end consequence at the manager: a quiet speaker whose engine
    /// managed only a volatile gets the batch pass, not an empty field.
    func testTheQuietMicrophoneCaseReachesTheBatchEngine() async {
        let engine = FakeAsrEngine(script: .init(
            result: .init(text: "quietly spoken", engine: "apple_live", finalizeMs: 90,
                          peakLevel: 0.001, producedNothing: true)))
        let batch = CountingBatch(text: "quietly spoken words the meter never saw")
        let m = AsrManager(settings: AsrSettings(),
                           primaryFactory: { _ in engine },
                           batch: FilteredBatchTranscriber(batch))
        await m.begin { _ in }
        m.feed(pcm: Data(count: 32_000))
        let r = await m.finalize()
        XCTAssertEqual(batch.calls, 1)
        XCTAssertEqual(r.text, "quietly spoken words the meter never saw")
        XCTAssertTrue(r.rescued)
    }
}

/// The progress-aware finalize deadline needs a liveness signal, and this is it.
final class TranscriptSinkProgressTests: XCTestCase {

    func testEveryArrivalAdvancesTheCounter() async {
        let sink = TranscriptSink()
        let atStart = await sink.changes
        _ = await sink.setVolatile("hello")
        let afterVolatile = await sink.changes
        _ = await sink.appendFinal("hello there.")
        let afterFinal = await sink.changes
        XCTAssertEqual([atStart, afterVolatile, afterFinal], [0, 1, 2])
    }

    /// A repeated volatile is suppressed for the live field (it would spam it)
    /// but must still count as progress — an analyzer repeating itself is an
    /// analyzer that is running, and killing it would be the original defect.
    func testSuppressedDuplicatesStillCountAsProgress() async {
        let sink = TranscriptSink()
        let first = await sink.setVolatile("same")
        let repeated = await sink.setVolatile("same")
        let changes = await sink.changes
        XCTAssertEqual(first, "same")
        XCTAssertNil(repeated, "the field must not be spammed")
        XCTAssertEqual(changes, 2, "…but the finalize deadline must see it")
    }

    func testErrorsDoNotFabricateProgress() async {
        let sink = TranscriptSink()
        await sink.setError("boom")
        let changes = await sink.changes
        XCTAssertEqual(changes, 0)
    }
}

/// `finalize`'s deadline discipline, exercised through the pure wait function so
/// no speech model is needed.
final class FinalizeDeadlineTests: XCTestCase {

    /// An idle stall costs exactly one budget — the dead-microphone case must
    /// not get slower just because a working finalize may now run longer.
    func testAnIdleStallGivesUpAfterOneBudget() async {
        let sink = TranscriptSink()
        let t0 = Date()
        let completed = await SpeechAnalyzerEngine.waitForFinalize(
            Signal(), sink: sink, budget: 0.5, from: t0)
        let elapsed = Date().timeIntervalSince(t0)
        XCTAssertFalse(completed)
        XCTAssertLessThan(elapsed, 1.0, "no progress must not buy extra time")
        XCTAssertGreaterThanOrEqual(elapsed, 0.5)
    }

    /// The defect this replaces: results were arriving and the flat deadline
    /// killed the session anyway, discarding the tail (5/200 LibriSpeech clips).
    func testProgressExtendsTheDeadlineUpToTheHardCap() async {
        let sink = TranscriptSink()
        let done = Signal()
        let budget = 0.4
        // Keep producing for longer than one budget, then let finalize land.
        let producer = Task {
            for i in 0..<6 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                _ = await sink.setVolatile("word \(i)")
            }
            done.fire()
        }
        let t0 = Date()
        let completed = await SpeechAnalyzerEngine.waitForFinalize(
            done, sink: sink, budget: budget, from: t0)
        await producer.value
        XCTAssertTrue(completed, "an actively-transcribing finalize must not be killed at the budget")
        XCTAssertGreaterThan(Date().timeIntervalSince(t0), budget)
    }

    /// …but only up to the cap: an analyzer that emits forever cannot hold the
    /// user's key-release hostage.
    func testTheHardCapBoundsEvenAContinuouslyProducingAnalyzer() async {
        let sink = TranscriptSink()
        let budget = 0.3
        let producer = Task {
            for i in 0..<200 {
                try? await Task.sleep(nanoseconds: 20_000_000)
                _ = await sink.setVolatile("forever \(i)")
            }
        }
        let t0 = Date()
        let completed = await SpeechAnalyzerEngine.waitForFinalize(
            Signal(), sink: sink, budget: budget, from: t0)
        let elapsed = Date().timeIntervalSince(t0)
        producer.cancel()
        XCTAssertFalse(completed)
        XCTAssertGreaterThanOrEqual(elapsed, budget * SpeechAnalyzerEngine.progressBudgetMultiple)
        XCTAssertLessThan(elapsed, budget * SpeechAnalyzerEngine.progressBudgetMultiple
                              + SpeechAnalyzerEngine.progressSliceSeconds + 0.3,
                          "the cap is a cap, not a suggestion")
    }

    /// The common case: 40–110 ms finalizes must return as fast as they ever did.
    func testACompletedFinalizeReturnsImmediately() async {
        let sink = TranscriptSink()
        let done = Signal()
        done.fire()
        let t0 = Date()
        let completed = await SpeechAnalyzerEngine.waitForFinalize(
            done, sink: sink, budget: 1.5, from: t0)
        XCTAssertTrue(completed)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 0.1,
                          "the progress loop must not add latency to a healthy utterance")
    }
}
