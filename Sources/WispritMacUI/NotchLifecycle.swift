import Foundation

/// How an utterance ended, as the notch shows it.
public enum NotchResult: String, Equatable, Sendable, CaseIterable {
    /// The words landed.
    case success
    /// Nothing to insert, and nothing wrong — silence, a tap, a clean miss.
    case missed
    /// Heard, too faint to read. An instruction, not an alarm.
    case tooQuiet
    /// Something of ours failed.
    case error
    /// Secure Keyboard Entry held the field; the text is in history.
    case blockedSecure
}

/// The post-release stage that is running.
public enum NotchProcessing: String, Equatable, Sendable {
    /// Grace, finalize, post-process, insert.
    case finalizing
    /// The Apple Intelligence pass — the long one.
    case refining
}

/// What the indicator is showing.
public enum NotchPhase: Equatable, Sendable {
    case hidden
    /// The key is down. `micLive` is false between key-down and the mic
    /// actually opening; only a live mic may be orange.
    case listening(micLive: Bool)
    case processing(NotchProcessing)
    case result(NotchResult)
    /// Folding back into the housing. Always ends in `.hidden`.
    case collapsing

    public var isVisible: Bool { self != .hidden }
}

/// Everything that can happen to the indicator.
public enum NotchSignal: Equatable, Sendable {
    /// Key-down accepted; mic not open yet.
    case prewarm
    /// The mic is open.
    case record
    /// One 20 Hz meter sample, raw 0…1.
    case level(Double)
    case processing(NotchProcessing)
    case result(NotchResult)
    /// Fold away now, without a result beat (`showIdle`, `hide`, Esc).
    case dismiss
    /// The session itself reports idle: no mic, nothing running. Folds a
    /// live or processing notch (a session path that ended without a pill
    /// call), never cuts a result beat short.
    case sessionIdle
    /// `pill_hidden` went on: gone this instant, no animation.
    case suppress

    enum Rank { case open, processing, terminal, local }

    var rank: Rank {
        switch self {
        case .prewarm, .record, .level: return .open
        case .processing: return .processing
        case .result, .dismiss: return .terminal
        case .sessionIdle, .suppress: return .local
        }
    }
}

/// The indicator's lifecycle as a pure value: no AppKit, no clock of its own.
///
/// **Termination is the contract.** From every visible phase there is a
/// deadline, and `advance(to:)` past it always moves toward `.hidden`:
///
/// | phase | leaves when | at the latest |
/// |---|---|---|
/// | `listening(micLive: false)` | `record` / a closing signal | `prewarmTimeout` after entry |
/// | `listening(micLive: true)` | a closing signal | `levelSilenceTimeout` after the last level tick |
/// | `processing` | a result / dismiss / session idle | `processingTimeout` after the last processing signal |
/// | `result` | its dwell | `dwell(for:)` after entry |
/// | `collapsing` | the view settles | `collapseBudget` after entry |
///
/// So any sequence of signals followed by silence ends hidden within
/// `worstCaseToHidden` seconds. `NotchLifecycleTests` checks that by brute
/// force over random signal sequences.
///
/// **Staleness.** A signal may carry the sequence number its caller stamped
/// *on the calling thread* (`NotchSequence`). Calls hop to main through a
/// queue, so a level tick taken on the ticker thread just before the session's
/// `showFinalizing` can land just after it. The fences make that harmless: an
/// opening signal older than the newest processing/terminal signal is
/// dropped, a processing signal older than the newest terminal one is
/// dropped, and nothing older than the utterance currently open applies.
/// An unstamped (nil) signal is applied as "now" and moves no fence — the
/// demo, the preview and the session-idle hook use that.
public struct NotchLifecycle: Equatable, Sendable {

    // MARK: - the bounds

    /// Key-down to mic-open is ~50 ms measured; a cold Bluetooth link can take
    /// a few seconds. Past this, the session has evidently moved on without us.
    public static let prewarmTimeout: TimeInterval = 4
    /// The level ticker runs at 20 Hz for as long as the mic is open. Three
    /// seconds without one means the utterance ended and we missed the call.
    public static let levelSilenceTimeout: TimeInterval = 3
    /// Refine can take ~7 s, finalize a few more in a rescue. Restarted by
    /// each processing signal.
    public static let processingTimeout: TimeInterval = 15
    /// The fold takes ~0.35 s; this is the hard stop if the frame clock
    /// stalls (display asleep, window server busy).
    public static let collapseBudget: TimeInterval = 0.6
    /// How long a session-idle report waits for the result call that usually
    /// follows it. The empty-utterance path reports idle *before* it flashes
    /// "missed"; folding at once would start a fold only to reopen it.
    public static let sessionIdleGrace: TimeInterval = 0.15

    public static func dwell(for result: NotchResult) -> TimeInterval {
        switch result {
        case .success: return 0.62
        case .missed: return 1.0
        case .tooQuiet: return 1.7
        case .error: return 1.7
        case .blockedSecure: return 2.4
        }
    }

    /// The longest any visible phase can last before a fold begins, plus the
    /// fold itself.
    public static var worstCaseToHidden: TimeInterval {
        max(prewarmTimeout, levelSilenceTimeout, processingTimeout,
            NotchResult.allCases.map(dwell(for:)).max() ?? 0) + collapseBudget
    }

    // MARK: - state

    public private(set) var phase: NotchPhase = .hidden
    public private(set) var enteredAt: TimeInterval = 0
    /// Last level tick (or the mic-open instant) — the silence watchdog's clock.
    public private(set) var lastLevelAt: TimeInterval = 0
    /// Last processing signal — the processing watchdog's clock.
    public private(set) var lastProcessingAt: TimeInterval = 0
    /// The most recent level, raw 0…1.
    public private(set) var level: Double = 0
    /// Bumped each time a new utterance (or an unprompted result) opens the
    /// notch, so the view can tell a fresh press from a continuing one.
    public private(set) var generation: Int = 0
    /// Screenshot aid: no watchdogs, no dwell. The dictation path never sets it.
    public var pinned = false
    /// When the session reported idle while we were still live or processing.
    public private(set) var sessionIdleAt: TimeInterval?

