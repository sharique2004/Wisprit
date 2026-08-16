import XCTest
import WispritKit
@testable import WispritPostProcess

/// The two pinned tables for the identity gate, in BOTH directions.
///
/// FIXTURES ARE FAKE, ALWAYS. `me@example.com`, `github.com/example`,
/// `linkedin.com/in/example`, `example.dev`. The real address and username are
/// runtime config and must never enter the repo — the gate is pure and takes an
/// injected `IdentityValues` precisely so these tests never touch ~/.wisprit or
/// a git config.
final class IdentityExpansionTests: XCTestCase {

    private let full = IdentityValues([
        .email: "me@example.com",
        .github: "github.com/example",
        .linkedin: "linkedin.com/in/example",
        .website: "example.dev",
    ])

    /// LinkedIn and website UNSET — the shipped shape, since those two values
    /// were never given.
    private let partial = IdentityValues([
        .email: "me@example.com",
        .github: "github.com/example",
    ])

    /// Which licenser a row pins, so a regression names the rule that broke.
    private enum Rule: String { case r1 = "R1", p = "P", l = "L", v1 = "V1", v2 = "V2", c = "C", a = "A" }

    private struct Row {
        let rule: Rule
        let input: String
        let expected: String
        let note: String
        init(_ rule: Rule, _ input: String, _ expected: String, _ note: String = "") {
            self.rule = rule; self.input = input; self.expected = expected; self.note = note
        }
    }

    // MARK: - MUST FIRE

    private var mustFire: [Row] {
        [
            // R1 — the whole utterance is the trigger. Unconditional.
            Row(.r1, "my email", "me@example.com"),
            Row(.r1, "My email.", "me@example.com",
                "capitalized input, period dropped, value stays lowercase"),
            Row(.r1, "my email address", "me@example.com", "longest form wins"),
            Row(.r1, "my e-mail", "me@example.com"),
            Row(.r1, "my github", "github.com/example"),
            Row(.r1, "my git hub", "github.com/example", "mishear"),
            Row(.r1, "my get hub", "github.com/example", "'my get' is never a noun phrase"),
            Row(.r1, "my linked in", "linkedin.com/in/example", "split mishear"),
            Row(.r1, "my LinkedIn profile", "linkedin.com/in/example"),
            Row(.r1, "my website", "example.dev"),
            Row(.r1, "my site", "example.dev", "solo-only form"),
            Row(.r1, "my home page", "example.dev"),
            Row(.r1, " my email ", " me@example.com",
                "the leadingSpace policy's space survives; the trailing gap does not"),

            // V1 — hand-over verb + bounded gap + strong preposition.
            Row(.v1, "send it to my email", "send it to me@example.com"),
            Row(.v1, "reach me at my email.", "reach me at me@example.com.",
                "sentence period kept — not a solo emission"),
            Row(.v1, "send the signed contract to my email",
                "send the signed contract to me@example.com", "3-token gap, the limit"),
            Row(.v1, "I'll send it to my email", "I'll send it to me@example.com",
                "I'll + base form is intent, not a report"),
            Row(.v1, "forward that to my email", "forward that to me@example.com"),

            // V2 — addressee-directed frame. `find`/`connect` are licensed by
            // the FRAME, never by the lemma.
            Row(.v2, "you can connect on my LinkedIn",
                "you can connect on linkedin.com/in/example"),
            Row(.v2, "you can find it via my website", "you can find it via example.dev"),
            Row(.v2, "you can find me on my GitHub.", "you can find me on github.com/example.",
                "utterance-final, gap='me'"),
            Row(.v2, "feel free to reach me at my email",
                "feel free to reach me at me@example.com"),
            Row(.v2, "find me on my GitHub", "find me on github.com/example",
                "bare imperative, clause-initial"),

            // L — locative predication, no verb at all.
            Row(.l, "it's on my GitHub", "it's on github.com/example"),
            Row(.l, "everything is up on my GitHub", "everything is up on github.com/example"),

            // P — presentative.
            Row(.p, "here's my email", "here's me@example.com"),
            Row(.p, "Here is my GitHub.", "Here is github.com/example."),
            Row(.p, "this is my website", "this is example.dev"),

            // C — dangling copula. An INSERTION: "my" is retained because the
            // value is the predicate nominal, and the dangling period is
            // dropped so the value takes its place.
            Row(.c, "my email is", "my email is me@example.com"),
            Row(.c, "my email is.", "my email is me@example.com"),

            // A — coordination, chaining off a licensed occurrence.
            Row(.a, "here's my email and my GitHub",
                "here's me@example.com and github.com/example"),
            Row(.a, "here's my email, my GitHub",
                "here's me@example.com, github.com/example"),
        ]
    }

