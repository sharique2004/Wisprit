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
//   b. GENERAL MARKER. The Python rule ("no wait"), plus two new markers that
//      are unambiguous enough to work on any word: "no actually" and "I mean".
//      The replaced span is the Python span — the single word before the
//      marker, the marker, and the joint whitespace — with the duplicate
//      function word the deletion tends to leave behind ("… to Bob no wait to
//      Alice" -> "… to to Alice") collapsed afterwards, exactly as before.
//
// The two tiers are one regex and one sweep, not two passes, because tier (a)
// has to be able to *veto* tier (b): when both sides of a marker are
// closed-class items of DIFFERENT classes the correction does not type-check
// ("Thursday no actually 3 o'clock" — you cannot correct a weekday into a
// time), which is the definition of ambiguous, so the joint passes verbatim
// and no other rule gets a second look at it. The one marker exempt from that
// veto is "no wait": its behavior is a Python-parity contract pinned by
// `Goldens.swift`, so it keeps deleting whatever it is handed.

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
    /// marker in it costs three regex scans and returns the input unchanged.
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
        var text = correctJoints(text)
        // "scratch that" — keep only what follows the LAST occurrence (greedy).
        if scratchProbeRx.matches(text) {
            text = scratchRx.replacingAll(in: text, with: "")
        }
        // Repeat until stable so "to to to" fully collapses.
        while true {
            let collapsed = dupRx.replacingAll(in: text, with: "$1")
            if collapsed == text { break }
            text = collapsed
        }
        return text
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
                      isCorrection(marker, match, x, ns, xClass, yClass) {
                // Tier (b). The Python span: the single word before the marker,
                // the marker, and the joint whitespace. Y — which this pattern
                // consumed and the Python one never did — is re-emitted
                // verbatim, so the result is identical either way.
                let drop = lastTokenStart(x, ns)
                out += ns.substring(with: NSRange(location: cursor, length: drop - cursor))
                if y.location != NSNotFound { out += ns.substring(with: y) }
                next = match.range.location + match.range.length
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

    /// Whether a general marker may delete the word in front of it.
    private static func isCorrection(_ marker: GeneralMarker, _ m: NSTextCheckingResult,
                                     _ x: NSRange, _ ns: NSString,
                                     _ xClass: Int?, _ yClass: Int?) -> Bool {
        // Sentence-boundary veto, all general markers including "no wait": the
        // widened gap exists so a CLOSED-CLASS pair can survive the ASR's
        // hesitation period ("…Thursday, umm. No, actually Friday"). A general
        // marker reaching back across a real sentence ("…is fine. I mean it")
        // is not a correction — and Python's comma-only gap could never match
        // one, so refusing here is what parity actually means.
        let markerRange = m.range(at: markerGroup(for: marker))
        if markerRange.location != NSNotFound {
            let xEnd = x.location + x.length
            if markerRange.location > xEnd {
                let between = ns.substring(with: NSRange(location: xEnd,
                                                         length: markerRange.location - xEnd))
                if between.contains(where: { ".!?…".contains($0) }) { return false }
            }
        }
        // "no wait" is the Python marker; its span is a parity contract.
        guard marker != .noWait else { return true }
        // Cross-class veto — tier (a) looked at this joint and refused it.
        if xClass != nil, yClass != nil { return false }
        // Discourse-hedge veto: "no actually" and "I mean" are also ordinary
        // conversational filler ("so I mean we should go", "well no actually
        // that's fine", "what I mean is …"). A correction replaces a CONTENT
        // word, so a function word or interjection in front of the marker means
        // the user is talking, not correcting.
        if xClass == nil {
            let start = lastTokenStart(x, ns)
            let leader = ns.substring(with: NSRange(location: start,
                                                   length: x.location + x.length - start))
            if hedgeLeaders.contains(leader.lowercased()) { return false }
        }
        return true
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

    /// The capture-group index of a general marker — the inverse of
    /// `generalMarker(_:)`, for reading the matched marker's range back out.
    private static func markerGroup(for marker: GeneralMarker) -> Int {
        switch marker {
        case .noWait: return markerNoWait
        case .noActually: return markerNoActually
        case .iMean: return markerIMean
        }
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

private let monthPattern = alternation([
    "january", "february", "march", "april", "may", "june", "july",
    "august", "september", "october", "november", "december",
    "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sept", "sep", "oct", "nov", "dec",
])

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

// "scratch that" — keep only what follows the LAST occurrence (greedy).
private let scratchRx = Rx(#"^.*\bscratch\s+that\b[,.]?\s*"#,
                           [.caseInsensitive, .dotMatchesLineSeparators])
private let scratchProbeRx = Rx(#"\bscratch\s+that\b"#)
// Collapse an immediate duplicate of a function word, which self-correction can
// leave behind ("... to InsForge no wait to production" -> "... to to ...").
// Restricted to words whose consecutive repetition is virtually always an
// artifact — "that"/"had" are excluded because "that that"/"had had" are valid.
private let dupRx = Rx(#"\b(to|the|a|an|of|in|on|at|and|or|for|with|is|was|it|i)\s+\1\b"#)

/// Words that make "no actually" / "I mean" a discourse hedge rather than a
/// correction. Deliberately small and function-word-only: anything a user would
/// actually be replacing ("Bob", "Thursday", "three") is a content word.
private let hedgeLeaders: Set<String> = [
    "so", "well", "yeah", "yea", "yes", "no", "nope", "but", "and", "or",
    "ok", "okay", "like", "what", "that", "which", "who", "whom",
    "know", "see", "if", "then", "hey", "look", "right", "sure",
    "i", "you", "he", "she", "it", "we", "they",
]
