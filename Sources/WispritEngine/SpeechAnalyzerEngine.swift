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
                              collector: collector, pump: pump))
        return true
    }

    /// Called from the audio callback. Lock-only, never waits.
    public func feed(pcm: Data) {
        state.session?.queue.enqueue(pcm)
    }

    public func finalize() async -> UtteranceResult {
        let t0 = Date()
        guard let session = state.take() else {
            return UtteranceResult(text: "", engine: Self.engineName, finalizeMs: 0, timedOut: true)
        }
        let budget = settings.finalizeTimeoutSeconds

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

        // Results can land a beat after finalize returns; give the collector the
        // remainder of the budget, never more.
        if completed {
            _ = await Signal.waitFor(remaining: budget, from: t0) { await sink.isDrained() }
        }
        session.collector.cancel()

        let (finals, lastPartial, error) = await sink.snapshot()
        let finalizeMs = Date().timeIntervalSince(t0) * 1000.0

        var text = finals.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let timedOut = !completed
        let crashed = completed && error != nil

        if timedOut || crashed {
            // Best effort, exactly as asr.py: append the last volatile if it adds anything.
            let tail = lastPartial.trimmingCharacters(in: .whitespaces)
            if !tail.isEmpty && !text.contains(tail) {
                text = (text + " " + tail).trimmingCharacters(in: .whitespaces)
            }
            log.warning("finalize \(timedOut ? "timed out" : "engine failed", privacy: .public) after \(finalizeMs, format: .fixed(precision: 0)) ms")
            await teardown(session, hard: true)
        } else {
            await teardown(session, hard: false)
        }

        return UtteranceResult(text: text.trimmingCharacters(in: .whitespaces),
                               engine: Self.engineName, finalizeMs: finalizeMs,
                               timedOut: timedOut, crashed: crashed)
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

/// Accumulates finals + the current volatile window and derives the text-so-far.
actor TranscriptSink {
    private var finals: [String] = []
    private var joinedFinals = ""
    private var volatileText = ""
    private var lastEmitted = ""
    private var error: String?
    private var sawTerminalFinal = false

    func appendFinal(_ text: String) -> String? {
        finals.append(text)
        joinedFinals = finals.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        volatileText = ""
        sawTerminalFinal = true
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

    /// Heuristic used only to decide whether it is worth waiting a few more ms
    /// after finalize returned: a final has landed and no volatile is pending.
    func isDrained() -> Bool { sawTerminalFinal && volatileText.isEmpty }

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