    /// Sequence of the utterance currently open (its first opening signal).
    private var utteranceSequence: UInt64 = 0
    /// Newest processing-or-terminal signal applied.
    private var closedSequence: UInt64 = 0
    /// Newest terminal signal applied.
    private var terminalSequence: UInt64 = 0

    public init() {}

    // MARK: - signals

    /// Apply one signal. Returns true when the phase changed.
    @discardableResult
    public mutating func receive(_ signal: NotchSignal, sequence: UInt64? = nil,
                                 at now: TimeInterval) -> Bool {
        if let sequence, isStale(signal, sequence) { return false }
        let before = phase

        switch signal {
        case .prewarm:
            // Always a new press. Even over a `listening(micLive: true)` that
            // somehow never closed, the new press's mic is not open yet — so
            // it starts grey, never inheriting the old orange.
            startUtterance(sequence, micLive: false, at: now)

        case .record:
            switch phase {
            case .listening(micLive: true):
                break
            case .listening(micLive: false):
                // The mic opened for the utterance on screen. The silence
                // watchdog starts now; ticks follow within 50 ms.
                phase = .listening(micLive: true)
                lastLevelAt = now
            case .hidden, .processing, .result, .collapsing:
                // Opened without a prewarm (suppressed, or a slow one the
                // watchdog folded): the mic is live, so say so.
                startUtterance(sequence, micLive: true, at: now)
            }

        case .level(let value):
            guard case .listening = phase else { return false }
            level = value.isFinite ? min(max(value, 0), 1) : 0
            lastLevelAt = now

        case .processing(let stage):
            fence(closed: sequence)
            lastProcessingAt = now
            level = 0
            if !phase.isVisible || phase == .collapsing { open(sequence) }
            if phase != .processing(stage) { enter(.processing(stage), at: now) }

        case .result(let kind):
            fence(closed: sequence, terminal: true)
            level = 0
            if !phase.isVisible || phase == .collapsing { open(sequence) }
            enter(.result(kind), at: now)

        case .dismiss:
            fence(closed: sequence, terminal: true)
            level = 0
            switch phase {
            case .hidden, .collapsing: break
            case .listening, .processing, .result: enter(.collapsing, at: now)
            }

        case .sessionIdle:
            switch phase {
            case .listening(micLive: true), .processing:
                // Arms a short fold; a result call inside the grace wins.
                if sessionIdleAt == nil { sessionIdleAt = now }
            case .hidden, .listening(micLive: false), .result, .collapsing:
                break
            }

        case .suppress:
            level = 0
            enter(.hidden, at: now)
        }
        return phase != before
    }

    private func isStale(_ signal: NotchSignal, _ seq: UInt64) -> Bool {
        switch signal.rank {
        case .open: return seq < closedSequence || seq < utteranceSequence
        case .processing: return seq < terminalSequence || seq < utteranceSequence
        case .terminal: return seq < utteranceSequence
        case .local: return false
        }
    }

    private mutating func fence(closed seq: UInt64?, terminal: Bool = false) {
        guard let seq else { return }
        closedSequence = max(closedSequence, seq)
        if terminal { terminalSequence = max(terminalSequence, seq) }
    }

    private mutating func open(_ seq: UInt64?) {
        generation += 1
        if let seq { utteranceSequence = max(utteranceSequence, seq) }
    }

    private mutating func startUtterance(_ seq: UInt64?, micLive: Bool, at now: TimeInterval) {
        open(seq)
        level = 0
        lastLevelAt = now
        enter(.listening(micLive: micLive), at: now)
    }

    private mutating func enter(_ next: NotchPhase, at now: TimeInterval) {
        phase = next
        enteredAt = now
        sessionIdleAt = nil
    }

    // MARK: - time

    /// When `advance(to:)` will next change the phase, if nothing else happens.
    public var deadline: TimeInterval? {
        if pinned && phase != .collapsing { return nil }
        guard let base = watchdog else { return nil }
        if let idle = sessionIdleAt { return min(base, idle + Self.sessionIdleGrace) }
        return base
    }

    private var watchdog: TimeInterval? {
        switch phase {
        case .hidden: return nil
        case .listening(micLive: false): return enteredAt + Self.prewarmTimeout
        case .listening(micLive: true): return lastLevelAt + Self.levelSilenceTimeout
        case .processing: return lastProcessingAt + Self.processingTimeout
        case .result(let kind): return enteredAt + Self.dwell(for: kind)
        case .collapsing: return enteredAt + Self.collapseBudget
        }
    }

    /// Run the watchdogs and dwells up to `now`. Returns true when the phase
    /// changed. Idempotent, and safe to call from any clock at any rate.
    @discardableResult
    public mutating func advance(to now: TimeInterval) -> Bool {
        let before = phase
        // At most two hops per call (visible → collapsing → hidden), each one
        // only when its own deadline has passed.
        for _ in 0..<2 {
            guard let due = deadline, now >= due else { break }
            switch phase {
            case .hidden: break
            case .collapsing: enter(.hidden, at: due)
            case .listening, .processing, .result: enter(.collapsing, at: due)
            }
        }
        return phase != before
    }

    /// The view has finished folding the body away.
    @discardableResult
    public mutating func collapseSettled(at now: TimeInterval) -> Bool {
        guard phase == .collapsing else { return false }
        enter(.hidden, at: now)
        return true
    }
}
