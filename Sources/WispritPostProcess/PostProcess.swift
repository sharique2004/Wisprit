// Verbatim-first Tier-1 cleanup: deterministic, fast (<20 ms), no LLM.
//
// 1:1 port of wisprit/postprocess.py. The guiding principle — answering Wispr
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
// 6. Whitespace / punctuation spacing cleanup.
// 7. Optional trailing period + configured leading-space policy.
//
// Deliberately **not** done: converting spelled-out numbers to digits. That is
// exactly the kind of surprising edit ("one more" -> "1 more") that erodes
// trust, so it is left to a future opt-in setting.

import Foundation
import WispritKit

// MARK: - Options

/// Config flags consumed by the pipeline; mirrors the three `settings` keys the
/// Python `process()` reads (`filler_removal`, `ensure_sentence_period`,
/// `leading_space`).
public struct PostProcessOptions: Sendable, Equatable {
    /// Space before inserted text. Any unrecognized value behaves as `.auto`,
    /// matching the Python `_apply_leading_space` fall-through.
    public enum LeadingSpace: String, Sendable, Equatable, CaseIterable {
        case auto, always, never
    }

    public var fillerRemoval: Bool
    public var ensureSentencePeriod: Bool
    public var leadingSpace: LeadingSpace

    public init(fillerRemoval: Bool = true,
                ensureSentencePeriod: Bool = false,
                leadingSpace: LeadingSpace = .auto) {
        self.fillerRemoval = fillerRemoval
        self.ensureSentencePeriod = ensureSentencePeriod
        self.leadingSpace = leadingSpace
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
