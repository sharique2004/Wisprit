import Foundation
import WispritIMProtocol
import WispritKit
import WispritPersistence

/// The two config keys live typing adds.
///
/// They are read through `Settings`' generic string-keyed accessors rather than
/// added to `SettingsKey`: `WispritPersistence` is frozen for this pass, and the
/// settings file already preserves keys it does not know about, so a config
/// written by either build round-trips intact.
public enum LiveTypingSettings {
    /// `live_typing` — off until the user runs onboarding and switches it on.
    public static let enabledKey = "live_typing"
    /// `im_selection_policy` — "warm" | "per_utterance".
    public static let selectionPolicyKey = "im_selection_policy"

    public static func isEnabled(_ settings: Settings) -> Bool {
        settings.bool(enabledKey, or: false)
    }

    public static func setEnabled(_ settings: Settings, _ value: Bool) {
        settings.set(enabledKey, value)
    }

    public static func selectionPolicy(_ settings: Settings) -> IMSelectionPolicy {
        switch settings.string(selectionPolicyKey, or: IMSelectionPolicy.default.rawValue) {
        case "per_utterance", IMSelectionPolicy.perUtterance.rawValue: return .perUtterance
        default: return .warm
        }
    }
}

/// Live in-field streaming, app side: the state machine that drives
/// `WispritIM.app` through one dictation and keeps the insertion ladder honest.
///
/// The shape of one utterance on rung 1:
///
///     Fn ↓   select the palette source (silent, no prompt) → beginSession
///            → clientAcquired(capabilities) → pick a rung
///     …      updateVolatile(tail) at partial cadence   (underlined, provisional)
///     Fn ↑   commitFinal(cleaned text)                 (one undo step)
///     later  applyEdit(replace:with:)                  (spoken-spelling fix)
///     idle   endSession(commit:) → deselect
///
/// Two rules the whole design hangs on:
///
///  * **Nothing here may lose text.** Every failure path returns "I did not
///    deliver it" and the session controller pastes instead. History is written
///    before insertion either way, so even a double failure leaves ⌘⌃V.
///  * **The IM session spans consecutive utterances, not one each.** The input
///    method resets its committed-text record on `beginSession`, so a
///    cross-utterance retroactive correction — "actually it's S-H-A-R-I-Q-U-E",
///    fixing a word committed by the *previous* utterance — is only possible
///    while the same session is still open. The session is closed by an idle
///    timeout, a focus change to another app, or shutdown.

// MARK: - Transport seam

/// What came back from the input method. Split three ways on purpose: the
/// underlying `CFMessagePort` round trip returns nil both for "delivered, no
/// event to report" and for "could not reach the process", and treating those the
/// same is how text goes missing.
public enum LiveTypingReply: Sendable, Equatable {
    case event(IMEventMessage)
    /// Delivered and handled; the input method had nothing to say.
    case acknowledged
    /// The input method could not be reached at all. Nothing was delivered.
    case unreachable
}

/// The system surface `LiveTypingSession` is written against — the message port
/// to `WispritIM.app` plus the two Text Input Source calls that are safe to make
/// per session (`TISSelectInputSource` / `TISDeselectInputSource` do not prompt).
///
/// `TISRegisterInputSource` and `TISEnableInputSource` are deliberately NOT here:
/// they change the user's system input configuration, they belong to onboarding,
/// and they live in `InputMethodInstaller` behind an explicit menu click.
public protocol LiveTypingPeer: AnyObject, Sendable {
    var isReachable: Bool { get }
    func exchange(_ message: IMCommandMessage, timeout: TimeInterval) -> LiveTypingReply
    @discardableResult
    func post(_ message: IMCommandMessage) -> Bool
    @discardableResult
    func selectInputSource() -> Bool
    func deselectInputSource()
    func inputMethodStatus() -> InputMethodStatus
    /// Unsolicited events (`clientLost` above all) arrive here.
    func startEvents(_ handler: @escaping @Sendable (IMEventMessage) -> Void)
    func stopEvents()

