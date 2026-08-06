import Foundation
import AVFoundation
import Speech
import WispritKit

/// The live path: `SpeechTranscriber` in its own `SpeechAnalyzer`, one pair per
/// utterance, `[.volatileResults, .fastResults]`.
///
/// Every choice here is a spike-S1 result (`docs/research/spikes-s1.md`):
/// * **Fresh module AND fresh analyzer per utterance.** A resident analyzer with
///   `finalize(through: nil)` returns fine (14/14, 39–74 ms) but silently loses
///   the head of every utterance after the first — a 2.0 s utterance vanished
///   completely, 5/5. Session-per-utterance was 12/12 correct at 69–108 ms.
/// * **Never `finalize(through: <CMTime>)`** — reproduced the >70 s hang, and a
///   wedged analyzer cannot be cancelled, so it must never be reachable.
/// * **Never reuse a `SpeechModule` across analyzers** — the second use traps the
///   process (SIGTRAP, no catchable error).
/// * **`.fastResults`** moves the first partial from ~3.9 s to ~1.0 s and the
///   partial cadence from ~3.8 s to ~0.95 s, with identical final text. Without
///   it, an utterance shorter than ~3.8 s produces no partial before release at all.
/// * **No inter-utterance cooldown** — 8/8 clean at 1.0 s gaps once objects are fresh.
public final class SpeechAnalyzerEngine: AsrEngine, @unchecked Sendable {
    public static let engineName = "apple_live"

    private let log = WLog.logger("engine.apple_live")
    private let settings: AsrSettings

    private let state = StateBox()

    public init(settings: AsrSettings) {
        self.settings = settings
    }

    /// Cheap availability gate — mirrors `AppleLiveEngine.healthy()`.
    public static var isAvailable: Bool { SpeechTranscriber.isAvailable }

    // MARK: - lifecycle

    public func begin(onPartial: @escaping @Sendable (String) -> Void) async -> Bool {
        await cancel()   // defensive: an abandoned utterance must never leak into this one

        guard SpeechTranscriber.isAvailable else {
            log.error("SpeechTranscriber unavailable (needs a 16-core ANE; false on the Simulator)")
            return false
        }
        let module = SpeechTranscriber(
            locale: Locale(identifier: settings.locale),
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: [])
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            log.error("no compatible audio format for locale \(self.settings.locale, privacy: .public)")
            return false
        }

        let sink = TranscriptSink()
        let queue = PcmChunkQueue()
        let analyzer = SpeechAnalyzer(modules: [module])
        let (sequence, builder) = AsyncStream.makeStream(of: AnalyzerInput.self)

        // Volatile text is WINDOWED, not cumulative: after an intermediate final the
        // volatiles restart from the post-final range. The caller gets
        // finalizedPrefix + volatile so a live field can render it directly.
        let collector = Task {
            do {
                for try await result in module.results {
                    let text = String(result.text.characters)
                    if result.isFinal {
                        if let full = await sink.appendFinal(text) { onPartial(full) }
                    } else {
                        if let full = await sink.setVolatile(text) { onPartial(full) }
                    }
                }
            } catch {
                await sink.setError("\(error)")
            }
        }

        do {
            try await analyzer.prepareToAnalyze(in: format)
            try await analyzer.start(inputSequence: sequence)
        } catch {
            log.error("analyzer start failed: \(error.localizedDescription, privacy: .public)")
            collector.cancel()
            builder.finish()
            await analyzer.cancelAndFinishNow()
            return false
        }

        let pump = Task {
            while let chunk = await queue.next() {
                guard let buffer = PcmFormat.buffer(from: chunk, in: format) else { continue }
                builder.yield(AnalyzerInput(buffer: buffer))
            }
            builder.finish()   // EOF: the analyzer may now finalize
        }

