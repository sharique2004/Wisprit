#if os(macOS)
import Foundation
import WispritDictionary

/// The Dictionary page's writes and its review queue.
///
/// Every write the page makes goes through `commitDictionaryChange`, which
/// snapshots the touched terms on both sides of the write (`DictionaryChange`)
/// and makes it undoable two ways that cannot disagree:
///
///  * the window's `UndoManager` (Edit ▸ Undo / ⌘Z, redo included), which the
///    page hands over as `dictionaryUndoManager`;
///  * the page's inline "Undo" (`undoDictionaryChange`), for the change it just
///    confirmed — which also withdraws that change from the undo manager, so
///    ⌘Z can never undo it a second time.
///
/// Learn proposals are the one decision that is NOT undoable from here: Accept
/// and Dismiss write the pending-learn ledger through the app's ports, and a
/// dismissal is a permanent negative by design.
extension WispritWindowModel {

    // MARK: - review

    /// Recompute what needs a decision from the rows already loaded. If the
    /// system lexicon was still loading, the answer came from its compiled-in
    /// floor alone, so ask again once it lands.
    public func refreshDictionaryReview() {
        dictionaryReview = dictionary.review(dictionaryRows)
        dictionary.whenOrdinaryWordsReady { [weak self] in
            Task { @MainActor in self?.refreshDictionaryReview() }
        }
    }

    /// The flagged phrases of one row (the list tints them).
    public func everydayWords(in row: DictionaryRow) -> [String] {
        dictionary.everydayWords(in: row)
    }

    /// The add/edit sheet's warning: is this phrase an everyday word?
    public func isEverydayWord(_ phrase: String) -> Bool {
        dictionary.ordinaryWords.isEveryday(phrase)
    }

    // MARK: - review decisions

    /// "Stop matching these": the term stops listening for exactly the flagged
    /// words. Everything else on the entry — its other phrases, stats,
    /// provenance — is untouched.
    @discardableResult
    public func stopMatching(_ item: EverydayWordReview) -> Bool {
        commitDictionaryChange(
            "\(item.term) no longer changes \(DictionaryCopy.quotedList(item.words)).",
            actionName: "Stop Matching", terms: [item.term]) {
                dictionary.stopMatching(item.words, for: item.term)
            }
    }

    /// "Keep": the words keep correcting, and the review stops asking about
    /// them (`kept_hears`). A new everyday word learned later is asked about.
    @discardableResult
    public func keepEverydayWords(_ item: EverydayWordReview) -> Bool {
        commitDictionaryChange(
            "Kept \(DictionaryCopy.quotedList(item.words)) for \(item.term).",
            actionName: "Keep Words", terms: [item.term]) {
                dictionary.keep(item.words, for: item.term)
            }
    }

    @discardableResult
    public func mergeDuplicates(_ item: DuplicateReview) -> Bool {
        commitDictionaryChange(
            "Merged the \(item.copies) copies of “\(item.term)”.",
            actionName: "Merge Duplicates", terms: [item.term]) {
                dictionary.mergeDuplicates(of: item.term)
            }
    }

    // MARK: - edits

    @discardableResult
    public func saveTerm(original: DictionaryRow?, term: String, hear: [String]) -> Bool {
        let name = term.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = original == nil ? "Added “\(name)”." : "Saved “\(name)”."
        return commitDictionaryChange(summary,
                                      actionName: original == nil ? "Add Term" : "Edit Term",
                                      terms: [original?.term, name].compactMap { $0 }) {
            dictionary.save(original: original, term: term, hear: hear)
        }
    }

    public func deleteTerm(_ term: String) {
        commitDictionaryChange("Deleted “\(term)”.", actionName: "Delete Term", terms: [term]) {
            dictionary.delete(term)
            return true
        }
    }

    /// Accept a quarantined term. Dismissing one is just `deleteTerm` — the
    /// store's own removal, not a second kind of delete.
    @discardableResult
    public func promoteTerm(_ row: DictionaryRow) -> Bool {
        commitDictionaryChange("Added “\(row.term)”.", actionName: "Accept Term",
                               terms: [row.term]) {
            dictionary.promote(row)
        }
    }

    // MARK: - undo

    /// The inline Undo: put the last change back and withdraw it from the undo
    /// manager.
    public func undoDictionaryChange() {
        guard let change = dictionaryLastChange else { return }
        dictionaryUndoManager?.removeAllActions(withTarget: change.token)
        dictionary.revert(change)
        dictionaryLastChange = nil
        reloadDictionary()
    }

    /// The confirmation went away (timed out, or closed). ⌘Z still works.
    public func dismissDictionaryChange() {
        dictionaryLastChange = nil
    }

    /// Run one write, record it, refresh. False when nothing changed.
    @discardableResult
    func commitDictionaryChange(_ summary: String, actionName: String, terms: [String],
                                _ perform: () -> Bool) -> Bool {
        let change = dictionary.change(summary, actionName: actionName, terms: terms,
                                       perform: perform)
        reloadDictionary()
        guard let change else { return false }
        dictionaryLastChange = change
        if let undo = dictionaryUndoManager {
            // Its own group, so the change undoes alone whatever else the
            // current event registered (a search-field edit, say).
            undo.beginUndoGrouping()
            register(change, undoing: true, on: undo)
            undo.endUndoGrouping()
        }
        return true
    }

    /// `undoing` true registers the undo (restore `before`); false the redo.
    /// Each run registers its inverse, which is how the manager gets redo.
    private func register(_ change: DictionaryChange, undoing: Bool, on undo: UndoManager) {
        undo.registerUndo(withTarget: change.token) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.replay(change, undoing: undoing)
            }
        }
        undo.setActionName(change.actionName)
    }

    private func replay(_ change: DictionaryChange, undoing: Bool) {
        if undoing { dictionary.revert(change) } else { dictionary.reapply(change) }
        dictionaryLastChange = nil
        reloadDictionary()
        if let undo = dictionaryUndoManager {
            register(change, undoing: !undoing, on: undo)
        }
    }
}

/// Copy the model writes into confirmations. Pure.
enum DictionaryCopy {
    /// “a”, “a” and “b”, “a”, “b” and “c”.
    static func quotedList(_ words: [String]) -> String {
        let quoted = words.map { "“\($0)”" }
        guard quoted.count > 1 else { return quoted.first ?? "" }
        return quoted.dropLast().joined(separator: ", ") + " and " + quoted[quoted.count - 1]
    }
}
#endif
