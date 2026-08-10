import Foundation

/// The wire contract between `Wisprit.app` (menu-bar app: audio, ASR, refine,
/// dictionary) and `WispritIM.app` (the palette input method that puts text in
/// the field while you speak).
///
/// Shape of the conversation, one dictation utterance:
///
///     app → IM   beginSession(generation: n)
///     IM  → app  clientAcquired(capabilities)      // or clientLost
///     app → IM   updateVolatile(tail: "quick brow")   ×N   (marked, underlined)
///     app → IM   commitFinal(text: "The quick brown ")     (unmarked, 1 undo step)
///     app → IM   applyEdit(replace: "Sharik", with: "Sharique", occurrence: .last)
///     IM  → app  editResult(ok:detail:)
///     app → IM   endSession(commit: true)
///
/// Every message carries the session `generation`. The IM refuses anything whose
/// generation is not the one it is currently serving, which is what makes it
/// impossible for a stale IM process (or a late delivery) to write into a
/// field that now belongs to a newer utterance.
///
/// Wire v2 adds a second, strictly read-only conversation alongside it — see
/// `IMReadBack.swift`. It is fire-and-forget in both directions:
///
///     app → IM   readContext                      (posted at key-down)
///     IM  → app  contextSnapshot(before:selected:after:)
///     app → IM   readCommitted                    (posted after the words land)
///     IM  → app  committedSnapshot(current:detail:)
public enum WispritIMWire {
    /// Bump on any incompatible change to the payloads below. The receiver
    /// rejects messages it cannot represent instead of guessing.
    public static let version = 2
    /// Oldest version this build still understands.
    public static let minimumSupportedVersion = 1

    // CONTRACT-DEVIATION: the plan said "wire v2", which reads as "stamp
    // everything 2". Messages are stamped with the version at which THEIR
    // channel was frozen instead, because stamping the write channel 2 would
    // make a v2 app unable to type through a v1 input method at all — the whole
    // feature would fail closed over an addition that has nothing to do with
    // putting words in the field. Stamped this way, a stale IM refuses exactly
    // the v2-only read commands and the app degrades to no-signal, which is the
    // degradation the plan actually asks for.
    /// The version at which the write channel (`IMCommand` / `IMEvent` — the
    /// messages that touch the user's text) was last changed. Commands and
    /// events are stamped with this, never with `version`.
    public static let writeChannelVersion = 1
    /// The version the read-back channel (`IMRead` / `IMSnapshot`) arrived in.
    /// A build older than this cannot represent a read and stays silent.
    public static let readChannelVersion = 2

    /// Can a receiver whose newest wire version is `build` represent a message
    /// stamped `version`? Parameterised so the compatibility rule is a pure
    /// function of two numbers rather than of whichever build is asking — which
    /// is how the stale-input-method case gets a test.
    public static func isSupported(_ version: Int, by build: Int = WispritIMWire.version) -> Bool {
        version >= minimumSupportedVersion && version <= build
    }
}

// MARK: - Capabilities

/// What the IM learned about the focused text field the moment it got a client.
/// The app uses this to pick a tier in the insertion ladder before it sends a
/// single character (see `IMDeliveryTier`).
public struct IMClientCapabilities: Codable, Sendable, Equatable {
    /// `[client supportsUnicode]`. IPAPalette treats NO as a hard error and so
    /// do we: the whole IM tier is skipped and the app falls back to pasting.
    public var supportsUnicode: Bool
    /// `[client bundleIdentifier]` — the key the app caches tier verdicts under.
    public var bundleID: String
    // CONTRACT-DEVIATION: the plan's capabilities were {supportsUnicode, bundleID}.
    // `supportsDocumentAccess` is added because it is the gate for the headline
    // feature: without TSMDocumentAccess a retroactive correction is silently
    // appended to the end of the field instead of replacing the wrong word.
    /// `[client supportsProperty: kTSMDocumentSupportDocumentAccessPropertyTag]`.
    /// Research verification V1: without TSMDocumentAccess the `replacementRange`
    /// of `insertText:replacementRange:` is *silently discarded*, and the read
    /// side (`stringFromRange:`) returns nil/NSNotFound. Retroactive correction
    /// is only offered when this is true; otherwise corrections have to happen
    /// before commit, while the text is still marked.
    public var supportsDocumentAccess: Bool
    /// `[client uniqueClientIdentifierString]`, when the client provides one.
    /// Purely diagnostic — never used to address a field.
    public var clientID: String

