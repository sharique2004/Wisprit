import Foundation
import AVFoundation
import Speech
import WispritKit

/// The batch recovery path, built on the ONLY recognizer this app is allowed to
/// ship: Apple's on-device `SpeechTranscriber`. No downloaded weights, no
/// network — the Phase-3 WhisperKit slot stayed a stub for two releases and in
/// the meantime `runBatch` was a guaranteed `nil`, which is to say there was no
/// recovery at all. 14.4 % of production utterances came back empty (494-row
/// sample); every one of the 25 timed-out utterances returned `chars=0`. The
/// audio was sitting in `PcmRetentionBuffer` the whole time.
///
/// It is the SAME model the live path uses, so "the live session wedged" is the
/// only failure this recovers — not "the model can't read this speaker". That is
/// enough: the measured defect is a broken *session*, not a broken model. Every
/// rescue starts from a fresh transcriber + fresh analyzer over the whole
/// utterance, with no volatile-window bookkeeping and no realtime pacing, which
/// is precisely the shape the live path could not have.
///
/// Three hard constraints inherited from spike S1 (`docs/research/spikes-s1.md`),
/// all of them process-fatal or hang-fatal if broken:
/// * **Fresh `SpeechModule` per analyzer.** Reusing one traps the process
///   (SIGTRAP, no catchable error) — so a rescue builds its own, never the live
///   session's.
/// * **Never `finalize(through: <CMTime>)`** — reproduced a >70 s hang.
/// * **A wedged `finalize` ignores cancellation**, so it is never awaited
///   directly: it fires a `Signal` and the deadline is enforced against that.
///   This is the same discipline `SpeechAnalyzerEngine.finalize` uses, and the
///   reason a rescue cannot reproduce the 498 s finalize hang it exists to fix.
public struct AppleBatchTranscriber: BatchTranscribing {
    public static let engineName = "apple_batch"
    public var name: String { Self.engineName }

    public init() {}

    /// Floor on the rescue budget.
    ///
    /// The live path's 1.5 s is a *latency* budget for a path the user is
    /// watching a live transcript on. This one runs only after that path has
    /// already failed, so the trade inverts: the words are currently lost, and
    /// waiting is strictly better than losing them. 4.0 s covers a cold session
    /// — the failing live finalize has just done a hard teardown
    /// (`SpeechModels.endRetention()`), so this analyzer pays a model load that
    /// a warm one (69–108 ms/utterance, spike S1) does not.
    static let minimumBudgetSeconds = 4.0

    /// Extra budget proportional to the audio, for the long utterance where even
    /// a warm analyzer has real work to do. The eval harness measures unpaced
    /// burst feeding at ~35× realtime with transcripts identical to the paced
    /// run, so 1.5× realtime is ~50× the measured need — a ceiling only a wedged
    /// analyzer can reach, not a latency target.
    static let budgetRealtimeMultiple = 1.5

    /// Deadline for one rescue of `bytes` of 16 kHz mono Int16 audio.
    static func budgetSeconds(forAudioBytes bytes: Int) -> Double {
        let seconds = Double(bytes) / (PcmFormat.sampleRate * Double(PcmFormat.bytesPerFrame))
        return max(minimumBudgetSeconds, budgetRealtimeMultiple * seconds)
    }

