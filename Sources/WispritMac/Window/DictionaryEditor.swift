import Foundation
import WispritContext
import WispritCorrections
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
///
/// The review decisions (stop matching, keep, merge) are in-place store edits
/// that keep every other key, and every write the page makes is undoable: the
/// editor snapshots the terms a change touches before and after it
/// (`DictionaryChange`), and undo puts the "before" back byte for byte.

// MARK: - Where a term came from

/// `source`, in the words the page shows. Every value the code writes has a
/// case; anything else (a hand-edited or future value) is `imported` rather
/// than a guess.
///
/// `vocab_retro` deserves a note: that path only ever adds a `hear` phrase to
/// a term the dictionary ALREADY had, and stamps `source` with `setIfAbsent`.
/// So on a term that had no `source` before, the tag records the first thing
/// Wisprit learned for it automatically — the term itself predates that.
public enum DictionarySource: String, CaseIterable, Sendable, Equatable {
    /// No `source` (hand-written or seeded entries) or `manual`.
    case addedByYou
    /// `vocab_retro`: the second listening pass heard the term.
    case learnedAutomatically
    /// `spoken_spelling`: "actually it's S-H-A-R-I-Q-U-E".
    case learnedFromSpelling
    /// `edit_capture`: the user typed over Wisprit's output, more than once.
    case learnedFromEdits
    /// Any other value.
    case imported

    public init(_ raw: String?) {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case nil, "", "manual": self = .addedByYou
        case "vocab_retro": self = .learnedAutomatically
        case "spoken_spelling": self = .learnedFromSpelling
        case "edit_capture": self = .learnedFromEdits
        default: self = .imported
        }
    }

    public var label: String {
        switch self {
        case .addedByYou: return "added by you"
        case .learnedAutomatically: return "learned automatically"
        case .learnedFromSpelling: return "learned from a spelling"
        case .learnedFromEdits: return "learned from your edits"
        case .imported: return "imported"
        }
    }

    /// Wisprit wrote it, not the user — the "Learned" filter.
    public var isLearned: Bool {
        switch self {
        case .learnedAutomatically, .learnedFromSpelling, .learnedFromEdits: return true
        case .addedByYou, .imported: return false
        }
    }
}

// MARK: - One row

public struct DictionaryRow: Identifiable, Sendable, Equatable {
    public var term: String
    /// The `hear` phrases, in file order.
    public var hear: [String]
    /// The raw `source` value; `kind` is what the page shows.
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
    /// `kept_hears`: everyday-word phrases the user reviewed and kept.
    public var keptHears: [String]

    public var id: String { term.lowercased() }

    public init(term: String, hear: [String] = [], source: String? = nil,
                hitCount: Int = 0, learnedAt: Date? = nil, lastUsed: Date? = nil,
                isPending: Bool = false, observations: [String] = [],
                keptHears: [String] = []) {
        self.term = term
        self.hear = hear
        self.source = source
        self.hitCount = hitCount
        self.learnedAt = learnedAt
        self.lastUsed = lastUsed
        self.isPending = isPending
        self.observations = observations
        self.keptHears = keptHears
    }

    public var kind: DictionarySource { DictionarySource(source) }

    /// Wisprit taught itself this one.
    public var isLearned: Bool { kind.isLearned }

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

// MARK: - "Is this an everyday word?"

/// The fuzzy layer's ordinary-word veto, asked by the page.
///
/// Not a second lexicon and not a second rule: the lookup is the same
/// `Lexicon` the app hands `FuzzyVocabularyCorrector` (AppController passes its
/// one shared `SystemLexicon`), and the rule is the corrector's own
/// `isOrdinaryToken` — the word itself, or a regular-suffix stem of it. So the
/// page calls "play" an everyday word exactly when the engine does.
///
/// What the page does with the answer is different, and that is the point: the
/// fuzzy layer *refuses* to guess at an everyday word, but the exact pass
/// applies whatever `hear` says, so a `hear` phrase that IS an everyday word
/// rewrites that word in every dictation ("play" → Ploy). Those are the phrases
/// the review asks about.
public struct OrdinaryWords: Sendable {
    private let lookup: @Sendable (String) -> Bool
    private let loaded: @Sendable () -> Bool

    public init(lookup: @escaping @Sendable (String) -> Bool,
                isLoaded: @escaping @Sendable () -> Bool = { true }) {
        self.lookup = lookup
        self.loaded = isLoaded
    }

