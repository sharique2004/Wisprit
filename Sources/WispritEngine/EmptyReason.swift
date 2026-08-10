import Foundation

/// Why an utterance produced no text.
///
/// `outcome=empty` is the second most common row in `metrics.log` (62 of 342 in
/// the pre-telemetry era) and every one of those rows was indistinguishable from
/// every other: a user who pressed the key and said nothing, a dead microphone,
/// and a wedged analyzer all logged the same nine fields. That is what made the
/// 2026-08-05 incident unreadable. This is the classifier that splits them, and
/// it is deliberately pure — the same function labels a live utterance for the
/// pill and labels a replayed `UtteranceResult` offline.
public enum EmptyReason: String, Sendable, CaseIterable {
    /// finalize did not complete inside `finalize_timeout_ms`. The engine may
    /// still have had text; whatever arrived late is lost.
    case timedOut = "timed_out"
    /// The results stream errored or finalize threw — a real engine failure, the
    /// only reason that may trigger the batch fallback.
    case crashed
    /// Less than one 100 ms chunk of audio ever reached the analyzer. The
    /// capture side, not the engine, produced the emptiness.
    case starved
    /// Audio arrived but never rose above the voiced threshold across a hold
    /// long enough to speak in: the user did not speak. Benign.
    case silent
    /// Same silence, but the key was held for less than `shortHoldMs` — a
    /// fumbled or accidental tap rather than an attempt at dictation. Split out
    /// because the two want different pill copy and only one is worth counting
    /// against the engine.
    case shortHold = "short_hold"
    /// Audible speech in, clean finish, nothing out. The real defect: everything
    /// worked and the analyzer still returned no result.
    case producedNothing = "produced_nothing"

    /// Label one finished utterance, or `nil` if it produced text (there is
    /// nothing to explain).
    ///
    /// Ordered by how much each condition explains: a crash or a timeout is a
    /// complete explanation on its own, starvation means the engine was never
    /// given a chance, and only once all three are ruled out does the audio
    /// level get to speak. `producedNothing` is the residue — no other reason
    /// applies — which is exactly what makes its rate the alarm worth watching.
    public static func classify(result: UtteranceResult, heldMs: Double,
                                shortHoldMs: Double = 1000) -> EmptyReason? {
        guard result.text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        if result.crashed { return .crashed }
        if result.timedOut { return .timedOut }
        if result.starvedInput { return .starved }
        if result.peakLevel < SpeechAnalyzerEngine.voicedPeakThreshold {
            return heldMs < shortHoldMs ? .shortHold : .silent
        }
        return .producedNothing
    }
}
