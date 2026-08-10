// Verbatim-first Tier-1 cleanup: deterministic, fast (<20 ms), no LLM.
//
// 1:1 port of wisprit/postprocess.py, plus one native-only stage the Python
// never had (#6, spoken emoji — docs/notes/deviations.md). The guiding
// principle — answering Wispr
// Flow's most common complaint that it *rewrites what you said* — is
// **conservatism**: only touch text when the intent is unambiguous. Anything
// uncertain passes through verbatim.
//
// Pipeline order (each stage is independent and defensively wrapped):
//
// 1. Filler removal — isolated um/uh/uhh/erm/uhm tokens only (config-gated).
// 2. Dictionary corrections — canonical-vocabulary substitutions.
// 3. Spoken email + URL joining — "a dot b at c dot com" -> "a.b@c.com".
// 4. Voice commands — "new line" / "new paragraph" and trailing punctuation
//    words ("period", "question mark" …).
// 5. Explicit self-correction — "X no wait Y" / "… scratch that Y" -> keep Y.
// 6. Spoken emoji — "fire emoji" -> 🔥 (config-gated). Same family as #4, one
//    step later: it runs AFTER self-correction on purpose, because the
//    noun-phrase guard treats "that" as a determiner, and "that" is also the
//    self-correction marker, so "nope scratch that fire emoji" only reads as a
//    directive once #5 has resolved it. See `applyEmoji`.
// 7. Whitespace / punctuation spacing cleanup.
// 8. Optional trailing period + configured leading-space policy.
//
// Deliberately **not** done: converting spelled-out numbers to digits. That is
// exactly the kind of surprising edit ("one more" -> "1 more") that erodes
// trust, so it is left to a future opt-in setting.

import Foundation
import WispritKit

// MARK: - Options

/// Config flags consumed by the pipeline; mirrors the three `settings` keys the
/// Python `process()` reads (`filler_removal`, `ensure_sentence_period`,
/// `leading_space`) plus one native-only key appended post-Python
/// (`emoji_commands`, docs/notes/deviations.md §"Spoken emoji directives").
public struct PostProcessOptions: Sendable, Equatable {
    /// Space before inserted text. Any unrecognized value behaves as `.auto`,
    /// matching the Python `_apply_leading_space` fall-through.
    public enum LeadingSpace: String, Sendable, Equatable, CaseIterable {
        case auto, always, never
    }

    public var fillerRemoval: Bool
    public var ensureSentencePeriod: Bool
    public var leadingSpace: LeadingSpace
    /// Spoken emoji directives ("fire emoji" -> 🔥). Post-Python addition, so it
    /// is the LAST init parameter: every existing call site keeps compiling.
    public var emojiCommands: Bool

    public init(fillerRemoval: Bool = true,
                ensureSentencePeriod: Bool = false,
                leadingSpace: LeadingSpace = .auto,
                emojiCommands: Bool = true) {
        self.fillerRemoval = fillerRemoval
        self.ensureSentencePeriod = ensureSentencePeriod
        self.leadingSpace = leadingSpace
        self.emojiCommands = emojiCommands
    }

    /// Mirrors the Python `settings.get(key)` signature the app context passes
    /// in: a missing or nil value falls back to the default, and a bogus
    /// `leading_space` string degrades to `.auto` rather than throwing.
    public init(settings get: (String) -> Any?) {
        func bool(_ key: String, _ fallback: Bool) -> Bool {
            switch get(key) {
            case let value as Bool: return value
            case let value as NSNumber: return value.boolValue
            case let value as String: return !value.isEmpty
            default: return fallback
            }
        }
        self.fillerRemoval = bool("filler_removal", true)
        self.ensureSentencePeriod = bool("ensure_sentence_period", false)
        self.leadingSpace = (get("leading_space") as? String).flatMap(LeadingSpace.init(rawValue:)) ?? .auto
        self.emojiCommands = bool("emoji_commands", true)
    }
}

// MARK: - Pipeline

