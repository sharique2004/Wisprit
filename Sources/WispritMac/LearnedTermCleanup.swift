import Foundation
import WispritCorrections
import WispritDictionary
import WispritKit
import WispritPersistence

/// Re-judging what the learn loop already wrote, and folding the mistakes back.
///
/// The gate in `LearnPlausibility` stops NEW junk. It cannot help the three
/// entries the ungated loop already put in the live dictionary — `Sharhuue`,
/// `Shaikd`, `Shariq`, each `hear: ["Sharik"]`, `source: "spoken_spelling"` —
/// which are three garbled spellings of one name the dictionary already knew.
/// This is the migration for those: the same classifier, run offline against
/// the rest of the file.
///
/// Two rules make it safe to offer as a button:
///
/// 1. **Only the loop's own writes are judged.** An entry whose `source` is
///    absent or `"manual"` is the user's, and a maintenance action that edits
///    it would be indefensible — so the audit never even looks at one, except
///    as a merge *target*.
/// 2. **Nothing is deleted that cannot be reconstructed.** A merged entry's
///    spelling survives as `hear` evidence on the term it was a spelling of; a
///    rejected one is marked `pending` rather than removed; and
///    `dictionary.json.bak` is written before a byte changes.
///
/// WispritMac is where this can live at all: the classifier is in
/// WispritCorrections, the file model in WispritDictionary, the atomic write in
/// WispritPersistence, and only the shell links all three.
public enum LearnedTermCleanup {

    /// The provenance tag the learn loop stamps on its own writes. Nothing else
    /// is ever audited.
    public static let learnedSource = "spoken_spelling"

    // MARK: - Audit

    /// One entry the classifier says should not be a canonical term, and what
    /// the fix would do with it.
    public struct Suspect: Sendable, Equatable {
        public enum Action: Sendable, Equatable {
            /// A garbled spelling of a term the dictionary already has. Folded
            /// into it as `hear` evidence.
            case fold(into: String)
            /// Not a readable spelling of anything. Quarantined, not deleted.
            case quarantine(reason: String)
        }

        public var term: String
        /// The entry's own `hear` phrases — the misrecognitions that produced
        /// it, and the evidence a fold carries over.
        public var hear: [String]
        public var action: Action

        public init(term: String, hear: [String], action: Action) {
            self.term = term
            self.hear = hear
            self.action = action
        }

        /// How the row reads in a checklist: "Sharhuue → Sharique".
        public var summary: String {
            switch action {
            case .fold(let target): return "\(term) → \(target)"
            case .quarantine(let reason): return "\(term) (\(reason))"
            }
        }
    }

    public struct Audit: Sendable, Equatable {
        /// Learned entries looked at — the denominator the doctor row reports.
        public var examined: Int
        public var suspects: [Suspect]

        public init(examined: Int = 0, suspects: [Suspect] = []) {
            self.examined = examined
            self.suspects = suspects
        }

        public var isClean: Bool { suspects.isEmpty }
        /// "Sharhuue → Sharique, Shaikd → Sharique" — for one doctor line.
        public var names: String { suspects.map(\.summary).joined(separator: ", ") }
    }

    /// Pure: judge every learned entry against the rest of the dictionary.
    ///
    /// Candidates deliberately exclude the audited entries themselves. Without
    /// that, the live file's junk would merge into its own junk (`Sharhuue`
    /// scores 0.980 against `Shariq`) and the cleanup would keep a
    /// misrecognition as the canonical spelling of a name.
    ///
    /// Pending entries are skipped on both sides: one is already quarantined,
    /// so there is nothing to warn about and nothing to merge into.
    public static func audit(entries: [DictionaryStore.LearnedEntry]) -> Audit {
        let live = entries.filter { !$0.isPending }
        let audited = live.filter { $0.stats.source == learnedSource }
        let auditedKeys = Set(audited.map { key($0.term) })
        let candidates = live.map(\.term).filter { !auditedKeys.contains(key($0)) }

        var suspects: [Suspect] = []
        for entry in audited {
            // The entry's first `hear` phrase IS the antecedent the learn event
            // had: the token the ASR produced when the user spelled the name.
            // It is what the anchored merge rule needs, and the reason `Shaikd`
            // (0.725 direct, below the merge bar) is still recognisable as
            // another spelling of the same name.
            let decision = LearnPlausibility.classify(
                collapsed: entry.term, antecedent: entry.hear.first ?? "",
                candidates: candidates)
            switch decision {
            case .merge(let target):
                suspects.append(Suspect(term: entry.term, hear: entry.hear,
                                        action: .fold(into: target)))
            case .reject(let reason):
                suspects.append(Suspect(term: entry.term, hear: entry.hear,
                                        action: .quarantine(reason: reason.rawValue)))
            case .quarantine:
                // Believable and already written: the classifier has no
                // complaint, only a lack of a second sighting. Leave it alone.
                continue
            }
        }
        return Audit(examined: audited.count, suspects: suspects)
    }

    public static func audit(store: DictionaryStore) -> Audit {
        audit(entries: store.learnedEntries())
    }

    // MARK: - The fix

    public struct Outcome: Sendable, Equatable {
        /// "Sharhuue → Sharique" per folded entry.
        public var folded: [String]
        public var quarantined: [String]
        /// Where the pre-fix file was copied. nil when nothing was changed.
        public var backupPath: String?

