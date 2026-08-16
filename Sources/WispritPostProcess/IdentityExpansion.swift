import Foundation
import WispritKit

/// "my email" → the address, but ONLY when the phrase is handing the value
/// over. A linguistic evidence gate, not a find-and-replace.
///
/// Two rules, and they are the user's own words:
///
///   R1  The whole utterance is "my <form>" → emit the value alone.
///   R2  Mid-sentence → expand ONLY under a named licenser. Everything else
///       stays verbatim.
///
/// WHY WHITELIST POLARITY. A false fire types a real personal address into
/// whatever app is frontmost — possibly a public channel or a shared doc. With
/// a whitelist of licensing frames, "I'm working on my website", "someone
/// commented on my LinkedIn" and "I logged in to my website" all stay verbatim
/// without anyone having to think of them. A blocklist of referring verbs
/// would fail OPEN on every verb nobody thought of; this fails closed. The
/// cost is false negatives ("share my email with the team"), which cost a
/// re-dictation. A false fire costs an address in a channel.
///
/// WHERE IT RUNS. After `PostProcess.processResult` and after
/// `SnippetStore.expand` (SessionController). After PostProcess because the
/// emitted value then cannot be touched by the spoken-email/URL joiner, by
/// `ensureSentencePeriod`, or by `SmartFormat.applyContextFit`'s
/// `lowercaseOpening` — a value spliced in post-pipeline is inserted verbatim.
/// After snippets because a user-authored snippet is an EXPLICIT unconditional
/// rule and must win a trigger collision; snippets consume the phrase first
/// and this gate then finds nothing. Zero precedence code.
///
/// Pure: the values are injected, so the tests never touch ~/.wisprit.
public enum IdentityExpansion {

    // MARK: - Entry point

    /// Expand every LICENSED occurrence. Everything else — including every
    /// occurrence of an inert slot — comes back byte-for-byte.
    public static func expand(_ text: String, _ values: IdentityValues) -> String {
        // Two cheap gates before any regex: nothing configured means this
        // stage is a measured no-op on a default install.
        guard !text.isEmpty, !values.isEmpty else { return text }
        let ns = text as NSString
        let matches = triggerRx.allMatches(text, ns)
        guard !matches.isEmpty else { return text }

        // R1 first, and it is exclusive: a solo utterance has exactly one
        // occurrence and nothing around it.
        if matches.count == 1, let solo = soloRewrite(matches[0], ns, values) { return solo }

        var out = ""
        var cursor = 0
        // The chain licenser (A) hangs off the end of the last LICENSED
        // occurrence, not the last EXPANDED one — so "here's my LinkedIn and
        // my GitHub" still fires GitHub when LinkedIn is unset.
        var lastLicensedEnd: Int?

        for m in matches {
            let span = m.range
            guard span.location >= cursor else { continue }
            guard let formText = m.group(1, ns), let form = form(for: formText) else { continue }
            let prefix = ns.substring(to: span.location)
            let suffix = ns.substring(from: span.location + span.length)

            out += ns.substring(with: NSRange(location: cursor, length: span.location - cursor))
            cursor = span.location + span.length

            guard let licence = licence(form: form, prefix: prefix, suffix: suffix,
                                        spanStart: span.location, ns: ns,
                                        lastLicensedEnd: lastLicensedEnd) else {
                out += ns.substring(with: span)
                continue
            }

            let value = values.value(form.slot)
            switch licence {
            case .substitute:
                // Licensed either way; only the rewrite is conditional. An
                // inert slot consumes no text and emits no placeholder.
                out += value ?? ns.substring(with: span)
                lastLicensedEnd = cursor
            case .copula(let gap):
                // "my email is" — an INSERTION, not a substitution: nothing
                // the user said is deleted, so "my" is retained and the value
                // becomes the predicate nominal. C never licenses a chain.
                out += ns.substring(with: span)
                if let value {
                    out += gap + "is " + value
                    cursor = ns.length
                }
            }
        }
        out += ns.substring(from: cursor)
        return out
    }

    // MARK: - R1: solo utterance, unconditional