    // Wire v2's read channel (Phase 4 context awareness). Defaulted below so a
    // peer that predates reads — or a double that never needs them — conforms
    // unchanged, and the default IS the documented degradation: a read that
    // cannot be posted is simply no signal.

    /// Fire-and-forget read request. There is no blocking counterpart on
    /// purpose — nothing about a read is worth making the user wait for.
    @discardableResult
    func postRead(_ message: IMReadMessage) -> Bool
    /// Where read-back answers land, generation-stamped. nil drops them at the
    /// door, which is what a consumer that is switched off should do.
    func setSnapshotHandler(_ handler: (@Sendable (IMSnapshotMessage) -> Void)?)
}

public extension LiveTypingPeer {
    @discardableResult
    func postRead(_ message: IMReadMessage) -> Bool { false }
    func setSnapshotHandler(_ handler: (@Sendable (IMSnapshotMessage) -> Void)?) {}
}

// MARK: - Session controller seam

/// Outcome of handing the final text to the input method.
public enum LiveTypingCommit: Sendable, Equatable {
    /// The text is in the field. `tier` is what goes in `metrics.log`.
    case committed(InsertionTier)
    /// Nothing was written — the caller must fall through to the paste rung.
    case fallback(reason: String)
}

/// The slice of live typing the session state machine talks to. A nil port is
/// the Phase-1 behaviour, unchanged.
public protocol LiveTypingPort: AnyObject, Sendable {
    /// Fn-down. Picks the rung for this utterance and opens/reuses an IM session.
    @discardableResult
    func beginUtterance() -> InsertionTier
    /// The rung picked at key-down, lowered live if the client degrades.
    var tier: InsertionTier { get }
    /// Rung 1 AND a client still attached — the pill bubble is suppressed
    /// exactly when this is true, so words never appear in two places.
    var isStreaming: Bool { get }
    /// Rung 1 or 2 — worth offering the final text to.
    var isEngaged: Bool { get }
    /// A growing partial, rendered as underlined marked text.
    func streamPartial(_ text: String)
    /// Take the provisional tail back down (cancel, empty result, error).
    func discardTail()
    func commit(_ text: String) -> LiveTypingCommit
    /// Retroactive correction over already-committed text. nil = the tier cannot
    /// do it at all, so the caller keeps the learn-and-notice behaviour.
    func applyRetroEdit(replace: String, with: String) -> IMEditResult?
    /// Fn-up bookkeeping. Does NOT close the IM session — idle does.
    func endUtterance()
    /// Called from the session run loop; closes an idle session and deselects.
    func tickIdle()
    /// Quit: commit anything marked, close, deselect, stop listening.
    func shutdown()
}

// MARK: - Configuration

public struct LiveTypingConfiguration: Sendable {
    /// The `live_typing` setting, read fresh at every key-down.
    public var isEnabled: @Sendable () -> Bool
    /// `terminal_bundle_ids`, for the rung-4 decision.
    public var terminalBundleIDs: @Sendable () -> [String]
    /// Frontmost application bundle id, used to notice a focus change between
    /// utterances (the committed-text anchor belongs to one field).
    public var frontmostBundleID: @Sendable () -> String?
    /// `Permissions.secureInput().active`.
    public var secureInputActive: @Sendable () -> Bool
    /// Close the session and give the input source back after this long with no
    /// dictation. Research V8: staying selected is what keeps the process warm,
    /// so this is generous rather than aggressive.
    public var idleTimeout: TimeInterval
    public var selectionPolicy: IMSelectionPolicy
    /// Round-trip budget for a command that must be answered.
    public var commandTimeout: TimeInterval

