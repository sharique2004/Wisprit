// Wispr Flow–style Smart Formatting: spoken punctuation mid-utterance,
// numbered lists from sequence words, extra line-break aliases, trailing
// "press enter", and context-aware casing / messaging-period policy.
//
// Lives beside `PostProcess` rather than inside it so the Python-parity
// stages stay a 1:1 port. Every rule here is new, native-only behavior
// (the `EmojiCommandTests` precedent): goldens / fuzz stay literal Python
// output, and these stages must be inert on that speech.
//
// Conservatism is the same contract as the rest of the pipeline. A
// punctuation name that is the head of a noun phrase ("the comma splice",
// "trial period") is left verbatim. A lone "one" / "first" is not a list.
// "Press enter" mid-sentence is content. Messaging trailing-period removal
// is short dictations in a closed native-app list only.

import Foundation

public struct PostProcessResult: Sendable, Equatable {
    public var text: String
    public var pressEnter: Bool

    public init(text: String, pressEnter: Bool = false) {
        self.text = text
        self.pressEnter = pressEnter
    }
}

enum SmartFormat {

    // MARK: - Spoken punctuation (mid-utterance)

    /// Replace spoken punctuation names with the mark, anywhere they are
    /// clearly a command and not a noun. Trailing "period" / "question mark"
    /// / "exclamation point" stay in `PostProcess.applyTrailingPunctuation`
    /// so those goldens do not move; this stage covers the rest of Flow's
    /// list and mid-sentence uses of the same names.
    static func applySpokenPunctuation(_ text: String) -> String {
        var text = text
        for rule in punctRules {
            text = rule.rx.replacing(in: text) { m, ns in
                let prefix = m.group(1, ns) ?? ""
                let next = m.group(2, ns)
                let words = prefix.split(whereSeparator: { $0.isWhitespace })
                    .map { $0.lowercased() }
                if let near = words.last, rule.blockedLeaders.contains(near) { return nil }
                if let next, rule.blockedTrailers.contains(next.lowercased()) { return nil }
                // A name that opens the match still needs whitespace in front
                // (or the start of the string) so "period" inside "periodic"
                // can never fire — the pattern already word-bounds, this is
                // the command-vs-mention seam.
                if words.isEmpty, m.range.location > 0,
                   !PostProcess.isSpace(ns.character(at: m.range.location - 1)) {
                    return nil
                }
                // The next word is lookahead-only (trailer guard), so the
                // original gap after the name stays in the string.
                return prefix.trimmingTrailingWhitespace() + rule.symbol
            }
        }
        return text
    }

    // MARK: - Line-break aliases

    /// Flow's extra break phrases: "next line", "line break", "skip a line",
    /// "start a new paragraph". The original "new line" / "new paragraph"
    /// rule is untouched (its goldens pin the noun-phrase guards).
    static func applyLineBreakAliases(_ text: String) -> String {
        lineAliasRx.replacing(in: text) { m, ns in
            let prefix = m.group(1, ns) ?? ""
            let kind = (m.group(2, ns) ?? "").lowercased()
            let next = m.group(3, ns)
            let words = prefix.split(whereSeparator: { $0.isWhitespace }).map { $0.lowercased() }
            if let near = words.last, aliasDeterminers.contains(near) { return nil }
            if let next, aliasContinuations.contains(next.lowercased()) { return nil }
            let brk = kind.contains("paragraph") ? "\n\n" : "\n"
            return prefix + brk + (next.map { " " + $0 } ?? "")
        }
    }

    // MARK: - Numbered lists

