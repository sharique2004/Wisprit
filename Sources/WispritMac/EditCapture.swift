import Foundation
import WispritContext
import WispritCorrections
import WispritDictionary
import WispritIMProtocol
import WispritKit
import WispritPersistence

/// The one config key the flywheel's learn path adds.
///
/// String-keyed for the same reason `LiveTypingSettings` is: `Settings.defaults`
/// is golden-pinned, the settings file preserves keys it does not know about,
/// and a config written by either build round-trips intact.
public enum EditLearnSettings {
    /// `learn_auto_accept` — default OFF: a candidate that reaches the
    /// ≥2-observations threshold is PROPOSED (pill notice + Dictionary badge),
    /// never silently written. Flipping this on is the "just learn it" mode:
    /// threshold candidates go straight into dictionary.json, no notice.
    public static let autoAcceptKey = "learn_auto_accept"

    public static func autoAccept(_ settings: Settings) -> Bool {
        settings.bool(autoAcceptKey, or: false)
    }

    public static func setAutoAccept(_ settings: Settings, _ value: Bool) {
        settings.set(autoAcceptKey, value)
    }
}

/// The slice the session state machine talks to for the paste-rung fallback —
/// nil is the pre-Phase-5 behaviour, exactly like `ContextPort`.
public protocol EditObservingPort: AnyObject, Sendable {
    /// The next utterance's context snapshot showed `current` where the previous
    /// utterance pasted `inserted`. Weaker evidence than the IM read (a bounded
    /// window, not a located run) and treated as such.
    func observeField(inserted: String, current: String)
}

/// Phase 5's collection point: every way the pipeline can see what became of
/// text it inserted lands here, is classified once, and leaves as at most three
/// things — one `edit_observed` metrics line, one `PendingLearnStore` record,
/// and (at the ≥2-observations threshold) one propose notice.
///
/// Two observation sources, honestly ranked:
///
///  * **`im`** — the wire-v2 `committedSnapshot`. The input method located the
///    run this session committed by content, single-occurrence rule
///    (`RetroEditPlanner.locate`), so `.unchanged` is a real zero-edit fact and
///    `.changed` is a real edit fact. Strong evidence.
///  * **`ax`** — the next utterance's context snapshot diffed against the text
///    the previous one pasted. A bounded window that may clip our run, in a
///    field we cannot prove is the same one — so anything ambiguous is
///    NO-SIGNAL, never a guess. Weaker evidence, and only ever available when
///    the user consented to context awareness (the snapshot does not otherwise
///    exist).
///
/// Everything here is off the paste path: snapshots arrive on the IM client's
/// event loop, field observations on the session thread at the NEXT finalize.
/// Refusing is normal — most edits are the user writing, not correcting — and
/// an utterance nobody observed writes no line at all, which is what keeps the
/// zero-edit denominator honest.
public final class EditCapture: EditObservingPort, @unchecked Sendable {

    /// `edit_scope` vocabulary — stable, they land in `metrics.log`.
    public static let imScope = "im"
    public static let axScope = "ax"
    /// `dictionary.json` `source` for terms this flywheel writes (via
    /// auto-accept or the Dictionary page's Accept).
    public static let learnSource = "edit_capture"

    /// Propose-first, verbatim from the plan: the word is NOT learned yet, and
    /// the notice says where the decision lives.
    public static func proposalNotice(_ term: String) -> String {
        "New word: \(term) — review in Dictionary"
    }

    public struct Configuration: Sendable {
        /// "Does the dictionary already know this?" — the gate's last refusal.
        public var knownTerm: @Sendable (String) -> Bool
        /// `learn_auto_accept`, read live per threshold event.
        public var autoAccept: @Sendable () -> Bool
        /// The observation stamp `PendingLearnStore` uses as utterance identity.
        public var now: @Sendable () -> Date

        public init(knownTerm: @escaping @Sendable (String) -> Bool = { _ in false },
                    autoAccept: @escaping @Sendable () -> Bool = { false },
                    now: @escaping @Sendable () -> Date = { Date() }) {
            self.knownTerm = knownTerm
            self.autoAccept = autoAccept
            self.now = now
        }
    }

    private let log = WLog.logger("edit-capture")
    private let store: PendingLearnStore
    private let metrics: MetricsPort
    private let vocabulary: (any VocabularyPort)?
    private let pill: (any PillPort)?
    private let lexicon: any Lexicon
    /// The app-side mirror of what the input method committed under a wire
    /// generation — `LiveTypingSession.committedText(for:)` in the real wiring.
    private let committedText: @Sendable (UInt64) -> String?
    private let config: Configuration

    private let lock = NSLock()
    /// One observation per committed state: the key-down read and the
    /// session-close read can both answer about the same run, and the second
    /// answer is the same fact, not a second utterance.
    private var lastClaim: (generation: UInt64, text: String)?

    public init(store: PendingLearnStore,
                metrics: MetricsPort,
                vocabulary: (any VocabularyPort)? = nil,
                pill: (any PillPort)? = nil,
                lexicon: any Lexicon = SystemLexicon(),
                committedText: @escaping @Sendable (UInt64) -> String? = { _ in nil },
                configuration: Configuration = Configuration()) {
        self.store = store
        self.metrics = metrics
        self.vocabulary = vocabulary
        self.pill = pill
        self.lexicon = lexicon
        self.committedText = committedText
        self.config = configuration
    }