    public init(isEnabled: @escaping @Sendable () -> Bool = { false },
                terminalBundleIDs: @escaping @Sendable () -> [String] = { [] },
                frontmostBundleID: @escaping @Sendable () -> String? = { nil },
                secureInputActive: @escaping @Sendable () -> Bool = { false },
                idleTimeout: TimeInterval = 20,
                selectionPolicy: IMSelectionPolicy = .default,
                commandTimeout: TimeInterval = 1.0) {
        self.isEnabled = isEnabled
        self.terminalBundleIDs = terminalBundleIDs
        self.frontmostBundleID = frontmostBundleID
        self.secureInputActive = secureInputActive
        self.idleTimeout = idleTimeout
        self.selectionPolicy = selectionPolicy
        self.commandTimeout = commandTimeout
    }
}

// MARK: - The state machine

public final class LiveTypingSession: LiveTypingPort, @unchecked Sendable {

    private let log = WLog.logger("live-typing")
    private let peer: any LiveTypingPeer
    private let counter: IMGenerationCounter
    private let cache: BundleCapabilityCache
    private let config: LiveTypingConfiguration
    private let clock: @Sendable () -> Date

    private let lock = NSLock()

    /// Generation of the OPEN IM session, if one is open.
    private var generation: UInt64?
    private var capabilities: IMClientCapabilities?
    private var clientAlive = false
    private var currentTier: InsertionTier = .paste
    private var sourceSelected = false
    /// Bundle id the open session is anchored to.
    private var boundBundleID: String?
    private var lastActivity = Date.distantPast
    private var tailIsLive = false
    /// Phase 5: the app-side mirror of the input method's own committed-text
    /// record — every commit appended, every applied retro edit rewritten,
    /// replaced when a new session opens. This is what a `committedSnapshot`
    /// gets diffed against, so it deliberately SURVIVES session close: the
    /// close-time read's answer arrives after `endSession`, and the input
    /// method keeps its record until the next `beginSession` for the same
    /// reason.
    private var committedRecord: (generation: UInt64, text: String)?
    /// Wire-v2 snapshot consumers. One peer handler slot exists, so the routes
    /// live here and a single installed router fans out by snapshot kind.
    private var contextRoute: (@Sendable (UInt64, IMContextSnapshot) -> Void)?
    private var committedRoute: (@Sendable (UInt64, IMCommittedSnapshot) -> Void)?

    public init(peer: any LiveTypingPeer,
                cache: BundleCapabilityCache = BundleCapabilityCache(),
                counter: IMGenerationCounter = IMGenerationCounter(),
                configuration: LiveTypingConfiguration = LiveTypingConfiguration(),
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.peer = peer
        self.cache = cache
        self.counter = counter
        self.config = configuration
        self.clock = clock
    }

    /// Start listening for `clientLost` / `clientAcquired`. Call once at wiring
    /// time; safe to skip in tests that drive the fake peer directly.
    public func start() {
        peer.startEvents { [weak self] event in self?.handle(event) }
    }

    public var capabilitySnapshot: IMClientCapabilities? {
        lock.lock(); defer { lock.unlock() }
        return capabilities
    }

    // MARK: Wire v2 reads (Phase 4)

    /// Post `readContext` for the OPEN session and return the wire generation
    /// the read named — the value the answer must match to be believed. nil
    /// when the IM rung cannot serve a read right now (no live client, no open
    /// session, or the post itself failed), which is the caller's cue to fall
    /// back to the AX reader. Fire-and-forget, exactly like a live partial.
    public func requestContextRead() -> UInt64? {
        lock.lock()
        let engaged = currentTier.usesInputMethod && clientAlive
        let g = generation
        lock.unlock()
        guard engaged, let g else { return nil }
        return peer.postRead(.readContext(generation: g)) ? g : nil
    }

    /// Route wire-v2 CONTEXT snapshots to one consumer, generation attached so
    /// the consumer can drop an answer that lost the race.
    public func onContextSnapshot(
        _ handler: @escaping @Sendable (UInt64, IMContextSnapshot) -> Void
    ) {
        lock.lock(); contextRoute = handler; lock.unlock()
        installSnapshotRouter()
    }

    /// Route wire-v2 COMMITTED snapshots (Phase 5's edit observation) the same
    /// way. A build that never calls this drops them at the door — the
    /// channel's own rule for an answer nothing consumes.
    public func onCommittedSnapshot(
        _ handler: @escaping @Sendable (UInt64, IMCommittedSnapshot) -> Void
    ) {
        lock.lock(); committedRoute = handler; lock.unlock()
        installSnapshotRouter()
    }

