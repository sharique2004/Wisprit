import XCTest
import WispritKit
@testable import WispritPostProcess

/// Test double for the WispritDictionary target's `CorrectionApplying`: the
/// compiled substitutions of `wisprit/dictionary.py::_load` (longest-source
/// first with a *stable* tie-break, `\s+`-relaxed multi-word phrases,
/// word-bounded, case-insensitive, plus self-casing of every term). The
/// goldens below were produced by the real Python `Dictionary`, so any drift
/// between this double and the shipping store shows up as a test failure.
struct FakeDictionary: CorrectionApplying {
    private let compiled: [(NSRegularExpression, String)]

    init(_ entries: [(term: String, hear: [String])]) {
        var pairs: [(source: String, replacement: String)] = []
        for entry in entries {
            pairs.append((entry.term, entry.term))
            for hear in entry.hear where !hear.isEmpty { pairs.append((hear, entry.term)) }
        }
        // Python sorts by descending source length; list.sort is stable, so
        // equal-length sources keep their file order.
        let ordered = pairs.enumerated()
            .sorted { ($0.element.source.count, $1.offset) > ($1.element.source.count, $0.offset) }
            .map(\.element)
        compiled = ordered.compactMap { pair in
            let body = Self.escape(pair.source).replacingOccurrences(of: #"\ "#, with: #"\s+"#)
            guard let re = try? NSRegularExpression(pattern: #"\b"# + body + #"\b"#,
                                                    options: [.caseInsensitive]) else { return nil }
            return (re, pair.replacement)
        }
    }

    func applyCorrections(to text: String) -> String {
        var text = text
        for (re, replacement) in compiled {
            text = re.stringByReplacingMatches(
                in: text, options: [], range: NSRange(location: 0, length: (text as NSString).length),
                withTemplate: NSRegularExpression.escapedTemplate(for: replacement))
        }
        return text
    }

    /// Python 3.7+ `re.escape`: only characters that can carry regex meaning,
    /// and the space IS one of them (that is what makes the `\ ` -> `\s+`
    /// relaxation possible).
    private static let specials = Set(#"()[]{}?*+-|^$\.&~# "# + "\t\n\r\u{0B}\u{0C}")
    private static func escape(_ s: String) -> String {
        String(s.flatMap { specials.contains($0) ? ["\\", $0] : [$0] })
    }
}

private let goldenDictionary = FakeDictionary([
    (term: "InsForge", hear: ["in forge", "ins forge"]),
    (term: "Wispr Flow", hear: ["whisper flow"]),
    (term: "Claude", hear: ["clod"]),
    (term: "PostgreSQL", hear: ["post grass sequel"]),
])

// MARK: - Golden parity

final class GoldenParityTests: XCTestCase {
    /// The Python value is the expectation unless `MeasuredDivergences`
    /// supersedes it — a deliberate behavior change, recorded there with the
    /// measurement that justifies it, so `Goldens.swift` can stay a literal
    /// (regenerable) snapshot of the Python run.
    private func assertGolden(_ cases: [(raw: String, expected: String)],
                              _ options: PostProcessOptions,
                              corrections: (any CorrectionApplying)? = nil,
                              file: StaticString = #filePath, line: UInt = #line) {
        for (raw, python) in cases {
            XCTAssertEqual(PostProcess.process(raw, options: options, corrections: corrections),
                           MeasuredDivergences.expectation(raw, python),
                           "input: \(raw.debugDescription)", file: file, line: line)
        }
    }

    func testDefaults() {
        assertGolden(Goldens.defaults, PostProcessOptions())
        XCTAssertGreaterThanOrEqual(Goldens.defaults.count, 60)
    }

    func testFillerRemovalDisabled() {
        assertGolden(Goldens.fillerOff, PostProcessOptions(fillerRemoval: false))
    }

    func testEnsureSentencePeriod() {
        assertGolden(Goldens.ensurePeriod, PostProcessOptions(ensureSentencePeriod: true))
    }

    func testLeadingSpaceAlways() {
        assertGolden(Goldens.leadingAlways, PostProcessOptions(leadingSpace: .always))
    }

    func testLeadingSpaceNever() {
        assertGolden(Goldens.leadingNever, PostProcessOptions(leadingSpace: .never))
    }

    func testChainedOptions() {
        assertGolden(Goldens.leadingAlwaysPeriod,
                     PostProcessOptions(ensureSentencePeriod: true, leadingSpace: .always))
    }

    func testDictionaryStage() {
        assertGolden(Goldens.dictionary, PostProcessOptions(), corrections: goldenDictionary)
    }
}

// MARK: - Contract behaviors not expressible as a golden pair

final class PostProcessContractTests: XCTestCase {
    func testNilAndEmptyInput() {
        XCTAssertEqual(PostProcess.process(nil), "")
        XCTAssertEqual(PostProcess.process(""), "")
    }

    func testDefaultArgumentsMatchPythonDefaults() {
        // process(text) with everything omitted: fillers on, no dictionary, no
        // forced period, leading space "auto".
        XCTAssertEqual(PostProcess.process("um hello world"), "hello world")
        XCTAssertEqual(PostProcess.process("this is a sentence"), "this is a sentence")
    }

    func testDictionaryStageRunsBeforeEmailJoin() {
        // Ordering proof: the dictionary rewrites the local part, and the email
        // joiner still fires on the rewritten text.
        let dict = FakeDictionary([(term: "Sharique", hear: ["sha reek"])])
        XCTAssertEqual(
            PostProcess.process("sha reek at gmail dot com", corrections: dict),
            "Sharique@gmail.com")
    }

    func testCorrectionFailureIsNotFatal() {
        struct Exploding: CorrectionApplying {
            func applyCorrections(to text: String) -> String { text }
        }
        XCTAssertEqual(PostProcess.process("um hi", corrections: Exploding()), "hi")
    }

    func testOptionsFromSettingsGetter() {
        let settings: [String: Any] = [
            "filler_removal": false,
            "ensure_sentence_period": true,
            "leading_space": "always",
        ]
        let options = PostProcessOptions { settings[$0] }
        XCTAssertEqual(options, PostProcessOptions(fillerRemoval: false,
                                                   ensureSentencePeriod: true,
                                                   leadingSpace: .always))
    }

    func testOptionsFromSettingsFallsBackOnMissingAndBogusValues() {
        // Python `_get` returns the default for a missing/None key, and
        // `_apply_leading_space` ignores an unrecognized policy string.
        let options = PostProcessOptions { _ in nil }
        XCTAssertEqual(options, PostProcessOptions())
        let bogus = PostProcessOptions { $0 == "leading_space" ? "sideways" : nil }
        XCTAssertEqual(bogus.leadingSpace, .auto)
    }

    func testFreemailSetIsTheEighteenPythonEntries() {
        // "me" and "pm" are in the set; "example" and "acme" are not.
        XCTAssertEqual(PostProcess.process("john at me dot com"), "john@me.com")
        XCTAssertEqual(PostProcess.process("john at pm dot me"), "john@pm.me")
        XCTAssertEqual(PostProcess.process("john at acme dot com"), "john at acme.com")
    }

    func testTldAllowlistIsElevenEntries() {
        for tld in ["com", "org", "net", "io", "ai", "dev", "co", "edu", "gov", "app", "me"] {
            XCTAssertEqual(PostProcess.process("go to example dot \(tld)"), "go to example.\(tld)")
        }
        for tld in ["xyz", "info", "biz", "uk"] {
            XCTAssertEqual(PostProcess.process("go to example dot \(tld)"),
                           "go to example dot \(tld)")
        }
    }

    func testDeterminerAndContinuationGuards() {
        for determiner in ["a", "an", "the", "this", "that", "another", "each", "every", "one",
                           "my", "your", "our", "his", "her", "their", "its", "some", "any", "no"] {
            let raw = "\(determiner) new line of work"
            XCTAssertEqual(PostProcess.process(raw), raw, determiner)
        }
        for continuation in ["of", "in", "on", "at", "to", "for", "with", "from", "by", "and",
                             "or", "that", "which", "is", "was", "are", "were", "between",
                             "through", "than"] {
            let raw = "draw new line \(continuation) here"
            XCTAssertEqual(PostProcess.process(raw), raw, continuation)
        }
    }

    func testSpelledNumbersAreNeverConverted() {
        // Deliberate non-feature (docs/notes/deviations.md): no digit conversion.
        XCTAssertEqual(PostProcess.process("one more thing"), "one more thing")
        XCTAssertEqual(PostProcess.process("twenty three items"), "twenty three items")
    }

    func testStagesAreIndividuallyAddressable() {
        XCTAssertEqual(PostProcess.removeFillers("um hi uh there"), " hi  there")
        XCTAssertEqual(PostProcess.joinDotted("a dot b dot c"), "a.b.c")
        XCTAssertEqual(PostProcess.joinURL("go to example dot COM"), "go to example.com")
        XCTAssertEqual(PostProcess.selfCorrect("we need to to fix"), "we need to fix")
        // Post-Python stage; the behavior table is EmojiCommandTests.swift.
        XCTAssertEqual(PostProcess.applyEmoji("nice work fire emoji"), "nice work 🔥")
        XCTAssertEqual(PostProcess.cleanupWhitespace("  a  ,  b  "), "a, b")
        XCTAssertEqual(PostProcess.applyLeadingSpace("x", .always), " x")
        XCTAssertEqual(PostProcess.applyLeadingSpace("  x", .never), "x")
        XCTAssertEqual(PostProcess.applyLeadingSpace("  x", .auto), "  x")
    }

    func testLatencyBudget() {
        // Contract: the whole pipeline is <20 ms; measured p50 = 1 ms in Python.
        let raw = String(repeating: "um so I pushed the fix to in forge no wait to production ",
                         count: 40)
        let start = DispatchTime.now().uptimeNanoseconds
        _ = PostProcess.process(raw, corrections: goldenDictionary)
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        XCTAssertLessThan(ms, 20)
    }
}

// MARK: - Randomized differential parity

final class FuzzParityTests: XCTestCase {
    func testFourHundredRandomTokenSaladsMatchPython() {
        for (raw, python) in FuzzGoldens.cases {
            XCTAssertEqual(PostProcess.process(raw),
                           MeasuredDivergences.expectation(raw, python),
                           "input: \(raw.debugDescription)")
        }
        XCTAssertEqual(FuzzGoldens.cases.count, 400)
    }

    /// The divergence table is an exception list, so it has to stay exactly as
    /// long as the exceptions: an entry that no longer fires (the parity value
    /// came back) is dead and would silently mask the next drift.
    func testEveryRecordedDivergenceStillDiverges() {
        let parity = Dictionary(
            (Goldens.defaults + FuzzGoldens.cases).map { ($0.raw, $0.expected) },
            uniquingKeysWith: { first, _ in first })
        for (raw, native) in MeasuredDivergences.outputs {
            XCTAssertEqual(PostProcess.process(raw), native, "input: \(raw.debugDescription)")
            guard let python = parity[raw] else {
                return XCTFail("not a parity fixture: \(raw.debugDescription)")
            }
            XCTAssertNotEqual(native, python,
                              "stale divergence entry: \(raw.debugDescription)")
        }
        XCTAssertEqual(MeasuredDivergences.outputs.count, 4)
    }
}
