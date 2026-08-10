import Foundation
import WispritContext
import WispritIMProtocol
import WispritKit
import WispritPersistence

/// The config keys context awareness adds — the `LiveTypingSettings` string-key
/// precedent, not `SettingsKey`: `Settings.defaults` is golden-pinned, the
/// settings file preserves keys it does not know about, and a config written by
/// either build round-trips intact.
public enum ContextSettings {
    /// `context_awareness` — the consent flag, default OFF. Flipped only by the
    /// explicit consent flow (`AppController.enableContextAwareness`), never by
    /// code, and outranked by `WISPRIT_NO_CONTEXT=1` either way.
    public static let enabledKey = "context_awareness"
    /// `context_max_terms` — biasing-candidate cap per utterance.
    public static let maxTermsKey = "context_max_terms"
    /// `context_excluded_bundle_ids` — apps whose text is never read. The
    /// entries EXTEND `ContextPolicy.defaultExcludedBundleIDs`; a hand-edited
    /// list can add a private app but can never re-admit a password manager.
    public static let excludedBundleIDsKey = "context_excluded_bundle_ids"
    /// `context_verbatim_bundle_ids` — frontmost apps whose dictation skips the
    /// refine stage entirely: terminals and IDEs get exactly what was said,
    /// faster. Independent of the consent flag — skipping a model pass reads
    /// nothing from anyone's screen.
    public static let verbatimBundleIDsKey = "context_verbatim_bundle_ids"

    /// IDEs joined with the user's terminal list for the verbatim default —
    /// the places where "cleanup" of identifiers is only ever damage.
    public static let defaultIDEBundleIDs = [
        "com.apple.dt.Xcode",
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92",   // Cursor
        "dev.zed.Zed",
        "com.sublimetext.4",
        "com.jetbrains.intellij",
        "com.jetbrains.intellij.ce",
        "com.jetbrains.pycharm",
        "com.jetbrains.pycharm.ce",
        "com.jetbrains.WebStorm",
        "com.jetbrains.goland",
        "com.jetbrains.rider",
        "com.jetbrains.CLion",
    ]

    public static func isEnabled(_ settings: Settings) -> Bool {
        settings.bool(enabledKey, or: false)
    }

    public static func setEnabled(_ settings: Settings, _ value: Bool) {
        settings.set(enabledKey, value)
    }

    /// Non-positive hand-edits fall back to the extractor's own default,
    /// mirroring `RefineConfiguration`'s treatment of bad numbers.
    public static func maxTerms(_ settings: Settings) -> Int {
        let value = settings.int(maxTermsKey, or: CandidateExtractor.defaultMaxTerms)
        return value > 0 ? value : CandidateExtractor.defaultMaxTerms
    }

    public static func excludedBundleIDs(_ settings: Settings) -> Set<String> {
        let listed = settings.stringArray(excludedBundleIDsKey) ?? []
        return ContextPolicy.defaultExcludedBundleIDs
            .union(listed.map { $0.lowercased() })
    }

    /// The effective verbatim list. Until the user writes their own, it tracks
    /// `terminal_bundle_ids` live — adding a terminal there keeps it verbatim
    /// here too — plus the compiled-in IDE set.
    public static func verbatimBundleIDs(_ settings: Settings) -> [String] {
        settings.stringArray(verbatimBundleIDsKey) ?? defaultVerbatimBundleIDs(settings)
    }

    public static func defaultVerbatimBundleIDs(_ settings: Settings) -> [String] {
        var seen = Set<String>()
        return (settings.terminalBundleIDs + defaultIDEBundleIDs)
            .filter { seen.insert($0.lowercased()).inserted }
    }

    public static func setVerbatimBundleIDs(_ settings: Settings, _ value: [String]) {
        settings.set(verbatimBundleIDsKey, value)
    }

    /// Case-insensitive, like `ContextPolicy`'s app gate: bundle IDs in the
    /// wild are sloppier than the spec says.
    public static func isVerbatimApp(_ settings: Settings, bundleID: String?) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return false }
        let needle = bundleID.lowercased()
        return verbatimBundleIDs(settings).contains { $0.lowercased() == needle }
    }

    /// The pure gate, built fresh from live settings — read per key-down so a
    /// toggle takes effect on the very next utterance.
    public static func policy(_ settings: Settings) -> ContextPolicy {
        ContextPolicy(enabled: isEnabled(settings),
                      excludedBundleIDs: excludedBundleIDs(settings))
    }
}

// MARK: - Consent

/// The consent sheet, as data. The AppKit alert renders exactly these strings
/// and the decision function below, so the flow's copy and its outcomes are
/// pinnable in tests without a window.
public enum ContextConsent {
    public static let title = "Enable Context Awareness?"
    public static let enableTitle = "Enable"
    public static let cancelTitle = "Cancel"