    // MARK: - the IM rung (edit_scope: "im")

    /// One wire-v2 `committedSnapshot`, generation-stamped. Consumption rules
    /// exactly as `IMAppClient` documents them: `.unchanged` is the zero-edit
    /// observation, `.changed` means an edit is a fact, everything else is a
    /// reason and therefore no signal.
    public func consumeCommitted(wireGeneration: UInt64, _ snapshot: IMCommittedSnapshot) {
        switch snapshot.detail {
        case .unchanged, .changed:
            break
        default:
            return  // unknown / noClient / staleGeneration / … — not evidence
        }
        // No mirror for that generation means the commit was never ours to
        // name — an answer we cannot diff is an answer we must not count.
        guard let ours = committedText(wireGeneration), !ours.isEmpty else { return }
        guard claimObservation(generation: wireGeneration, text: ours) else { return }

        guard snapshot.detail == .changed else {
            writeObservation(distance: 0, scope: Self.imScope)
            return
        }
        let current = snapshot.current
        guard !current.isEmpty else {
            // The shipping input method refuses to guess WHICH edit happened,
            // so `.changed` can arrive with no text: the edit is a fact, its
            // size is not. Observed, never zero-edit, distance omitted.
            writeObservation(distance: nil, scope: Self.imScope)
            return
        }
        writeObservation(distance: Self.editDistance(ours, current), scope: Self.imScope)
        route(EditObservationGate.observe(committed: ours, current: current,
                                          lexicon: lexicon, knownTerm: config.knownTerm))
    }

    // MARK: - the paste rung (edit_scope: "ax")

    public func observeField(inserted: String, current: String) {
        // The paste path may have added a leading space; the containment check
        // must not fail on our own formatting.
        let ours = inserted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ours.isEmpty, !current.isEmpty else { return }

        // Exactly once in the window, character for character: our text is
        // sitting where we left it, whatever the user typed around it.
        if Self.occurrences(of: ours, in: current) == 1 {
            writeObservation(distance: 0, scope: Self.axScope)
            return
        }
        let observation = EditObservationGate.observe(committed: ours, current: current,
                                                      lexicon: lexicon,
                                                      knownTerm: config.knownTerm)
        if observation.refusal == .unchanged {
            // Token streams identical once case/punctuation/whitespace fold:
            // the app re-wrapped or smart-quoted our text. Still zero-edit.
            writeObservation(distance: 0, scope: Self.axScope)
            return
        }
        guard observation.proposal != nil else {
            // Insertions, deletions, reflow, a clipped window, a different
            // field entirely — from one bounded snapshot these are all the
            // same picture, so none of them is evidence of anything.
            return
        }
        writeObservation(distance: Self.editDistance(ours, current), scope: Self.axScope)
        route(observation)
    }

    // MARK: - proposals

    /// Accepted proposals go through `PendingLearnStore.record`; the threshold
    /// decides whether anything is surfaced. Refusals were already logged as
    /// the observation line — a refusal is a classified edit, not an error.
    private func route(_ observation: EditObservation) {
        guard let proposal = observation.proposal else { return }
        switch store.record(term: proposal.replacement, heard: proposal.replaced,
                            at: config.now()) {
        case .recorded:
            break  // evidence noted; one utterance is a coincidence
        case .alreadyDismissed:
            break  // the user said no, and no is forever
        case .reachedThreshold:
            if config.autoAccept() {
                // Silent add: the same write the Dictionary page's Accept makes.
                vocabulary?.add(LearnedTerm(term: proposal.replacement,
                                            heard: [proposal.replaced],
                                            source: Self.learnSource))
                store.promoteConsumed(term: proposal.replacement)
                log.info("auto-accepted a learned term at threshold")
            } else {
                pill?.transientNotice(Self.proposalNotice(proposal.replacement))
            }
        }
    }

    // MARK: - the edit_observed line

    /// The reference-less third line (`vocab_retro` precedent): ref-less by
    /// construction, `edit_dist` + `edit_scope` and nothing an utterance row
    /// carries. See `docs/notes/deviations.md`.
    private func writeObservation(distance: Int?, scope: String) {
        metrics.write(MetricsRecord(
            heldMs: 0, engine: "", finalizeMs: 0, timedOut: false, postMs: 0,
            insertMs: 0, outcome: MetricsSummary.editObservedOutcome, chars: 0,
            editDist: distance, editScope: scope))
    }

    private func claimObservation(generation: UInt64, text: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let lastClaim, lastClaim.generation == generation, lastClaim.text == text {
            return false
        }
        lastClaim = (generation, text)
        return true
    }

    // MARK: - helpers

    /// Character Levenshtein with the same escape hatch as
    /// `SessionController.refineDelta`: past the cap the length difference is
    /// the honest cheap answer, and this path runs at most twice per utterance.
    static func editDistance(_ a: String, _ b: String) -> Int {
        guard a != b else { return 0 }
        let cap = 2_000
        guard a.count <= cap, b.count <= cap else { return abs(a.count - b.count) }
        return StringMetrics.levenshtein(a, b)
    }

    /// Occurrence count, capped at 2 — none / one / more is all any caller asks.
    static func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var from = haystack.startIndex
        while let hit = haystack.range(of: needle, range: from..<haystack.endIndex) {
            count += 1
            if count > 1 { return count }
            from = hit.upperBound
        }
        return count
    }
}
