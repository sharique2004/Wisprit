import Foundation
import Speech
import WispritKit

/// Reads `transcriptionConfidence` off a finalized attributed string.
///
/// The plain transcript is always `String(text.characters)`. Attributes never
/// add, drop, or rewrite characters. Volatile partials are not read here: the
/// SDK's `attributeOptions` is module-wide (there is no finals-only switch),
/// and walking attributes on the partial burst would be work the live-typing
/// path does not need. The engine asks for the attribute and inspects it only
/// on `isFinal` results.
enum SpeechConfidenceReader {
    static func plainText(_ text: AttributedString) -> String {
        String(text.characters)
    }

    /// Runs relative to `plainText`, in UTF-16. A run without the attribute is
    /// skipped, which leaves a coverage gap rather than a fabricated score.
    static func runs(in text: AttributedString) -> [TranscriptionConfidenceRun] {
        var runs: [TranscriptionConfidenceRun] = []
        var cursor = 0
        for run in text.runs {
            let slice = String(text[run.range].characters)
            let length = slice.utf16.count
            if length > 0, let confidence = run.transcriptionConfidence {
                runs.append(TranscriptionConfidenceRun(
                    utf16Location: cursor, utf16Length: length, confidence: confidence))
            }
            cursor += length
        }
        return runs
    }
}

/// One finalized segment plus the confidence runs indexed into that segment's
/// raw text, before the trim-and-join the sink already does.
struct FinalPiece: Sendable, Equatable {
    var text: String
    var runs: [TranscriptionConfidenceRun]
}

/// The same trim-and-join `SpeechAnalyzerEngine.finalize` has always used for
/// the inserted string, plus the runs shifted onto that joined string.
///
/// A salvaged volatile tail is NOT part of this join. Callers that append one
/// keep these runs indexed at the finalized prefix; uncovered tail is not
/// "entirely high confidence".
enum FinalConfidence {
    static func joinedText(_ finals: [String]) -> String {
        finals.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func joined(_ pieces: [FinalPiece]) -> (text: String, runs: [TranscriptionConfidenceRun]) {
        var text = ""
        var runs: [TranscriptionConfidenceRun] = []
        for piece in pieces {
            guard let trimmed = trimmed(piece.text) else { continue }
            if !text.isEmpty { text += " " }
            let base = text.utf16.count
            text += trimmed.slice
            let sliceLength = trimmed.slice.utf16.count
            for run in piece.runs {
                let start = run.utf16Location - trimmed.lead
                let end = start + run.utf16Length
                let clippedStart = max(0, start)
                let clippedEnd = min(sliceLength, end)
                guard clippedStart < clippedEnd else { continue }
                runs.append(TranscriptionConfidenceRun(
                    utf16Location: base + clippedStart,
                    utf16Length: clippedEnd - clippedStart,
                    confidence: run.confidence))
            }
        }
        return (text, runs)
    }

    private struct Trimmed {
        var lead: Int
        var slice: String
    }

    private static func trimmed(_ text: String) -> Trimmed? {
        guard let start = text.firstIndex(where: { !$0.isWhitespace }) else { return nil }
        let lead = text.utf16.distance(from: text.utf16.startIndex,
                                       to: start.samePosition(in: text.utf16) ?? text.utf16.startIndex)
        let slice = text.trimmingCharacters(in: .whitespaces)
        guard !slice.isEmpty else { return nil }
        return Trimmed(lead: lead, slice: slice)
    }
}