    /// What is read, what is never read, where it goes — the §consent contract,
    /// verbatim in the sheet.
    public static let whatIsRead =
        "What is read: the text near your cursor in the active field, at the "
        + "moment you press the dictation key."
    public static let neverRead =
        "What is never read: other windows, screenshots, browser URLs, or "
        + "anything in a password manager or secure field."
    public static let whereItGoes =
        "Where it goes: nowhere. It helps this Mac recognize the words you "
        + "already have on screen for this one utterance, then it is discarded. "
        + "Nothing is stored, nothing is transmitted."
    /// The IM rung reads through Wisprit's own input method and needs no
    /// permission at all — the sheet says so, per the plan.
    public static let permissionNote =
        "With Live Typing on, the reading comes through Wisprit's own input "
        + "method and needs no new permission. Everywhere else macOS will ask "
        + "for Accessibility, the same permission pasting already uses."

    public static var informativeText: String {
        [whatIsRead, neverRead, whereItGoes, permissionNote].joined(separator: "\n\n")
    }

    /// What accepting (or not) the sheet does. Pure, so the flow's two rules —
    /// nothing happens without an accept, and the Accessibility prompt is
    /// raised only when the AX path actually needs it — are tested as data.
    public struct Plan: Equatable, Sendable {
        public var enable: Bool
        public var requestAccessibility: Bool

        public init(enable: Bool, requestAccessibility: Bool) {
            self.enable = enable
            self.requestAccessibility = requestAccessibility
        }
    }

    public static func plan(accepted: Bool, axTrusted: Bool) -> Plan {
        Plan(enable: accepted, requestAccessibility: accepted && !axTrusted)
    }
}

// MARK: - The session-facing seam

/// `metrics.log`'s `ctx` field: what one utterance's capture cycle produced.
/// Only written when the consent flag was on at key-down — the default-off
/// install never grows the field at all.
public enum ContextReadStatus: String, Sendable, Equatable {
    /// A snapshot was consumed; `ctx_terms` counts what the extractor kept.
    case read
    /// No reader answered before finalize (or a wedged reader answered after
    /// its budget). The utterance simply had no signal.
    case late
    /// The AX reader was still serving the previous request — depth-1 queue,
    /// the newcomer is dropped and says so.
    case busy
    /// The policy refused: kill switch, excluded app, Secure Event Input, or
    /// the setting flipped off mid-utterance.
    case off
}

/// What `finishCapture()` hands the session. `status == nil` means no capture
/// cycle ran (the feature is off) and no metrics field is written.
public struct ContextOutcome: Equatable, Sendable {
    public var status: ContextReadStatus?
    /// Ranked biasing candidates for THIS utterance — the strings fed to the
    /// vocabulary channel's `extraTerms` and to nothing else. Empty unless
    /// `status == .read`.
    public var terms: [String]
    /// Reader latency (key-down → snapshot arrival), for the `ctx_ms` field.
    public var captureMs: Double?
    /// The clamped window itself, in document order — Phase 5's paste-rung edit
    /// observation diffs it against the text the PREVIOUS utterance inserted.
    /// Present only on a consumed snapshot (`status == .read`), which means only
    /// under the same consent flag as everything else here, and it dies with
    /// this value: nothing downstream stores or logs it.
    public var fieldText: String?

    public init(status: ContextReadStatus? = nil, terms: [String] = [],
                captureMs: Double? = nil, fieldText: String? = nil) {
        self.status = status
        self.terms = terms
        self.captureMs = captureMs
        self.fieldText = fieldText
    }
}

/// The slice the session state machine talks to — nil is Phase-1 behaviour,
/// exactly like `LiveTypingPort`.
public protocol ContextPort: AnyObject, Sendable {
    /// Key-down, alongside prewarm. Posts/enqueues one read and returns
    /// immediately; the answer lands asynchronously or not at all.
    func beginCapture()
    /// Finalize. A slot read, never a wait — a snapshot that has not arrived
    /// yet is `late`, and whatever state the cycle left behind is cleared so
    /// the snapshot cannot outlive its utterance.
    func finishCapture() -> ContextOutcome
}

// MARK: - AX reader seam

/// One bounded reading of the focused field. What the AX adapter produces and
/// the IM wire's `IMContextSnapshot` already carries.
public struct ContextFieldText: Equatable, Sendable {
    public var before: String
    public var selected: String
    public var after: String

    public init(before: String = "", selected: String = "", after: String = "") {
        self.before = before
        self.selected = selected
        self.after = after
    }
}

