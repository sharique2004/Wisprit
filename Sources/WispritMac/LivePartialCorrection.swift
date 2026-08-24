import Foundation
import WispritKit
import WispritPostProcess

/// Self-correction *and* dictionary hear-phrases on the live partial stream —
/// the *display* half of the rules `PostProcess` applies at finalize.
///
/// "I want to have a meeting with person x on thuersday umm no actually friday"
/// has to read "… on friday" while the user is still talking, not half a second
/// after they let go of the key. Same for "whisper flow" → "Wispr Flow": a
/// preview that still shows the mishear until release is the error the user
/// sees *while speaking*. `SelfCorrection.apply` and `CorrectionApplying` are
/// the same engines the finalize path uses — they were lifted so they could
/// be — and what this file adds is the two rules that make them safe to run
/// on a partial:
///
///  * **Display only.** The corrected string goes to the pill bubble and the
///    input method's marked text and nowhere else. The session keeps no partial
///    state, so finalize still sees the RAW ASR final and re-runs the whole
///    pipeline over it — which is what keeps the spoken-spelling corrector, the
///    refine prompt, `history` and `metrics.raw_chars` reading exactly what the
///    engine heard. A partial is a preview; the final is the record, and a
///    preview that edited the record would be inventing evidence.
///  * **Budgeted.** Both engines are a handful of regex scans (<1 ms on an
///    utterance-sized string), but a partial is untrusted length: a runaway
///    dictation is one long string re-scanned from scratch several times a
///    second, on the session thread. Past `maxCharacters` the tail is shown
///    verbatim rather than risk a hitch — nothing is lost, because finalize
///    corrects it a moment later.
///
/// There is no setting. Stage 2 (dictionary) and stage 5 (self-correction) are
/// unconditional in the finalize pipeline, so the live path is unconditional
/// for the same reason: a preview that could disagree with the text it is
/// previewing is worse than no preview at all. Order matches finalize:
/// dictionary first, then self-correction, so a hear-phrase that is also a
/// correction target is already canonical when the joint fires.
enum LivePartialCorrection {
    /// Longest partial worth correcting, in characters. The same order of
    /// magnitude as `SessionController.refineDelta`'s cap and for the same
    /// reason — past it the string has stopped being an utterance, and the
    /// budget that matters is the one that keeps the field responsive.
    static let maxCharacters = 2_000

    /// What the user should see for this partial.
    ///
    /// Idempotent, because the caller is: partials arrive cumulatively-windowed
    /// and every one of them is corrected from scratch, so the displayed text
    /// only ever depends on the partial in hand.
    static func display(_ raw: String,
                        corrections: (any CorrectionApplying)? = nil) -> String {
        guard raw.count <= maxCharacters else { return raw }
        // Dictionary first, matching PostProcess stage 2 → 5. A mid-correction
        // tail still shows the hear-phrase rewrite — "Wispr Flow no actually"
        // is a better frame than "whisper flow no actually" — but does not
        // run the joint, because that would delete the word being replaced
        // with nothing to show in its place.
        let withVocab = corrections?.applyCorrections(to: raw) ?? raw
        guard !SelfCorrection.endsMidCorrection(raw) else { return withVocab }
        return SelfCorrection.apply(withVocab)
    }
}
