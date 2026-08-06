import XCTest
import AVFoundation
import Speech
@testable import WispritEngine

/// Headless reproduction harness for the production "utterances 3..N all come
/// back empty at the finalize timeout" failure (metrics ts 1785971800–1785971842).
///
/// It drives N consecutive live-shaped utterances through ONE `AsrManager` —
/// the production topology, where `SessionController` holds a single manager for
/// the app's lifetime — with fed PCM instead of a microphone. `MicCapture` is
/// deliberately bypassed: if the empties reproduce here, capture is exonerated.
///
/// Configurations (env `WISPRIT_MATRIX`):
///   a  — no reconcile between utterances (control)
///   b  — `reconcileVocabulary()` detached after every success (production shape)
///   c  — as (b), plus `SpeechModels.endRetention()` when the reconcile finishes
///   p  — poison-then-recover: one (b)-shaped pair, then the candidate recovery
///
/// Everything is env-gated so the normal suite never pays for it:
///
///   WISPRIT_LIVE_ASR=1 WISPRIT_MATRIX=b swift test \
///     --filter RapidSessionMatrixTests --scratch-path /tmp/wisprit-build-WispritEngine
final class RapidSessionMatrixTests: XCTestCase {

    private static let env = ProcessInfo.processInfo.environment
    private static let enabled = env["WISPRIT_LIVE_ASR"] == "1" && env["WISPRIT_MATRIX"] != nil
    private static var config: String { env["WISPRIT_MATRIX"] ?? "a" }
    private static var utterances: Int { Int(env["WISPRIT_MATRIX_N"] ?? "") ?? 8 }
    /// Release→next-press idle. Production metrics: 3.7–4.1 s between utterances.
    private static var gapSeconds: Double { Double(env["WISPRIT_MATRIX_GAP"] ?? "") ?? 4.0 }

    override func setUpWithError() throws {
        try XCTSkipUnless(Self.enabled,
                          "set WISPRIT_LIVE_ASR=1 and WISPRIT_MATRIX=a|b|c|p to run the matrix")
        #if !os(macOS)
        throw XCTSkip("`say` synthesis is macOS-only")
        #endif
    }

    #if os(macOS)

    // MARK: - audio