/// The AX fallback behind a seam, so the coordinator (and its tests) never
/// touch a TCC-gated API. The real conformer is `AXContextReader`; tests
/// inject a closure-backed fake.
public protocol AXContextReading: AnyObject, Sendable {
    /// Start one read. `false` = dropped, a read is already in flight (the
    /// depth-1 rule). The completion fires at most once, on the reader's own
    /// thread, with nil for a field that could not be read.
    @discardableResult
    func read(_ completion: @escaping @Sendable (ContextFieldText?) -> Void) -> Bool
}

// MARK: - The coordinator

/// One utterance's context read, end to end: policy at key-down, the IM wire
/// when the rung is live, the 4-call AX read as the rungs-3/4 fallback, and a
/// generation-stamped slot the session drains at finalize.
///
/// Non-blocking by construction: `beginCapture` fires a post (IM) or an enqueue
/// (AX) and returns; `finishCapture` reads the slot under a lock and returns.
/// Neither ever waits on a reader, so the paste path cannot be delayed by a
/// wedged Accessibility peer — the same "no signal beats waiting" rule the IM
/// read channel documents.
///
/// Nothing is stored: the snapshot lives in one slot, is consumed (or
/// discarded) by the very next `finishCapture`/`beginCapture`, and only its
/// SHAPE ever reaches a log line (`ContextSnapshot.description` is redacted by
/// design, and this class logs statuses, never text or terms).
public final class ContextCapture: ContextPort, @unchecked Sendable {

    public struct Configuration: Sendable {
        /// Read fresh per key-down, like every live setting.
        public var policy: @Sendable () -> ContextPolicy
        public var maxTerms: @Sendable () -> Int
        public var frontmostBundleID: @Sendable () -> String?
        /// The same probe the insertion ladder's `blocked_secure` rung uses
        /// (`Permissions.secureInput().active`): while Secure Event Input is
        /// held, nothing is read, whatever the policy says.
        public var secureInputActive: @Sendable () -> Bool
        /// Injectable for the kill-switch tests; `ProcessInfo`'s dictionary is
        /// captured once per process.
        public var environment: [String: String]
        public var clock: @Sendable () -> Date

        public init(policy: @escaping @Sendable () -> ContextPolicy = { ContextPolicy() },
                    maxTerms: @escaping @Sendable () -> Int = { CandidateExtractor.defaultMaxTerms },
                    frontmostBundleID: @escaping @Sendable () -> String? = { nil },
                    secureInputActive: @escaping @Sendable () -> Bool = { false },
                    environment: [String: String] = ProcessInfo.processInfo.environment,
                    clock: @escaping @Sendable () -> Date = { Date() }) {
            self.policy = policy
            self.maxTerms = maxTerms
            self.frontmostBundleID = frontmostBundleID
            self.secureInputActive = secureInputActive
            self.environment = environment
            self.clock = clock
        }
    }

    private let log = WLog.logger("context")
    private let config: Configuration
    /// Post `readContext` for the open IM session; returns the wire generation
    /// the read named, or nil when the rung cannot serve one (no live client).
    private let requestIMRead: @Sendable () -> UInt64?
    private let axReader: (any AXContextReading)?
    private let lexicon: any Lexicon

    private let lock = NSLock()
    /// The coordinator's own monotonic utterance counter — what stamps
    /// `ContextSnapshot.generation`, so utterance N's snapshot can never bias
    /// utterance N+1.
    private var generation = 0
    /// True while a capture cycle for the current utterance exists at all.
    private var active = false
    private var startedAt = Date.distantPast
    private var bundleID = ""
    /// The IM session generation the in-flight read named; an answer stamped
    /// with anything else lost a race and is dropped at the door.
    private var pendingWireGeneration: UInt64?
    /// A key-down verdict that already ended the cycle (`off`/`busy`).
    private var refusal: ContextReadStatus?
    private var slot: ContextSnapshot?
    private var arrivedAt: Date?

    public init(configuration: Configuration = Configuration(),
                requestIMRead: @escaping @Sendable () -> UInt64? = { nil },
                axReader: (any AXContextReading)? = nil,
                lexicon: any Lexicon = SystemLexicon()) {
        self.config = configuration
        self.requestIMRead = requestIMRead
        self.axReader = axReader
        self.lexicon = lexicon
    }

    /// Warm the system dictionary off-thread. Called when consent flips on (and
    /// at wiring time when it already is), so the first utterance's extractor
    /// is not running against the compiled-in list alone.
    public func prewarm() {
        (lexicon as? SystemLexicon)?.prewarm()
    }

    // MARK: ContextPort

