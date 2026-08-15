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
// 5. Explicit self-correction — "X no wait Y" / "… scratch that Y" -> keep Y,
//    plus the closed-class pair rule ("Thursday no actually Friday" -> Friday).
//    The engine lives in SelfCorrection.swift because the live path runs it on
//    raw partials too; this stage is just its finalize-path caller.
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
    /// Text immediately before the caret, when context awareness read a field.
    /// Empty means "no context" — casing and leading space stay as produced.
    public var precedingText: String
    /// Frontmost bundle id, used for messaging-style trailing-period removal.
    public var frontmostBundleID: String
    /// Strip a trailing "press enter" command and report it on the result.
    public var pressEnterEnabled: Bool
    /// Wispr-style Smart Formatting: mid-utterance punctuation, lists, extra
    /// line-break aliases. Default OFF so the Python goldens / fuzz stay a
    /// differential net; the app opts in.
    public var smartFormatting: Bool

    public init(fillerRemoval: Bool = true,
                ensureSentencePeriod: Bool = false,
                leadingSpace: LeadingSpace = .auto,
                emojiCommands: Bool = true,
                precedingText: String = "",
                frontmostBundleID: String = "",
                pressEnterEnabled: Bool = true,
                smartFormatting: Bool = false) {
        self.fillerRemoval = fillerRemoval
        self.ensureSentencePeriod = ensureSentencePeriod
        self.leadingSpace = leadingSpace
        self.emojiCommands = emojiCommands
        self.precedingText = precedingText
        self.frontmostBundleID = frontmostBundleID
        self.pressEnterEnabled = pressEnterEnabled
        self.smartFormatting = smartFormatting
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
        self.precedingText = (get("preceding_text") as? String) ?? ""
        self.frontmostBundleID = (get("frontmost_bundle_id") as? String) ?? ""
        self.pressEnterEnabled = bool("press_enter", true)
        self.smartFormatting = bool("smart_formatting", false)
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
        processResult(text, options: options, corrections: corrections).text
    }

    /// Full result, including whether a trailing "press enter" command fired.
    public static func processResult(_ text: String?,
                                     options: PostProcessOptions = PostProcessOptions(),
                                     corrections: (any CorrectionApplying)? = nil) -> PostProcessResult {
        guard var text, !text.isEmpty else { return PostProcessResult(text: "") }

        if options.fillerRemoval { text = removeFillers(text) }
        text = applyDictionary(text, corrections)
        text = joinEmail(text)
        text = joinURL(text)
        text = voiceCommands(text)
        if options.smartFormatting {
            text = SmartFormat.applyLineBreakAliases(text)
        }
        text = selfCorrect(text)
        // Emoji before spoken punctuation so "star emoji" stays a glyph
        // and is not rewritten as "* emoji" by the asterisk rule.
        if options.emojiCommands { text = applyEmoji(text) }
        if options.smartFormatting {
            text = SmartFormat.applySpokenPunctuation(text)
            text = SmartFormat.applyLists(text)
        }
        text = cleanupWhitespace(text)
        var pressEnter = false
        if options.pressEnterEnabled, options.smartFormatting {
            (text, pressEnter) = SmartFormat.consumePressEnter(text)
        }
        if options.ensureSentencePeriod, !text.isEmpty, let last = text.unicodeScalars.last,
           !Self.sentenceEnders.contains(last) {
            text += "."
        }
        if !options.precedingText.isEmpty {
            text = SmartFormat.applyContextFit(text, preceding: options.precedingText)
        } else {
            text = applyLeadingSpace(text, options.leadingSpace)
        }
        text = SmartFormat.applyMessagingPeriod(text, bundleID: options.frontmostBundleID)
        return PostProcessResult(text: text, pressEnter: pressEnter)
    }

    private static let sentenceEnders = Set(".!?:\n".unicodeScalars)
}

// MARK: - Stage constants

// Fillers removed only as isolated, word-bounded tokens. Deliberately excludes
// "like", "so", "well", "you know" (context-free removal mangles meaning) and
// "err" (a real verb — "err on the side of caution").
// Internal, not private: SelfCorrection.swift compiles the same vocabulary into
// its joint separator, because the live path hands that engine text this stage
// has not run on yet.
let fillerWords = ["um", "umm", "uh", "uhh", "uhm", "erm"]

