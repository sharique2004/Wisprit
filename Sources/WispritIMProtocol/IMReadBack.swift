import Foundation

/// Wire v2: the read-back channel — the input method looking at the field and
/// telling the app what it sees, without ever writing to it.
///
/// Two questions, both asked as fire-and-forget posts and answered as unsolicited
/// messages on the app's own port:
///
///   * `readContext`  → "what is around the cursor right now?" — a *bounded*
///     window (`IMContextWindow`) used to bias recognition toward the words
///     already on screen. This is Phase 4's zero-permission context reader: the
///     input method can already read the focused document through
///     TSMDocumentAccess, with no Accessibility grant of any kind.
///   * `readCommitted` → "is the text this session put in the field still
///     exactly what we put there?" — Phase 5's edit observation.
///
/// Three rules the whole channel hangs on:
///
///  1. **Never on the latency path.** Both are posted, never awaited. Key-down
///     must not wait on a round trip, so a read that is slow, refused or lost is
///     simply no signal — the same outcome as not asking.
///  2. **Never more than the window.** `readContext` returns at most
///     `IMContextWindow.before` UTF-16 units before the selection and
///     `IMContextWindow.after` after it, clamped to the document. The cap is
///     fixed by the protocol rather than requested by the caller, so "the whole
///     document can never leave the input method" is a property both sides can
///     check. `readCommitted` returns only the run this session committed —
///     never the surrounding document.
///  3. **Never a guess.** The committed run is located by the same
///     content-match/single-occurrence discipline `RetroEditPlanner` uses for
///     corrections. Two matches, or none, is reported as such; it is never
///     resolved by picking one.
///
// CONTRACT-DEVIATION: the reads are a separate payload kind rather than two more
// `IMCommand` cases. Two reasons, and the second is the load-bearing one:
//
//   * `IMCommand`/`IMEvent` is the *write* channel. Every one of its cases moves
//     the user's text, and every consumer switches on the reply to decide
//     whether to fall back to pasting. A read has no bearing on that decision and
//     must never be able to influence it (a failed read must not downgrade the
//     tier that decides where the user's words go).
//   * Degradation is stronger. An input method too old to know about reads does
//     not recognise the payload's `kind` at all, so the archive fails to decode
//     at the door and the process stays silent — instead of decoding an envelope
//     and then failing on an unknown enum case. Silence is exactly what the app
//     already treats as "no signal", in both directions.

// MARK: - Window

/// How much text a context read may carry, in UTF-16 units.
///
/// Fixed by the protocol, not negotiated. A caller cannot ask for more, so the
/// promise in the consent sheet ("the text around your cursor, not your
/// document") is enforced by the wire rather than by the caller's good manners.
public enum IMContextWindow {
    /// Characters before the selection.
    public static let before = 400
    /// Characters after it.
    public static let after = 200
    /// The widest a snapshot can ever be, selection aside.
    public static var maxSpan: Int { before + after }
}

// MARK: - Reads (app → IM)

/// A read-back request. No parameters on purpose: everything that bounds the
/// answer lives in `IMContextWindow`, where both sides can see it.
public enum IMRead: Codable, Sendable, Equatable {
    /// The bounded window around the insertion point.
    case context
    /// The current text of the run this session committed.
    case committed

    /// Stable name for logs/metrics.
    public var name: String {
        switch self {
        case .context: return "read_context"
        case .committed: return "read_committed"
        }
    }
}

/// Versioned, generation-stamped read envelope. Mirrors `IMCommandMessage`
/// exactly, including the rule that the generation rides on the envelope rather
/// than inside the case.
public struct IMReadMessage: IMWireMessage, Equatable {
    public var wireVersion: Int
    public var generation: UInt64
    public var read: IMRead

    public init(generation: UInt64, read: IMRead,
                wireVersion: Int = WispritIMWire.readChannelVersion) {
        self.wireVersion = wireVersion
        self.generation = generation
        self.read = read
    }

    public static func readContext(generation: UInt64) -> IMReadMessage {
        IMReadMessage(generation: generation, read: .context)
    }

    public static func readCommitted(generation: UInt64) -> IMReadMessage {
        IMReadMessage(generation: generation, read: .committed)
    }
}

// MARK: - Detail

/// Why a read produced what it did.
///
/// Deliberately NOT `IMEditDetail`: those raw strings drive the per-bundle
/// tier-verdict downgrade cache, and a read that could not be answered must
/// never lower the tier that decides where the user's words go. The strings are
/// stable for the same reason `IMEditDetail`'s are — they land in `metrics.log`.
public enum IMReadDetail: String, Codable, Sendable, Equatable, CaseIterable {
    /// A context window was read. Empty strings with this detail mean an empty
    /// field, not a failure.
    case read
    /// `readCommitted`: our run is still in the document, exactly once,
    /// character-for-character. The zero-edit observation.
    case unchanged
    /// `readCommitted`: the text this session committed is no longer in the
    /// field. Something edited it — that much is a fact. *Which* edit is not, so
    /// `current` stays empty rather than carrying a guess.
    case changed
    /// `readCommitted`: our run appears more than once, or nothing was committed
    /// to look for. Evidence of nothing; must not count toward a zero-edit rate.
    case unknown
    /// No IMKTextInput client — nothing is focused, or the input method is not
    /// the active source. Also what Secure Event Input looks like from here.
    case noClient
    /// The client does not support TSMDocumentAccess, so `stringFromRange:`
    /// returns nothing. Reads are impossible in this field, permanently.
    case noDocumentAccess
    /// The client supports reads and still gave us nothing back.
    case readFailed
    /// The read named a generation this input method is not serving and never
    /// served last. Answered with the detail and no text at all.
    case staleGeneration
    /// No session has ever been open in this process.
    case noSession

