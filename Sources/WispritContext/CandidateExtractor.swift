import Foundation
import WispritCorrections

/// One biasing candidate, ranked. `weight` is 1.0 at the cursor and decays
/// with distance (plus a small in-window frequency bonus) — the shape the
/// vocabulary channel can consume directly or ignore, since the ARRAY order is
/// already the ranking.
public struct ContextCandidate: Equatable, Sendable {
    public var term: String
    public var weight: Double

    public init(term: String, weight: Double) {
        self.term = term
        self.weight = weight
    }
}

/// Deterministic proper-noun/term extraction from a context window. This is
/// Wisprit's answer to Wispr Flow's `/llm/extract_asr_words` — except pure,
/// local, and sub-millisecond, because FoundationModels measured 759–2325 ms
/// elsewhere in this codebase and also serializes system-wide against the
/// on-path refine. No model, no IO, no state.
///
/// The NEGATIVE spec is as load-bearing as the positive one: Wispr's auto-add
/// over-added common words ("sprint", "deploy") until they bolted plausibility
/// rules on after the fact. Here the `Lexicon` filter and the
/// `LearnPlausibility` orthographic faults are in the acceptance path from day
/// one, and emails, URLs, and long digit runs can never become biasing terms.
///
/// Candidates feed `VocabularyChannel`-style `contextualStrings` biasing for
/// the CURRENT utterance only; `EditObservationGate` reuses the same
/// acceptance rules so "worth biasing toward" and "worth learning" stay one
/// definition.
public enum CandidateExtractor {

    /// Mirrors `ContextInfo.extractorVersion` for callers stamping metrics.
    public static var version: Int { ContextInfo.extractorVersion }

    // MARK: - Calibration

    public static let defaultMaxTerms = 24
    /// Shorter than this and a plain word is noise ("ok", "hm"). Letter-digit
    /// mixes are exempt down to 2 — "Q3", "M4", "v2" are exactly the terms the
    /// window is read for.
    public static let minLength = 3
    /// Longer than this is a paste accident or a secret, never a name.
    public static let maxLength = 40
    /// A run of this many digits inside one token is an ID, a phone number, or
    /// a secret. Hard reject — never biased toward, never learned.
    public static let maxDigitRun = 5
    /// ALLCAPS tokens outside this band are single letters or shouting.
    public static let allCapsLength = 2...8

    /// ALLCAPS strings that are ordinary writing, not vocabulary: initialisms
    /// everyone's ASR already knows plus email/chat shorthand. Lexicon lookup
    /// already catches shouted common words ("NEVER"); this catches the
    /// acronyms the dictionary file does not spell.
    public static let allCapsStoplist: Set<String> = [
        "AI", "AM", "API", "ASAP", "BCC", "BTW", "CC", "CEO", "CFO", "COO",
        "CSS", "CTO", "DIY", "EOD", "ETA", "EU", "FAQ", "FYI", "GIF", "GPU",
        "HR", "HTML", "HTTP", "HTTPS", "ID", "IMHO", "IMO", "IT", "JPEG",
        "JPG", "JSON", "LOL", "ML", "NASA", "OK", "OMG", "OS", "PDF", "PIN",
        "PM", "PNG", "PR", "PS", "QA", "RAM", "RSVP", "SQL", "TBD", "TBH",
        "TLDR", "TODO", "TV", "UI", "UK", "URL", "US", "USA", "USB", "UX",
        "VP", "WIFI", "XML",
    ]

    /// A dotted token ending in one of these is a bare domain — URL-adjacent,
    /// so rejected even without a scheme. Deliberately short: it only has to
    /// catch domains, not name every TLD.
    static let urlTLDs: Set<String> = [
        "ai", "app", "co", "com", "dev", "edu", "gov", "info", "io", "me",
        "mil", "net", "org", "uk", "us", "xyz",
    ]

    // MARK: - Extraction

    /// Rank order: nearest-to-cursor first, then in-window frequency, then
    /// text position, then the term itself — a total order, so the result is
    /// bit-identical across runs. Duplicate surface forms dedupe
    /// case-insensitively; the first-seen casing wins.
    public static func candidates(in snapshot: ContextSnapshot,
                                  lexicon: any Lexicon,
                                  maxTerms: Int = defaultMaxTerms) -> [ContextCandidate] {
        guard maxTerms > 0 else { return [] }
        let window = snapshot.before + snapshot.selected + snapshot.after
        let cursorLower = snapshot.before.count
        let cursorUpper = cursorLower + snapshot.selected.count

        struct Entry {
            var term: String
            var bestDistance: Int
            var count: Int
            var firstPosition: Int
        }
        var entries: [String: Entry] = [:]

        for token in ContextTokenizer.tokens(in: window) {
            guard let term = canonicalTerm(for: token.text,
                                           sentenceInitial: token.sentenceInitial,
                                           lexicon: lexicon) else { continue }
            let distance: Int
            if token.range.upperBound <= cursorLower {
                distance = cursorLower - token.range.upperBound
            } else if token.range.lowerBound >= cursorUpper {
                distance = token.range.lowerBound - cursorUpper
            } else {
                distance = 0
            }
            let key = term.lowercased()
            if var entry = entries[key] {
                entry.count += 1
                entry.bestDistance = min(entry.bestDistance, distance)
                entries[key] = entry
            } else {
                entries[key] = Entry(term: term, bestDistance: distance, count: 1,
                                     firstPosition: token.range.lowerBound)
            }
        }

        let ranked = entries.values.sorted {
            if $0.bestDistance != $1.bestDistance { return $0.bestDistance < $1.bestDistance }
            if $0.count != $1.count { return $0.count > $1.count }
            if $0.firstPosition != $1.firstPosition { return $0.firstPosition < $1.firstPosition }
            return $0.term < $1.term
        }
        return ranked.prefix(maxTerms).map { entry in
            let proximity = 1.0 / (1.0 + Double(entry.bestDistance) / 100.0)
            let bonus = 0.1 * Double(min(entry.count, 4) - 1)
            return ContextCandidate(term: entry.term, weight: min(1.0, proximity + bonus))
        }
    }

