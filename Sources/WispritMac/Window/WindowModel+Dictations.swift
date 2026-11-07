#if os(macOS)
import Foundation
import WispritMacUI
import WispritPersistence

/// The Dictations page's state: its rows (dictations and misses, already
/// matched against `metrics.log`), the selection the inspector follows, and
/// the Heard | Written toggle.
///
/// Its own object rather than more `@Published` lines on the window model, so
/// the page that reads it is the only view that redraws when it changes. The
/// window model owns one and feeds it from `loadHistory`, which already runs
/// when the window opens, on every tick while this page is showing, and after
/// a purge — so the page needs no timer of its own.
///
/// The log is parsed off the main actor and only when its modification date
/// moves: an idle page costs one `stat` and one 50-row SQLite read per tick.
@MainActor
public final class DictationsFeed: ObservableObject {
    /// Newest first: every loaded dictation and every miss as far back as
    /// they reach (`DictationsModel.timeline`).
    @Published public private(set) var entries: [DictationEntry] = []
    /// The first read has landed. Until then the page draws nothing rather
    /// than an empty state over a full history.
    @Published public private(set) var hasLoaded = false
    /// Median key-up → text over recent deliveries, for the header line.
    @Published public private(set) var secondsToText: Double?
    /// The row the inspector shows. Survives reloads (ids are stable).
    @Published public var selection: DictationEntry.ID?
    /// The inspector's toggle: Heard (true) or Written (false, the default).
    @Published public var showsHeard = false

    /// What `render-window --select` asks for, applied once to the first load.
    public enum Preselect: String, Sendable {
        /// The newest row.
        case first
        /// The newest miss.
        case missed
        /// The newest dictation whose written text differs from what was heard.
        case changed
    }
    public var preselect: Preselect?
    /// The search the preselection picks within (the render's `--search`).
    public var preselectQuery = ""

    private var metricsStamp: Date?
    private var metrics: [MetricsUtterance] = []
    private var generation = 0

    public init() {}

    /// The selected row, if it is still loaded.
    public var selectedEntry: DictationEntry? {
        guard let selection else { return nil }
        return entries.first { $0.id == selection }
    }

    /// Re-read the newest `limit` transcripts and, if it changed, the log.
    /// A reload that a newer one overtakes is dropped.
    public func reload(limit: Int,
                       rows: @escaping @Sendable (Int) -> [DictationRow],
                       metricsStamp: @escaping @Sendable () -> Date?,
                       metricsRows: @escaping @Sendable () -> [JSONObject],
                       now: @escaping @Sendable () -> Date = { Date() }) {
        generation += 1
        let token = generation
        let knownStamp = self.metricsStamp
        let cached = self.metrics
        let mustParse = !hasLoaded
        Task { [weak self] in
            let read = await Task.detached(priority: .utility) { () -> Read in
                let fetched = rows(limit)
                let records = HomeSource.records(fetched)
                let stamp = metricsStamp()
                let lines = (!mustParse && stamp == knownStamp)
                    ? cached
                    : HomeSource.utterances(metricsRows())
                let entries = DictationsModel.timeline(records: records, metrics: lines,
                                                       isComplete: fetched.count < limit,
                                                       now: now())
                return Read(entries: entries, stamp: stamp, metrics: lines,
                            secondsToText: DictationsModel.medianSecondsToText(lines))
            }.value
            guard let self, token == self.generation else { return }
            self.metricsStamp = read.stamp
            self.metrics = read.metrics
            if self.entries != read.entries { self.entries = read.entries }
            if self.secondsToText != read.secondsToText { self.secondsToText = read.secondsToText }
            self.hasLoaded = true
            self.applyPreselect()
        }
    }

    private struct Read: Sendable {
        var entries: [DictationEntry]
        var stamp: Date?
        var metrics: [MetricsUtterance]
        var secondsToText: Double?
    }

    private func applyPreselect() {
        guard let preselect else { return }
        self.preselect = nil
        let candidates = DictationsModel.filter(entries, query: preselectQuery)
        let pick: DictationEntry?
        switch preselect {
        case .first:
            pick = candidates.first
        case .missed:
            pick = candidates.first { $0.miss != nil }
        case .changed:
            pick = candidates.first { entry in
                guard let record = entry.record, let heard = record.heard else { return false }
                return !WordDiff.diff(heard: heard, written: record.text).isUnchanged
            }
        }
        selection = pick?.id
    }
}

// MARK: - actions the page and its inspector take

extension WispritWindowModel {

    /// What Teach did — the popover says so in words.
    public enum TeachResult: Equatable, Sendable {
        /// A new term, or a new heard phrase on an existing one.
        case added(term: String)
        /// The dictionary already had exactly this.
        case alreadyKnown(term: String)
        /// Nothing to write: no spelling.
        case invalid
    }

    /// Teach a spelling from a dictation: "when you hear `heard`, write
    /// `spelling`". Goes through the same `DictionaryEditor` plan the
    /// Dictionary page uses — an existing term gains the phrase without losing
    /// its stats, a new term is added as the user's own.
    @discardableResult
    public func teach(heard: String, spelling: String) -> TeachResult {
        let term = spelling.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return .invalid }
        let phrase = DictationsModel.teachablePhrase(heard)
        let existing = dictionaryRows.first { $0.term.lowercased() == term.lowercased() }
        var hear = existing?.hear ?? []
        if !phrase.isEmpty, phrase.lowercased() != term.lowercased() { hear.append(phrase) }
        let canonical = existing?.term ?? term
        if existing != nil, DictionaryEdit.plan(original: existing, term: canonical, hear: hear) == .noop {
            return .alreadyKnown(term: canonical)
        }
        return saveTerm(original: existing, term: canonical, hear: hear)
            ? .added(term: canonical)
            : .alreadyKnown(term: canonical)
    }

    /// Paste one dictation back into the app the user was in. The window
    /// model's own guard (idle session, non-empty text) still applies.
    public func pasteAgain(_ record: DictationRecord) {
        pasteAtCursor(record.text)
    }
}
#endif
