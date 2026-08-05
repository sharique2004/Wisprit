import Foundation

/// A word from the recent context that the letter run is probably correcting.
public struct Antecedent: Equatable, Sendable {
    /// The token exactly as it was transcribed — this is the ASR's own
    /// misrecognition, which is the only pronunciation evidence available
    /// (there is no system grapheme-to-phoneme API on either platform).
    public let token: String
    public let score: Double
    public let inCurrentUtterance: Bool
    /// Character offsets, current utterance only.
    public let range: Range<Int>?
}

/// Searches backwards for the word a spelled run is correcting.
///
/// Window, scorer and threshold are the measured values from the research: the
/// last ~12 non-stopword tokens, `max(0.6·codeSim + 0.4·JW, 0.9·JW)`, cut at
/// 0.62 (12/14 true misrecognition pairs landed ≥0.65, 8/8 unrelated pairs
/// ≤0.52). Ties go to the most recent token.
public struct AntecedentMatcher {

    public static let threshold = 0.62
    public static let tokenWindow = 12

    /// Function words plus every word the trigger phrases are built from —
    /// without the latter, "Correction" itself wins the match. "hi"/"hey" are
    /// in here because they are short enough to score 0.675 against an
    /// eight-letter run on Jaro-Winkler alone.
    public static let defaultStoplist: Set<String> = [
        "a", "about", "after", "all", "am", "an", "and", "any", "are", "as", "at",
        "back", "be", "because", "been", "before", "but", "by",
        "can", "could", "did", "do", "does", "down",
        "each", "for", "from", "get", "go", "going", "got",
        "had", "has", "have", "he", "her", "here", "hers", "him", "his", "how",
        "if", "in", "into", "is", "it", "its", "it's",
        "just", "like", "me", "more", "most", "much", "my",
        "of", "off", "on", "one", "only", "or", "other", "our", "out", "over", "own",
        "said", "same", "say", "see", "she", "should", "so", "some", "such",
        "than", "that", "the", "their", "them", "then", "there", "these", "they",
        "this", "those", "through", "to", "too", "two",
        "up", "us", "use", "very", "was", "we", "well", "were", "what", "when",
        "where", "which", "while", "who", "why", "will", "with", "would",
        "you", "your", "yours",
        // trigger vocabulary
        "actually", "correct", "correction", "i", "mean", "meant", "no", "not",
        "sorry", "spell", "spelled", "spelling", "that's", "let's",
        // greetings and generic nouns that showed up as false-pair fodder
        "hi", "hey", "hello", "thanks", "thank", "please", "ok", "okay",
        "yes", "yeah", "email", "name", "names", "thing", "things", "word", "words",
        "today", "tomorrow", "yesterday",
    ]

    public let stoplist: Set<String>

    public init(stoplist: Set<String> = AntecedentMatcher.defaultStoplist) {
        self.stoplist = stoplist
    }

    /// - Parameters:
    ///   - word: the collapsed run, e.g. "SHARIQUE". Scoring is case-insensitive.
    ///   - current: the utterance the run was found in.
    ///   - before: character offset of the run; only text left of it is context.
    ///   - previous: the utterance before it, searched first (older).
    public func bestAntecedent(
        for word: String, current: String, before: Int, previous: String = ""
    ) -> Antecedent? {
        let currentChars = Array(current)
        let head = currentChars[0..<min(before, currentChars.count)]
        var tokens = Self.tokenize(Array(previous)[...]).map {
            (text: $0.text, range: Optional<Range<Int>>.none, current: false)
        }
        tokens += Self.tokenize(head).map {
            (text: $0.text, range: Optional($0.range), current: true)
        }
        let considered = tokens
            .filter { !stoplist.contains($0.text.lowercased()) }
            .suffix(Self.tokenWindow)

        var best: Antecedent?
        for token in considered {
            let score = PhoneticScorer.score(token.text, word)
            // >= keeps the LAST of equal scores: recency breaks ties.
            if best == nil || score >= best!.score {
                best = Antecedent(
                    token: token.text, score: score,
                    inCurrentUtterance: token.current, range: token.range)
            }
        }
        guard let candidate = best, candidate.score >= Self.threshold else { return nil }
        return candidate
    }

    // MARK: - Tokenizing

    struct Token {
        let text: String
        let range: Range<Int>
    }

    static func tokenize(_ chars: ArraySlice<Character>) -> [Token] {
        var tokens: [Token] = []
        var start: Int?
        for index in chars.indices {
            let isWord = chars[index].isLetter || chars[index] == "'" || chars[index] == "\u{2019}"
            if isWord {
                if start == nil { start = index }
            } else if let from = start {
                append(&tokens, chars, from..<index)
                start = nil
            }
        }
        if let from = start { append(&tokens, chars, from..<chars.endIndex) }
        return tokens
    }

    private static func append(
        _ tokens: inout [Token], _ chars: ArraySlice<Character>, _ range: Range<Int>
    ) {
        // Apostrophes are kept inside a token ("it's") but trimmed at the edges.
        var lower = range.lowerBound, upper = range.upperBound
        while lower < upper && !chars[lower].isLetter { lower += 1 }
        while upper > lower && !chars[upper - 1].isLetter { upper -= 1 }
        guard lower < upper else { return }
        tokens.append(Token(text: String(chars[lower..<upper]), range: lower..<upper))
    }
}
