import Foundation

/// Where the audio came from. Required on every manifest line, and carried all
/// the way into the scoreboard header: a `tts` row can never be quoted as an
/// accuracy claim, and the only way to guarantee that is to make the provenance
/// impossible to omit.
public enum CorpusSource: String, Codable, Sendable, CaseIterable {
    case human
    case tts
    case librispeech
}

/// What the pipeline is expected to do with this utterance beyond transcribing
/// it. Both fields are assertions the scoreboard can fail on, not hints.
public struct CorpusExpectation: Codable, Equatable, Sendable {
    /// Dictionary terms that must survive into the final text — the metric that
    /// moves when ASR biasing lands.
    public var terms: [String]
    /// The `RefineOutcome` raw value this utterance must bypass the model with
    /// ("has_address", "has_letter_run"). Nil means "no expectation".
    public var refineBypass: String?

    public init(terms: [String] = [], refineBypass: String? = nil) {
        self.terms = terms
        self.refineBypass = refineBypass
    }
}

public struct CorpusEntry: Codable, Equatable, Sendable {
    public var id: String
    /// Path to the audio, relative to the manifest.
    public var audio: String
    /// SHA-256 of the audio file — the cache key for `eval asr`, so a re-recorded
    /// take cannot silently reuse an old transcript.
    public var sha256: String
    public var ref: String
    public var category: String
    public var speaker: String
    public var source: CorpusSource
    public var mic: String?
    public var script: String?
    public var durationMs: Int?
    public var expect: CorpusExpectation?
    /// `dev` | `held`. **Assigned by speaker, never by utterance** — thresholds
    /// tune on the dev speaker and are reported on voices the tuning never
    /// heard. Written by `Wisprit eval record`; nil on corpora recorded before
    /// the rule existed (the synthetic one), which report as unsplit rather than
    /// silently joining a side.
    public var split: String?
    /// A human compared this clip's reference against a real transcript and
    /// accepted it (`Wisprit eval verify`). Nil means nobody has looked yet: an
    /// unreviewed reader error becomes a permanent WER floor, so the two states
    /// are worth telling apart.
    public var verified: Bool?

    public init(id: String, audio: String, sha256: String, ref: String, category: String,
                speaker: String, source: CorpusSource, mic: String? = nil,
                script: String? = nil, durationMs: Int? = nil,
                expect: CorpusExpectation? = nil, split: String? = nil,
                verified: Bool? = nil) {
        self.id = id; self.audio = audio; self.sha256 = sha256; self.ref = ref
        self.category = category; self.speaker = speaker; self.source = source
        self.mic = mic; self.script = script; self.durationMs = durationMs; self.expect = expect
        self.split = split; self.verified = verified
    }
}

public enum CorpusError: Error, Equatable, CustomStringConvertible {
    case malformedLine(line: Int, detail: String)
    case missingField(line: Int, field: String)
    case unknownSource(line: Int, value: String)
    case duplicateID(line: Int, id: String)
    case empty

    public var description: String {
        switch self {
        case let .malformedLine(line, detail): return "line \(line): \(detail)"
        case let .missingField(line, field): return "line \(line): missing required field '\(field)'"
        case let .unknownSource(line, value):
            return "line \(line): unknown source '\(value)' "
                + "(expected \(CorpusSource.allCases.map(\.rawValue).joined(separator: "|")))"
        case let .duplicateID(line, id): return "line \(line): duplicate id '\(id)'"
        case .empty: return "manifest has no entries"
        }
    }
}

/// One corpus split: the manifest lines plus the identity the scoreboard stamps
/// on every row it produces from them.
public struct Corpus: Equatable, Sendable {
    public var id: String
    public var split: String
    public var entries: [CorpusEntry]

    public init(id: String, split: String, entries: [CorpusEntry]) {
        self.id = id; self.split = split; self.entries = entries
    }

    /// Every source present. A mixed corpus is legal but must be reported as
    /// mixed — the banner rule keys on this.
    public var sources: Set<CorpusSource> { Set(entries.map(\.source)) }

    /// The single source when there is one, else nil. `Scoreboard` renders the
    /// TTS banner when this is `.tts`.
    public var source: CorpusSource? { sources.count == 1 ? sources.first : nil }

    public var categories: [String] {
        var seen = Set<String>()
        return entries.compactMap { seen.insert($0.category).inserted ? $0.category : nil }
    }

    public func entries(inCategory category: String) -> [CorpusEntry] {
        entries.filter { $0.category == category }
    }

