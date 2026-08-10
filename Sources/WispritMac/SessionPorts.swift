import Foundation
import WispritDictionary
import WispritEngine
import WispritKit
import WispritMacInput
import WispritPersistence
import WispritRefine

/// The seams `SessionController` is written against.
///
/// Everything the state machine touches that involves a microphone, a neural
/// engine, the pasteboard, a window or the disk arrives through one of these,
/// so the machine itself is exercisable on a laptop with no TCC grants: the
/// tests drive it with fakes, and the thin adapters below (the only code that
/// names the real subsystems) stay uncovered by design.

public protocol AsrPort: Sendable {
    func begin(onPartial: @escaping @Sendable (String) -> Void) async
    func finalize() async -> UtteranceResult
    /// The audio `finalize()` detached. The session captures it on its own
    /// thread the instant finalize returns; anything off-path gets the value,
    /// never another look at this property.
    var lastRetained: RetainedUtterance { get }
    func cancel() async
    /// Off-path reconciliation over one utterance's audio. Contractually only
    /// ever called AFTER insertion — it takes hundreds of ms to seconds.
    /// `extraTerms` are THIS utterance's context-awareness candidates (empty in
    /// every wiring that has none); they bias this one pass and die with it.
    func reconcileVocabulary(_ retained: RetainedUtterance,
                             extraTerms: [String]) async -> VocabularyReconciliation?
}

public protocol AudioPort: Sendable {
    /// false = the input could not be opened; the utterance aborts cleanly.
    func start() -> Bool
    func stop()
    /// 0…1, read by the pill level ticker at 20 Hz.
    var level: Double { get }

    // R4 telemetry (FINAL-PLAN B-2). Both describe the current-or-most-recent
    // capture session and are read by the session AFTER `stop()`, on its own
    // thread. Additive with defaults so a port that cannot measure them (fakes,
    // the onboarding meter) simply omits the fields from the metrics row.

    /// Quietest ~300 ms window of the utterance on the meter's own scale
    /// (RMS × 4, clamped — deliberately comparable with `peak_level`, so the
    /// (level, floor) pair reads as an SNR proxy on one axis). nil until three
    /// chunks exist.
    var noiseFloor: Double? { get }
    /// mic-live → first chunk at or above the voiced threshold, in ms. The
    /// clipping-exposure metric: its p5 owns the verdict on whether cold-start
    /// head-loss was ever real exposure (never reported as an accuracy win).
    var firstVoicedMs: Double? { get }
}

public extension AudioPort {
    var noiseFloor: Double? { nil }
    var firstVoicedMs: Double? { nil }
}

public protocol RefinePort: Sendable {
    /// Prewarm at record start so the model loads during the hold.
    func begin() async
    func refine(_ raw: String,
                interrupt: @escaping @Sendable () -> InterruptSignal) async -> RefineResult
    func cancel() async
    /// nil while the availability probe is still running (the menu shows the
    /// toggle anyway; only an explicit false swaps in the disabled row).
    func availability() async -> Bool?
}

public protocol InsertPort: Sendable {
    /// Never throws — every failure comes back as an `InsertResult`.
    func insert(_ text: String) -> InsertResult
    /// Same cascade, plus the R6 delivery hook: `onDelivered` fires the moment
    /// the text is in the target app — on the paste rung that is after ⌘V and
    /// BEFORE the 500 ms restore sleep — and never on a failure. The session
    /// flashes success (and plays the commit cue) from inside it, so feedback
    /// stops trailing the text it confirms.
    func insert(_ text: String, onDelivered: () -> Void) -> InsertResult
}

public extension InsertPort {
    /// A conformer that predates the hook delivers by the time `insert`
    /// returns, so firing the callback at return preserves the old ordering —
    /// feedback is never earlier than delivery, merely no longer late.
    func insert(_ text: String, onDelivered: () -> Void) -> InsertResult {
        let result = insert(text)
        if result.ok { onDelivered() }
        return result
    }
}

/// R11's two cues — mic-open and commit. Deliberately no error cue: the visual
/// alarm body is enough, and a failure buzzer would make a starved mic feel
/// like a slot machine (native-feel §2.10).
public enum SoundCue: String, Sendable, CaseIterable {
    /// Played on the show-recording event, i.e. only once `audio.start()` has
    /// succeeded — the orange rule in a second sense: the cue may never claim
    /// a mic that did not open.
    case micOpen = "mic_open"
    /// Played at the delivery instant, alongside the success flash.
    case commit
}

public protocol SoundPort: Sendable {
    /// Cheap and non-blocking; called on the session thread.
    func play(_ cue: SoundCue)
}

public protocol PillPort: Sendable {
    func showRecording()
    func updateLevel(_ level: Double)
    func livePartial(_ text: String)
    func showFinalizing()
    func flashSuccess()
    func flashError(_ message: String)
    func transientNotice(_ text: String)
    func hide()

    // The three states `docs/design/ui-redesign.md` §2.4 adds. All three are
    // additive with a default implementation, so no conformer breaks and each
    // one degrades to what the pill did before it existed.

