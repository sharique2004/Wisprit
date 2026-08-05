import Foundation
import WispritCorrections
import WispritEngine
import WispritKit
import WispritMacInput
import WispritPersistence
import WispritPostProcess
import WispritRefine

/// The dictation state machine — a 1:1 port of `wisprit/session.py`.
///
/// Consumes `HotkeyEvent`s from the shared queue and drives one utterance
/// through capture → streaming ASR → spoken-spelling corrections → Apple
/// Intelligence refinement → deterministic cleanup → history → insertion,
/// flashing the pill and logging one metrics line along the way.
///
/// Runs on a single dedicated worker thread so the stages are naturally
/// serialized (async core APIs are awaited via `runBlocking`), and the loop is
/// crash-proof: a per-utterance failure returns the machine to IDLE.
///
/// States: IDLE → RECORDING → FINALIZING → INSERTING → IDLE, with a CANCEL
/// path (Esc, chord interrupt, or a sub-debounce tap) that discards audio.
public final class SessionController: @unchecked Sendable {

    public enum State: String, Sendable, CaseIterable {
        case idle, recording, finalizing, inserting
    }

    /// Everything read per-utterance from live settings, plus the test seams.
    public struct Configuration {
        /// `hold_debounce_ms` — a press→release shorter than this is an
        /// accidental brush and is silently discarded (no metrics row).
        public var holdDebounceMs: @Sendable () -> Double
        /// The master `enabled` toggle from the menu.
        public var isEnabled: @Sendable () -> Bool
        /// `filler_removal` / `ensure_sentence_period` / `leading_space`.
        public var postProcessOptions: @Sendable () -> PostProcessOptions
        /// Pill level-meter cadence; nil disables the ticker entirely (tests,
        /// and `pill_hidden`). Python ran a 20 Hz `pill-level` thread.
        public var levelTickInterval: TimeInterval?
        /// Run the off-path DictationTranscriber vocabulary pass after each
        /// insertion. Off in tests: it spawns a detached task.
        public var reconcileVocabulary: Bool
        /// `self._events.get(timeout=0.25)` in the Python run loop.
        public var pollTimeout: TimeInterval

        public init(holdDebounceMs: @escaping @Sendable () -> Double = { 150 },
                    isEnabled: @escaping @Sendable () -> Bool = { true },
                    postProcessOptions: @escaping @Sendable () -> PostProcessOptions = { PostProcessOptions() },
                    levelTickInterval: TimeInterval? = 0.05,
                    reconcileVocabulary: Bool = true,
                    pollTimeout: TimeInterval = 0.25) {
            self.holdDebounceMs = holdDebounceMs
            self.isEnabled = isEnabled
            self.postProcessOptions = postProcessOptions
            self.levelTickInterval = levelTickInterval
            self.reconcileVocabulary = reconcileVocabulary
            self.pollTimeout = pollTimeout
        }
    }

    private let log = WLog.logger("session")

    private let events: HotkeyEventQueue
    private let asr: AsrPort
    private let audio: AudioPort
    private let refiner: RefinePort?
    private let inserter: InsertPort
    private let pill: PillPort?
    private let history: HistoryPort
    private let metrics: MetricsPort
    private let vocabulary: VocabularyPort?
    private let corrections: (any CorrectionApplying)?
    private let corrector: SpokenSpellingCorrector?
    private let gate: RecordingGate?
    private let config: Configuration

    private let lock = NSLock()
    private var stateValue: State = .idle
    private var pressTimestampValue: Double = 0
    /// The previous utterance's RAW final — the antecedent window for a
    /// cross-utterance spoken-spelling correction.
    private var previousUtterance: String = ""

    private let stopFlag = StopFlag()
    private var thread: Thread?
    private let levelStop = StopFlag()

