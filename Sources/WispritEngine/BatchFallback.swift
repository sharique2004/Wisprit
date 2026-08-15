import Foundation
import WispritKit

/// The batch recovery path, ported from `wisprit/asr_batch.py`.
///
/// Python ran mlx-whisper (GPU) then faster-whisper (CPU). The shipping
/// implementation is `AppleBatchTranscriber` — Apple's own on-device
/// `SpeechTranscriber` over the retained PCM, no downloaded weights and no
/// network. It is what `AsrManager` installs by default.
public protocol BatchTranscribing: Sendable {
    var name: String { get }
    /// nil = this engine could not produce anything (unavailable / failed).
    /// The hallucination filter is applied by the caller, never here.
    func transcribe(pcm: Data, settings: AsrSettings) async -> String?
}

/// The never-built Phase-3 slot, kept only because `mlx_whisper` and
/// `faster_whisper` are still valid `settings["engine"]` values (the Python
/// model names stay accepted so an existing `config.json` keeps working) and a
/// config that names one has to map SOMEWHERE.
///
/// It is no longer the default. It always returned nil, which meant that for as
/// long as it was wired in as `AsrManager`'s batch engine there was no recovery
/// path at all — the retained PCM of every failed utterance was read by nobody.
/// Do not restore it to that position without a real engine behind it.
public struct WhisperKitBatchStub: BatchTranscribing {
    public let name = "whisperkit"
    public init() {}

    public func transcribe(pcm: Data, settings: AsrSettings) async -> String? {
        WLog.logger("engine.batch").info("WhisperKit batch slot was never built — no recovery from this engine")
        return nil
    }
}

/// Applies the silence-hallucination filter around any batch engine, mirroring
/// where `_drop_if_hallucinated` sits in `asr_batch.py` (inside each transcribe
/// function, so every batch result passes through it).
public struct FilteredBatchTranscriber: BatchTranscribing {
    public let inner: any BatchTranscribing
    public var name: String { inner.name }

    public init(_ inner: any BatchTranscribing) { self.inner = inner }

    public func transcribe(pcm: Data, settings: AsrSettings) async -> String? {
        guard !pcm.isEmpty else { return nil }
        guard let raw = await inner.transcribe(pcm: pcm, settings: settings) else { return nil }
        let kept = SilenceHallucinationFilter.drop(raw.trimmingCharacters(in: .whitespaces))
        return kept.isEmpty ? nil : kept
    }
}
