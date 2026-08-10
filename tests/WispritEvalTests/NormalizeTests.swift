import XCTest
@testable import WispritEval

/// The three profiles, pinned. Fixtures are hand-computed: this is new spec
/// code, not a port, so there is no Python to generate goldens from — every
/// expectation below is the tokenization the profile is *specified* to produce.
final class NormalizeTests: XCTestCase {

    // MARK: - .asr

    /// The keep-set promoted from `docs/research/probes/fc_acc.swift:23`:
    /// letter | digit | space | apostrophe survive, everything else becomes a
    /// space. Hyphens therefore SPLIT.
    func testAsrKeepSet() {
        let cases: [(String, [String])] = [
            ("Hello, World!", ["hello", "world"]),
            ("write-heavy", ["write", "heavy"]),
            ("it's fine", ["it's", "fine"]),
            ("(parenthetical) [bracketed]", ["parenthetical", "bracketed"]),
            ("multi   space\ttab\nnewline", ["multi", "space", "tab", "newline"]),
            ("", []),
            ("   ", []),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(Normalize.tokens(input, profile: .asr), expected, input)
        }
    }

    func testAsrFoldsQuotesDashesAndEllipsis() {
        let cases: [(String, [String])] = [
            ("it\u{2019}s", ["it's"]),
            ("\u{201C}quoted\u{201D}", ["quoted"]),
            ("yes\u{2014}no", ["yes", "no"]),
            ("yes\u{2013}no", ["yes", "no"]),
            ("wait\u{2026} then go", ["wait", "then", "go"]),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(Normalize.tokens(input, profile: .asr), expected, input)
        }
    }

    /// Case folding is ICU-root, not locale-driven, and diacritics are PRESERVED
    /// — an engine that heard "cafe" for "café" made a real error and must be
    /// charged for it.
    func testAsrLowercasesButKeepsDiacritics() {
        XCTAssertEqual(Normalize.tokens("Café Zoë Ångström", profile: .asr),
                       ["café", "zoë", "ångström"])
        XCTAssertNotEqual(Normalize.tokens("café", profile: .asr),
                          Normalize.tokens("cafe", profile: .asr))
    }

    func testAsrNFKCFoldsCompatibilityForms() {
        // Fullwidth digits and letters are the shape a TTS script can leak.
        XCTAssertEqual(Normalize.tokens("\u{FF21}\u{FF22}\u{FF11}\u{FF12}", profile: .asr),
                       ["ab12"])
    }

    func testAsrCollapsesSingleLetterRuns() {
        let cases: [(String, [String])] = [
            ("j s o n", ["json"]),
            ("the j s o n file", ["the", "json", "file"]),
            ("S-H-A-R-I-Q-U-E", ["sharique"]),
            ("spell it K R Z Y S Z T O F", ["spell", "it", "krzysztof"]),
            // A lone single-letter token is not a run.
            ("a file", ["a", "file"]),
            ("e mail", ["email"]),   // "e" alone → run of one → left for the variant table
            // Digits are not letters: a clock time must not glue.
            ("3 15", ["3", "15"]),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(Normalize.tokens(input, profile: .asr), expected, input)
        }
    }

    /// The ITN table is canonicalization, so it must land ref and hyp on the
    /// same tokens no matter which side spelled the number out.
    func testAsrITNIsSymmetric() {
        let pairs: [(String, String, [String])] = [
            ("twenty three", "23", ["23"]),
            ("one hundred twenty three", "123", ["123"]),
            ("zero", "0", ["0"]),
            ("nine hundred ninety nine", "999", ["999"]),
            ("the thirty first", "the 31st", ["the", "31st"]),
            ("the first item", "the 1st item", ["the", "1st", "item"]),
            ("the twelfth", "the 12th", ["the", "12th"]),
            ("five dollars", "$5", ["5", "dollars"]),
            ("fifty percent", "50%", ["50", "percent"]),
            ("three fifteen", "3:15", ["3", "15"]),
        ]
        for (spelled, digits, expected) in pairs {
            XCTAssertEqual(Normalize.tokens(spelled, profile: .asr), expected, spelled)
            XCTAssertEqual(Normalize.tokens(digits, profile: .asr), expected, digits)
        }
    }

    /// Nothing outside the table is normalized — no number parser, no fuzzy
    /// matching. That is what keeps the profile honest.
    func testAsrLeavesUnenumeratedFormsAlone() {
        XCTAssertEqual(Normalize.tokens("one thousand", profile: .asr), ["1", "thousand"])
        XCTAssertEqual(Normalize.tokens("1000", profile: .asr), ["1000"])
        XCTAssertEqual(Normalize.tokens("thirty second", profile: .asr), ["30", "2nd"])
        XCTAssertEqual(Normalize.tokens("fortieth", profile: .asr), ["fortieth"])
    }

