/// Opt-in, consent-first context awareness: reads text near the cursor
/// locally, extracts candidate proper nouns, and feeds them to the vocabulary
/// biasing channel for the current utterance only. Nothing is stored, nothing
/// is transmitted — the module has no persistence and no networking, and the
/// whole feature is default-off behind an explicit consent flow.
public enum ContextInfo {
    /// Bumped when the extraction rules change; recorded in metrics so a
    /// biasing win is attributable to the extractor that produced it.
    public static let extractorVersion = 1
}