        state.install(Session(analyzer: analyzer, sink: sink, queue: queue,
                              collector: collector, pump: pump, fed: AudioMeter()))
        return true
    }

    /// Called from the audio callback. Lock-only, never waits.
    public func feed(pcm: Data) {
        guard let session = state.session else { return }
        session.fed.add(pcm)
        session.queue.enqueue(pcm)
    }

    /// One 100 ms chunk. Below this the analyzer never had a chance, so an empty
    /// result is a capture fault and must not be blamed on (or "recovered" from
    /// in) the engine.
    static let minimumAudioBytes = Int(PcmFormat.chunkFrames) * PcmFormat.bytesPerFrame

    /// Peak `PcmFormat.level` (RMS × 4, clamped) below which the utterance is
    /// treated as "the user did not speak". Digital silence measures exactly 0
    /// and normal speech 0.1–1.0, so this only has to clear room tone.
    static let voicedPeakThreshold: Float = 0.02

    public func finalize() async -> UtteranceResult {
        let t0 = Date()
        guard let session = state.take() else {
            return UtteranceResult(text: "", engine: Self.engineName, finalizeMs: 0, timedOut: true)
        }
        let budget = settings.finalizeTimeoutSeconds
        let fedBytes = session.fed.byteCount
        let peakLevel = session.fed.peakLevel

        session.queue.close()          // drain what is queued, then EOF
        _ = await session.pump.value

        // A wedged `finalize` cannot be cancelled (spike S1), so it is never
        // awaited directly — it signals, and we wait on the signal with a deadline.
        let done = Signal()
        let analyzer = session.analyzer
        let sink = session.sink
        Task.detached {
            do { try await analyzer.finalizeAndFinishThroughEndOfInput() }
            catch { await sink.setError("finalize: \(error)") }
            done.fire()
        }
        let completed = await done.wait(timeout: budget, deadlineFrom: t0)

        // Results can land a beat after finalize returns. Wait for the COLLECTOR
        // to finish rather than polling `sink.isDrained()`: the collector exits
        // when `module.results` ends, which is the analyzer's own statement that
        // nothing more is coming. The old heuristic required a final to have
        // landed, so an utterance that produced no final could never satisfy it
        // and burned the entire budget — that is the measured `finalize_ms≈1500`
        // in every empty production row, and it made a dead microphone cost the
        // user 1.5 s per press on top of getting nothing.
        if completed {
            let drained = Signal()
            let collector = session.collector
            Task.detached { _ = await collector.value; drained.fire() }
            _ = await drained.wait(timeout: budget, deadlineFrom: t0)
        }
        session.collector.cancel()

        let (finals, lastPartial, error) = await sink.snapshot()
        let finalizeMs = Date().timeIntervalSince(t0) * 1000.0

        var text = finals.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let timedOut = !completed
        let crashed = completed && error != nil
        let starved = fedBytes < Self.minimumAudioBytes
        // The analyzer was given audible speech, finished cleanly, and produced
        // nothing at all — not a final, not even a volatile. That is a dead
        // session, and the cached engine behind it is suspect.
        //
        // The `peakLevel` gate is load-bearing: MEASURED, 3 s of digital silence
        // also yields zero results (0 partials, 0 finals), so emptiness alone
        // cannot tell a wedged analyzer from a user who simply did not speak.
        // Without the gate every silent press would release the cached engines
        // and pay a reload on the next press — a routine cooldown, which spike
        // S1 explicitly rejected.
        let producedNothing = text.isEmpty && finals.isEmpty && !starved
            && peakLevel >= Self.voicedPeakThreshold

        if timedOut || crashed || producedNothing {
            // Best effort, exactly as asr.py: append the last volatile if it adds anything.
            // This now also covers `producedNothing`, where volatiles had been
            // collected and then silently discarded.
            let tail = lastPartial.trimmingCharacters(in: .whitespaces)
            if !tail.isEmpty && !text.contains(tail) {
                text = (text + " " + tail).trimmingCharacters(in: .whitespaces)
            }
            let reason = timedOut ? "timed out" : (crashed ? "engine failed" : "produced no result")
            log.warning("finalize \(reason, privacy: .public) after \(finalizeMs, format: .fixed(precision: 0)) ms (fed \(fedBytes) bytes, peak \(peakLevel, format: .fixed(precision: 2))) — releasing cached engines")
            await teardown(session, hard: true)
        } else {
            if starved {
                // Never silently indistinguishable from a quiet user again.
                log.error("analyzer received \(fedBytes) bytes of audio — the capture side delivered nothing")
            }
            await teardown(session, hard: false)
        }

        return UtteranceResult(text: text.trimmingCharacters(in: .whitespaces),
                               engine: Self.engineName, finalizeMs: finalizeMs,
                               timedOut: timedOut, crashed: crashed,
                               starvedInput: starved)
    }

    public func cancel() async {
        guard let session = state.take() else { return }
        session.queue.discardAll()
        _ = await session.pump.value
        session.collector.cancel()
        await teardown(session, hard: true)
    }

    // MARK: - internals

    private func teardown(_ session: Session, hard: Bool) async {
        if hard {
            await session.analyzer.cancelAndFinishNow()
            // Free the cached engine so a wedged/failed utterance cannot poison the
            // next one. Measured at 0 ms and harmless (spike S1 Q1); NOT a routine
            // cooldown — there is no cooldown requirement.
            await SpeechModels.endRetention()
        }
    }

    private struct Session {
        let analyzer: SpeechAnalyzer
        let sink: TranscriptSink
        let queue: PcmChunkQueue
        let collector: Task<Void, Never>
        let pump: Task<Void, Never>
        /// Audio actually handed to this session, so `finalize` can tell a dead
        /// analyzer from a dead microphone.
        let fed: AudioMeter
    }

    private final class StateBox: @unchecked Sendable {
        private let lock = UnfairLock()
        private var current: Session?
        var session: Session? {
            lock.lock(); defer { lock.unlock() }
            return current
        }
        func install(_ s: Session) { lock.lock(); current = s; lock.unlock() }
        func take() -> Session? {
            lock.lock(); defer { lock.unlock() }
            let s = current; current = nil; return s
        }
    }
}