    /// Whole-utterance PCM in, text out. Never throws, never blocks past the
    /// deadline, and returns nil for "nothing recoverable" so the caller keeps
    /// whatever the streaming engine managed — the hallucination filter that
    /// wraps this (`FilteredBatchTranscriber`) treats nil the same way.
    ///
    /// EVERY leg runs inside the budget, setup included. The obvious shape —
    /// `await` the setup, then bound only the finalize — is wrong here, and
    /// measurably so: a rescue runs exactly when the speech stack has just
    /// failed and been hard-torn-down, which is the worst moment to assume
    /// `prepareToAnalyze` returns promptly. A live probe with a second
    /// `SpeechAnalyzer` process active stalled setup for over five minutes. So
    /// the whole session is a detached task that signals when it is done, and
    /// this function only ever waits on the signal.
    public func transcribe(pcm: Data, settings: AsrSettings) async -> String? {
        let log = WLog.logger("engine.batch")
        guard !pcm.isEmpty else { return nil }
        guard SpeechTranscriber.isAvailable else {
            log.error("batch recovery unavailable: SpeechTranscriber needs a 16-core ANE")
            return nil
        }

        let t0 = Date()
        let budget = Self.budgetSeconds(forAudioBytes: pcm.count)
        // The live path's sink, deliberately: a rescued transcript must be
        // assembled exactly the way a live one is (trimmed finals joined by a
        // single space), or the same audio would read differently depending on
        // which engine produced it. Shared with the session task, so a deadline
        // that fires mid-transcription still returns the finals that landed.
        let sink = TranscriptSink()
        let handoff = BatchSessionHandoff<SpeechAnalyzer>()
        let done = Signal()

        Task.detached {
            await Self.runSession(pcm: pcm, settings: settings,
                                  sink: sink, handoff: handoff, done: done)
        }
        let completed = await done.wait(timeout: budget, deadlineFrom: t0)

        let (finals, _, error) = await sink.snapshot()
        let text = finals.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let elapsedMs = Date().timeIntervalSince(t0) * 1000.0

        if !completed {
            log.warning("batch session timed out after \(elapsedMs, format: .fixed(precision: 0)) ms of a \(budget, format: .fixed(precision: 1)) s budget — keeping \(text.count) chars")
            // Fire-and-forget teardown of whatever the session had built by now.
            // Never awaited: a wedged analyzer cannot be un-wedged, and awaiting
            // its teardown would hand the caller back the very hang this
            // deadline exists to bound. A session still inside setup has
            // registered nothing yet — `handoff` has marked it abandoned, and it
            // will destroy what it builds instead of leaking it.
            let orphan = handoff.abandon()
            Task.detached {
                orphan.collector?.cancel()
                if let analyzer = orphan.analyzer { await analyzer.cancelAndFinishNow() }
                await SpeechModels.endRetention()
            }
        } else if error != nil {
            // Whatever finals arrived before the stream errored are still real
            // words; this is the recovery path, so partial beats nothing.
            log.warning("batch results stream errored — keeping \(text.count) recovered chars")
        }

        guard !text.isEmpty else { return nil }
        log.info("batch recovered \(text.count) chars in \(elapsedMs, format: .fixed(precision: 0)) ms")
        return text
    }

    /// The unbounded half: builds the session, feeds it, finalizes it, and
    /// fires `done`. Nothing awaits this task, so it is free to block forever on
    /// an Apple call — the caller has already left. Its one obligation is that
    /// every stage checks `handoff` before starting the next, so a session that
    /// wakes up after the deadline destroys what it built instead of leaking a
    /// live analyzer (and the cached engine behind it) into the next utterance.
    private static func runSession(pcm: Data, settings: AsrSettings,
                                   sink: TranscriptSink,
                                   handoff: BatchSessionHandoff<SpeechAnalyzer>,
                                   done: Signal) async {
        let log = WLog.logger("engine.batch")
        defer { done.fire() }

        // `reportingOptions: []` — finals only. Volatiles exist to make a LIVE
        // field move; here nobody is watching, and every volatile is a result
        // the collector has to marshal for nothing. `.fastResults` is likewise
        // a latency lever for a live transcript, not an accuracy one (identical
        // final text, spike S1), so it is off too.
        let module = SpeechTranscriber(
            locale: Locale(identifier: settings.locale),
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [])
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            log.error("no batch audio format for \(settings.locale, privacy: .public)")
            return
        }
        // Nothing has been constructed yet, so an abandoned session here simply
        // stops — there is nothing to destroy and nothing to release.
        guard handoff.isLive else { return }

        let analyzer = SpeechAnalyzer(modules: [module])
        let (sequence, builder) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let collector = Task {
            do {
                for try await result in module.results where result.isFinal {
                    _ = await sink.appendFinal(String(result.text.characters))
                }
            } catch {
                await sink.setError("\(error)")
            }
        }
        // The registration IS the ownership rule: whoever holds these objects
        // tears them down, and exactly one side ever holds them. `adopt` fails
        // when the deadline has already fired, which makes this session the
        // owner of an analyzer nobody is waiting for.
        guard handoff.adopt(analyzer: analyzer, collector: collector) else {
            log.warning("batch setup finished after the deadline — discarding the analyzer it built")
            collector.cancel()
            builder.finish()
            await Self.discard(analyzer)
            return
        }

