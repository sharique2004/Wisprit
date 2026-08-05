import Foundation

/// Whisper models hallucinate stock caption phrases on silence / near-silence
/// (learned from YouTube captions). Ported verbatim from `_HALLUCINATIONS` /
/// `_drop_if_hallucinated` in `wisprit/asr_batch.py` (commit 8f2d8de).
///
/// Matched only against the ENTIRE trimmed, lowercased output, so a real
/// sentence containing "thank you" is untouched. A silent push-to-talk must
/// insert nothing, never a phantom "Thank you."
///
/// This is a BATCH-path filter only. The streaming engine returns nothing on
/// silence, which is correct and must not be second-guessed.
public enum SilenceHallucinationFilter {
    public static let phrases: Set<String> = [
        "thank you", "thank you.", "thanks for watching", "thanks for watching.",
        "thanks for watching!", "thank you for watching", "thank you for watching.",
        "thank you very much", "thank you very much.", "you", "you.", ".", "bye",
        "bye.", "bye!", "please subscribe", "so", "so.", "okay", "okay.",
        "i'm sorry", "i'm sorry.", "subtitles by the amara.org community",
        "thanks", "thanks.", "thank you.thank you.", "уou",
    ]

    /// Returns "" when the whole output is a known hallucination, else the input
    /// UNCHANGED (not trimmed — Python returns `text`, so "   " stays "   ").
    public static func drop(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return phrases.contains(key) ? "" : text
    }
}
