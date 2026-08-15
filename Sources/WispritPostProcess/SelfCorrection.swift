// Explicit self-correction — "I said X, no actually Y" -> "Y".
//
// Lifted out of `PostProcess` stage 5 so the same code can run in both places
// it is needed:
//
//   * the finalize path, where `PostProcess.selfCorrect` calls it after stage 1
//     has already stripped the fillers, and
//   * the live path, where it runs on every raw ASR partial (~1/s) and the
//     fillers are still in the text.
//
// That second caller is why every joint tolerates interleaved um/uh/erm, why
// the whole engine is one bounded left-to-right sweep over the string, and why
// `apply` is idempotent: a partial is re-processed from scratch each time it
// grows, so `apply(apply(x))` must equal `apply(x)` for every input.
//
// Two tiers, both explicit-marker-only — the SPEC §postprocessing rule is
// "detect explicit markers only … ambiguous cases pass through verbatim":
//
//   a. CLOSED-CLASS PAIR. "<X> <connective> <Y>" where X and Y are members of
//      the SAME closed class (weekday, month, clock time, number, relative day)
//      keeps Y and drops X plus the joint. Because both sides have to be the
//      same *kind of thing* to fire at all, the weak connectives — a bare
//      "actually", "sorry", a bare "no" — are safe here, and only here.
//      "Thursday umm no actually Friday" -> "Friday"; "that's actually great"
//      and "I actually think Friday works" are untouched, because nothing on
//      the left of "actually" is a weekday.
//
//      POSSESSIVE DATE PAIR, the phrase form of tier (a): "<class>'s <head>
//      <connective> <class>'s <head>" with the SAME head noun on both sides
//      keeps the right phrase wholesale — "tonight's meeting? Actually,
//      tomorrow's meeting" -> "tomorrow's meeting". The repeated head is what
//      makes the weak connectives safe on a two-token side, exactly as class
//      membership does for a bare one. See `possessivePairRx`.
//
//   b. GENERAL MARKER. The Python rule ("no wait"), plus two new markers that
//      are unambiguous enough to work on any word: "no actually" and "I mean".
//      The replaced span is the Python span — the single word before the
//      marker, the marker, and the joint whitespace — with the duplicate
//      function word the deletion tends to leave behind ("… to Bob no wait to
//      Alice" -> "… to to Alice") collapsed afterwards, exactly as before.
//
//      CLAUSE RESTART, the general form of tier (b): when the text after the
//      marker RE-BEGINS the clause in front of it, the user restarted the
//      clause and the restart replaces it wholesale — "I want to meet Vivek,
//      no actually I want it Sharique" -> "I want it Sharique". The evidence
//      requirement — B shares A's first two tokens (case-insensitive, fillers
//      skipped), or its single first token when that token is a non-lexicon
//      content word — is what makes wholesale deletion safe on ARBITRARY
//      content: a name works exactly like a weekday, with no class list to
//      maintain. No shared re-beginning, no clause repair; the single-word
//      span above still applies under its own rules.
//
// The two tiers are one regex and one sweep, not two passes, because tier (a)
// has to be able to *veto* tier (b): when both sides of a marker are
// closed-class items of DIFFERENT classes the correction does not type-check
// ("Thursday no actually 3 o'clock" — you cannot correct a weekday into a
// time), which is the definition of ambiguous, so the joint passes verbatim
// and no other rule gets a second look at it. The one marker still largely
// exempt from that veto is "no wait": its span is a Python-parity contract
// pinned by `Goldens.swift`, so inside the parity domain it keeps deleting
// what it is handed. Python's comma-only gap never crossed a sentence
// terminator, so across one (which this engine now permits for the
// "no"-anchored markers) "no wait" obeys the same vetoes as "no actually".
//
// PARITY SUPERSEDED, measured. The blanket exemption was wrong on the LITERAL
// "no wait" — the noun phrase, not the interjection. Two shapes were measured
// through the shipping pipeline and both lost a word: "There is no wait at the
// DMV." -> "There at the DMV." and "The clinic has no wait time today." ->
// "The clinic time today." Python deleted those too, so this is a bug the port
// inherited rather than a divergence the port introduced, and parity is not a
// reason to keep shipping it. The exemption now carries two literal-use
// vetoes (`noWaitLiteralLeaders`, `noWaitObjectWords`) and is otherwise
// unchanged; every parity golden that exercises the interjection still holds.

import Foundation

// MARK: - Engine

public enum SelfCorrection {
    /// True when `text` ends on a connective whose replacement has not been
    /// spoken yet ("…on Thursday umm no actually"). The live partial path
    /// defers display correction for exactly that frame: applying the engine
    /// there would delete the word being corrected with nothing to put in its
    /// place, and the very next partial resolves it either way.
    public static func endsMidCorrection(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let range = NSRange(text.startIndex..., in: text)
        return midCorrectionTail.firstMatch(in: text, range: range) != nil
    }

