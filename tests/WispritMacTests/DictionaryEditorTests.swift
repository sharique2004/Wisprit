import XCTest
import WispritDictionary
import WispritKit
@testable import WispritMac

/// Dictionary edits, round-tripped against a real `DictionaryStore` on a temp
/// path. Never the user's `~/.wisprit/dictionary.json`.
final class DictionaryEditorTests: XCTestCase {

    private var root: URL!
    private var path: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wisprit-dict-editor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        path = root.appendingPathComponent("dictionary.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func seed(_ json: String) throws {
        try json.write(to: path, atomically: true, encoding: .utf8)
    }

    private func editor() -> DictionaryEditor {
        DictionaryEditor(store: DictionaryStore(path: path))
    }

    private func raw() throws -> String {
        try String(contentsOf: path, encoding: .utf8)
    }

    // MARK: - reading

    func testRowsCarryTheLearnedMetadata() throws {
        try seed("""
            {"terms": [
              {"term": "InsForge", "hear": ["in forge", "ins forge"]},
              {"term": "Sharique", "hear": ["Shariq", "Cherie"],
               "source": "spoken_spelling", "learned_at": "2026-08-05T09:12:00Z",
               "hit_count": 3, "last_used": "2026-08-05T11:44:10Z"}
            ]}
            """)
        let rows = editor().rows()

        XCTAssertEqual(rows.map(\.term), ["InsForge", "Sharique"], "file order is preserved")
        XCTAssertEqual(rows[0].hear, ["in forge", "ins forge"])
        XCTAssertNil(rows[0].source)
        XCTAssertFalse(rows[0].isLearned)

        let learned = rows[1]
        XCTAssertTrue(learned.isLearned)
        XCTAssertEqual(learned.hitCount, 3)
        XCTAssertNotNil(learned.learnedAt)
        XCTAssertEqual(learned.badges, ["learned", "used 3×"])
    }

    func testSearchMatchesTheMisheardPhraseToo() throws {
        try seed("""
            {"terms": [{"term": "Sharique", "hear": ["Shariq", "Cherie"]}]}
            """)
        let row = editor().rows()[0]
        XCTAssertTrue(row.matches(""), "an empty query matches everything")
        XCTAssertTrue(row.matches("shar"))
        XCTAssertTrue(row.matches("cherie"), "the phrase the user remembers is the wrong one")
        XCTAssertFalse(row.matches("InsForge"))
    }

    // MARK: - creating

    func testAddingATermWritesItThroughTheStore() throws {
        try seed("{\"terms\": []}")
        let editor = editor()
        XCTAssertTrue(editor.save(original: nil, term: "InsForge",
                                  hear: ["in forge", " ins forge ", "in forge"]))

        let rows = editor.rows()
        XCTAssertEqual(rows.map(\.term), ["InsForge"])
        XCTAssertEqual(rows[0].hear, ["in forge", "ins forge"],
                       "phrases are trimmed and de-duplicated case-insensitively")
        XCTAssertEqual(rows[0].source, "manual")
        XCTAssertTrue(try raw().contains("InsForge"), "and it reached the file")
    }

    func testAnEmptyTermIsRefused() throws {
        try seed("{\"terms\": []}")
        let editor = editor()
        XCTAssertFalse(editor.save(original: nil, term: "   ", hear: ["nope"]))
        XCTAssertTrue(editor.rows().isEmpty)
    }

    // MARK: - editing

    /// Appending a phrase goes down the additive path, which is the only one
    /// that keeps `learned_at`, `source` and any hand-written keys.
    func testAppendingAPhraseIsALosslessMerge() throws {
        try seed("""
            {"terms": [{"term": "Sharique", "hear": ["Shariq"],
                        "source": "spoken_spelling",
                        "learned_at": "2026-08-05T09:12:00Z",
                        "note": "hand written key"}]}
            """)
        let editor = editor()
        let before = editor.rows()[0]

        let plan = DictionaryEdit.plan(original: before, term: "Sharique",
                                       hear: ["Shariq", "Cherie"])
        XCTAssertEqual(plan, .merge(term: "Sharique", heard: ["Cherie"],
                                    source: "spoken_spelling"),
                       "only the new phrase is written")
        editor.apply(plan)

        let after = editor.rows()[0]
        XCTAssertEqual(after.hear, ["Shariq", "Cherie"])
        XCTAssertEqual(after.source, "spoken_spelling")
        XCTAssertEqual(after.learnedAt, before.learnedAt, "learned_at survives")
        XCTAssertTrue(try raw().contains("hand written key"),
                      "keys this build has never heard of survive")
    }

    /// Removing a phrase cannot be expressed additively, so the entry is
    /// rewritten. The plan says so, and `source` is still carried across.
    func testRemovingAPhraseRebuildsTheEntryButKeepsTheSource() throws {
        try seed("""
            {"terms": [{"term": "Sharique", "hear": ["Shariq", "Cherie"],
                        "source": "spoken_spelling", "hit_count": 4}]}
            """)
        let editor = editor()
        let before = editor.rows()[0]

        let plan = DictionaryEdit.plan(original: before, term: "Sharique", hear: ["Shariq"])
        XCTAssertEqual(plan, .rebuild(removing: "Sharique", term: "Sharique",
                                      heard: ["Shariq"], source: "spoken_spelling"))
        editor.apply(plan)

        let after = editor.rows()[0]
        XCTAssertEqual(after.hear, ["Shariq"])
        XCTAssertEqual(after.source, "spoken_spelling", "the badge survives a rewrite")
    }

    func testRenamingATermRebuildsAndLeavesNoDuplicate() throws {
        try seed("""
            {"terms": [{"term": "Shariq", "hear": ["Cherie"]}]}
            """)
        let editor = editor()
        let before = editor.rows()[0]
        editor.save(original: before, term: "Sharique", hear: ["Cherie", "Shariq"])

        let rows = editor.rows()
        XCTAssertEqual(rows.map(\.term), ["Sharique"])
        XCTAssertEqual(rows[0].hear, ["Cherie", "Shariq"])
    }

    func testSavingWithNoChangeWritesNothing() throws {
        try seed("""
            {"terms": [{"term": "InsForge", "hear": ["in forge"]}]}
            """)
        let editor = editor()
        let before = editor.rows()[0]
        let untouched = try raw()

        XCTAssertEqual(DictionaryEdit.plan(original: before, term: "InsForge",
                                           hear: ["in forge"]), .noop)
        XCTAssertFalse(editor.save(original: before, term: "InsForge", hear: [" in forge "]))
        XCTAssertEqual(try raw(), untouched)
    }

    // MARK: - deleting

    func testDeletingRemovesOnlyThatTerm() throws {
        try seed("""
            {"terms": [{"term": "InsForge", "hear": []}, {"term": "Sharique", "hear": []}]}
            """)
        let editor = editor()
        editor.delete("insforge")   // case-insensitive, like the store

        XCTAssertEqual(editor.rows().map(\.term), ["Sharique"])
    }

    // MARK: - field parsing

    func testHearFieldRoundTrips() {
        let phrases = ["in forge", "ins forge"]
        let text = DictionaryEdit.formatHearField(phrases)
        XCTAssertEqual(text, "in forge, ins forge")
        XCTAssertEqual(DictionaryEdit.parseHearField(text), phrases)
        XCTAssertEqual(DictionaryEdit.parseHearField(" a ,, b \n c , A "), ["a", "b", "c"])
        XCTAssertEqual(DictionaryEdit.parseHearField("   "), [])
    }
}
