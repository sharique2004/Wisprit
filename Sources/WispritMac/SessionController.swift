import Foundation
import WispritCorrections
import WispritEngine
import WispritKit
import WispritMacInput
import WispritPersistence
import WispritPostProcess
import WispritRefine

/// The one config key retro-correction adds.
///
/// Read through `Settings`' generic string-keyed accessors for the same reason
/// `LiveTypingSettings` is: `Settings.defaults` is golden-pinned, the settings
/// file preserves keys it does not know about, and a config written by either
/// build round-trips intact.
public enum VocabularyRetroSettings {
    /// `vocabulary_retro` — on by default. The reconciliation pass already runs;
    /// this decides whether its findings are allowed to touch the document.
    public static let enabledKey = "vocabulary_retro"

    public static func isEnabled(_ settings: Settings) -> Bool {
        settings.bool(enabledKey, or: true)
    }

    public static func setEnabled(_ settings: Settings, _ value: Bool) {
        settings.set(enabledKey, value)
    }
}

/// `keyup_grace_ms` — how long the microphone stays open after key-up.
///
/// The number, in one place. `SessionController.Configuration.releaseGrace` is
/// the knob the state machine reads; this is where the app's value for it comes
/// from, so the grace has a single definition instead of a literal at the
/// wiring site. Same string-keyed accessor pattern as `VocabularyRetroSettings`
/// above: `Settings.defaults` stays golden-pinned and a config written by either
/// build round-trips intact.
///
/// 120 ms is not arbitrary: the tap is installed at 100 ms granularity, so at
/// key-up a uniformly distributed 0–100 ms of already-captured hardware audio is
/// sitting in it undelivered, and `MicCapture.stop()` used to throw that away
/// along with the resampler's 15 ms tail. 120 ms covers the whole tap window
/// with margin; the resampler tail is recovered by `PcmDownconverter.flush()`
/// and no longer needs grace at all. Read at wiring time (like
/// `levelTickInterval` and `History.detailEnabled`), so an edit takes effect on
/// the next launch. Clamped to 500 ms by the session, whatever the file says.
public enum KeyupGraceSettings {
    public static let key = "keyup_grace_ms"
    public static let defaultMs = 120

    public static func milliseconds(_ settings: Settings) -> Int {
        settings.int(key, or: defaultMs)
    }

    public static func seconds(_ settings: Settings) -> TimeInterval {
        Double(milliseconds(settings)) / 1000.0
    }
}

/// `input_device_policy` — what to do about a narrowband Bluetooth microphone.
///
/// * `warn` (default) — one pill notice the first time such a device appears.
/// * `prefer_builtin` — additionally pin capture to the built-in mic while the
///   default input is a narrowband classic-BT one.
/// * `off` — say nothing, pin nothing.
///
/// Advisory by default on purpose: the user chose that headset, and a dictation
/// tool that silently overrides the system input device is worse than one that
/// mentions the trade-off once.
public enum InputDevicePolicySettings: String, CaseIterable, Sendable {
    case warn, preferBuiltin = "prefer_builtin", off

    public static let key = "input_device_policy"

    public static func policy(_ settings: Settings) -> InputDevicePolicySettings {
        InputDevicePolicySettings(rawValue: settings.string(key, or: warn.rawValue)) ?? .warn
    }
}

/// `history_detail` — whether the per-utterance pipeline triple
/// (`utterance_detail`) is written alongside each transcript. Same string-key
/// precedent as above; default TRUE because a triple is the same sensitivity
/// class as the final text `transcripts` already stores. Honored at the wiring
/// site: `History` takes it as a constructor parameter, so flipping the key
/// takes effect at the next launch, never mid-store.
public enum HistoryDetailSettings {
    public static let enabledKey = "history_detail"

    public static func isEnabled(_ settings: Settings) -> Bool {
        settings.bool(enabledKey, or: true)
    }