    /// Resolve every explicit self-correction in `text`.
    ///
    /// Pure, allocation-light and fast enough to run on every partial: a sweep
    /// only allocates when it actually rewrites something, and a string with no
    /// marker in it costs four regex scans and returns the input unchanged.
    public static func apply(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var text = text
        // A chain ("Tuesday no Wednesday no Thursday") already collapses inside
        // a single sweep — the cursor resumes AT the survivor — so the loop is
        // a fixpoint guarantee for the tiers that interact (a general-marker
        // deletion can expose a new duplicate, a collapsed duplicate can expose
        // a new joint), not the chain mechanism. Bounded so a pathological
        // input can never spin.
        for _ in 0..<maxPasses {
            let next = sweep(text)
            if next == text { break }
            text = next
        }
        return text
    }

    /// Upper bound on the fixpoint loop. Four is well past the observed need
    /// (one sweep changes, the second confirms) and keeps the worst case inside
    /// the <1 ms live budget.
    static let maxPasses = 4

    static func sweep(_ text: String) -> String {
        // Possessive date pair first — its evidence (same head noun on both
        // sides) is stronger than anything the joint sweep can establish, so
        // it gets first claim on the span. See `possessivePairRx`.
        var text = possessivePairRx.replacingAll(in: text, with: "$2")
        text = correctJoints(text)
        // "scratch that" — keep only what follows the last DIRECTIVE occurrence.
        text = applyScratch(text)
        // Repeat until stable so "to to to" fully collapses.
        while true {
            let collapsed = dupRx.replacingAll(in: text, with: "$1")
            if collapsed == text { break }
            text = collapsed
        }
        return text
    }

    /// "scratch that" — delete everything through the LAST occurrence that is
    /// actually the directive, and keep the text after it.
    ///
    /// The Python rule was one greedy `^.*scratch that` substitution with no
    /// guard at all, which is fine for the imperative ("draft the email scratch
    /// that write the memo") and catastrophic for the transitive verb, where
    /// "that" is a determiner introducing the object rather than the marker's
    /// pronoun. Measured through the shipping pipeline: "Don't scratch that
    /// itch, it'll get worse." -> "itch, it'll get worse.", i.e. the sentence
    /// lost its subject, its verb and its negation.
    ///
    /// The guard is a lookback, not a lookahead, because a lookahead cannot
    /// work: a genuine directive is followed by arbitrary content, including
    /// the content words a determiner reading would predict ("scratch that
    /// today", "scratch that write the memo" — both pinned goldens). What the
    /// two readings do NOT share is what stands in FRONT of the verb. The
    /// directive is an imperative, so it opens the utterance or follows the
    /// clause it retracts; the transitive reading needs a negation, a modal, an
    /// infinitive "to" or a nominative subject to license it, and none of those
    /// can end a retracted clause. See `scratchLiteralLeaders`.
    static func applyScratch(_ text: String) -> String {
        guard scratchProbeRx.matches(text) else { return text }
        let ns = text as NSString
        var cut: Int?
        for m in scratchRx.allMatches(text, ns)
        where isScratchDirective(at: m.range.location, ns) {
            cut = m.range.location + m.range.length
        }
        guard let cut else { return text }
        return ns.substring(from: cut)
    }

    private static func isScratchDirective(at start: Int, _ ns: NSString) -> Bool {
        // Nothing in front of it (or only fillers/punctuation) is the purest
        // imperative there is.
        guard let leader = wordBefore(ns, start) else { return true }
        return !scratchLiteralLeaders.contains(leader)
    }

    /// Comparison form of the last non-filler word before `index`, nil when the
    /// text in front of it holds no word at all.
    private static func wordBefore(_ ns: NSString, _ index: Int) -> String? {
        var i = min(index, ns.length)
        while i > 0 {
            while i > 0, isWhitespace(ns.character(at: i - 1)) { i -= 1 }
            guard i > 0 else { return nil }
            let end = i
            while i > 0, !isWhitespace(ns.character(at: i - 1)) { i -= 1 }
            let word = comparisonForm(ns.substring(with: NSRange(location: i, length: end - i)))
            if !word.isEmpty, !fillerSet.contains(word) { return word }
        }
        return nil
    }

