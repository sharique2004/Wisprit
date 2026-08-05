import XCTest
import WispritKit
@testable import WispritEngine

/// Protocol-level engine with the same queueing discipline as the real one, so
/// the manager's fallback semantics can be tested without a speech model.
final class FakeAsrEngine: AsrEngine, @unchecked Sendable {
    struct Script: Sendable {
        var beginSucceeds = true
        var partials: [String] = []
        var result: UtteranceResult = .init(text: "", engine: "fake", finalizeMs: 0)
        var finalizeDelay: Double = 0
    }

    private let script: Script
    private let queue: PcmChunkQueue
    private let lock = UnfairLock()
    private var fedChunks: [Data] = []
    private(set) var beginCount = 0
    private(set) var cancelCount = 0
    private(set) var finalizeCount = 0

    init(script: Script, capacity: Int = PcmChunkQueue.defaultCapacity) {
        self.script = script
        self.queue = PcmChunkQueue(capacity: capacity)
    }

    var droppedChunks: Int { queue.droppedChunks }
    var queuedChunks: Int { queue.count }

    func begin(onPartial: @escaping @Sendable (String) -> Void) async -> Bool {
        beginCount += 1
        guard script.beginSucceeds else { return false }
        for p in script.partials { onPartial(p) }
        return true
    }

    func feed(pcm: Data) {
        queue.enqueue(pcm)
        lock.lock(); fedChunks.append(pcm); lock.unlock()
    }

    func finalize() async -> UtteranceResult {
        finalizeCount += 1
        if script.finalizeDelay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(script.finalizeDelay * 1e9))
        }
        queue.close()
        return script.result
    }

    func cancel() async {
        cancelCount += 1
        queue.discardAll()
    }
}

final class AsrEngineProtocolTests: XCTestCase {

    func testFeedIsNonBlockingAndDropsOldest() async {
        let engine = FakeAsrEngine(script: .init(), capacity: 4)
        let start = Date()
        for i in 0..<5_000 { engine.feed(pcm: Data([UInt8(i % 251)])) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0, "feed must never block the audio callback")
        XCTAssertEqual(engine.queuedChunks, 4)
        XCTAssertEqual(engine.droppedChunks, 4_996)
    }

    func testPartialsReachTheCallback() async {
        let engine = FakeAsrEngine(script: .init(partials: ["Hi", "Hi there"]))
        let box = Collected()
        _ = await engine.begin { box.addSync($0) }
        try? await Task.sleep(nanoseconds: 30_000_000)
        let seen = await box.all()
        XCTAssertEqual(seen, ["Hi", "Hi there"])
    }

    func testFinalizeTextConvenienceMirrorsResultText() async {
        let engine = FakeAsrEngine(script: .init(
            result: .init(text: "hello world", engine: "fake", finalizeMs: 12)))
        let text = await engine.finalizeText()
        XCTAssertEqual(text, "hello world")
    }

    func testCancelDropsQueuedAudio() async {
        let engine = FakeAsrEngine(script: .init())
        for _ in 0..<10 { engine.feed(pcm: Data([1])) }
        await engine.cancel()
        XCTAssertEqual(engine.cancelCount, 1)
        XCTAssertEqual(engine.queuedChunks, 0)
    }
}

final class AsrManagerFallbackTests: XCTestCase {

    private func manager(engine: FakeAsrEngine,
                         batchText: String?,
                         settings: AsrSettings = AsrSettings()) -> (AsrManager, CountingBatch) {
        let batch = CountingBatch(text: batchText)
        let m = AsrManager(settings: settings,
                           primaryFactory: { _ in engine },
                           batch: FilteredBatchTranscriber(batch))
        return (m, batch)
    }

    private func pcm(_ seconds: Double) -> Data {
        Data(count: Int(seconds * PcmFormat.sampleRate) * 2)
    }

    // The b0a763f rule, in both directions.

    func testEmptyCleanResultNeverTriggersBatch() async {
        let engine = FakeAsrEngine(script: .init(
            result: .init(text: "", engine: "apple_live", finalizeMs: 40)))
        let (m, batch) = manager(engine: engine, batchText: "Thank you.")
        await m.begin { _ in }
        m.feed(pcm: pcm(1))
        let r = await m.finalize()
        XCTAssertEqual(r.text, "", "a silent push-to-talk must insert nothing")
        XCTAssertEqual(batch.calls, 0, "batch must never run on a merely empty result")
    }