    /// One peer handler, fanned out by snapshot kind. Idempotent — the second
    /// consumer's registration re-installs the same router.
    private func installSnapshotRouter() {
        peer.setSnapshotHandler { [weak self] message in
            guard let self else { return }
            self.lock.lock()
            let context = self.contextRoute
            let committed = self.committedRoute
            self.lock.unlock()
            switch message.snapshot {
            case .contextSnapshot(let snapshot):
                context?(message.generation, snapshot)
            case .committedSnapshot(let snapshot):
                committed?(message.generation, snapshot)
            }
        }
    }

    /// The mirror `committedSnapshot` answers are diffed against: what this
    /// session committed under `generation`, retro edits included. nil when the
    /// record is for some other session or nothing was committed — in which
    /// case an answer stamped with that generation is not ours to interpret.
    public func committedText(for generation: UInt64) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let record = committedRecord, record.generation == generation,
              !record.text.isEmpty else { return nil }
        return record.text
    }

    /// Post `readCommitted` for the run this session has committed. nil when
    /// there is nothing to ask about — no open session, no live client, or no
    /// commit on record. Fire-and-forget, exactly like a context read: a read
    /// that cannot be posted is simply no signal.
    @discardableResult
    public func requestCommittedRead() -> UInt64? {
        lock.lock()
        let g = generation
        let alive = clientAlive
        let record = committedRecord
        lock.unlock()
        guard let g, alive, let record, record.generation == g else { return nil }
        return peer.postRead(.readCommitted(generation: g)) ? g : nil
    }

    public var isSessionOpen: Bool {
        lock.lock(); defer { lock.unlock() }
        return generation != nil
    }

    // MARK: LiveTypingPort

    public var tier: InsertionTier {
        lock.lock(); defer { lock.unlock() }
        return currentTier
    }

    public var isStreaming: Bool {
        lock.lock(); defer { lock.unlock() }
        return currentTier.streamsLiveTail && clientAlive && generation != nil
    }

    public var isEngaged: Bool {
        lock.lock(); defer { lock.unlock() }
        return currentTier.usesInputMethod && clientAlive && generation != nil
    }

    @discardableResult
    public func beginUtterance() -> InsertionTier {
        let front = config.frontmostBundleID()
        let secure = config.secureInputActive()
        let enabled = config.isEnabled()
        let terminals = config.terminalBundleIDs()

        // Cheap outs first: never touch the input source when live typing is off
        // or when Secure Input has the keyboard.
        guard enabled, !secure else {
            let context = InsertionContext(liveTypingEnabled: enabled,
                                           secureInputActive: secure,
                                           frontmostBundleID: front,
                                           terminalBundleIDs: terminals)
            closeSession(commit: true, releaseSource: true)
            return setTier(InsertionLadder.tier(context))
        }

        let status = peer.inputMethodStatus()
        let usable = IMPreflight.evaluate(status).isUsable
        guard usable else {
            log.info("live typing unavailable: \(IMPreflight.remedy(for: IMPreflight.evaluate(status)), privacy: .public)")
            return setTier(InsertionLadder.tier(InsertionContext(
                liveTypingEnabled: enabled,
                inputMethodUsable: false,
                secureInputActive: secure,
                frontmostBundleID: front,
                terminalBundleIDs: terminals)))
        }

        selectSourceIfNeeded(status)

        // A focus change to a different app invalidates the committed-text
        // anchor the open session is holding: close it rather than let a
        // retro-edit reach into the wrong document.
        lock.lock()
        let openElsewhere = generation != nil && boundBundleID != nil && front != nil
            && boundBundleID != front
        lock.unlock()
        if openElsewhere { closeSession(commit: true, releaseSource: false) }

        // Phase 5, the key-down half of edit observation: before this utterance
        // writes a character into a REUSED session's field, ask what became of
        // the text the previous one left there. Fire-and-forget — the answer
        // races nothing and lands off-path. (A session closed above already
        // posted its own last read from `closeSession`.)
        if isSessionOpen { requestCommittedRead() }

        if !isSessionOpen { openSession() }

        lock.lock()
        let caps = capabilities
        let alive = clientAlive
        lock.unlock()

        let context = InsertionContext(
            liveTypingEnabled: enabled,
            inputMethodUsable: true,
            inputMethodReachable: alive && peer.isReachable,
            capabilities: caps,
            cachedVerdict: cache.verdict(for: caps?.bundleID ?? front),
            secureInputActive: secure,
            frontmostBundleID: front,
            terminalBundleIDs: terminals)
        let chosen = InsertionLadder.tier(context)
        switch chosen {
        case .imStreaming: cache.observe(.markedStreaming, for: caps?.bundleID, reason: "probe")
        case .imCommit: cache.observe(.commitOnly, for: caps?.bundleID, reason: "probe")
        default: break
        }
        touch()
        return setTier(chosen)
    }

    public func streamPartial(_ text: String) {
        lock.lock()
        let ok = currentTier.streamsLiveTail && clientAlive
        let g = generation
        lock.unlock()
        guard ok, let g else { return }
        if peer.post(.updateVolatile(generation: g, tail: text)) {
            lock.lock(); tailIsLive = !text.isEmpty; lock.unlock()
            touch()
        }
        // A dropped partial is lossless: `commitFinal` always carries the whole
        // stable text, so there is nothing to retry and nothing to downgrade on.
    }

    public func discardTail() {
        lock.lock()
        let live = tailIsLive
        let g = generation
        let engaged = currentTier.usesInputMethod && clientAlive
        lock.unlock()
        guard live, engaged, let g else { return }
        _ = peer.post(.updateVolatile(generation: g, tail: ""))
        lock.lock(); tailIsLive = false; lock.unlock()
    }

    public func commit(_ text: String) -> LiveTypingCommit {
        lock.lock()
        let engaged = currentTier.usesInputMethod && clientAlive
        let g = generation
        let tier = currentTier
        let bundleID = capabilities?.bundleID
        lock.unlock()

        guard engaged, let g else { return .fallback(reason: "no input-method session") }
        guard peer.isReachable else {
            markClientLost(reason: "input method unreachable")
            return .fallback(reason: "input method unreachable")
        }

        switch peer.exchange(.commitFinal(generation: g, text: text),
                             timeout: max(config.commandTimeout, 1.0)) {
        case .acknowledged:
            // `commitFinal` answers only when something went wrong, so silence
            // from a reachable process is the success case.
            touch()
            lock.lock()
            tailIsLive = false
            appendCommittedLocked(g, text)
            lock.unlock()
            return .committed(tier)

        case .event(let message):
            switch message.event {
            case .clientLost(let reason):
                markClientLost(reason: reason)
                return .fallback(reason: "client lost: \(reason)")
            case .editResult(let result) where !result.ok:
                cache.downgrade(for: bundleID, detail: result.detail, note: result.note)
                lowerTier(after: result.detail)
                log.warning("""
                    commit refused (\(result.detail.rawValue, privacy: .public)) — \
                    falling back to paste
                    """)
                return .fallback(reason: result.detail.rawValue)
            default:
                touch()
                lock.lock()
                tailIsLive = false
                appendCommittedLocked(g, text)
                lock.unlock()
                return .committed(tier)
            }

        case .unreachable:
            // The transport failed, so the message never landed: pasting cannot
            // duplicate anything.
            markClientLost(reason: "commit could not be delivered")
            return .fallback(reason: "input method unreachable")
        }
    }

    public func applyRetroEdit(replace: String, with replacement: String) -> IMEditResult? {
        lock.lock()
        let engaged = currentTier.usesInputMethod && clientAlive
        let g = generation
        let caps = capabilities
        lock.unlock()

        guard engaged, let g else { return nil }
        guard !replace.isEmpty else { return .failed(.emptyEdit) }
        // Without TSMDocumentAccess an absolute replacement range is silently
        // discarded and the "correction" lands at the end of the field. Refuse
        // here rather than let the input method discover it: the caller then
        // keeps the learn-and-notice behaviour, which is honest.
        guard IMDeliveryTier.supportsRetroEdit(caps) else {
            return .failed(.noDocumentAccess, note: caps?.bundleID ?? "")
        }

        switch peer.exchange(.applyEdit(generation: g, replace: replace, with: replacement),
                             timeout: max(config.commandTimeout, 1.0)) {
        case .event(let message):
            switch message.event {
            case .editResult(let result):
                if !result.ok {
                    cache.downgrade(for: caps?.bundleID, detail: result.detail, note: result.note)
                    lowerTier(after: result.detail)
                } else {
                    // The input method rewrote its committed record; the mirror
                    // follows, or the next `committedSnapshot` would read our
                    // own fix as somebody's edit.
                    rewriteCommitted(g, replace: replace, with: replacement)
                }
                touch()
                return result
            case .clientLost(let reason):
                markClientLost(reason: reason)
                return .failed(.noClient, note: reason)
            case .clientAcquired:
                return nil
            }
        case .acknowledged:
            // `applyEdit` always answers. Silence means we cannot prove the edit
            // landed, and claiming it did would show the user a "Fixed …" notice
            // for a word that never changed.
            return nil
        case .unreachable:
            markClientLost(reason: "edit could not be delivered")
            return .failed(.noClient, note: "input method unreachable")
        }
    }

    public func endUtterance() {
        touch()
        lock.lock(); tailIsLive = false; lock.unlock()
    }

    public func tickIdle() {
        lock.lock()
        let open = generation != nil
        let idleFor = clock().timeIntervalSince(lastActivity)
        lock.unlock()
        guard open, idleFor > config.idleTimeout else { return }
        log.info("live typing idle for \(Int(idleFor), privacy: .public)s — releasing the input source")
        closeSession(commit: true, releaseSource: true)
    }

    public func shutdown() {
        closeSession(commit: true, releaseSource: true)
        peer.stopEvents()
    }

    // MARK: - Session lifecycle

    private func openSession() {
        let g = counter.next()
        switch peer.exchange(.beginSession(generation: g), timeout: max(config.commandTimeout, 1.0)) {
        case .event(let message):
            switch message.event {
            case .clientAcquired(let caps):
                lock.lock()
                generation = g
                capabilities = caps
                clientAlive = true
                boundBundleID = caps.bundleID.isEmpty ? config.frontmostBundleID() : caps.bundleID
                tailIsLive = false
                // The input method's `beginSession` starts an empty committed
                // record; the mirror starts empty with it.
                committedRecord = nil
                lock.unlock()
                log.info("""
                    live typing session \(g, privacy: .public) open in \
                    \(caps.bundleID, privacy: .public) (unicode \(caps.supportsUnicode, privacy: .public), \
                    document access \(caps.supportsDocumentAccess, privacy: .public))
                    """)
            case .clientLost(let reason):
                log.info("no text field for live typing: \(reason, privacy: .public)")
                resetSessionState()
            case .editResult(let result):
                log.warning("beginSession refused: \(result.detail.rawValue, privacy: .public)")
                resetSessionState()
            }
        case .acknowledged, .unreachable:
            resetSessionState()
        }
    }

    private func closeSession(commit: Bool, releaseSource: Bool) {
        lock.lock()
        let g = generation
        let record = committedRecord
        lock.unlock()
        if let g {
            // Phase 5, the close half: the last chance to see what the user did
            // to the run this session committed. Legal after `endSession` too —
            // the input method answers for the last generation it served — but
            // posted before it so the read cannot lose a race with a peer
            // shutdown. The answer lands on the snapshot router whenever it
            // lands; `committedRecord` survives `resetSessionState` for exactly
            // that reason.
            if let record, record.generation == g {
                _ = peer.postRead(.readCommitted(generation: g))
            }
            _ = peer.exchange(.endSession(generation: g, commit: commit),
                              timeout: max(config.commandTimeout, 0.5))
        }
        resetSessionState()
        if releaseSource { releaseSourceIfNeeded() }
    }

    private func resetSessionState() {
        lock.lock()
        generation = nil
        capabilities = nil
        clientAlive = false
        boundBundleID = nil
        tailIsLive = false
        lock.unlock()
    }

    private func selectSourceIfNeeded(_ status: InputMethodStatus) {
        guard !status.selected else {
            lock.lock(); sourceSelected = true; lock.unlock()
            return
        }
        // Silent and prompt-free (unlike TISEnableInputSource), and legal for a
        // palette source: "zero or more of these can be selected".
        if peer.selectInputSource() {
            lock.lock(); sourceSelected = true; lock.unlock()
        }
    }

    private func releaseSourceIfNeeded() {
        lock.lock()
        let held = sourceSelected
        sourceSelected = false
        lock.unlock()
        guard held else { return }
        peer.deselectInputSource()
    }

    // MARK: - Events

    /// Unsolicited event from `WispritIM.app`.
    func handle(_ message: IMEventMessage) {
        switch message.event {
        case .clientLost(let reason):
            markClientLost(reason: reason)
        case .clientAcquired(let caps):
            lock.lock()
            if generation == message.generation {
                capabilities = caps
                clientAlive = true
            }
            lock.unlock()
        case .editResult:
            break
        }
    }

    /// The field went away mid-utterance. Everything still to be written falls to
    /// the paste rung; history was written before insertion, so nothing is lost.
    private func markClientLost(reason: String) {
        lock.lock()
        let had = clientAlive || generation != nil
        clientAlive = false
        generation = nil
        capabilities = nil
        boundBundleID = nil
        tailIsLive = false
        currentTier = fallbackTierLocked()
        lock.unlock()
        if had {
            log.info("live typing client lost (\(reason, privacy: .public)) — pasting instead")
        }
    }

    /// A failure detail that means "this rung is gone" lowers the live tier so the
    /// rest of the utterance stops trying.
    private func lowerTier(after detail: IMEditDetail) {
        lock.lock()
        switch detail {
        case .notSupported:
            currentTier = currentTier == .imStreaming ? .imCommit : fallbackTierLocked()
        case .noClient, .noSession, .staleGeneration:
            currentTier = fallbackTierLocked()
            clientAlive = false
        default:
            break
        }
        lock.unlock()
    }

    /// Caller holds `lock`. Appends to the mirror for the session that owns it,
    /// or starts it — the input method's own record accumulates across the
    /// utterances one session spans, and the mirror must accumulate with it.
    private func appendCommittedLocked(_ generation: UInt64, _ text: String) {
        guard !text.isEmpty else { return }
        if var record = committedRecord, record.generation == generation {
            record.text += text
            committedRecord = record
        } else {
            committedRecord = (generation, text)
        }
    }

    /// Mirror an APPLIED retro edit: backwards-last occurrence, the same
    /// occurrence rule `RetroEditPlanner` resolves inside the input method.
    private func rewriteCommitted(_ generation: UInt64, replace: String, with replacement: String) {
        lock.lock(); defer { lock.unlock() }
        guard var record = committedRecord, record.generation == generation,
              let range = record.text.range(of: replace, options: .backwards) else { return }
        record.text.replaceSubrange(range, with: replacement)
        committedRecord = record
    }

    /// Caller holds `lock`.
    private func fallbackTierLocked() -> InsertionTier {
        let front = config.frontmostBundleID()
        if config.secureInputActive() { return .blockedSecure }
        if let front, config.terminalBundleIDs().contains(front) { return .typed }
        return .paste
    }

    @discardableResult
    private func setTier(_ tier: InsertionTier) -> InsertionTier {
        lock.lock(); currentTier = tier; lock.unlock()
        return tier
    }

    private func touch() {
        lock.lock(); lastActivity = clock(); lock.unlock()
    }
}