    public static func setEnabled(_ settings: Settings, _ value: Bool) {
        settings.set(enabledKey, value)
    }
}

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
        /// `filler_removal` / `ensure_sentence_period` / `leading_space` /
        /// `emoji_commands`.
        public var postProcessOptions: @Sendable () -> PostProcessOptions
        /// Pill level-meter cadence; nil disables the ticker entirely (tests,
        /// and `pill_hidden`). Python ran a 20 Hz `pill-level` thread.
        public var levelTickInterval: TimeInterval?
        /// Run the off-path DictationTranscriber vocabulary pass after each
        /// insertion. Off in tests: it spawns a detached task.
        public var reconcileVocabulary: Bool
        /// `vocabulary_retro` — let that pass retroactively fix a misheard
        /// dictionary term in the field. A closure, not a value, so the toggle
        /// takes effect on the very next utterance; the pass itself keeps
        /// running either way, because its `recordUse` bookkeeping is useful
        /// even when the document is left alone.
        public var vocabularyRetro: @Sendable () -> Bool
        /// `self._events.get(timeout=0.25)` in the Python run loop.
        public var pollTimeout: TimeInterval
        /// Voice-triggered snippet expansion (Flow Snippets). Identity by
        /// default so tests that never constructed a store stay verbatim.
        public var expandSnippets: @Sendable (String) -> String
        /// "my email" → the configured address, but only when the phrase hands
        /// the value over. Identity by default, like `expandSnippets`.
        ///
        /// A SEPARATE closure rather than a composition inside `expandSnippets`
        /// so the ORDER is a fact this file states and a test can pin: snippets
        /// run first, which is the whole of the precedence rule — a
        /// user-authored snippet is an explicit unconditional override and
        /// consumes the phrase before the conditional identity gate sees it.
        public var expandIdentity: @Sendable (String) -> String
        /// How long to keep the mic open after key-up so the in-flight
        /// ~100 ms tap and resampler tail are not discarded. Zero in tests
        /// (and the default) so the state machine stays instantaneous;
        /// the app sets it from `KeyupGraceSettings` (~120 ms).
        ///
        /// Spent in ≤20 ms slices that keep watching the event queue, never as
        /// one blocking sleep: Esc must still abort inside the grace, and a
        /// queued press must still be able to cut it short.
        public var releaseGrace: TimeInterval
        /// One line about the input device, or nil — shown once per device
        /// appearance, never per utterance. nil by default, so no wiring that
        /// omits it ever says anything.
        public var inputWarning: @Sendable () -> String?
        /// The system input volume as a percentage, ONCE per device, and only
        /// when it is low enough to be worth saying (2026-08-15). Consulted
        /// solely on a marginal-audio miss — the one moment the number explains
        /// something — and read-only: nothing in Wisprit sets the slider.
        /// nil by default, exactly like `inputWarning`.
        public var inputVolumeAdvisory: @Sendable () -> Int?

        public init(holdDebounceMs: @escaping @Sendable () -> Double = { 150 },
                    isEnabled: @escaping @Sendable () -> Bool = { true },
                    postProcessOptions: @escaping @Sendable () -> PostProcessOptions = { PostProcessOptions() },
                    levelTickInterval: TimeInterval? = 0.05,
                    reconcileVocabulary: Bool = true,
                    vocabularyRetro: @escaping @Sendable () -> Bool = { true },
                    pollTimeout: TimeInterval = 0.25,
                    expandSnippets: @escaping @Sendable (String) -> String = { $0 },
                    expandIdentity: @escaping @Sendable (String) -> String = { $0 },
                    releaseGrace: TimeInterval = 0,
                    inputWarning: @escaping @Sendable () -> String? = { nil },
                    inputVolumeAdvisory: @escaping @Sendable () -> Int? = { nil }) {
            self.holdDebounceMs = holdDebounceMs
            self.isEnabled = isEnabled
            self.postProcessOptions = postProcessOptions
            self.levelTickInterval = levelTickInterval
            self.reconcileVocabulary = reconcileVocabulary
            self.vocabularyRetro = vocabularyRetro
            self.pollTimeout = pollTimeout
            self.expandSnippets = expandSnippets
            self.expandIdentity = expandIdentity
            self.releaseGrace = releaseGrace
            self.inputWarning = inputWarning
            self.inputVolumeAdvisory = inputVolumeAdvisory
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
    /// Phase-4 context awareness. nil = no capture cycle ever runs — the exact
    /// behaviour of every build before the feature existed, and of every build
    /// where the consent flag stays off.
    private let context: (any ContextPort)?
    /// Phase-5 edit observation, paste-rung half: the next utterance's context
    /// snapshot diffed against what this one pasted. nil = the fallback never
    /// runs; the IM rung's observation channel is wired elsewhere and is not
    /// affected.
    private let editObserver: (any EditObservingPort)?
    /// R11 sound cues — mic-open and commit. nil = silent, the pre-cue
    /// behaviour of every earlier build and of every test harness.
    private let sound: (any SoundPort)?
    private let config: Configuration

    private let lock = NSLock()
    private var stateValue: State = .idle
    private var pressTimestampValue: Double = 0
    /// The previous utterance's RAW final — the antecedent window for a
    /// cross-utterance spoken-spelling correction.
    private var previousUtterance: String = ""
    /// What the previous utterance delivered and by which rung — the paste-rung
    /// edit observation's "ours" side. Consumed (one shot) at the next finalize.
    private var lastDelivery: (text: String, outcome: String)?
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
                context: (any ContextPort)? = nil,
                editObserver: (any EditObservingPort)? = nil,
                sound: (any SoundPort)? = nil,
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
        self.context = context
        self.editObserver = editObserver
        self.sound = sound
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
        /// Runs when the work is discarded instead of drained — a new utterance
        /// dropping it, or a newer plan replacing it. Telemetry only: the hook
        /// that keeps a parked proposal from vanishing without a metrics row.
        var onDrop: (@Sendable () -> Void)?
    }

    /// Park work for the next idle tick. Deliberately a single slot: a second
    /// enqueue REPLACES the first, because the newer reconciliation is the
    /// better one and a queue of stale edits is worse than none.
    func enqueueDeferred(_ label: String, onDrop: (@Sendable () -> Void)? = nil,
                         _ action: @escaping @Sendable () -> Void) {
        lock.lock()
        let replaced = deferredWork
        deferredWork = DeferredWork(label: label, action: action, onDrop: onDrop)
        lock.unlock()
        if let replaced {
            log.info("deferred \(replaced.label, privacy: .public) replaced by \(label, privacy: .public)")
            replaced.onDrop?()
        }
    }

    /// Label of the work currently parked, nil when the slot is empty. The
    /// reconciliation that fills it lands on a detached task, so this is how a
    /// test waits for it without sleeping on a guess.
    var deferredLabel: String? {
        lock.lock(); defer { lock.unlock() }
        return deferredWork?.label
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
        let dropped = deferredWork
        deferredWork = nil
        lock.unlock()
        if let dropped {
            log.info("deferred \(dropped.label, privacy: .public) dropped — new utterance")
            dropped.onDrop?()
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
        guard config.isEnabled() else {
            // Belt and braces for the R33 prestart: the hotkey hook checks the
            // same toggle, but it does so on another thread, so a press that
            // races the menu item off could leave a microphone running with no
            // utterance to own it. Idempotent — a stop with nothing to stop is
            // free.
            audio.stop()
            return
        }
        dropDeferred()

        // Hot-reload the dictionary on key-down so an edit lands on the very
        // next utterance without a restart. Cheap (an mtime stat).
        _ = vocabulary?.maybeReload()

        setPressTimestamp(timestamp)
        // Before the microphone opens, not after: `audio.start()` plus the
        // analyzer's prepareToAnalyze is tens of milliseconds in which the user
        // has pressed a key and seen nothing. The pill fades in grey and at
        // floor here, and turns orange on the first real level tick (§2.4).
        pill?.showPrewarming()
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

        // Context capture rides key-down too, AFTER the rung is picked so the
        // IM reader can name the session that just opened. One post or one
        // enqueue, then straight back — the answer races the utterance and is
        // consumed at finalize only if it won.
        context?.beginCapture()

        // begin() carries the analyzer's prepareToAnalyze (31–54 ms measured);
        // the sub-400 ms finalize budget depends on paying it here, on key-down.
        let pill = self.pill
        let live = self.liveTyping
        runBlocking { [asr] in
            await asr.begin(onPartial: { text in
                // Resolve "Thursday umm no actually Friday" HERE, once, before
                // the partial forks: both surfaces below are a preview of the
                // same words and must never disagree about them. `text` itself
                // is untouched — nothing downstream of this closure reads a
                // partial, so the raw final is still what finalize sees.
                let shown = LivePartialCorrection.display(text)
                // The pill bubble is the feedback for every rung that CANNOT put
                // provisional text in the field. When rung 1 is actually
                // streaming, showing it too would print the same words twice —
                // and the check is live, so losing the client mid-utterance hands
                // the preview straight back to the pill.
                if let live, live.isStreaming {
                    live.streamPartial(shown)
                } else {
                    pill?.livePartial(shown)
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
        // The mic-open cue rides the show-recording event, which this function
        // only reaches once `audio.start()` HAS succeeded — the orange rule in
        // a second sense: the cue may never claim a mic that did not open. For
        // a `pill_hidden` user this is the only "it's listening" signal.
        sound?.play(.micOpen)
        // AFTER `showRecording()`, never between `audio.start()` and it.
        // `PillModel.transientNotice` only keeps the pill alive on its
        // in-flight states (recording/finalizing/refining); issued from
        // `.prewarming` it flips the pill to `.success` — a green flash before
        // a word is spoken — and the `showRecording()` below would then wipe
        // the bubble, so the warning would never be seen at all. Here it lands
        // in the bubble exactly like the dead-mic cue.
        if let warning = config.inputWarning() {
            pill?.transientNotice(warning)
        }
        startLevelTicker()
    }

    private func finish(at timestamp: Double) {
        stopLevelTicker()
        let debounceMs = config.holdDebounceMs()
        let heldMs = (timestamp - pressTimestampValue) * 1000.0

        if heldMs < debounceMs {
            // Accidental brush — discard everything, write no metrics row.
            discardUtterance()
            return
        }

        setState(.finalizing)

        // The stamp is at TRUE release, before the grace: `release_to_text_ms`
        // must carry the grace honestly rather than hide it.
        let tRelease = MonotonicClock.now()
        // The last ~100 ms of speech is still sitting in the tap buffer
        // when the key comes up. A short grace lets that chunk (and the
        // speech the user is still finishing) reach the engine before the mic
        // goes dark. Debounce-abort and Esc above skip this on purpose.
        if awaitReleaseGrace() == .cancelled {
            // Esc inside the grace: the same discard the debounce branch runs,
            // and strictly faster than today's Esc-during-finalize path — the
            // utterance never reaches the analyzer at all.
            discardUtterance()
            return
        }
        // The pill only now says "finalizing": for the length of the grace the
        // microphone is still hot, and a frozen meter under a finalizing label
        // would be describing a state the session is not in yet.
        pill?.showFinalizing()
        audio.stop()
        // The capture session's acoustic telemetry, read once it is closed and
        // threaded onto every row this utterance writes: the (peak, floor)
        // pair maps live conditions onto the eval matrix's noise axis, and
        // `first_voiced_ms` is the clipping-exposure clock (R4).
        let noiseFloor = audio.noiseFloor
        let firstVoicedMs = audio.firstVoicedMs
        let result = runBlocking { [asr] in await asr.finalize() }
        // Snapshot the utterance's audio HERE, on the session thread, while no
        // other utterance can exist: every off-path consumer gets this value, so
        // a slow pass can never be handed the NEXT utterance's bytes.
        let retained = asr.lastRetained
        let audioMs = retained.durationSeconds * 1000.0
        let tAsr = MonotonicClock.now()

        // The context snapshot for THIS utterance, IF a reader answered in
        // time. A slot read, never a wait — finalize spends zero time on it,
        // and taking it here (before the Esc check) also guarantees the slot
        // is emptied on every exit from this function.
        let ctx = context?.finishCapture() ?? ContextOutcome()

        // Phase 5's paste-rung observation: that snapshot shows the field as it
        // read at THIS key-down — which is where the PREVIOUS utterance's pasted
        // text has been sitting since. One attempt per delivery, and consent-
        // gated by construction: `fieldText` only exists when context awareness
        // read a field at all.
        observeLastDelivery(against: ctx)

        // An Esc during a slow finalize aborts — check before paying for AI
        // cleanup. The hotkey keeps emitting Esc until AFTER the refine stage:
        // it is the longest window in the pipeline and must stay cancellable.
        if events.drainCancel() {
            gate?.setRecording(false)
            cancelRefiner()
            endLiveUtterance(discardingTail: true)
            setState(.idle)
            pill?.showIdle()
            return
        }

        // Spoken-spelling corrections run on the RAW final, before refine:
        // the model deterministically corrupts spelled runs
        // ("S-H-A-R-I-Q-U-E" → "Sharifue"). Refine's own letter-run bypass is
        // the safety net, not the detector.
        let raw = result.text
        let priorUtterance = previousUtterance
        let action = corrector?.decide(utterance: raw, previousUtterance: priorUtterance) ?? .none
        var correction = CorrectionApplier.apply(action, to: raw)
        setPreviousUtterance(raw)

        // Cross-utterance retro-replace: the wrong word is already in the user's
        // document. On rungs 3–5 that is the end of it — learn the term, flash
        // "Learned Sharique", leave their text alone. On rungs 1–2 the input
        // method still owns the run it committed, so the fix is real: it re-reads
        // the live document and aborts unless our text is still exactly where we
        // left it (`RetroEditPlanner`), which is what stops a stale offset from
        // mangling a sentence the user has since typed into.
        if correction.wasCrossUtterance, case .retroReplace(let target, let replacement, _, _) = action,
           case .applied(let notice) = applyRetroEdit(target: target, replacement: replacement) {
            correction.notice = notice
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
            // The pill says which stage is running: refine is the longest one in
            // the pipeline and the only one a user can mistake for a hang (§2.4).
            pill?.showRefining()
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

        var options = config.postProcessOptions()
        options.precedingText = ctx.precedingText ?? ""
        options.frontmostBundleID = ctx.bundleID ?? ""
        let processed = PostProcess.processResult(refined,
                                                 options: options,
                                                 corrections: corrections)
        // ORDER IS THE PRECEDENCE RULE, and it is load-bearing in both
        // directions. Snippets first: an explicit user-authored trigger is an
        // unconditional override and must win a collision with an identity
        // trigger, which it does by consuming the phrase — zero precedence
        // code. Identity last, i.e. after the WHOLE of PostProcess: the
        // address it splices in can then no longer be re-mangled by the
        // spoken-email/URL joiner, by `ensureSentencePeriod`, or by
        // `applyContextFit`'s `lowercaseOpening`. Reordering these two lines
        // silently flips both guarantees.
        var text = config.expandIdentity(config.expandSnippets(processed.text))
        // Follow-up "not a pet pill" after the wrong word is already in
        // the field: rewrite that word and swallow the cue, the same
        // shape as a spoken-spelling retro-replace.
        if let pair = SelfCorrection.standaloneNotCorrection(text),
           SelfCorrection.containsWord(pair.rejected, in: priorUtterance),
           case .applied(let notice) = applyRetroEdit(target: pair.rejected,
                                                      replacement: pair.replacement) {
            text = ""
            correction.notice = notice
        }
        let pressEnter = processed.pressEnter
        let tPost = MonotonicClock.now()

        // An Esc pressed WHILE we were finalizing/refining means the user wants
        // to abort — honor it before inserting.
        if aiOutcome == .cancelled || events.drainCancel() {
            endLiveUtterance(discardingTail: true)
            setState(.idle)
            pill?.showIdle()
            return
        }

        if text.isEmpty, pressEnter {
            endLiveUtterance(discardingTail: true)
            setState(.inserting)
            inserter.pressReturn()
            pill?.flashSuccess()
            sound?.play(.commit)
            writeMetrics(heldMs: heldMs, result: result, postMs: (tPost - tAi) * 1000.0,
                         insertMs: 0, outcome: "paste", releaseToTextMs: nil,
                         aiMs: (tAi - tAsr) * 1000.0, ai: aiOutcome.rawValue,
                         audioMs: audioMs, refineDelta: refineDelta, ctx: ctx,
                         noiseFloor: noiseFloor, firstVoicedMs: firstVoicedMs)
            setState(.idle)
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
                // Nothing was inserted, so there is nothing in the field for the
                // vocabulary pass to correct — it still runs, for `recordUse`.
                completeCorrection(correction, retained: retained,
                                   inserted: "", outcome: "correction",
                                   extraTerms: ctx.terms)
                if correction.notice == nil { pill?.showIdle() }
                // CONTRACT-DEVIATION: a fourth `outcome` value beyond
                // paste|type|blocked_secure|error|empty. Logging this as
                // "empty" would inflate the existing empty-rate metric (50/285
                // utterances in the Python era) with successful corrections.
                writeMetrics(heldMs: heldMs, result: result, postMs: 0, insertMs: 0,
                             outcome: "correction", releaseToTextMs: nil,
                             aiMs: (tAi - tAsr) * 1000.0, ai: aiOutcome.rawValue,
                             audioMs: audioMs, refineDelta: refineDelta, ctx: ctx,
                             noiseFloor: noiseFloor, firstVoicedMs: firstVoicedMs)
                return
            }
            // Split the one indistinguishable `outcome=empty` row into the
            // reasons the 2026-08-05 incident needed and could not get — and
            // tell the user the right thing while we are at it: a microphone
            // that delivered nothing and a hold nobody spoke into are not the
            // same problem, and only one of them is ours.
            let reason = EmptyReason.classify(result: result, heldMs: heldMs)
            flashEmpty(reason, peakLevel: result.peakLevel, noiseFloor: noiseFloor)
            writeMetrics(heldMs: heldMs, result: result, postMs: 0, insertMs: 0,
                         outcome: "empty", releaseToTextMs: nil,
                         aiMs: (tAi - tAsr) * 1000.0, ai: aiOutcome.rawValue,
                         audioMs: audioMs, emptyReason: reason, refineDelta: refineDelta,
                         ctx: ctx,
                         // The rows the floor pair exists to decompose: an
                         // empty with normal floor+peak is a finger slip; a
                         // sub-threshold peak over a real floor is quiet
                         // speech misfiled as silence (R26's evidence).
                         noiseFloor: noiseFloor, firstVoicedMs: firstVoicedMs)
            return
        }

        // History first — a failed insert must never lose words.
        let transcriptId = history.add(text: text, engine: result.engine, durationMs: heldMs)

        setState(.inserting)
        // R6, the feedback-inversion fix: the success flash (and commit cue)
        // fire from inside the delivery — on the paste rung that is right
        // after ⌘V and BEFORE the 500 ms clipboard-restore sleep, which stays
        // on this thread, after the flash, semantics unchanged. The checkmark
        // lands with the words instead of half a second behind them.
        var deliveredEarly = false
        let insertion = deliver(text) {
            self.pill?.flashSuccess()
            self.sound?.play(.commit)
            deliveredEarly = true
        }
        let tInsert = MonotonicClock.now()
        // When the text was actually in the field. Rungs without a stamp
        // (IM commit, a pre-hook port) deliver at return, where tInsert is it.
        let tText = insertion.deliveredAt ?? tInsert
        // The R6 one-line counter (§1.1-T5): a press still queued once the
        // restore window closes spent that window waiting behind it. This is
        // the number that would ever justify reviving R34 — as deferred
        // restore, never as a skip.
        let repressQueued = events.hasPendingPress

        if insertion.ok {
            if pressEnter { inserter.pressReturn() }
            if !deliveredEarly {
                pill?.flashSuccess()
                sound?.play(.commit)
            }
            // The device-switch case the empty-reason row CANNOT reach: the
            // engine stopped itself mid-hold, the prefix read cleanly, and the
            // user is about to accept a truncated sentence under a success
            // checkmark. The batch rescue cannot fix this one — the post-switch
            // audio was never captured, so there is nothing to re-read — which
            // makes saying so the entire remedy. Rides the same
            // post-delivery notice channel as "Learned X" below.
            if result.sawConfigurationChange {
                pill?.transientNotice("Mic changed mid-dictation — check for missing words")
            }
        } else if insertion.blockedSecure {
            // Its own pill state (§2.4): a lock rather than an alarm, held long
            // enough to read, because the text is safe in history and ⌘⌃V is a
            // remedy the user can still act on.
            log.warning("insertion blocked by Secure Keyboard Entry — text is in history")
            pill?.flashBlockedSecure()
        } else {
            flashError(insertion.detail.isEmpty ? "insert failed" : insertion.detail)
        }

        writeMetrics(heldMs: heldMs, result: result,
                     postMs: (tPost - tAi) * 1000.0,
                     // Through delivery only. The restore window is split out
                     // below — this is a METRIC CORRECTION, not a speedup
                     // (docs/notes/deviations.md records the discontinuity).
                     insertMs: (tText - tPost) * 1000.0,
                     outcome: insertion.outcome,
                     releaseToTextMs: (tText - tRelease) * 1000.0,
                     aiMs: (tAi - tAsr) * 1000.0,
                     ai: aiOutcome.rawValue,
                     audioMs: audioMs,
                     refineDelta: refineDelta,
                     ctx: ctx,
                     noiseFloor: noiseFloor,
                     firstVoicedMs: firstVoicedMs,
                     // Only the paste rung has a post-delivery custody window.
                     restoreMs: insertion.outcome == InsertResult.Method.paste.rawValue
                         ? insertion.deliveredAt.map { (tInsert - $0) * 1000.0 }
                         : nil,
                     repressQueued: repressQueued ? true : nil)
        setState(.idle)

        // The utterance's pipeline triple, keyed to the transcript row written
        // above — strictly off the paste path (the text has already landed).
        // The `vocab` column stays NULL here on purpose: the reconciliation
        // pass fills it seconds from now, through the update path below.
        history.addDetail(transcriptId: transcriptId,
                          raw: raw, corrected: correction.text, refined: refined,
                          inserted: insertion.ok ? text : "",
                          vocab: nil, ai: aiOutcome.rawValue, termsHit: [])

        // What the paste-rung observation will need at the NEXT finalize.
        setLastDelivery(insertion.ok ? (text, insertion.outcome) : nil)

        // Strictly off the paste path: dictionary writes and the vocabulary
        // reconciliation pass cost hundreds of ms and must never delay text.
        // `text` and `insertion.outcome` are passed by value because the retro
        // pass needs to know what went into the field and by which rung, and by
        // the time it finishes both may describe a different utterance.
        // `ctx.terms` travels the same way — one utterance's candidates, dead
        // when the pass returns.
        completeCorrection(correction, retained: retained,
                           inserted: insertion.ok ? text : "",
                           outcome: insertion.outcome,
                           extraTerms: ctx.terms,
                           transcriptId: transcriptId,
                           commitAnchor: insertion.ok ? insertion.commitAnchor : nil)
    }

    /// Throw this utterance away and return to idle, leaving no metrics row.
    ///
    /// The accidental-brush branch and the Esc-inside-the-grace branch are the
    /// same discard and must stay the same discard — including
    /// `context?.finishCapture()` and the live-typing tail, either of which
    /// leaking would carry a snapshot or a provisional run into the NEXT
    /// utterance.
    private func discardUtterance() {
        stopLevelTicker()
        gate?.setRecording(false)
        audio.stop()
        runBlocking { [asr] in await asr.cancel() }
        cancelRefiner()
        endLiveUtterance(discardingTail: true)
        // Drained and dropped: a snapshot must never outlive its utterance.
        _ = context?.finishCapture()
        setState(.idle)
        pill?.showIdle()
    }

    /// How a post-release grace ended.
    enum GraceOutcome: Equatable {
        /// The full grace elapsed (or there was none).
        case elapsed
        /// Esc/cancel arrived — the utterance is to be discarded.
        case cancelled
        /// A press is already queued; the next utterance outranks our tail.
        case preempted
    }

    /// Longest grace the session will honour, whatever `keyup_grace_ms` says.
    /// Every millisecond here is added to `release_to_text_ms` for EVERY
    /// utterance, so a fat-fingered config must not be able to make dictation
    /// feel broken.
    static let maxReleaseGrace: TimeInterval = 0.5

    /// Keep the microphone open briefly after key-up.
    ///
    /// Not one blocking sleep: the loop watches the event queue in ≤20 ms
    /// slices so Esc still aborts inside the grace (faster than it can today,
    /// where it has to wait out finalize), and so a re-press cuts the grace
    /// short rather than adding 120 ms to the next utterance's wait.
    @discardableResult
    func awaitReleaseGrace() -> GraceOutcome {
        let grace = min(max(config.releaseGrace, 0), SessionController.maxReleaseGrace)
        guard grace > 0 else { return .elapsed }
        let deadline = Date().addingTimeInterval(grace)
        while true {
            if events.drainCancel() { return .cancelled }
            if events.hasPendingPress { return .preempted }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return .elapsed }
            Thread.sleep(forTimeInterval: min(remaining, 0.02))
        }
    }

    private func abort(reason: String) {
        gate?.setRecording(false)
        stopLevelTicker()
        audio.stop()
        runBlocking { [asr] in await asr.cancel() }
        cancelRefiner()
        endLiveUtterance(discardingTail: true)
        // Aborted utterance, discarded snapshot — same rule as the tail above.
        _ = context?.finishCapture()
        setState(.idle)
        if reason == "esc" || reason == "cancelled" {
            pill?.showIdle()
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
        var deliveredEarly = false
        let insertion = inserter.insert(text) {
            // Same truth-in-feedback ordering as the main path (R6): the
            // checkmark rides the delivery, not the restore sleep behind it.
            self.pill?.flashSuccess()
            deliveredEarly = true
        }
        if insertion.ok {
            if !deliveredEarly { pill?.flashSuccess() }
        } else if insertion.method == .blockedSecure {
            // R9d: the same condition as the main path gets the same state —
            // the lock with the ⌘⌃V remedy, not an alarm styled differently.
            pill?.flashBlockedSecure()
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
        /// `MonotonicClock` stamp of the moment the text was in the field, when
        /// the serving rung reported one (the paste rung stamps it before its
        /// restore sleep). nil = delivery coincided with the return.
        var deliveredAt: Double? = nil
        /// Where this utterance's text starts inside the run its IM session
        /// committed, when rung 1/2 served it. nil on the paste path, where
        /// nothing in the field is ours to address. Carried BY VALUE for the
        /// same reason `inserted`/`outcome` are: by drain time `liveTyping`
        /// describes a different utterance.
        var commitAnchor: CommitAnchor? = nil
    }

    /// Walk the ladder for real. Rungs 1–2 first when the input method holds a
    /// live client, then the existing `Inserter` cascade, which stays the
    /// authority on rungs 3–5 — it re-checks Secure Input and AX trust at the
    /// moment of insertion, both of which can change between key-down and here.
    ///
    /// A rung-1/2 refusal falls through to paste rather than failing: the text
    /// was never delivered (the transport says so explicitly), and history was
    /// written before any of this, so the worst case is still ⌘⌃V.
    func deliver(_ text: String, onDelivered: () -> Void = {}) -> Delivery {
        if let live = liveTyping, live.isEngaged {
            switch live.commit(text) {
            case .committed(let tier):
                live.endUtterance()
                // The committed text IS the delivery on this rung and there is
                // no post-delivery window; notify and return in one breath.
                onDelivered()
                // Read before anything else can commit: this is where the chunk
                // we just wrote begins inside the session's run.
                return Delivery(ok: true, outcome: tier.rawValue, detail: "",
                                blockedSecure: false, commitAnchor: live.lastCommitAnchor)
            case .fallback(let reason):
                log.info("live typing declined (\(reason, privacy: .public)) — pasting")
            }
        }
        endLiveUtterance(discardingTail: true)
        let insertion = inserter.insert(text, onDelivered: onDelivered)
        return Delivery(ok: insertion.ok,
                        outcome: insertion.method.rawValue,
                        detail: insertion.detail,
                        blockedSecure: insertion.method == .blockedSecure,
                        deliveredAt: insertion.deliveredAtMonotonic)
    }

    /// One retro-edit attempt, as the metrics row will tell it: the pill notice
    /// when the edit landed, otherwise the `apply_detail` word for why it did
    /// not. The words are `IMEditDetail`'s raw values plus two sentinels of our
    /// own for the cases the input method was never asked — all stable, they
    /// land in `metrics.log` (the transcript-318 lesson: an os_log info line is
    /// memory-only and was gone by the time anyone looked).
    enum RetroEditAttempt: Equatable {
        case applied(notice: String)
        case declined(detail: String)
    }

    /// Route a cross-utterance `retroReplace` through the input method. On
    /// `.applied` the returned notice replaces the learn-only one.
    func applyRetroEdit(target: String, replacement: String,
                        utf16LocationInCommitted: Int? = nil,
                        anchorGeneration: UInt64? = nil) -> RetroEditAttempt {
        guard let live = liveTyping, live.isEngaged else {
            return .declined(detail: "not_engaged")
        }
        guard let result = live.applyRetroEdit(
                replace: target, with: replacement,
                utf16LocationInCommitted: utf16LocationInCommitted,
                anchorGeneration: anchorGeneration) else {
            // Silence (or a crossed `clientAcquired`): the edit cannot be
            // proven to have landed, which for the caller is a refusal.
            return .declined(detail: "no_reply")
        }
        guard result.ok else {
            log.info("""
                retro edit \(target, privacy: .public) → \(replacement, privacy: .public) \
                declined: \(result.detail.rawValue, privacy: .public)
                """)
            return .declined(detail: result.detail.rawValue)
        }
        return .applied(notice: "Fixed \(replacement)")
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
    /// must keep transcribing the one it was spawned for. `inserted` and
    /// `outcome` travel with it for exactly the same reason — the retro pass
    /// plans against the text THIS utterance put in the field, by the rung THIS
    /// utterance used, and both have moved on by the time it finishes.
    func completeCorrection(_ correction: CorrectionOutcome, retained: RetainedUtterance,
                            inserted: String = "", outcome: String = "",
                            extraTerms: [String] = [], transcriptId: Int64 = -1,
                            commitAnchor: CommitAnchor? = nil) {
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
        let history = self.history
        let planRetro = config.vocabularyRetro() && !inserted.isEmpty
        Task.detached(priority: .utility) { [weak self] in
            guard let reconciliation = await asr.reconcileVocabulary(retained,
                                                                     extraTerms: extraTerms)
            else { return }
            for (term, hits) in reconciliation.termHits where hits > 0 {
                vocabulary?.recordUse(term: term)
            }
            // The late `vocab` column: what the biased pass heard, attached to
            // the detail row ITS utterance wrote before this task started —
            // `transcriptId` rides by value for the same reason `retained` does.
            if transcriptId > 0 {
                history.updateDetail(transcriptId: transcriptId,
                                     vocab: reconciliation.transcript)
            }
            guard let self else { return }
            let plan = planRetro
                ? VocabularyReconciler.plan(
                    inserted: inserted,
                    reconciled: reconciliation.transcript,
                    termHits: reconciliation.termHits,
                    knownTerm: { vocabulary?.isKnownTerm($0) ?? false })
                : VocabularyRetroPlan()
            self.scheduleVocabularyRetro(plan, reconciliation: reconciliation, rung: outcome,
                                         commitAnchor: commitAnchor)
        }
    }

    /// `metrics.log`'s `outcome` for the two rungs that can still edit what they
    /// wrote.
    ///
    /// Judged on the delivery that actually happened — the `outcome` string
    /// travels by value into the retro pass — never on `liveTyping.tier`, which
    /// is live state and by drain time can already describe
    /// a different utterance in a different app. An utterance that was pasted
    /// must reach the learn-only fallback even if the input method has since
    /// come back, because the text in the field is no longer ours to touch.
    static func isInputMethodRung(_ outcome: String) -> Bool {
        outcome == InsertionTier.imStreaming.rawValue || outcome == InsertionTier.imCommit.rawValue
    }

    /// Park the plan for the next idle moment, or — when there is nothing to
    /// apply — close the books on it immediately.
    private func scheduleVocabularyRetro(_ plan: VocabularyRetroPlan,
                                         reconciliation: VocabularyReconciliation,
                                         rung: String,
                                         commitAnchor: CommitAnchor? = nil) {
        let hits = reconciliation.termHits.values.reduce(0, +)
        guard !plan.edits.isEmpty else {
            if let refusal = plan.refusal {
                log.info("vocab retro refused: \(refusal.rawValue, privacy: .public)")
            }
            writeVocabularyRetroMetrics(reconciliation: reconciliation, hits: hits,
                                        proposed: false, applied: false,
                                        rung: rung, refusal: plan.refusal)
            return
        }
        // A parked plan's row is written when its fate is known: at drain, or
        // right here at discard time — a proposal must never vanish silently.
        enqueueDeferred("vocab-retro", onDrop: { [weak self] in
            self?.writeVocabularyRetroMetrics(reconciliation: reconciliation, hits: hits,
                                              proposed: true, applied: false,
                                              rung: rung, applyDetail: "dropped")
        }) { [weak self] in
            self?.applyVocabularyRetro(plan, reconciliation: reconciliation, hits: hits,
                                       rung: rung, commitAnchor: commitAnchor)
        }
    }

    /// Drain-time half of retro-correction, on the session thread, at idle.
    ///
    /// Every edit is offered to the input method first and falls back to
    /// learning when that is refused — including, unconditionally, on the paste
    /// and type rungs, where the text has left our custody entirely. The
    /// fallback is deliberately narrower than it looks: `isKnownTerm` gates it,
    /// so it can only ever add a `hear` phrase to a term the user already has.
    /// It can never invent a canonical spelling out of a machine's guess.
    func applyVocabularyRetro(_ plan: VocabularyRetroPlan,
                              reconciliation: VocabularyReconciliation,
                              hits: Int,
                              rung: String,
                              commitAnchor: CommitAnchor? = nil) {
        let onInputMethodRung = SessionController.isInputMethodRung(rung)
        var fixed: String?
        var learned: String?
        var declined: String?
        // HIGHEST OFFSET FIRST. Every anchor is measured against the committed
        // record as it stood when the text landed; applying a lower-offset edit
        // first shifts everything after it whenever `replace` and `with` differ
        // in length, and the next anchor then names characters that have moved.
        // Walking backwards means no applied edit can invalidate an anchor that
        // has not been used yet. (`maxEdits` is 2, so this is one pair today —
        // stated anyway, because the reason does not depend on the cap.)
        for edit in plan.edits.sorted(by: { $0.utf16Location > $1.utf16Location }) {
            if onInputMethodRung {
                // Run-relative: where this utterance starts inside the session's
                // committed run, plus where the block sits inside this utterance.
                switch applyRetroEdit(target: edit.replace, replacement: edit.with,
                                      utf16LocationInCommitted: commitAnchor.map {
                                          $0.utf16Offset + edit.utf16Location
                                      },
                                      anchorGeneration: commitAnchor?.generation) {
                case .applied:
                    if fixed == nil { fixed = edit.with }
                    continue
                case .declined(let detail):
                    // The first refusal names the row, like the planner's
                    // `refusal` names the first gate that said no.
                    if declined == nil { declined = detail }
                }
            }
            if learnVocabularyEvidence(term: edit.with, heard: edit.replace), learned == nil {
                learned = edit.with
            }
        }
        // One notice per utterance, and the truthful one: "Fixed" only when the
        // user's document actually changed.
        if let fixed {
            pill?.transientNotice("Fixed \(fixed)")
        } else if let learned {
            pill?.transientNotice("Learned \(learned)")
        }
        // `apply_detail` only on a proposed-but-not-applied row that ATTEMPTED
        // an edit. On the paste/type rungs no edit is ever attempted and the
        // `rung` field is the whole explanation.
        writeVocabularyRetroMetrics(reconciliation: reconciliation, hits: hits,
                                    proposed: true, applied: fixed != nil,
                                    rung: rung,
                                    applyDetail: fixed == nil ? declined : nil)
    }

    /// Record the misrecognition against a term the dictionary ALREADY has.
    /// Returns false when it does not have it — in which case nothing at all is
    /// written, because a canonical term created from a second engine's opinion
    /// is exactly the pollution `LearnPlausibility` exists to prevent.
    private func learnVocabularyEvidence(term: String, heard: String) -> Bool {
        guard let vocabulary, vocabulary.isKnownTerm(term) else { return false }
        vocabulary.add(LearnedTerm(term: term, heard: [heard], source: "vocab_retro"))
        return true
    }

    /// The reference-less second line. See the note on `MetricsRecord`.
    private func writeVocabularyRetroMetrics(reconciliation: VocabularyReconciliation,
                                             hits: Int, proposed: Bool, applied: Bool,
                                             rung: String,
                                             refusal: VocabularyRetroRefusal? = nil,
                                             applyDetail: String? = nil) {
        metrics.write(MetricsRecord(
            heldMs: 0, engine: VocabularyChannel.engineName, finalizeMs: 0,
            timedOut: false, postMs: 0, insertMs: 0, outcome: "vocab_retro", chars: 0,
            vocabMs: reconciliation.elapsedMs, vocabHits: hits,
            vocabDelta: proposed ? 1 : 0, applied: applied,
            vocabRefusal: refusal?.rawValue,
            rung: rung.isEmpty ? nil : rung,
            applyDetail: applyDetail))
    }

    private func flashError(_ message: String) {
        log.warning("utterance error: \(message, privacy: .public)")
        pill?.flashError(message)
    }

    /// Copy for the utterance whose audio the room nearly swallowed, and the
    /// one honest thing this app can say about it.
    ///
    /// "Didn't catch that" is true of a silent hold and a lie here: the engine
    /// DID hear the user, the speech was 6–16 dB over the room, and no amount of
    /// gain — live, retroactive, or in the batch rescue — puts back what the
    /// microphone never separated (measured: normalizing the 14 dB rung recovers
    /// 0.26 pt of a 3.9 pt WER loss). Speaking up or moving closer is the whole
    /// remedy, and the copy names the one of the two that fits: the pill's
    /// alarm-state budget is 40 characters (`PillGeometry.errorMessageCharacters`
    /// — 2 × 12 pt inset + 40 × 6.5 pt of advance is the 288 pt cap), and a line
    /// the frame cuts in half would lose the remedy rather than the diagnosis.
    static let tooQuietMessage = "Heard you, but too faint — speak up"

    /// The same miss when the system input slider is the readiest lever. Names
    /// the number because that is what makes it findable in System Settings —
    /// and REPLACES the line above rather than extending it, for the same
    /// 40-character reason. Raising the slider buys level, not SNR, on a
    /// built-in mic; what it buys that matters is classification margin, and a
    /// meter that finally moves when the user speaks.
    static func tooQuietMessage(inputVolumePercent percent: Int) -> String {
        "Too faint — input volume is \(percent)%"
    }

    /// Pill copy for an utterance that produced nothing.
    ///
    /// Silence and a clean miss are not faults — Flow fades; we name them
    /// quietly and leave. A starved mic, a crash or a timeout still alarm,
    /// because those are ours.
    private func flashEmpty(_ reason: EmptyReason?, peakLevel: Float, noiseFloor: Double?) {
        switch reason {
        case .starved:
            flashError("Microphone delivered no audio")
        case .deviceChanged:
            flashError("Microphone changed — try again")
        // Gated to `produced_nothing` deliberately, which is where the class
        // lands anyway: `silent`/`short_hold` sit below the voiced threshold and
        // can never be marginal, and the fault reasons have copy of their own
        // that names something we did. A voiced empty with a healthy floor stays
        // on the generic line — it was not faint, and saying it was would be the
        // same untruth in the other direction.
        case .producedNothing where MarginalAudio.isMarginal(peakLevel: peakLevel,
                                                            noiseFloor: noiseFloor):
            if let percent = config.inputVolumeAdvisory() {
                pill?.flashTooQuiet(Self.tooQuietMessage(inputVolumePercent: percent))
            } else {
                pill?.flashTooQuiet(Self.tooQuietMessage)
            }
        case .silent, .producedNothing, .none:
            pill?.flashMissed("Didn't catch that")
        case .shortHold:
            pill?.flashMissed("Hold the key while you speak")
        case .timedOut, .crashed:
            flashError("Didn't catch that")
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

    private func setLastDelivery(_ value: (text: String, outcome: String)?) {
        lock.lock(); lastDelivery = value; lock.unlock()
    }

    /// The paste-rung half of Phase-5 edit observation.
    ///
    /// One shot per delivery: the slot is consumed whether or not a snapshot
    /// arrived, because the claim "this window shows what became of our paste"
    /// only holds for the very next look at the field — every utterance after
    /// that is a guess. The IM rungs are excluded here (their own read channel
    /// observes them with located-run evidence), and `blocked_secure` never had
    /// a delivery to observe.
    private func observeLastDelivery(against ctx: ContextOutcome) {
        lock.lock()
        let last = lastDelivery
        lastDelivery = nil
        lock.unlock()
        guard let editObserver, let last, !last.text.isEmpty,
              last.outcome == InsertResult.Method.paste.rawValue
                  || last.outcome == InsertResult.Method.type.rawValue,
              ctx.status == .read, let field = ctx.fieldText, !field.isEmpty
        else { return }
        editObserver.observeField(inserted: last.text, current: field)
    }

    private func writeMetrics(heldMs: Double, result: UtteranceResult,
                              postMs: Double, insertMs: Double, outcome: String,
                              releaseToTextMs: Double?, aiMs: Double?, ai: String?,
                              audioMs: Double, emptyReason: EmptyReason? = nil,
                              refineDelta: Int? = nil,
                              ctx: ContextOutcome = ContextOutcome(),
                              noiseFloor: Double? = nil,
                              firstVoicedMs: Double? = nil,
                              restoreMs: Double? = nil,
                              repressQueued: Bool? = nil) {
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
            refineDelta: refineDelta,
            // Phase-4 context awareness. All three stay omitted on the
            // default-off install (status nil ⇒ no capture cycle ran), and
            // `ctx_terms` is only meaningful for a consumed snapshot.
            ctx: ctx.status?.rawValue,
            ctxMs: ctx.captureMs,
            ctxTerms: ctx.status == .read ? ctx.terms.count : nil,
            // R6: the paste rung's post-delivery custody window, split out of
            // `release_to_text_ms`/`insert_ms` so the felt number stops
            // carrying the sleep — plus the re-press counter it prices R34 by.
            restoreMs: restoreMs,
            repressQueued: repressQueued,
            // R4: the capture session's acoustic pair, every utterance row.
            noiseFloor: noiseFloor,
            firstVoicedMs: firstVoicedMs,
            // Derived here rather than passed by each call site, so EVERY
            // utterance row carries it — the truncated-but-non-empty rows most
            // of all, which is the shape the 2026-08-05 log could not express.
            // Omitted when false: the append-only stream never grows a byte on
            // the overwhelming majority of rows.
            configChanged: result.sawConfigurationChange ? true : nil,
            // Every utterance row, not just the empty ones — and deliberately
            // wider than the pill copy, which only fires on `produced_nothing`.
            // The interesting number is how often marginal audio still SUCCEEDS:
            // that ratio is what says whether the 0.12/5 thresholds describe the
            // failure class or merely a quiet room.
            marginalAudio: MarginalAudio.isMarginal(peakLevel: result.peakLevel,
                                                    noiseFloor: noiseFloor) ? true : nil,
            // The rescue's own pair. `rescue_normalized` appears on declined
            // rescues too (see `UtteranceResult.rescueGainDb`), so the rate of
            // amplification stays readable independently of whether the batch
            // reading won.
            rescueNormalized: result.rescueGainDb != nil ? true : nil,
            appliedGainDb: result.rescueGainDb))
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
