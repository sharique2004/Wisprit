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
    /// Quarantined (`pending: true`): believable, seen once, and excluded from
    /// every derived structure until a second sighting promotes it. Not
    /// vocabulary yet — bookkeeping the window is the only place to act on.
    public var isPending: Bool
    /// Sightings recorded while pending. They become the `hear` phrases on
    /// promotion, so to a reader of the row they ARE its heard phrases.
    public var observations: [String]

    public var id: String { term.lowercased() }

    public init(term: String, hear: [String] = [], source: String? = nil,
                hitCount: Int = 0, learnedAt: Date? = nil, lastUsed: Date? = nil,
                isPending: Bool = false, observations: [String] = []) {
        self.term = term
        self.hear = hear
        self.source = source
        self.hitCount = hitCount
        self.learnedAt = learnedAt
        self.lastUsed = lastUsed
        self.isPending = isPending
        self.observations = observations
    }

    /// Wisprit taught itself this one, from "actually it's S-H-A-R-I-Q-U-E".
    public var isLearned: Bool { source == "spoken_spelling" }

    /// What the row shows under "hears". A pending entry has no `hear` array
    /// at all — the store moves its phrases to `observations` — so the two are
    /// one list to everything that only wants to read them.
    public var phrases: [String] { hear.isEmpty ? observations : hear }

    /// Short labels shown next to the term.
    public var badges: [String] {
        // A quarantined entry corrects nothing and has never been used, so
        // "learned"/"used" would both be lies. Pending is the whole story.
        if isPending { return ["pending"] }
        var out: [String] = []
        if isLearned { out.append("learned") }
        if hitCount > 0 { out.append("used \(hitCount)×") }
        return out
    }

    /// Search over the canonical spelling AND the misrecognitions — the phrase
    /// the user remembers is usually the wrong one they keep getting. A pending
    /// entry's misrecognitions live in `observations`, and searching only `hear`
    /// would make exactly the rows that need a decision unfindable.
    public func matches(_ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return true }
        if term.lowercased().contains(needle) { return true }
        return phrases.contains { $0.lowercased().contains(needle) }
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
    ///
    /// `learnedEntries()` rather than `terms()` because it is the one read that
    /// reports quarantined entries: `terms()` — like the compiled corrections,
    /// `isKnownTerm` and the biasing list — deliberately excludes them, which is
    /// right for the engine and wrong for the only surface where a human can
    /// accept or dismiss one. It is also per-entry, so a file with the same term
    /// twice gets two rows with their own stats instead of two copies of the
    /// first one's.
    public func rows() -> [DictionaryRow] {
        store.maybeReload()
        return store.learnedEntries().map { entry in
            DictionaryRow(term: entry.term,
                          hear: entry.hear,
                          source: entry.stats.source,
                          hitCount: entry.stats.hitCount,
                          learnedAt: entry.stats.learnedAt,
                          lastUsed: entry.stats.lastUsed,
                          isPending: entry.isPending,
                          observations: entry.observations)
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

    /// Accept a quarantined entry: it becomes live vocabulary now, without
    /// waiting for the second sighting.
    ///
    /// Routed through `DictionaryStore.addPending` — the *same* call the second
    /// sighting makes — rather than through a plan, because promotion is the
    /// store's own transition: `observations` fold into `hear`, `pending` and
    /// `observations` drop out, and the entry starts ranking like any other
    /// learn. A `.merge` plan would leave `pending: true` in place and the term
    /// still invisible to the engine, which is exactly the bug this avoids.
    ///
    /// - Returns: true once the term is live vocabulary.
    @discardableResult
    public func promote(_ row: DictionaryRow) -> Bool {
        guard row.isPending else { return false }
        // Passing back one of its own observations is a no-op for the merged
        // `hear` list (the store de-duplicates case-insensitively), so the only
        // effect is the promotion itself.
        return store.addPending(term: row.term,
                                observation: row.observations.first ?? "",
                                source: row.source ?? DictionaryEdit.defaultSource)
    }
}
