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
    /// The audio hardware was reconfigured mid-hold (the default input changed,
    /// or its format did). The engine stopped itself at the switch, so an empty
    /// result says nothing about the user or the analyzer — the microphone died
    /// under them. Ranked above `silent` because a dead capture explains an
    /// empty better than a quiet meter does: the peak this hold measured is the
    /// peak of the fragment before the switch.
    case deviceChanged = "device_changed"
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
        // After starvation (which names the capture side precisely) and before
        // the level clause (whose evidence the switch invalidated).
        if result.sawConfigurationChange { return .deviceChanged }
        if result.peakLevel < SpeechAnalyzerEngine.voicedPeakThreshold {
            return heldMs < shortHoldMs ? .shortHold : .silent
        }
        return .producedNothing
    }
}

/// Was the audio too WEAK to read, as opposed to absent?
///
/// The measured failure class behind the mangled quiet dictations (2026-08-15).
/// The engine is level-invariant — attenuating LibriSpeech to a peak of 0.06,
/// the band the user's telemetry shows, costs 0.17 pt of WER — but the same
/// speech over a real noise floor is a different signal entirely: peak 0.06 over
/// floor 0.012 (≈14 dB SNR) scored 5.58 % against a 1.72 % control, 3.2× worse,
/// and re-amplifying it afterwards recovers 0.26 pt of that 3.9 pt loss because
/// gain lifts the floor identically. The information is gone at the microphone,
/// which makes telling the user the only remedy there is.
///
/// Deliberately NOT an `EmptyReason` case: the reason vocabulary names what the
/// pipeline did, and this names what the room sounded like. One is the log's
/// classification, the other is a fact about the same row — a row can be
/// `produced_nothing` AND marginal, and collapsing them would cost the empty-rate
/// series its continuity.
public enum MarginalAudio {
    /// Above this the utterance is loud enough that faintness is not the story —
    /// production rows at peak 0.076–0.15 come back with text.
    public static let peakCeiling: Float = 0.12
    /// peak / noise_floor, both on the meter's RMS×4 scale, so the ratio is a
    /// crude SNR: 5 ≈ 14 dB, the rung where WER tripled. Below it, speech and
    /// room are within a factor of five of each other.
    public static let minimumSignalRatio: Double = 5

    /// True when the audio carried speech the room nearly swallowed.
    ///
    /// A nil floor is NOT marginal: `MicCapture` needs three 100 ms chunks
    /// before it can name a quietest window, so a sub-300 ms tap has no floor
    /// at all — and guessing one from a fumbled press is how a real user with a
    /// quiet-but-working setup starts getting nagged. Same for a floor of zero
    /// (digital silence under the speech): nothing swallowed anything.
    public static func isMarginal(peakLevel: Float, noiseFloor: Double?) -> Bool {
        guard peakLevel >= SpeechAnalyzerEngine.voicedPeakThreshold,
              peakLevel < peakCeiling,
              let floor = noiseFloor, floor > 0 else { return false }
        return Double(peakLevel) / floor < minimumSignalRatio
    }
}
