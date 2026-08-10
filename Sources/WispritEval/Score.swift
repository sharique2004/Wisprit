import Foundation

/// What one alignment step did to get from ref to hyp.
public enum AlignmentOp: String, Sendable, Equatable {
    case hit
    case sub
    case del   // a reference word the hypothesis never produced
    case ins   // a hypothesis word with nothing behind it
}

public struct AlignedPair: Sendable, Equatable {
    public var op: AlignmentOp
    public var ref: String?
    public var hyp: String?

    public init(op: AlignmentOp, ref: String?, hyp: String?) {
        self.op = op; self.ref = ref; self.hyp = hyp
    }
}

/// Levenshtein counts plus the alignment that produced them. The pair list is
/// what makes a bad number debuggable — a WER row without it is an assertion,
/// not evidence.
public struct EditOps: Sendable, Equatable {
    public var hits: Int
    public var sub: Int
    public var del: Int
    public var ins: Int
    public var pairs: [AlignedPair]

    public init(hits: Int = 0, sub: Int = 0, del: Int = 0, ins: Int = 0,
                pairs: [AlignedPair] = []) {
        self.hits = hits; self.sub = sub; self.del = del; self.ins = ins; self.pairs = pairs
    }

    public var errors: Int { sub + del + ins }
}

public struct WordErrorRate: Sendable, Equatable {
    public var errors: Int
    public var refWords: Int
    public var sub: Int
    public var del: Int
    public var ins: Int
    public var hits: Int

    public init(errors: Int, refWords: Int, sub: Int, del: Int, ins: Int, hits: Int) {
        self.errors = errors; self.refWords = refWords
        self.sub = sub; self.del = del; self.ins = ins; self.hits = hits
    }

    /// Errors per reference word. An empty reference scores 0 when the
    /// hypothesis is also empty and 1 otherwise — there is no denominator to
    /// divide by, and silently reporting 0 for "invented a sentence from
    /// nothing" would be a lie.
    public var rate: Double {
        refWords > 0 ? Double(errors) / Double(refWords) : (errors == 0 ? 0 : 1)
    }
}

public struct CharacterErrorRate: Sendable, Equatable {
    public var errors: Int
    public var refChars: Int
    public var sub: Int
    public var del: Int
    public var ins: Int

    public init(errors: Int, refChars: Int, sub: Int, del: Int, ins: Int) {
        self.errors = errors; self.refChars = refChars
        self.sub = sub; self.del = del; self.ins = ins
    }

    public var rate: Double {
        refChars > 0 ? Double(errors) / Double(refChars) : (errors == 0 ? 0 : 1)
    }
}

public struct TermRecall: Sendable, Equatable {
    /// Terms present in the hypothesis, in the order they were asked for.
    public var found: [String]
    public var missing: [String]
    /// Whole-word occurrence counts, same shape as `VocabularyChannel.termHits`.
    public var hits: [String: Int]

    public init(found: [String], missing: [String], hits: [String: Int]) {
        self.found = found; self.missing = missing; self.hits = hits
    }

    public var total: Int { found.count + missing.count }
    /// An utterance that expects no terms recalls all zero of them.
    public var rate: Double { total > 0 ? Double(found.count) / Double(total) : 1 }
}

/// The metrics. Every entry point takes raw strings and names its profile, so
/// a caller can never accidentally compare a rendered ref against ASR tokens.
public enum Score {

    // MARK: - alignment

    /// Word-level Levenshtein with backtrace. Unit costs; on a tie the
    /// diagonal wins, then deletion, then insertion — fixed so the same pair
    /// always yields the same alignment and a golden stays a golden.
    public static func align(ref: [String], hyp: [String]) -> EditOps {
        let m = ref.count, n = hyp.count
        var d = [[Int]](repeating: [Int](repeating: 0, count: n + 1), count: m + 1)
        for i in 0...m { d[i][0] = i }
        for j in 0...n { d[0][j] = j }
        if m > 0 && n > 0 {
            for i in 1...m {
                for j in 1...n {
                    if ref[i - 1] == hyp[j - 1] {
                        d[i][j] = d[i - 1][j - 1]
                    } else {
                        d[i][j] = 1 + min(d[i - 1][j - 1], min(d[i - 1][j], d[i][j - 1]))
                    }
                }
            }
        }

        var pairs: [AlignedPair] = []
        var ops = EditOps()
        var i = m, j = n
        while i > 0 || j > 0 {
            if i > 0, j > 0, ref[i - 1] == hyp[j - 1], d[i][j] == d[i - 1][j - 1] {
                pairs.append(AlignedPair(op: .hit, ref: ref[i - 1], hyp: hyp[j - 1]))
                ops.hits += 1
                i -= 1; j -= 1
            } else if i > 0, j > 0, d[i][j] == d[i - 1][j - 1] + 1 {
                pairs.append(AlignedPair(op: .sub, ref: ref[i - 1], hyp: hyp[j - 1]))
                ops.sub += 1
                i -= 1; j -= 1
            } else if i > 0, d[i][j] == d[i - 1][j] + 1 {
                pairs.append(AlignedPair(op: .del, ref: ref[i - 1], hyp: nil))
                ops.del += 1
                i -= 1
            } else {
                pairs.append(AlignedPair(op: .ins, ref: nil, hyp: hyp[j - 1]))
                ops.ins += 1
                j -= 1
            }
        }
        ops.pairs = pairs.reversed()
        return ops
    }