    func testMustFire() {
        for row in mustFire {
            XCTAssertEqual(IdentityExpansion.expand(row.input, full), row.expected,
                           "\(row.rule.rawValue) | \(row.input) | \(row.note)")
        }
    }

    /// Every rewrite is a fixed point. Running the gate twice must not find a
    /// second trigger inside its own output, and must not un-do the first pass.
    func testMustFireIsIdempotent() {
        for row in mustFire {
            let once = IdentityExpansion.expand(row.input, full)
            XCTAssertEqual(IdentityExpansion.expand(once, full), once,
                           "\(row.rule.rawValue) | \(row.input)")
        }
    }

    // MARK: - MUST NOT FIRE

    /// Byte-for-byte identity, not "does not contain the value": the point is
    /// that an unlicensed utterance is UNTOUCHED, whitespace included.
    private let mustNotFire: [String] = [
        // The user's own examples.
        "I need to check my email",
        "my website is being redesigned",
        "my LinkedIn needs updating",
        "I'll post it on my LinkedIn",
        "push it to my GitHub",
        "sign in to my website",
        "his email",
        "my wife's LinkedIn",
        "my work email",
        "my emails",

        // Referring frames with no licenser at all.
        "my email keeps bouncing",
        "my email is down",
        "my email is full",
        "my website is slow today",
        "my email address is not working",
        "my site is down",
        "I hate my website.",
        "I'm working on my website",
        "I spent all morning on my LinkedIn",
        "someone commented on my LinkedIn",
        "I logged in to my website",

        // Wrong determiner, or a modifier breaking adjacency.
        "send it to his email",
        "their GitHub is a mess",
        "connect on your LinkedIn",
        "it is on our GitHub",
        "my old website",
        "check my emails",
        "my GitHub's readme",

        // Prepositions deliberately outside STRONG_PREP.
        "it's in my email",
        "I deleted it from my email",
        "I went through my email",
        "sign up with my email",
        "share my email with the team",
        "cc my email on that",

        // Forms deliberately rejected.
        "my Lincoln",
        "my mail is here",
        "my inbox",
        "I need to update my portfolio",

        // Compound heads, singular and plural.
        "send it to my email account",
        "here's my GitHub repo",
        "my website traffic is up",
        "my email addresses are in the sheet",
        "here's my GitHub pages",

        // DEPOSIT verbs: the prepositional object is a place you own, not an
        // address. Every one of these fired under a verb list that mixed the
        // two semantic classes.
        "upload the deck to my website",
        "publish it on my website",
        "I put the photos on my website",
        "add that to my LinkedIn",
        "drop it on my website",
        "I hosted it on my website",
        "I shared it on my LinkedIn",
        "I applied to that job on my LinkedIn",
        "I follow a lot of people on my LinkedIn",
        "I linked to my website from the footer",
        "point it at my website",
        "I signed in to my website",
        "signed up on my website",

        // Frame restriction on find/connect: 1st-person past is a report.
        "I found it on my GitHub",
        "I couldn't find it on my LinkedIn",
        "I can't connect to my website",

        // The "about" frame and the V1 subject guard.
        "I wrote about it on my website",
        "she asked about it on my LinkedIn",
        "I sent it to my email",

        // Every licenser is anchored to the text IMMEDIATELY before "my". A
        // licensing frame that occurred earlier in the sentence licenses
        // nothing — these two fire if any `\z` anchor is ever dropped.
        "send it to Bob and then check my email",
        "here's the thing about my website",
    ]

