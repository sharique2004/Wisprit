import XCTest
import WispritKit
@testable import WispritDictionary

/// Byte-for-byte parity with `wisprit/dictionary.py`. Everything asserted here
/// was produced by RUNNING the real Python over the real term data — see the
/// generator command at the top of `Goldens.swift`.
final class GoldenParityTests: XCTestCase {

    struct Goldens: Decodable {
        struct Case: Decodable { let input: String; let expected: String }
        let terms: [String]
        let correctionPairs: [[String]]
        let cases: [Case]
        let writerSampleOutput: String
    }

    private var root: URL!
    private var golden: Goldens!
    private var store: DictionaryStore!

    override func setUpWithError() throws {
        root = try makeTempRoot()
        WispritPaths.overrideRoot = root
        // The raw literal drops the file's trailing newline; put it back so the
        // bytes on disk are exactly what Python read.
        try (DictGolden.dictionaryJSON + "\n")
            .write(to: WispritPaths.dictionaryPath, atomically: true, encoding: .utf8)
        golden = try JSONDecoder().decode(Goldens.self, from: Data(DictGolden.goldensJSON.utf8))
        store = DictionaryStore()
    }

    override func tearDownWithError() throws {
        WispritPaths.overrideRoot = nil
        try? FileManager.default.removeItem(at: root)
    }

    func testTermsMatchPythonOrderAndContent() {
        XCTAssertEqual(store.terms(), golden.terms)
        XCTAssertEqual(store.terms().count, 137)
    }