    public func beginCapture() {
        let policy = config.policy()
        let front = config.frontmostBundleID() ?? ""

        lock.lock()
        generation += 1
        let gen = generation
        active = policy.enabled
        startedAt = config.clock()
        bundleID = front
        pendingWireGeneration = nil
        refusal = nil
        slot = nil
        arrivedAt = nil
        lock.unlock()

        // Default off: no cycle, no metrics field, not even a policy question.
        guard policy.enabled else { return }

        // The consent sheet's promises, in severity order. Secure Event Input
        // is checked exactly the way the blocked_secure rung checks it.
        if config.secureInputActive() {
            setRefusal(.off)
            return
        }
        if let refused = policy.refusalToCapture(bundleID: front,
                                                environment: config.environment) {
            log.info("context capture refused: \(refused.rawValue, privacy: .public)")
            setRefusal(.off)
            return
        }

        // Reader 1: the IM wire — zero permissions, and only when the rung is
        // live right now. Fire-and-forget; the snapshot lands on `deliver`.
        if let wire = requestIMRead() {
            lock.lock()
            pendingWireGeneration = wire
            lock.unlock()
            return
        }

        // Reader 2 (rungs 3–4): the bounded AX read, depth 1 — a request while
        // one is in flight is dropped and RECORDED, never queued behind a
        // possibly-wedged peer.
        guard let axReader else {
            return  // no reader in this wiring: finalize reads it as `late`
        }
        let started = axReader.read { [weak self] field in
            self?.deliverFieldText(generation: gen, field)
        }
        if !started {
            log.info("context capture dropped: AX reader busy")
            setRefusal(.busy)
        }
    }

    public func finishCapture() -> ContextOutcome {
        let policy = config.policy()
        lock.lock()
        let wasActive = active
        let verdict = refusal
        let snapshot = slot
        let arrived = arrivedAt
        let began = startedAt
        // The snapshot dies with the utterance — consumed or not, the slot is
        // empty from here on.
        active = false
        refusal = nil
        slot = nil
        arrivedAt = nil
        pendingWireGeneration = nil
        lock.unlock()

        guard wasActive else { return ContextOutcome() }
        if let verdict { return ContextOutcome(status: verdict) }
        guard let snapshot, let arrived else { return ContextOutcome(status: .late) }

        // Use-time recheck against the ARRIVAL clock: a reader that outlived
        // its budget is caught (the reason `capturedAt` exists), while a long
        // dictation is not punished for its own length — the text near the
        // cursor at key-down is no less true after thirty seconds of speech.
        if let refused = policy.refusalToUse(snapshot, now: arrived,
                                             environment: config.environment) {
            log.info("context snapshot refused at use: \(refused.rawValue, privacy: .public)")
            return ContextOutcome(status: refused == .stale ? .late : .off)
        }

        let clamped = policy.clamped(snapshot)
        let candidates = CandidateExtractor.candidates(in: clamped,
                                                       lexicon: lexicon,
                                                       maxTerms: config.maxTerms())
        return ContextOutcome(status: .read,
                              terms: candidates.map(\.term),
                              captureMs: arrived.timeIntervalSince(began) * 1000.0,
                              fieldText: clamped.before + clamped.selected + clamped.after)
    }

    // MARK: deliveries

    /// The IM wire's answer. Consumption rules exactly as `IMAppClient`
    /// documents them: generation-match against the read we posted, drop
    /// everything stale, and a detail that is a reason rather than a result is
    /// the same as no answer.
    public func deliverIMSnapshot(wireGeneration: UInt64, _ snapshot: IMContextSnapshot) {
        guard snapshot.detail.isUsable else { return }
        store(before: snapshot.before, selected: snapshot.selected, after: snapshot.after) {
            self.pendingWireGeneration == wireGeneration
        }
    }

    /// The AX reader's answer, stamped with the utterance it was started for.
    func deliverFieldText(generation: Int, _ field: ContextFieldText?) {
        guard let field else { return }
        store(before: field.before, selected: field.selected, after: field.after) {
            self.generation == generation
        }
    }

    /// Shared slot write. `stillWanted` runs under the lock, so the generation
    /// comparison and the write are one atomic step.
    private func store(before: String, selected: String, after: String,
                       stillWanted: () -> Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard active, refusal == nil, slot == nil, stillWanted() else { return }
        slot = ContextSnapshot(bundleID: bundleID,
                               before: before,
                               selected: selected,
                               after: after,
                               capturedAt: startedAt,
                               generation: generation)
        arrivedAt = config.clock()
    }

    private func setRefusal(_ status: ContextReadStatus) {
        lock.lock()
        refusal = status
        lock.unlock()
    }
}
