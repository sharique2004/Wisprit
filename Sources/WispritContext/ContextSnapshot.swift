import Foundation

/// One read of the text around the user's cursor, captured at key-down and used
/// for exactly one utterance. The platform reader (AX or the IM wire) fills it
/// in; this module only ever consumes it and then lets it go — nothing in
/// `WispritContext` persists, logs, or transmits field text.
///
/// The `description` is REDACTED by design: snapshots flow through session
/// logging and metrics plumbing, and an interpolated snapshot must never put
/// the user's document into a log line. Only shape (character counts), app
/// identity, and bookkeeping fields are printable; a test pins this.
public struct ContextSnapshot: Equatable, Sendable {
    /// Bundle identifier of the frontmost app the text was read from — the key
    /// `ContextPolicy` gates on (password managers, secure contexts).
    public var bundleID: String
    /// Text before the insertion point. When the policy clamps it, the END is
    /// kept — the characters nearest the cursor are the valuable ones.
    public var before: String
    /// The current selection, empty for a bare caret. Distance zero for
    /// ranking: selected text IS the cursor position.
    public var selected: String
    /// Text after the insertion point; clamping keeps the START.
    public var after: String
    /// When the capture STARTED. `ContextPolicy.isStale` measures the time
    /// budget from here, so a reader that answered late is caught even though
    /// the snapshot itself looks fresh.
    public var capturedAt: Date
    /// Monotonic capture counter from the session layer. A snapshot taken for
    /// utterance N must not bias utterance N+1; comparing generations is how
    /// the integration layer drops leftovers.
    public var generation: Int

    public init(bundleID: String, before: String, selected: String = "",
                after: String = "", capturedAt: Date, generation: Int) {
        self.bundleID = bundleID
        self.before = before
        self.selected = selected
        self.after = after
        self.capturedAt = capturedAt
        self.generation = generation
    }
}

extension ContextSnapshot: CustomStringConvertible, CustomDebugStringConvertible {
    /// Shape only — never field text. `String(describing:)` and
    /// `String(reflecting:)` both land here.
    public var description: String {
        "ContextSnapshot(\(bundleID), before: \(before.count) chars, "
            + "selected: \(selected.count) chars, after: \(after.count) chars, "
            + "generation: \(generation))"
    }

    public var debugDescription: String { description }
}