    /// The whole text is "my <form>" plus optional trailing punctuation.
    /// Returns nil when this is not that shape (or the slot is inert), which
    /// hands the occurrence back to the rule-2 scan.
    private static func soloRewrite(_ m: NSTextCheckingResult, _ ns: NSString,
                                    _ values: IdentityValues) -> String? {
        let span = m.range
        let prefix = ns.substring(to: span.location)
        let suffix = ns.substring(from: span.location + span.length)
        guard soloHeadRx.matches(prefix), soloTailRx.matches(suffix) else { return nil }
        guard let formText = m.group(1, ns), let form = form(for: formText),
              let value = values.value(form.slot) else { return nil }
        // The leading whitespace is load-bearing: PostProcess stage 8 may have
        // prepended a space under the `leading_space` policy, and dropping it
        // would jam the address against the previous word. The TRAILING period
        // is dropped on purpose — a period glued to a URL or an address breaks
        // click targets, and a solo emission is a value, not a sentence.
        //
        // Casing is never adjusted: "My email." emits the lowercase value,
        // because addresses and URLs are lowercase by convention and nothing
        // downstream re-capitalizes (we run after PostProcess).
        return prefix + value
    }

    // MARK: - R2: licensing

    private enum Licence {
        case substitute
        /// The whitespace between the form and the copula, re-emitted verbatim.
        case copula(String)
    }

    private static func licence(form: Form, prefix: String, suffix: String,
                                spanStart: Int, ns: NSString,
                                lastLicensedEnd: Int?) -> Licence? {
        // A solo-only form ("my site") is too common a referring frame to
        // admit into the sentence rules. R1 already had its chance.
        if form.soloOnly { return nil }
        // Right-hand guard: the next token makes the form a pre-nominal
        // modifier rather than a referent ("my email account", "my GitHub
        // repo"). A repo is not the profile.
        if compoundHead(suffix, form.slot) { return nil }
        // Left-hand guard: the "about" frame is a report, never a hand-over,
        // and no compound head can reach it ("I wrote about it on my website").
        if aboutRx.matches(prefix) { return nil }

        // C is checked first because it is the only INSERTION and it is
        // anchored to the end of the text. The pattern is `\A\s+is…`, so the
        // gap to re-emit IS the suffix's leading whitespace run — read straight
        // off the string rather than through a capture group, because the only
        // `Rx` accessor that hands back groups relaxes the anchoring bounds and
        // this match must stay anchored.
        if copulaTailRx.matches(suffix) {
            return .copula(String(suffix.prefix(while: \.isWhitespace)))
        }
        if presentativeRx.matches(prefix) { return .substitute }   // P
        if locativeRx.matches(prefix) { return .substitute }       // L
        if addresseeFrameRx.matches(prefix) { return .substitute } // V2 (you can find me on …)
        if imperativeFrameRx.matches(prefix) { return .substitute }// V2 (find me on …)
        if handoverFires(prefix) { return .substitute }            // V1
        if let end = lastLicensedEnd, end <= spanStart,            // A
           conjunctionRx.matches(ns.substring(with: NSRange(location: end,
                                                            length: spanStart - end))) {
            return .substitute
        }
        return nil
    }

    /// V1 — a hand-over verb, a bounded gap, and a strong preposition.
    ///
    /// THE VERB CLASS IS THE WHOLE POINT. A HAND-OVER verb's prepositional
    /// object is the CHANNEL by which something reaches a person; a DEPOSIT
    /// verb's prepositional object is a PLACE the speaker owns. Only the first
    /// names an address. "send it to my email" hands over; "I'll post it on my
    /// LinkedIn", "push it to my GitHub" and "upload the deck to my website"
    /// name a place, and every one of them was measured firing under a verb
    /// list that mixed the two classes. See `handoverVerbForms` for the
    /// deposit verbs that were removed, each with the sentence that removed it.
    private static func handoverFires(_ prefix: String) -> Bool {
        let ns = prefix as NSString
        guard let m = handoverRx.firstMatch(prefix, ns, from: 0),
              let verb = m.group(1, ns)?.lowercased() else { return false }
        // Subject guard: a 1st-person subject with a past or progressive verb
        // is a REPORT of what the speaker already did, never an instruction to
        // the listener. "I sent it to my email" stays quiet — a deliberate,
        // re-dictation-cost false negative. "send it to my email" and "I'll
        // send it to my email" both fire, because a base form after "I'll" is
        // future/intent, directed outward.
        guard reportVerbForms.contains(verb) else { return true }
        let beforeVerb = ns.substring(to: m.range(at: 1).location)
        return !firstPersonSubjectRx.matches(beforeVerb)
    }