    /// The acceptance rules alone, for a single token with no positional
    /// context — how `EditObservationGate` asks "is the user's replacement a
    /// believable term?". Sentence position does not apply to a typed
    /// correction, so capitalized words get the benefit of the doubt.
    public static func acceptsTerm(_ token: String, lexicon: any Lexicon) -> Bool {
        guard !token.isEmpty, !token.contains(where: \.isWhitespace) else { return false }
        return canonicalTerm(for: token, sentenceInitial: false, lexicon: lexicon) != nil
    }

    // MARK: - Acceptance

    /// nil, or the term to keep (possessive suffix stripped, casing intact).
    static func canonicalTerm(for raw: String, sentenceInitial: Bool,
                              lexicon: any Lexicon) -> String? {
        var term = raw
        for suffix in ["'s", "\u{2019}s"] where term.hasSuffix(suffix) {
            term = String(term.dropLast(2))
            break
        }

        // Emails and URLs never become biasing terms, whatever their shape.
        // The tokenizer already skips whole chunks containing them; this
        // repeats the check for direct `acceptsTerm` callers.
        let lower = term.lowercased()
        guard !lower.contains("@"), !lower.contains(":"), !lower.contains("/"),
              !lower.hasPrefix("www.") else { return nil }

        // Shape checks run on the apostrophe-folded form ("O'Brien" → "OBrien")
        // but the RETURNED term keeps the original characters.
        let folded = term.filter { $0 != "'" && $0 != "\u{2019}" }
        let chars = Array(folded)
        guard chars.count >= 2, chars.count <= maxLength else { return nil }
        guard chars.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-" })
        else { return nil }

        var digitRun = 0
        for char in chars {
            digitRun = char.isNumber ? digitRun + 1 : 0
            if digitRun > maxDigitRun { return nil }
        }

        let letters = chars.filter(\.isLetter)
        guard !letters.isEmpty else { return nil }                       // pure digits, dates, phones
        guard letters.contains(where: \.isASCII) else { return nil }     // non-Latin noise
        guard !lexicon.contains(String(chars).lowercased()) else { return nil }  // the sprint/deploy fix

        if chars.contains(where: { $0 == "." || $0 == "_" || $0 == "-" }) {
            return connectorTerm(term, folded: folded, lexicon: lexicon)
        }
        if chars.contains(where: \.isNumber) {
            return term  // letter-digit mix: Q3, M4, v2, sha256 — shape IS the evidence
        }

        let upperCount = chars.filter(\.isUppercase).count
        if upperCount == chars.count {
            return allCapsTerm(term, folded: folded)
        }
        guard chars.count >= minLength else { return nil }
        if chars.dropFirst().contains(where: \.isUppercase), upperCount < chars.count {
            return term  // interior capitals: InsForge, SpeechAnalyzer, iPhone
        }
        if let first = chars.first, first.isUppercase, upperCount == 1 {
            // Capitalized ordinary-shaped word. Position has to argue for it
            // (sentence-initial capitalization proves nothing) and the spelled
            // run plausibility rules gate out Sharhuue-class ASR junk — the
            // same classifier the learn loop uses, so "believable name" stays
            // one definition across the whole product.
            guard !sentenceInitial else { return nil }
            switch LearnPlausibility.classify(collapsed: folded, antecedent: "", candidates: []) {
            case .quarantine: return term
            case .merge, .reject: return nil
            }
        }
        return nil  // plain lowercase / mixed junk: no shape evidence at all
    }