    private func synthesize(_ text: String) throws -> Data {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wisprit-matrix-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        p.arguments = ["-v", "Samantha", "-r", "175", "-o", url.path,
                       "--file-format=WAVE", "--data-format=LEI16@16000", text]
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw XCTSkip("`say` unavailable") }
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(file.length)) else {
            throw XCTSkip("could not read synthesized audio")
        }
        try file.read(into: buffer)
        return PcmFormat.canonicalData(from: buffer)
    }

    /// Real-time-paced 100 ms chunks — the push-to-talk shape MicCapture produces.
    private func feedRealtime(_ pcm: Data, to sink: (Data) -> Void) async {
        let step = Int(PcmFormat.chunkFrames) * PcmFormat.bytesPerFrame
        let start = Date()
        var i = 0, n = 0
        while i < pcm.count {
            sink(pcm.subdata(in: i..<min(i + step, pcm.count)))
            i += step; n += 1
            let due = start.addingTimeInterval(Double(n) * 0.1).timeIntervalSinceNow
            if due > 0 { try? await Task.sleep(nanoseconds: UInt64(due * 1e9)) }
        }
    }

    /// Production-sized vocabulary: ~/.wisprit/dictionary.json held 138 terms on
    /// the failing machine, and the whole dictionary ships (spike S1 Q3).
    private func productionVocabulary() -> StubVocabulary {
        let real = ["Sharique", "Wisprit", "InsForge", "Sharique Khatri", "Khatri",
                    "SwiftUI", "AVFoundation", "SpeechAnalyzer", "Xcode", "macOS"]
        let total = Int(Self.env["WISPRIT_MATRIX_TERMS"] ?? "") ?? 138
        return StubVocabulary(terms: real + (0..<max(0, total - real.count)).map { "Term\($0)" })
    }

    // MARK: - one utterance

    private struct Row {
        var index: Int
        var finalizeMs: Double
        var empty: Bool
        var timedOut: Bool
        var crashed: Bool
        var text: String
        var reconcilesInFlight: Int
        /// Volatile callbacks seen. 0 with audio fed == the engine produced nothing
        /// at all; >0 with an empty result == finals never landed but text existed.
        var partials: Int
    }

    private func runUtterance(_ i: Int, pcm: Data, manager: AsrManager,
                              inFlight: Counter) async -> Row {
        let overlapping = inFlight.value
        let partials = Counter()
        await manager.begin { _ in partials.increment() }
        await feedRealtime(pcm) { manager.feed(pcm: $0) }
        let r = await manager.finalize()
        let row = Row(index: i, finalizeMs: r.finalizeMs, empty: r.text.isEmpty,
                      timedOut: r.timedOut, crashed: r.crashed, text: r.text,
                      reconcilesInFlight: overlapping, partials: partials.value)
        print(String(format: "MATRIX utt %d | finalize %7.1f ms | %@ | timedOut=%@ crashed=%@ | inflight=%d partials=%2d | %@",
                     i, r.finalizeMs, r.text.isEmpty ? "EMPTY" : "ok   ",
                     r.timedOut ? "Y" : "n", r.crashed ? "Y" : "n",
                     overlapping, partials.value, String(r.text.prefix(60))))
        return row
    }

    // MARK: - (d) what a starved-input utterance looks like

    /// The production metrics row was `outcome=empty, finalize_ms≈1500,
    /// timed_out=false`. Two very different faults can produce it: a wedged
    /// analyzer, or an analyzer that simply never received audio. This prints the
    /// signature of the second so the two can be told apart.
    func testStarvedInputSignature() async throws {
        try XCTSkipUnless(Self.config == "d", "WISPRIT_MATRIX=d")
        let speech = try synthesize("The quick brown fox jumps over the lazy dog.")
        let cases: [(String, Data)] = [
            ("no audio at all   ", Data()),
            ("3 s digital silence", Data(count: 16_000 * 2 * 3)),
            ("normal speech     ", speech),
        ]
        for (label, pcm) in cases {
            let partials = Counter()
            let engine = SpeechAnalyzerEngine(settings: AsrSettings())
            let ok = await engine.begin { _ in partials.increment() }
            if !pcm.isEmpty { await feedRealtime(pcm) { engine.feed(pcm: $0) } }
            let r = await engine.finalize()
            print(String(format: "MATRIX starved | %@ | began=%@ finalize %7.1f ms | %@ | timedOut=%@ crashed=%@ starved=%@ partials=%d",
                         label, ok ? "Y" : "N", r.finalizeMs,
                         r.text.isEmpty ? "EMPTY" : "ok", r.timedOut ? "Y" : "n",
                         r.crashed ? "Y" : "n", r.starvedInput ? "Y" : "n", partials.value))
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    // MARK: - (p) one bad utterance must never strand the user

    /// Injects the production failure (a starved session) into the middle of a
    /// production-shaped run and asserts the run keeps working afterwards.
    func testStarvedUtteranceDoesNotStrandTheFollowingOnes() async throws {
        try XCTSkipUnless(Self.config == "p", "WISPRIT_MATRIX=p")
        let clips = [
            try synthesize("Hi Sharique, please add this to Wisprit and InsForge before the meeting."),
            try synthesize("Let's ship the native rewrite this week."),
            try synthesize("The quick brown fox jumps over the lazy dog."),
        ]
        let manager = AsrManager(settings: AsrSettings(), vocabulary: productionVocabulary())
        let inFlight = Counter()
        var empties = 0

        for i in 1...8 {
            // Utterances 3 and 4 get NO audio at all — exactly what the wedged
            // microphone did in production.
            let starve = (i == 3 || i == 4)
            let partials = Counter()
            await manager.begin { _ in partials.increment() }
            if !starve { await feedRealtime(clips[(i - 1) % clips.count]) { manager.feed(pcm: $0) } }
            let r = await manager.finalize()
            let bad = r.text.isEmpty && !starve
            if bad { empties += 1 }
            print(String(format: "MATRIX recover utt %d | %@ | finalize %7.1f ms | %@ | starved=%@ | %@",
                         i, starve ? "STARVED " : "fed     ", r.finalizeMs,
                         r.text.isEmpty ? "EMPTY" : "ok   ", r.starvedInput ? "Y" : "n",
                         String(r.text.prefix(50))))
            XCTAssertEqual(r.starvedInput, starve, "utt \(i): starvation must be reported, and only when real")
            if !starve {
                XCTAssertFalse(r.text.isEmpty, "utt \(i) was stranded by the injected failure")
            }
            if Self.config != "a" && !r.text.isEmpty {
                inFlight.increment()
                Task.detached(priority: .utility) {
                    _ = await manager.reconcileVocabulary()
                    inFlight.decrement()
                }
            }
            try? await Task.sleep(nanoseconds: UInt64(Self.gapSeconds * 1e9))
        }
        XCTAssertEqual(empties, 0)
    }

    // MARK: - the matrix

    func testRapidSessionMatrix() async throws {
        try XCTSkipUnless(!["d", "p"].contains(Self.config), "configs d and p run their own tests")
        let clips = [
            try synthesize("Hi Sharique, please add this to Wisprit and InsForge before the meeting."),
            try synthesize("Let's ship the native rewrite this week."),
            try synthesize("The quick brown fox jumps over the lazy dog."),
        ]
        let config = Self.config
        let n = Self.utterances
        let vocabulary = productionVocabulary()
        let manager = AsrManager(settings: AsrSettings(), vocabulary: vocabulary)
        let inFlight = Counter()
        var rows: [Row] = []

        print("MATRIX config=\(config) n=\(n) gap=\(Self.gapSeconds)s terms=\(vocabulary.terms.count)")

        for i in 1...n {
            let row = await runUtterance(i, pcm: clips[(i - 1) % clips.count],
                                         manager: manager, inFlight: inFlight)
            rows.append(row)

            if config != "a" && !row.empty {
                // Production shape: SessionController.completeCorrection fires this
                // detached and does NOT await it, so it can still be running when
                // the next utterance starts.
                inFlight.increment()
                Task.detached(priority: .utility) {
                    let r = await manager.reconcileVocabulary()
                    print(String(format: "MATRIX   reconcile after utt %d took %.0f ms -> %@",
                                 row.index, r?.elapsedMs ?? -1, String((r?.transcript ?? "nil").prefix(50))))
                    if config == "c" { await SpeechModels.endRetention() }
                    inFlight.decrement()
                }
            }
            if i < n { try? await Task.sleep(nanoseconds: UInt64(Self.gapSeconds * 1e9)) }
        }

        let empties = rows.filter(\.empty).count
        print("MATRIX RESULT config=\(config) empties=\(empties)/\(n) " +
              "finalizeMs=[\(rows.map { String(format: "%.0f", $0.finalizeMs) }.joined(separator: ", "))]")

        // Only the fixed production shape is asserted; a/b are measurement runs.
        if config == "c" || ProcessInfo.processInfo.environment["WISPRIT_MATRIX_ASSERT"] == "1" {
            XCTAssertEqual(empties, 0, "every utterance must produce text")
        }
    }
    #endif
}

/// Tiny thread-safe counter for "is a reconcile still running?".
final class Counter: @unchecked Sendable {
    private let lock = UnfairLock()
    private var n = 0
    var value: Int { lock.withLock { n } }
    func increment() { lock.withLock { n += 1 } }
    func decrement() { lock.withLock { n -= 1 } }
}
