import Foundation

/// What one utterance looked like at every stage of the pipeline, written by
/// `eval asr` / `eval stages` as JSONL.
///
/// This is the artifact that makes a scoreboard row debuggable: the aggregate
/// says WER moved, the stage records say *which* utterance and *which* stage
/// moved it. Stage names follow `SessionController.finalizeUtterance` order —
/// raw (engine final) → corrected (spoken-spelling) → refined (the AI cage) →
/// final (post-process + insertion text).
///
/// Everything after `final` is optional so a partial run (ASR only, no refine)
/// still produces valid lines, and so a field added later does not invalidate
/// records already on disk.
public struct StageRecord: Codable, Equatable, Sendable {
    /// The corpus entry this replays.
    public var id: String
    public var engine: String
    public var raw: String
    public var corrected: String
    public var refined: String
    public var final: String
    /// The off-path DictationTranscriber reading, when the vocabulary channel ran.
    public var vocab: String?
    /// `RefineOutcome` raw value — the same vocabulary `metrics.log`'s `ai` uses.
    public var ai: String?
    public var aiMs: Double?
    public var finalizeMs: Double?
    public var timedOut: Bool?
    public var starvedInput: Bool?
    public var vocabHits: Int?
    public var vocabMs: Double?

    public init(id: String, engine: String, raw: String, corrected: String, refined: String,
                final: String, vocab: String? = nil, ai: String? = nil, aiMs: Double? = nil,
                finalizeMs: Double? = nil, timedOut: Bool? = nil, starvedInput: Bool? = nil,
                vocabHits: Int? = nil, vocabMs: Double? = nil) {
        self.id = id; self.engine = engine; self.raw = raw; self.corrected = corrected
        self.refined = refined; self.final = final; self.vocab = vocab; self.ai = ai
        self.aiMs = aiMs; self.finalizeMs = finalizeMs; self.timedOut = timedOut
        self.starvedInput = starvedInput; self.vocabHits = vocabHits; self.vocabMs = vocabMs
    }
}

public enum StageRecordError: Error, Equatable, CustomStringConvertible {
    case malformedLine(line: Int, detail: String)

    public var description: String {
        switch self {
        case let .malformedLine(line, detail): return "line \(line): \(detail)"
        }
    }
}

extension StageRecord {

    /// One JSON object on one line, no trailing newline. Keys are sorted so a
    /// re-run over identical inputs produces a byte-identical file and `git
    /// diff` shows only real changes.
    public func jsonLine() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        return String(decoding: data, as: UTF8.self)
    }

    public static func jsonl(_ records: [StageRecord]) throws -> String {
        try records.map { try $0.jsonLine() }.joined(separator: "\n") + "\n"
    }

    /// Blank lines are skipped; anything else that fails to decode is reported
    /// with its line number rather than dropped.
    public static func decode(jsonl text: String) throws -> [StageRecord] {
        let decoder = JSONDecoder()
        var out: [StageRecord] = []
        for (offset, rawLine) in text.components(separatedBy: "\n").enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            guard let data = line.data(using: .utf8) else {
                throw StageRecordError.malformedLine(line: offset + 1, detail: "not UTF-8")
            }
            do {
                out.append(try decoder.decode(StageRecord.self, from: data))
            } catch {
                throw StageRecordError.malformedLine(line: offset + 1, detail: "\(error)")
            }
        }
        return out
    }
}