    /// snake_case, kebab-case, dotted.identifiers. Code identifiers are
    /// accepted on shape; ordinary hyphenated English ("well-known") and bare
    /// domains ("wisprflow.ai") are not.
    private static func connectorTerm(_ term: String, folded: String,
                                      lexicon: any Lexicon) -> String? {
        let chars = Array(folded)
        guard chars.count >= minLength else { return nil }
        guard let first = chars.first, let last = chars.last,
              first.isLetter || first.isNumber, last.isLetter || last.isNumber
        else { return nil }
        let segments = folded.split(omittingEmptySubsequences: false,
                                    whereSeparator: { $0 == "." || $0 == "_" || $0 == "-" })
        // "e.g", "x-ray", doubled connectors: single-character (or empty)
        // segments make an abbreviation, not an identifier.
        guard segments.allSatisfy({ $0.count >= 2 }) else { return nil }
        if folded.contains("."), let tail = segments.last,
           urlTLDs.contains(tail.lowercased()) {
            return nil  // bare domain — URL by another spelling
        }
        if folded.contains("-"), !folded.contains("_"), !folded.contains("."),
           segments.allSatisfy({ lexicon.contains($0.lowercased()) }) {
            return nil  // "well-known": hyphenated prose, not an identifier
        }
        return term
    }

    /// ALLCAPS 2–8 letters. The plausibility faults apply EXCEPT no-vowel:
    /// initialisms are read out letter by letter ("MLX", "TDT") and are
    /// exactly the biasing candidates the window is for, whereas "AAAA" and
    /// "SHARHUUE" remain the junk the faults exist to stop.
    private static func allCapsTerm(_ term: String, folded: String) -> String? {
        guard allCapsLength.contains(folded.count) else { return nil }
        guard !allCapsStoplist.contains(folded.uppercased()) else { return nil }
        switch LearnPlausibility.classify(collapsed: folded, antecedent: "", candidates: []) {
        case .quarantine, .merge:
            return term
        case .reject(let reason):
            return reason == .noVowel ? term : nil
        }
    }
}

// MARK: - Tokenizing

/// Shared tokenizer for the extractor and the edit-observation gate.
///
/// Two layers: whitespace-separated CHUNKS first — a chunk containing "@",
/// "://", or a "www." prefix is skipped whole, so no fragment of an email or
/// URL ever reaches classification — then word tokens inside surviving
/// chunks. `.`/`_`/`-` join a token only between two word characters (so
/// "snake_case_name" and "config.yaml" survive but a trailing period does
/// not); apostrophes ride inside and are trimmed at the edges, matching
/// `AntecedentMatcher`. Ranges are grapheme indices into `Array(text)`.
enum ContextTokenizer {

    struct Token: Equatable {
        let text: String
        let range: Range<Int>
        /// True when the previous non-space character ends a sentence — or
        /// when the window simply starts here, where conservatism says assume
        /// a boundary rather than mint a candidate from "The".
        let sentenceInitial: Bool
    }

    static func tokens(in text: String) -> [Token] {
        let chars = Array(text)
        var tokens: [Token] = []
        var index = 0
        while index < chars.count {
            if chars[index].isWhitespace {
                index += 1
                continue
            }
            let chunkStart = index
            while index < chars.count, !chars[index].isWhitespace { index += 1 }
            let chunk = String(chars[chunkStart..<index]).lowercased()
            if chunk.contains("@") || chunk.contains("://") || chunk.hasPrefix("www.") {
                continue  // emails/URLs: skipped whole, never mined for parts
            }
            appendWordTokens(in: chunkStart..<index, chars: chars, into: &tokens)
        }
        return tokens
    }

    private static func appendWordTokens(in range: Range<Int>, chars: [Character],
                                         into tokens: inout [Token]) {
        var start: Int?

        func isAlnum(_ char: Character) -> Bool { char.isLetter || char.isNumber }

        func flush(upTo end: Int) {
            guard let from = start else { return }
            start = nil
            var lower = from, upper = end
            while lower < upper, !isAlnum(chars[lower]) { lower += 1 }
            while upper > lower, !isAlnum(chars[upper - 1]) { upper -= 1 }
            guard lower < upper else { return }
            tokens.append(Token(text: String(chars[lower..<upper]),
                                range: lower..<upper,
                                sentenceInitial: isSentenceInitial(at: lower, chars: chars)))
        }

        for index in range {
            let char = chars[index]
            let apostrophe = char == "'" || char == "\u{2019}"
            let connector = char == "." || char == "_" || char == "-"
            let joins = connector && index > range.lowerBound && index + 1 < range.upperBound
                && isAlnum(chars[index - 1]) && isAlnum(chars[index + 1])
            if isAlnum(char) || apostrophe || joins {
                if start == nil { start = index }
            } else {
                flush(upTo: index)
            }
        }
        flush(upTo: range.upperBound)
    }

    /// Quotes, brackets, and bullet marks are transparent; a newline is a
    /// boundary (lists, chat) even though it is also whitespace.
    private static func isSentenceInitial(at index: Int, chars: [Character]) -> Bool {
        let transparent: Set<Character> = [
            "\"", "'", "\u{2018}", "\u{2019}", "\u{201C}", "\u{201D}",
            "(", "[", "{", "*", "\u{2022}", ">", "#", "-", "\u{2013}", "\u{2014}",
        ]
        var i = index - 1
        while i >= 0 {
            let char = chars[i]
            if char == "\n" || char == "\r" { return true }
            if char.isWhitespace || transparent.contains(char) {
                i -= 1
                continue
            }
            return char == "." || char == "!" || char == "?" || char == "\u{2026}"
        }
        return true  // window starts mid-text: unknown context, assume boundary
    }
}
