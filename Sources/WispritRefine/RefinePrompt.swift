import Foundation

/// Prompt shaping shared by the real generator and the rehearsal battery, kept
/// out of the FoundationModels-only file so it stays unit-testable.
public enum RefinePrompt {

    /// The user turn, byte-identical to the helper's
    /// `"<transcript>\n\(transcript)\n</transcript>"`. The transcript arrives in
    /// the (untrusted) prompt turn, which the model is trained to treat as data
    /// relative to the instructions.
    public static func userTurn(for transcript: String) -> String {
        "<transcript>\n\(transcript)\n</transcript>"
    }

    /// Bound the response so a misfire can never run away (and never blow the
    /// 4096-token shared context). Cleanup output is at most ~input-sized;
    /// English tokenizes at ~3.5 chars/token, but CJK scripts run ~1 token per
    /// character — `maximumResponseTokens` truncates WITHOUT throwing, so
    /// undershooting the budget would silently drop the tail of a dictation.
    public static func maximumResponseTokens(for transcript: String) -> Int {
        let hasDenseScript = transcript.unicodeScalars.contains {
            (0x2E80...0x9FFF).contains($0.value)         // CJK radicals, kana, han
                || (0xAC00...0xD7AF).contains($0.value)  // hangul
        }
        let estimated = hasDenseScript
            ? Int(Double(transcript.count) * 1.6) + 96
            : Int(Double(transcript.count) / 3.5 * 1.8) + 64
        return max(96, min(2800, estimated))
    }
}
