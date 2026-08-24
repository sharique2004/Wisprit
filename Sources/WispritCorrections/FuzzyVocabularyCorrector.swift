import Foundation
import WispritKit

/// The fuzzy layer over the exact dictionary pass
/// (docs/research/hearing-and-corrections.md, corrections A1).
///
/// `DictionaryStore.applyCorrections` is exact by design: word-boundary,
/// case-insensitive, whitespace-relaxed — and therefore brittle to exactly the
/// drift a recognizer produces. An inflection ("Shariqs"), a pluralized
/// re-spacing ("in forges"), a phonetic garble with no recorded hear phrase
/// ("Shreek") all sail past it. This decorator runs the exact pass first,
/// byte-identical, then fills only the spans it left alone.
///
/// Conservatism is the design, borrowed piece by piece from systems already in
/// production here:
///  * substitution only — never insert, never delete (`VocabularyReconciler`'s
///    structural rule);
///  * the ordinary-word veto — "shark" codes identically to "Sharique"
///    (Double Metaphone XRK) and clears every phonetic bar; only the lexicon
///    stops the marine biology notes from being renamed (the ALIX/WellX
///    incident, generalized);
///  * the orthographic guard on the phonetic tier — sounding alike argues FOR
///    a rewrite, only the letters make one safe (`LearnPlausibility`);
///  * ambiguity refusal — two terms over the floor is a refusal, not a coin
///    flip (`VocabularyReconciler.ambiguousTerm`);
///  * idempotence — the live-partial path re-runs the whole layer on every
///    partial, so `apply(apply(x)) == apply(x)` is a hard requirement. It
///    falls out structurally: every replacement is a canonical term, and
///    canonical terms (and each word of a multi-word term) are vetoed as
///    candidates.
public final class FuzzyVocabularyCorrector: CorrectionApplying, @unchecked Sendable {

    /// One dictionary entry, as the fuzzy pass needs it. Built from
    /// `DictionaryStore.learnedEntries()` (non-pending only) at the wiring.
    public struct Entry: Sendable, Equatable {
        public var term: String
        public var hears: [String]

        public init(term: String, hears: [String]) {
            self.term = term
            self.hears = hears
        }
    }

    /// Tier-1 floor: a token/window against a RECORDED hear phrase. Two ways
    /// in, either suffices — Jaro-Winkler favors shared prefixes (inflections),
    /// the Levenshtein bound catches short edits anywhere.
    public static let hearJaroWinklerFloor = 0.90
    public static let hearLevenshteinCeiling = 0.2
    /// Tier-2 floor: a token against the TERM itself, no hear evidence.
    /// Deliberately far above the 0.62 the off-path antecedent matcher uses:
    /// this path applies silently, on-path, before the user sees anything.
    public static let phoneticFloor = 0.85
    /// The letters' own veto on tier 2 — `LearnPlausibility.orthographicFloor`
    /// semantics, same matching-initial escape.
    public static let orthographicFloor = 0.5
    /// Single-token candidates shorter than this are noise ("Io", "ok").
    public static let minimumTokenLength = 3
    /// Past this the fuzzy pass stands down (the exact pass still runs): the
    /// live-partial path re-runs from scratch about once a second and its own
    /// budget is 2000 characters.
    public static let characterBudget = 2000

    private let base: any CorrectionApplying
    private let entries: @Sendable () -> [Entry]
    private let isKnownTerm: @Sendable (String) -> Bool
    private let isOrdinaryWord: @Sendable (String) -> Bool
    private let log = WLog.logger("corrections.fuzzy")

    public init(base: any CorrectionApplying,
                entries: @escaping @Sendable () -> [Entry],
                isKnownTerm: @escaping @Sendable (String) -> Bool,
                isOrdinaryWord: @escaping @Sendable (String) -> Bool) {
        self.base = base
        self.entries = entries
        self.isKnownTerm = isKnownTerm
        self.isOrdinaryWord = isOrdinaryWord
    }