    func testCrashWithNoTextTriggersBatch() async {
        let engine = FakeAsrEngine(script: .init(
            result: .init(text: "", engine: "apple_live", finalizeMs: 40, crashed: true)))
        let (m, batch) = manager(engine: engine, batchText: "recovered text")
        await m.begin { _ in }
        m.feed(pcm: pcm(1))
        let r = await m.finalize()
        XCTAssertEqual(r.text, "recovered text")
        XCTAssertEqual(r.engine, "counting")
        XCTAssertEqual(batch.calls, 1)
    }

    func testCrashWithTextKeepsTheStreamingResult() async {
        let engine = FakeAsrEngine(script: .init(
            result: .init(text: "partial words", engine: "apple_live", finalizeMs: 40, crashed: true)))
        let (m, batch) = manager(engine: engine, batchText: "should not be used")
        await m.begin { _ in }
        m.feed(pcm: pcm(1))
        let r = await m.finalize()
        XCTAssertEqual(r.text, "partial words")
        XCTAssertEqual(batch.calls, 0)
    }

    func testTimeoutReturnsPartialsAndDoesNotTriggerBatch() async {
        let engine = FakeAsrEngine(script: .init(
            result: .init(text: "as far as it got", engine: "apple_live",
                          finalizeMs: 1500, timedOut: true)))
        let (m, batch) = manager(engine: engine, batchText: "should not be used")
        await m.begin { _ in }
        m.feed(pcm: pcm(1))
        let r = await m.finalize()
        XCTAssertTrue(r.timedOut)
        XCTAssertEqual(r.text, "as far as it got")
        XCTAssertEqual(batch.calls, 0)
    }

    func testCrashRecoveryStillDropsHallucinations() async {
        let engine = FakeAsrEngine(script: .init(
            result: .init(text: "", engine: "apple_live", finalizeMs: 40, crashed: true)))
        let (m, batch) = manager(engine: engine, batchText: "Thank you.")
        await m.begin { _ in }
        m.feed(pcm: pcm(1))
        let r = await m.finalize()
        XCTAssertEqual(batch.calls, 1)
        XCTAssertEqual(r.text, "", "the batch engine's silence-hallucination must not be inserted")
        XCTAssertTrue(r.crashed)
    }

    func testBatchOnlyEngineOverrideSkipsTheStreamingPrimary() async {
        for kind in [AsrEngineKind.mlxWhisper, .fasterWhisper] {
            let engine = FakeAsrEngine(script: .init())
            let (m, batch) = manager(engine: engine, batchText: "batch said this",
                                     settings: AsrSettings(engine: kind))
            await m.begin { _ in }
            m.feed(pcm: pcm(1))
            let r = await m.finalize()
            XCTAssertEqual(engine.beginCount, 0, "\(kind) must not start the streaming engine")
            XCTAssertEqual(batch.calls, 1)
            XCTAssertEqual(r.text, "batch said this")
        }
    }

    func testBatchOnlyWithNoBatchEngineYieldsEmptyTimedOut() async {
        let m = AsrManager(settings: AsrSettings(engine: .mlxWhisper),
                           primaryFactory: { _ in FakeAsrEngine(script: .init()) },
                           batch: FilteredBatchTranscriber(CountingBatch(text: nil)))
        await m.begin { _ in }
        m.feed(pcm: pcm(1))
        let r = await m.finalize()
        XCTAssertEqual(r.text, "")
        XCTAssertEqual(r.engine, "none")
        XCTAssertTrue(r.timedOut)
    }

    func testPrimaryThatFailsToStartFallsThroughToBatch() async {
        let engine = FakeAsrEngine(script: .init(beginSucceeds: false))
        let (m, batch) = manager(engine: engine, batchText: "batch rescued it")
        await m.begin { _ in }
        m.feed(pcm: pcm(1))
        let r = await m.finalize()
        XCTAssertEqual(engine.finalizeCount, 0)
        XCTAssertEqual(batch.calls, 1)
        XCTAssertEqual(r.text, "batch rescued it")
    }