    /// The generated ICU pattern BODY must equal Python's `re.escape` output with
    /// `\ ` relaxed to `\s+`, and the longest-first ordering must be the same
    /// *stable* ordering Python's `sort(key=len, reverse=True)` produces.
    ///
    /// The EDGES deliberately diverge. Python wraps each pattern in `\b…\b`; a
    /// hyphen is a non-word character, so `\b` reports a boundary inside every
    /// hyphenated compound and the phrase swallows the half in front of it —
    /// measured: "The well x-ray results are in." → "The WellX-ray results are
    /// in.". `(?<![\w-])…(?![\w-])` is `\b` plus "and the neighbour is not a
    /// hyphen". The body is still the parity surface, so it is compared against
    /// the golden with only the edges swapped.
    func testCompiledCorrectionsMatchPythonPatternsAndOrder() {
        let compiled = store.corrections()
        XCTAssertEqual(compiled.count, golden.correctionPairs.count)
        XCTAssertEqual(compiled.count, 521)
        for (index, expected) in golden.correctionPairs.enumerated() {
            let python = expected[0]
            XCTAssertTrue(python.hasPrefix(#"\b"#) && python.hasSuffix(#"\b"#),
                          "golden pattern #\(index) is not \\b-wrapped: \(python)")
            let body = String(python.dropFirst(2).dropLast(2))
            XCTAssertEqual(compiled[index].pattern.pattern, #"(?<![\w-])"# + body + #"(?![\w-])"#,
                           "pattern #\(index) diverged from Python")
            XCTAssertEqual(compiled[index].replacement, expected[1],
                           "replacement #\(index) diverged from Python")
        }
    }

    /// The golden cases were produced by Python's cascading loop, which re-runs
    /// every pattern over the previous pattern's OUTPUT. That cascade is the
    /// corruption this engine was fixed to stop (it turned "We flew to Amman
    /// last night." into "…Aman UAE UAE…"), so one golden expectation moved with
    /// it — see `deviations` and the test below it.
    private static let deviations: [String: String] = [
        "we ran mlx whisper then faster whisper": "we ran mlx-whisper then faster-whisper",
    ]

    private func expectation(for testCase: Goldens.Case) -> String {
        Self.deviations[testCase.input] ?? testCase.expected
    }

    func testApplyCorrectionsMatchesPython() {
        for testCase in golden.cases {
            XCTAssertEqual(store.applyCorrections(to: testCase.input), expectation(for: testCase),
                           "input: \(testCase.input.debugDescription)")
        }
    }

    /// The one golden that moved, stated on its own so the reason is on the
    /// record rather than buried in a dictionary literal.
    ///
    /// Python reached "MLX-whisper" in two hops: "mlx whisper" → "mlx-whisper"
    /// (the term), then the 3-character "MLX" self-pattern re-matched the "mlx"
    /// of the text it had just written — legal only because `\b` sits at the
    /// hyphen — and up-cased it. Both hops are the defects: a replaced span
    /// being re-examined, and a match ending against a hyphen. Note where that
    /// left the output: "MLX-whisper" is not a term in this dictionary. The
    /// canonical spelling on file is `mlx-whisper`, which is also the real
    /// package name, so the single-pass result is the more faithful one.
    func testTheMLXCascadeNoLongerReCasesTheTermItJustWrote() {
        XCTAssertTrue(store.terms().contains("mlx-whisper"))
        XCTAssertFalse(store.terms().contains("MLX-whisper"))
        XCTAssertEqual(store.applyCorrections(to: "we ran mlx whisper then faster whisper"),
                       "we ran mlx-whisper then faster-whisper")
        // The standalone acronym still self-cases; only the compound is spared.
        XCTAssertEqual(store.applyCorrections(to: "we ran it on mlx today"),
                       "we ran it on MLX today")
    }

    /// The measured cascade, on the shipping dictionary rather than a fixture:
    /// "Aman UAE" lists both "amman" and "aman", and the old engine expanded the
    /// term it had just written a second time.
    func testTheAmanCascadeIsGoneOnTheRealDictionary() {
        XCTAssertEqual(store.applyCorrections(to: "We flew to Amman last night."),
                       "We flew to Aman UAE last night.")
        XCTAssertEqual(store.applyCorrections(to: "Aman UAE signed the contract."),
                       "Aman UAE signed the contract.")
    }

    /// Idempotence over the whole golden corpus at real scale: 137 terms, 521
    /// patterns, every generated case.
    func testEveryGoldenCaseIsIdempotent() {
        for testCase in golden.cases {
            let once = store.applyCorrections(to: testCase.input)
            XCTAssertEqual(store.applyCorrections(to: once), once,
                           "not idempotent for \(testCase.input.debugDescription)")
        }
    }

    /// With no usage data every term scores 0, so the vocabulary order collapses
    /// to file order — i.e. Python's `terms()`, minus the one duplicate the
    /// mined vault data contains.
    func testVocabularyTermsWithoutUsageMatchesFileOrder() {
        var seen = Set<String>()
        let deduped = golden.terms.filter { seen.insert($0.lowercased()).inserted }
        XCTAssertEqual(store.vocabularyTerms(), deduped)
        XCTAssertEqual(golden.terms.count - deduped.count, 1)  // "Spotnana" twice
    }

    /// Our JSON writer must be byte-compatible with
    /// `json.dumps(data, indent=2, ensure_ascii=False) + "\n"`, so parse→write
    /// of Python's own output is the identity.
    func testJSONWriterRoundTripsPythonOutput() throws {
        let parsed = try JSONValue.parse(golden.writerSampleOutput)
        XCTAssertEqual(parsed.serialized() + "\n", golden.writerSampleOutput)
    }

    /// Whole-file round-trip at real scale: learning a term and then removing it
    /// must give back the original 137-entry file byte-for-byte. Both operations
    /// rewrite the entire file through our serialiser, so this proves every
    /// untouched entry — and the file's exact Python `json.dumps` formatting —
    /// survives a write.
    func testAddThenRemoveRestoresTheFileByteForByte() throws {
        let before = try String(contentsOf: WispritPaths.dictionaryPath, encoding: .utf8)
        store.add(LearnedTerm(term: "Krzysztof", heard: ["Cherie"], source: "spoken_spelling"))
        XCTAssertNotEqual(try String(contentsOf: WispritPaths.dictionaryPath, encoding: .utf8), before)
        store.removeTerm("Krzysztof")
        XCTAssertEqual(try String(contentsOf: WispritPaths.dictionaryPath, encoding: .utf8), before)
        XCTAssertEqual(store.terms(), golden.terms)
        XCTAssertEqual(store.corrections().count, golden.correctionPairs.count)
    }

    /// The quarantine fields are additive, so they have to be invisible at real
    /// scale: writing one must leave the other 137 entries — and the file's
    /// exact Python `json.dumps` formatting — byte-identical, and must change
    /// nothing the rest of the app reads. Removing it restores the file
    /// exactly, the same guarantee `add`/`removeTerm` carry.
    func testPendingEntriesRoundTripAndChangeNothingDerived() throws {
        let before = try String(contentsOf: WispritPaths.dictionaryPath, encoding: .utf8)
        store.addPending(term: "Sharifue", observation: "Shariq")

        XCTAssertEqual(store.terms(), golden.terms)
        XCTAssertEqual(store.corrections().count, golden.correctionPairs.count)
        XCTAssertFalse(store.isKnownTerm("Sharifue"))
        XCTAssertFalse(store.vocabularyTerms().contains("Sharifue"))
        for testCase in golden.cases {
            XCTAssertEqual(store.applyCorrections(to: testCase.input), expectation(for: testCase),
                           "a pending entry changed a golden correction")
        }

        // The written file is still exactly what our serialiser round-trips,
        // and the 137 entries before it are untouched.
        let after = try String(contentsOf: WispritPaths.dictionaryPath, encoding: .utf8)
        XCTAssertEqual(try JSONValue.parse(after).serialized() + "\n", after)
        let arrayClose = try XCTUnwrap(before.range(of: "\n  ]", options: .backwards))
        XCTAssertTrue(after.hasPrefix(String(before[..<arrayClose.lowerBound])),
                      "the 137 existing entries were rewritten")
        XCTAssertTrue(after.contains(#""pending": true"#))

        store.removeTerm("Sharifue")
        XCTAssertEqual(try String(contentsOf: WispritPaths.dictionaryPath, encoding: .utf8), before)
    }

    /// 521 regex passes is the per-utterance cost. Measured on this machine
    /// (M4): 0.60 ms debug / 0.47 ms release, against 0.22 ms for the same loop
    /// in Python — ICU is ~2× CPython's `re` here, and both are noise next to
    /// the refine stage. The bound is a canary for a pathological regression
    /// (e.g. recompiling the patterns per call), not a parity target.
    func testApplyCorrectionsStaysFast() {
        let text = "hacker thought at pen state with in forge and whisper flow and clod"
        let start = Date()
        for _ in 0..<20 { _ = store.applyCorrections(to: text) }
        let msPerCall = Date().timeIntervalSince(start) * 1000 / 20
        XCTAssertLessThan(msPerCall, 10, "dictionary pass took \(msPerCall) ms/utterance")
    }
}

func makeTempRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("wisprit-dict-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