    // MARK: - WER

    public static func wer(ref: String, hyp: String, profile: NormalizeProfile = .asr)
        -> WordErrorRate {
        let refTokens = Normalize.tokens(ref, profile: profile)
        let ops = align(ref: refTokens, hyp: Normalize.tokens(hyp, profile: profile))
        return WordErrorRate(errors: ops.errors, refWords: refTokens.count,
                             sub: ops.sub, del: ops.del, ins: ops.ins, hits: ops.hits)
    }

    /// Corpus WER is Σerrors / Σrefwords — the micro-average. Summing the rows
    /// first is the whole point: a macro-average over utterances lets a
    /// three-word utterance outvote a ninety-word one.
    public static func aggregate(_ results: [WordErrorRate]) -> WordErrorRate {
        results.reduce(WordErrorRate(errors: 0, refWords: 0, sub: 0, del: 0, ins: 0, hits: 0)) {
            WordErrorRate(errors: $0.errors + $1.errors, refWords: $0.refWords + $1.refWords,
                          sub: $0.sub + $1.sub, del: $0.del + $1.del,
                          ins: $0.ins + $1.ins, hits: $0.hits + $1.hits)
        }
    }

    public static func microAverage(_ results: [WordErrorRate]) -> Double {
        aggregate(results).rate
    }

    /// The unweighted mean of per-utterance rates. Provided so the two can be
    /// reported side by side when they disagree — never as the headline number.
    public static func macroAverage(_ results: [WordErrorRate]) -> Double {
        guard !results.isEmpty else { return 0 }
        return results.reduce(0.0) { $0 + $1.rate } / Double(results.count)
    }

    // MARK: - CER

    /// Character error rate over `.rendered`: case and punctuation count, which
    /// is what makes this the formatter's metric rather than the engine's.
    public static func cer(ref: String, hyp: String) -> CharacterErrorRate {
        let refChars = Normalize.normalized(ref, profile: .rendered).map(String.init)
        let hypChars = Normalize.normalized(hyp, profile: .rendered).map(String.init)
        let ops = align(ref: refChars, hyp: hypChars)
        return CharacterErrorRate(errors: ops.errors, refChars: refChars.count,
                                  sub: ops.sub, del: ops.del, ins: ops.ins)
    }

    // MARK: - term recall

    /// Whole-word, case-insensitive presence of each expected term.
    ///
    /// The matching rule is a deliberate copy of
    /// `Sources/WispritEngine/VocabularyChannel.swift::termHits` — `\b` +
    /// escaped words joined with `\s+` + `\b`, `.caseInsensitive`. WispritEval
    /// may only depend on WispritKit, so the rule cannot be shared by import;
    /// it is duplicated so the offline scoreboard and the live `termHits`
    /// telemetry count the same thing. Keep the two in sync.
    public static func termRecall(refTerms: [String], hyp: String) -> TermRecall {
        var found: [String] = []
        var missing: [String] = []
        var hits: [String: Int] = [:]
        for term in refTerms {
            let n = occurrences(of: term, in: hyp)
            if n > 0 {
                found.append(term)
                hits[term] = n
            } else {
                missing.append(term)
            }
        }
        return TermRecall(found: found, missing: missing, hits: hits)
    }

    static func occurrences(of term: String, in text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        let words = term.split(whereSeparator: { $0.isWhitespace })
            .map { NSRegularExpression.escapedPattern(for: String($0)) }
        guard !words.isEmpty else { return 0 }
        let pattern = "\\b" + words.joined(separator: "\\s+") + "\\b"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        else { return 0 }
        return re.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    // MARK: - zero edit

    /// True when the user would have had nothing to fix. Wispr Flow's headline
    /// metric is the rate of these, not WER.
    public static func isZeroEdit(ref: String, hyp: String) -> Bool {
        Normalize.tokens(ref, profile: .light) == Normalize.tokens(hyp, profile: .light)
    }

    /// Zero-edit rate over a set of (ref, hyp) pairs. Reported with `n` always,
    /// because a rate over three utterances is not a rate.
    public static func zeroEditRate(_ pairs: [(ref: String, hyp: String)]) -> Double {
        guard !pairs.isEmpty else { return 0 }
        let ok = pairs.filter { isZeroEdit(ref: $0.ref, hyp: $0.hyp) }.count
        return Double(ok) / Double(pairs.count)
    }
}