    func testMustNotFire() {
        for input in mustNotFire {
            XCTAssertEqual(IdentityExpansion.expand(input, full), input,
                           "must stay verbatim: \(input)")
        }
    }

    func testMustNotFireIsIdempotent() {
        for input in mustNotFire {
            let once = IdentityExpansion.expand(input, full)
            XCTAssertEqual(IdentityExpansion.expand(once, full), once, input)
        }
    }

    // MARK: - The inert-slot pin: never invent a value

    /// LinkedIn and website are unset, which is how the feature SHIPS. Every
    /// LinkedIn/website input from both tables must survive as the literal
    /// words the user said.
    func testInertSlotNeverEmits() {
        let inputs = mustFire.map(\.input) + mustNotFire
        for input in inputs where mentionsInertSlot(input) {
            let out = IdentityExpansion.expand(input, partial)
            XCTAssertEqual(out, input, "an unset slot must be inert: \(input)")
            XCTAssertFalse(out.isEmpty, "an unset slot must never emit an empty string")
            XCTAssertFalse(out.lowercased().contains("example.dev"), input)
            XCTAssertFalse(out.lowercased().contains("linkedin.com/in"), input)
            XCTAssertFalse(out.contains("https://"), "no placeholder, no stub: \(input)")
        }
    }

    private func mentionsInertSlot(_ text: String) -> Bool {
        let lower = text.lowercased()
        guard !lower.contains("email"), !lower.contains("github"),
              !lower.contains("git hub"), !lower.contains("get hub") else { return false }
        return lower.contains("linkedin") || lower.contains("linked in")
            || lower.contains("website") || lower.contains("site")
            || lower.contains("home page")
    }

    /// The chain licenses off LICENSED, not EXPANDED — so a chain survives an
    /// inert slot in the middle of it, and the inert half stays verbatim.
    func testChainLicensesOffLicensedNotExpanded() {
        XCTAssertEqual(
            IdentityExpansion.expand("here's my LinkedIn and my GitHub", partial),
            "here's my LinkedIn and github.com/example")
        XCTAssertEqual(
            IdentityExpansion.expand("here's my LinkedIn and my GitHub", full),
            "here's linkedin.com/in/example and github.com/example")
    }

    /// A default install — no identity.json, nothing configured — is a measured
    /// no-op on the WHOLE must-fire table. This is the second kill switch, and
    /// it is independent of the settings flag.
    func testEmptyStoreIsTheIdentityFunction() {
        let empty = IdentityValues()
        XCTAssertTrue(empty.isEmpty)
        for row in mustFire {
            XCTAssertEqual(IdentityExpansion.expand(row.input, empty), row.input, row.input)
        }
    }

    func testBlankValueIsIndistinguishableFromAbsent() {
        for blank in ["", "   ", "\n", "\t "] {
            let values = IdentityValues([.email: blank])
            XCTAssertNil(values.value(.email))
            XCTAssertTrue(values.isEmpty)
            XCTAssertEqual(IdentityExpansion.expand("my email", values), "my email")
            XCTAssertEqual(IdentityExpansion.expand("send it to my email", values),
                           "send it to my email")
        }
    }

    // MARK: - Mechanics

    /// The possessive is CONSUMED by every rule but C, where the value is the
    /// predicate nominal and "my email is me@example.com" is correct English.
    func testPossessiveIsConsumedExceptInCopula() {
        for row in mustFire where row.rule != .c {
            XCTAssertFalse(row.expected.lowercased().contains("my "),
                           "\(row.rule.rawValue) leaves a stray possessive: \(row.expected)")
        }
        XCTAssertEqual(IdentityExpansion.expand("my email is", full),
                       "my email is me@example.com")
    }