    public init(events: HotkeyEventQueue,
                asr: AsrPort,
                audio: AudioPort,
                inserter: InsertPort,
                history: HistoryPort,
                metrics: MetricsPort,
                refiner: RefinePort? = nil,
                pill: PillPort? = nil,
                vocabulary: VocabularyPort? = nil,
                corrections: (any CorrectionApplying)? = nil,
                corrector: SpokenSpellingCorrector? = nil,
                gate: RecordingGate? = nil,
                configuration: Configuration = Configuration()) {
        self.events = events
        self.asr = asr
        self.audio = audio
        self.inserter = inserter
        self.history = history
        self.metrics = metrics
        self.refiner = refiner
        self.pill = pill
        self.vocabulary = vocabulary
        self.corrections = corrections
        self.corrector = corrector
        self.gate = gate
        self.config = configuration
    }

    public var state: State {
        lock.lock(); defer { lock.unlock() }
        return stateValue
    }

    /// Notified on every state transition — the menu-bar glyph. Assign once at
    /// wiring time, before `start()`.
    public var onStateChange: (@Sendable (State) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return stateObserver }
        set { lock.lock(); stateObserver = newValue; lock.unlock() }
    }
    private var stateObserver: (@Sendable (State) -> Void)?

    // MARK: - lifecycle

    public func start() {
        stopFlag.reset()
        let thread = Thread { [weak self] in self?.run() }
        thread.name = "session"
        thread.start()
        self.thread = thread
    }

    public func stop() {
        stopFlag.signal()
        stopLevelTicker()
    }

    /// The worker loop. Public so a caller can run it on a thread it owns.
    public func run() {
        log.info("session loop started")
        while !stopFlag.isSignalled {
            guard let event = events.get(timeout: config.pollTimeout) else { continue }
            dispatch(event)
        }
    }

    // MARK: - dispatch

    /// `Session._dispatch`. Synchronous and re-entrancy-free: the caller is the
    /// single session thread (or, in tests, the test thread).
    public func dispatch(_ event: HotkeyEvent) {
        switch event.kind {
        case .press:
            if state == .idle { begin(at: event.ts) }
        case .release:
            if state == .recording { finish(at: event.ts) }
        case .cancel, .esc:
            if state == .recording || state == .finalizing {
                abort(reason: event.kind == .cancel ? "cancelled" : "esc")
            }
        case .pasteLast:
            if state == .idle, config.isEnabled() { pasteLast() }
        }
    }

    // MARK: - transitions

    private func begin(at timestamp: Double) {
        guard config.isEnabled() else { return }

        // Hot-reload the dictionary on key-down so an edit lands on the very
        // next utterance without a restart. Cheap (an mtime stat).
        _ = vocabulary?.maybeReload()

        setPressTimestamp(timestamp)
        guard audio.start() else {
            flashError("microphone unavailable")
            return
        }

        // begin() carries the analyzer's prepareToAnalyze (31–54 ms measured);
        // the sub-400 ms finalize budget depends on paying it here, on key-down.
        let pill = self.pill
        runBlocking { [asr] in
            await asr.begin(onPartial: { text in pill?.livePartial(text) })
        }

        // Spawn/prewarm the Apple Intelligence session now so the model loads
        // while the user is still speaking (refine itself runs at finalize).
        if let refiner {
            runBlocking { await refiner.begin() }
        }

        setState(.recording)
        gate?.setRecording(true)
        pill?.showRecording()
        startLevelTicker()
    }

    private func finish(at timestamp: Double) {
        stopLevelTicker()
        let debounceMs = config.holdDebounceMs()
        let heldMs = (timestamp - pressTimestampValue) * 1000.0

        if heldMs < debounceMs {
            // Accidental brush — discard everything, write no metrics row.
            gate?.setRecording(false)
            audio.stop()
            runBlocking { [asr] in await asr.cancel() }
            cancelRefiner()
            setState(.idle)
            pill?.hide()
            return
        }

        setState(.finalizing)
        pill?.showFinalizing()

        let tRelease = MonotonicClock.now()
        audio.stop()
        let result = runBlocking { [asr] in await asr.finalize() }
        let tAsr = MonotonicClock.now()

        // An Esc during a slow finalize aborts — check before paying for AI
        // cleanup. The hotkey keeps emitting Esc until AFTER the refine stage:
        // it is the longest window in the pipeline and must stay cancellable.
        if events.drainCancel() {
            gate?.setRecording(false)
            cancelRefiner()
            setState(.idle)
            pill?.hide()
            return
        }

        // Spoken-spelling corrections run on the RAW final, before refine:
        // the model deterministically corrupts spelled runs
        // ("S-H-A-R-I-Q-U-E" → "Sharifue"). Refine's own letter-run bypass is
        // the safety net, not the detector.
        let raw = result.text
        let action = corrector?.decide(utterance: raw, previousUtterance: previousUtterance) ?? .none
        let correction = CorrectionApplier.apply(action, to: raw)
        setPreviousUtterance(raw)

        // Apple Intelligence refinement (prewarmed at record start). Any
        // failure/skip returns the verbatim text — never blocks insertion. The
        // interrupt hook lets Esc abort mid-generation (~100 ms) and lets a
        // queued fn-press finish the stage instantly with verbatim text.
        var aiOutcome = RefineOutcome.off
        var refined = correction.text
        if let refiner {
            let events = self.events
            let outcome = runBlocking {
                await refiner.refine(correction.text, interrupt: {
                    SessionController.interruptSignal(for: events.pollInterrupt())
                })
            }
            refined = outcome.text
            aiOutcome = outcome.outcome
        }
        let tAi = MonotonicClock.now()
        // Refine was the last cancellable stage; stop emitting Esc now.
        gate?.setRecording(false)

        let text = PostProcess.process(refined,
                                       options: config.postProcessOptions(),
                                       corrections: corrections)
        let tPost = MonotonicClock.now()

        // An Esc pressed WHILE we were finalizing/refining means the user wants
        // to abort — honor it before inserting.
        if aiOutcome == .cancelled || events.drainCancel() {
            setState(.idle)
            pill?.hide()
            return
        }

        guard !text.isEmpty else {
            setState(.idle)
            // A pure spelling directive ("Actually, it's S-H-A-R-I-Q-U-E")
            // legitimately leaves nothing to insert: the whole utterance WAS
            // the directive. Learn it and flash "Learned Sharique" — flashing
            // "nothing recognized" would call a successful correction a failure.
            if correction.learn != nil || correction.notice != nil {
                completeCorrection(correction)
                if correction.notice == nil { pill?.hide() }
                // CONTRACT-DEVIATION: a fourth `outcome` value beyond
                // paste|type|blocked_secure|error|empty. Logging this as
                // "empty" would inflate the existing empty-rate metric (50/285
                // utterances in the Python era) with successful corrections.
                writeMetrics(heldMs: heldMs, result: result, postMs: 0, insertMs: 0,
                             outcome: "correction", releaseToTextMs: nil,
                             aiMs: (tAi - tAsr) * 1000.0, ai: aiOutcome.rawValue)
                return
            }
            flashError("nothing recognized")
            writeMetrics(heldMs: heldMs, result: result, postMs: 0, insertMs: 0,
                         outcome: "empty", releaseToTextMs: nil,
                         aiMs: (tAi - tAsr) * 1000.0, ai: aiOutcome.rawValue)
            return
        }

        // History first — a failed insert must never lose words.
        history.add(text: text, engine: result.engine, durationMs: heldMs)

        setState(.inserting)
        let insertion = inserter.insert(text)
        let tInsert = MonotonicClock.now()

        if insertion.ok {
            pill?.flashSuccess()
        } else if insertion.method == .blockedSecure {
            flashError("secure field — press ⌘⌃V to paste")
        } else {
            flashError(insertion.detail.isEmpty ? "insert failed" : insertion.detail)
        }

        writeMetrics(heldMs: heldMs, result: result,
                     postMs: (tPost - tAi) * 1000.0,
                     insertMs: (tInsert - tPost) * 1000.0,
                     outcome: insertion.method.rawValue,
                     releaseToTextMs: (tInsert - tRelease) * 1000.0,
                     aiMs: (tAi - tAsr) * 1000.0,
                     ai: aiOutcome.rawValue)
        setState(.idle)

        // Strictly off the paste path: dictionary writes and the vocabulary
        // reconciliation pass cost hundreds of ms and must never delay text.
        completeCorrection(correction)
    }

    private func abort(reason: String) {
        gate?.setRecording(false)
        stopLevelTicker()
        audio.stop()
        runBlocking { [asr] in await asr.cancel() }
        cancelRefiner()
        setState(.idle)
        if reason == "esc" || reason == "cancelled" {
            pill?.hide()
        } else {
            flashError(reason)
        }
    }

    // MARK: - paste-last recovery

    /// Thread-safe entry point used by the menu: enqueue a paste-last so it runs
    /// serialized on the session thread, never concurrently with a dictation.
    public func requestPasteLast() {
        events.put(HotkeyEvent(.pasteLast))
    }

    /// Re-insert the most recent transcript (⌘⌃V / menu) — the recovery path
    /// for a paste that failed the first time.
    public func pasteLast() {
        guard let text = history.lastText(), !text.isEmpty else {
            flashError("no transcript to paste")
            return
        }
        let insertion = inserter.insert(text)
        if insertion.ok {
            pill?.flashSuccess()
        } else if insertion.method == .blockedSecure {
            flashError("secure field — can't paste here")
        } else {
            flashError(insertion.detail.isEmpty ? "paste failed" : insertion.detail)
        }
    }

    // MARK: - helpers

    /// `HotkeyInterrupt` → `InterruptSignal`, a 1:1 case map. The two types
    /// exist separately because `WispritMacInput` depends only on `WispritKit`
    /// and cannot name `WispritRefine`'s.
    static func interruptSignal(for interrupt: HotkeyInterrupt) -> InterruptSignal {
        switch interrupt {
        case .none: return .none
        case .cancel: return .cancel
        case .hurry: return .hurry
        }
    }

    private func cancelRefiner() {
        guard let refiner else { return }
        runBlocking { await refiner.cancel() }
    }

    /// The learn + notice + reconciliation tail of a corrected utterance.
    /// Internal so tests can assert it without a detached task.
    func completeCorrection(_ correction: CorrectionOutcome) {
        if let learned = correction.learn {
            vocabulary?.add(learned)
            vocabulary?.recordUse(term: learned.term)
        }
        if let notice = correction.notice {
            pill?.transientNotice(notice)
        }
        guard config.reconcileVocabulary else { return }
        let asr = self.asr
        let vocabulary = self.vocabulary
        Task.detached(priority: .utility) {
            guard let reconciliation = await asr.reconcileVocabulary() else { return }
            for (term, hits) in reconciliation.termHits where hits > 0 {
                vocabulary?.recordUse(term: term)
            }
        }
    }

    private func flashError(_ message: String) {
        log.warning("utterance error: \(message, privacy: .public)")
        pill?.flashError(message)
    }

    private func setState(_ newState: State) {
        lock.lock()
        stateValue = newState
        let observer = stateObserver
        lock.unlock()
        observer?(newState)
    }

    private func setPressTimestamp(_ value: Double) {
        lock.lock(); pressTimestampValue = value; lock.unlock()
    }

    private func setPreviousUtterance(_ value: String) {
        lock.lock(); previousUtterance = value; lock.unlock()
    }

    private func writeMetrics(heldMs: Double, result: UtteranceResult,
                              postMs: Double, insertMs: Double, outcome: String,
                              releaseToTextMs: Double?, aiMs: Double?, ai: String?) {
        metrics.write(MetricsRecord(
            heldMs: heldMs,
            engine: result.engine,
            finalizeMs: result.finalizeMs,
            timedOut: result.timedOut,
            postMs: postMs,
            insertMs: insertMs,
            outcome: outcome,
            // `chars` counts the RAW ASR text, exactly as session.py does, so
            // the field stays comparable across the Python→Swift cutover.
            chars: result.text.count,
            releaseToTextMs: releaseToTextMs,
            aiMs: aiMs,
            ai: ai))
    }

    // MARK: - level ticker

    private func startLevelTicker() {
        guard let interval = config.levelTickInterval else { return }
        levelStop.reset()
        let thread = Thread { [weak self] in
            guard let self else { return }
            while !self.levelStop.wait(interval) {
                self.pill?.updateLevel(self.audio.level)
            }
        }
        thread.name = "pill-level"
        thread.start()
    }

    private func stopLevelTicker() {
        levelStop.signal()
    }
}
