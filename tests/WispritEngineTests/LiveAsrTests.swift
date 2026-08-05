import XCTest
import AVFoundation
@testable import WispritEngine

/// Tests that load the real on-device speech models. Skipped unless
/// `WISPRIT_LIVE_ASR=1`, because they need installed assets, a 16-core ANE
/// (false on the entire Simulator), and ~1 s of wall time each:
///
///   WISPRIT_LIVE_ASR=1 swift test --filter WispritEngineTests \
///       --scratch-path /tmp/wisprit-build-WispritEngine
///
/// Audio is synthesized with `say`, matching the spike-S1 probes. Carried
/// caveat: TTS audio validates plumbing and latency, not WER (spike S4).
final class LiveAsrTests: XCTestCase {

    private static let enabled = ProcessInfo.processInfo.environment["WISPRIT_LIVE_ASR"] == "1"

    override func setUpWithError() throws {
        try XCTSkipUnless(Self.enabled, "set WISPRIT_LIVE_ASR=1 to run live-model tests")
        #if !os(macOS)
        throw XCTSkip("`say` synthesis is macOS-only; iOS live tests run from the app target")
        #endif
    }

    // MARK: - helpers

    #if os(macOS)
    /// `say` writes 16 kHz mono Int16 WAV directly — the pipeline format.
    private func synthesize(_ text: String, rate: Int = 175) throws -> Data {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wisprit-live-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        p.arguments = ["-v", "Samantha", "-r", "\(rate)", "-o", url.path,
                       "--file-format=WAVE", "--data-format=LEI16@16000", text]
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw XCTSkip("`say` unavailable (status \(p.terminationStatus))")
        }
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(file.length)) else {
            throw XCTSkip("could not read synthesized audio")
        }
        try file.read(into: buffer)
        return PcmFormat.canonicalData(from: buffer)
    }

    /// Feed in 100 ms chunks, real-time paced when `realtime` — the push-to-talk shape.
    private func feed(_ pcm: Data, to sink: (Data) -> Void, realtime: Bool) async {
        let step = Int(PcmFormat.chunkFrames) * PcmFormat.bytesPerFrame
        let start = Date()
        var i = 0, n = 0
        while i < pcm.count {
            sink(pcm.subdata(in: i..<min(i + step, pcm.count)))
            i += step; n += 1
            if realtime {
                let due = start.addingTimeInterval(Double(n) * 0.1).timeIntervalSinceNow
                if due > 0 { try? await Task.sleep(nanoseconds: UInt64(due * 1e9)) }
            }
        }
    }
    #endif

    // MARK: - tests

    #if os(macOS)
    func testPreflightReportsReadyForAnInstalledLocale() async throws {
        let check = await AsrDoctor.check(locale: "en-US")
        XCTAssertTrue(check.transcriberAvailable)
        XCTAssertTrue(check.ok, check.detail)
        XCTAssertEqual(check.matchedLocale.map { $0.replacingOccurrences(of: "_", with: "-") }, "en-US")
        // Advisory only — measured `.supported` on a machine where ASR works.
        XCTAssertFalse(check.assetStatus.isEmpty)
    }

    func testPreflightFailsClearlyForAnUninstalledLocale() async throws {
        let check = await AsrDoctor.check(locale: "ja-JP")
        XCTAssertFalse(check.ok)
        XCTAssertNotNil(check.fix)
    }

    func testEndToEndUtteranceProducesTextAndLeadingPartials() async throws {
        let pcm = try synthesize("Hi Sharique, please add this to Wisprit and InsForge before the meeting.")
        let engine = SpeechAnalyzerEngine(settings: AsrSettings())
        let partials = PartialLog()
        let started = await engine.begin { partials.add($0) }
        XCTAssertTrue(started)

        let t0 = Date()
        await feed(pcm, to: { engine.feed(pcm: $0) }, realtime: true)
        let audioSeconds = Date().timeIntervalSince(t0)
        let result = await engine.finalize()

        XCTAssertFalse(result.timedOut, "release->final must fit the 1.5 s budget")
        XCTAssertFalse(result.crashed)
        XCTAssertFalse(result.text.isEmpty)
        XCTAssertLessThan(result.finalizeMs, 400, "spike S1: session-per-utterance measured 69–108 ms")

        // .fastResults: first partial ~1.0 s in, cadence ~0.95 s — partials must
        // LEAD the release, otherwise live streaming is impossible.
        XCTAssertGreaterThan(partials.count, 1)
        XCTAssertLessThan(partials.firstOffset ?? .infinity, min(2.0, audioSeconds),
                          "first partial must arrive well before end of audio")
        // The callback delivers finalizedPrefix + volatile, so text only grows.
        XCTAssertTrue(partials.isMonotonicPrefixGrowth, "partials: \(partials.all)")
    }

    func testBackToBackUtterancesDoNotLoseTheirHead() async throws {
        // The exact failure a resident analyzer produced (spike S1 Q1): the head
        // of every utterance after the first disappeared, short ones entirely.
        let a = try synthesize("Hi Sharique, please add this to Wisprit and InsForge before the meeting.")
        let b = try synthesize("Let's ship the native rewrite this week.")
        var texts: [String] = []
        for (i, pcm) in [a, b, a, b, a, b].enumerated() {
            let engine = SpeechAnalyzerEngine(settings: AsrSettings())
            let ok = await engine.begin { _ in }
            XCTAssertTrue(ok, "utterance \(i + 1) failed to start")
            await feed(pcm, to: { engine.feed(pcm: $0) }, realtime: false)
            let r = await engine.finalize()
            XCTAssertFalse(r.text.isEmpty, "utterance \(i + 1) came back empty")
            texts.append(r.text.lowercased())
            try? await Task.sleep(nanoseconds: 800_000_000)   // <4 s gap, no cooldown needed
        }
        for (i, t) in texts.enumerated() where i % 2 == 1 {
            XCTAssertTrue(t.contains("ship"), "short utterance \(i + 1) lost its content: \(t)")
        }
        for (i, t) in texts.enumerated() where i % 2 == 0 {
            XCTAssertTrue(t.contains("meeting"), "utterance \(i + 1) truncated: \(t)")
        }
    }

    func testCancelledUtteranceProducesNothingAndLeavesTheNextOneClean() async throws {
        let pcm = try synthesize("This utterance is thrown away.")
        let engine = SpeechAnalyzerEngine(settings: AsrSettings())
        let started = await engine.begin { _ in }
        XCTAssertTrue(started)
        await feed(pcm, to: { engine.feed(pcm: $0) }, realtime: false)
        await engine.cancel()
        let after = await engine.finalize()
        XCTAssertEqual(after.text, "")
        XCTAssertTrue(after.timedOut, "finalize with no live session reports timed out, as in asr.py")

        let next = SpeechAnalyzerEngine(settings: AsrSettings())
        let restarted = await next.begin { _ in }
        XCTAssertTrue(restarted)
        await feed(try synthesize("The quick brown fox jumps over the lazy dog."),
                   to: { next.feed(pcm: $0) }, realtime: false)
        let r = await next.finalize()
        XCTAssertTrue(r.text.lowercased().contains("quick brown fox"), r.text)
    }

    func testSilenceInsertsNothingAndNeverReachesTheBatchEngine() async throws {
        let batch = CountingBatch(text: "Thank you.")
        let manager = AsrManager(settings: AsrSettings(),
                                 batch: FilteredBatchTranscriber(batch))
        await manager.begin { _ in }
        await feed(Data(count: 32_000 * 2), to: { manager.feed(pcm: $0) }, realtime: false)  // 2 s of digital silence
        let r = await manager.finalize()
        XCTAssertEqual(r.text, "", "a silent push-to-talk must insert nothing")
        XCTAssertEqual(batch.calls, 0, "empty is not a crash — b0a763f")
    }

    func testVocabularyChannelRecoversALearnedNameOffPath() async throws {
        let pcm = try synthesize("Hi Sharique, please add this to Wisprit and InsForge before the meeting.")
        let vocab = StubVocabulary(terms: ["Sharique", "Wisprit", "InsForge", "Sharique Khatri", "Khatri"])

        let without = await VocabularyChannel(settings: AsrSettings(), vocabulary: nil).reconcile(pcm: pcm)
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        let with = await VocabularyChannel(settings: AsrSettings(), vocabulary: vocab).reconcile(pcm: pcm)

        let unbiased = try XCTUnwrap(without)
        let biased = try XCTUnwrap(with)
        XCTAssertFalse(unbiased.transcript.isEmpty, ".frequentFinalization must yield a real final")
        XCTAssertFalse(biased.transcript.isEmpty)
        XCTAssertEqual(biased.termCount, 5)
        // The whole point of the channel: the learned name is RECOGNIZED, not patched.
        XCTAssertEqual(biased.termHits["Sharique"], 1,
                       "biased: \(biased.transcript) | unbiased: \(unbiased.transcript)")
    }

    func testFullDictionaryOfContextualStringsStillRecoversTheName() async throws {
        // Spike S1 Q3: no dilution at n = 500, and setup cost is off the paste path.
        let padding = (0..<495).map { "Zeta\($0)" }
        let vocab = StubVocabulary(terms: ["Sharique", "Wisprit", "InsForge", "Sharique Khatri", "Khatri"] + padding)
        let pcm = try synthesize("Hi Sharique, please add this to Wisprit and InsForge before the meeting.")
        let reconciled = await VocabularyChannel(settings: AsrSettings(), vocabulary: vocab).reconcile(pcm: pcm)
        let out = try XCTUnwrap(reconciled)
        XCTAssertEqual(out.termCount, 500)
        XCTAssertEqual(out.termHits["Sharique"], 1, out.transcript)
    }
    #endif
}

/// Records partials with arrival offsets so the live test can assert they lead.
final class PartialLog: @unchecked Sendable {
    private let lock = UnfairLock()
    private var items: [(String, Date)] = []
    private let start = Date()

    func add(_ s: String) { lock.withLock { items.append((s, Date())) } }

    var all: [String] { lock.withLock { items.map(\.0) } }
    var count: Int { lock.withLock { items.count } }
    var firstOffset: Double? {
        lock.withLock { items.first.map { $0.1.timeIntervalSince(start) } }
    }
    /// The callback delivers finalizedPrefix + volatile, so each partial should
    /// keep or extend the previous one's word count — never shrink to a window.
    var isMonotonicPrefixGrowth: Bool {
        let words = all.map { $0.split(separator: " ").count }
        return zip(words, words.dropFirst()).allSatisfy { $1 + 2 >= $0 }
    }
}
