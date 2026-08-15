import Foundation

/// Every way an utterance can leave the refine stage. The first thirteen values
/// are the Python `wisprit/refine.py` vocabulary, byte-identical because they are
/// written into `metrics.log`'s `ai` field and must stay one comparable stream
/// across the Python→Swift cutover. Two values are additions: `hasLetterRun`
/// (the spelled-run bypass, research §correction-detection) and `obeyed` (the
/// eval harness caught the model executing the dictation).
///
/// Everything except `applied` returns the verbatim transcript: refinement can
/// only ever *win*.
public enum RefineOutcome: String, Sendable, CaseIterable {
    case applied
    case off
    case empty
    case tooLong = "too_long"
    case hasAddress = "has_address"
    case timeout
    case cancelled
    case preempted
    case spawnFailed = "spawn_failed"
    case badReply = "bad_reply"
    case helperError = "helper_error"
    case implausible
    case error
    /// NEW (not in the Python vocabulary): utterance contains a spelled letter
    /// run, which the model measurably corrupts (S-H-A-R-I-Q-U-E → "Sharifue").
    case hasLetterRun = "has_letter_run"
    /// NEW (not in the Python vocabulary): the reply is evidence that the model
    /// OBEYED the dictation instead of cleaning it — it wrote the code the
    /// utterance asked for, or it executed the utterance's opening instruction
    /// and returned only the object. Distinct from `implausible`, which is the
    /// word-count band and the assistant-opener check: an obedient reply is
    /// often exactly utterance-sized, so the band never sees it.
    case obeyed
    /// NEW (not in the Python vocabulary): the frontmost app is on
    /// `context_verbatim_bundle_ids` — a terminal or an IDE, where "cleanup" of
    /// identifiers is only ever damage — so the stage was skipped outright.
    /// Its own value rather than a reuse of `off` for the same reason
    /// `hasLetterRun` got one: every previously recorded `off` row meant "the
    /// setting is off", and it has to keep meaning exactly that.
    case skippedVerbatimApp = "skipped_verbatim_app"
    /// NEW (not in the Python vocabulary): the reply deleted content words the
    /// utterance carried — a whole clause gone. Distinct from `implausible`
    /// because the word-count band structurally cannot see it: its floor is a
    /// ratio (0.4×), so a 24-word dictation may lose ten words and stay inside
    /// the band. Measured on LibriSpeech test-clean (200 clips): raw ASR WER
    /// 2.68% → refined 3.59%, worst clip ten words short, outcome `applied`.
    case droppedContent = "dropped_content"
    /// NEW (not in the Python vocabulary): the reply said something the
    /// utterance did not — a substitution or an insertion that is neither a
    /// phonetic repair, a merge, nor ITN. Its own value rather than a reuse of
    /// `dropped_content` because the two are different failures and both are
    /// read out of `metrics.log`: that one is words GONE, this one is words
    /// CHANGED, which every guard before it is structurally blind to (the word
    /// count is unremarkable and nothing was deleted). Measured on LibriSpeech
    /// test-clean: refined WER 3.16% → 2.93% with this guard in the chain.
    case paraphrased

    /// True for the thirteen outcomes `wisprit/refine.py` can emit.
    public var isPythonVocabulary: Bool {
        switch self {
        case .hasLetterRun, .obeyed, .skippedVerbatimApp, .droppedContent, .paraphrased:
            return false
        default: return true
        }
    }
}

/// What the session wants the refiner to do while the model is generating.
/// Mirrors `session._refine_interrupt()`'s `None | "cancel" | "hurry"`.
public enum InterruptSignal: Sendable, Equatable {
    /// Keep waiting.
    case none
    /// Esc — the utterance is being discarded anyway.
    case cancel
    /// A new dictation is queued: finish NOW with the verbatim text so the next
    /// press isn't stuck behind the model.
    case hurry
}

public struct RefineResult: Sendable, Equatable {
    public var text: String
    public var outcome: RefineOutcome
    public init(text: String, outcome: RefineOutcome) {
        self.text = text
        self.outcome = outcome
    }
}

/// The settings the cage reads, snapshotted per call so a live settings
/// change takes effect without restarting (Python re-reads `self._settings`
/// inside `refine()`). Non-positive numbers fall back to the defaults, which is
/// what `Refiner._num` does.
public struct RefineConfiguration: Sendable, Equatable {
    public var enabled: Bool
    public var maxWords: Int
    public var timeoutMs: Int
    /// Phase 4's tone-lite: the frontmost app is on
    /// `context_verbatim_bundle_ids`, so this utterance skips the model
    /// entirely (`skipped_verbatim_app`) — only ever more verbatim + faster.
    /// A snapshot like the rest: the wiring resolves the frontmost bundle per
    /// call, this struct just carries the verdict.
    public var verbatimApp: Bool

    public init(enabled: Bool = true, maxWords: Int = 350, timeoutMs: Int = 12000,
                verbatimApp: Bool = false) {
        self.enabled = enabled
        self.maxWords = maxWords > 0 ? maxWords : 350
        self.timeoutMs = timeoutMs > 0 ? timeoutMs : 12000
        self.verbatimApp = verbatimApp
    }
}

/// Result of one Apple Intelligence availability probe.
public struct RefineAvailability: Sendable, Equatable {
    public var available: Bool
    /// `String(describing: UnavailableReason)` when unavailable, "" otherwise.
    public var reason: String

    public init(available: Bool, reason: String = "") {
        self.available = available
        self.reason = available ? "" : reason
    }
}

/// Failures the generator raises. Ported so the in-process path lands on the
/// same metrics outcomes the subprocess protocol produced.
public enum RefineError: Error, Equatable {
    /// Session could not be built/prewarmed → `spawn_failed`.
    case setupFailed(String)
    /// The model threw (guardrailViolation, exceededContextWindowSize,
    /// rateLimited, …) → `helper_error`.
    case generationFailed(String)
    /// Model returned nothing → the helper's `{"ok": false, "error": "empty
    /// response"}` → `helper_error`.
    case emptyResponse
    /// No in-process analogue (the subprocess emitted an unparseable line);
    /// kept so the `bad_reply` outcome stays reachable and tested.
    case malformedReply
    /// Apple Intelligence went away mid-session (assets evicted, setting off).
    case unavailable(String)
}

/// The model behind the cage. Every guard in `Refiner` is testable against a
/// fake conformance — no Apple Intelligence required.
///
/// Lifecycle mirrors the subprocess one exactly: `prewarm()` at record start,
/// one `generate` per utterance, `discard()` on skip/abort. One session per
/// utterance is mandatory in-process too — `LanguageModelSession` accumulates a
/// transcript, and a reused session would spend the shared 4096-token context
/// on previous dictations.
public protocol RefineGenerating: Sendable {
    /// Ask the system whether the model is usable right now.
    func probe() async -> RefineAvailability
    /// Build + prewarm a session for the next utterance. Never throws — a
    /// failure here just means `generate` pays the setup cost inline.
    func prewarm() async
    /// Run one utterance. Consumes the prewarmed session.
    func generate(_ transcript: String) async throws -> String
    /// Drop any live session (record cancelled, refine skipped, shutdown).
    func discard() async
}