    /// One left-to-right sweep over the correction joints. The cursor only ever
    /// moves forward, so the sweep is linear in the number of joints.
    static func correctJoints(_ text: String) -> String {
        let ns = text as NSString
        guard var match = jointRx.firstMatch(text, ns, from: 0),
              match.numberOfRanges > yClassFirst + classCount - 1 else { return text }
        var out = ""
        out.reserveCapacity(ns.length)
        var cursor = 0
        while true {
            // Exactly one of the two X branches participates: the closed-class
            // item, or the single spoken word tier (b) works on.
            let xClassRange = match.range(at: xWhole)
            let x = xClassRange.location == NSNotFound ? match.range(at: xWord) : xClassRange
            // Unreachable — the alternation is not optional — but the pipeline's
            // contract is that no stage ever raises, so a pattern edit that
            // broke the group layout must degrade to verbatim, not to a trap.
            guard x.location != NSNotFound else { return text }
            let xEnd = x.location + x.length
            let y = match.range(at: yWhole)
            let xClass = classIndex(match, xClassFirst)
            let yClass = y.location == NSNotFound ? nil : classIndex(match, yClassFirst)
            let next: Int
            if let xClass, let yClass, xClass == yClass {
                // Tier (a). Keep Y, drop X and the joint; resume AT Y so
                // "Tuesday no Wednesday no Thursday" resolves in this sweep.
                out += ns.substring(with: NSRange(location: cursor,
                                                  length: match.range.location - cursor))
                next = y.location
            } else if let marker = generalMarker(match),
                      let plan = repairPlan(marker, x, y, ns, xClass, yClass,
                                            matchEnd: match.range.location + match.range.length,
                                            cursor: cursor) {
                switch plan {
                case .restart(let aStart, let bStart):
                    // Clause restart. B re-begins the clause that ends at X,
                    // so B replaces it wholesale: everything from the clause
                    // start through the marker goes, and B — casing,
                    // punctuation and all — stays verbatim.
                    out += ns.substring(with: NSRange(location: cursor,
                                                      length: aStart - cursor))
                    next = bStart
                case .span:
                    // Tier (b). The Python span: the single word before the
                    // marker, the marker, and the joint whitespace. Y — which
                    // this pattern consumed and the Python one never did — is
                    // re-emitted verbatim, so the result is identical either
                    // way.
                    let drop = lastTokenStart(x, ns)
                    out += ns.substring(with: NSRange(location: cursor,
                                                      length: drop - cursor))
                    if y.location != NSNotFound { out += ns.substring(with: y) }
                    next = match.range.location + match.range.length
                }
            } else {
                // Ambiguous. Verbatim, and resume just past X so a later joint
                // in the same sentence still gets its own look — but not so far
                // back that the vetoed joint can be re-read with a new X.
                out += ns.substring(with: NSRange(location: cursor, length: xEnd - cursor))
                next = xEnd
            }
            cursor = next
            guard let more = jointRx.firstMatch(text, ns, from: cursor) else { break }
            match = more
        }
        out += ns.substring(from: cursor)
        return out
    }

    /// What a general marker may do to a joint its vetoes allow — repair the
    /// whole clause, delete the single-word span — or nil when they refuse.
    private static func repairPlan(_ marker: GeneralMarker, _ x: NSRange, _ y: NSRange,
                                   _ ns: NSString, _ xClass: Int?, _ yClass: Int?,
                                   matchEnd: Int, cursor: Int) -> Repair? {
        let xEnd = x.location + x.length
        // B — the replacement text — starts at Y when the pattern consumed a
        // closed-class Y, otherwise right after the marker's trailing gap.
        let bStart = y.location == NSNotFound ? matchEnd : y.location
        let crossed = terminatorCount(ns, from: xEnd, to: bStart)
        guard isCorrection(marker, x, ns, xClass, yClass, crossed: crossed,
                           bStart: bStart) else { return nil }
        if let aStart = restartStart(x, bStart: bStart, ns, floor: cursor) {
            return .restart(aStart: aStart, bStart: bStart)
        }
        // Across a terminator the span may only replace with a content word:
        // a clause opener after "No," is a denial of the previous sentence,
        // not a replacement ("I finished the report. No, actually I think we
        // should celebrate." stays verbatim).
        //
        // …and it may only replace with a bare FRAGMENT. The single-word span
        // reaches back into the PREVIOUS sentence and deletes its last word, so
        // when the text after the marker is itself a whole clause the edit
        // fuses two sentences into garbage rather than correcting anything:
        // "I finished the report. No, actually Jane finished it." measured as
        // "I finished the Jane finished it." The restart tier above is the
        // mechanism for a re-stated CLAUSE and it already declined this one
        // (the clauses share no re-beginning — "finished" appears in both, but
        // an incidentally shared verb is not evidence of a restart, only a
        // shared opening is). What is left for the span is the shape it was
        // measured to get right — a replacement noun phrase standing alone
        // after the marker, "…to Viveque. No, actually, Shariq." — so the span
        // now requires that shape as its evidence and passes everything else
        // through verbatim. See `isReplacementFragment`.
        if crossed > 0 {
            let b = restartTokens(ns, from: bStart, to: ns.length,
                                  stopAtSentenceEnd: true, limit: fragmentWindow + 1)
            guard let head = b.first, !hedgeLeaders.contains(head.text) else { return nil }
            guard isReplacementFragment(b) else { return nil }
        }
        return .span
    }

    /// Whether the tokens after a cross-terminator marker are a replacement
    /// noun phrase rather than a new clause: one bare token ("Shariq.",
    /// "production."), or two whose first opens a noun phrase ("the footer",
    /// "next quarter"). Anything longer, or a two-token pair that starts with
    /// its own subject ("Jane finished"), is prose the span must not touch.
    ///
    /// Deliberately shape evidence rather than token evidence: a shared token
    /// between the two clauses is NOT usable here, because the false-fire that
    /// motivated the rule shares one ("…the report. No, actually Jane finished
    /// it."). Phonetic evidence — the mishear-restatement channel — would be
    /// the natural third signal, but `WispritPostProcess` depends on
    /// `WispritKit` alone (Package.swift), so `WispritCorrections`'
    /// DoubleMetaphone is out of reach and a second copy of it is not worth a
    /// case the shape rule already covers.
    private static func isReplacementFragment(_ b: [(start: Int, text: String)]) -> Bool {
        switch b.count {
        case 1: return true
        case 2: return fragmentOpeners.contains(b[0].text)
        default: return false
        }
    }

    /// Upper bound, in words, on a cross-terminator replacement fragment.
    static let fragmentWindow = 2

