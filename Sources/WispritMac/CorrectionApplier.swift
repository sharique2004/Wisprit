import Foundation
import WispritCorrections
import WispritKit

/// Turn a `CorrectionAction` into (a) the text that should actually be
/// inserted and (b) the off-path follow-up work.
///
/// Pure, and deliberately so: this is the only place in the shell that edits
/// words the user is about to see, and a wrong retro-edit deletes a correct
/// word from their document. Everything here runs on the RAW ASR final, BEFORE
/// the refine stage (the model corrupts spelled runs), and all offsets are
/// CHARACTER offsets into that final — `Array(text)` indices, per
/// `LetterRun.range` / `directiveRange`.
///
/// Correction handling v1 (per the target contract):
///
/// - the directive is always **suppressed** from the inserted text;
/// - `tailReplace` and a same-utterance `retroReplace` are applied to the text
///   before insertion;
/// - `abstain` — the run failed the learn plausibility gate — suppresses the
///   directive, edits nothing, learns nothing, and says so;
/// - a cross-utterance `retroReplace` — the antecedent lives in an EARLIER
///   utterance, already committed to some other app's text field — does not
///   touch that field. It learns the term and flashes "Learned Sharique". The
///   in-field retro-edit needs the Phase-2 input-method tier.
struct CorrectionOutcome: Equatable {
    /// Text to carry into the refine stage.
    var text: String
    /// Persist to the dictionary AFTER insertion, never on the paste path.
    var learn: LearnedTerm?
    /// True when `learn` has not earned a canonical entry yet: the run was
    /// believable but attested exactly once, so it belongs in the dictionary as
    /// `pending: true` via `DictionaryStore.addPending(term:observation:)`,
    /// where a second sighting promotes it. A vocabulary port that predates the
    /// quarantine seam still calls `add` and gets v1 behaviour — the flag is
    /// additive, and ignoring it is the status quo, not a new failure.
    var learnIsPending: Bool
    /// Pill notice to flash after insertion, e.g. "Learned Sharique".
    var notice: String?
    /// True when the antecedent lived in an earlier utterance — the branch that
    /// deliberately declines to edit already-committed text.
    var wasCrossUtterance: Bool

    init(text: String, learn: LearnedTerm? = nil, learnIsPending: Bool = false,
         notice: String? = nil, wasCrossUtterance: Bool = false) {
        self.text = text
        self.learn = learn
        self.learnIsPending = learnIsPending
        self.notice = notice
        self.wasCrossUtterance = wasCrossUtterance
    }
}

enum CorrectionApplier {

    static func apply(_ action: CorrectionAction, to text: String) -> CorrectionOutcome {
        switch action {
        case .none:
            return CorrectionOutcome(text: text)

        case .insertLiterally(let word, let replace, _):
            // Inert by construction: `replace` covers the RUN ONLY. "J-S-O-N"
            // becomes "JSON" in place and nothing else moves. The `offer` is
            // passive UI in a later phase, so v1 does not learn from it —
            // learning a term the matcher had no confidence in is exactly how a
            // dictionary fills up with garbage.
            return CorrectionOutcome(text: splice(text, replace, with: word))

        case .abstain(let suppress, _):
            // The plausibility gate says the ASR misread the letters. There is
            // no replacement to trust and nothing worth learning, so the whole
            // directive goes and the user is told — inserting "SHARHUUE" or
            // promoting it to a canonical term are both worse than saying so.
            return CorrectionOutcome(text: tidy(splice(text, suppress, with: "")),
                                     notice: "Couldn't read that spelling")

        case .tailReplace(let target, let replacement, let suppress, let learn):
            // Antecedent is in THIS utterance and the run is its tail, so the
            // edit only ever touches text that has not been inserted yet.
            var out = splice(text, suppress, with: "")
            out = replaceLastWord(target, with: replacement, in: out) ?? out
            return CorrectionOutcome(text: tidy(out), learn: learn.term,
                                     learnIsPending: learn.isPending)

        case .retroReplace(let target, let replacement, let suppress, let learn):
            // Drop the whole directive (trigger phrase included) either way.
            let stripped = splice(text, suppress, with: "")
            if let edited = replaceLastWord(target, with: replacement, in: stripped) {
                // Same utterance: the antecedent is still in the pending text.
                return CorrectionOutcome(text: tidy(edited), learn: learn.term,
                                         learnIsPending: learn.isPending)
            }
            // Cross-utterance: the wrong word is already in the user's document.
            // Learn it so it never comes back, and say so.
            return CorrectionOutcome(text: tidy(stripped), learn: learn.term,
                                     learnIsPending: learn.isPending,
                                     notice: "Learned \(replacement)",
                                     wasCrossUtterance: true)
        }
    }

    // MARK: - character-offset splicing

    /// Replace `range` (character offsets) with `replacement`. Out-of-bounds
    /// ranges are clamped rather than trapping: a detector/session skew must
    /// never crash a dictation.
    static func splice(_ text: String, _ range: Range<Int>, with replacement: String) -> String {
        let chars = Array(text)
        let lower = min(max(0, range.lowerBound), chars.count)
        let upper = min(max(lower, range.upperBound), chars.count)
        return String(chars[0..<lower]) + replacement + String(chars[upper...])
    }

    /// Replace the LAST whole-word occurrence of `target`, case-insensitively.
    /// Returns nil when the word is not present — which is precisely the signal
    /// that the antecedent lived in an earlier utterance.
    static func replaceLastWord(_ target: String, with replacement: String,
                                in text: String) -> String? {
        guard !target.isEmpty else { return nil }
        let haystack = Array(text)
        let needle = Array(target.lowercased())
        guard haystack.count >= needle.count else { return nil }

        var found: Int?
        var start = haystack.count - needle.count
        while start >= 0 {
            if matchesWord(haystack, needle, at: start) { found = start; break }
            start -= 1
        }
        guard let at = found else { return nil }
        return String(haystack[0..<at]) + replacement + String(haystack[(at + needle.count)...])
    }

    private static func matchesWord(_ haystack: [Character], _ needle: [Character],
                                    at start: Int) -> Bool {
        for offset in 0..<needle.count
        where Character(haystack[start + offset].lowercased()) != needle[offset] {
            return false
        }
        if start > 0, isWordCharacter(haystack[start - 1]) { return false }
        let after = start + needle.count
        if after < haystack.count, isWordCharacter(haystack[after]) { return false }
        return true
    }

    private static func isWordCharacter(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "'" || c == "\u{2019}"
    }

    /// Removing a directive from the middle of a sentence leaves a double space
    /// or a dangling separator. Collapse only what the removal created; the
    /// deterministic postprocess stage does the real tidying afterwards.
    static func tidy(_ text: String) -> String {
        var out = ""
        var lastWasSpace = false
        for c in text {
            let isSpace = c == " " || c == "\t"
            if isSpace && lastWasSpace { continue }
            out.append(c)
            lastWasSpace = isSpace
        }
        // A directive at the tail leaves " ," / " ." behind.
        out = out.replacingOccurrences(of: " ,", with: ",")
        out = out.replacingOccurrences(of: " .", with: ".")
        out = out.trimmingCharacters(in: .whitespacesAndNewlines)
        // "Actually, it's S-H-A-R-I-Q-U-E." suppresses everything but the final
        // stop. What is left carries no words, so it is removal debris, not
        // dictation — inserting a lone "." into the user's document would be a
        // visible bug. (Only ever reached on a correction path.)
        guard out.contains(where: { $0.isLetter || $0.isNumber }) else { return "" }
        return out
    }
}