    /// Key-down accepted, audio not open yet: the pill fades in at floor, grey,
    /// so the panel is already on screen when the first level tick lands.
    func showPrewarming()
    /// The Apple Intelligence pass has started — the longest stage, and the one
    /// the user could otherwise read as a hang.
    func showRefining()
    /// The `blocked_secure` outcome: a lock, and the ⌘⌃V remedy.
    ///
    /// Deliberately argument-free where §6.6 sketches `flashBlockedSecure(detail)`:
    /// the copy is `PillGeometry.blockedSecureMessage` (§2.4), which lives in
    /// `WispritMacUI`, and the session names the *state*, not the words — that is
    /// what keeps `SessionController` free of any UI import.
    func flashBlockedSecure()
}

public extension PillPort {
    func showPrewarming() {}
    /// Without a pill that knows the state, refining looks exactly like
    /// finalizing — which is what it did before, and is still true.
    func showRefining() { showFinalizing() }
    /// The message this state replaced, for a pill that predates it.
    func flashBlockedSecure() { flashError("secure field — press ⌘⌃V to paste") }
}

public protocol HistoryPort: Sendable {
    @discardableResult
    func add(text: String, engine: String, durationMs: Double?) -> Int64
    func lastText() -> String?
    /// The utterance's pipeline triple, keyed to the transcript row `add`
    /// returned. Off the paste path — written after the text has landed.
    @discardableResult
    func addDetail(transcriptId: Int64, raw: String, corrected: String, refined: String,
                   inserted: String, vocab: String?, ai: String?, termsHit: [String]) -> Int64
    /// The late `vocab` column: the off-path reconciliation finishes seconds
    /// after the detail row was written, so its outcome arrives as an update.
    @discardableResult
    func updateDetail(transcriptId: Int64, vocab: String) -> Bool
}

public protocol MetricsPort: Sendable {
    func write(_ record: MetricsRecord)
}

/// The dictionary, as the session uses it: hot-reload at key-down, learn +
/// usage bookkeeping strictly off the paste path.
public protocol VocabularyPort: Sendable {
    @discardableResult
    func maybeReload() -> Bool
    func add(_ learned: LearnedTerm)
    /// Quarantine path: the run was believable but unverified, so it must not
    /// become live vocabulary until a second observation confirms it.
    func addPending(term: String, observation: String)
    func recordUse(term: String)
    /// Is this already a canonical term? The retro-correction fallback's whole
    /// safety argument: it may only ever attach a misrecognition to a term the
    /// user already has, never mint one.
    func isKnownTerm(_ word: String) -> Bool
}

/// `hotkey.set_recording(...)` — gates Esc emission. Kept true through the
/// refine stage, which is what keeps the longest stage abortable.
public protocol RecordingGate: Sendable {
    func setRecording(_ recording: Bool)
}

// MARK: - System adapters
//
// Thin, untested by design: each one forwards to a frozen core API.

extension History: HistoryPort {}
extension MetricsWriter: MetricsPort {}
extension HotkeyMonitor: RecordingGate {}
extension DictionaryStore: VocabularyPort {
    public func addPending(term: String, observation: String) {
        addPending(term: term, observation: observation,
                   source: "spoken_spelling")
    }
}

public struct AsrManagerPort: AsrPort {
    let manager: AsrManager
    public init(_ manager: AsrManager) { self.manager = manager }

    public func begin(onPartial: @escaping @Sendable (String) -> Void) async {
        await manager.begin(onPartial: onPartial)
    }
    public func finalize() async -> UtteranceResult { await manager.finalize() }
    public var lastRetained: RetainedUtterance { manager.lastRetained }
    public func cancel() async { await manager.cancel() }
    public func reconcileVocabulary(_ retained: RetainedUtterance,
                                    extraTerms: [String]) async -> VocabularyReconciliation? {
        await manager.reconcileVocabulary(retained, extraTerms: extraTerms)
    }
}

public struct RefinerPort: RefinePort {
    let refiner: Refiner
    public init(_ refiner: Refiner) { self.refiner = refiner }

    public func begin() async { await refiner.begin() }
    public func refine(_ raw: String,
                       interrupt: @escaping @Sendable () -> InterruptSignal) async -> RefineResult {
        await refiner.refine(raw, interrupt: interrupt)
    }
    public func cancel() async { await refiner.cancel() }
    public func availability() async -> Bool? { await refiner.availability }
}

/// Builds an `InserterConfig` from live `Settings` on every call, so a config
/// edit takes effect on the very next utterance.
public struct SettingsInserterPort: InsertPort {
    let inserter: Inserter
    let settings: Settings

    public init(inserter: Inserter, settings: Settings) {
        self.inserter = inserter
        self.settings = settings
    }

    public func insert(_ text: String) -> InsertResult {
        insert(text, onDelivered: {})
    }

    public func insert(_ text: String, onDelivered: () -> Void) -> InsertResult {
        inserter.insert(text, config: InserterConfig(
            terminalBundleIDs: settings.terminalBundleIDs,
            pasteRestoreDelayMs: Double(settings.pasteRestoreDelayMs)),
                        onDelivered: onDelivered)
    }
}

#if os(macOS)
public struct MicCapturePort: AudioPort {
    let capture: MicCapture
    public init(_ capture: MicCapture) { self.capture = capture }

    public func start() -> Bool { capture.start() }
    public func stop() { capture.stop() }
    public var level: Double { Double(capture.level) }
    public var noiseFloor: Double? { capture.noiseFloor }
    public var firstVoicedMs: Double? { capture.firstVoicedMs }
}
#endif
