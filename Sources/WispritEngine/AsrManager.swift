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
                batch: (any BatchTranscribing)? = FilteredBatchTranscriber(AppleBatchTranscriber())) {
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
        guard ok else {
            setPrimary(nil, started: false)
            return
        }
        // Retained-head replay (R7, acoustic §3 fix 1): the mic goes live
        // BEFORE this install completes, and until now any chunk arriving in
        // that window reached only the retention buffer — on a cold start the
        // head of the utterance silently vanished from the live transcript
        // while the retained copy kept it. Splice that head into the engine
        // here, INSIDE the feed lock and BEFORE the started flag flips, so a
        // live chunk can neither overtake the replay nor be fed twice:
        // `feed` appends and checks the flag inside the same critical section,
        // which makes every chunk either part of this snapshot (flag still
        // down when it appended) or a post-replay live feed (flag already up)
        // — never both. Burst-feeding a multi-chunk head is the eval
        // harness's proven-safe unpaced shape (~35× realtime, identical
        // transcripts). Expected steady-state delta ≈ 0 — this closes a race
        // deterministically; it is not an accuracy lever.
        lock.lock()
        let head = retention.data
        if !head.isEmpty { engine.feed(pcm: head) }
        primary = engine
        primaryStarted = true
        lock.unlock()
    }

    /// Audio-callback path: retain, then hand to the engine. Both are
    /// lock-only and allocation-bounded; neither can block. The append and the
    /// started-flag check share one critical section with `begin`'s install —
    /// the no-double-feed/no-reorder guarantee of the head replay above.
    public func feed(pcm: Data) {
        lock.lock()
        retention.append(pcm)
        let engine = primaryStarted ? primary : nil
        lock.unlock()
        engine?.feed(pcm: pcm)
    }

    public func finalize() async -> UtteranceResult {
        let retained = detachRetention()

        if let engine = currentPrimary, primaryIsStarted {
            let result = await engine.finalize()
            setPrimary(nil, started: false)
            guard Self.needsRescue(result) else { return result }
            return await rescue(result, pcm: retained.pcm)
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
    /// `extraTerms` travel the same way and for the same reason — they are one
    /// utterance's context candidates, dead the moment this pass returns.
    public func reconcileVocabulary(_ retained: RetainedUtterance,
                                    extraTerms: [String] = []) async -> VocabularyReconciliation? {
        guard let channel = vocabularyChannel else { return nil }
        return await channel.reconcile(pcm: retained.pcm, extraTerms: extraTerms)
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

    /// Is this streaming result one the batch engine is allowed to re-read?
    ///
    /// The old rule was "crash only", and it was written when `runBatch` could
    /// not succeed (the WhisperKit slot was a stub returning nil) and when the
    /// only batch engine on the table was a Whisper that hallucinates stock
    /// captions on silence. Both premises are gone: the batch engine is now
    /// Apple's own on-device recognizer over the SAME retained PCM, and the
    /// production numbers say crash-only left the user with nothing far too
    /// often — 14.4 % of 494 utterances empty, and all 25 timeouts (5.1 %)
    /// returned `chars=0` while the full utterance sat unread in retention.
    ///
    /// So: rescue every way the ENGINE can fail —
    /// * `crashed` — the original trigger, unchanged.
    /// * `timedOut` — the finalize deadline fired. Whatever the streaming
    ///   engine had is a truncation of the utterance at best; on the LibriSpeech
    ///   eval, 5/200 clips were truncated or emptied by exactly this.
    /// * `producedNothing` — audible speech in, clean finish, nothing out.
    /// * empty text with a peak level that clears `voicedPeakThreshold` — the
    ///   same defect as `producedNothing`, for an engine that did not label it
    ///   (a starved-but-loud session; any `AsrEngine` other than this one).
    ///
    /// The quiet-microphone case arrives through `producedNothing`, not through
    /// the peak clause: `SpeechAnalyzerEngine.producedNothing` treats a volatile
    /// the analyzer emitted as speech evidence in its own right, precisely
    /// because the meter can sit under the threshold while the analyzer is
    /// transcribing. A result that carried a partial is therefore already
    /// flagged by the time it gets here — and, having had that partial salvaged
    /// into its text, is no longer empty either.
    ///
    /// And never rescue SILENCE. A clean finish with a peak below the voiced
    /// threshold is a user who did not speak, and a silent push-to-talk must
    /// insert nothing — the b0a763f rule, still load-bearing. `peakLevel` is
    /// what makes the distinction possible at all: MEASURED, 3 s of digital
    /// silence yields zero results, exactly like a wedged analyzer does.
    static func needsRescue(_ result: UtteranceResult) -> Bool {
        if result.crashed || result.timedOut || result.producedNothing { return true }
        return result.text.isEmpty
            && result.peakLevel >= SpeechAnalyzerEngine.voicedPeakThreshold
    }

    /// Re-transcribe the retained utterance and decide which reading to keep.
    ///
    /// The interesting case is timeout-WITH-partial-text, which used to be
    /// returned as a success. It is not one: the deadline fired mid-utterance,
    /// so the partial is the sentence cut off wherever the clock happened to
    /// land. The batch pass reads the whole thing, and more words is the signal
    /// that it did — a longer reading of the same audio can only be a longer
    /// reading. When the batch pass comes back shorter (or empty, or the filter
    /// dropped it as a hallucination), the streaming text stands: the rescue is
    /// allowed to add words, never to lose them.
    private func rescue(_ streaming: UtteranceResult, pcm: Data) async -> UtteranceResult {
        guard let batch = await runBatch(pcm) else { return streaming }
        if !streaming.text.isEmpty,
           Self.wordCount(batch.text) <= Self.wordCount(streaming.text) {
            log.info("batch rescue declined: streaming kept \(Self.wordCount(streaming.text)) words vs batch \(Self.wordCount(batch.text))")
            return streaming
        }
        log.warning("batch rescue applied: \(batch.text.count) chars from \(batch.engine, privacy: .public) after the streaming engine returned \(streaming.text.count)")
        // The engine name and elapsed ms are the BATCH pass's, because that is
        // the pass whose text the user is about to see. Everything describing
        // the streaming failure survives untouched, so `metrics.log` still
        // counts this utterance against the streaming engine.
        return UtteranceResult(text: batch.text, engine: batch.engine,
                               finalizeMs: batch.finalizeMs,
                               timedOut: streaming.timedOut,
                               crashed: streaming.crashed,
                               starvedInput: streaming.starvedInput,
                               peakLevel: streaming.peakLevel,
                               producedNothing: streaming.producedNothing,
                               rescued: true)
    }

    /// Words after lowercasing and stripping punctuation, so "more words" is a
    /// statement about CONTENT and not about how each engine punctuates.
    static func wordCount(_ text: String) -> Int { TranscriptText.words(text).count }

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