    func testCasingIsNeverAdjusted() {
        XCTAssertEqual(IdentityExpansion.expand("My email.", full), "me@example.com")
        XCTAssertEqual(IdentityExpansion.expand("My GitHub", full), "github.com/example")
        XCTAssertEqual(IdentityExpansion.expand("Here's my EMAIL", full), "Here's me@example.com")
    }

    func testLeadingSpacePreserved() {
        XCTAssertEqual(IdentityExpansion.expand(" my email", full), " me@example.com")
        XCTAssertEqual(IdentityExpansion.expand("\n my email", full), "\n me@example.com")
    }

    func testLongestFormWins() {
        XCTAssertEqual(IdentityExpansion.expand("here's my email address", full),
                       "here's me@example.com")
        // …and the compound guard sees the token AFTER the longest form.
        XCTAssertEqual(IdentityExpansion.expand("here's my email account", full),
                       "here's my email account")
    }

    func testMultipleOccurrences() {
        XCTAssertEqual(
            IdentityExpansion.expand("here's my email and here's my GitHub", full),
            "here's me@example.com and here's github.com/example")
        // One licensed, one not: only the licensed half moves.
        XCTAssertEqual(
            IdentityExpansion.expand("here's my email but my website is down", full),
            "here's me@example.com but my website is down")
    }

    /// Every DEPOSIT verb removed from the hand-over list, asserted as a loop,
    /// so re-adding one fails a test that names it. The frame is deliberately
    /// 1st-person-future rather than a bare imperative: `find`, `connect` and
    /// `follow` ARE licensed clause-initially by V2, and that is by design.
    func testVerbClassSeparation() {
        let deposit = ["post", "put", "push", "upload", "publish", "host", "add",
                       "drop", "share", "apply", "follow", "link", "point", "sign",
                       "log", "check", "see", "read", "manage", "update", "fix"]
        for verb in deposit {
            let text = "I'll \(verb) it on my website"
            XCTAssertEqual(IdentityExpansion.expand(text, full), text,
                           "'\(verb)' is a deposit verb — its object is a place, not an address")
        }
    }

    /// A `$1` or a `\1` in a stored value must land literally. `Rx.replacing`'s
    /// closure form splices verbatim; a template-based rewrite would read them
    /// as group references.
    func testValueIsSplicedVerbatim() {
        let odd = IdentityValues([.website: #"https://x.dev/$1\1"#])
        XCTAssertEqual(IdentityExpansion.expand("my website", odd), #"https://x.dev/$1\1"#)
        XCTAssertEqual(IdentityExpansion.expand("here's my website", odd),
                       #"here's https://x.dev/$1\1"#)
    }

    /// `Rx.init` degrades a non-compiling pattern to a silent no-op, which
    /// looks exactly like "the licenser did not apply". This is the existing
    /// idiom for proving a pattern edit did not quietly break.
    func testEveryPatternCompiled() {
        for (name, rx) in IdentityExpansion.compiledPatterns {
            XCTAssertGreaterThanOrEqual(rx.captureGroupCount, 0,
                                        "\(name) failed to compile and is a no-op")
        }
    }

    func testFormTableIsSortedLongestFirst() {
        let lengths = IdentityExpansion.forms.map(\.phrase.count)
        XCTAssertEqual(lengths, lengths.sorted(by: >),
                       "longest form must win at each position, like SnippetStore's triggers")
    }

    /// The hand-over roster, pinned as data. A deposit verb appearing here is
    /// the exact defect this split exists to prevent.
    func testHandoverRosterHoldsNoDepositVerbs() {
        let deposit: Set<String> = ["post", "put", "push", "upload", "publish", "host",
                                    "add", "drop", "share", "apply", "follow", "link",
                                    "point", "sign", "log", "find", "connect"]
        for form in IdentityExpansion.handoverVerbForms {
            XCTAssertFalse(deposit.contains(form), "'\(form)' names a place, not a channel")
        }
    }
}