    /// "one finish the report two send the presentation" →
    /// "1. Finish the report 2. Send the presentation".
    ///
    /// Fires only when at least two sequence words each introduce a verb
    /// phrase. "I have one meeting and two calls" stays verbatim — those
    /// heads are nouns.
    static func applyLists(_ text: String) -> String {
        let tokens = tokenize(text)
        guard tokens.count >= 4 else { return text }
        var items: [(index: Int, ordinal: Int, start: Int, end: Int)] = []
        var i = 0
        while i < tokens.count {
            if let ordinal = sequenceNumber(tokens[i].lower),
               i + 1 < tokens.count,
               listVerbs.contains(tokens[i + 1].lower) {
                items.append((items.count, ordinal, i, i + 1))
            }
            i += 1
        }
        guard items.count >= 2 else { return text }
        // Sequence words must be in increasing order (one… two… / first… second…).
        for pair in zip(items, items.dropFirst()) where pair.1.ordinal <= pair.0.ordinal {
            return text
        }
        // Close each item at the next sequence word (or the end).
        var spans: [(start: Int, end: Int, n: Int)] = []
        for (idx, item) in items.enumerated() {
            let close = idx + 1 < items.count ? items[idx + 1].start : tokens.count
            spans.append((item.start, close, idx + 1))
        }
        // Rebuild: everything before the first item, then numbered spans.
        var out = String(text[text.startIndex..<tokens[spans[0].start].range.lowerBound])
        let trimmedIntro = out.trimmingCharacters(in: .whitespacesAndNewlines)
        if let last = trimmedIntro.last, last.isLetter || last.isNumber {
            out = trimmedIntro
            if !out.hasSuffix(":") { out += ":" }
            out += " "
        }
        for (idx, span) in spans.enumerated() {
            let bodyStart = tokens[span.start + 1].range.lowerBound
            let bodyEnd = span.end < tokens.count
                ? tokens[span.end].range.lowerBound
                : text.endIndex
            var body = String(text[bodyStart..<bodyEnd])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if body.hasSuffix(",") { body = String(body.dropLast()).trimmingCharacters(in: .whitespaces) }
            if let first = body.first, first.isLetter {
                body = first.uppercased() + body.dropFirst()
            }
            if idx > 0 { out += spans.count >= 3 ? "\n" : " " }
            out += "\(span.n). \(body)"
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Press Enter

    /// Strip a trailing "press enter" command. Mid-sentence the phrase is
    /// content and stays. An utterance that is only the command returns
    /// empty text with the flag set — Flow still presses Enter.
    static func consumePressEnter(_ text: String) -> (String, Bool) {
        let ns = text as NSString
        if pressEnterOnlyRx.matches(text) { return ("", true) }
        guard let m = pressEnterTailRx.firstMatch(text, ns, from: 0) else {
            return (text, false)
        }
        let kept = ns.substring(to: m.range.location)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (kept, true)
    }

    // MARK: - Context-aware casing / spacing

    /// Flow's mid-sentence insert: lowercase the start so it flows, and add
    /// a leading space when the cursor is not already on one. Sentence
    /// starts (empty preceding, or preceding ends with . ! ? or a newline)
    /// keep the recognizer's capitalization.
    static func applyContextFit(_ text: String, preceding: String) -> String {
        guard !text.isEmpty else { return text }
        let prev = preceding
        guard let last = prev.last else { return text }
        var out = text
        let sentenceStart = ".!?\n".contains(last)
            || prev.unicodeScalars.last.map({ CharacterSet.newlines.contains($0) }) == true
        if !sentenceStart {
            out = lowercaseOpening(out)
            if !last.isWhitespace, !out.hasPrefix("\n"),
               out.first.map({ !$0.isPunctuation || $0 == "'" || $0 == "\u{2019}" }) == true {
                out = " " + out
            }
        }
        return out
    }

    /// Messaging apps drop a trailing period on short dictations (Flow's
    /// default / Casual style). Exclamation and question marks stay.
    static func applyMessagingPeriod(_ text: String, bundleID: String) -> String {
        guard !text.isEmpty, messagingBundleIDs.contains(bundleID) else { return text }
        guard text.last == "." else { return text }
        let sentences = text.split { ".!?".contains($0) }.filter { !$0.isEmpty }
        guard sentences.count <= 2 else { return text }
        return String(text.dropLast())
    }

    // MARK: - internals

    private struct PunctRule {
        let rx: Rx
        let symbol: String
        let blockedLeaders: Set<String>
        let blockedTrailers: Set<String>
    }

    /// Shared noun-phrase leaders: a determiner in front means the spoken
    /// name is the head of a phrase, not a command.
    private static let determiners: Set<String> = [
        "a", "an", "the", "this", "that", "another", "each", "every", "one",
        "my", "your", "our", "his", "her", "their", "its", "some", "any", "no",
        "these", "those", "which", "what", "whose",
    ]

    private static let punctRules: [PunctRule] = [
        PunctRule(rx: Rx(#"((?:\w+\s+){0,2})(?:question\s+mark)(?=\s+(\w+)|$)"#),
                  symbol: "?",
                  blockedLeaders: determiners.union(["every", "first", "second", "third", "next", "last"]),
                  blockedTrailers: []),
        PunctRule(rx: Rx(#"((?:\w+\s+){0,2})exclamation\s+(?:point|mark)(?=\s+(\w+)|$)"#),
                  symbol: "!",
                  blockedLeaders: determiners,
                  blockedTrailers: []),
        PunctRule(rx: Rx(#"((?:\w+\s+){0,2})(?:full\s+stop)(?=\s+(\w+)|$)"#),
                  symbol: ".",
                  blockedLeaders: determiners,
                  blockedTrailers: []),
        // Mid-sentence "period" only — trailing is the existing stage.
        // Refuse the noun-noun compounds the trailing stage already lists.
        PunctRule(rx: Rx(#"((?:\w+\s+){0,2})period(?=\s+(\w+))"#),
                  symbol: ".",
                  blockedLeaders: determiners.union([
                      "trial", "grace", "notice", "waiting", "cooling", "probation",
                      "probationary", "time", "rest", "class", "free", "lunch",
                      "question", "warranty", "billing", "blackout", "refund",
                      "vesting", "transition", "pay", "sales", "holding", "quiet",
                  ]),
                  blockedTrailers: ["of", "in", "on", "to", "for", "with", "from"]),
        PunctRule(rx: Rx(#"((?:\w+\s+){0,2})comma(?=\s+(\w+)|$)"#),
                  symbol: ",",
                  blockedLeaders: determiners.union(["oxford", "serial", "inverted"]),
                  blockedTrailers: ["splice", "splices", "separated", "operator", "operators"]),
        PunctRule(rx: Rx(#"((?:\w+\s+){0,2})colon(?=\s+(\w+)|$)"#),
                  symbol: ":",
                  blockedLeaders: determiners.union(["semi", "semi-"]),
                  blockedTrailers: ["cancer", "oscopy", "el"]),
        PunctRule(rx: Rx(#"((?:\w+\s+){0,2})semicolon(?=\s+(\w+)|$)"#),
                  symbol: ";",
                  blockedLeaders: determiners,
                  blockedTrailers: []),
        PunctRule(rx: Rx(#"((?:\w+\s+){0,2})(?:em(?:\s+|-)?dash|emdash)(?=\s+(\w+)|$)"#),
                  symbol: "—",
                  blockedLeaders: determiners,
                  blockedTrailers: []),
        PunctRule(rx: Rx(#"((?:\w+\s+){0,2})(?:quotation\s+mark|quote)(?=\s+(\w+)|$)"#),
                  symbol: "\"",
                  blockedLeaders: determiners.union(["end", "open", "close", "air"]),
                  blockedTrailers: ["unquote", "marks", "from"]),
        PunctRule(rx: Rx(#"((?:\w+\s+){0,2})(?:apostrophe|single\s+quote)(?=\s+(\w+)|$)"#),
                  symbol: "'",
                  blockedLeaders: determiners,
                  blockedTrailers: ["s"]),
        PunctRule(rx: Rx(#"((?:\w+\s+){0,2})(?:asterisk|star)(?=\s+(\w+)|$)"#),
                  symbol: "*",
                  blockedLeaders: determiners.union(["north", "movie", "pop", "rock", "super", "all"]),
                  blockedTrailers: ["wars", "trek", "bucks", "fish", "emoji"]),
        PunctRule(rx: Rx(#"((?:\w+\s+){0,2})ampersand(?=\s+(\w+)|$)"#),
                  symbol: "&",
                  blockedLeaders: determiners,
                  blockedTrailers: []),
        PunctRule(rx: Rx(#"((?:\w+\s+){0,2})(?:percent\s+sign|per\s+cent|percentage\s+symbol)(?=\s+(\w+)|$)"#),
                  symbol: "%",
                  blockedLeaders: determiners,
                  blockedTrailers: []),
        PunctRule(rx: Rx(#"((?:\w+\s+){0,2})ellipsis(?=\s+(\w+)|$)"#),
                  symbol: "…",
                  blockedLeaders: determiners,
                  blockedTrailers: []),
        PunctRule(rx: Rx(#"((?:\w+\s+){0,2})(?:forward\s+slash|backslash)(?=\s+(\w+)|$)"#),
                  symbol: "/",
                  blockedLeaders: determiners,
                  blockedTrailers: []),
        PunctRule(rx: Rx(#"((?:\w+\s+){0,2})underscore(?=\s+(\w+)|$)"#),
                  symbol: "_",
                  blockedLeaders: determiners,
                  blockedTrailers: []),
        PunctRule(rx: Rx(#"((?:\w+\s+){0,2})(?:hashtag|hash)(?=\s+(\w+)|$)"#),
                  symbol: "#",
                  blockedLeaders: determiners.union(["corned", "potato"]),
                  blockedTrailers: ["brown", "browns", "tag"]),
        PunctRule(rx: Rx(#"((?:\w+\s+){0,2})(?:at\s+sign|at\s+symbol)(?=\s+(\w+)|$)"#),
                  symbol: "@",
                  blockedLeaders: determiners,
                  blockedTrailers: []),
        PunctRule(rx: Rx(#"((?:\w+\s+){0,2})(?:open\s+(?:parenthesis|paren|bracket)|left\s+paren)(?=\s+(\w+)|$)"#),
                  symbol: "(",
                  blockedLeaders: determiners,
                  blockedTrailers: []),
        PunctRule(rx: Rx(#"((?:\w+\s+){0,2})(?:close\s+(?:parenthesis|paren|bracket)|right\s+paren)(?=\s+(\w+)|$)"#),
                  symbol: ")",
                  blockedLeaders: determiners,
                  blockedTrailers: []),
        PunctRule(rx: Rx(#"((?:\w+\s+){0,2})(?:plus\s+sign)(?=\s+(\w+)|$)"#),
                  symbol: "+",
                  blockedLeaders: determiners,
                  blockedTrailers: []),
        PunctRule(rx: Rx(#"((?:\w+\s+){0,2})(?:equals\s+sign)(?=\s+(\w+)|$)"#),
                  symbol: "=",
                  blockedLeaders: determiners,
                  blockedTrailers: []),
        PunctRule(rx: Rx(#"((?:\w+\s+){0,2})(?:hyphen|dash)(?=\s+(\w+)|$)"#),
                  symbol: "-",
                  blockedLeaders: determiners.union(["em", "en", "em-", "en-"]),
                  blockedTrailers: ["cam", "board", "boards", "pot", "to"]),
        PunctRule(rx: Rx(#"((?:\w+\s+){0,2})tilde(?=\s+(\w+)|$)"#),
                  symbol: "~",
                  blockedLeaders: determiners,
                  blockedTrailers: []),
        PunctRule(rx: Rx(#"((?:\w+\s+){0,2})(?:minus\s+sign)(?=\s+(\w+)|$)"#),
                  symbol: "-",
                  blockedLeaders: determiners,
                  blockedTrailers: []),
        PunctRule(rx: Rx(#"((?:\w+\s+){0,2})(?:greater-than\s+sign|close\s+angle\s+bracket)(?=\s+(\w+)|$)"#),
                  symbol: ">",
                  blockedLeaders: determiners,
                  blockedTrailers: []),
        PunctRule(rx: Rx(#"((?:\w+\s+){0,2})(?:less-than\s+sign|open\s+angle\s+bracket|angle\s+bracket)(?=\s+(\w+)|$)"#),
                  symbol: "<",
                  blockedLeaders: determiners,
                  blockedTrailers: []),
        PunctRule(rx: Rx(#"((?:\w+\s+){0,2})(?:degree\s+(?:sign|symbol))(?=\s+(\w+)|$)"#),
                  symbol: "°",
                  blockedLeaders: determiners,
                  blockedTrailers: []),
        PunctRule(rx: Rx(#"((?:\w+\s+){0,2})(?:degrees?\s+(?:celsius|centigrade))(?=\s+(\w+)|$)"#),
                  symbol: "°C",
                  blockedLeaders: determiners,
                  blockedTrailers: []),
        PunctRule(rx: Rx(#"((?:\w+\s+){0,2})(?:degrees?\s+(?:fahrenheit|f))\b(?=\s+(\w+)|$)"#),
                  symbol: "°F",
                  blockedLeaders: determiners,
                  blockedTrailers: []),
        PunctRule(rx: Rx(#"((?:\w+\s+){0,2})(?:copyright\s+symbol)(?=\s+(\w+)|$)"#),
                  symbol: "©",
                  blockedLeaders: determiners,
                  blockedTrailers: []),
        PunctRule(rx: Rx(#"((?:\w+\s+){0,2})(?:registered\s+trademark)(?=\s+(\w+)|$)"#),
                  symbol: "®",
                  blockedLeaders: determiners,
                  blockedTrailers: []),
        PunctRule(rx: Rx(#"((?:\w+\s+){0,2})(?:trademark)(?=\s+(\w+)|$)"#),
                  symbol: "™",
                  blockedLeaders: determiners,
                  blockedTrailers: []),
    ]

    private static let aliasDeterminers = determiners
    private static let aliasContinuations: Set<String> = [
        "of", "in", "on", "at", "to", "for", "with", "from", "by", "and", "or",
        "that", "which", "is", "was", "are", "were", "about", "into", "onto",
    ]

    /// Prefix + kind + optional next word. Kind is captured so paragraph
    /// aliases can emit a blank line.
    private static let lineAliasRx = Rx(
        #"((?:\w+\s+){0,2})(next\s+line|line\s+break|skip\s+a\s+line|"#
            + #"start\s+a\s+new\s+paragraph)(?:\s+(\w+))?"#)

    private static let pressEnterOnlyRx = Rx(#"^press\s+enter[.!]?\s*$"#)
    private static let pressEnterTailRx = Rx(#"\s+press\s+enter[.!]?\s*$"#)

    /// Native messaging apps Flow documents. Web-only detections (Messenger,
    /// Instagram, X, …) are omitted — we do not inspect URLs.
    static let messagingBundleIDs: Set<String> = [
        "com.apple.MobileSMS",
        "com.apple.iChat",
        "com.tinyspeck.slackmacgap",
        "com.hnc.Discord",
        "com.hnc.Discord.helper",
        "ru.keepcoder.Telegram",
        "org.telegram.desktop",
        "org.whispersystems.signal-desktop",
        "net.whatsapp.WhatsApp",
        "com.microsoft.teams",
        "com.microsoft.teams2",
        "com.tencent.xinWeChat",
        "jp.naver.line.mac",
        "com.larksuite.lark",
        "com.google.chat",
        "com.automattic.beeper",
        "com.texts.Texts",
    ]

    private static let sequenceCardinal: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
    ]
    private static let sequenceOrdinal: [String: Int] = [
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5,
        "sixth": 6, "seventh": 7, "eighth": 8, "ninth": 9, "tenth": 10,
    ]

    private static func sequenceNumber(_ word: String) -> Int? {
        sequenceCardinal[word] ?? sequenceOrdinal[word]
    }

    /// Verbs that open a dictated list item. Closed and measured: a noun
    /// after "one" / "first" is ordinary speech.
    static let listVerbs: Set<String> = [
        "finish", "send", "write", "call", "review", "ship", "fix", "add",
        "remove", "update", "check", "meet", "draft", "schedule", "buy",
        "make", "get", "put", "take", "start", "stop", "create", "delete",
        "open", "close", "move", "copy", "run", "test", "deploy", "ask",
        "tell", "email", "ping", "book", "cancel", "confirm", "prepare",
        "share", "upload", "download", "read", "watch", "listen", "go",
        "bring", "leave", "try", "use", "set", "change", "pick", "choose",
        "find", "look", "talk", "speak", "discuss", "plan", "build",
        "launch", "publish", "submit", "approve", "reject", "follow",
        "join", "clean", "polish", "rewrite", "summarize", "translate",
        "install", "configure", "enable", "disable", "reset", "restart",
        "migrate", "refactor", "commit", "push", "pull", "merge",
    ]

    private struct Token {
        var lower: String
        var range: Range<String.Index>
    }

    private static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var start: String.Index?
        for i in text.indices {
            if text[i].isWhitespace {
                if let s = start {
                    let raw = String(text[s..<i])
                    tokens.append(Token(lower: raw.lowercased()
                        .trimmingCharacters(in: .punctuationCharacters), range: s..<i))
                    start = nil
                }
            } else if start == nil {
                start = i
            }
        }
        if let s = start {
            let raw = String(text[s...])
            tokens.append(Token(lower: raw.lowercased()
                .trimmingCharacters(in: .punctuationCharacters), range: s..<text.endIndex))
        }
        return tokens.filter { !$0.lower.isEmpty }
    }

    private static func lowercaseOpening(_ text: String) -> String {
        guard let first = text.first, first.isLetter, first.isUppercase else { return text }
        let word = String(text.prefix(while: { $0.isLetter || $0 == "'" || $0 == "\u{2019}" }))
        if word == "I" || word.hasPrefix("I'") || word.hasPrefix("I\u{2019}") { return text }
        if word.count > 1, word == word.uppercased() { return text }  // acronym
        return first.lowercased() + text.dropFirst()
    }
}

private extension String {
    func trimmingTrailingWhitespace() -> String {
        var scalars = Substring.UnicodeScalarView(unicodeScalars)
        while let last = scalars.last,
              CharacterSet.whitespacesAndNewlines.contains(last) { scalars.removeLast() }
        return String(String.UnicodeScalarView(scalars))
    }
}

private extension NSTextCheckingResult {
    func group(_ index: Int, _ ns: NSString) -> String? {
        guard index < numberOfRanges else { return nil }
        let r = range(at: index)
        return r.location == NSNotFound ? nil : ns.substring(with: r)
    }
}