    private enum Repair {
        case restart(aStart: Int, bStart: Int)
        case span
    }

    /// Whether a general marker may correct at this joint at all. `crossed` is
    /// the number of sentence terminators between X and B.
    private static func isCorrection(_ marker: GeneralMarker, _ x: NSRange, _ ns: NSString,
                                     _ xClass: Int?, _ yClass: Int?, crossed: Int,
                                     bStart: Int) -> Bool {
        // Sentence-boundary veto, narrowed by anchor. The "no"-anchored
        // markers may cross ONE terminator: the recognizer routinely
        // punctuates the pause before a correction ("Vivek. No, actually …"),
        // and a "No," opening the next sentence is a denial/correction
        // discourse cue, not prose. "I mean" is the hedge that caused the
        // original regression ("…is fine. I mean it.") and still refuses every
        // terminator — Python's comma-only gap could never match one, so
        // refusing there is what parity actually means.
        switch marker {
        case .iMean: guard crossed == 0 else { return false }
        case .noWait, .noActually: guard crossed <= 1 else { return false }
        }
        // "no wait" is the Python marker and its span is a parity contract —
        // but the parity domain is what Python could match, and that never
        // crossed a terminator. Inside it, "no wait" keeps deleting whatever
        // it is handed; across one, it obeys the same vetoes as "no actually".
        //
        // Minus the LITERAL reading, which parity does not protect: "no wait"
        // is also an ordinary noun phrase, and there the "no" is a determiner
        // on "wait", not an interjection. Two high-precision signals, both
        // measured on the false fires in the header note, and both of them
        // shapes the interjection cannot take:
        //   * the word the span would delete is a copula / possession verb /
        //     preposition ("there IS no wait", "the clinic HAS no wait") — the
        //     interjection replaces the content word it follows, and a
        //     correction never replaces "is";
        //   * "wait" carries a noun continuation ("no wait TIME", "no wait AT
        //     the DMV") — the interjection is a complete utterance, so what
        //     follows it is the replacement, never the phrase's own tail.
        // "…to Bob no wait to Alice" and "…three no wait four pm" are untouched
        // by both: "Bob"/"three" are content, and "to"/"four" are not tails.
        if marker == .noWait, crossed == 0 {
            if xClass == nil, noWaitLiteralLeaders.contains(leaderWord(x, ns)) { return false }
            if let after = restartTokens(ns, from: bStart, to: ns.length,
                                         stopAtSentenceEnd: true, limit: 1).first,
               noWaitObjectWords.contains(after.text) { return false }
            return true
        }
        // Cross-class veto — tier (a) looked at this joint and refused it.
        if xClass != nil, yClass != nil { return false }
        // Discourse-hedge veto: "no actually" and "I mean" are also ordinary
        // conversational filler ("so I mean we should go", "well no actually
        // that's fine", "what I mean is …"). A correction replaces a CONTENT
        // word, so a function word or interjection in front of the marker means
        // the user is talking, not correcting.
        if xClass == nil, hedgeLeaders.contains(leaderWord(x, ns)) { return false }
        return true
    }

    /// The lowercased last token of X — the single word a tier (b) span would
    /// delete, even when the pattern matched a multi-token closed-class item.
    private static func leaderWord(_ x: NSRange, _ ns: NSString) -> String {
        let start = lastTokenStart(x, ns)
        return ns.substring(with: NSRange(location: start,
                                          length: x.location + x.length - start)).lowercased()
    }

    /// The clause-restart evidence check: start of the deleted span when the
    /// text after the marker re-begins the clause that ends at X, nil when the
    /// evidence is missing. A = the clause ending at X — from the last
    /// sentence start (or `floor`, the sweep cursor, so a restart can never
    /// reach back into text an earlier joint already resolved), capped at
    /// `restartWindow` words. B = what follows the marker, up to its own
    /// sentence end. The deleted span is [aStart, bStart), which by
    /// construction crosses at most the one terminator the narrowed veto
    /// already allowed.
    private static func restartStart(_ x: NSRange, bStart: Int, _ ns: NSString,
                                     floor: Int) -> Int? {
        var clauseStart = floor
        var i = x.location
        while i > floor {
            let c = ns.character(at: i - 1)
            if isSentenceTerminator(c) || c == 0x0A || c == 0x0D {
                clauseStart = i
                break
            }
            i -= 1
        }
        let a = Array(restartTokens(ns, from: clauseStart, to: x.location + x.length,
                                    stopAtSentenceEnd: false, limit: Int.max)
            .suffix(restartWindow))
        guard let first = a.first else { return nil }
        let b = restartTokens(ns, from: bStart, to: ns.length,
                              stopAtSentenceEnd: true, limit: a.count)
        var shared = 0
        for (ta, tb) in zip(a, b) {
            guard ta.text == tb.text else { break }
            shared += 1
        }
        if shared >= 2 { return first.start }
        // One shared token is enough only when it is a non-lexicon content
        // word — a name re-begins a clause the way "I" or "the" never can.
        if shared == 1, !restartFunctionWords.contains(a[0].text),
           !closedClassWordRx.matches(a[0].text) { return first.start }
        return nil
    }