    public func applyCorrections(to text: String) -> String {
        let exact = base.applyCorrections(to: text)
        guard exact.count <= Self.characterBudget else { return exact }
        let compiled = Self.compile(entries())
        guard !compiled.entries.isEmpty else { return exact }
        return fuzzyPass(exact, compiled)
    }

    // MARK: - compiled dictionary snapshot

    private struct Compiled {
        var entries: [CompiledEntry]
        /// Every word of every canonical term, lowercased — the idempotence
        /// fence: output words are never candidates.
        var termWords: Set<String>
    }

    private struct CompiledEntry {
        var term: String
        var termLower: String
        var termSqueezed: String
        /// Lowercased hear phrases, bucketed by word count.
        var hears: [Int: [String]]
    }

    private static func compile(_ entries: [Entry]) -> Compiled {
        var compiled: [CompiledEntry] = []
        var words: Set<String> = []
        for entry in entries {
            let lower = entry.term.lowercased()
            words.formUnion(lower.split(separator: " ").map(String.init))
            var hears: [Int: [String]] = [:]
            for hear in entry.hears {
                let phrase = hear.lowercased()
                    .split(whereSeparator: \.isWhitespace).joined(separator: " ")
                guard !phrase.isEmpty else { continue }
                let count = phrase.split(separator: " ").count
                hears[count, default: []].append(phrase)
            }
            compiled.append(CompiledEntry(term: entry.term, termLower: lower,
                                          termSqueezed: lower.replacingOccurrences(of: " ", with: ""),
                                          hears: hears))
        }
        return Compiled(entries: compiled, termWords: words)
    }

    // MARK: - the pass

    struct Token {
        var text: String
        var lower: String
        var range: Range<String.Index>
        var hasDigit: Bool
        /// Touching `@ / : . _` on either side the way a URL, an email, or a
        /// path does — never a candidate.
        var embedded: Bool
    }

    private func fuzzyPass(_ text: String, _ compiled: Compiled) -> String {
        let tokens = Self.tokenize(text)
        guard !tokens.isEmpty else { return text }

        var claimed = [Bool](repeating: false, count: tokens.count)
        var edits: [(tokens: Range<Int>, replacement: String)] = []

        // Windows first, longest first: multi-word evidence outranks a
        // token-level guess, and a claimed token is settled.
        for size in [3, 2] where tokens.count >= size {
            for start in 0...(tokens.count - size) {
                let window = start..<(start + size)
                guard !window.contains(where: { claimed[$0] }) else { continue }
                let slice = tokens[window]
                guard !slice.contains(where: { $0.hasDigit || $0.embedded }) else { continue }
                let joined = slice.map(\.lower).joined(separator: " ")
                guard let term = matchAgainstHears(joined, wordCount: size, compiled) else { continue }
                for i in window { claimed[i] = true }
                edits.append((window, term))
            }
        }

        for i in tokens.indices where !claimed[i] {
            let token = tokens[i]
            guard !token.hasDigit, !token.embedded,
                  token.lower.count >= Self.minimumTokenLength,
                  !isOrdinaryWord(token.lower),
                  !isKnownTerm(token.lower),
                  !compiled.termWords.contains(token.lower)
            else { continue }
            guard let term = matchSingle(token.lower, compiled) else { continue }
            claimed[i] = true
            edits.append((i..<(i + 1), term))
        }

        guard !edits.isEmpty else { return text }
        var result = text
        for edit in edits.sorted(by: { $0.tokens.lowerBound > $1.tokens.lowerBound }) {
            let from = tokens[edit.tokens.lowerBound].range.lowerBound
            let upTo = tokens[edit.tokens.upperBound - 1].range.upperBound
            log.info("fuzzy correction: \"\(result[from..<upTo], privacy: .private)\" → \(edit.replacement, privacy: .private)")
            result.replaceSubrange(from..<upTo, with: edit.replacement)
        }
        return result
    }