    /// Wrap a lexicon. A `SystemLexicon` loads `/usr/share/dict/words` in the
    /// background and answers from its compiled-in floor until then, which
    /// `isReady` reports so the page can re-ask.
    public init(_ lexicon: any Lexicon) {
        let system = lexicon as? SystemLexicon
        self.init(lookup: { lexicon.contains($0) },
                  isLoaded: { system?.isLoaded ?? true })
    }

    /// For anything built without the app's lexicon (the offscreen renderer,
    /// tests that do not care): one process-wide `SystemLexicon`, made on
    /// first use.
    public static var system: OrdinaryWords { OrdinaryWords(SharedLexicon.instance) }

    /// Nothing is an everyday word — a review that never flags anything.
    public static let none = OrdinaryWords(lookup: { _ in false })

    /// The full lexicon is answering (not just its compiled-in floor).
    public var isReady: Bool { loaded() }

    /// Start the lexicon's one-time load without waiting for it.
    public func prewarm() { _ = lookup("the") }

    /// One word, and the engine's veto calls it ordinary. A multi-word phrase
    /// is never "an everyday word": it only matches when all of its words are
    /// said together, and most such phrases are the term itself, spaced out
    /// ("four hands" for Four Hands) — which is the dictionary working.
    public func isEveryday(_ phrase: String) -> Bool {
        let token = phrase.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !token.isEmpty, !token.contains(where: \.isWhitespace) else { return false }
        return FuzzyVocabularyCorrector.isOrdinaryToken(token, lookup)
    }
}

private enum SharedLexicon {
    static let instance = SystemLexicon()
}

// MARK: - Needs review

/// A term whose `hear` list contains everyday words — each one is rewritten to
/// the term every time it is said.
public struct EverydayWordReview: Identifiable, Equatable, Sendable {
    public var term: String
    public var kind: DictionarySource
    /// The flagged phrases, in file order: everyday words, not the term's own
    /// spelling, not already kept. Exactly what "Stop matching" removes.
    public var words: [String]

    public var id: String { term.lowercased() }
}

/// One term listed more than once in the file.
public struct DuplicateReview: Identifiable, Equatable, Sendable {
    public var term: String
    public var copies: Int

    public var id: String { term.lowercased() }
}

/// Everything in `dictionary.json` that needs the user's decision. (Learn
/// proposals and the learned-spelling audit live in their own stores and are
/// added to the count by the window model.)
public struct DictionaryReview: Equatable, Sendable {
    public var everydayWords: [EverydayWordReview] = []
    public var duplicates: [DuplicateReview] = []
    /// Quarantined entries: heard once, waiting for a second sighting.
    public var pending: [DictionaryRow] = []

    public static let empty = DictionaryReview()

    public init(everydayWords: [EverydayWordReview] = [], duplicates: [DuplicateReview] = [],
                pending: [DictionaryRow] = []) {
        self.everydayWords = everydayWords
        self.duplicates = duplicates
        self.pending = pending
    }

    public var count: Int { everydayWords.count + duplicates.count + pending.count }
    public var isEmpty: Bool { count == 0 }

    /// The flagged `hear` phrases of one row: everyday words that are not the
    /// term's own spelling (every term already matches itself, so removing
    /// that phrase would change nothing) and that the user has not kept.
    public static func everydayWords(in row: DictionaryRow, ordinary: OrdinaryWords) -> [String] {
        guard !row.isPending else { return [] }
        let term = normalized(row.term)
        let kept = Set(row.keptHears.map(normalized))
        return row.hear.filter { phrase in
            let key = normalized(phrase)
            return key != term && !kept.contains(key) && ordinary.isEveryday(phrase)
        }
    }

    public static func build(_ rows: [DictionaryRow], ordinary: OrdinaryWords) -> DictionaryReview {
        var review = DictionaryReview()
        var everydayIndex: [String: Int] = [:]
        var copies: [String: (term: String, count: Int)] = [:]
        var order: [String] = []

        for row in rows {
            if copies[row.id] == nil { order.append(row.id) }
            copies[row.id, default: (row.term, 0)].count += 1

            if row.isPending {
                review.pending.append(row)
                continue
            }
            let words = everydayWords(in: row, ordinary: ordinary)
            guard !words.isEmpty else { continue }
            // A term listed twice is one decision, not two.
            if let index = everydayIndex[row.id] {
                let seen = Set(review.everydayWords[index].words.map(normalized))
                review.everydayWords[index].words += words.filter { !seen.contains(normalized($0)) }
            } else {
                everydayIndex[row.id] = review.everydayWords.count
                review.everydayWords.append(
                    EverydayWordReview(term: row.term, kind: row.kind, words: words))
            }
        }
        review.duplicates = order.compactMap { id in
            guard let entry = copies[id], entry.count > 1 else { return nil }
            return DuplicateReview(term: entry.term, copies: entry.count)
        }
        return review
    }