// The boundary is `[\w-]`, not `\w`, on both sides. A hyphen is a non-word
// character, so the Python-parity `(?<!\w)…(?!\w)` treated the two halves of a
// hyphenated word as separate tokens and ate one of them: "Uh-oh that broke the
// build." measured as "-oh that broke the build." A hyphen glues a word
// together everywhere else in this file (`emojiRx` already spells the same
// guard), and "uh-oh"/"uh-huh" are words, not hesitations.
private let fillerRx = Rx(#"(?<![\w-])(?:"# + fillerWords.joined(separator: "|") + #")(?![\w-])[,]?"#)
private let fillerEdgePunctuation = CharacterSet(charactersIn: ",")

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
//
// The lookback is TWO words, captured verbatim as one prefix (so the original
// spacing survives a rewrite), because one word only sees the modifier: "a
// brand new line", "a whole new paragraph" put the determiner two back, and
// both measured as a line break jammed into the middle of a sentence ("We are
// launching a brand\nnext quarter."). A determiner two back only counts when
// the word between it and "new" is a pre-nominal modifier — "the total new
// line item two" is still a dictated break, and only an adjective in that slot
// makes "new line" the head of the phrase instead.
private let lineBreakRx = Rx(#"((?:\w+\s+){0,2})new\s+(line|paragraph)\b(?:\s+(\w+))?"#)
private let determiners: Set<String> = [
    "a", "an", "the", "this", "that", "another", "each", "every", "one",
    "my", "your", "our", "his", "her", "their", "its", "some", "any", "no",
]
// Modifiers that sit between a determiner and "new" in a noun phrase. Small and
// measured: "brand"/"whole" are the two the corpus produced, the rest are the
// intensifiers and size adjectives that take the same slot.
private let nounPhraseModifiers: Set<String> = [
    "brand", "whole", "entire", "completely", "totally", "really", "very", "all",
    "single", "big", "long", "short", "blank", "extra", "bold", "straight", "solid",
    "thin", "same", "other",
]
private let continuations: Set<String> = [
    "of", "in", "on", "at", "to", "for", "with", "from", "by", "and", "or",
    "that", "which", "is", "was", "are", "were", "between", "through", "than",
    // "about" completes the preposition family the list already carries — it
    // was simply missing, and "he started a whole new paragraph ABOUT pricing"
    // is what missing cost. "into"/"onto" are "in"/"on" with directional
    // morphology and can no more open a dictated continuation than those can.
    //
    // "next" is deliberately NOT here, even though the other measured sentence
    // ("a brand new line NEXT quarter") ends that way: "new line next up" is a
    // pinned command shape, so "next" is genuinely ambiguous after the phrase
    // and the determiner lookback above is what stops that sentence instead.
    "about", "into", "onto",
]

// Trailing spoken punctuation ("... question mark" at the very end).
//
// The spoken names are also ordinary nouns, and the unguarded rewrite deleted
// the noun and everything the sentence needed it for — measured: "We billed
// them for the trial period." -> "We billed them for the trial.", "Add a grace
// period" -> "Add a grace.", "She answered every question mark" -> "She
// answered every?" So each rule captures the (up to two) words in front of the
// name, verbatim, and refuses when they make the name the HEAD of a noun
// phrase rather than a dictated punctuation mark.
//
// The guard is on the IMMEDIATELY preceding word only. A determiner two back
// was the tempting rule and it is wrong: "that is the end period" is a pinned
// golden with exactly that shape, and it is a command. What separates it from
// "the trial period" is the collocation, not the determiner.
private struct TrailingPunctRule {
    let rx: Rx
    let punct: String
    /// Words that make the spoken name a noun. A match whose immediately
    /// preceding word is one of these passes through verbatim.
    let blockedLeaders: Set<String>
}

/// "<det> period" is always the noun ("the period", "a period"), and these are
/// the noun-noun compounds where the second word is the head: a trial period,
/// a grace period, a notice period. Business-dictation frequency ordered.
private let periodCollocations: Set<String> = determiners.union([
    "trial", "grace", "notice", "waiting", "cooling", "probation", "probationary",
    "time", "rest", "class", "free", "lunch", "question", "warranty", "billing",
    "blackout", "refund", "vesting", "transition", "pay", "sales", "holding", "quiet",
])

/// "<det/quantifier> question mark" is the noun phrase — "every question mark",
/// "the question mark". A dictated "question mark" follows the clause it
/// terminates, which never ends in a determiner.
private let questionCollocations: Set<String> = determiners.union([
    "these", "those", "which", "what", "whose", "first", "second", "third", "next", "last",
])

private let trailingPunct: [TrailingPunctRule] = [
    TrailingPunctRule(rx: Rx(#"((?:\w+\s+){0,2})question\s+mark[.\s]*$"#), punct: "?",
                      blockedLeaders: questionCollocations),
    TrailingPunctRule(rx: Rx(#"((?:\w+\s+){0,2})exclamation\s+(?:point|mark)[.\s]*$"#), punct: "!",
                      blockedLeaders: determiners),
    TrailingPunctRule(rx: Rx(#"((?:\w+\s+){0,2})period[.\s]*$"#), punct: ".",
                      blockedLeaders: periodCollocations),
    TrailingPunctRule(rx: Rx(#"((?:\w+\s+){0,2})full\s+stop[.\s]*$"#), punct: ".",
                      blockedLeaders: periodCollocations),
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

// Self-correction lives in SelfCorrection.swift — the markers, the closed-class
// pair rule and the duplicate collapse are all one engine there, because the
// live path needs to run it on raw partials without the rest of the pipeline.

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
    /// Stage 1. An all-caps token is an acronym, not a hesitation: the
    /// recognizer writes the hesitation as "um"/"Um", and "UH"/"UM" are
    /// universities ("She transferred to UH last fall." measured as "She
    /// transferred to last fall."). The exemption is exact-case, so "Um," at
    /// the start of a sentence — the shape the recognizer actually emits — is
    /// still a filler.
    static func removeFillers(_ text: String) -> String {
        fillerRx.replacing(in: text) { m, ns in
            let token = ns.substring(with: m.range)
                .trimmingCharacters(in: fillerEdgePunctuation)
            return token == token.uppercased() ? nil : ""
        }
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
            // The prefix is re-emitted byte-for-byte (its own inter-word
            // spacing included); only the whitespace the break replaces is
            // normalized, exactly as the one-word version did.
            let prefix = m.group(1, ns) ?? ""
            let words = prefix.split(whereSeparator: { $0.isWhitespace }).map { $0.lowercased() }
            let kind = (m.group(2, ns) ?? "").lowercased()
            let next = m.group(3, ns)
            // Noun-phrase guards: "a new line of ...", "the new paragraph that
            // ...", "a brand new line ...".
            if let near = words.last, determiners.contains(near) { return nil }
            if words.count == 2, determiners.contains(words[0]),
               nounPhraseModifiers.contains(words[1]) { return nil }
            if let next, continuations.contains(next.lowercased()) { return nil }
            let brk = kind == "paragraph" ? "\n\n" : "\n"
            return prefix + brk + (next.map { " " + $0 } ?? "")
        }
    }

    /// Trailing spoken punctuation, with the noun-phrase guard described at
    /// `trailingPunct`. Beyond the guard this is the Python rule: the name has
    /// to be preceded by whitespace (a bare "period" is the word, not a
    /// command) and it takes the trailing dots and spaces with it.
    static func applyTrailingPunctuation(_ text: String) -> String {
        var text = text
        for rule in trailingPunct {
            text = rule.rx.replacing(in: text) { m, ns in
                let prefix = m.group(1, ns) ?? ""
                let words = prefix.split(whereSeparator: { $0.isWhitespace }).map { $0.lowercased() }
                if let near = words.last, rule.blockedLeaders.contains(near) { return nil }
                // No captured word means the name opens the match: it is only a
                // command if whitespace stands in front of it (Python's `\s+`).
                guard !words.isEmpty || (m.range.location > 0
                    && Self.isSpace(ns.character(at: m.range.location - 1))) else { return nil }
                return prefix.trimmingTrailingWhitespace() + rule.punct
            }
        }
        return text
    }

    static func isSpace(_ c: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(c) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
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
        applyTrailingPunctuation(applyLineBreaks(text))
    }

    /// Stage 5. Unconditional, like the Python rule it ports — self-correction
    /// has no settings key of its own, so the closed-class tier does not get
    /// one either: it is the same product surface, not a new one.
    static func selfCorrect(_ text: String) -> String {
        SelfCorrection.apply(text)
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
/// contract that `process()` never raises. Internal, not private, so
/// SelfCorrection.swift shares one piece of regex plumbing with the pipeline.
struct Rx {
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

    /// Every non-overlapping match, left to right — the scanning primitive for
    /// a stage that has to CHOOSE among the matches (which "scratch that" is
    /// the directive) rather than rewrite each one where it stands.
    func allMatches(_ s: String, _ ns: NSString) -> [NSTextCheckingResult] {
        guard let re else { return [] }
        return re.matches(in: s, options: [], range: NSRange(location: 0, length: ns.length))
    }

    /// Leftmost match at or after `from`. The text before `from` stays visible
    /// to `\b` and lookbehind (transparent, non-anchoring bounds), so a cursor
    /// parked mid-word cannot manufacture a word boundary — the scanning
    /// primitive `SelfCorrection` drives its sweep with.
    func firstMatch(_ s: String, _ ns: NSString, from: Int) -> NSTextCheckingResult? {
        guard let re, from >= 0, from <= ns.length else { return nil }
        return re.firstMatch(in: s, options: [.withTransparentBounds, .withoutAnchoringBounds],
                             range: NSRange(location: from, length: ns.length - from))
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
    /// Right-strip only — the trailing-punctuation stage re-emits the words in
    /// front of a spoken mark verbatim but drops the gap the mark replaces.
    func trimmingTrailingWhitespace() -> String {
        var scalars = Substring.UnicodeScalarView(unicodeScalars)
        while let last = scalars.last,
              CharacterSet.whitespacesAndNewlines.contains(last) { scalars.removeLast() }
        return String(String.UnicodeScalarView(scalars))
    }

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