        public init(folded: [String] = [], quarantined: [String] = [],
                    backupPath: String? = nil) {
            self.folded = folded
            self.quarantined = quarantined
            self.backupPath = backupPath
        }

        public var changed: Bool { backupPath != nil }

        public var summary: String {
            guard changed else { return "nothing to clean up" }
            var parts: [String] = []
            if !folded.isEmpty { parts.append("folded " + folded.joined(separator: ", ")) }
            if !quarantined.isEmpty {
                parts.append("quarantined " + quarantined.joined(separator: ", "))
            }
            return parts.joined(separator: "; ")
        }
    }

    public enum CleanupError: Error, Equatable {
        /// The file could not be parsed as `{"terms": [...]}`. Nothing is
        /// written — a dictionary this code cannot read is a dictionary it has
        /// no business rewriting.
        case unreadable(String)
    }

    /// Back up, fold, quarantine, reload. Idempotent: a second run finds a clean
    /// audit and touches nothing (not even the backup).
    @discardableResult
    public static func run(store: DictionaryStore) throws -> Outcome {
        let audit = audit(store: store)
        guard !audit.isClean else { return Outcome() }

        let url = store.path
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let parsed = try? WispritJSON.parse(text),
              case .object(var root) = parsed,
              case .array(let terms)? = root["terms"] else {
            throw CleanupError.unreadable(url.path)
        }

        root["terms"] = .array(rewrite(terms: terms, suspects: audit.suspects))

        // The backup first, and unconditionally: everything below this line is
        // the user's own file being rewritten by a program.
        let backup = url.appendingPathExtension("bak")
        try AtomicWrite.write(text, to: backup)
        try AtomicWrite.write(WispritJSON.serializePretty(.object(root)) + "\n", to: url)
        store.reload()

        var outcome = Outcome(backupPath: backup.path)
        for suspect in audit.suspects {
            switch suspect.action {
            case .fold: outcome.folded.append(suspect.summary)
            case .quarantine: outcome.quarantined.append(suspect.term)
            }
        }
        return outcome
    }

    // MARK: - Rewriting

    /// The whole edit, as a function of the parsed `terms` array. Order and
    /// unknown keys are preserved because a dictionary.json is hand-edited: an
    /// entry this code did not touch must come back byte-identical.
    static func rewrite(terms: [SettingValue], suspects: [Suspect]) -> [SettingValue] {
        var list = terms
        var dropped = Set<String>()

        for suspect in suspects {
            guard let entryIndex = index(of: suspect.term, in: list) else { continue }
            switch suspect.action {
            case .fold(let target):
                guard let targetIndex = index(of: target, in: list) else { continue }
                // The junk canonical spelling is itself evidence — it is what
                // the ASR produced when the user spelled the name — so it joins
                // the target's `hear` list alongside the phrases it collected.
                list[targetIndex] = appending(hear: [suspect.term] + suspect.hear,
                                              to: list[targetIndex])
                dropped.insert(key(suspect.term))
            case .quarantine:
                list[entryIndex] = quarantining(list[entryIndex])
            }
        }

        guard !dropped.isEmpty else { return list }
        return list.filter { entry in
            guard let term = string(entry, "term") else { return true }
            return !dropped.contains(key(term))
        }
    }

    /// Append-only union, case-insensitive — the same rule `DictionaryStore`
    /// applies to a learn, so a fold and a learn leave the file in the same
    /// shape. A spelling the target already lists is not added twice.
    static func appending(hear phrases: [String], to entry: SettingValue) -> SettingValue {
        guard case .object(var object) = entry else { return entry }
        var out = strings(object["hear"])
        var seen = Set(out.map { $0.lowercased() })
        for phrase in phrases {
            let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { continue }
            out.append(trimmed)
        }
        object["hear"] = .array(out.map { SettingValue.string($0) })
        return .object(object)
    }

    /// Mark an entry pending, in the shape `DictionaryStore.addPending` writes:
    /// `hear` becomes `observations`, because a quarantined entry has not earned
    /// `hear` phrases — it has sightings. Nothing is lost, and a later promotion
    /// folds the observations back into `hear`.
    static func quarantining(_ entry: SettingValue) -> SettingValue {
        guard case .object(var object) = entry else { return entry }
        var observations = strings(object["observations"])
        var seen = Set(observations.map { $0.lowercased() })
        for phrase in strings(object["hear"]) where seen.insert(phrase.lowercased()).inserted {
            observations.append(phrase)
        }
        object["hear"] = nil
        object["pending"] = .bool(true)
        object["observations"] = .array(observations.map { SettingValue.string($0) })
        return .object(object)
    }

    // MARK: - Entry access

    static func index(of term: String, in list: [SettingValue]) -> Int? {
        let needle = key(term)
        return list.firstIndex { string($0, "term").map(key) == needle }
    }

    static func string(_ entry: SettingValue, _ field: String) -> String? {
        guard case .object(let object) = entry,
              case .string(let value)? = object[field] else { return nil }
        return value
    }

    static func strings(_ value: SettingValue?) -> [String] {
        guard case .array(let items)? = value else { return [] }
        return items.compactMap { item -> String? in
            guard case .string(let text) = item else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    /// Terms are matched the way the store matches them: trimmed, case-folded.
    static func key(_ term: String) -> String {
        term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