    /// True when the payload carries text the caller may use. Everything else is
    /// a reason, not a result.
    public var isUsable: Bool {
        switch self {
        case .read, .unchanged: return true
        default: return false
        }
    }
}

// MARK: - Snapshots (IM → app)

/// The bounded window around the insertion point.
///
/// `before + selected + after` is what the user can see near their cursor, and
/// nothing else: no other window, no other field, no scroll-back beyond the cap.
public struct IMContextSnapshot: Codable, Sendable, Equatable {
    /// Up to `IMContextWindow.before` UTF-16 units immediately before the
    /// selection, clipped to the start of the document.
    public var before: String
    /// The selected text, if any. Empty for a plain caret.
    public var selected: String
    /// Up to `IMContextWindow.after` UTF-16 units immediately after it.
    public var after: String
    public var detail: IMReadDetail

    public init(before: String = "", selected: String = "", after: String = "",
                detail: IMReadDetail) {
        self.before = before
        self.selected = selected
        self.after = after
        self.detail = detail
    }

    public static func read(before: String, selected: String, after: String) -> IMContextSnapshot {
        IMContextSnapshot(before: before, selected: selected, after: after, detail: .read)
    }

    /// A reason with no text. Every failure path answers — silence is reserved
    /// for "this input method is too old to know what you asked", so an explicit
    /// refusal is what distinguishes an unreadable field from a stale install.
    public static func unavailable(_ detail: IMReadDetail) -> IMContextSnapshot {
        IMContextSnapshot(detail: detail)
    }

    /// Everything the app is allowed to see, in document order. Convenience for
    /// candidate extraction, which does not care where the caret sits.
    public var text: String { before + selected + after }
}

/// The state of the run this session committed.
public struct IMCommittedSnapshot: Codable, Sendable, Equatable {
    /// What the field says that run reads now — populated only for `.unchanged`,
    /// where it is read back out of the document rather than recalled, so the app
    /// is comparing against what is really there.
    public var current: String
    public var detail: IMReadDetail

    public init(current: String = "", detail: IMReadDetail) {
        self.current = current
        self.detail = detail
    }

    public static func unchanged(_ current: String) -> IMCommittedSnapshot {
        IMCommittedSnapshot(current: current, detail: .unchanged)
    }

    /// Our run is no longer in the field. Carries no text on purpose: the edit
    /// happened, and that is the entire honest content of the observation.
    public static let changed = IMCommittedSnapshot(detail: .changed)

    public static func unavailable(_ detail: IMReadDetail) -> IMCommittedSnapshot {
        IMCommittedSnapshot(detail: detail)
    }
}

public enum IMSnapshot: Codable, Sendable, Equatable {
    case contextSnapshot(IMContextSnapshot)
    case committedSnapshot(IMCommittedSnapshot)

    public var name: String {
        switch self {
        case .contextSnapshot: return "context_snapshot"
        case .committedSnapshot: return "committed_snapshot"
        }
    }

    public var detail: IMReadDetail {
        switch self {
        case .contextSnapshot(let snapshot): return snapshot.detail
        case .committedSnapshot(let snapshot): return snapshot.detail
        }
    }
}

/// Versioned, generation-stamped snapshot envelope.
///
/// The generation is the one the read named, so a reply that arrives after the
/// user has started the next utterance is discardable by comparison — the same
/// rule, and the same placement, as every other message on this wire.
public struct IMSnapshotMessage: IMWireMessage, Equatable {
    public var wireVersion: Int
    public var generation: UInt64
    public var snapshot: IMSnapshot

    public init(generation: UInt64, snapshot: IMSnapshot,
                wireVersion: Int = WispritIMWire.readChannelVersion) {
        self.wireVersion = wireVersion
        self.generation = generation
        self.snapshot = snapshot
    }

    public static func contextSnapshot(generation: UInt64,
                                       _ snapshot: IMContextSnapshot) -> IMSnapshotMessage {
        IMSnapshotMessage(generation: generation, snapshot: .contextSnapshot(snapshot))
    }

    public static func contextSnapshot(generation: UInt64,
                                       before: String,
                                       selected: String,
                                       after: String) -> IMSnapshotMessage {
        .contextSnapshot(generation: generation,
                         IMContextSnapshot.read(before: before, selected: selected, after: after))
    }

    public static func committedSnapshot(generation: UInt64,
                                         _ snapshot: IMCommittedSnapshot) -> IMSnapshotMessage {
        IMSnapshotMessage(generation: generation, snapshot: .committedSnapshot(snapshot))
    }

    public static func committedSnapshot(generation: UInt64,
                                         current: String,
                                         detail: IMReadDetail) -> IMSnapshotMessage {
        .committedSnapshot(generation: generation,
                           IMCommittedSnapshot(current: current, detail: detail))
    }
}