    /// Upper bound, in words, on the clause a restart may delete.
    static let restartWindow = 12

    /// Whitespace-delimited tokens of `ns` in `from..<to`, fillers skipped,
    /// each carrying its start offset and comparison form (lowercased, edge
    /// punctuation stripped, curly apostrophe normalized). `stopAtSentenceEnd`
    /// cuts the list at the first token that closes a sentence — B never reads
    /// past its own sentence. `limit` bounds the work, not the meaning.
    private static func restartTokens(_ ns: NSString, from: Int, to: Int,
                                      stopAtSentenceEnd: Bool,
                                      limit: Int) -> [(start: Int, text: String)] {
        var tokens: [(start: Int, text: String)] = []
        var i = from
        while i < to, tokens.count < limit {
            while i < to, isWhitespace(ns.character(at: i)) { i += 1 }
            guard i < to else { break }
            let start = i
            var closesSentence = false
            while i < to, !isWhitespace(ns.character(at: i)) {
                if isSentenceTerminator(ns.character(at: i)) { closesSentence = true }
                i += 1
            }
            let text = comparisonForm(ns.substring(with: NSRange(location: start,
                                                                 length: i - start)))
            if !text.isEmpty, !fillerSet.contains(text) {
                tokens.append((start: start, text: text))
            }
            if stopAtSentenceEnd, closesSentence { break }
        }
        return tokens
    }

    private static func comparisonForm(_ raw: String) -> String {
        raw.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .trimmingCharacters(in: comparisonTrim)
    }

    private static func terminatorCount(_ ns: NSString, from: Int, to: Int) -> Int {
        var count = 0
        for i in from..<to where isSentenceTerminator(ns.character(at: i)) { count += 1 }
        return count
    }

    private static func isSentenceTerminator(_ c: unichar) -> Bool {
        switch c {
        case 0x2E, 0x21, 0x3F, 0x2026: return true  // . ! ? …
        default: return false
        }
    }

