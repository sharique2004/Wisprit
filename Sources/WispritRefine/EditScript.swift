import Foundation
import WispritKit

/// The edit-script refine backend's deterministic half
/// (docs/research/hearing-and-corrections.md, corrections A2).
///
/// The full-text backend re-emits the whole utterance, so everything the cage
/// guards against — paraphrase, obedience, summarization, dropped clauses — is
/// REPRESENTABLE and must be caught after the fact. An edit script cannot
/// express any of it: the model may only quote a span and offer a repair, and
/// this applier decides, deterministically, whether each repair is admissible.
/// SpeechAnalyzer already emits cased, punctuated text; re-deriving it was
/// pure paraphrase surface.
///
/// Self-corrections ("Thursday no wait Friday") are deliberately NOT this
/// backend's job: the deterministic `SelfCorrection` resolver owns them,
/// eval-locked, and the `dropped_correction` guard exists precisely because a
/// model eating a cue hands the resolver nothing. The edit vocabulary here is
/// mishears, fillers, and stutters — the three shapes a find→replace pair can
/// express safely.
public struct EditScriptEdit: Sendable, Equatable {
    public var find: String
    public var replace: String

    public init(find: String, replace: String) {
        self.find = find
        self.replace = replace
    }
}

public enum EditScriptApplier {

    /// More than this many edits is the model padding, not repairing.
    public static let maximumEdits = 8
    /// A find longer than this is a rewrite wearing an edit's clothes.
    public static let maximumFindWords = 4
    /// The repair must SOUND like what it replaces — the same calibrated 0.60
    /// the cage's paraphrase guard uses, with the same meaning: below it, the
    /// model is substituting content, not fixing a mishear.
    public static let phoneticFloor = 0.60

    /// Fillers a bare deletion may remove — `PostProcess.fillerWords` plus the
    /// hesitation sounds the locked prompt enumerates. Anything else deleted
    /// is content, and content deletions are dropped.
    public static let deletableFillers: Set<String> = [
        "um", "umm", "uh", "uhh", "uhm", "erm", "hmm",
    ]

    public struct Outcome: Sendable, Equatable {
        public var text: String
        /// Edits that passed every guard and landed.
        public var applied: Int
        /// Edits the guards dropped (silently, by design — a dropped edit
        /// costs nothing; a wrong one costs the user's words).
        public var dropped: Int
    }

    /// Apply the admissible subset of `edits` to `text`, in order, each
    /// against the current state. `isKnownTerm` is the dictionary's voice —
    /// the one evidence source that can admit an arbitrary-looking repair
    /// ("in forge" → "InsForge").
    public static func apply(_ edits: [EditScriptEdit], to text: String,
                             isKnownTerm: (String) -> Bool) -> Outcome {
        var current = text
        var applied = 0
        var dropped = 0
        for edit in edits.prefix(maximumEdits) {
            if applyOne(edit, to: &current, isKnownTerm: isKnownTerm) {
                applied += 1
            } else {
                dropped += 1
            }
        }
        dropped += max(0, edits.count - maximumEdits)
        return Outcome(text: current, applied: applied, dropped: dropped)
    }

    private static func applyOne(_ edit: EditScriptEdit, to text: inout String,
                                 isKnownTerm: (String) -> Bool) -> Bool {
        let find = edit.find.trimmingCharacters(in: .whitespacesAndNewlines)
        let replace = edit.replace.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !find.isEmpty, find != replace else { return false }
        let findWords = words(find)
        guard !findWords.isEmpty, findWords.count <= maximumFindWords else { return false }

        // The anchor: `find` must quote the transcript exactly, on word
        // boundaries (the dictionary applier's hyphen-excluding edges — the
        // "well x-ray"/"WellX-ray" incident generalizes here too). No anchor,
        // no edit: an unanchored repair is the model imagining a transcript.
        guard let range = anchoredRange(of: find, in: text) else { return false }

        guard admissible(findWords: findWords, replace: replace,
                         range: range, in: text, isKnownTerm: isKnownTerm)
        else { return false }

        if replace.isEmpty {
            // Deletion takes one adjacent space with it so "take um the" does
            // not become "take  the".
            var lower = range.lowerBound
            var upper = range.upperBound
            if upper < text.endIndex, text[upper] == " " {
                upper = text.index(after: upper)
            } else if lower > text.startIndex,
                      text[text.index(before: lower)] == " " {
                lower = text.index(before: lower)
            }
            text.replaceSubrange(lower..<upper, with: "")
        } else {
            text.replaceSubrange(range, with: replace)
        }
        return true
    }

    /// The four admissible repair shapes, in the order they are cheapest to
    /// test. Everything else is dropped.
    private static func admissible(findWords: [String], replace: String,
                                   range: Range<String.Index>, in text: String,
                                   isKnownTerm: (String) -> Bool) -> Bool {
        // (a) Deletion: every deleted word is a filler, or the single deleted
        //     word is a stutter (its twin sits immediately beside the span).
        if replace.isEmpty {
            if findWords.allSatisfy({ deletableFillers.contains($0) }) { return true }
            if findWords.count == 1 { return isStutter(findWords[0], around: range, in: text) }
            return false
        }
        // (b) Casing/punctuation-only: the letters agree entirely.
        let findFolded = folded(findWords.joined())
        let replaceFolded = folded(words(replace).joined())
        if !findFolded.isEmpty, findFolded == replaceFolded { return true }
        // (c) The dictionary vouches for the replacement.
        if isKnownTerm(replace) { return true }
        // (d) The repair sounds like the mishear — a genuine recognition fix.
        return PhoneticScorer.score(findWords.joined(separator: " "),
                                    words(replace).joined(separator: " ")) >= phoneticFloor
    }

    /// A single deleted word is a stutter only when the same word (folded)
    /// sits immediately before or after the span — "i i think" → "i think".
    private static func isStutter(_ word: String, around range: Range<String.Index>,
                                  in text: String) -> Bool {
        let target = folded(word)
        let after = text[range.upperBound...].drop { $0 == " " || $0 == "," }
        if folded(String(after.prefix { $0.isLetter || $0 == "'" || $0 == "’" })) == target {
            return true
        }
        let before = text[..<range.lowerBound].reversed().drop { $0 == " " || $0 == "," }
        let previous = String(before.prefix { $0.isLetter || $0 == "'" || $0 == "’" }.reversed())
        return folded(previous) == target
    }

    /// First occurrence of `find` on the dictionary applier's word edges,
    /// whitespace-relaxed exactly like the exact matcher.
    static func anchoredRange(of find: String, in text: String) -> Range<String.Index>? {
        // The model's own spacing is not evidence: collapse runs to one space
        // first, then relax every space to \s+ — the exact matcher's rule.
        let normalized = find.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let escaped = NSRegularExpression.escapedPattern(for: normalized)
            .replacingOccurrences(of: " ", with: "\\s+")
        guard let rx = try? NSRegularExpression(
            pattern: "(?<![\\w-])" + escaped + "(?![\\w-])",
            options: [.caseInsensitive]) else { return nil }
        let whole = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = rx.firstMatch(in: text, options: [], range: whole),
              let range = Range(match.range, in: text) else { return nil }
        return range
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "'" && $0 != "’" && $0 != "-" }
            .map(String.init)
    }

    private static func folded(_ text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }
}
