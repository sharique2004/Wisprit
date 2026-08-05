import Foundation
import WispritKit
import os

/// Custom vocabulary: `~/.wisprit/dictionary.json`. Port of `wisprit/dictionary.py`.
///
/// Two roles, both fed by the same file:
///
/// 1. `vocabularyTerms()` / `terms()` — the canonical vocabulary. On the Python
///    side this went to `apple_live --context` (a no-op, because
///    `SpeechTranscriber` ignores `contextualStrings`); natively it feeds the
///    `DictationTranscriber` vocabulary channel, which the research A/B proved
///    *does* honour it. Ranking is `hit_count × recency` so a consumer that
///    caps the list keeps the terms most likely to matter.
/// 2. `applyCorrections(to:)` — compiled, whole-word, case-insensitive
///    substitutions applied after recognition. This is the real vocabulary net,
///    and the parity surface with Python.
///
/// File format (unchanged from Python; extension fields are additive):
/// ```json
/// {"terms": [
///     {"term": "InsForge", "hear": ["in forge", "ins forge"]},
///     {"term": "Sharique", "hear": ["Shariq", "Cherie"],
///      "source": "spoken_spelling", "learned_at": "2026-08-05T09:12:00Z",
///      "hit_count": 3, "last_used": "2026-08-05T11:44:10Z"}
/// ]}
/// ```
/// Hand-edited entries that predate the extension fields must survive
/// round-trips byte-identical, including keys this code has never heard of —
/// hence the order-preserving `JSONValue` model instead of `Codable`.
public final class DictionaryStore: CorrectionApplying, VocabularySource, @unchecked Sendable {

    /// One compiled substitution. `source` is the literal phrase the pattern was
    /// built from; kept for diagnostics and for the ordering test.
    public struct Correction {
        public let source: String
        public let replacement: String
        public let pattern: NSRegularExpression
    }

    /// Learn-loop bookkeeping for one term (nil fields = never written).
    public struct TermStats: Equatable, Sendable {
        public var hitCount: Int
        public var lastUsed: Date?
        public var learnedAt: Date?
        public var source: String?
    }

    private struct Entry {
        var term: String
        var hear: [String]
        var hitCount: Int
        var lastUsed: Date?
        var learnedAt: Date?
        var source: String?
    }

    private let log = WLog.logger("dictionary")
    private let lock = NSLock()
    private let url: URL

    private var mtime: Date?
    private var fileSize: Int?
    private var entries: [Entry] = []
    private var loadedTerms: [String] = []
    private var loadedCorrections: [Correction] = []
    private var knownLowercased: Set<String> = []

    public init(path: URL = WispritPaths.dictionaryPath) {
        url = path
        load()
    }

    public var path: URL { url }

    // MARK: - Reading

