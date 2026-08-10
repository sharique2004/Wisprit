import Foundation

/// How much of the surface form a comparison is allowed to see. Every metric in
/// `Score` names one of these, so a number is never ambiguous about what it
/// forgave.
public enum NormalizeProfile: String, Sendable, CaseIterable {
    /// Formatting-blind — scores the acoustic model and nothing else. Case,
    /// punctuation, hyphenation, digit-vs-word and a handful of pinned spelling
    /// variants are all erased, so a WER computed here moves only when the
    /// engine actually heard a different word.
    case asr
    /// Formatting-sensitive — case and punctuation are part of the answer. This
    /// is what CER runs over and what the post-process stages are judged by.
    case rendered
    /// Zero-edit equality — the only tolerance is whitespace and a trailing
    /// sentence mark, because that is the edit a user makes without noticing.
    case light
}

/// The three tokenizers. Pure `String -> [String]`, no state, no locale.
///
/// The `.asr` chain is a promotion of `docs/research/probes/fc_acc.swift:23`
/// (the probe that produced the first ST-vs-DT WER numbers) — keep the
/// keep-set (letter | digit | space | apostrophe) identical to it, because the
/// probe's numbers are quoted in the research notes and must stay reproducible.
/// Everything after the keep-set is new, and each addition is an *explicit
/// table*: nothing is normalized unless it is enumerated here.
public enum Normalize {

    // MARK: - entry points

    public static func tokens(_ text: String, profile: NormalizeProfile) -> [String] {
        switch profile {
        case .asr: return asrTokens(text)
        case .rendered: return renderedTokens(text)
        case .light: return lightTokens(text)
        }
    }

    /// Tokens rejoined with single spaces — the string form the character-level
    /// metrics compare.
    public static func normalized(_ text: String, profile: NormalizeProfile) -> String {
        tokens(text, profile: profile).joined(separator: " ")
    }

    // MARK: - .asr

    static func asrTokens(_ text: String) -> [String] {
        // NFKC first: it folds the compatibility forms an ASR or a TTS script
        // can emit (fullwidth digits, ligatures, U+2026 -> "...").
        var s = text.precomposedStringWithCompatibilityMapping
        s = fold(s)
        s = s.lowercased()   // ICU root case mapping — `lowercased()` is deliberately
                             // NOT `lowercased(with:)`, so a Turkish locale cannot
                             // turn "I" into "ı" and move a number.
        s = symbolITN(s)
        s = String(s.map { ch in
            (ch.isLetter || ch.isNumber || ch == " " || ch == "'") ? ch : " "
        })
        var out = s.split(separator: " ").map(String.init)
        out = collapseLetterRuns(out)
        out = rewritePhrases(out)
        return out
    }

    /// Curly quotes to ASCII; en dash, em dash and ellipsis to space. The
    /// ellipsis entry is belt-and-braces — NFKC already expanded it to three
    /// dots, which the keep-set turns into spaces anyway — but it is listed so
    /// the rule reads the way it is specified.
    static func fold(_ text: String) -> String {
        String(text.map { ch -> Character in
            if let ascii = quoteFolds[ch] { return ascii }
            if spaceFolds.contains(ch) { return " " }
            return ch
        })
    }

    static let quoteFolds: [Character: Character] = [
        "\u{2018}": "'", "\u{2019}": "'", "\u{201A}": "'", "\u{201B}": "'", "\u{2032}": "'",
        "\u{201C}": "\"", "\u{201D}": "\"", "\u{201E}": "\"", "\u{201F}": "\"", "\u{2033}": "\"",
    ]
    static let spaceFolds: Set<Character> = ["\u{2013}", "\u{2014}", "\u{2026}"]

    /// Inverse text normalization for the three symbols the keep-set would
    /// otherwise destroy silently. Runs before the keep-set, on both ref and
    /// hyp, so "$5" and "five dollars" land on the same tokens.
    static func symbolITN(_ text: String) -> String {
        var s = text
        // "$1,200.50" -> "1,200.50 dollars" (the separators die in the keep-set).
        s = replaceAll(currency, in: s, with: "$1 dollars")
        // Any percent sign is the word, wherever it sits.
        s = s.replacingOccurrences(of: "%", with: " percent ")
        // Clock times: "3:15" -> "3 15". The keep-set would produce the same two
        // tokens on its own; the rule is explicit so the intent is not incidental.
        s = replaceAll(clock, in: s, with: "$1 $2")
        return s
    }

