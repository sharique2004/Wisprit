import AVFoundation
import XCTest
@testable import WispritParakeet

/// End-to-end against the REAL models: gated on `WISPRIT_PARAKEET_LIVE=1` and
/// on the spike's already-downloaded caches being present on this machine
/// (docs/research/spikes-parakeet.md, "Re-running") — skips cleanly otherwise,
/// so CI and ordinary runs never load a model or touch the network.
///
/// The caches are used READ-ONLY through symlinks staged into a temp models
/// dir shaped exactly like `~/.wisprit/models/parakeet`, which also makes this
/// the one place the real manifest hashes meet real bytes: `state()` must
/// answer `.verified` against the very files the B-0 measurements ran on.
final class ParakeetLiveTests: XCTestCase {

    private static let tdtCache = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("MeetingScribe/native/asr-ab/models/parakeet-tdt-0.6b-v3")
    private static let ctcCache = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("FluidAudio/Models/parakeet-ctc-110m-coreml")

    private func stagedModelsDir() throws -> URL {
        guard ProcessInfo.processInfo.environment["WISPRIT_PARAKEET_LIVE"] == "1" else {
            throw XCTSkip("set WISPRIT_PARAKEET_LIVE=1 to run the live Parakeet test")
        }
        let fm = FileManager.default
        guard fm.fileExists(atPath: Self.tdtCache.path),
              fm.fileExists(atPath: Self.ctcCache.path) else {
            throw XCTSkip("spike model caches not present on this machine")
        }
        let dir = fm.temporaryDirectory
            .appendingPathComponent("parakeet-live-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? fm.removeItem(at: dir) }
        try fm.createSymbolicLink(
            at: dir.appendingPathComponent(ParakeetManifest.tdtDirectory),
            withDestinationURL: Self.tdtCache)
        try fm.createSymbolicLink(
            at: dir.appendingPathComponent(ParakeetManifest.ctcDirectory),
            withDestinationURL: Self.ctcCache)
        return dir
    }

    /// pn-01 from the tts-samantha corpus: "Hi Sharique, please add this to
    /// Wisprit before the meeting." — the clip whose alias hit ("whisper it" →
    /// Wisprit at similarity 1.0) the spike documented.
    private func corpusPcm() throws -> Data {
        let wav = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // WispritParakeetTests
            .deletingLastPathComponent()   // tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("tools/eval/corpus/tts-samantha/audio/pn-01.wav")
        guard FileManager.default.fileExists(atPath: wav.path) else {
            throw XCTSkip("tts-samantha corpus not present")
        }
        let file = try AVAudioFile(forReading: wav)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)) else {
            throw XCTSkip("could not allocate corpus buffer")
        }
        try file.read(into: buffer)
        // The corpus is 16 kHz mono by construction; AVAudioFile hands it
        // back as Float32, so rebuild the canonical Int16 bytes the retained
        // PCM would carry.
        guard buffer.format.sampleRate == 16_000, buffer.format.channelCount == 1,
              let floats = buffer.floatChannelData else {
            throw XCTSkip("corpus clip is not 16k mono")
        }
        var pcm = Data(capacity: Int(buffer.frameLength) * 2)
        for i in 0..<Int(buffer.frameLength) {
            let clamped = max(-1.0, min(1.0, floats[0][i]))
            var sample = Int16((clamped * 32767.0).rounded()).littleEndian
            withUnsafeBytes(of: &sample) { pcm.append(contentsOf: $0) }
        }
        return pcm
    }

    func testVerifiedCachesReconcileTheSpikeClip() async throws {
        let modelsDir = try stagedModelsDir()

        // The real manifest against the real bytes.
        let store = ParakeetModelStore(modelsDir: modelsDir)
        guard case .verified = store.state() else {
            throw XCTSkip("local caches no longer match the manifest: \(store.state())")
        }

        let pcm = try corpusPcm()
        let decoder = ParakeetLiveDecoder(modelsDir: modelsDir)
        let channel = ParakeetVocabularyChannel(decoder: decoder) {
            [ParakeetTerm(text: "Wisprit", aliases: ["whisper it", "whisper"]),
             ParakeetTerm(text: "Sharique", aliases: ["shariq", "cherie"])]
        }

        let warm0 = Date()
        await channel.warmup()
        let warmMs = Date().timeIntervalSince(warm0) * 1000

        let result = await channel.reconcile(pcm: pcm, extraTerms: [])
        let reconciliation = try XCTUnwrap(result, "live reconcile returned nil")

        XCTAssertFalse(reconciliation.transcript.isEmpty)
        XCTAssertEqual(reconciliation.termCount, 2)
        // Whatever was recovered must be a term we asked for — nothing else.
        XCTAssertTrue(Set(reconciliation.termHits.keys)
            .isSubset(of: ["Wisprit", "Sharique"]))
        // Plumbing-grade sanity on the words around the terms.
        XCTAssertTrue(reconciliation.transcript.lowercased().contains("meeting"),
                      reconciliation.transcript)

        print("parakeet-live: warmup \(Int(warmMs)) ms, reconcile "
              + "\(Int(reconciliation.elapsedMs)) ms, hits \(reconciliation.termHits), "
              + "transcript: \(reconciliation.transcript)")
    }

    /// The unverified path refuses before FluidAudio is ever reached — the
    /// zero-network promise depends on this refusal, so it gets a live pin.
    func testUnverifiedDirRefusesToLoad() async throws {
        guard ProcessInfo.processInfo.environment["WISPRIT_PARAKEET_LIVE"] == "1" else {
            throw XCTSkip("set WISPRIT_PARAKEET_LIVE=1 to run the live Parakeet test")
        }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("parakeet-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let decoder = ParakeetLiveDecoder(modelsDir: dir)
        do {
            try await decoder.warmup()
            XCTFail("expected modelsNotVerified")
        } catch let error as ParakeetLiveDecoder.DecoderError {
            XCTAssertEqual(error, .modelsNotVerified)
        }
    }
}