    /// Canonical terms in file order — the exact list `Dictionary.terms()`
    /// returns in Python, duplicates and all.
    public func terms() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return loadedTerms
    }

    /// Compiled `(pattern, replacement)` pairs, longest source first.
    public func corrections() -> [Correction] {
        lock.lock(); defer { lock.unlock() }
        return loadedCorrections
    }

    /// Reload if the file changed on disk. Called at every key-down, so it must
    /// stay a stat, not a read.
    @discardableResult
    public func maybeReload() -> Bool {
        lock.lock()
        let (currentMtime, currentSize) = Self.stat(url)
        guard currentMtime != nil else {
            // File vanished — keep whatever we had rather than going empty.
            lock.unlock()
            return false
        }
        // CONTRACT-DEVIATION: Python compares st_mtime alone. Size is compared
        // too because APFS + an editor that rewrites in place can reuse a
        // timestamp, and a missed reload silently degrades every later
        // utterance. Strictly a superset of the Python trigger.
        guard currentMtime != mtime || currentSize != fileSize else {
            lock.unlock()
            return false
        }
        lock.unlock()
        reload()
        return true
    }

    public func reload() {
        lock.lock(); defer { lock.unlock() }
        load()
    }

    // MARK: - CorrectionApplying

    /// Sequential application in longest-first order, exactly as
    /// `postprocess._apply_dictionary` does it — later patterns see earlier
    /// substitutions, and that cascade is part of the golden behaviour
    /// ("mlx whisper" → "mlx-whisper" → "MLX-whisper").
    public func applyCorrections(to text: String) -> String {
        guard !text.isEmpty else { return text }
        let compiled = corrections()
        var out = text
        for correction in compiled {
            guard !out.isEmpty else { break }
            let range = NSRange(out.startIndex..<out.endIndex, in: out)
            // CONTRACT-DEVIATION: the replacement is run through
            // `escapedTemplate`, so `$` and `\` inside a canonical term stay
            // literal. Python's `sub` would interpret `\1` in a term as a group
            // reference (and raise on a bad one); no seeded or mined term
            // contains either character, so behaviour is identical on real data
            // and strictly safer on hostile input.
            out = correction.pattern.stringByReplacingMatches(
                in: out, options: [], range: range,
                withTemplate: NSRegularExpression.escapedTemplate(for: correction.replacement))
        }
        return out
    }

    // MARK: - VocabularySource

    /// Most-recently-useful first: `hit_count × recency`, ties broken by file
    /// order. A dictionary with no usage data therefore comes back in exactly
    /// `terms()` order. Case-insensitive duplicates are collapsed (the mined
    /// vault data really does contain a repeated term, and biasing the same
    /// string twice only costs latency).
    public func vocabularyTerms() -> [String] {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        let ranked = entries.enumerated().sorted { lhs, rhs in
            let a = Self.usefulness(lhs.element, now: now)
            let b = Self.usefulness(rhs.element, now: now)
            if a != b { return a > b }
            return lhs.offset < rhs.offset  // stable: preserve file order
        }
        var seen = Set<String>()
        var out: [String] = []
        for item in ranked where seen.insert(item.element.term.lowercased()).inserted {
            out.append(item.element.term)
        }
        return out
    }

    /// Is this word already a canonical term? Checked against canonical
    /// spellings only — a `hear` phrase is by definition a *wrong* spelling, so
    /// matching one must not suppress the correction/learn path.
    public func isKnownTerm(_ word: String) -> Bool {
        let needle = word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return false }
        lock.lock(); defer { lock.unlock() }
        return knownLowercased.contains(needle)
    }

    // MARK: - Writing (learn loop)

    /// Merge a learned term into the file additively. Existing entries keep
    /// every key they already had — including ones this code does not know —
    /// and `hear` order is preserved (new misrecognitions are appended).
    public func add(_ learned: LearnedTerm) {
        let term = learned.term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        mutate { root in
            let now = Self.iso8601.string(from: Date())
            let existing = Self.entryObject(in: root, matching: term)
            let isNew = existing == nil
            var entry = existing ?? JSONObject()

            entry["term"] = .string(term)
            entry["hear"] = .array(Self.mergedHear(existing: entry["hear"], adding: learned.heard))
            entry.setIfAbsent("source", .string(learned.source))
            entry.setIfAbsent("learned_at", .string(now))
            // A learn event is also a use: rank the new term straight to the top.
            entry["hit_count"] = .int((entry["hit_count"]?.intValue ?? 0) + 1)
            entry["last_used"] = .string(now)

            Self.store(entry: entry, term: term, into: &root, append: isNew)
        }
    }

    /// Python parity helper (`Dictionary.add_term`), routed through the same
    /// additive merge.
    public func addTerm(_ term: String, misrecognitions: [String] = [], source: String = "manual") {
        add(LearnedTerm(term: term, heard: misrecognitions, source: source))
    }

    /// Remove a term by its canonical spelling (case-insensitive).
    public func removeTerm(_ term: String) {
        let needle = term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return }
        mutate { root in
            guard var object = root.objectValue,
                  let list = object["terms"]?.arrayValue else { return }
            object["terms"] = .array(list.filter { item in
                guard let term = item.objectValue?["term"]?.stringValue else { return true }
                return term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != needle
            })
            root = .object(object)
        }
    }

    /// Bump `hit_count` / `last_used` for a term that just proved useful.
    /// No-op for unknown terms — recording usage must never invent entries.
    public func recordUse(term: String) {
        let needle = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return }
        guard isKnownTerm(needle) else { return }
        mutate { root in
            guard var entry = Self.entryObject(in: root, matching: needle) else { return }
            entry["hit_count"] = .int((entry["hit_count"]?.intValue ?? 0) + 1)
            entry["last_used"] = .string(Self.iso8601.string(from: Date()))
            Self.store(entry: entry, term: needle, into: &root, append: false)
        }
    }

    /// Learn-loop bookkeeping for one term, nil if unknown.
    public func stats(for term: String) -> TermStats? {
        let needle = term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries.first(where: { $0.term.lowercased() == needle }) else { return nil }
        return TermStats(hitCount: entry.hitCount, lastUsed: entry.lastUsed,
                         learnedAt: entry.learnedAt, source: entry.source)
    }

    /// Recorded `hear` phrases for a term, in file order.
    public func heardPhrases(for term: String) -> [String] {
        let needle = term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        lock.lock(); defer { lock.unlock() }
        return entries.first(where: { $0.term.lowercased() == needle })?.hear ?? []
    }

    // MARK: - Load

    private func load() {
        (mtime, fileSize) = Self.stat(url)
        let root = Self.readRaw(url, log: log)
        var parsed: [Entry] = []
        // Correction sources, in discovery order; sorted longest-first below so
        // multi-word misrecognitions win over any single-word overlap.
        var rawPairs: [(source: String, replacement: String)] = []

        for item in root.objectValue?["terms"]?.arrayValue ?? [] {
            guard let object = item.objectValue else { continue }
            let term = (object["term"]?.stringValue ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty else { continue }

            let hear = (object["hear"]?.arrayValue ?? []).compactMap { value -> String? in
                let phrase = (value.stringValue ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return phrase.isEmpty ? nil : phrase
            }
            parsed.append(Entry(
                term: term,
                hear: hear,
                hitCount: object["hit_count"]?.intValue ?? 0,
                lastUsed: Self.parseDate(object["last_used"]?.stringValue),
                learnedAt: Self.parseDate(object["learned_at"]?.stringValue),
                source: object["source"]?.stringValue))

            // Self-correct the term's own casing (the pattern is case-insensitive,
            // so "insforge" → "InsForge" and the canonical form is a no-op).
            rawPairs.append((term, term))
            for phrase in hear { rawPairs.append((phrase, term)) }
        }

        // Stable descending sort by source length in Unicode scalars — Python's
        // `list.sort(key=len, reverse=True)` is stable, Swift's `sorted` is not.
        let ordered = rawPairs.enumerated().sorted { lhs, rhs in
            let a = lhs.element.source.unicodeScalars.count
            let b = rhs.element.source.unicodeScalars.count
            if a != b { return a > b }
            return lhs.offset < rhs.offset
        }

        var compiled: [Correction] = []
        compiled.reserveCapacity(ordered.count)
        for item in ordered {
            let body = Self.relaxedEscape(item.element.source)
            guard let regex = try? NSRegularExpression(pattern: "\\b" + body + "\\b",
                                                       options: [.caseInsensitive]) else {
                log.warning("could not compile correction for \(item.element.source, privacy: .public)")
                continue
            }
            compiled.append(Correction(source: item.element.source,
                                       replacement: item.element.replacement,
                                       pattern: regex))
        }

        entries = parsed
        loadedTerms = parsed.map(\.term)
        loadedCorrections = compiled
        knownLowercased = Set(parsed.map { $0.term.lowercased() })
        log.debug("dictionary loaded: \(parsed.count) terms, \(compiled.count) corrections")
    }

    // MARK: - Pattern construction

    /// Python's `re.escape` (3.7+): escape everything in this set, nothing else.
    /// Reproduced literally so the generated pattern text matches byte-for-byte.
    private static let pythonSpecials: Set<Unicode.Scalar> = {
        var set = Set<Unicode.Scalar>("()[]{}?*+-|^$\\.&~# ".unicodeScalars)
        set.formUnion(["\t", "\n", "\r", "\u{0B}", "\u{0C}"])
        return set
    }()

    /// `re.escape(src).replace("\\ ", "\\s+")` — escaped spaces become `\s+` so
    /// a multi-word misrecognition matches however the recogniser spaced it.
    static func relaxedEscape(_ source: String) -> String {
        var out = ""
        out.reserveCapacity(source.unicodeScalars.count * 2)
        for scalar in source.unicodeScalars {
            if pythonSpecials.contains(scalar) { out.unicodeScalars.append("\\") }
            out.unicodeScalars.append(scalar)
        }
        return out.replacingOccurrences(of: "\\ ", with: "\\s+")
    }

    // MARK: - Ranking

    /// `hit_count × recency`, 30-day half-life. Never-used terms score 0 and
    /// fall back to file order.
    private static func usefulness(_ entry: Entry, now: Date) -> Double {
        guard entry.hitCount > 0 else { return 0 }
        guard let reference = entry.lastUsed ?? entry.learnedAt else { return Double(entry.hitCount) }
        let ageDays = max(0, now.timeIntervalSince(reference)) / 86_400
        return Double(entry.hitCount) * pow(2.0, -ageDays / 30.0)
    }

    // MARK: - File IO

    /// `FileManager`, not `URL.resourceValues`: URL caches resource values, so
    /// the same URL instance would keep reporting the mtime it saw first and hot
    /// reload would never fire.
    private static func stat(_ url: URL) -> (Date?, Int?) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        else { return (nil, nil) }
        return (attributes[.modificationDate] as? Date, (attributes[.size] as? NSNumber)?.intValue)
    }

    private static func readRaw(_ url: URL, log: Logger) -> JSONValue {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return .object(JSONObject())  // missing file: treat as empty, like Python
        }
        do {
            let value = try JSONValue.parse(text)
            guard value.objectValue != nil else {
                log.error("dictionary is not a JSON object; treating as empty")
                return .object(JSONObject())
            }
            return value
        } catch {
            log.error("cannot parse dictionary; treating as empty: \(String(describing: error), privacy: .public)")
            return .object(JSONObject())
        }
    }

    /// Read-modify-write under the lock: always re-reads from disk first so a
    /// hand edit made since the last load is never clobbered, then writes
    /// atomically (temp + fsync + rename) and reloads.
    private func mutate(_ body: (inout JSONValue) -> Void) {
        lock.lock(); defer { lock.unlock() }
        var root = Self.readRaw(url, log: log)
        if root.objectValue?["terms"]?.arrayValue == nil {
            var object = root.objectValue ?? JSONObject()
            object["terms"] = .array([])
            root = .object(object)
        }
        body(&root)
        write(root)
        load()
    }

    private func write(_ root: JSONValue) {
        let text = root.serialized() + "\n"
        let directory = url.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: temporary)
            // fsync before rename: a crash must leave either the old file or the
            // new one, never a truncated dictionary.
            if let handle = try? FileHandle(forWritingTo: temporary) {
                try? handle.synchronize()
                try? handle.close()
            }
            guard rename(temporary.path, url.path) == 0 else {
                throw CocoaError(.fileWriteUnknown)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            log.error("failed to write dictionary: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - JSON entry helpers

    private static func entryObject(in root: JSONValue, matching term: String) -> JSONObject? {
        let needle = term.lowercased()
        for item in root.objectValue?["terms"]?.arrayValue ?? [] {
            guard let object = item.objectValue,
                  let existing = object["term"]?.stringValue else { continue }
            if existing.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == needle {
                return object
            }
        }
        return nil
    }

    private static func store(entry: JSONObject, term: String, into root: inout JSONValue, append: Bool) {
        guard var object = root.objectValue else { return }
        var list = object["terms"]?.arrayValue ?? []
        if append {
            list.append(.object(entry))
        } else {
            let needle = term.lowercased()
            for (index, item) in list.enumerated() {
                guard let existing = item.objectValue?["term"]?.stringValue else { continue }
                if existing.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == needle {
                    list[index] = .object(entry)
                    break
                }
            }
        }
        object["terms"] = .array(list)
        root = .object(object)
    }

    /// Append-only union: existing phrases keep their order and spelling, new
    /// ones are appended, comparison is case-insensitive.
    // CONTRACT-DEVIATION: Python's `add_term` does `sorted(set(...))`, which
    // reorders and re-cases a hand-edited `hear` array on every write. The learn
    // loop writes far more often than a human edits, so preserving what the user
    // typed wins over matching that sort.
    private static func mergedHear(existing: JSONValue?, adding: [String]) -> [JSONValue] {
        var out = existing?.arrayValue ?? []
        var seen = Set(out.compactMap { $0.stringValue?.lowercased() })
        for phrase in adding {
            let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { continue }
            out.append(.string(trimmed))
        }
        return out
    }

    // MARK: - Timestamps

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let iso8601Fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func parseDate(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        return iso8601.date(from: text) ?? iso8601Fractional.date(from: text)
    }
}