    // MARK: - Form tables

    struct Form {
        let phrase: String
        let slot: IdentitySlot
        /// Admitted by R1 only. "my site is down / slow / on Squarespace" is
        /// too common a referring frame for the sentence rules, but a solo
        /// "my site" is unambiguous. This is also the demotion mechanism if a
        /// mishear form ever misbehaves in practice.
        let soloOnly: Bool
    }

    /// Longest phrase first at every position, exactly like SnippetStore's
    /// longest-trigger-first sort, so `email address` is never eaten by
    /// `email` — and so the compound-head guard sees the token AFTER the form.
    static let forms: [Form] = {
        var out: [Form] = []
        func add(_ slot: IdentitySlot, _ phrases: [String], soloOnly: Bool = false) {
            out += phrases.map { Form(phrase: $0, slot: slot, soloOnly: soloOnly) }
        }
        // REJECTED, with the reason: `mail` (postal — "my mail is here"),
        // `inbox` (the container, never the address), `gmail`, `work email` /
        // `personal email` (a different address than the configured one).
        add(.email, ["email address", "e-mail address", "email addy", "email id",
                     "email", "e-mail", "e mail"])
        // REJECTED: `lincoln` (a real surname and a real car — the mishear is
        // not worth a false fire), `link`, `linked` alone.
        // `linked in` is ADMITTED on a syntactic argument, not on charity:
        // after possessive "my", `linked` can only be a participle modifying a
        // noun, and `in` is not a noun, so there is no competing reading.
        add(.linkedin, ["linkedin profile", "linkedin page", "linkedin url", "linkedin link",
                        "linkedin", "linked in", "linked-in"])
        // `get hub` is ADMITTED by the same argument: after possessive "my",
        // `get` cannot be a verb, and there is no English noun phrase "my get
        // hub". REJECTED: `git`, `hub`, `get up`, `kit hub`, `github repo`
        // (a specific repository is not the profile URL).
        add(.github, ["github profile", "github page", "github url", "github link",
                      "github", "git hub", "git-hub", "get hub", "gethub"])
        // REJECTED: `portfolio` (financial ambiguity), `blog`, `landing page`,
        // `page`, `web`.
        add(.website, ["personal website", "personal site", "website url", "website link",
                       "website", "web site", "homepage", "home page", "web page"])
        add(.website, ["site"], soloOnly: true)
        return out.sorted { $0.phrase.count > $1.phrase.count }
    }()

    private static let formsByKey: [String: Form] = {
        var out: [String: Form] = [:]
        for f in forms where out[f.phrase] == nil { out[f.phrase] = f }
        return out
    }()

    private static func form(for matched: String) -> Form? {
        formsByKey[collapseRx.replacingAll(in: matched.lowercased(), with: " ")]
    }

    // MARK: - Patterns
    //
    // NO VARIABLE-LENGTH LOOKBEHIND ANYWHERE. ICU rejects a lookbehind whose
    // maximum length is unbounded, and `Rx.init` silently degrades a
    // non-compiling pattern to a no-op — a lookbehind-shaped licenser would
    // simply never fire. Every prefix-sensitive licenser is instead matched
    // against the substring in front of the occurrence, anchored with `\z`,
    // the same capture-the-prefix shape `applyLineBreaks` and SmartFormat's
    // punct rules already use.
    //
    // `\z`, not `$`: ICU's `$` also matches before a final line terminator, so
    // `$` would let a licenser reach across a newline into the next line.

