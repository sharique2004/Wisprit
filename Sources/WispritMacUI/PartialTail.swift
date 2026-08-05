import Foundation

/// Pure text logic behind `Pill.livePartial(_:)`.
///
/// `pill.py`'s `update_partial` was a deliberate no-op ("the indicator
/// intentionally does not display the transcript"), so this is new UX rather
/// than a port. The constraints that shaped it:
///
/// - The engine's `onPartial` contract delivers **monotonically growing** text,
///   several times a second, and the research digest measures first-partial
///   latency at ~1.26 s — so the whole transcript would be a wall of stale
///   words. Only the *tail* is informative: it answers "is it still hearing
///   me?", which is the one question the dot alone cannot answer.
/// - The pill must stay a pill. A three-word tail fits a bubble narrower than
///   a menu-bar item and never becomes a text window.
/// - Flicker-free: the caller compares the returned tail against the previous
///   one and skips the redraw when it is unchanged, and bubble width is
///   quantised (see `PillBubbleGeometry`), so mid-word partial churn does not
///   resize the panel.
public enum PartialTail {
    /// Default number of trailing words shown.
    public static let defaultMaxWords = 3
    /// Default character budget — keeps the bubble under `maxWidth`.
    public static let defaultMaxCharacters = 26

    /// Last `maxWords` whitespace-separated words of `text`, trimmed to
    /// `maxCharacters`.
    ///
    /// Trimming drops *leading* words first (we are tracking the tail of
    /// speech, so the newest words are the ones worth keeping). A single word
    /// that still overflows is truncated head-first with a trailing ellipsis —
    /// the head of a long word is what makes it recognisable.
    public static func tail(of text: String,
                            maxWords: Int = defaultMaxWords,
                            maxCharacters: Int = defaultMaxCharacters) -> String {
        let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        guard !words.isEmpty else { return "" }
        var chosen = words.suffix(max(1, maxWords)).map(String.init)
        while chosen.count > 1 && chosen.joined(separator: " ").count > maxCharacters {
            chosen.removeFirst()
        }
        var result = chosen.joined(separator: " ")
        if result.count > maxCharacters {
            let keep = max(1, maxCharacters - 1)
            result = String(result.prefix(keep)) + "…"
        }
        return result
    }

    /// Single-line, length-capped form of a `transientNotice` string. Notices
    /// are app-authored ("Learned Sharique"), so they are clipped rather than
    /// word-selected.
    public static func notice(_ text: String,
                              maxCharacters: Int = defaultMaxCharacters) -> String {
        let flat = text
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
        guard flat.count > maxCharacters else { return flat }
        let keep = max(1, maxCharacters - 1)
        return String(flat.prefix(keep)) + "…"
    }
}
