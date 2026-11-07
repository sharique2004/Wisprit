import Foundation

/// Every machine word Insights can be handed, in the user's language.
///
/// `metrics.log` speaks the engine's vocabulary — `im_streaming`, `starved`,
/// `skipped_verbatim_app` — and the page used to print it verbatim, which read
/// as "something is wrong" even when nothing was. Every value a writer in this
/// repo can put in `outcome`, `empty_reason`, `ai` or `capture_backend` has an
/// entry below (the tests walk the writers' own enums to keep it that way), and
/// anything else — a value from a build that does not exist yet — goes through
/// `fallback`, which never leaves an underscore on screen.
///
/// Plain words only. Short, sentence case, no jargon.
public enum InsightsLabels {

    // MARK: - outcome (what happened to the hold)

    /// `metrics.log`'s `outcome`. The insertion rungs are `InsertionTier`'s raw
    /// values (`im_streaming`, `im_commit`, `paste`, `type`, `blocked_secure`)
    /// plus `InsertResult.Method.error`; `empty` and `correction` are written by
    /// the session directly; `vocab_retro` / `edit_observed` / `onboarding` are
    /// not holds and are filtered before anything is counted, but they get a
    /// name anyway so no path can leak them; `unrecorded` is the mapper's name
    /// for a row whose outcome never reached disk.
    public static let outcomeLabels: [String: String] = [
        "im_streaming": "Typed live",
        "im_commit": "Typed in one go",
        "paste": "Pasted",
        "type": "Typed",
        "blocked_secure": "Blocked by a password field",
        "error": "Couldn't insert",
        "empty": "Nothing inserted",
        "correction": "Spelling correction",
        "vocab_retro": "Dictionary pass",
        "edit_observed": "Edit check",
        "onboarding": "First run",
        "unrecorded": "Not recorded",
    ]

    /// `EmptyReason`'s raw values — why a hold put nothing in the field.
    public static let emptyReasonLabels: [String: String] = [
        "silent": "Nothing heard",
        "starved": "Mic sent no audio",
        "short_hold": "Key released too soon",
        "produced_nothing": "Heard sound, no words",
        "timed_out": "Recognition took too long",
        "crashed": "Speech engine stopped",
        "device_changed": "Mic changed mid-sentence",
    ]

    /// `RefineOutcome`'s raw values — what AI cleanup did with the text.
    public static let cleanupLabels: [String: String] = [
        "applied": "Cleaned up",
        "off": "Cleanup turned off",
        "empty": "Nothing to clean up",
        "too_long": "Too long to clean up",
        "has_address": "Skipped: web or email address",
        "timeout": "Cleanup took too long",
        "cancelled": "Cancelled",
        "preempted": "Skipped for the next dictation",
        "spawn_failed": "Cleanup couldn't start",
        "bad_reply": "Cleanup reply unusable",
        "helper_error": "Cleanup failed",
        "implausible": "Kept as spoken: reply looked wrong",
        "error": "Cleanup failed",
        "has_letter_run": "Skipped: spelled-out letters",
        "obeyed": "Kept as spoken: reply answered instead",
        "skipped_verbatim_app": "Cleanup skipped for this app",
        "dropped_content": "Kept as spoken: reply dropped words",
        "paraphrased": "Kept as spoken: reply reworded",
        "dropped_correction": "Kept as spoken: reply lost a correction",
    ]

    /// `MicCapture.Backend`'s raw values — how the microphone was opened.
    public static let captureBackendLabels: [String: String] = [
        "hal": "Direct mic capture",
        "engine": "System audio engine",
    ]

    public static func outcome(_ key: String) -> String { label(key, in: outcomeLabels) }
    public static func emptyReason(_ key: String) -> String { label(key, in: emptyReasonLabels) }
    public static func cleanup(_ key: String) -> String { label(key, in: cleanupLabels) }
    public static func captureBackend(_ key: String) -> String { label(key, in: captureBackendLabels) }

    private static func label(_ key: String, in table: [String: String]) -> String {
        table[key] ?? fallback(key)
    }

    /// A value no table knows: `some_new_value` → "Some new value". Never
    /// empty, never an underscore, never the raw token.
    public static func fallback(_ key: String) -> String {
        let words = key
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard let first = words.first else { return "Other" }
        return first.uppercased() + words.dropFirst().lowercased()
    }
}