    /// possessive + form, ADJACENT.
    ///
    /// Three refusals come free from the shape. (1) Only first-person
    /// singular: there is exactly one determiner in the pattern and it is
    /// `my`, so "his email", "their GitHub", "your website" never match.
    /// (2) "my wife's LinkedIn" and "my work email" die on ADJACENCY — a
    /// modifier means it is not necessarily the configured value, and
    /// inventing one would be a lie. (3) Plurals and possessives die on the
    /// trailing boundary: "my emails" and "my GitHub's readme" both miss.
    static let triggerRx = Rx(#"(?<![\w])my\s+("# + formAlternation + #")(?![\w'’])"#)

    private static var formAlternation: String {
        forms.map { form in
            NSRegularExpression.escapedPattern(for: form.phrase)
                .replacingOccurrences(of: "\\ ", with: #"\s+"#)
                .replacingOccurrences(of: " ", with: #"\s+"#)
        }.joined(separator: "|")
    }

    private static let collapseRx = Rx(#"\s+"#)

    static let soloHeadRx = Rx(#"\A\s*\z"#)
    static let soloTailRx = Rx(#"\A\s*[.!?…,;:]?\s*\z"#)

    /// C — dangling copula, anchored to END OF TEXT.
    ///
    /// DECISION: expand. A copula with an empty predicate is an incomplete
    /// sentence in every reading, so there is no competing interpretation to
    /// protect, and the boundary is maximally testable: followed by NOTHING
    /// expands, followed by ANYTHING stays verbatim — which is exactly what
    /// keeps "my email is down / full / not working / being migrated" quiet.
    /// If it ever misbehaves, deleting this one licenser is a one-line,
    /// test-covered removal and nothing else regresses.
    ///
    /// Only ` is` — never `'s`. `my email's` cannot reach here at all: the
    /// trigger's `(?![\w'’])` lookahead refuses an apostrophe after the form.
    static let copulaTailRx = Rx(#"\A\s+is[ \t]*[.,!?…]?\s*\z"#)

    /// P — presentative.
    static let presentativeRx =
        Rx(#"(?<![\w])(?:here['’]s|here[ \t]+is|this[ \t]+is|that['’]s|that[ \t]+is)[ \t]+\z"#)

    /// L — locative predication: what makes "it's on my GitHub" work with no
    /// verb at all. The preposition is restricted to `on`; `in` would readmit
    /// "it's in my email", which is the inbox.
    static let locativeRx = Rx(
        #"(?<![\w])(?:it|that|this|they|those|these|everything)"#
        + #"(?:['’]s|[ \t]+(?:is|are|was|were))"#
        + #"(?:[ \t]+(?:up|all|already|right))?[ \t]+on[ \t]+\z"#)

    /// STRONG_PREP. Each exclusion has the sentence that excludes it:
    /// `in` — "it's in my email" (the inbox); `from` — "I deleted it from my
    /// email" refers while "get it from my website" hands over, genuinely
    /// ambiguous so verbatim-first wins; `with` — "sign up with my email"
    /// hands over but "I'm having trouble with my email" refers; `through` —
    /// "I went through my email" is one of the commonest referring frames in
    /// dictation.
    private static let strongPrep = #"(?:to|at|on|via|onto)"#
    /// Gap tokens: spaces and tabs only, so a newline or a sentence-terminal
    /// mark ends the clause and no licenser reaches across it. Commas are
    /// allowed inside a token ("send the signed contract, to my email").
    private static let gapToken = #"(?:[ \t]+[\w',’\-]+)"#

    /// V1 verbs — HAND-OVER senses only. Group 1 is the verb, so the subject
    /// guard can look at what precedes it.
    static let handoverRx = Rx(
        #"(?<![\w])("# + handoverVerbForms.joined(separator: "|") + #")(?![\w'’])"#
        + gapToken + #"{0,3}[ \t]+"# + strongPrep + #"[ \t]+\z"#)

    /// The hand-over class: the prepositional object is the channel by which
    /// something reaches a PERSON.
    ///
    /// REMOVED as DEPOSIT verbs — their object is a place you own, and every
    /// one was measured firing on ordinary dictation:
    ///   post   "I'll post it on my LinkedIn"      put    "I put the photos on my website"
    ///   push   "push it to my GitHub"             upload "upload the deck to my website"
    ///   publish "publish it on my website"        host   "I hosted it on my website"
    ///   add    "add that to my LinkedIn"          drop   "drop it on my website"
    ///   share  "I shared it on my LinkedIn"       apply  "I applied to that job on my LinkedIn"
    ///   follow "I follow a lot of people on my LinkedIn"
    ///   link   "I linked to my website from the footer"
    ///   point  "point it at my website" (DNS, not an address)
    ///   sign   "sign in to my website" — the identical construction `log` was
    ///          already excluded for, so `sign` goes with it
    /// `find` and `connect` were carrying must-fire rows and are re-licensed
    /// below under FRAME restriction rather than lemma membership.
    /// `share` is dropped outright: "share it on my LinkedIn" is the platform
    /// and "share my email" is already an accepted false negative, so no
    /// licensed frame is left worth the risk. `write` is KEPT ("write to my
    /// email" is unambiguous hand-over) and its one false fire, "I wrote about
    /// it on my website", is killed by `aboutRx` instead.
    static let handoverVerbForms = [
        "sends", "sent", "sending", "send",
        "forwards", "forwarded", "forwarding", "forward",
        "emails", "emailed", "emailing", "email",
        "messages", "messaged", "messaging", "message",
        "dms", "dmed", "dm",
        "pings", "pinged", "ping",
        "texts", "texted", "text",
        "writes", "wrote", "writing", "write",
        "replies", "replied", "reply",
        "responds", "responded", "respond",
        "reaches", "reached", "reaching", "reach",
        "contacts", "contacted", "contact",
        "invites", "invited", "invite",
        "refers", "referred", "refer",
        "subscribes", "subscribed", "subscribe",
        "registers", "registered", "register",
        "bcc", "cc", "hits", "hit",
    ]

    /// Past and progressive forms, listed rather than sniffed for a suffix:
    /// `ping` ends in "ing" and is a base form, and `hit` is its own past but
    /// "I hit it to my email" is not English. An explicit table cannot be
    /// wrong about either.
    static let reportVerbForms: Set<String> = [
        "sent", "sending", "forwarded", "forwarding", "emailed", "emailing",
        "messaged", "messaging", "dmed", "pinged", "texted", "wrote", "writing",
        "replied", "responded", "reached", "reaching", "contacted", "invited",
        "referred", "subscribed", "registered",
    ]

    /// A 1st-person subject, optionally with up to two auxiliaries, sitting
    /// immediately in front of the verb. `I'll` is deliberately absent: "I'll
    /// send it to my email" is intent, not a report.
    static let firstPersonSubjectRx = Rx(
        #"(?<![\w])(?:i|we|i['’]ve|we['’]ve|i['’]d|we['’]d)"#
        + #"(?:[ \t]+(?:have|had|was|were|am|are|just|already|also|never|"#
        + #"can['’]?t|cannot|couldn['’]?t)){0,2}[ \t]+\z"#)

    /// V2 — the addressee-directed frame. This is what `find` and `connect`
    /// were really doing: the licensing evidence is that the clause is aimed
    /// at the LISTENER, never that the lemma is in a list. "you can find me on
    /// my GitHub" fires; "I found it on my GitHub" and "I can't connect to my
    /// website" do not.
    static let addresseeFrameRx = Rx(
        #"(?<![\w])(?:you(?:['’]ll)?|feel[ \t]+free[ \t]+to|please)"#
        + #"(?:[ \t]+(?:can|could|should|may|might|will))?[ \t]+"#
        + #"(?:find|reach|contact|connect|follow|message|email|dm|ping|write|subscribe)s?(?![\w'’])"#
        + gapToken + #"{0,3}[ \t]+"# + strongPrep + #"[ \t]+\z"#)

    /// V2's bare-imperative half: clause-initial only, so "I can't connect to
    /// my website" cannot reach it.
    static let imperativeFrameRx = Rx(
        #"(?:\A|[.!?;\n][ \t]*|(?<![\w])(?:and|or)[ \t]+)"#
        + #"(?:find|reach|contact|connect|follow|subscribe)(?![\w'’])"#
        + gapToken + #"{0,3}[ \t]+"# + strongPrep + #"[ \t]+\z"#)

    /// A — coordination. Licensing chains off LICENSED, not EXPANDED.
    static let conjunctionRx = Rx(#"\A\s*(?:and[ \t]+also|,[ \t]*and|and|,|&|plus)\s+\z"#)

    /// The report frame no compound head can reach.
    static let aboutRx = Rx(#"(?<![\w])about"# + gapToken + #"{0,2}[ \t]+"#
                            + strongPrep + #"[ \t]+\z"#)

    // MARK: - Compound-head guard

    /// Tokens that make the form a pre-nominal MODIFIER rather than a
    /// referent. Matched with `(?:e?s)?` so the plural is caught by the
    /// singular entry — "my email addresses" backtracks the longest-form match
    /// to `email` with `addresses` following, which the bare `address` entry
    /// would otherwise miss.
    ///
    /// Necessarily incomplete: a novel compound ("send it to my email queue")
    /// slips through. The blast radius is bounded — the value is still
    /// correct, the trailing noun just reads oddly — and the list is data,
    /// extended by one line.
    private static let sharedHeads = [
        "account", "link", "url", "handle", "name", "username", "profile", "info",
        "detail", "credential", "login", "password", "setting", "notification",
        "history", "backup", "access", "permission", "subscription", "stuff",
        "situation", "issue", "problem", "setup",
    ]

    private static let slotHeads: [IdentitySlot: [String]] = [
        .email: ["address", "client", "app", "list", "signature", "thread", "chain",
                 "folder", "inbox", "server", "provider", "alias", "domain",
                 "campaign", "newsletter", "filter", "rule", "draft"],
        .linkedin: ["post", "message", "connection", "headline", "bio", "summary",
                    "invite", "request", "recruiter", "premium", "feed", "network"],
        .github: ["repo", "repository", "action", "issue", "pr", "pull", "token",
                  "workflow", "org", "organization", "gist", "star", "readme",
                  "page", "copilot", "sponsor"],
        .website: ["copy", "design", "redesign", "traffic", "analytics", "host",
                   "hosting", "domain", "builder", "template", "footer", "header",
                   "content", "seo", "speed", "performance", "migration", "launch",
                   "visitor", "theme", "plugin", "cms"],
    ]

    static let compoundHeadRx: [IdentitySlot: Rx] = {
        var out: [IdentitySlot: Rx] = [:]
        for slot in IdentitySlot.allCases {
            let heads = (sharedHeads + (slotHeads[slot] ?? []))
                .sorted { $0.count > $1.count }
                .map { NSRegularExpression.escapedPattern(for: $0) }
            out[slot] = Rx(#"\A[ \t]+(?:"# + heads.joined(separator: "|") + #")(?:e?s)?(?![\w])"#)
        }
        return out
    }()

    private static func compoundHead(_ suffix: String, _ slot: IdentitySlot) -> Bool {
        compoundHeadRx[slot]?.matches(suffix) ?? false
    }

    // MARK: - Test seam

    /// Every pattern the gate builds, so a test can prove none of them
    /// silently degraded to a no-op. `Rx` swallows a compile failure to keep
    /// the Python contract that `process()` never raises, which means a broken
    /// pattern here would look exactly like "the licenser did not apply".
    static var compiledPatterns: [(name: String, rx: Rx)] {
        var out: [(String, Rx)] = [
            ("trigger", triggerRx), ("soloHead", soloHeadRx), ("soloTail", soloTailRx),
            ("copulaTail", copulaTailRx), ("presentative", presentativeRx),
            ("locative", locativeRx), ("handover", handoverRx),
            ("firstPersonSubject", firstPersonSubjectRx),
            ("addresseeFrame", addresseeFrameRx), ("imperativeFrame", imperativeFrameRx),
            ("conjunction", conjunctionRx), ("about", aboutRx), ("collapse", collapseRx),
        ]
        for slot in IdentitySlot.allCases {
            out.append(("compoundHead.\(slot.rawValue)", compoundHeadRx[slot]!))
        }
        return out
    }
}

private extension NSTextCheckingResult {
    func group(_ index: Int, _ ns: NSString) -> String? {
        guard index < numberOfRanges else { return nil }
        let r = range(at: index)
        return r.location == NSNotFound ? nil : ns.substring(with: r)
    }
}
