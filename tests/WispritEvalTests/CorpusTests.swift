import XCTest
@testable import WispritEval

final class CorpusTests: XCTestCase {

    static let humanLine = """
        {"id":"h-001","audio":"wav/h-001.wav","sha256":"abc123","ref":"Add this to Wisprit \
        and InsForge.","category":"proper-nouns","speaker":"sk","source":"human","mic":"internal",\
        "script":"human-v1","durationMs":3400,"expect":{"terms":["Wisprit","InsForge"],\
        "refineBypass":null}}
        """

    static let ttsLine = """
        {"id":"t-001","audio":"wav/t-001.wav","sha256":"def456","ref":"Email me at \
        john at example dot com.","category":"addresses","speaker":"samantha","source":"tts",\
        "expect":{"terms":[],"refineBypass":"has_address"}}
        """

    func testParsesAFullManifestLine() throws {
        let entries = try Corpus.parse(jsonl: Self.humanLine)
        XCTAssertEqual(entries.count, 1)
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.id, "h-001")
        XCTAssertEqual(entry.audio, "wav/h-001.wav")
        XCTAssertEqual(entry.sha256, "abc123")
        XCTAssertEqual(entry.ref, "Add this to Wisprit and InsForge.")
        XCTAssertEqual(entry.category, "proper-nouns")
        XCTAssertEqual(entry.speaker, "sk")
        XCTAssertEqual(entry.source, .human)
        XCTAssertEqual(entry.mic, "internal")
        XCTAssertEqual(entry.script, "human-v1")
        XCTAssertEqual(entry.durationMs, 3400)
        XCTAssertEqual(entry.expect?.terms, ["Wisprit", "InsForge"])
        XCTAssertNil(entry.expect?.refineBypass)
    }

    func testOptionalFieldsMayBeAbsent() throws {
        let entry = try XCTUnwrap(try Corpus.parse(jsonl: Self.ttsLine).first)
        XCTAssertNil(entry.mic)
        XCTAssertNil(entry.script)
        XCTAssertNil(entry.durationMs)
        XCTAssertEqual(entry.expect?.refineBypass, "has_address")
    }

    func testBlankAndCommentLinesAreSkipped() throws {
        let text = "# corpus: human-v1 (dev split)\n\n" + Self.humanLine + "\n\n" + Self.ttsLine
        XCTAssertEqual(try Corpus.parse(jsonl: text).map(\.id), ["h-001", "t-001"])
    }

    /// Provenance is the one field the scoreboard's honesty rests on: a row
    /// whose audio source is unknown could be a TTS number quoted as accuracy.
    func testMissingSourceFailsLoudlyAndByName() {
        let line = """
            {"id":"x","audio":"a.wav","sha256":"s","ref":"hi","category":"c","speaker":"sk"}
            """
        XCTAssertThrowsError(try Corpus.parse(jsonl: line)) { error in
            XCTAssertEqual(error as? CorpusError, .missingField(line: 1, field: "source"))
            XCTAssertTrue("\(error)".contains("source"), "\(error)")
        }
    }

    func testUnknownSourceIsRejected() {
        let line = """
            {"id":"x","audio":"a.wav","sha256":"s","ref":"hi","category":"c","speaker":"sk",\
            "source":"synthetic"}
            """
        XCTAssertThrowsError(try Corpus.parse(jsonl: line)) { error in
            XCTAssertEqual(error as? CorpusError, .unknownSource(line: 1, value: "synthetic"))
        }
    }

    func testOtherMissingFieldsAlsoNameThemselves() {
        let line = """
            {"id":"x","audio":"a.wav","sha256":"s","category":"c","speaker":"sk","source":"tts"}
            """
        XCTAssertThrowsError(try Corpus.parse(jsonl: line)) { error in
            XCTAssertEqual(error as? CorpusError, .missingField(line: 1, field: "ref"))
        }
    }

    func testLineNumbersSurviveBlankLines() {
        let text = "\n\n" + Self.humanLine + "\nnot json\n"
        XCTAssertThrowsError(try Corpus.parse(jsonl: text)) { error in
            guard case let .malformedLine(line, _)? = error as? CorpusError else {
                return XCTFail("expected malformedLine, got \(error)")
            }
            XCTAssertEqual(line, 4)
        }
    }

    func testDuplicateIDsAreRejected() {
        let text = Self.humanLine + "\n" + Self.humanLine
        XCTAssertThrowsError(try Corpus.parse(jsonl: text)) { error in
            XCTAssertEqual(error as? CorpusError, .duplicateID(line: 2, id: "h-001"))
        }
    }

    func testEmptyManifestIsAnError() {
        XCTAssertThrowsError(try Corpus.parse(jsonl: "\n# nothing\n")) { error in
            XCTAssertEqual(error as? CorpusError, .empty)
        }
    }

    func testCorpusReportsItsSource() throws {
        let tts = try Corpus.load(jsonl: Self.ttsLine, id: "tts-samantha", split: "dev")
        XCTAssertEqual(tts.source, .tts)
        XCTAssertEqual(tts.sources, [.tts])

        let mixed = try Corpus.load(jsonl: Self.humanLine + "\n" + Self.ttsLine,
                                    id: "mixed", split: "dev")
        XCTAssertNil(mixed.source, "a mixed corpus must not claim a single provenance")
        XCTAssertEqual(mixed.sources, [.human, .tts])
    }

    func testCategoriesAreDistinctAndOrdered() throws {
        let corpus = try Corpus.load(jsonl: Self.humanLine + "\n" + Self.ttsLine,
                                     id: "mixed", split: "dev")
        XCTAssertEqual(corpus.categories, ["proper-nouns", "addresses"])
        XCTAssertEqual(corpus.entries(inCategory: "addresses").map(\.id), ["t-001"])
    }
}

