import Foundation
import WispritDictionary
import WispritKit

/// The dictionary table's model, and the only place the window writes terms.
///
/// Every write goes through `DictionaryStore`, so it stays atomic and the
/// running session picks it up through the normal mtime hot-reload — the window
/// never touches `dictionary.json` itself. That also means the window is bound
/// by the store's public API, which is *additive*: `add` merges and preserves
/// keys it has never heard of, `removeTerm` deletes. An edit that only appends
/// misrecognitions therefore keeps `learned_at`, `source` and any hand-written
/// fields; an edit that deletes a phrase or renames the term cannot, and the
/// plan says so out loud.

// MARK: - One row

public struct DictionaryRow: Identifiable, Sendable, Equatable {
    public var term: String
    /// The `hear` phrases, in file order.
    public var hear: [String]
    /// `spoken_spelling` for terms Wisprit learned from a spelled-out
    /// correction, `manual` for hand-added ones, nil for entries that predate
    /// the field.
    public var source: String?
    public var hitCount: Int
    public var learnedAt: Date?
    public var lastUsed: Date?

    public var id: String { term.lowercased() }

    public init(term: String, hear: [String] = [], source: String? = nil,
                hitCount: Int = 0, learnedAt: Date? = nil, lastUsed: Date? = nil) {
        self.term = term
        self.hear = hear
        self.source = source
        self.hitCount = hitCount
        self.learnedAt = learnedAt
        self.lastUsed = lastUsed
    }

    /// Wisprit taught itself this one, from "actually it's S-H-A-R-I-Q-U-E".
    public var isLearned: Bool { source == "spoken_spelling" }

    /// Short labels shown next to the term.
    public var badges: [String] {
        var out: [String] = []
        if isLearned { out.append("learned") }
        if hitCount > 0 { out.append("used \(hitCount)×") }
        return out
    }

    /// Search over the canonical spelling AND the misrecognitions — the phrase
    /// the user remembers is usually the wrong one they keep getting.
    public func matches(_ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return true }
        if term.lowercased().contains(needle) { return true }
        return hear.contains { $0.lowercased().contains(needle) }
    }
}

// MARK: - Edit planning

/// What an edit has to do to the file, decided before anything is written so the
/// consequence (lossless merge vs. rewrite) is visible and testable.
public enum DictionaryEditPlan: Sendable, Equatable {
    case noop
    /// Additive merge through `DictionaryStore.add` — keeps `learned_at`,
    /// `source` and unknown keys, appends new `hear` phrases.
    case merge(term: String, heard: [String], source: String)
    /// A phrase was removed or the canonical spelling changed, neither of which
    /// the additive path can express: delete the entry and write it again.
    /// `learned_at` and `hit_count` restart; `source` is carried over.
    case rebuild(removing: String, term: String, heard: [String], source: String)
}

public enum DictionaryEdit {

    public static let defaultSource = "manual"

    /// `original` nil means "new term".
    public static func plan(original: DictionaryRow?,
                            term rawTerm: String,
                            hear rawHear: [String]) -> DictionaryEditPlan {
        let term = rawTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return .noop }
        let hear = normalize(rawHear)
        let source = original?.source ?? defaultSource

        guard let original else {
            return .merge(term: term, heard: hear, source: source)
        }

        let renamed = original.term != term
        let existing = normalize(original.hear)
        let kept = Set(existing.map { $0.lowercased() })
            .isSubset(of: Set(hear.map { $0.lowercased() }))

        if !renamed && kept {
            let added = hear.filter { phrase in
                !existing.contains { $0.lowercased() == phrase.lowercased() }
            }
            guard !added.isEmpty else { return .noop }
            return .merge(term: term, heard: added, source: source)
        }
        return .rebuild(removing: original.term, term: term, heard: hear, source: source)
    }

    /// Trim, drop empties, drop case-insensitive duplicates, keep order.
    public static func normalize(_ phrases: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for phrase in phrases {
            let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { continue }
            out.append(trimmed)
        }
        return out
    }

    /// Split the comma-or-newline separated text field the editor sheet uses.
    public static func parseHearField(_ text: String) -> [String] {
        normalize(text.split(whereSeparator: { $0 == "," || $0 == "\n" }).map(String.init))
    }

    public static func formatHearField(_ phrases: [String]) -> String {
        phrases.joined(separator: ", ")
    }
}

// MARK: - The store-backed editor

/// A thin, testable wrapper: reads rows out of a `DictionaryStore`, applies
/// plans back into it. Owns no state of its own, so a hot-reload triggered by
/// the session thread is picked up on the next `rows()`.
public final class DictionaryEditor: @unchecked Sendable {
    private let store: DictionaryStore

    public init(store: DictionaryStore) {
        self.store = store
    }

    public var path: URL { store.path }

    /// Fresh rows, file order preserved. Reloads first so a term the learn loop
    /// added while the window was open shows up.
    public func rows() -> [DictionaryRow] {
        store.maybeReload()
        return store.terms().map { term in
            let stats = store.stats(for: term)
            return DictionaryRow(term: term,
                                 hear: store.heardPhrases(for: term),
                                 source: stats?.source,
                                 hitCount: stats?.hitCount ?? 0,
                                 learnedAt: stats?.learnedAt,
                                 lastUsed: stats?.lastUsed)
        }
    }

    public func row(named term: String) -> DictionaryRow? {
        let needle = term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return rows().first { $0.term.lowercased() == needle }
    }

    @discardableResult
    public func apply(_ plan: DictionaryEditPlan) -> Bool {
        switch plan {
        case .noop:
            return false
        case .merge(let term, let heard, let source):
            store.add(LearnedTerm(term: term, heard: heard, source: source))
            return true
        case .rebuild(let removing, let term, let heard, let source):
            store.removeTerm(removing)
            store.add(LearnedTerm(term: term, heard: heard, source: source))
            return true
        }
    }

    /// Convenience for the sheet: plan, then apply.
    @discardableResult
    public func save(original: DictionaryRow?, term: String, hear: [String]) -> Bool {
        apply(DictionaryEdit.plan(original: original, term: term, hear: hear))
    }

    public func delete(_ term: String) {
        store.removeTerm(term)
    }
}
