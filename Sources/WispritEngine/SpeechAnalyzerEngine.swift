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
    static let voicedPeakThreshold: Float = 0.01

    /// Poll slice for the progress-aware finalize wait. Small enough that the
    /// stall detector reacts inside the budget, large enough that a result
    /// actually has time to arrive between two looks — the measured partial
    /// cadence with `.fastResults` is ~0.95 s worst case, so a slice must be a
    /// fraction of that or every slice would look like a stall.
    static let progressSliceSeconds = 0.2

    /// How far past the idle budget a finalize that is STILL PRODUCING may run:
    /// 2× (3.0 s at the shipped 1.5 s budget). The flat budget killed live
    /// transcription mid-sentence — on the LibriSpeech eval, 5/200 clips came
    /// back truncated or empty because the deadline landed while results were
    /// arriving. This is the ceiling for an actively-working analyzer only; an
    /// idle one still costs exactly one budget.
    static let progressBudgetMultiple = 2.0

    /// The collector's OWN window after a completed finalize, measured from the
    /// moment finalize completed rather than from `t0`. The collector exits when
    /// `module.results` ends — the analyzer's own statement that nothing more is
    /// coming — which is normally immediate; 500 ms is the margin for the late
    /// results that used to be cancelled out from under a slow utterance.
    static let collectorGraceSeconds = 0.5

    public func finalize() async -> UtteranceResult {
        let t0 = Date()
        guard let session = state.take() else {
            return UtteranceResult(text: "", engine: Self.engineName, finalizeMs: 0, timedOut: true)
        }
        let budget = settings.finalizeTimeoutSeconds
        let fedBytes = session.fed.byteCount
        let peakLevel = session.fed.peakLevel

        session.queue.close()          // drain what is queued, then EOF

        // The pump drain is INSIDE the deadline, not before it. `await
        // session.pump.value` was unbounded, which made every millisecond the
        // pump spent stuck a millisecond nobody was counting — the shape of the
        // 498 s finalize, where the deadline machinery below never even got to
        // run. Nothing the pump does is worth an unbounded wait: on the far side
        // of `queue.close()` it has only to convert what is already queued.
        let pumped = Signal()
        let pump = session.pump
        Task.detached { _ = await pump.value; pumped.fire() }
        if await pumped.wait(timeout: budget, deadlineFrom: t0) == false {
            // Drop what is still queued so the pump can reach `builder.finish()`
            // and the analyzer can see EOF. The cost is the tail of the audio;
            // the alternative is the whole utterance.
            session.queue.discardAll()
            log.warning("pump did not drain inside the finalize budget — discarding the queued tail")
        }

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
        let completed = await Self.waitForFinalize(done, sink: sink, budget: budget, from: t0)

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
            // A FRESH window, deliberately not the leftover of the finalize
            // budget. Sharing one deadline from `t0` meant a finalize that
            // completed at 1.4 s of a 1.5 s budget left the collector 100 ms to
            // drain `module.results` before the `cancel()` below threw the rest
            // away — silent tail truncation, and worst on exactly the long
            // utterances where the tail is worth the most.
            _ = await drained.wait(timeout: Self.collectorGraceSeconds, deadlineFrom: Date())
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
        let producedNothing = Self.producedNothing(
            finals: finals, lastPartial: lastPartial, starved: starved, peakLevel: peakLevel)

        if timedOut || crashed || producedNothing {
            // Best effort, exactly as asr.py: append the last volatile if it
            // adds anything. This also covers `producedNothing`, where volatiles
            // had been collected and then silently discarded.
            text = TranscriptText.appendingTail(lastPartial, to: text)
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
                               starvedInput: starved, peakLevel: peakLevel,
                               producedNothing: producedNothing)
    }

    public func cancel() async {
        guard let session = state.take() else { return }
        session.queue.discardAll()
        // Bounded for the same reason `finalize` bounds it, with more at stake:
        // `begin` calls `cancel` defensively, so an unbounded wait here could
        // hang the START of the next utterance rather than the end of this one.
        // `discardAll` has already resumed the queue's waiter, so a pump still
        // running after the budget is one that is never coming back.
        let pumped = Signal()
        let pump = session.pump
        Task.detached { _ = await pump.value; pumped.fire() }
        if await pumped.wait(timeout: settings.finalizeTimeoutSeconds, deadlineFrom: Date()) == false {
            log.warning("pump still running at cancel — abandoning it rather than blocking the next utterance")
        }
        session.collector.cancel()
        await teardown(session, hard: true)
    }

    // MARK: - internals

    /// The analyzer was given speech, finished cleanly, and produced no FINAL.
    /// That is a dead session, and the cached engine behind it is suspect.
    ///
    /// "Was given speech" has two independent witnesses, and it needs both:
    /// * `peakLevel` clears the voiced threshold. Load-bearing on its own —
    ///   MEASURED, 3 s of digital silence also yields zero results (0 partials,
    ///   0 finals), so emptiness alone cannot tell a wedged analyzer from a user
    ///   who did not speak. Without a gate here every silent press would release
    ///   the cached engines and pay a reload on the next press, the routine
    ///   cooldown spike S1 explicitly rejected.
    /// * a non-empty volatile. The meter is a THRESHOLD on a physical signal, so
    ///   a low-gain mic (or a quiet speaker on a distant array) can sit under
    ///   the meter floor while the analyzer is transcribing perfectly well. When the
    ///   analyzer itself emitted words, arguing about the microphone's level is
    ///   absurd: its own output is the better evidence, and requiring the meter
    ///   too meant a quiet user's utterance was dropped with a volatile in hand.
    ///
    /// Neither witness can fire on true silence: digital silence produces no
    /// volatiles, and its peak is exactly 0.
    static func producedNothing(finals: [String], lastPartial: String,
                                starved: Bool, peakLevel: Float) -> Bool {
        guard finals.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }),
              !starved else { return false }
        return peakLevel >= voicedPeakThreshold
            || !lastPartial.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Wait for `done`, extending the deadline for as long as the analyzer is
    /// still producing results.
    ///
    /// The flat `budget`-from-`t0` deadline this replaces could not tell "the
    /// analyzer is stuck" from "the analyzer is busy", so it treated both as
    /// stuck and hard-killed at 1.5 s — discarding the tail of a long utterance,
    /// or all of it when no final had landed yet. `TranscriptSink.changes` is
    /// the discriminator: it moves on every result of either kind, so a finalize
    /// that is transcribing visibly differs from one that is wedged.
    ///
    /// Two guarantees, both deliberate:
    /// * an IDLE stall costs exactly `budget` — the dead-microphone case does
    ///   not get slower;
    /// * a WORKING finalize gets up to `progressBudgetMultiple × budget` from
    ///   `t0` and not one slice more, so a wedged analyzer that somehow keeps
    ///   emitting cannot extend itself forever.
    static func waitForFinalize(_ done: Signal, sink: TranscriptSink,
                                budget: Double, from t0: Date) async -> Bool {
        let hardCap = max(budget, budget * progressBudgetMultiple)
        var lastChange = await sink.changes
        var lastProgress = Date()
        while true {
            // Polls at 1 ms inside the slice, so the common 40–110 ms finalize
            // still returns as fast as it ever did.
            if await done.wait(timeout: progressSliceSeconds, deadlineFrom: Date()) { return true }
            if Date().timeIntervalSince(t0) >= hardCap { return false }
            let changes = await sink.changes
            if changes != lastChange {
                lastChange = changes
                lastProgress = Date()
                continue
            }
            if Date().timeIntervalSince(lastProgress) >= budget { return false }
        }
    }

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

    /// Monotonic count of results absorbed, of EITHER kind.
    ///
    /// This is the liveness signal `finalize` polls, which is why it counts
    /// every arrival rather than every text change: a run of identical volatiles
    /// is suppressed for the live field (it would spam it), but it is still
    /// proof that the analyzer is working, and killing a finalize that is
    /// repeating itself would be the same defect in a smaller costume.
    private(set) var changes: UInt64 = 0

    func appendFinal(_ text: String) -> String? {
        changes &+= 1
        finals.append(text)
        joinedFinals = finals.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        volatileText = ""
        return emit(joinedFinals)
    }

    func setVolatile(_ text: String) -> String? {
        changes &+= 1
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
