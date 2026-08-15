import Foundation
import WispritKit

/// On-path Apple Intelligence transcript refinement — the cage from
/// `wisprit/refine.py`, now driving the model in-process.
///
/// Placement in the pipeline: ASR → **refine** → deterministic postprocess →
/// insert. The deterministic stage still runs afterwards, so dictionary
/// corrections (personal vocabulary the ~3B model provably ignores when hinted —
/// measured), voice commands, and email/URL joining all keep working, and any
/// refinement failure simply degrades to the deterministic behavior.
///
/// Trust rules (the model is small and occasionally answers, obeys, or
/// summarizes instead of cleaning — all observed in testing):
///
/// - output stripped of leaked meta-preambles ("here's the cleaned transcript:")
///   and invented wrappers (fences, echoed tags, full quoting);
/// - output must be plausibly the same utterance (word-count band + assistant
///   opener check);
/// - output must not be code the utterance did not contain, and must not be the
///   utterance minus its opening instruction — the two ways an obedient reply
///   slips through the word-count band (`RefineGuards` §obedience evidence);
/// - output must not have deleted a clause: the band's floor is a ratio, so a
///   long utterance can lose ten words and still look plausible (`RefineGuards`
///   §dropped content — measured on LibriSpeech, where the stage made real
///   speech 34% relatively worse);
/// - any error, timeout, or crash keeps the verbatim text. Refinement can only
///   ever *win* — it must never lose words or block insertion.
///
/// The refine call polls the interrupt hook instead of blocking, so the session
/// can interrupt it: Esc aborts the utterance within ~100 ms, and a new fn-press
/// finishes immediately with the verbatim text so the next dictation isn't
/// delayed behind the model.
public actor Refiner {

    // Measured on M4 (macOS 26.5): ~20 ms per output word + ~0.5 s fixed. The
    // timeout is ~2× the expectation so a healthy run never trips it.
    static let timeoutBase: Double = 3.0
    static let timeoutPerWord: Double = 0.045

    /// How often the poll loop wakes to check the model and the interrupt.
    static let pollInterval: Duration = .milliseconds(50)

    /// How long the availability probe waits before re-checking while Apple
    /// Intelligence is unavailable (assets still downloading, setting off), so
    /// the feature comes back without a relaunch.
    static let probeRetryInterval: Duration = .seconds(300)

    private let generator: any RefineGenerating
    private let configuration: @Sendable () -> RefineConfiguration
    private let vocabulary: (any VocabularySource)?
    private let log = WLog.logger("refine")

    /// nil = unknown (probe still running), true/false = probed.
    private var available: Bool?
    private var reason: String = ""

    /// - Parameters:
    ///   - generator: the model. Inject a fake to exercise the cage without
    ///     Apple Intelligence.
    ///   - configuration: read per call so a settings change takes effect
    ///     without a restart.
    ///   - vocabulary: optional dictionary, so a spelled run that is already a
    ///     known term does not force the letter-run bypass.
    ///   - startProbe: false keeps availability at `nil` (tests).
    public init(generator: any RefineGenerating,
                configuration: @escaping @Sendable () -> RefineConfiguration,
                vocabulary: (any VocabularySource)? = nil,
                startProbe: Bool = true) {
        self.generator = generator
        self.configuration = configuration
        self.vocabulary = vocabulary
        // Resolve availability in the background and keep it fresh. `self` is
        // held only for the duration of each probe, never across the sleep, so
        // the loop dies with the Refiner.
        if startProbe {
            Task { [weak self] in
                while true {
                    guard let resolved = await self?.probeNow() else { return }
                    if resolved { return }
                    do { try await Task.sleep(for: Refiner.probeRetryInterval) }
                    catch { return }
                }
            }
        }
    }

    // MARK: - availability

    /// nil while probing; true/false once resolved. Read by the menu.
    public var availability: Bool? { available }
    public var unavailableReason: String { reason }

    /// True when refinement should run: setting on and Apple Intelligence not
    /// known-unavailable (unknown ⇒ try anyway).
    public func enabled() -> Bool {
        configuration().enabled && available != false
    }

    /// Run one availability probe and publish the result. Called on a retry
    /// loop while unavailable (assets still downloading, Apple Intelligence
    /// switched off) so the feature comes back without a relaunch, and directly
    /// by the menu's "check again". `refine` flips availability off again if the
    /// model later reports itself gone.
    @discardableResult
    public func probeNow() async -> Bool {
        let probed = await generator.probe()
        available = probed.available
        reason = probed.reason
        if !probed.available {
            log.warning("Apple Intelligence unavailable: \(probed.reason, privacy: .public)")
        }
        return probed.available
    }

    // MARK: - lifecycle

    /// Prewarm at record start so the model loads during the hold. Failure is
    /// silent — `refine` will retry or fall back. A verbatim-app utterance
    /// skips the prewarm too: that is the "faster" half of the skip.
    public func begin() async {
        guard enabled(), !configuration().verbatimApp else { return }
        await generator.prewarm()
    }

    /// Drop the live session (record cancelled, refine skipped, shutdown).
    public func cancel() async {
        await generator.discard()
    }

    // MARK: - the cage

    /// Clean `raw` through Apple Intelligence.
    ///
    /// Returns text that is always safe to insert plus the metrics outcome.
    /// Never throws.
    ///
    /// `interrupt` is polled ~20×/s while the model runs and may return
    /// `.cancel` (Esc — the caller will discard the utterance) or `.hurry` (a
    /// new dictation is queued: finish NOW with verbatim text). `.none` keeps
    /// waiting.
    public func refine(_ raw: String,
                       interrupt: (@Sendable () -> InterruptSignal)? = nil) async -> RefineResult {
        if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            await cancel()
            return RefineResult(text: raw, outcome: .empty)
        }
        guard enabled() else {
            await cancel()
            return RefineResult(text: raw, outcome: .off)
        }
        // After the master toggle, before every content guard: `off` keeps
        // meaning "the setting is off" in every previously recorded row, and a
        // terminal/IDE utterance pays for no guard it will never use.
        if configuration().verbatimApp {
            await cancel()
            return RefineResult(text: raw, outcome: .skippedVerbatimApp)
        }
        if RefineGuards.hasAddress(raw) {
            await cancel()
            return RefineResult(text: raw, outcome: .hasAddress)
        }
        if RefineGuards.hasLetterRun(raw, vocabulary: vocabulary) {
            await cancel()
            return RefineResult(text: raw, outcome: .hasLetterRun)
        }

        let words = RefineGuards.estimatedWords(raw)
        let config = configuration()
        if words > config.maxWords {
            // Latency is generation-bound (~20 ms/word, serialized system-wide —
            // parallel chunking measured to NOT help), and the shared context is
            // 4096 tokens. Long dictations keep the fast deterministic path.
            await cancel()
            return RefineResult(text: raw, outcome: .tooLong)
        }

        let budget = min(Double(config.timeoutMs) / 1000.0,
                         Self.timeoutBase + Self.timeoutPerWord * Double(words))

        switch await race(raw, deadlineSeconds: budget, interrupt: interrupt) {
        case .interrupted(let outcome):
            // Abandon the model: the generation task is cancelled and the
            // session dropped, so the next press prewarms a fresh one.
            await generator.discard()
            if outcome == .timeout {
                log.warning("refine timed out (\(words, privacy: .public) words)")
            }
            return RefineResult(text: raw, outcome: outcome)

        case .failed(let error):
            let outcome = await outcome(for: error)
            await generator.discard()
            return RefineResult(text: raw, outcome: outcome)

        case .produced(let generated):
            let refined = RefineGuards.stripWrappers(generated)
            // The accept path, in order. `plausible` stays FIRST: it is the
            // broadest check and the one every previously recorded metrics row
            // was attributed to, so anything the word-count band or the
            // assistant-opener check already caught keeps reporting
            // `implausible` and the stream stays comparable. The two obedience
            // detectors run after it because they catch precisely what the band
            // cannot — a reply whose LENGTH is unremarkable but whose CONTENT is
            // the dictation carried out.
            guard RefineGuards.plausible(raw: raw, refined: refined) else {
                log.warning("refined text implausible; keeping verbatim")
                return RefineResult(text: raw, outcome: .implausible)
            }
            guard !RefineGuards.obeyedWithCode(raw: raw, refined: refined) else {
                log.warning("refined text is code the utterance did not contain; keeping verbatim")
                return RefineResult(text: raw, outcome: .obeyed)
            }
            guard !RefineGuards.droppedLeadingInstruction(raw: raw, refined: refined) else {
                log.warning("refined text dropped the leading instruction; keeping verbatim")
                return RefineResult(text: raw, outcome: .obeyed)
            }
            // LAST, deliberately. This is the broad content-loss check, and the
            // two obedience detectors above are the specific diagnoses of the
            // same symptom — an executed instruction also loses content words.
            // Running it after them keeps `obeyed` meaning exactly what it has
            // always meant, and leaves `dropped_content` to report the failure
            // nothing else names: a plain clause deletion out of ordinary
            // speech, which the ratio-floored word-count band cannot see.
            guard !RefineGuards.droppedContent(raw: raw, refined: refined) else {
                log.warning("refined text dropped content words; keeping verbatim")
                return RefineResult(text: raw, outcome: .droppedContent)
            }
            // AFTER `droppedContent`, deliberately: every guard above polices
            // length, obedience or DELETION, and each one owns a metrics row it
            // has been reporting since the cutover. This one is the last and
            // narrowest — words CHANGED rather than words gone — so putting it
            // last leaves every previously recorded outcome meaning exactly what
            // it always meant, and `paraphrased` reports only what nothing else
            // names. Measured on LibriSpeech test-clean: refined WER 3.16% →
            // 2.93%, ls-test-other 6.53% → 6.33%, with zero measured collateral
            // on the battery, the tts-samantha records, or the improved clips.
            guard !RefineGuards.paraphrasedContent(raw: raw, refined: refined) else {
                log.warning("refined text paraphrased the utterance; keeping verbatim")
                return RefineResult(text: raw, outcome: .paraphrased)
            }
            return RefineResult(text: refined, outcome: .applied)
        }
    }

    // MARK: - internals

    private enum RaceResult {
        case produced(String)
        case failed(any Error)
        case interrupted(RefineOutcome)
    }

    /// Race the generation against the deadline and the interrupt hook. The
    /// Python polled a subprocess at 20 Hz for exactly this reason; in-process
    /// the poller races the generation task and cancels it on the way out.
    private func race(_ raw: String,
                      deadlineSeconds: Double,
                      interrupt: (@Sendable () -> InterruptSignal)?) async -> RaceResult {
        enum Leg: Sendable {
            case generation(Result<String, any Error>)
            case interrupted(RefineOutcome)
            case pollerStopped
        }
        let generator = self.generator
        return await withTaskGroup(of: Leg.self) { group in
            group.addTask {
                do { return .generation(.success(try await generator.generate(raw))) }
                catch { return .generation(.failure(error)) }
            }
            group.addTask {
                let deadline = ContinuousClock.now.advanced(by: .seconds(deadlineSeconds))
                while !Task.isCancelled {
                    if ContinuousClock.now >= deadline { return .interrupted(.timeout) }
                    switch interrupt?() ?? .none {
                    case .cancel: return .interrupted(.cancelled)
                    case .hurry: return .interrupted(.preempted)
                    case .none: break
                    }
                    do { try await Task.sleep(for: Refiner.pollInterval) } catch { break }
                }
                return .pollerStopped
            }

            var result: RaceResult = .interrupted(.timeout)
            while let leg = await group.next() {
                switch leg {
                case .pollerStopped:
                    continue                       // only reachable after cancelAll
                case .generation(.success(let text)):
                    result = .produced(text)
                case .generation(.failure(let error)):
                    result = .failed(error)
                case .interrupted(let outcome):
                    result = .interrupted(outcome)
                }
                break
            }
            group.cancelAll()
            return result
        }
    }

    /// Map a generator failure onto the Python outcome vocabulary.
    private func outcome(for error: any Error) async -> RefineOutcome {
        if let refineError = error as? RefineError {
            switch refineError {
            case .setupFailed(let detail):
                log.warning("refine session setup failed: \(detail, privacy: .public)")
                return .spawnFailed
            case .malformedReply:
                return .badReply
            case .unavailable(let detail):
                // Apple Intelligence got disabled / assets evicted mid-session:
                // stop trying until a probe or relaunch recovers.
                available = false
                reason = String(detail.prefix(120))
                return .helperError
            case .emptyResponse, .generationFailed:
                log.warning("refine model error: \(String(describing: refineError), privacy: .public)")
                return .helperError
            }
        }
        // Anything that isn't a RefineError is an unexpected throw — Python's
        // blanket `except` around `_refine_inner`, which logged and returned
        // "error" with the verbatim text.
        let described = String(describing: error)
        log.error("refine failed; keeping verbatim text: \(described, privacy: .public)")
        if described.lowercased().contains("unavailable") {
            available = false
            reason = String(described.prefix(120))
        }
        return .error
    }
}
