import Foundation
import WispritKit

/// The deterministic half of the cage — a 1:1 port of the module-level guards in
/// `wisprit/refine.py`. Pure, synchronous, and the only thing standing between
/// the 3B model's measured failure modes (answering the dictation, summarizing,
/// inventing wrappers, leaking preambles, mangling addresses and spelled runs)
/// and the user's text field.
public enum RefineGuards {

    // MARK: - patterns

    /// A leaked meta-preamble line before the real output. Deliberately shaped
    /// like the model narrating ("here's the cleaned transcript:", "Corrected
    /// text:") — a bare keyword is NOT enough, so dictated headings like
    /// "Transcript review notes:" or "Here is the plan:" survive.
    static let preamble = regex(
        #"^(?:[^\n]{0,40}\bhere(?:'s| is)\b[^\n]{0,40}\b(?:transcript|text|version|output)\b[^\n]{0,20}"#
            + #"|[^\n]{0,40}\b(?:cleaned|corrected)\s+(?:transcript|text|version|output)\b[^\n]{0,20})"#
            + #":\s*\n+"#,
        [.caseInsensitive])

    // Invented wrappers the small model sometimes adds despite instructions
    // (widely reported): markdown fences, a single XML-ish tag pair, full quotes.
    static let fence = regex(#"^```[a-z]*\n(.*?)\n?```$"#, [.dotMatchesLineSeparators])
    static let tagPair = regex(#"^<([a-z_-]{1,32})>\s*(.*?)\s*</\1>$"#,
                               [.dotMatchesLineSeparators, .caseInsensitive])
    static let quotePairs: [Character: Character] = ["\"": "\"", "'": "'", "\u{201C}": "\u{201D}",
                                                     "\u{2018}": "\u{2019}"]

    /// Mirrors `postprocess._TLDS`. WispritRefine may not depend on
    /// WispritPostProcess (one module per agent), so the list is duplicated —
    /// keep the two in sync; `AddressGuardTests` pins it against the Python.
    static let tlds = ["com", "org", "net", "io", "ai", "dev", "co", "edu", "gov", "app", "me"]
    static let tldAlt = tlds.joined(separator: "|")

    /// Utterances containing addresses skip AI entirely: the model eats spoken
    /// "dot"/"at" joiners before postprocess can assemble them, and capitalizes
    /// already-formed addresses ("john.smith@…" → "John.Smith@…") — both
    /// measured. Addresses are rare and highly structured; the deterministic
    /// joiners own them.
    static let formedAddress = regex(
        #"(?:@|https?://|\bwww\.|\b[a-z0-9-]+\.(?:"# + tldAlt + #")\b)"#, [.caseInsensitive])
    static let spokenEmail = regex(
        #"\b([a-z0-9]+(?:\s+dot\s+[a-z0-9]+)*)\s+at\s+"#
            + #"([a-z0-9]+(?:\s+dot\s+[a-z0-9]+)*\s+dot\s+(?:"# + tldAlt + #"))\b"#,
        [.caseInsensitive])
    static let spokenURL = regex(
        #"\b([a-z0-9]+(?:\s+dot\s+[a-z0-9]+)*)\s+dot\s+("# + tldAlt + #")\b"#, [.caseInsensitive])

    /// Spelled letter runs, matched against ONE whitespace-delimited token.
    /// Case-SENSITIVE: research measured that the stable invariant is uppercase,
    /// not the hyphen — SpeechTranscriber's ITN emits "S. H. A. R. I. Q. U. E."
    /// as `S-H-A-R-I-Q-U-E`, `S-HA-R-I-Q-U-E`, `S H-A-R-I-Q-U-E` or glued
    /// `SHIRIQUE` depending on delivery. Space-broken runs are covered because
    /// the caller tokenizes first; matching per token (rather than over the raw
    /// string) is what keeps `COVID-19` and `AB1` out — a run is only a run when
    /// the WHOLE token is letters and separators.
    static let letterRun = regex(#"^[A-Z][A-Z\-.]{2,}[A-Z]$"#, [])

    /// Sentence punctuation trimmed off a token before it is scored. `.` is both
    /// a sentence ender and an observed in-run separator, so it is trimmed at
    /// the edges and stripped in the middle.
    static let runEdgePunctuation =
        CharacterSet(charactersIn: ",.!?;:\"'\u{201C}\u{201D}\u{2018}\u{2019}()[]{}")

    /// An output that *starts* like an assistant reply means the model answered
    /// the dictation instead of cleaning it — the whole output is untrustworthy.
    static let assistantPrefix = regex(
        #"^(?:here(?:'s| is)\b|certainly\b|sure[,!]|of course\b|i'm sorry\b|"#
            + #"i am sorry\b|sorry[, ]|as an ai\b|i can(?:'t|not) help\b|great question\b|"#
            + #"you're welcome\b|you are welcome\b|happy to help\b|glad to help\b|"#
            + #"how can i (?:help|assist)\b|great[,!] |no problem[,!.])"#,
        [.caseInsensitive])

    /// Words ignored when comparing the utterance's opening word — the model is
    /// *supposed* to delete these, so they can't anchor the identity check.
    static let leadFillers: Set<String> = ["um", "umm", "uh", "uhh", "uhm", "erm", "hmm",
                                           "so", "okay", "ok", "well", "and", "like"]

    static let wordPunctuation = CharacterSet(charactersIn: ".,!?\"'\u{201C}\u{201D}\u{2018}\u{2019}")

    // MARK: - skips

    public static func hasAddress(_ raw: String) -> Bool {
        matches(formedAddress, raw) || matches(spokenEmail, raw) || matches(spokenURL, raw)
    }

    /// True when the utterance contains a spelled-out letter run, which must
    /// bypass the model: measured, refine turns `S-H-A-R-I-Q-U-E` into
    /// "Sharifue" non-deterministically, which would silently break the spoken
    /// spelling-correction feature. Semantics are deliberately the same shape as
    /// WispritCorrections' detector (uppercase run, separators stripped,
    /// collapsed length ≥ 3, alphabetic segments, not already a known term) so
    /// the two stages never disagree about what an utterance is.
    ///
    /// Deliberately liberal: a genuine 4+ letter acronym ("JSON") also bypasses.
    /// Skipping cleanup costs polish; refining a spelled run costs the user's
    /// name — verbatim wins on any doubt.
    public static func hasLetterRun(_ raw: String, vocabulary: VocabularySource? = nil) -> Bool {
        for token in raw.split(whereSeparator: { $0.isWhitespace }) {
            let bare = String(token).trimmingCharacters(in: runEdgePunctuation)
            guard matchesAtStart(letterRun, bare) else { continue }
            let collapsed = bare.filter { $0 != "-" && $0 != "." }
            guard collapsed.count >= 3 else { continue }
            // Separators mean the letters were dictated one by one — a spelled
            // run, bypassed even when the word is already known (the model
            // corrupts the RUN, not the dictionary). A glued all-caps token is
            // formally identical to an acronym, so there the vocabulary decides.
            let spelledOut = bare.contains("-") || bare.contains(".")
            if !spelledOut, vocabulary?.isKnownTerm(collapsed) == true { continue }
            return true
        }
        return false
    }

    /// Word count that stays meaningful for space-free scripts (CJK locales),
    /// where whitespace splitting sees one giant token; budgets/timeouts use it.
    public static func estimatedWords(_ raw: String) -> Int {
        // `raw.unicodeScalars.count` is Python's `len(str)` (code points).
        max(wordCount(raw), raw.unicodeScalars.count / 6)
    }

    // MARK: - output laundering

    /// Deterministically peel meta-preambles and invented wrappers.
    ///
    /// Runs to a fixpoint (≤3 passes) because the failure modes compose — a
    /// preamble line followed by fenced content was observed as two separate
    /// modes and can co-occur.
    public static func stripWrappers(_ text: String) -> String {
        var out = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for _ in 0..<3 {
            let previous = out
            out = replaceFirst(preamble, in: out, with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            out = unwrapOnce(out)
            if out == previous { break }
        }
        return out
    }

    static func unwrapOnce(_ out: String) -> String {
        if let inner = capture(fence, in: out, group: 1) {
            return inner.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let inner = capture(tagPair, in: out, group: 2) {
            return inner.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if out.count >= 2, let opening = out.first, let closing = quotePairs[opening],
           out.last == closing {
            let inner = String(out.dropFirst().dropLast())
            // Only a true full wrap: the same quote chars inside mean the quotes
            // are dialogue punctuation, not a wrapper.
            if !inner.contains(opening) && !inner.contains(closing) {
                return inner.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return out
    }

    /// True when `refined` is plausibly the same utterance as `raw`.
    ///
    /// Cleanup only removes fillers/stutters and fixes words, so the output word
    /// count stays close to the input's. A big shrink means the model summarized
    /// or dropped sentences; a big growth means it answered or hallucinated.
    /// Both observed in testing — both must fall back to verbatim. An output
    /// that opens like an assistant reply ("Sure, here's…") is rejected
    /// outright, and tiny inputs get almost no growth slack — "thank you" must
    /// never come back as "You're welcome! Happy to help.".
    public static func plausible(raw: String, refined: String) -> Bool {
        if refined.isEmpty { return false }
        if matchesAtStart(assistantPrefix, refined) {
            // Only damning when the speaker didn't open that way themselves
            // ("um so sorry I missed your call" must still be cleanable).
            if firstContentWord(raw) != firstContentWord(refined) { return false }
        }
        let nRaw = wordCount(raw)
        let nRef = wordCount(refined)
        let lower = Int(Double(nRaw) * 0.4)
        let upper = Int(Double(nRaw) * 1.2) + (nRaw < 6 ? 2 : 8)
        return lower <= nRef && nRef <= upper
    }

    static func firstContentWord(_ text: String) -> String {
        for word in text.split(whereSeparator: { $0.isWhitespace }) {
            let bare = String(word)
                .trimmingCharacters(in: wordPunctuation)
                .lowercased()
            if !bare.isEmpty && !leadFillers.contains(bare) { return bare }
        }
        return ""
    }

    // MARK: - regex plumbing

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    static func regex(_ pattern: String, _ options: NSRegularExpression.Options)
        -> NSRegularExpression {
        // Patterns are compile-time literals; a throw here is a programmer error.
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    static func matches(_ re: NSRegularExpression, _ text: String) -> Bool {
        re.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length))
            != nil
    }

    /// Python's `re.match`: anchored at the start, not a full match.
    static func matchesAtStart(_ re: NSRegularExpression, _ text: String) -> Bool {
        guard let m = re.firstMatch(in: text, options: [.anchored],
                                    range: NSRange(location: 0, length: (text as NSString).length))
        else { return false }
        return m.range.location == 0
    }

    static func capture(_ re: NSRegularExpression, in text: String, group: Int) -> String? {
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              m.range(at: group).location != NSNotFound else { return nil }
        return ns.substring(with: m.range(at: group))
    }

    static func replaceFirst(_ re: NSRegularExpression, in text: String, with template: String)
        -> String {
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length))
        else { return text }
        return ns.replacingCharacters(in: m.range, with: template)
    }
}