    private static func normalized(_ phrase: String) -> String {
        phrase.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

// MARK: - Undo

/// One undoable write: the touched terms as the file held them before and
/// after. Undo restores `before`, redo restores `after`, both through
/// `DictionaryStore.restore` — positions, unknown keys and stats included.
public struct DictionaryChange: Identifiable, Equatable, Sendable {
    public let id = UUID()
    /// The inline confirmation: "Deleted “Ploy”."
    public let summary: String
    /// Edit ▸ Undo <name>.
    public let actionName: String
    let before: [DictionaryStore.TermSnapshot]
    let after: [DictionaryStore.TermSnapshot]
    /// The `UndoManager` registers against this object, so one change's
    /// actions can be removed without touching any other.
    let token = DictionaryChangeToken()

    public static func == (lhs: DictionaryChange, rhs: DictionaryChange) -> Bool {
        lhs.id == rhs.id
    }
}

final class DictionaryChangeToken: Sendable {}

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
    public let ordinaryWords: OrdinaryWords

    private let readyLock = NSLock()
    private var isAwaitingLexicon = false

    public init(store: DictionaryStore, ordinaryWords: OrdinaryWords = .system) {
        self.store = store
        self.ordinaryWords = ordinaryWords
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
                          observations: entry.observations,
                          keptHears: entry.keptHears)
        }
    }

    public func row(named term: String) -> DictionaryRow? {
        let needle = term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return rows().first { $0.term.lowercased() == needle }
    }

    // MARK: review

    public func review(_ rows: [DictionaryRow]) -> DictionaryReview {
        DictionaryReview.build(rows, ordinary: ordinaryWords)
    }

    public func everydayWords(in row: DictionaryRow) -> [String] {
        DictionaryReview.everydayWords(in: row, ordinary: ordinaryWords)
    }

    /// Call `body` once the lexicon has finished loading, if it has not yet —
    /// a review computed before then only knew the compiled-in word list.
    /// Nothing happens when it is already loaded; overlapping requests share
    /// one wait.
    public func whenOrdinaryWordsReady(_ body: @escaping @Sendable () -> Void) {
        let words = ordinaryWords
        guard !words.isReady else { return }
        readyLock.lock()
        guard !isAwaitingLexicon else {
            readyLock.unlock()
            return
        }
        isAwaitingLexicon = true
        readyLock.unlock()
        words.prewarm()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let deadline = Date().addingTimeInterval(10)
            while !words.isReady, Date() < deadline { usleep(50_000) }
            guard let self else { return }
            self.readyLock.lock()
            self.isAwaitingLexicon = false
            self.readyLock.unlock()
            body()
        }
    }

    // MARK: writes

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

    /// "Stop matching these": drop just these phrases from the term's `hear`
    /// list. Lossless for everything else on the entry.
    @discardableResult
    public func stopMatching(_ phrases: [String], for term: String) -> Bool {
        store.removeHears(phrases, from: term)
    }

    /// "Keep": the phrases stay and keep correcting; the review stops asking.
    @discardableResult
    public func keep(_ phrases: [String], for term: String) -> Bool {
        store.keepHears(phrases, for: term)
    }

    @discardableResult
    public func mergeDuplicates(of term: String) -> Bool {
        store.mergeDuplicates(of: term)
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

    // MARK: undo

    /// Run `perform` with the touched terms snapshotted on both sides. nil when
    /// it reported no write or the file came out identical — nothing to undo.
    public func change(_ summary: String, actionName: String, terms: [String],
                       perform: () -> Bool) -> DictionaryChange? {
        var keys = Set<String>()
        let unique = terms.filter {
            let key = $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return !key.isEmpty && keys.insert(key).inserted
        }
        let before = unique.map { store.snapshot(term: $0) }
        guard perform() else { return nil }
        let after = unique.map { store.snapshot(term: $0) }
        guard before != after else { return nil }
        return DictionaryChange(summary: summary, actionName: actionName,
                                before: before, after: after)
    }

    public func revert(_ change: DictionaryChange) {
        change.before.forEach(store.restore)
    }

    public func reapply(_ change: DictionaryChange) {
        change.after.forEach(store.restore)
    }
}