        do {
            try await analyzer.prepareToAnalyze(in: format)
            try await analyzer.start(inputSequence: sequence)
        } catch {
            log.error("batch analyzer start failed: \(error.localizedDescription, privacy: .public)")
            builder.finish()
            if let owned = handoff.take() {
                owned.collector?.cancel()
                if let a = owned.analyzer { await Self.discard(a) }
            }
            return
        }
        guard handoff.isLive else { builder.finish(); return }

        // Unpaced burst: the whole utterance is already in memory, so there is
        // nothing to pace against. Chunked at the pipeline's 100 ms only
        // because that is the shape both the eval harness and the vocabulary
        // channel proved safe — it bounds the per-buffer allocation without
        // adding a single sleep.
        for chunk in PcmFormat.split(pcm) {
            guard let buffer = PcmFormat.buffer(from: chunk, in: format) else { continue }
            builder.yield(AnalyzerInput(buffer: buffer))
        }
        builder.finish()   // EOF: the analyzer may now finalize

        do { try await analyzer.finalizeAndFinishThroughEndOfInput() }
        catch { await sink.setError("batch finalize: \(error)") }

        // Results land a beat after finalize returns, so wait for the COLLECTOR
        // — it exits when `module.results` ends, which is the analyzer's own
        // statement that nothing more is coming. Its own fresh window, because
        // the caller's budget may be nearly spent by now and the finals that
        // arrive in this window are the whole point of the pass.
        guard let owned = handoff.take() else { return }   // the deadline already cleaned up
        let drained = Signal()
        Task.detached { _ = await collector.value; drained.fire() }
        _ = await drained.wait(timeout: SpeechAnalyzerEngine.collectorGraceSeconds,
                               deadlineFrom: Date())
        owned.collector?.cancel()
    }

    /// Destroy an analyzer this side owns. Also releases the cached engine: the
    /// same lever the live path pulls after a failure, for the same reason — a
    /// failed session leaves a cached engine behind and this path shares that
    /// cache with the live one. Measured free (0 ms, spike S1 Q1).
    private static func discard(_ analyzer: SpeechAnalyzer) async {
        await analyzer.cancelAndFinishNow()
        await SpeechModels.endRetention()
    }
}

/// One-shot ownership hand-off between a deadline-bounded caller and the
/// unbounded task it started.
///
/// The rule it enforces has exactly one job: **the analyzer and its collector
/// are torn down by whichever side holds them, and only one side ever does.**
/// Without it the two obvious implementations are both wrong — if the caller
/// always tears down, a setup still running at the deadline builds an analyzer
/// nobody destroys (a live analyzer, and the cached engine behind it, leaking
/// into the next utterance); if the session always tears down, a wedged setup
/// means it never happens at all.
///
/// Generic over the analyzer type so the race can be tested without a speech
/// model — what is under test is the ownership protocol, not transcription.
final class BatchSessionHandoff<Analyzer: AnyObject>: @unchecked Sendable {
    typealias Owned = (analyzer: Analyzer?, collector: Task<Void, Never>?)

    private let lock = UnfairLock()
    private var analyzer: Analyzer?
    private var collector: Task<Void, Never>?
    private var abandoned = false
    private var claimed = false

    /// False once the deadline has fired. Checked between stages so a session
    /// that is merely slow (rather than wedged) stops doing work nobody wants.
    var isLive: Bool {
        lock.lock(); defer { lock.unlock() }
        return !abandoned
    }

    /// Register what the session built. Returns false when the deadline already
    /// fired — the session then owns what it built and must destroy it.
    func adopt(analyzer: Analyzer, collector: Task<Void, Never>) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !abandoned else { return false }
        self.analyzer = analyzer
        self.collector = collector
        return true
    }

    /// Take ownership from the session side. nil means the deadline got here
    /// first and has already dealt with them.
    func take() -> Owned? {
        lock.lock(); defer { lock.unlock() }
        guard !abandoned, !claimed else { return nil }
        claimed = true
        let owned: Owned = (analyzer, collector)
        analyzer = nil; collector = nil
        return owned
    }

    /// The deadline fired: mark the session abandoned and take whatever it had
    /// registered, in one step. Both halves must be atomic or the analyzer
    /// registered a microsecond later would belong to nobody.
    @discardableResult
    func abandon() -> Owned {
        lock.lock(); defer { lock.unlock() }
        abandoned = true
        let owned: Owned = (analyzer, collector)
        analyzer = nil; collector = nil
        return owned
    }
}