    static let currency = regex(#"\$\s*([0-9][0-9,]*(?:\.[0-9]+)?)"#)
    static let clock = regex(#"\b([0-9]{1,2}):([0-9]{2})\b"#)

    /// Spelled runs arrive from the engine as separate one-letter tokens
    /// ("j s o n"); joining any run of two or more makes them comparable with
    /// the glued form. Digits are deliberately excluded — "3 15" is a clock
    /// time, not a run.
    ///
    /// Known cost: "a" and "i" are real words, so "did i a b test" collapses to
    /// "did iab test". Accepted, because the collapse is applied to ref and hyp
    /// alike and therefore cannot invent an error; it can only hide one.
    static func collapseLetterRuns(_ tokens: [String]) -> [String] {
        var out: [String] = []
        var run: [String] = []
        func flush() {
            if run.count >= 2 { out.append(run.joined()) } else { out.append(contentsOf: run) }
            run.removeAll()
        }
        for token in tokens {
            if token.count == 1, token.first?.isLetter == true {
                run.append(token)
            } else {
                flush()
                out.append(token)
            }
        }
        flush()
        return out
    }

    /// Greedy longest-match rewrite over the enumerated tables. A phrase that is
    /// not in a table is left exactly as it was — there is no number *parser*
    /// and no fuzzy variant matching here, on purpose.
    static func rewritePhrases(_ tokens: [String]) -> [String] {
        var out: [String] = []
        var i = 0
        while i < tokens.count {
            var matched = false
            var span = min(maxPhraseTokens, tokens.count - i)
            while span >= 1 {
                let phrase = tokens[i..<(i + span)].joined(separator: " ")
                if let replacement = phraseTable[phrase] {
                    out.append(contentsOf: replacement.split(separator: " ").map(String.init))
                    i += span
                    matched = true
                    break
                }
                span -= 1
            }
            if !matched {
                out.append(tokens[i])
                i += 1
            }
        }
        return out
    }

    // MARK: - the explicit tables

    /// Spelled numbers and ordinals, canonicalized toward the DIGIT form
    /// (compact, and it collapses a multi-token number phrase to one token on
    /// both sides). Enumerated, not parsed: 0…999 cardinals and 1st…31st
    /// ordinals, exactly the range a dictation corpus needs.
    ///
    /// Known collision: "second" maps to "2nd", so "wait a second" reads as
    /// "wait a 2nd". Harmless — both ref and hyp get it — and the alternative
    /// (dropping the ordinal) would leave "2nd" and "second" scoring as an error.
    public static let itnTable: [String: String] = {
        var table: [String: String] = [:]
        for n in 0...999 { table[cardinalWords(n)] = String(n) }
        for n in 1...31 { table[ordinalWords(n)] = digitOrdinal(n) }
        return table
    }()

    /// Spellings the pipeline treats as the same word. Four pairs, and only
    /// four: every entry here is a decision to stop measuring something.
    public static let variantTable: [String: String] = [
        "okay": "ok",
        "e mail": "email",
        "git hub": "github",
        "postgresql": "postgres",
    ]

    static let phraseTable: [String: String] = itnTable.merging(variantTable) { _, variant in variant }
    /// "nine hundred ninety nine" — the longest phrase in either table.
    static let maxPhraseTokens = 4

    static let cardinalOnes = ["zero", "one", "two", "three", "four", "five", "six", "seven",
                               "eight", "nine", "ten", "eleven", "twelve", "thirteen", "fourteen",
                               "fifteen", "sixteen", "seventeen", "eighteen", "nineteen"]
    static let cardinalTens = ["", "", "twenty", "thirty", "forty", "fifty",
                               "sixty", "seventy", "eighty", "ninety"]

    static func cardinalWords(_ n: Int) -> String {
        if n < 20 { return cardinalOnes[n] }
        if n < 100 {
            let tens = cardinalTens[n / 10]
            return n % 10 == 0 ? tens : tens + " " + cardinalOnes[n % 10]
        }
        let hundreds = cardinalOnes[n / 100] + " hundred"
        return n % 100 == 0 ? hundreds : hundreds + " " + cardinalWords(n % 100)
    }

    static let ordinalOnes = ["", "first", "second", "third", "fourth", "fifth", "sixth",
                              "seventh", "eighth", "ninth", "tenth", "eleventh", "twelfth",
                              "thirteenth", "fourteenth", "fifteenth", "sixteenth",
                              "seventeenth", "eighteenth", "nineteenth"]

    static func ordinalWords(_ n: Int) -> String {
        if n < 20 { return ordinalOnes[n] }
        if n == 20 { return "twentieth" }
        if n == 30 { return "thirtieth" }
        return cardinalTens[n / 10] + " " + ordinalOnes[n % 10]
    }

    static func digitOrdinal(_ n: Int) -> String {
        let suffix: String
        switch (n % 100, n % 10) {
        case (11, _), (12, _), (13, _): suffix = "th"
        case (_, 1): suffix = "st"
        case (_, 2): suffix = "nd"
        case (_, 3): suffix = "rd"
        default: suffix = "th"
        }
        return "\(n)\(suffix)"
    }

    // MARK: - .rendered

    /// NFKC, quote folding, whitespace collapse. Nothing else: case and
    /// punctuation stay, attached to their tokens, because this profile exists
    /// to catch the formatter regressing.
    static func renderedTokens(_ text: String) -> [String] {
        fold(text.precomposedStringWithCompatibilityMapping)
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
    }

    // MARK: - .light

    /// Whitespace collapse plus one tolerance: a trailing sentence mark. That is
    /// the edit a user makes without thinking, and counting it would make the
    /// zero-edit rate measure punctuation taste instead of correctness.
    static func lightTokens(_ text: String) -> [String] {
        let collapsed = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let trimmed = trimTrailing(collapsed)
        return trimmed.isEmpty ? [] : trimmed.split(separator: " ").map(String.init)
    }

    static let trailingPunctuation: Set<Character> = [".", ",", "!", "?", ";", ":", "\u{2026}"]

    static func trimTrailing(_ text: String) -> String {
        var out = Substring(text)
        while let last = out.last, trailingPunctuation.contains(last) || last == " " {
            out = out.dropLast()
        }
        return String(out)
    }

    // MARK: - regex plumbing

    static func regex(_ pattern: String) -> NSRegularExpression {
        // Compile-time literals; a throw here is a programmer error.
        try! NSRegularExpression(pattern: pattern, options: [])
    }

    static func replaceAll(_ re: NSRegularExpression, in text: String, with template: String)
        -> String {
        let ns = text as NSString
        return re.stringByReplacingMatches(in: text, options: [],
                                           range: NSRange(location: 0, length: ns.length),
                                           withTemplate: template)
    }
}