    private static func isWhitespace(_ c: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(c) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    /// Start of the last whitespace-delimited token inside `range` — the word
    /// the Python `\b[\w']+` captured, even when the pattern matched a
    /// multi-token closed-class item ("half past three no wait Bob").
    private static func lastTokenStart(_ range: NSRange, _ ns: NSString) -> Int {
        var i = range.location + range.length
        while i > range.location {
            guard let scalar = Unicode.Scalar(ns.character(at: i - 1)),
                  !CharacterSet.whitespacesAndNewlines.contains(scalar) else { break }
            i -= 1
        }
        return i
    }

    /// Which closed class the side rooted at `base` matched, if any. Exactly
    /// one of the five discriminator groups participates per side.
    private static func classIndex(_ m: NSTextCheckingResult, _ base: Int) -> Int? {
        for i in 0..<classCount where m.range(at: base + i).location != NSNotFound { return i }
        return nil
    }

    private static func generalMarker(_ m: NSTextCheckingResult) -> GeneralMarker? {
        if m.range(at: markerNoWait).location != NSNotFound { return .noWait }
        if m.range(at: markerNoActually).location != NSNotFound { return .noActually }
        if m.range(at: markerIMean).location != NSNotFound { return .iMean }
        return nil
    }

    enum GeneralMarker { case noWait, noActually, iMean }
}

// MARK: - Closed classes

// The five closed classes tier (a) recognizes, in the order their discriminator
// groups appear in the pattern. `SelfCorrection.classIndex` returns an offset
// into this order, so the order is the contract — the values themselves are
// never compared to anything but each other.
//
// Every sub-pattern below is group-free (`(?:…)` only): the joint pattern
// counts capture groups by position, so a stray `(` here would shift every
// index in `SelfCorrection`.

private let unitWords = "one|two|three|four|five|six|seven|eight|nine"
private let teenWords =
    "ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen"
private let ordinalUnitWords = "first|second|third|fourth|fifth|sixth|seventh|eighth|ninth"
private let ordinalTeenWords = "tenth|eleventh|twelfth|thirteenth|fourteenth|fifteenth|"
    + "sixteenth|seventeenth|eighteenth|nineteenth"

// Spelled 1–31, cardinal and ordinal, plus the digit forms. Compound forms
// accept either joiner ("twenty one", "twenty-one"). Longest alternative first
// throughout, so "thirteen" never resolves as "three" and "4th" never as "4".
private let cardinalWordPattern = "(?:twenty[\\s-]?(?:" + unitWords + ")|thirty[\\s-]?one|"
    + teenWords + "|twenty|thirty|" + unitWords + ")"
private let ordinalWordPattern = "(?:twenty[\\s-]?(?:" + ordinalUnitWords + ")|"
    + "thirty[\\s-]?first|twentieth|thirtieth|" + ordinalTeenWords + "|" + ordinalUnitWords + ")"
private let numberPattern = "(?:\\d{1,4}(?:st|nd|rd|th)|" + ordinalWordPattern + "|"
    + cardinalWordPattern + "|\\d{1,4})"

// Clock times, tried BEFORE bare numbers so "3 o'clock" is one time rather than
// the number 3 followed by a word.
private let clockPattern = "(?:" + [
    "(?:half|quarter)\\s+(?:past|to)\\s+(?:\\d{1,2}|" + cardinalWordPattern + ")",
    "\\d{1,2}:\\d{2}(?:\\s*[ap]\\.?m\\.?)?",
    "(?:\\d{1,2}|" + cardinalWordPattern + ")\\s+o['\u{2019}]?\\s?clock",
    "\\d{1,2}\\s*[ap]\\.?m\\.?",
].joined(separator: "|") + ")"

/// Longest-first, ties broken alphabetically — the `emojiNamePattern` idiom:
/// `sorted` is not stable and the compiled pattern must be.
private func alternation(_ words: [String]) -> String {
    "(?:" + words.sorted { ($0.count, $1) > ($1.count, $0) }.joined(separator: "|") + ")"
}

// Weekdays. Full names only — "wed"/"sat"/"sun" are ordinary English words and
// the abbreviations buy nothing, since SpeechAnalyzer spells the day out. The
// second row is the misspelling family this recognizer actually emits for a
// fast-spoken weekday; none of them are words, so they cost no false positives.
private let weekdayPattern = alternation([
    "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
    "mondy", "teusday", "tuesay", "wendsday", "wensday", "wedsday",
    "thuersday", "thuersay", "thursay", "thersday", "thurdsay",
    "saterday", "satuday", "sundy",
])

// Months, split by ambiguity. The unambiguous names are not English words, so
// they are matched case-insensitively like every other class.
private let unambiguousMonthPattern = alternation([
    "january", "february", "april", "june", "july",
    "august", "september", "october", "november", "december",
    "jan", "feb", "apr", "jun", "jul", "aug", "sept", "sep", "oct", "nov", "dec",
])

// "may", "march" and "mar" are also a modal and two verbs, and the class list
// is what tier (a) uses to decide that BOTH sides of a connective are the same
// kind of thing — so a bare lowercase "may" made every "<verb> actually <verb>"
// sentence look like a month correction. Measured: "He may actually march in
// the parade." -> "He march in the parade.", a sentence with no correction in
// it at all losing its modal.
//
// Month sense therefore has to be evidenced, and dictated text carries exactly
// two cheap signals for it:
//   * capitalization. The recognizer capitalizes a month and lowercases the
//     modal, so `(?-i:…)` (an inline ICU flag, since the compiled pattern is
//     case-insensitive as a whole) is the discriminator. Sentence-initial "May
//     I …" is capitalized too, but tier (a) needs a same-class item on the
//     OTHER side of the connective as well, which no modal reading supplies;
//   * an adjacent day or year number ("march 5", "may 2026") — the date shape,
//     which the verb reading does not have.
// Everything else stays a plain word. The pinned pairs are unaffected:
// "March. Sorry, April." and "May no June" are both capitalized.
// ("MAR" is left out of the shouted forms on purpose: a three-letter all-caps
// token is an acronym far more often than a shouted month abbreviation.)
private let ambiguousMonthPattern = "(?:(?-i:"
    + alternation(["March", "May", "Mar", "MARCH", "MAY"]) + ")|"
    + alternation(["march", "may", "mar"])
    + "(?=\\s+(?:\\d{1,2}(?:st|nd|rd|th)?|\\d{4})(?![\\w-])))"

private let monthPattern = "(?:" + unambiguousMonthPattern + "|" + ambiguousMonthPattern + ")"

private let relativeDayPattern = alternation(["today", "tonight", "tomorrow", "yesterday"])

private let classCount = 5
private let classAlternation = "(?:(" + clockPattern + ")|(" + numberPattern + ")|("
    + weekdayPattern + ")|(" + monthPattern + ")|(" + relativeDayPattern + "))"

// MARK: - The joint pattern

// Shares the pipeline's filler vocabulary (`PostProcess` stage 1) rather than
// keeping a second copy: the live path hands this engine text stage 1 has not
// seen yet, so the two lists have to agree by construction.
private let filler = "(?:" + fillerWords.joined(separator: "|") + ")"

/// The separator on either side of a connective: the Python `[,]?\s+`, extended
/// to swallow the fillers the live path has not stripped. With no filler in the
/// text it matches a superset of what the Python rule matched: real recognizer
/// output punctuates the hesitation ("on Thursday, umm. No, actually Friday"),
/// so a single terminal mark is tolerated before the whitespace — measured on
/// the tts corpus, where the comma-only form never occurred.
private let gap = "[,.!?…]?\\s+(?:" + filler + "[,.!?…]?\\s+)*"

/// Whitespace *inside* a two-word connective ("no umm wait", and the ASR's
/// "No, actually"), likewise filler-tolerant. "uh no" / "umm no" need no entry
/// of their own — a leading filler is already part of `gap`.
private let innerGap = "[,]?\\s+(?:" + filler + "\\s+)*"

// The connectives, longest first so "no wait"/"no actually" always beat the
// bare "no". The three that are also general (tier b) markers are captured; the
// rest fire only inside a same-closed-class sandwich. One phrase list feeds
// both the joint pattern and the mid-correction tail probe below, so the two
// can never disagree about what a connective is.
private let markerPhrases: [(pattern: String, captured: Bool)] = [
    ("no" + innerGap + "wait", true),
    ("no" + innerGap + "actually", true),
    ("i" + innerGap + "mean", true),
    ("or" + innerGap + "rather", false),
    ("make" + innerGap + "that", false),
    ("actually", false),
    ("sorry", false),
    ("no", false),
]
private let markerAlternation = markerPhrases
    .map { $0.captured ? "(" + $0.pattern + ")" : $0.pattern }
    .joined(separator: "|")

/// A partial that ENDS on a connective (plus trailing fillers/punctuation) is
/// a correction whose Y has not been spoken yet. The live path defers display
/// correction for exactly that frame — otherwise the general markers fire with
/// nothing to keep and the word being corrected visibly vanishes until the
/// next partial arrives.
private let midCorrectionTail: NSRegularExpression = {
    let bare = markerPhrases.map(\.pattern).joined(separator: "|")
    let pattern = "\\b(?:" + bare + ")(?:[,.]?\\s+" + filler + ")*[,.…]?\\s*$"
    return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
}()

// Group layout. Positional, so every sub-pattern above is group-free and the
// order here is load-bearing.
private let xWhole = 1
private let xClassFirst = 2          // 2…6  — clock, number, weekday, month, relative day
private let xWord = 7
private let markerNoWait = 8
private let markerNoActually = 9
private let markerIMean = 10
private let yWhole = 11
private let yClassFirst = 12         // 12…16

// A joint is `<X> <gap> <connective> <gap> <Y?>`, where each side is either a
// closed-class item or (X only) a single spoken word. The class branch is tried
// first so "3 o'clock" reads as one time rather than the word "clock"; a filler
// can never be the word a correction replaces. Y is optional because tier (b)
// does not care what follows the marker — but when it IS a closed-class item,
// tier (a) needs it, so the pattern always consumes it when it can.
private let jointPattern = "(?<![\\w'-])"
    + "(?:(" + classAlternation + ")|(?!" + filler + "\\b)([\\w']+))"
    + gap
    + "(?:" + markerAlternation + ")"
    + gap
    + "(?:(" + classAlternation + ")(?![\\w'-]))?"
private let jointRx = Rx(jointPattern)

// MARK: - Possessive date pair

// "tonight's meeting? Actually, tomorrow's meeting" -> "tomorrow's meeting".
//
// Tier (a)'s safety argument, one construction wider: both sides are a
// possessive DATE-class item ("tonight's", "Friday's", "March's") and the head
// noun after it repeats verbatim, so the weak connectives — bare "actually",
// "sorry", "no" — are safe here for the same reason they are safe in a
// closed-class sandwich. The repeated head is the load-bearing evidence: it is
// exactly what the contraction reading ("tomorrow's fine" = "tomorrow is
// fine") can never produce, and without it the sentence is ambiguous prose
// ("Monday's numbers, actually Friday's report is better") and passes
// verbatim. The three DATE classes may cross ("Friday's meeting no actually
// tomorrow's meeting") — a day corrects a day; clock times and numbers are not
// in the rule because their possessives do not occur in speech.
//
// Y — its possessor, its copy of the head, casing and all — stays verbatim;
// X, the joint, and X's copy of the head go, which is what `sweep` replaces
// the whole match with via `$2`. The head may span up to three words
// ("tomorrow's team meeting"), compared case-insensitively through the
// backreference. Chains resolve through the fixpoint loop in `apply`.
private let datePossessive = "(?:" + weekdayPattern + "|" + monthPattern + "|"
    + relativeDayPattern + ")['\u{2019}]s"
private let possessivePairRx = Rx(
    "(?<![\\w'-])" + datePossessive
        + "\\s+([\\w']+(?:\\s+[\\w']+){0,2})" + gap
        + "(?:" + markerPhrases.map(\.pattern).joined(separator: "|") + ")" + gap
        + "(" + datePossessive + "\\s+\\1)(?![\\w'-])")

// "scratch that" — one occurrence, guarded by `SelfCorrection.applyScratch`,
// which walks every match and cuts at the last DIRECTIVE one. (Python spelled
// this as a single greedy `^.*scratch that` substitution; the cut point is the
// same, the guard is what is new.)
private let scratchRx = Rx(#"\bscratch\s+that\b[,.]?\s*"#,
                           [.caseInsensitive, .dotMatchesLineSeparators])
private let scratchProbeRx = Rx(#"\bscratch\s+that\b"#)

/// Words that make "scratch" the transitive verb and "that" its determiner:
/// negations, modals, the infinitive "to" and nominative subjects. Each one
/// licenses a verb phrase and none of them can END a retracted clause, which is
/// what makes the lookback safe — "call him tomorrow scratch that today" and
/// "draft the email scratch that write the memo" lead with "tomorrow"/"email".
private let scratchLiteralLeaders: Set<String> = [
    "don't", "dont", "do", "not", "never", "won't", "wont", "can't", "cant", "cannot",
    "didn't", "didnt", "doesn't", "doesnt", "wouldn't", "wouldnt",
    "shouldn't", "shouldnt", "couldn't", "couldnt",
    "to", "must", "should", "would", "could", "might", "may", "can", "will", "shall",
    "i", "you", "we", "they", "he", "she",
]

// Collapse an immediate duplicate of a function word, which self-correction can
// leave behind ("... to InsForge no wait to production" -> "... to to ...").
//
// The list is an allowlist of doubles that are NEVER grammatical in English,
// and it used to be much longer. Three of its members made the stage delete a
// word from ordinary, correction-free speech — measured through the shipping
// pipeline:
//
//   "Please hand it in in March."        -> "Please hand it in March."
//   "The show must go on on Friday."     -> "The show must go on Friday."
//   "What it is is a resourcing problem."-> "What it is a resourcing problem."
//
// Those doubles are grammatical (particle + preposition; the pseudo-cleft
// copula), so no context test can rescue them and they are simply gone, along
// with "at"/"it"/"i", which buy nothing a correction actually needs. What is
// left is the shape the rule was written for: "to to", "the the", and their
// kin, which only ever occur as an artifact of the deletion above — the pinned
// goldens ("go to the the store", "we need to to to fix it", "…to Bob no wait
// to Alice") all live in that shape.
//
// Content words are deliberately NOT collapsible either: "very very", "long
// long" and the corpus's "just just ship it" are all real speech, and the
// stutter-repair they want belongs to WispritRefine, which already owns it.
private let dupRx = Rx(#"\b(to|the|a|an|and|or|but|of|for|with)\s+\1\b"#)

/// The literal "no wait" (a queue with no waiting), signal one: the word the
/// span would delete. A copula, a possession verb or a preposition is never
/// what a correction replaces — "There IS no wait", "The clinic HAS no wait".
private let noWaitLiteralLeaders: Set<String> = [
    "is", "was", "are", "were", "be", "been", "being", "has", "have", "had",
    "with", "of", "there's", "theres", "that's", "thats", "here's", "heres",
]

/// The literal "no wait", signal two: a noun continuation after "wait". The
/// interjection is a complete utterance, so what follows it is the replacement
/// word, never a tail of the phrase itself — "no wait TIME", "no wait AT the
/// DMV", "no wait LIST". "to" is absent on purpose: "…to Bob no wait to Alice"
/// is the pinned parity golden.
private let noWaitObjectWords: Set<String> = [
    "time", "times", "list", "lists", "at", "for", "on", "in", "anywhere", "whatsoever",
]

/// Words that can open a two-token replacement fragment after a
/// cross-terminator marker ("No, actually, the footer." / "…next quarter.").
/// Determiners, possessives and the ordinal-ish modifiers — everything that
/// announces a noun phrase rather than a new subject.
private let fragmentOpeners: Set<String> = [
    "the", "a", "an", "this", "that", "these", "those", "another", "other", "same",
    "my", "your", "our", "their", "his", "her", "its",
    "next", "last", "first", "second", "third", "final", "every", "each", "any", "some",
    "half", "quarter", "no",
]

/// Words that make "no actually" / "I mean" a discourse hedge rather than a
/// correction. Deliberately small and function-word-only: anything a user would
/// actually be replacing ("Bob", "Thursday", "three") is a content word. The
/// one exception to function-word-only is the say-family: a marker DIRECTLY
/// after a verb of saying means the "no" was the thing said — "I said no,
/// actually, and I stand by it" is the speaker's answer, not a correction —
/// while a real correction after reported speech keeps its content leader
/// ("I said Bob no actually Alice" corrects on "Bob", never on "said").
private let hedgeLeaders: Set<String> = [
    "so", "well", "yeah", "yea", "yes", "no", "nope", "but", "and", "or",
    "ok", "okay", "like", "what", "that", "which", "who", "whom",
    "know", "see", "if", "then", "hey", "look", "right", "sure",
    "i", "you", "he", "she", "it", "we", "they",
    "say", "says", "said", "saying",
]

// MARK: - Clause-restart vocabulary

/// The pipeline's filler list as a set, for the restart tokenizer — a filler is
/// never restart evidence and never a compared token.
private let fillerSet = Set(fillerWords)

/// Edge punctuation stripped from a token before comparison. Inverted
/// alphanumerics so quotes, commas and terminators go while an interior
/// apostrophe ("let's") stays.
private let comparisonTrim = CharacterSet.alphanumerics.inverted

/// The function-word lexicon for the ONE-token restart rule: a single shared
/// token only counts as restart evidence when it is a content word — a name,
/// not a pronoun or determiner, because "I …" re-begins half the clauses in
/// English by accident. Two shared tokens are evidence regardless, so this
/// list only has to catch the words that open clauses on their own.
private let restartFunctionWords: Set<String> = hedgeLeaders.union([
    "the", "a", "an", "this", "these", "those", "there", "here",
    "to", "of", "in", "on", "at", "for", "with", "from", "by", "as",
    "is", "are", "was", "were", "be", "been", "am",
    "do", "does", "did", "have", "has", "had",
    "will", "would", "can", "could", "should", "shall", "may", "might", "must",
    "not", "my", "your", "our", "their", "his", "her", "its",
    "me", "him", "us", "them", "when", "where", "why", "how",
])

/// The closed-class vocabulary as an anchored probe — the rest of the engine's
/// "lexicon". A weekday or number shared by accident is not the restart
/// evidence a name is; those corrections belong to tier (a) and its classes.
private let closedClassWordRx = Rx("^(?:" + clockPattern + "|" + numberPattern + "|"
    + weekdayPattern + "|" + monthPattern + "|" + relativeDayPattern + ")$")
