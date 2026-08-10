/// Accuracy measurement for Wisprit: normalization, WER/CER/term-recall scoring,
/// corpus manifests, and the scoreboard. Pure — no audio, no models, no network.
public enum EvalInfo {
    /// Bumped when scoring semantics change; stamped into scoreboard rows so a
    /// recorded number is attributable to the scorer that produced it.
    public static let scorerVersion = 1
}