    public init(supportsUnicode: Bool,
                bundleID: String,
                supportsDocumentAccess: Bool,
                clientID: String = "") {
        self.supportsUnicode = supportsUnicode
        self.bundleID = bundleID
        self.supportsDocumentAccess = supportsDocumentAccess
        self.clientID = clientID
    }
}

// MARK: - Edits

/// A retroactive correction: "the word you already committed is wrong, here is
/// the right one". Deliberately expressed as *text*, not as a range — the IM
/// re-reads the live document and computes the range itself, because any offset
/// the app cached can be stale by the time it arrives (the user may have typed).
public struct IMEdit: Codable, Sendable, Equatable {
    public enum Occurrence: String, Codable, Sendable, Equatable, CaseIterable {
        /// The last occurrence inside the text THIS session committed.
        case last
    }

    public var replace: String
    public var with: String
    public var occurrence: Occurrence

    public init(replace: String, with: String, occurrence: Occurrence = .last) {
        self.replace = replace
        self.with = with
        self.occurrence = occurrence
    }
}

/// Why an edit did or did not land. The raw strings are stable: they end up in
/// `metrics.log` and in the tier-verdict cache keyed by bundle id.
public enum IMEditDetail: String, Codable, Sendable, Equatable, CaseIterable {
    case applied
    /// No IMKTextInput client — the IM is not the active input method, or the
    /// focused thing is not a text field.
    case noClient
    /// The message belongs to an older (or newer) session than the one open.
    case staleGeneration
    /// Client does not support TSMDocumentAccess: the replacement range would be
    /// silently dropped, so we refuse rather than append the correction.
    case noDocumentAccess
    /// `stringFromRange:` gave us nothing to verify against.
    case readFailed
    /// The word to fix is not in the text this session committed.
    case targetNotFound
    /// The document no longer contains what we committed where we committed it —
    /// the user typed, clicked, or the app rewrote the field. Never guess.
    case fieldChanged
    /// Our committed text appears more than once and we cannot tell which run is
    /// ours. Also an abort, for the same reason.
    case ambiguousRelocation
    /// `supportsUnicode == false`, or marked text already degraded this session.
    case notSupported
    /// Empty `replace` — nothing to look for.
    case emptyEdit
    /// The session ended (or never began) before the edit arrived.
    case noSession
}

public struct IMEditResult: Codable, Sendable, Equatable {
    public var ok: Bool
    public var detail: IMEditDetail
    /// Optional human note for the log (never shown in the field).
    public var note: String

    public init(ok: Bool, detail: IMEditDetail, note: String = "") {
        self.ok = ok
        self.detail = detail
        self.note = note
    }

    public static func applied(note: String = "") -> IMEditResult {
        IMEditResult(ok: true, detail: .applied, note: note)
    }

    public static func failed(_ detail: IMEditDetail, note: String = "") -> IMEditResult {
        IMEditResult(ok: false, detail: detail, note: note)
    }
}

// MARK: - Commands (app → IM)

public enum IMCommand: Codable, Sendable, Equatable {
    /// Open a session. The generation in the envelope becomes the only one the
    /// IM will serve until `endSession`.
    case beginSession
    /// Commit a stable chunk: one `insertText:` → one undo step in the target app.
    case commitFinal(text: String)
    /// Replace the provisional tail: one `setMarkedText:` → underlined text,
    /// wholesale-replaced at partial cadence (3–10 Hz, far below what CJK IMEs
    /// already sustain).
    case updateVolatile(tail: String)
    /// Retroactive correction over already-committed text.
    case applyEdit(IMEdit)
    /// Close the session. `commit: false` drops the still-marked tail.
    case endSession(commit: Bool)

