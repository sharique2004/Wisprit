import Foundation

/// Logging and edit-gate constants for `SpeechTranscriber` confidence.
///
/// Two numbers, on purpose, and neither is a calibrated quality decision.
/// `human-v1` has not been recorded. Do not borrow a Whisper cutoff.
public enum TranscriptionConfidence {
    /// Bucket for the metrics summary only. It must not change inserted text.
    /// A run below this is counted in `fractionBelowLoggingBucket` and nowhere else.
    public static let loggingBucket: Double = 0.5

    /// Uncalibrated until `human-v1` exists. Consulted only by
    /// `refine_backend=apple_edits`. The default `apple` backend must not read it.
    public static let uncalibratedEditGate: Double = 0.5

    /// Compact summary of the finalized runs. Nil when the recognizer attached
    /// no confidence attributes — absence is not "everything was confident".
    public static func summary(of runs: [TranscriptionConfidenceRun]) -> TranscriptionConfidenceSummary? {
        guard !runs.isEmpty else { return nil }
        let below = runs.reduce(0) { $0 + ($1.confidence < loggingBucket ? 1 : 0) }
        return TranscriptionConfidenceSummary(
            runCount: runs.count,
            fractionBelowLoggingBucket: Double(below) / Double(runs.count),
            minimumConfidence: runs.map(\.confidence).min() ?? 0)
    }

    /// True only when every UTF-16 unit of `utf16` is covered by a run whose
    /// confidence is at or above `uncalibratedEditGate`. A gap, a missing
    /// attribute, or a single low run is not "entirely high".
    public static func isEntirelyAtOrAboveEditGate(_ utf16: Range<Int>,
                                                   runs: [TranscriptionConfidenceRun]) -> Bool {
        guard !utf16.isEmpty else { return false }
        let relevant = runs
            .map { (range: $0.utf16, confidence: $0.confidence) }
            .filter { $0.range.overlaps(utf16) }
            .sorted { $0.range.lowerBound < $1.range.lowerBound }
        guard !relevant.isEmpty else { return false }
        var cursor = utf16.lowerBound
        for run in relevant {
            let start = max(run.range.lowerBound, utf16.lowerBound)
            if start > cursor { return false }
            if run.confidence < uncalibratedEditGate { return false }
            cursor = max(cursor, min(run.range.upperBound, utf16.upperBound))
            if cursor >= utf16.upperBound { return true }
        }
        return cursor >= utf16.upperBound
    }
}

/// One attributed run, indexed into the plain transcript in UTF-16 so an edit
/// can ask about the span it is about to replace.
public struct TranscriptionConfidenceRun: Sendable, Equatable {
    public var utf16Location: Int
    public var utf16Length: Int
    public var confidence: Double

    public init(utf16Location: Int, utf16Length: Int, confidence: Double) {
        self.utf16Location = utf16Location
        self.utf16Length = utf16Length
        self.confidence = confidence
    }

    public var utf16: Range<Int> { utf16Location..<(utf16Location + utf16Length) }
}

/// What `metrics.log` records. The logging bucket, not a gate.
public struct TranscriptionConfidenceSummary: Sendable, Equatable {
    public var runCount: Int
    public var fractionBelowLoggingBucket: Double
    public var minimumConfidence: Double

    public init(runCount: Int, fractionBelowLoggingBucket: Double, minimumConfidence: Double) {
        self.runCount = runCount
        self.fractionBelowLoggingBucket = fractionBelowLoggingBucket
        self.minimumConfidence = minimumConfidence
    }
}

/// Agreement between the live final and a second reading (Parakeet / the
/// vocabulary channel), built by `VocabularyReconciler` from its own aligner.
///
/// `tokens` are the live string's word spans. A find span is an agreement span
/// when every live token it overlaps was matched. `accepted` is the substitution
/// list `VocabularyReconciler.plan` would already write — the only high-confidence
/// disagreement the edit-script backend may keep.
public struct TranscriptAgreement: Sendable, Equatable {
    public struct Token: Sendable, Equatable {
        public var utf16: Range<Int>
        public var agreed: Bool

        public init(utf16: Range<Int>, agreed: Bool) {
            self.utf16 = utf16
            self.agreed = agreed
        }
    }

    public struct Accepted: Sendable, Equatable {
        public var find: String
        public var replacement: String

        public init(find: String, replacement: String) {
            self.find = find
            self.replacement = replacement
        }
    }

    public var tokens: [Token]
    public var accepted: [Accepted]

    public init(tokens: [Token], accepted: [Accepted]) {
        self.tokens = tokens
        self.accepted = accepted
    }

    /// True when the span overlaps at least one live token and every such token
    /// was agreed with the peer. No overlap is not agreement — a span we cannot
    /// place is not frozen.
    public func isAgreementSpan(_ utf16: Range<Int>) -> Bool {
        let overlapping = tokens.filter { $0.utf16.overlaps(utf16) }
        guard !overlapping.isEmpty else { return false }
        return overlapping.allSatisfy(\.agreed)
    }

    public func wouldAccept(find: String, replacement: String) -> Bool {
        accepted.contains {
            $0.find.compare(find, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
                && $0.replacement == replacement
        }
    }
}
