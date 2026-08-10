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
    /// Rungs 1–2 of the insertion ladder. nil = Phase-1 behaviour: the pill shows
    /// the live tail and the text is pasted at the end.
    private let liveTyping: (any LiveTypingPort)?
    private let config: Configuration

    private let lock = NSLock()
    private var stateValue: State = .idle
    private var pressTimestampValue: Double = 0
    /// The previous utterance's RAW final — the antecedent window for a
    /// cross-utterance spoken-spelling correction.
    private var previousUtterance: String = ""
    private var deferredWork: DeferredWork?

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
                liveTyping: (any LiveTypingPort)? = nil,
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
        self.liveTyping = liveTyping
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
        liveTyping?.shutdown()
    }

    /// The worker loop. Public so a caller can run it on a thread it owns.
    public func run() {
        log.info("session loop started")
        while !stopFlag.isSignalled {
            guard let event = events.get(timeout: config.pollTimeout) else {
                // The idle sweep rides the existing 0.25 s poll rather than
                // spawning a timer: it only ever has to notice that a whole
                // idle timeout has gone by.
                liveTyping?.tickIdle()
                drainDeferred()
                continue
            }
            dispatch(event)
        }
    }

    // MARK: - deferred work

    /// One piece of work parked for the next idle moment.
    ///
    /// The Phase-3 retro-correction pass is what this exists for: the vocabulary
    /// channel finishes 0.5–2.5 s after insertion, and the edit it wants to make
    /// goes through the input method, which this state machine owns. Running it
    /// from the detached reconcile task would race whatever the user is doing by
    /// then, so it is parked and drained from the run loop instead — which is
    /// also what keeps it serialized with every other IM call.
    struct DeferredWork: Sendable {
        /// Log/test label; never shown to the user.
        var label: String
        var action: @Sendable () -> Void
    }

    /// Park work for the next idle tick. Deliberately a single slot: a second
    /// enqueue REPLACES the first, because the newer reconciliation is the
    /// better one and a queue of stale edits is worse than none.
    func enqueueDeferred(_ label: String, _ action: @escaping @Sendable () -> Void) {
        lock.lock()
        let replaced = deferredWork?.label
        deferredWork = DeferredWork(label: label, action: action)
        lock.unlock()
        if let replaced {
            log.info("deferred \(replaced, privacy: .public) replaced by \(label, privacy: .public)")
        }
    }

    /// Run the parked work, but only from IDLE: an edit computed for the last
    /// utterance must never land in the middle of the next one.
    func drainDeferred() {
        guard state == .idle else { return }
        lock.lock()
        let work = deferredWork
        deferredWork = nil
        lock.unlock()
        guard let work else { return }
        log.info("deferred \(work.label, privacy: .public) running")
        work.action()
    }

    /// Throw away parked work. A new utterance invalidates it outright — by the
    /// time this one ends, the document the edit was planned against is gone.
    private func dropDeferred() {
        lock.lock()
        let dropped = deferredWork?.label
        deferredWork = nil
        lock.unlock()
        if let dropped {
            log.info("deferred \(dropped, privacy: .public) dropped — new utterance")
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
        dropDeferred()

        // Hot-reload the dictionary on key-down so an edit lands on the very
        // next utterance without a restart. Cheap (an mtime stat).
        _ = vocabulary?.maybeReload()

        setPressTimestamp(timestamp)
        guard audio.start() else {
            flashError("microphone unavailable")
            return
        }

        // Pick the insertion rung before a single word exists: on rung 1 the
        // input source is selected here, while the user is still drawing breath,
        // so the first partial has somewhere to land.
        let tier = liveTyping?.beginUtterance() ?? .paste
        if tier.usesInputMethod {
            log.info("insertion tier \(tier.rawValue, privacy: .public) for this utterance")
        }

        // begin() carries the analyzer's prepareToAnalyze (31–54 ms measured);
        // the sub-400 ms finalize budget depends on paying it here, on key-down.
        let pill = self.pill
        let live = self.liveTyping
        runBlocking { [asr] in
            await asr.begin(onPartial: { text in
                // The pill bubble is the feedback for every rung that CANNOT put
                // provisional text in the field. When rung 1 is actually
                // streaming, showing it too would print the same words twice —
                // and the check is live, so losing the client mid-utterance hands
                // the preview straight back to the pill.
                if let live, live.isStreaming {
                    live.streamPartial(text)
                } else {
                    pill?.livePartial(text)
                }
            })
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
            endLiveUtterance(discardingTail: true)
            setState(.idle)
            pill?.hide()
            return
        }

        setState(.finalizing)
        pill?.showFinalizing()

        let tRelease = MonotonicClock.now()
        audio.stop()
        let result = runBlocking { [asr] in await asr.finalize() }
        // Snapshot the utterance's audio HERE, on the session thread, while no
        // other utterance can exist: every off-path consumer gets this value, so
        // a slow pass can never be handed the NEXT utterance's bytes.
        let retained = asr.lastRetained
        let audioMs = retained.durationSeconds * 1000.0
        let tAsr = MonotonicClock.now()

        // An Esc during a slow finalize aborts — check before paying for AI
        // cleanup. The hotkey keeps emitting Esc until AFTER the refine stage:
        // it is the longest window in the pipeline and must stay cancellable.
        if events.drainCancel() {
            gate?.setRecording(false)
            cancelRefiner()
            endLiveUtterance(discardingTail: true)
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
        var correction = CorrectionApplier.apply(action, to: raw)
        setPreviousUtterance(raw)

        // Cross-utterance retro-replace: the wrong word is already in the user's
        // document. On rungs 3–5 that is the end of it — learn the term, flash
        // "Learned Sharique", leave their text alone. On rungs 1–2 the input
        // method still owns the run it committed, so the fix is real: it re-reads
        // the live document and aborts unless our text is still exactly where we
        // left it (`RetroEditPlanner`), which is what stops a stale offset from
        // mangling a sentence the user has since typed into.
        if correction.wasCrossUtterance, case .retroReplace(let target, let replacement, _, _) = action {
            correction.notice = applyRetroEdit(target: target, replacement: replacement)
                ?? correction.notice
        }

        // Apple Intelligence refinement (prewarmed at record start). Any
        // failure/skip returns the verbatim text — never blocks insertion. The
        // interrupt hook lets Esc abort mid-generation (~100 ms) and lets a
        // queued fn-press finish the stage instantly with verbatim text.
        var aiOutcome = RefineOutcome.off
        var refined = correction.text
        var refineDelta: Int?
        if let refiner {
            let events = self.events
            let corrected = correction.text
            let outcome = runBlocking {
                await refiner.refine(corrected, interrupt: {
                    SessionController.interruptSignal(for: events.pollInterrupt())
                })
            }
            refined = outcome.text
            aiOutcome = outcome.outcome
            refineDelta = SessionController.refineDelta(raw: raw, refined: refined)
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
            endLiveUtterance(discardingTail: true)
            setState(.idle)
            pill?.hide()
            return
        }

        guard !text.isEmpty else {
            // Nothing to commit — take the provisional tail back down so the
            // field is left exactly as the user found it.
            endLiveUtterance(discardingTail: true)
            setState(.idle)
            // A pure spelling directive ("Actually, it's S-H-A-R-I-Q-U-E")
            // legitimately leaves nothing to insert: the whole utterance WAS
            // the directive. Learn it and flash "Learned Sharique" — flashing
            // "nothing recognized" would call a successful correction a failure.
            if correction.learn != nil || correction.notice != nil {
                completeCorrection(correction, retained: retained)
                if correction.notice == nil { pill?.hide() }
                // CONTRACT-DEVIATION: a fourth `outcome` value beyond
                // paste|type|blocked_secure|error|empty. Logging this as
                // "empty" would inflate the existing empty-rate metric (50/285
                // utterances in the Python era) with successful corrections.
                writeMetrics(heldMs: heldMs, result: result, postMs: 0, insertMs: 0,
                             outcome: "correction", releaseToTextMs: nil,
                             aiMs: (tAi - tAsr) * 1000.0, ai: aiOutcome.rawValue,
                             audioMs: audioMs, refineDelta: refineDelta)
                return
            }
            // Split the one indistinguishable `outcome=empty` row into the
            // reasons the 2026-08-05 incident needed and could not get — and
            // tell the user the right thing while we are at it: a microphone
            // that delivered nothing and a hold nobody spoke into are not the
            // same problem, and only one of them is ours.
            let reason = EmptyReason.classify(result: result, heldMs: heldMs)
            flashEmpty(reason)
            writeMetrics(heldMs: heldMs, result: result, postMs: 0, insertMs: 0,
                         outcome: "empty", releaseToTextMs: nil,
                         aiMs: (tAi - tAsr) * 1000.0, ai: aiOutcome.rawValue,
                         audioMs: audioMs, emptyReason: reason, refineDelta: refineDelta)
            return
        }

        // History first — a failed insert must never lose words.
        history.add(text: text, engine: result.engine, durationMs: heldMs)

        setState(.inserting)
        let insertion = deliver(text)
        let tInsert = MonotonicClock.now()

        if insertion.ok {
            pill?.flashSuccess()
        } else if insertion.blockedSecure {
            flashError("secure field — press ⌘⌃V to paste")
        } else {
            flashError(insertion.detail.isEmpty ? "insert failed" : insertion.detail)
        }

        writeMetrics(heldMs: heldMs, result: result,
                     postMs: (tPost - tAi) * 1000.0,
                     insertMs: (tInsert - tPost) * 1000.0,
                     outcome: insertion.outcome,
                     releaseToTextMs: (tInsert - tRelease) * 1000.0,
                     aiMs: (tAi - tAsr) * 1000.0,
                     ai: aiOutcome.rawValue,
                     audioMs: audioMs,
                     refineDelta: refineDelta)
        setState(.idle)

        // Strictly off the paste path: dictionary writes and the vocabulary
        // reconciliation pass cost hundreds of ms and must never delay text.
        completeCorrection(correction, retained: retained)
    }

    private func abort(reason: String) {
        gate?.setRecording(false)
        stopLevelTicker()
        audio.stop()
        runBlocking { [asr] in await asr.cancel() }
        cancelRefiner()
        endLiveUtterance(discardingTail: true)
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

    // MARK: - insertion ladder

    /// What one delivery attempt produced, whichever rung served it.
    struct Delivery: Equatable {
        var ok: Bool
        /// `metrics.log`'s `outcome` field: `im_streaming` / `im_commit` /
        /// `paste` / `type` / `blocked_secure` / `error`.
        var outcome: String
        var detail: String
        var blockedSecure: Bool
    }

    /// Walk the ladder for real. Rungs 1–2 first when the input method holds a
    /// live client, then the existing `Inserter` cascade, which stays the
    /// authority on rungs 3–5 — it re-checks Secure Input and AX trust at the
    /// moment of insertion, both of which can change between key-down and here.
    ///
    /// A rung-1/2 refusal falls through to paste rather than failing: the text
    /// was never delivered (the transport says so explicitly), and history was
    /// written before any of this, so the worst case is still ⌘⌃V.
    func deliver(_ text: String) -> Delivery {
        if let live = liveTyping, live.isEngaged {
            switch live.commit(text) {
            case .committed(let tier):
                live.endUtterance()
                return Delivery(ok: true, outcome: tier.rawValue, detail: "", blockedSecure: false)
            case .fallback(let reason):
                log.info("live typing declined (\(reason, privacy: .public)) — pasting")
            }
        }
        endLiveUtterance(discardingTail: true)
        let insertion = inserter.insert(text)
        return Delivery(ok: insertion.ok,
                        outcome: insertion.method.rawValue,
                        detail: insertion.detail,
                        blockedSecure: insertion.method == .blockedSecure)
    }

    /// Route a cross-utterance `retroReplace` through the input method. Returns
    /// the pill notice to use, or nil to keep the learn-only one.
    func applyRetroEdit(target: String, replacement: String) -> String? {
        guard let live = liveTyping, live.isEngaged else { return nil }
        guard let result = live.applyRetroEdit(replace: target, with: replacement) else { return nil }
        guard result.ok else {
            log.info("""
                retro edit \(target, privacy: .public) → \(replacement, privacy: .public) \
                declined: \(result.detail.rawValue, privacy: .public)
                """)
            return nil
        }
        return "Fixed \(replacement)"
    }

    /// Close out the input method's share of this utterance.
    private func endLiveUtterance(discardingTail: Bool) {
        guard let live = liveTyping else { return }
        if discardingTail { live.discardTail() }
        live.endUtterance()
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
    ///
    /// `retained` is the audio snapshotted at finalize, passed by value: the
    /// pass below can still be running when the next utterance starts, and it
    /// must keep transcribing the one it was spawned for.
    func completeCorrection(_ correction: CorrectionOutcome, retained: RetainedUtterance) {
        if let learned = correction.learn {
            if correction.learnIsPending {
                // Quarantined: recorded, excluded from corrections and biasing
                // until a second observation (or the user) confirms it.
                vocabulary?.addPending(term: learned.term,
                                       observation: learned.heard.first ?? "")
            } else {
                vocabulary?.add(learned)
                vocabulary?.recordUse(term: learned.term)
            }
        }
        if let notice = correction.notice {
            pill?.transientNotice(notice)
        }
        guard config.reconcileVocabulary else { return }
        let asr = self.asr
        let vocabulary = self.vocabulary
        Task.detached(priority: .utility) {
            guard let reconciliation = await asr.reconcileVocabulary(retained) else { return }
            for (term, hits) in reconciliation.termHits where hits > 0 {
                vocabulary?.recordUse(term: term)
            }
        }
    }

    private func flashError(_ message: String) {
        log.warning("utterance error: \(message, privacy: .public)")
        pill?.flashError(message)
    }

    /// Pill copy for an utterance that produced nothing. "nothing recognized"
    /// used to be the answer to every one of these, which told the user with a
    /// muted microphone exactly what it told the user who never spoke.
    private func flashEmpty(_ reason: EmptyReason?) {
        switch reason {
        case .starved:
            flashError("Microphone delivered no audio")
        case .silent:
            flashError("Didn't hear anything — is the right mic selected?")
        case .shortHold:
            // A fumbled tap is a coaching moment, not a failure — the notice is
            // the pill's non-error styling.
            pill?.transientNotice("Hold the key while you speak")
        case .timedOut, .crashed, .producedNothing, .none:
            flashError("nothing recognized")
        }
    }

    /// `refine_delta`: how many characters the model moved. The over-rewrite
    /// alarm — a verbatim-first refiner that rewrites a third of an utterance is
    /// not polishing it. Character Levenshtein is the cheap proxy; a novel-length
    /// dictation falls back to the length difference rather than paying the
    /// quadratic on a path that runs once per utterance.
    static func refineDelta(raw: String, refined: String) -> Int {
        guard raw != refined else { return 0 }
        let cap = 2_000
        guard raw.count <= cap, refined.count <= cap else {
            return abs(refined.count - raw.count)
        }
        return StringMetrics.levenshtein(raw, refined)
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
                              releaseToTextMs: Double?, aiMs: Double?, ai: String?,
                              audioMs: Double, emptyReason: EmptyReason? = nil,
                              refineDelta: Int? = nil) {
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
            ai: ai,
            emptyReason: emptyReason?.rawValue,
            // Every row, not just the empty ones: the level is only readable as
            // a threshold once there are rows on both sides of it.
            peakLevel: Double(result.peakLevel),
            audioMs: audioMs,
            // Deliberately the same count as `chars` — `chars` keeps its Python
            // meaning, `raw_chars` names it for the post-Python schema so a
            // later reader never has to guess which side of refine it is on.
            rawChars: result.text.count,
            refineDelta: refineDelta))
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