    /// Stable name for logs/metrics.
    public var name: String {
        switch self {
        case .beginSession: return "begin_session"
        case .commitFinal: return "commit_final"
        case .updateVolatile: return "update_volatile"
        case .applyEdit: return "apply_edit"
        case .endSession: return "end_session"
        }
    }
}

// MARK: - Events (IM → app)

public enum IMEvent: Codable, Sendable, Equatable {
    /// The IM has a live text field and here is what it can do.
    case clientAcquired(IMClientCapabilities)
    /// Focus left, the IM was deselected, or the app quit under us. The session
    /// controller must fall back to the paste tier for whatever is left.
    case clientLost(reason: String)
    /// Outcome of an `applyEdit`.
    case editResult(IMEditResult)

    public var name: String {
        switch self {
        case .clientAcquired: return "client_acquired"
        case .clientLost: return "client_lost"
        case .editResult: return "edit_result"
        }
    }
}

// MARK: - Envelopes

/// The one thing every envelope on this wire has in common: it says which
/// version wrote it, so the receiver can refuse rather than half-decode.
public protocol IMWireMessage: Codable, Sendable {
    var wireVersion: Int { get }
}

// CONTRACT-DEVIATION: the plan put the generation on `beginSession` only. It is
// on EVERY message instead — a stale `updateVolatile` or `applyEdit` arriving
// after the next utterance has begun is exactly the case the counter exists to
// stop, and it cannot be stopped without a generation to compare.
/// Versioned, generation-stamped command envelope. `Codable` is the source of
/// truth; `WispritIMPayload` carries it across the port as `NSSecureCoding`.
public struct IMCommandMessage: IMWireMessage, Equatable {
    public var wireVersion: Int
    public var generation: UInt64
    public var command: IMCommand

    public init(generation: UInt64, command: IMCommand,
                wireVersion: Int = WispritIMWire.writeChannelVersion) {
        self.wireVersion = wireVersion
        self.generation = generation
        self.command = command
    }

    public static func beginSession(generation: UInt64) -> IMCommandMessage {
        IMCommandMessage(generation: generation, command: .beginSession)
    }

    public static func commitFinal(generation: UInt64, text: String) -> IMCommandMessage {
        IMCommandMessage(generation: generation, command: .commitFinal(text: text))
    }

    public static func updateVolatile(generation: UInt64, tail: String) -> IMCommandMessage {
        IMCommandMessage(generation: generation, command: .updateVolatile(tail: tail))
    }

    public static func applyEdit(generation: UInt64,
                                 replace: String,
                                 with: String,
                                 occurrence: IMEdit.Occurrence = .last) -> IMCommandMessage {
        IMCommandMessage(generation: generation,
                         command: .applyEdit(IMEdit(replace: replace, with: with, occurrence: occurrence)))
    }

    public static func endSession(generation: UInt64, commit: Bool) -> IMCommandMessage {
        IMCommandMessage(generation: generation, command: .endSession(commit: commit))
    }
}

public struct IMEventMessage: IMWireMessage, Equatable {
    public var wireVersion: Int
    public var generation: UInt64
    public var event: IMEvent

    public init(generation: UInt64, event: IMEvent,
                wireVersion: Int = WispritIMWire.writeChannelVersion) {
        self.wireVersion = wireVersion
        self.generation = generation
        self.event = event
    }

    public static func clientAcquired(generation: UInt64, _ caps: IMClientCapabilities) -> IMEventMessage {
        IMEventMessage(generation: generation, event: .clientAcquired(caps))
    }

    public static func clientLost(generation: UInt64, reason: String) -> IMEventMessage {
        IMEventMessage(generation: generation, event: .clientLost(reason: reason))
    }

    public static func editResult(generation: UInt64, _ result: IMEditResult) -> IMEventMessage {
        IMEventMessage(generation: generation, event: .editResult(result))
    }
}

// MARK: - Generation gate