public enum PostProcess {
    /// Run the full deterministic cleanup pipeline.
    ///
    /// `options` and `corrections` are optional so the function is trivially
    /// unit-testable; when omitted, filler removal is on, no dictionary
    /// corrections are applied, no trailing period is forced, and leading space
    /// is "auto". Never throws.
    public static func process(_ text: String?,
                               options: PostProcessOptions = PostProcessOptions(),
                               corrections: (any CorrectionApplying)? = nil) -> String {
        guard var text, !text.isEmpty else { return "" }

        if options.fillerRemoval { text = removeFillers(text) }
        text = applyDictionary(text, corrections)
        text = joinEmail(text)
        text = joinURL(text)
        text = voiceCommands(text)
        text = selfCorrect(text)
        if options.emojiCommands { text = applyEmoji(text) }
        text = cleanupWhitespace(text)
        if options.ensureSentencePeriod, let last = text.unicodeScalars.last,
           !Self.sentenceEnders.contains(last) {
            text += "."
        }
        text = applyLeadingSpace(text, options.leadingSpace)
        return text
    }

    private static let sentenceEnders = Set(".!?:\n".unicodeScalars)
}

// MARK: - Stage constants

// Fillers removed only as isolated, word-bounded tokens. Deliberately excludes
// "like", "so", "well", "you know" (context-free removal mangles meaning) and
// "err" (a real verb — "err on the side of caution").
private let fillerWords = ["um", "umm", "uh", "uhh", "uhm", "erm"]
private let fillerRx = Rx(#"(?<!\w)(?:"# + fillerWords.joined(separator: "|") + #")(?!\w)[,]?"#)

// Known TLDs for spoken-URL joining. Conservative list — real, common TLDs.
private let tlds = ["com", "org", "net", "io", "ai", "dev", "co", "edu", "gov", "app", "me"]
private let tldAlt = tlds.joined(separator: "|")

// Second-level domains where "<name> at <sld> dot <tld>" is almost certainly an
// email (freemail providers). For any other domain we require the local part to
// be explicitly dotted before turning "at" into "@" — otherwise "at" usually
// means "located at" ("visit my site at foo dot dev"), and we must not guess.
private let freemail: Set<String> = [
    "gmail", "googlemail", "yahoo", "ymail", "outlook", "hotmail", "live",
    "icloud", "me", "mac", "proton", "protonmail", "aol", "gmx", "zoho",
    "fastmail", "yandex", "msn", "pm",
]

// "<local> at <domain> dot <tld>" where each part may contain " dot " joiners.
private let emailRx = Rx(
    #"\b([a-z0-9]+(?:\s+dot\s+[a-z0-9]+)*)\s+at\s+"# +
    #"([a-z0-9]+(?:\s+dot\s+[a-z0-9]+)*\s+dot\s+(?:"# + tldAlt + #"))\b"#)

// "<host> dot <tld>", possibly chained ("sub dot example dot com").
private let urlRx = Rx(#"\b([a-z0-9]+(?:\s+dot\s+[a-z0-9]+)*)\s+dot\s+("# + tldAlt + #")\b"#)

private let dotJoinerRx = Rx(#"\s+dot\s+"#)

// Line-break voice commands. "new line"/"new paragraph" is dangerously common as
// ordinary speech ("a new line of business"), so we only treat it as a command
// when it is NOT part of a noun phrase — i.e. not preceded by a determiner and
// not followed by a word that continues the phrase grammatically.
private let lineBreakRx = Rx(#"(?:(\w+)\s+)?new\s+(line|paragraph)\b(?:\s+(\w+))?"#)
private let determiners: Set<String> = [
    "a", "an", "the", "this", "that", "another", "each", "every", "one",
    "my", "your", "our", "his", "her", "their", "its", "some", "any", "no",
]
private let continuations: Set<String> = [
    "of", "in", "on", "at", "to", "for", "with", "from", "by", "and", "or",
    "that", "which", "is", "was", "are", "were", "between", "through", "than",
]

// Trailing spoken punctuation ("... question mark" at the very end).
private let trailingPunct: [(Rx, String)] = [
    (Rx(#"\s+(?:question\s+mark)[.\s]*$"#), "?"),
    (Rx(#"\s+(?:exclamation\s+(?:point|mark))[.\s]*$"#), "!"),
    (Rx(#"\s+period[.\s]*$"#), "."),
    (Rx(#"\s+(?:full\s+stop)[.\s]*$"#), "."),
]

// Spoken emoji directives — "<name> emoji" -> the glyph. See
// `PostProcess.emojiTable` for the curated names and `applyEmoji` for the
// guards and the stage-ordering argument; the pieces live here, with the other
// voice-command constants, because the directive is one of them — it just runs
// one step later than the rest of the family.
//
// Two deliberate narrowings versus the other command regexes:
//   * the gaps are `[ \t]+`, not `\s+`, so a directive can never reach across a
//     line break stage 4 just inserted ("fire new line emoji" stays a break);
//   * `(?<!-)` keeps a hyphen-glued fragment ("re-fire emoji") out — the name
//     has to be a whole spoken word, which is also the first line of defense
//     against a spelled run.
// The leading word is captured ONLY to run the noun-phrase guard; unlike the
// line-break rewrite (where the break legitimately replaces the whitespace) it
// is re-emitted byte-for-byte with its gap, so the directive is a pure in-place
// substitution and surrounding spacing/punctuation survives untouched.
private let emojiNamePattern = PostProcess.emojiTable
    .map(\.name)
    // Longest first so "check mark emoji" beats "check", "one hundred emoji"
    // beats "hundred", "red heart emoji" beats "heart". Ties broken
    // alphabetically: `sorted` is not stable, and the pattern must be.
    .sorted { ($0.count, $1) > ($1.count, $0) }
    .map { $0.replacingOccurrences(of: " ", with: #"[ \t]+"#) }
    .joined(separator: "|")
private let emojiRx = Rx(#"(?:\b(\w+)([ \t]+))??(?<!-)\b("# + emojiNamePattern + #")[ \t]+emoji\b"#)
private let emojiByName: [String: String] = Dictionary(
    PostProcess.emojiTable.map { ($0.name, $0.glyph) }, uniquingKeysWith: { first, _ in first })
private let emojiSpaceRx = Rx(#"\s+"#)

// Words that turn the directive into a noun phrase: "the fire emoji", "a heart
// emoji", "that rocket emoji", "which fire emoji" — the user is TALKING ABOUT
// the emoji, so it stays verbatim. Reuses the line-break determiner set (the
// ambiguity is identical) plus interrogatives/demonstratives and the
// prepositions that make "emoji" the object of the sentence rather than an
// instruction to type one.
private let emojiSubjectMarkers: Set<String> = determiners.union([
    "which", "what", "whose", "these", "those", "such",
    "of", "about", "with", "without", "like", "for", "from", "by",
    "in", "on", "at", "to", "between", "using",
])

// A spelled run is an uppercase token of letters and separators — the same
// invariant `WispritRefine.RefineGuards.hasLetterRun` keys on (kept as a local
// copy: this module depends on WispritKit only). Post-corrections a run should
// never reach here, so this is an assertion rather than a workhorse: if the
// text around the match still looks spelled out, we do not touch it.
private let letterRunRx = Rx(#"^[A-Z][A-Z\-.]{2,}[A-Z]$"#, [])
private let letterRunEdgePunctuation =
    CharacterSet(charactersIn: ",.!?;:\"'\u{201C}\u{201D}\u{2018}\u{2019}()[]{}")

// Self-correction: drop the single word before "no wait" (+ the marker).
private let noWaitRx = Rx(#"\b[\w']+[,]?\s+no\s+wait[,]?\s+"#)
// "scratch that" — keep only what follows the LAST occurrence (greedy).
private let scratchRx = Rx(#"^.*\bscratch\s+that\b[,.]?\s*"#, [.caseInsensitive, .dotMatchesLineSeparators])
private let scratchProbeRx = Rx(#"\bscratch\s+that\b"#)
// Collapse an immediate duplicate of a function word, which self-correction can
// leave behind ("... to InsForge no wait to production" -> "... to to ...").
// Restricted to words whose consecutive repetition is virtually always an
// artifact — "that"/"had" are excluded because "that that"/"had had" are valid.
private let dupRx = Rx(#"\b(to|the|a|an|of|in|on|at|and|or|for|with|is|was|it|i)\s+\1\b"#)

// Space before sentence punctuation; multiple spaces.
private let spaceBeforePunctRx = Rx(#"\s+([,.;:!?])"#, [])
private let multiSpaceRx = Rx(#"[ \t]{2,}"#, [])
private let spaceAroundNewlineRx = Rx(#"[ \t]*\n[ \t]*"#, [])
private let manyNewlinesRx = Rx(#"\n{3,}"#, [])

// MARK: - Spoken emoji table

extension PostProcess {
    /// The curated spoken-emoji vocabulary, `(spoken name, glyph)`.
    ///
    /// **Closed by design.** An open "any emoji name" mapping would fire on
    /// ordinary speech; the point of the stage is that saying "fire emoji" is
    /// as explicit an instruction as saying "new line". Names are stored
    /// lowercase with single spaces — the compiled pattern relaxes the spaces
    /// and matches case-insensitively.
    ///
    /// Several names deliberately share a glyph (the recognizer's transcript
    /// depends on what the user actually said: "heart"/"red heart",
    /// "laughing"/"joy", "party"/"tada", "hundred"/"one hundred",
    /// "folded hands"/"pray"). Internal (not private) so the tests can assert
    /// the shipped table itself, which is the contract users learn.
    static let emojiTable: [(name: String, glyph: String)] = [
        ("fire", "🔥"),
        ("thumbs up", "👍"),
        ("thumbs down", "👎"),
        ("heart", "❤️"),
        ("red heart", "❤️"),
        ("rocket", "🚀"),
        ("check mark", "✅"),
        ("check", "✅"),
        ("cross mark", "❌"),
        ("laughing", "😂"),
        ("joy", "😂"),
        ("party", "🎉"),
        ("tada", "🎉"),
        ("eyes", "👀"),
        ("hundred", "💯"),
        ("one hundred", "💯"),
        ("clap", "👏"),
        ("folded hands", "🙏"),
        ("pray", "🙏"),
        ("thinking", "🤔"),
        ("smile", "😊"),
        ("wink", "😉"),
        ("sob", "😭"),
        ("skull", "💀"),
        ("warning", "⚠️"),
        ("star", "⭐"),
        ("sparkles", "✨"),
        ("muscle", "💪"),
        ("wave", "👋"),
        ("salute", "🫡"),
        ("handshake", "🤝"),
        ("light bulb", "💡"),
        ("bullseye", "🎯"),
    ]
}

// MARK: - Stages

extension PostProcess {
    static func removeFillers(_ text: String) -> String {
        fillerRx.replacingAll(in: text, with: "")
    }

    static func applyDictionary(_ text: String, _ corrections: (any CorrectionApplying)?) -> String {
        corrections?.applyCorrections(to: text) ?? text
    }

    /// Turn "a dot b dot c" into "a.b.c".
    static func joinDotted(_ phrase: String) -> String {
        dotJoinerRx.split(phrase)
            .map { $0.pythonStripped() }
            .filter { !$0.isEmpty }
            .joined(separator: ".")
    }

    static func joinEmail(_ text: String) -> String {
        emailRx.replacing(in: text) { m, ns in
            let localRaw = m.group(1, ns) ?? ""
            let domainRaw = m.group(2, ns) ?? ""
            let sld = (dotJoinerRx.split(domainRaw).first ?? "").pythonStripped().lowercased()
            let localIsDotted = dotJoinerRx.matches(localRaw)
            // Only turn "at" into "@" when we are confident it is an address:
            // either the local part was spelled with dots, or the domain is a
            // known freemail provider. Otherwise "at" is left alone (the URL
            // pass still joins the "<domain> dot <tld>" tail).
            guard localIsDotted || freemail.contains(sld) else { return nil }
            return "\(joinDotted(localRaw))@\(joinDotted(domainRaw))"
        }
    }

    static func joinURL(_ text: String) -> String {
        urlRx.replacing(in: text) { m, ns in
            let host = joinDotted(m.group(1, ns) ?? "")
            return "\(host).\((m.group(2, ns) ?? "").lowercased())"
        }
    }

    static func applyLineBreaks(_ text: String) -> String {
        lineBreakRx.replacing(in: text) { m, ns in
            let prev = m.group(1, ns)
            let kind = (m.group(2, ns) ?? "").lowercased()
            let next = m.group(3, ns)
            // Noun-phrase guards: "a new line of ...", "the new paragraph that ...".
            if let prev, determiners.contains(prev.lowercased()) { return nil }
            if let next, continuations.contains(next.lowercased()) { return nil }
            let brk = kind == "paragraph" ? "\n\n" : "\n"
            return (prev.map { $0 + " " } ?? "") + brk + (next.map { " " + $0 } ?? "")
        }
    }

    /// Spoken emoji: "<name> emoji" -> the glyph, for the curated
    /// `emojiTable` only. The word "emoji" is REQUIRED — a bare "fire" is
    /// speech, "fire emoji" is a directive — which is what keeps this in the
    /// same family as "new line" rather than the guessing the pipeline refuses
    /// to do.
    ///
    /// Two guards, both erring toward verbatim:
    ///  * a determiner / interrogative / preposition in front means the user is
    ///    *talking about* the emoji ("the fire emoji", "a heart emoji",
    ///    "an eyes emoji", "that fire emoji", "which fire emoji") — untouched;
    ///  * a spelled letter run overlapping the match ("F-I-R-E emoji", a glued
    ///    all-caps "FIRE EMOJI") is left alone, so the stage can never eat a
    ///    spelling the user dictated letter by letter.
    ///
    /// Position in the pipeline (stage 6), and why it is exactly there:
    ///  * it is an explicit spoken directive, so it belongs with "new line" and
    ///    the trailing punctuation words rather than off in a stage of its own —
    ///    it runs immediately after that family, gated by `emoji_commands`;
    ///  * after the dictionary (stage 2), so the user's own vocabulary has been
    ///    enforced on the words being read;
    ///  * after the word-shaped commands (stage 4), so every `\w`/`\b` pattern
    ///    there only ever sees the original words — a glyph substituted earlier
    ///    could silently perturb them;
    ///  * after self-correction (stage 5), because the guard word "that" is also
    ///    the "scratch that" marker: run earlier, "nope scratch that fire emoji"
    ///    reads as the noun phrase "that fire emoji", is (correctly, at that
    ///    point) left verbatim, and the user gets the literal words "fire emoji"
    ///    after the marker is stripped. Running here, self-correction resolves
    ///    first and the directive fires;
    ///  * before whitespace cleanup (stage 7), so that stage tidies the seam,
    ///    exactly as the line-break rewrite relies on.
    static func applyEmoji(_ text: String) -> String {
        emojiRx.replacing(in: text) { m, ns in
            let prev = m.group(1, ns)
            let gap = m.group(2, ns) ?? ""
            let name = m.group(3, ns) ?? ""
            if let prev, emojiSubjectMarkers.contains(prev.lowercased()) { return nil }
            if touchesLetterRun(m.range, ns) { return nil }
            // Unknown name is unreachable (the pattern is built from the table)
            // but stays a verbatim pass-through rather than a crash.
            guard let glyph = emojiByName[normalizedEmojiName(name)] else { return nil }
            return (prev ?? "") + gap + glyph
        }
    }

    /// Lowercase + single-space, so "Thumbs   Up" finds "thumbs up".
    static func normalizedEmojiName(_ raw: String) -> String {
        emojiSpaceRx.replacingAll(in: raw.lowercased(), with: " ")
    }

    /// True when any whitespace-delimited token overlapping `range` is a
    /// spelled run. The match is expanded to token boundaries first, so a
    /// separator-glued fragment is judged by the run it belongs to.
    static func touchesLetterRun(_ range: NSRange, _ ns: NSString) -> Bool {
        func isSpace(_ index: Int) -> Bool {
            guard let scalar = Unicode.Scalar(ns.character(at: index)) else { return false }
            return CharacterSet.whitespacesAndNewlines.contains(scalar)
        }
        var start = range.location
        var end = range.location + range.length
        while start > 0, !isSpace(start - 1) { start -= 1 }
        while end < ns.length, !isSpace(end) { end += 1 }
        let region = ns.substring(with: NSRange(location: start, length: end - start))
        return region.split(whereSeparator: { $0.isWhitespace }).contains {
            letterRunRx.matches(String($0).trimmingCharacters(in: letterRunEdgePunctuation))
        }
    }

    static func voiceCommands(_ text: String) -> String {
        var text = applyLineBreaks(text)
        for (pattern, punct) in trailingPunct {
            text = pattern.replacingAll(in: text, with: NSRegularExpression.escapedTemplate(for: punct))
        }
        return text
    }

    static func selfCorrect(_ text: String) -> String {
        var text = noWaitRx.replacingAll(in: text, with: "")
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

    static func cleanupWhitespace(_ text: String) -> String {
        var text = spaceAroundNewlineRx.replacingAll(in: text, with: "\n")
        text = spaceBeforePunctRx.replacingAll(in: text, with: "$1")
        text = multiSpaceRx.replacingAll(in: text, with: " ")
        // Collapse 3+ newlines to a paragraph break.
        text = manyNewlinesRx.replacingAll(in: text, with: "\n\n")
        return text.pythonStripped()
    }

    static func applyLeadingSpace(_ text: String, _ policy: PostProcessOptions.LeadingSpace) -> String {
        if text.isEmpty { return text }
        switch policy {
        case .always:
            return (text.hasPrefix(" ") || text.hasPrefix("\n")) ? text : " " + text
        case .never:
            return String(text.drop(while: { $0 == " " }))
        case .auto:
            return text  // leave as produced (already stripped)
        }
    }
}

// MARK: - Regex plumbing

/// Thin wrapper over NSRegularExpression with Python-`re`-shaped operations.
/// A pattern that fails to compile degrades to a no-op, preserving the Python
/// contract that `process()` never raises.
private struct Rx {
    private let re: NSRegularExpression?

    init(_ pattern: String, _ options: NSRegularExpression.Options = [.caseInsensitive]) {
        re = try? NSRegularExpression(pattern: pattern, options: options)
    }

    func matches(_ s: String) -> Bool {
        guard let re else { return false }
        return re.firstMatch(in: s, options: [], range: NSRange(location: 0, length: (s as NSString).length)) != nil
    }

    func replacingAll(in s: String, with template: String) -> String {
        guard let re else { return s }
        return re.stringByReplacingMatches(
            in: s, options: [], range: NSRange(location: 0, length: (s as NSString).length),
            withTemplate: template)
    }

    /// `re.sub` with a callable replacement; returning nil keeps the match
    /// verbatim (the Python `return m.group(0)` escape hatch).
    func replacing(in s: String, _ body: (NSTextCheckingResult, NSString) -> String?) -> String {
        guard let re else { return s }
        let ns = s as NSString
        var out = ""
        var cursor = 0
        for m in re.matches(in: s, options: [], range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            out += body(m, ns) ?? ns.substring(with: m.range)
            cursor = m.range.location + m.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }

    /// `re.split` on a group-less pattern.
    func split(_ s: String) -> [String] {
        guard let re else { return [s] }
        let ns = s as NSString
        var parts: [String] = []
        var cursor = 0
        for m in re.matches(in: s, options: [], range: NSRange(location: 0, length: ns.length)) {
            parts.append(ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor)))
            cursor = m.range.location + m.range.length
        }
        parts.append(ns.substring(from: cursor))
        return parts
    }
}

private extension NSTextCheckingResult {
    func group(_ index: Int, _ ns: NSString) -> String? {
        guard index < numberOfRanges else { return nil }
        let r = range(at: index)
        return r.location == NSNotFound ? nil : ns.substring(with: r)
    }
}

private extension String {
    /// Python `str.strip()`: trims every scalar for which `str.isspace()` is
    /// true. Foundation's `.whitespacesAndNewlines` omits U+001C…U+001F, which
    /// Python treats as whitespace, so the set is spelled out.
    func pythonStripped() -> String {
        let isSpace: (Unicode.Scalar) -> Bool = { u in
            switch u.value {
            case 0x09...0x0D, 0x1C...0x20, 0x85, 0xA0, 0x1680,
                 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000:
                return true
            default:
                return false
            }
        }
        var scalars = Substring.UnicodeScalarView(unicodeScalars)
        while let f = scalars.first, isSpace(f) { scalars.removeFirst() }
        while let l = scalars.last, isSpace(l) { scalars.removeLast() }
        return String(String.UnicodeScalarView(scalars))
    }
}
