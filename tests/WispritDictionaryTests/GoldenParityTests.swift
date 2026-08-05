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

    /// The generated ICU pattern text must equal Python's `re.escape` output
    /// with `\ ` relaxed to `\s+`, and the longest-first ordering must be the
    /// same *stable* ordering Python's `sort(key=len, reverse=True)` produces.
    func testCompiledCorrectionsMatchPythonPatternsAndOrder() {
        let compiled = store.corrections()
        XCTAssertEqual(compiled.count, golden.correctionPairs.count)
        XCTAssertEqual(compiled.count, 521)
        for (index, expected) in golden.correctionPairs.enumerated() {
            XCTAssertEqual(compiled[index].pattern.pattern, expected[0],
                           "pattern #\(index) diverged from Python")
            XCTAssertEqual(compiled[index].replacement, expected[1],
                           "replacement #\(index) diverged from Python")
        }
    }

    func testApplyCorrectionsMatchesPython() {
        for testCase in golden.cases {
            XCTAssertEqual(store.applyCorrections(to: testCase.input), testCase.expected,
                           "input: \(testCase.input.debugDescription)")
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
