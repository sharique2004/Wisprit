import Foundation

/// Cross-module seams. Only types that TWO different build agents' targets need
/// belong here; everything else is owned by its module. Frozen for agents —
/// request changes through the orchestrator.

/// Implemented by WispritDictionary; consumed by WispritPostProcess (stage 2 of
/// the deterministic pipeline) and by the correction learn loop.
public protocol CorrectionApplying {
    /// Apply dictionary corrections: whole-word, case-insensitive `hear` →
    /// `term` substitutions (longest-first, \s+-relaxed) plus self-casing of
    /// every term. Deterministic, pure.
    func applyCorrections(to text: String) -> String
}

/// Implemented by WispritDictionary; consumed by WispritEngine to feed
/// DictationTranscriber contextualStrings, and by WispritCorrections to check
/// "is this letter run already a known term?".
public protocol VocabularySource: Sendable {
    /// Canonical terms, most-recently-useful first. Engine passes these to
    /// AnalysisContext.contextualStrings.
    func vocabularyTerms() -> [String]
    func isKnownTerm(_ word: String) -> Bool
}

/// Persisted learn-loop event: WispritCorrections produces these, WispritDictionary
/// persists them ({term, hear:[...]} + provenance fields).
public struct LearnedTerm: Sendable, Equatable {
    public var term: String          // canonical spelling, e.g. "Sharique"
    public var heard: [String]       // ASR's own misrecognitions, e.g. ["Cherie", "Shariq"]
    public var source: String        // "spoken_spelling" | "manual" | ...
    public init(term: String, heard: [String], source: String) {
        self.term = term; self.heard = heard; self.source = source
    }
}

/// Uniform per-utterance stage timing record, mirroring the Python metrics.log
/// JSONL schema. Produced by the session layer, written by WispritPersistence.
public struct UtteranceMetrics: Sendable {
    public var fields: [String: Double]
    public var outcome: String
    public var engine: String
    public init(fields: [String: Double] = [:], outcome: String = "", engine: String = "") {
        self.fields = fields; self.outcome = outcome; self.engine = engine
    }
}
