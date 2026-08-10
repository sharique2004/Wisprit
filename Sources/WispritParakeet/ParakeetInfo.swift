import FluidAudio

/// Parakeet TDT v3 via FluidAudio: the vocabulary-channel replacement (spike
/// verdict, docs/research/spikes-parakeet.md — fork (b)). Evidence-only: the
/// CTC candidate scores feed the Phase-3 reconciler gates; the rescorer's
/// rewritten text is never used (measured 23–50 false replacements).
///
/// Deliberately NOT linked into WispritMac yet: the transitive binary
/// xcframework would ride every install for an opt-in feature whose ship
/// decision is human-corpus-gated. Linking is one manifest line when the
/// scoreboard says go.
public enum ParakeetInfo {
    /// The MeetingScribe-validated FluidAudio pin this target builds against.
    public static let fluidAudioRevision = "5390df9752c8fc583596018360c5fd70d6fa6c75"
}
