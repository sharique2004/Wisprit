import Foundation
import WispritKit

/// Engine-agnostic facade the session drives, ported 1:1 from `AsrManager` in
/// `wisprit/asr.py`. Owns the utterance's retained PCM, the engine-selection
/// enum, and the fallback semantics.
public final class AsrManager: @unchecked Sendable {
    private let log = WLog.logger("engine.manager")
    private let settings: AsrSettings
    private let primaryFactory: @Sendable (AsrSettings) -> any AsrEngine
    private let batch: (any BatchTranscribing)?
    private let vocabularyChannel: VocabularyChannel?

    private let lock = UnfairLock()
    private var primary: (any AsrEngine)?
    private var primaryStarted = false
    private let retention = PcmRetentionBuffer()

    public init(settings: AsrSettings,
                vocabulary: (any VocabularySource)? = nil,
                primaryFactory: @escaping @Sendable (AsrSettings) -> any AsrEngine = { SpeechAnalyzerEngine(settings: $0) },
                batch: (any BatchTranscribing)? = FilteredBatchTranscriber(WhisperKitBatchStub())) {
        self.settings = settings
        self.primaryFactory = primaryFactory
        self.batch = batch
        self.vocabularyChannel = vocabulary.map { VocabularyChannel(settings: settings, vocabulary: $0) }
    }

    public var primaryAvailable: Bool { SpeechAnalyzerEngine.isAvailable }

    /// The full utterance, kept for the batch fallback and the vocabulary pass.
    public var retainedPcm: Data { retention.data }
    public var retainedSeconds: Double { retention.durationSeconds }

    public func begin(onPartial: @escaping @Sendable (String) -> Void) async {
        retention.reset()
        guard settings.engine.usesStreamingPrimary else {
            // Batch-only override: nothing streams, finalize transcribes the PCM.
            setPrimary(nil, started: false)
            return
        }
        let engine = primaryFactory(settings)
        let ok = await engine.begin(onPartial: onPartial)
        setPrimary(ok ? engine : nil, started: ok)
    }

    /// Audio-callback path: retain, then hand to the engine. Both are
    /// lock-only and allocation-bounded; neither can block.
    public func feed(pcm: Data) {
        retention.append(pcm)
        guard let engine = currentPrimary, primaryIsStarted else { return }
        engine.feed(pcm: pcm)
    }

    public func finalize() async -> UtteranceResult {
        let fullPcm = retention.data

        if let engine = currentPrimary, primaryIsStarted {
            let result = await engine.finalize()
            setPrimary(nil, started: false)
            // Any streaming result with text (clean or timeout-with-partials) is
            // returned as-is. The batch engine is the recovery path for a genuine
            // CRASH only — never for an empty result. On silence the engine
            // legitimately returns nothing, and running Whisper on that silence is
            // slow AND hallucinates stock phrases like "Thank you." A silent
            // push-to-talk must insert nothing. (commit b0a763f)
            if !result.text.isEmpty || !result.crashed { return result }
            if let fallback = await runBatch(fullPcm) { return fallback }
            return result
        }

        // Batch-only path (engine override, or the primary never started).
        setPrimary(nil, started: false)
        return await runBatch(fullPcm)
            ?? UtteranceResult(text: "", engine: "none", finalizeMs: 0, timedOut: true)
    }

    public func cancel() async {
        let engine = currentPrimary
        setPrimary(nil, started: false)
        await engine?.cancel()
        retention.reset()
    }

    /// Off-path reconciliation over the retained PCM. Call AFTER the live text is
    /// inserted; it takes hundreds of ms to seconds by design.
    public func reconcileVocabulary() async -> VocabularyReconciliation? {
        guard let channel = vocabularyChannel else { return nil }
        return await channel.reconcile(pcm: retention.data)
    }

    // MARK: - internals

    private func runBatch(_ pcm: Data) async -> UtteranceResult? {
        guard let batch, !pcm.isEmpty else { return nil }
        let t0 = Date()
        guard let text = await batch.transcribe(pcm: pcm, settings: settings) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return UtteranceResult(text: trimmed, engine: batch.name,
                               finalizeMs: Date().timeIntervalSince(t0) * 1000.0)
    }

    private var currentPrimary: (any AsrEngine)? {
        lock.lock(); defer { lock.unlock() }
        return primary
    }

    private var primaryIsStarted: Bool {
        lock.lock(); defer { lock.unlock() }
        return primaryStarted
    }

    private func setPrimary(_ engine: (any AsrEngine)?, started: Bool) {
        lock.lock(); primary = engine; primaryStarted = started; lock.unlock()
    }
}