/// What one session was actually fed: how much, and whether any of it was loud
/// enough to be speech. Written from the audio callback, so lock-only; the RMS
/// is the same O(chunk) pass `MicCapture` already runs for the pill meter.
final class AudioMeter: @unchecked Sendable {
    private let lock = UnfairLock()
    private var bytes = 0
    private var peak: Float = 0

    func add(_ chunk: Data) {
        let level = PcmFormat.level(of: chunk)
        lock.lock()
        bytes += chunk.count
        if level > peak { peak = level }
        lock.unlock()
    }

    var byteCount: Int { lock.lock(); defer { lock.unlock() }; return bytes }
    var peakLevel: Float { lock.lock(); defer { lock.unlock() }; return peak }
}

/// Accumulates finals + the current volatile window and derives the text-so-far.
actor TranscriptSink {
    private var finals: [String] = []
    private var joinedFinals = ""
    private var volatileText = ""
    private var lastEmitted = ""
    private var error: String?

    func appendFinal(_ text: String) -> String? {
        finals.append(text)
        joinedFinals = finals.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        volatileText = ""
        return emit(joinedFinals)
    }

    func setVolatile(_ text: String) -> String? {
        volatileText = text
        let joined = joinedFinals.isEmpty
            ? text
            : joinedFinals + " " + text.trimmingCharacters(in: .whitespaces)
        return emit(joined)
    }

    func setError(_ message: String) { if error == nil { error = message } }

    func snapshot() -> ([String], String, String?) { (finals, lastVolatileOrEmitted(), error) }

    private func lastVolatileOrEmitted() -> String {
        volatileText.isEmpty ? lastEmitted : volatileText
    }

    private func emit(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != lastEmitted else { return nil }
        lastEmitted = trimmed
        return trimmed
    }
}

/// One-shot cross-task signal with a hard deadline. Deliberately NOT a task
/// group: spike S1 showed a wedged `SpeechAnalyzer.finalize` ignores
/// cancellation, and a task group would then never return — the hang would
/// escape the timeout it was supposed to bound.
final class Signal: @unchecked Sendable {
    private let lock = UnfairLock()
    private var fired = false

    func fire() { lock.lock(); fired = true; lock.unlock() }

    private var isFired: Bool { lock.lock(); defer { lock.unlock() }; return fired }

    func wait(timeout: Double, deadlineFrom start: Date) async -> Bool {
        await Signal.waitFor(remaining: timeout, from: start) { [self] in isFired }
    }

    /// Polls `condition` every millisecond until `start + budget`. The poll cost
    /// is ≤ 1 ms on a 40–110 ms finalize; the Python did the same thing with
    /// `threading.Event.wait(timeout=…)`.
    static func waitFor(remaining budget: Double, from start: Date,
                        condition: @escaping @Sendable () async -> Bool) async -> Bool {
        while true {
            if await condition() { return true }
            if Date().timeIntervalSince(start) >= budget { return false }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }
}
