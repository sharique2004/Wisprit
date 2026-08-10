import Foundation
import WispritKit

/// One utterance's audio, detached from the live retention buffer at finalize.
///
/// It is a value, and that is the whole point: `begin()` resets the retention
/// buffer, so an off-path pass that read `retention.data` lazily — as
/// `reconcileVocabulary()` used to — transcribed whatever the NEXT utterance had
/// recorded by the time it got around to looking. A second Fn press inside the
/// 0.5–2.5 s reconcile window was enough. The `id` is monotonic per utterance,
/// so a consumer (or a test) can say which utterance a late result belongs to.
public struct RetainedUtterance: Sendable, Equatable {
    public let id: UInt64
    /// The whole utterance, 16 kHz mono Int16.
    public let pcm: Data

    public init(id: UInt64, pcm: Data) {
        self.id = id
        self.pcm = pcm
    }

    public var isEmpty: Bool { pcm.isEmpty }
    public var durationSeconds: Double {
        Double(pcm.count) / (PcmFormat.sampleRate * Double(PcmFormat.bytesPerFrame))
    }
}

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
    private var utteranceID: UInt64 = 0
    private var lastRetainedValue = RetainedUtterance(id: 0, pcm: Data())

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

    /// The audio the last `finalize()` detached. Read it on the session thread
    /// the moment finalize returns and pass the VALUE to anything off-path —
    /// reading it later is exactly the race this type exists to kill.
    public var lastRetained: RetainedUtterance {
        lock.lock(); defer { lock.unlock() }
        return lastRetainedValue
    }

    public func begin(onPartial: @escaping @Sendable (String) -> Void) async {
        startUtterance()
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
        let retained = detachRetention()

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
            if let fallback = await runBatch(retained.pcm) { return fallback }
            return result
        }

        // Batch-only path (engine override, or the primary never started).
        setPrimary(nil, started: false)
        return await runBatch(retained.pcm)
            ?? UtteranceResult(text: "", engine: "none", finalizeMs: 0, timedOut: true)
    }

    public func cancel() async {
        let engine = currentPrimary
        setPrimary(nil, started: false)
        await engine?.cancel()
        retention.reset()
        clearRetained()
    }

    /// Off-path reconciliation over ONE utterance's audio. Call AFTER the live
    /// text is inserted; it takes hundreds of ms to seconds by design.
    ///
    /// The audio is a parameter, not a lookup: whoever spawns this holds the
    /// value `finalize()` handed them, so a pass still running when the next Fn
    /// press lands keeps transcribing the utterance it was spawned for.
    public func reconcileVocabulary(_ retained: RetainedUtterance) async -> VocabularyReconciliation? {
        guard let channel = vocabularyChannel else { return nil }
        return await channel.reconcile(pcm: retained.pcm)
    }

    // MARK: - internals

    private func startUtterance() {
        retention.reset()
        lock.lock(); utteranceID &+= 1; lock.unlock()
    }

    /// Take this utterance's audio out of the live buffer in one step. The audio
    /// side has already been stopped by the time finalize runs, so the read and
    /// the reset see the same bytes; what matters is that nothing after this
    /// point can reach the buffer the next `begin()` will refill.
    private func detachRetention() -> RetainedUtterance {
        let pcm = retention.data
        retention.reset()
        lock.lock()
        let retained = RetainedUtterance(id: utteranceID, pcm: pcm)
        lastRetainedValue = retained
        lock.unlock()
        return retained
    }

    /// A cancelled utterance has no audio to hand anyone — say so rather than
    /// leave the previous utterance's snapshot standing.
    private func clearRetained() {
        lock.lock()
        lastRetainedValue = RetainedUtterance(id: utteranceID, pcm: Data())
        lock.unlock()
    }

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