    /// The dev / held partition, by the `split` a manifest line carries.
    /// Entries with no split belong to neither — an unsplit clip must not be
    /// silently reported as held.
    public func entries(inSplit split: String) -> [CorpusEntry] {
        entries.filter { $0.split == split }
    }

    public var speakers: [String] {
        var seen = Set<String>()
        return entries.compactMap { seen.insert($0.speaker).inserted ? $0.speaker : nil }
    }

    // MARK: - parsing

    /// Parse a JSONL manifest. One entry per non-blank line; blank lines and
    /// `#` comment lines are skipped so a generator script can annotate itself.
    ///
    /// `Codable` does the work rather than the order-preserving `WispritJSON`
    /// model in WispritPersistence: WispritEval may depend only on WispritKit,
    /// and a manifest is read-only input — nothing round-trips it, so key order
    /// does not matter here the way it does for the user's config.json.
    public static func parse(jsonl text: String) throws -> [CorpusEntry] {
        let decoder = JSONDecoder()
        var out: [CorpusEntry] = []
        var seen = Set<String>()
        for (offset, rawLine) in text.components(separatedBy: "\n").enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let number = offset + 1
            guard let data = line.data(using: .utf8) else {
                throw CorpusError.malformedLine(line: number, detail: "not UTF-8")
            }
            try requireSource(in: data, line: number)
            let entry: CorpusEntry
            do {
                entry = try decoder.decode(CorpusEntry.self, from: data)
            } catch let error as DecodingError {
                throw corpusError(for: error, line: number)
            } catch {
                throw CorpusError.malformedLine(line: number, detail: "\(error)")
            }
            guard seen.insert(entry.id).inserted else {
                throw CorpusError.duplicateID(line: number, id: entry.id)
            }
            out.append(entry)
        }
        guard !out.isEmpty else { throw CorpusError.empty }
        return out
    }

    public static func load(jsonl text: String, id: String, split: String) throws -> Corpus {
        Corpus(id: id, split: split, entries: try parse(jsonl: text))
    }

    public static func load(contentsOf url: URL, id: String, split: String) throws -> Corpus {
        try load(jsonl: String(contentsOf: url, encoding: .utf8), id: id, split: split)
    }

    /// `source` is checked before `Codable` runs so its failure names the field
    /// and the offending value instead of arriving as a generic "data corrupted".
    /// Provenance is the one field the whole scoreboard's honesty rests on.
    static func requireSource(in data: Data, line: Int) throws {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CorpusError.malformedLine(line: line, detail: "not a JSON object")
        }
        guard let raw = object["source"] else {
            throw CorpusError.missingField(line: line, field: "source")
        }
        guard let text = raw as? String, CorpusSource(rawValue: text) != nil else {
            throw CorpusError.unknownSource(line: line, value: String(describing: raw))
        }
    }

    // MARK: - writing

    /// One JSON object on one line, keys sorted, no trailing newline — the same
    /// shape `StageRecord.jsonLine` writes and the same reason: a manifest
    /// rewritten by `eval verify` must differ from its predecessor only where a
    /// decision changed it, or the diff stops being reviewable.
    ///
    /// `/` is not escaped, so `audio/spk01/spk01.internal.pn-01.wav` reads as a
    /// path in the file rather than as `audio\/spk01\/…`.
    public static func jsonLine(_ entry: CorpusEntry) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(entry), as: UTF8.self)
    }

    public static func jsonl(_ entries: [CorpusEntry]) throws -> String {
        guard !entries.isEmpty else { return "" }
        return try entries.map { try jsonLine($0) }.joined(separator: "\n") + "\n"
    }

    /// Turn `DecodingError`'s prose into a failure that names the field.
    static func corpusError(for error: DecodingError, line: Int) -> CorpusError {
        switch error {
        case let .keyNotFound(key, _):
            return .missingField(line: line, field: key.stringValue)
        case let .valueNotFound(_, context):
            return .missingField(line: line,
                                 field: context.codingPath.last?.stringValue ?? "?")
        case let .typeMismatch(_, context):
            return .malformedLine(line: line,
                                  detail: "wrong type for '"
                                      + (context.codingPath.last?.stringValue ?? "?") + "'")
        case let .dataCorrupted(context):
            return .malformedLine(line: line, detail: context.debugDescription)
        @unknown default:
            return .malformedLine(line: line, detail: "\(error)")
        }
    }
}
