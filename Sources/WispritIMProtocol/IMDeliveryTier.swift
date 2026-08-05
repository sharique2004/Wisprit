import Foundation

/// Where a given text field lands in the insertion ladder.
///
/// Ladder (research recommendation, macOS Developer ID SKU):
///   1. `markedStreaming` — live underlined tail + committed chunks, this module.
///   2. `commitOnly`      — client exists, marked text misbehaves (Java/Qt/games):
///                          no live tail, one `insertText:` per stable chunk.
///   3. paste-at-end      — no IM client at all; `WispritMacInput.Inserter`.
///   4. typed unicode     — clipboard-hostile contexts.
///   5. blocked_secure    — Secure Event Input, which defeats the IM tier too.
///
/// Tiers 3–5 are the existing `Inserter` cascade and are not this module's
/// business; `unsupported` is how the IM says "drop to tier 3".
public enum IMDeliveryTier: String, Codable, Sendable, Equatable, CaseIterable {
    case markedStreaming = "marked_streaming"
    case commitOnly = "commit_only"
    case unsupported

    /// Pure tier decision, so the app and the IM can never disagree about it.
    ///
    /// - `capabilities == nil` → no client → `unsupported`.
    /// - `supportsUnicode == false` → IPAPalette's hard error → `unsupported`.
    /// - marked text already failed this session → `commitOnly`.
    public static func decide(capabilities: IMClientCapabilities?,
                              markedTextHealthy: Bool = true) -> IMDeliveryTier {
        guard let capabilities else { return .unsupported }
        guard capabilities.supportsUnicode else { return .unsupported }
        return markedTextHealthy ? .markedStreaming : .commitOnly
    }

    /// Retroactive correction of *committed* text needs the client to honour an
    /// absolute `replacementRange`, which is gated on TSMDocumentAccess. Without
    /// it the range is silently discarded and the correction would be appended
    /// to the end of the field — worse than not correcting at all.
    ///
    /// (Apple's `-replacementRange` override in `IMKInputController.h` positions
    /// *marked* text, so it blesses correct-before-commit, not this. The
    /// post-commit rewrite rides on `insertText:replacementRange:`.)
    public static func supportsRetroEdit(_ capabilities: IMClientCapabilities?) -> Bool {
        guard let capabilities, capabilities.supportsUnicode else { return false }
        return capabilities.supportsDocumentAccess
    }

    public var streamsLiveTail: Bool { self == .markedStreaming }
    public var acceptsCommits: Bool { self != .unsupported }
}