    /// Tier 1 only for windows: a multi-word span is a candidate solely on the
    /// strength of a RECORDED mishear of the same word count. No phonetic tier
    /// here — its floor is not calibrated for phrases, and windows made of
    /// ordinary words ("in forges") are exactly what hear evidence licenses.
    private func matchAgainstHears(_ span: String, wordCount: Int, _ compiled: Compiled) -> String? {
        var matched: String?
        for entry in compiled.entries {
            guard span != entry.termLower else { return nil }   // already canonical
            guard let hears = entry.hears[wordCount] else { continue }
            let hit = hears.contains { hear in
                guard abs(hear.count - span.count) <= max(2, hear.count * 2 / 5) else { return false }
                return StringMetrics.jaroWinkler(span, hear) >= Self.hearJaroWinklerFloor
                    || StringMetrics.normalizedLevenshtein(span, hear) <= Self.hearLevenshteinCeiling
            }
            guard hit else { continue }
            guard matched == nil || matched == entry.term else { return nil }  // ambiguous
            matched = entry.term
        }
        return matched
    }

    /// Single tokens: tier 1 (hear near-miss) or tier 2 (phonetic + the
    /// orthographic guard). Matches from BOTH tiers pool into one ambiguity
    /// decision — a tier-1 hit for one term and a tier-2 hit for another is a
    /// refusal, not a priority contest.
    private func matchSingle(_ token: String, _ compiled: Compiled) -> String? {
        var matched: String?
        for entry in compiled.entries {
            var hit = false
            if let hears = entry.hears[1] {
                hit = hears.contains { hear in
                    guard abs(hear.count - token.count) <= max(2, hear.count * 2 / 5) else { return false }
                    return StringMetrics.jaroWinkler(token, hear) >= Self.hearJaroWinklerFloor
                        || StringMetrics.normalizedLevenshtein(token, hear) <= Self.hearLevenshteinCeiling
                }
            }
            if !hit,
               abs(entry.termSqueezed.count - token.count) <= max(2, entry.termSqueezed.count * 2 / 5),
               PhoneticScorer.score(token, entry.term) >= Self.phoneticFloor {
                let similarity = 1 - StringMetrics.normalizedLevenshtein(token, entry.termSqueezed)
                hit = similarity >= Self.orthographicFloor
                    || token.first == entry.termSqueezed.first
            }
            guard hit else { continue }
            guard matched == nil || matched == entry.term else { return nil }  // ambiguous
            matched = entry.term
        }
        return matched
    }

    // MARK: - tokenization

    private static let compoundNeighbors: Set<Character> = ["@", "/", ":", "_"]

    static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var index = text.startIndex
        while index < text.endIndex {
            guard text[index].isLetter || text[index].isNumber else {
                index = text.index(after: index)
                continue
            }
            let start = index
            var hasDigit = false
            while index < text.endIndex {
                let c = text[index]
                if c.isLetter || c.isNumber || c == "'" || c == "’" || c == "-" {
                    if c.isNumber { hasDigit = true }
                    index = text.index(after: index)
                } else { break }
            }
            let range = start..<index
            let word = String(text[range])
            tokens.append(Token(text: word, lower: word.lowercased(), range: range,
                                hasDigit: hasDigit,
                                embedded: isEmbedded(text, range)))
        }
        return tokens
    }

    /// Part of a URL, email, or path-like compound: the character touching the
    /// token is `@ / : _`, or a `.` that glues it to more alphanumerics
    /// ("shariq.dev"). A sentence-final period does not count — nothing
    /// alphanumeric follows it.
    private static func isEmbedded(_ text: String, _ range: Range<String.Index>) -> Bool {
        if range.lowerBound > text.startIndex {
            let before = text[text.index(before: range.lowerBound)]
            if compoundNeighbors.contains(before) || before == "." { return true }
        }
        if range.upperBound < text.endIndex {
            let after = text[range.upperBound]
            if compoundNeighbors.contains(after) { return true }
            if after == "." {
                let next = text.index(after: range.upperBound)
                if next < text.endIndex, text[next].isLetter || text[next].isNumber { return true }
            }
        }
        return false
    }
}