    func testITNTableShape() {
        XCTAssertEqual(Normalize.itnTable.count, 1000 + 31)
        XCTAssertEqual(Normalize.itnTable["twenty three"], "23")
        XCTAssertEqual(Normalize.itnTable["nine hundred ninety nine"], "999")
        XCTAssertEqual(Normalize.itnTable["one hundred"], "100")
        XCTAssertEqual(Normalize.itnTable["zero"], "0")
        XCTAssertEqual(Normalize.itnTable["first"], "1st")
        XCTAssertEqual(Normalize.itnTable["second"], "2nd")
        XCTAssertEqual(Normalize.itnTable["third"], "3rd")
        XCTAssertEqual(Normalize.itnTable["eleventh"], "11th")
        XCTAssertEqual(Normalize.itnTable["twelfth"], "12th")
        XCTAssertEqual(Normalize.itnTable["thirteenth"], "13th")
        XCTAssertEqual(Normalize.itnTable["twentieth"], "20th")
        XCTAssertEqual(Normalize.itnTable["twenty first"], "21st")
        XCTAssertEqual(Normalize.itnTable["thirtieth"], "30th")
        XCTAssertEqual(Normalize.itnTable["thirty first"], "31st")
        XCTAssertNil(Normalize.itnTable["thirty second"])
    }

    func testAsrVariantMap() {
        let pairs: [(String, String)] = [
            ("okay", "ok"),
            ("e mail", "email"),
            ("e-mail", "email"),
            ("git hub", "github"),
            ("PostgreSQL", "postgres"),
            ("Postgres", "postgres"),
        ]
        for (input, canonical) in pairs {
            XCTAssertEqual(Normalize.tokens(input, profile: .asr), [canonical], input)
        }
        // Four pairs, and only four: every entry is a decision to stop measuring.
        XCTAssertEqual(Normalize.variantTable.count, 4)
        XCTAssertNil(Normalize.variantTable["postgre sql"])
    }

    // MARK: - .rendered

    func testRenderedKeepsCaseAndPunctuation() {
        XCTAssertEqual(Normalize.tokens("Hello, World!", profile: .rendered),
                       ["Hello,", "World!"])
        XCTAssertEqual(Normalize.tokens("write-heavy", profile: .rendered), ["write-heavy"])
        XCTAssertEqual(Normalize.tokens("a  \n  b", profile: .rendered), ["a", "b"])
        // Quotes still fold, so a smart-quote setting cannot move the number.
        XCTAssertEqual(Normalize.tokens("it\u{2019}s", profile: .rendered), ["it's"])
        // …and NFKC still applies.
        XCTAssertEqual(Normalize.tokens("\u{FF21}", profile: .rendered), ["A"])
    }

    // MARK: - .light

    func testLightToleratesWhitespaceAndTrailingPunctuation() {
        XCTAssertEqual(Normalize.tokens("Hello world.", profile: .light), ["Hello", "world"])
        XCTAssertEqual(Normalize.tokens("Hello   world", profile: .light), ["Hello", "world"])
        XCTAssertEqual(Normalize.tokens("Hello world!!!", profile: .light), ["Hello", "world"])
        XCTAssertEqual(Normalize.tokens("Hello world \u{2026}", profile: .light),
                       ["Hello", "world"])
        // Internal punctuation and case are edits.
        XCTAssertEqual(Normalize.tokens("Hello, world", profile: .light), ["Hello,", "world"])
        XCTAssertNotEqual(Normalize.tokens("Hello world", profile: .light),
                          Normalize.tokens("hello world", profile: .light))
        XCTAssertEqual(Normalize.tokens("...", profile: .light), [])
    }

    // MARK: - profiles disagree, on purpose

    func testProfilesDisagreeOnFormatting() {
        let ref = "Hello, World!"
        let hyp = "hello world"
        XCTAssertEqual(Normalize.tokens(ref, profile: .asr), Normalize.tokens(hyp, profile: .asr))
        XCTAssertNotEqual(Normalize.tokens(ref, profile: .rendered),
                          Normalize.tokens(hyp, profile: .rendered))
        XCTAssertNotEqual(Normalize.tokens(ref, profile: .light),
                          Normalize.tokens(hyp, profile: .light))
    }
}