    func testRetentionIsIndependentOfTheEngineAndResetPerUtterance() async {
        let engine = FakeAsrEngine(script: .init(beginSucceeds: false))
        let (m, _) = manager(engine: engine, batchText: nil)
        await m.begin { _ in }
        m.feed(pcm: pcm(0.5))
        m.feed(pcm: pcm(0.5))
        XCTAssertEqual(m.retainedPcm.count, 32_000)
        XCTAssertEqual(m.retainedSeconds, 1.0, accuracy: 1e-9)
        await m.begin { _ in }
        XCTAssertEqual(m.retainedPcm.count, 0, "begin() starts a fresh utterance")
    }

    func testCancelClearsRetentionAndEngine() async {
        let engine = FakeAsrEngine(script: .init())
        let (m, _) = manager(engine: engine, batchText: nil)
        await m.begin { _ in }
        m.feed(pcm: pcm(1))
        await m.cancel()
        XCTAssertEqual(engine.cancelCount, 1)
        XCTAssertTrue(m.retainedPcm.isEmpty)
    }

    func testEmptyRetentionNeverReachesTheBatchEngine() async {
        let engine = FakeAsrEngine(script: .init(
            result: .init(text: "", engine: "apple_live", finalizeMs: 5, crashed: true)))
        let (m, batch) = manager(engine: engine, batchText: "unused")
        await m.begin { _ in }
        let r = await m.finalize()   // no feed at all
        XCTAssertEqual(batch.calls, 0)
        XCTAssertTrue(r.crashed)
    }
}

final class AsrEngineKindTests: XCTestCase {
    func testMatchesThePythonSettingsVocabulary() {
        XCTAssertEqual(AsrEngineKind(settingsValue: "auto"), .auto)
        XCTAssertEqual(AsrEngineKind(settingsValue: "apple_live"), .appleLive)
        XCTAssertEqual(AsrEngineKind(settingsValue: "mlx_whisper"), .mlxWhisper)
        XCTAssertEqual(AsrEngineKind(settingsValue: "faster_whisper"), .fasterWhisper)
        XCTAssertEqual(AsrEngineKind(settingsValue: nil), .auto)
        XCTAssertEqual(AsrEngineKind(settingsValue: "nonsense"), .auto)
    }

    func testStreamingPrimarySelection() {
        XCTAssertTrue(AsrEngineKind.auto.usesStreamingPrimary)
        XCTAssertTrue(AsrEngineKind.appleLive.usesStreamingPrimary)
        XCTAssertFalse(AsrEngineKind.mlxWhisper.usesStreamingPrimary)
        XCTAssertFalse(AsrEngineKind.fasterWhisper.usesStreamingPrimary)
    }

    func testFinalizeTimeoutDefaultsMatchSettingsPy() {
        XCTAssertEqual(AsrSettings().finalizeTimeoutMs, 1500)
        XCTAssertEqual(AsrSettings().locale, "en-US")
        XCTAssertEqual(AsrSettings().finalizeTimeoutSeconds, 1.5, accuracy: 1e-9)
        // Python: a non-positive / missing value falls back to 1.5 s.
        XCTAssertEqual(AsrSettings(finalizeTimeoutMs: 0).finalizeTimeoutSeconds, 1.5, accuracy: 1e-9)
        XCTAssertEqual(AsrSettings(finalizeTimeoutMs: -5).finalizeTimeoutSeconds, 1.5, accuracy: 1e-9)
        XCTAssertEqual(AsrSettings(finalizeTimeoutMs: 800).finalizeTimeoutSeconds, 0.8, accuracy: 1e-9)
    }
}

/// Volatile results are windowed, not cumulative (spike S1 Q2) — the sink is
/// what turns them back into "everything said so far".
final class TranscriptSinkTests: XCTestCase {

    func testVolatileIsPrefixedWithFinalizedText() async {
        let sink = TranscriptSink()
        var emitted: [String?] = []
        emitted.append(await sink.setVolatile("hello"))
        emitted.append(await sink.appendFinal("hello there."))
        // After a final the analyzer restarts the volatile window.
        emitted.append(await sink.setVolatile("how are"))
        emitted.append(await sink.setVolatile("how are you"))
        emitted.append(await sink.appendFinal(" How are you?"))
        XCTAssertEqual(emitted, ["hello", "hello there.", "hello there. how are",
                                 "hello there. how are you", "hello there. How are you?"])
    }

