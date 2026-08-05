import Foundation
import WispritKit

/// The batch recovery path, ported from `wisprit/asr_batch.py`.
///
/// Python ran mlx-whisper (GPU) then faster-whisper (CPU). The native port
/// replaces both with WhisperKit large-v3-turbo shipped as a Background Assets
/// pack (research §asr-alternatives) — Phase 3. Until then the slot is a stub
/// that reports itself unavailable, which makes the fallback a no-op and leaves
/// the streaming result untouched.
public protocol BatchTranscribing: Sendable {
    var name: String { get }
    /// nil = this engine could not produce anything (unavailable / failed).
    /// The hallucination filter is applied by the caller, never here.
    func transcribe(pcm: Data, settings: AsrSettings) async -> String?
}

/// Phase 3 slot. `mlx_whisper` and `faster_whisper` in `settings["engine"]` both
/// map here — the Python model names stay valid config values so an existing
/// `config.json` keeps working.
public struct WhisperKitBatchStub: BatchTranscribing {
    public let name = "whisperkit"
    public init() {}

    public func transcribe(pcm: Data, settings: AsrSettings) async -> String? {
        // TODO(Phase 3): WhisperKit large-v3-turbo via Background Assets.
        // Returning nil keeps the b0a763f semantics exactly: no phantom text,
        // and a crash with no recoverable audio simply yields an empty utterance.
        WLog.logger("engine.batch").info("batch fallback requested but WhisperKit is not built yet (Phase 3)")
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