/// The per-utterance detail the aggregates are built from — the artifact that
/// turns "WER moved" into "this utterance, at this stage".
final class StageRecordTests: XCTestCase {

    static let full = StageRecord(
        id: "h-001", engine: "apple_live",
        raw: "add this to wisprit and ins forge",
        corrected: "add this to wisprit and ins forge",
        refined: "Add this to Wisprit and ins forge.",
        final: "Add this to Wisprit and InsForge.",
        vocab: "add this to Wisprit and InsForge", ai: "applied", aiMs: 812.5,
        finalizeMs: 91.0, timedOut: false, starvedInput: false,
        vocabHits: 2, vocabMs: 2400.0)

    static let minimal = StageRecord(id: "h-002", engine: "apple_live", raw: "hi",
                                     corrected: "hi", refined: "hi", final: "Hi.")

    func testJSONLRoundTrips() throws {
        let text = try StageRecord.jsonl([Self.full, Self.minimal])
        XCTAssertEqual(try StageRecord.decode(jsonl: text), [Self.full, Self.minimal])
        XCTAssertEqual(text.components(separatedBy: "\n").filter { !$0.isEmpty }.count, 2)
    }

    /// One record is one line, and the same record always produces the same
    /// bytes — a re-run over identical inputs must not show up as a diff.
    func testLinesAreSingleLineAndStable() throws {
        let line = try Self.full.jsonLine()
        XCTAssertFalse(line.contains("\n"))
        XCTAssertEqual(line, try Self.full.jsonLine())
        XCTAssertTrue(line.hasPrefix("{\"ai\""), line)   // sorted keys
    }

    /// Absent stages are omitted, not nulled, so a partial run (ASR only) still
    /// writes valid lines and a field added later does not invalidate old ones.
    func testOptionalStagesAreOmitted() throws {
        let line = try Self.minimal.jsonLine()
        XCTAssertFalse(line.contains("vocab"), line)
        XCTAssertFalse(line.contains("null"), line)
        XCTAssertEqual(try StageRecord.decode(jsonl: line), [Self.minimal])
    }

    func testDecodeReportsTheOffendingLine() {
        let text = try! Self.minimal.jsonLine() + "\n{\"id\":\"broken\"}\n"
        XCTAssertThrowsError(try StageRecord.decode(jsonl: text)) { error in
            guard case let .malformedLine(line, _)? = error as? StageRecordError else {
                return XCTFail("expected malformedLine, got \(error)")
            }
            XCTAssertEqual(line, 2)
        }
    }
}
