import Foundation
import WispritRefine

/// Prompt shaping shared by the real generator and the rehearsal battery, kept
/// out of the FoundationModels-only file so it stays unit-testable.
public enum PolishPrompt {

    /// The user turn. Byte-identical in shape to `RefinePrompt.userTurn` and to
    /// `polish.py`'s `f"<transcript>\n{text}\n</transcript>"`: the transcript
    /// lives in the (untrusted) prompt turn, wrapped in the tags the
    /// instructions declare to be data, so a dictated imperative gets rewritten
    /// instead of obeyed.
    public static func userTurn(for transcript: String) -> String {
        "<transcript>\n\(transcript)\n</transcript>"
    }

    /// How much longer than the input a mode's output may legitimately run.
    /// `maximumResponseTokens` truncates WITHOUT throwing, so undershooting
    /// silently amputates the user's text; these are ceilings, not targets.
    static func tokenHeadroom(for mode: PolishMode) -> Double {
        switch mode {
        case .cleanUp: return 1.0       // cleanup only ever shrinks
        case .makeFormal: return 1.5    // formal wording is wordier than speech
        case .makeCasual: return 1.2
        case .asAIPrompt: return 1.6    // may split constraints onto lines
        }
    }

    /// Response budget for one request. Built on `RefinePrompt`'s measured
    /// estimator (English ≈3.5 chars/token, CJK ≈1 token/char) and widened per
    /// mode, then clamped so a misfire can never blow the shared 4096-token
    /// context.
    public static func maximumResponseTokens(for transcript: String, mode: PolishMode) -> Int {
        let base = RefinePrompt.maximumResponseTokens(for: transcript)
        let scaled = Int(Double(base) * tokenHeadroom(for: mode))
        return max(96, min(2800, scaled))
    }
}