/// The rule that makes a stale process harmless.
///
/// Generations are strictly increasing per app launch (the app uses a counter;
/// a restarted app must not reuse a lower one — `IMGenerationGate.seed` exists
/// for that). The IM serves exactly one generation at a time and rejects
/// everything else, so a message that was in flight when the user released Fn
/// and started a new utterance is dropped instead of being written into the new
/// field.
public struct IMGenerationGate: Sendable, Equatable {
    public enum Decision: Sendable, Equatable {
        case accept
        /// Message belongs to a session that is over (or to a future one we have
        /// not been told about).
        case rejectStale(current: UInt64)
        /// No session is open at all.
        case rejectNoSession
    }

    /// Highest generation ever seen, open or closed.
    public private(set) var highWaterMark: UInt64
    /// The generation currently being served, if a session is open.
    public private(set) var openGeneration: UInt64?

    public init(highWaterMark: UInt64 = 0) {
        self.highWaterMark = highWaterMark
        self.openGeneration = nil
    }

    public var isOpen: Bool { openGeneration != nil }

    /// Open a session. Only a strictly-newer generation may open one; a repeat
    /// or a rewind is a stale `beginSession` from a process that lost the race.
    public mutating func begin(_ generation: UInt64) -> Decision {
        guard generation > highWaterMark else { return .rejectStale(current: highWaterMark) }
        highWaterMark = generation
        openGeneration = generation
        return .accept
    }

    /// Admit a mid-session command.
    public mutating func admit(_ generation: UInt64) -> Decision {
        guard let open = openGeneration else { return .rejectNoSession }
        guard generation == open else { return .rejectStale(current: open) }
        return .accept
    }

    /// Admit a read-back (`IMRead`), which is a different question from admitting
    /// a write.
    ///
    /// A read never touches the field, so the interlock that stops a stale
    /// *write* is not the rule that applies. The rule that does: never answer for
    /// a generation this process has not served, because that would be some other
    /// utterance's field. Beyond that, the last generation served stays readable
    /// after `endSession` — the user's correction happens *after* they stop
    /// speaking, so refusing there would mean never observing an edit at all
    /// (Phase 5's whole point), and the IM still remembers that session's
    /// committed run until the next `beginSession` clears it.
    public func admitRead(_ generation: UInt64) -> Decision {
        if let open = openGeneration {
            return generation == open ? .accept : .rejectStale(current: open)
        }
        guard highWaterMark > 0 else { return .rejectNoSession }
        return generation == highWaterMark ? .accept : .rejectStale(current: highWaterMark)
    }

    /// Admit and close.
    public mutating func end(_ generation: UInt64) -> Decision {
        let decision = admit(generation)
        if case .accept = decision { openGeneration = nil }
        return decision
    }

    /// Force-close without a message (client lost, IM deactivated, app quit).
    public mutating func abandon() {
        openGeneration = nil
    }

    /// Route any message through the right door.
    public mutating func evaluate(_ message: IMCommandMessage) -> Decision {
        switch message.command {
        case .beginSession: return begin(message.generation)
        case .endSession: return end(message.generation)
        default: return admit(message.generation)
        }
    }

    /// The detail an out-of-band message maps to, for `editResult`.
    public static func detail(for decision: Decision) -> IMEditDetail {
        switch decision {
        case .accept: return .applied
        case .rejectStale: return .staleGeneration
        case .rejectNoSession: return .noSession
        }
    }
}

/// Monotonic generation source for the app side. One per app launch; seeded from
/// the wall clock so a relaunch can never hand out a generation an IM process
/// that outlived the app has already served.
public final class IMGenerationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64

    public init(seed: UInt64? = nil) {
        // Milliseconds since 2020-01-01, which is monotonic across relaunches in
        // practice and leaves 500+ years of headroom in UInt64.
        let epoch2020: TimeInterval = 1_577_836_800
        let seeded = seed ?? UInt64(max(0, (Date().timeIntervalSince1970 - epoch2020) * 1000))
        self.value = seeded
    }

    public func next() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        value &+= 1
        return value
    }

    public var current: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