    func testDuplicateEmissionsAreSuppressed() async {
        let sink = TranscriptSink()
        let first = await sink.setVolatile("same")
        let repeated = await sink.setVolatile("same")
        let padded = await sink.setVolatile(" same ")
        XCTAssertEqual(first, "same")
        XCTAssertNil(repeated, "bursts of identical partials must not spam the field")
        XCTAssertNil(padded)
    }

    func testSnapshotCarriesFinalsAndLastPartial() async {
        let sink = TranscriptSink()
        _ = await sink.appendFinal("one.")
        _ = await sink.setVolatile("two")
        let (finals, partial, err) = await sink.snapshot()
        XCTAssertEqual(finals, ["one."])
        XCTAssertEqual(partial, "two")
        XCTAssertNil(err)
    }

    func testErrorIsStickyToTheFirstOne() async {
        let sink = TranscriptSink()
        await sink.setError("first")
        await sink.setError("second")
        let error = await sink.snapshot().2
        XCTAssertEqual(error, "first")
    }
}

final class LocaleMatchingTests: XCTestCase {
    func testHyphenAndUnderscoreLocalesAreTheSame() {
        XCTAssertTrue(AsrDoctor.matches("en_US", "en-US"))
        XCTAssertTrue(AsrDoctor.matches("en-US", "en_us"))
        XCTAssertFalse(AsrDoctor.matches("en_GB", "en-US"))
    }
}

final class VocabularyChannelTests: XCTestCase {

    func testTermLimitDefaultsToTheWholeDictionary() {
        let vocab = StubVocabulary(terms: (0..<500).map { "Term\($0)" })
        let all = VocabularyChannel(settings: AsrSettings(), vocabulary: vocab).contextualTerms()
        XCTAssertEqual(all.count, 500, "spike S1 Q3: no 50-term cap — the cost is off the paste path")
    }

    func testTermLimitIsHonouredWhenSetExplicitly() {
        let vocab = StubVocabulary(terms: (0..<500).map { "Term\($0)" })
        let capped = VocabularyChannel(settings: AsrSettings(contextualTermLimit: 50),
                                       vocabulary: vocab).contextualTerms()
        XCTAssertEqual(capped.count, 50)
        XCTAssertEqual(capped.first, "Term0", "most-recently-useful first, per VocabularySource")
    }

    func testNoVocabularySourceYieldsNoTerms() {
        XCTAssertTrue(VocabularyChannel(settings: AsrSettings(), vocabulary: nil).contextualTerms().isEmpty)
    }

    func testTermHitsAreWholeWordAndCaseInsensitive() {
        let hits = VocabularyChannel.termHits(
            in: "Hi Sharique, add this to wisprit. Sharique said so. Unsharique.",
            terms: ["Sharique", "Wisprit", "InsForge"])
        XCTAssertEqual(hits["Sharique"], 2, "'Unsharique' must not count")
        XCTAssertEqual(hits["Wisprit"], 1)
        XCTAssertNil(hits["InsForge"])
    }

    func testMultiWordTermsMatchWithRelaxedWhitespace() {
        let hits = VocabularyChannel.termHits(in: "call Sharique   Khatri now", terms: ["Sharique Khatri"])
        XCTAssertEqual(hits["Sharique Khatri"], 1)
    }

    func testEmptyTranscriptYieldsNoHits() {
        XCTAssertTrue(VocabularyChannel.termHits(in: "", terms: ["Sharique"]).isEmpty)
    }
}

// MARK: - test doubles

final class CountingBatch: BatchTranscribing, @unchecked Sendable {
    let name = "counting"
    let text: String?
    private let lock = UnfairLock()
    private var count = 0
    var calls: Int { lock.withLock { count } }

    init(text: String?) { self.text = text }

    func transcribe(pcm: Data, settings: AsrSettings) async -> String? {
        lock.withLock { count += 1 }
        return text
    }
}

struct StubVocabulary: VocabularySource {
    let terms: [String]
    func vocabularyTerms() -> [String] { terms }
    func isKnownTerm(_ word: String) -> Bool {
        terms.contains { $0.caseInsensitiveCompare(word) == .orderedSame }
    }
}

actor Collected {
    private var items: [String] = []
    nonisolated func addSync(_ s: String) { Task { await self.add(s) } }
    func add(_ s: String) { items.append(s) }
    func all() -> [String] { items }
}
