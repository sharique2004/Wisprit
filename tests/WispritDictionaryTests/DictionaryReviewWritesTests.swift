import XCTest
import WispritKit
@testable import WispritDictionary

/// The store edits the Dictionary page's review and undo stand on: removing
/// some `hear` phrases, recording a "keep" decision, merging a term listed
/// twice, and snapshot/restore. Every one of them must leave keys it does not
/// own exactly as it found them, because `dictionary.json` is hand-edited.
final class DictionaryReviewWritesTests: XCTestCase {

    private var root: URL!
    private var path: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wisprit-dict-review-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        path = root.appendingPathComponent("dictionary.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func seed(_ json: String) throws {
        try json.write(to: path, atomically: true, encoding: .utf8)
    }

    private func raw() throws -> String {
        try String(contentsOf: path, encoding: .utf8)
    }

    private func entries() throws -> [[String: Any]] {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any]
        return object?["terms"] as? [[String: Any]] ?? []
    }

    private static let ploy = """
        {"terms": [
          {"term": "InsForge", "hear": ["in forge"]},
          {"term": "Ploy", "hear": ["play", "employ", "ploy", "place"],
           "source": "vocab_retro", "hit_count": 2, "learned_at": "2026-11-07T08:30:30Z",
           "last_used": "2026-11-07T08:30:30Z", "note": "hand-written"}
        ]}
        """

    // MARK: - removeHears

    func testRemovingHearsKeepsEveryOtherKeyAndPhrase() throws {
        try seed(Self.ploy)
        let store = DictionaryStore(path: path)
        XCTAssertEqual(store.applyCorrections(to: "let's play later"), "let's Ploy later",
                       "the exact pass rewrites a hear phrase that is an everyday word")

        XCTAssertTrue(store.removeHears(["PLAY", " employ ", "place"], from: "ploy"))

        let ploy = try entries()[1]
        XCTAssertEqual(ploy["hear"] as? [String], ["ploy"], "case-insensitive, order kept")
        XCTAssertEqual(ploy["hit_count"] as? Int, 2)
        XCTAssertEqual(ploy["learned_at"] as? String, "2026-11-07T08:30:30Z")
        XCTAssertEqual(ploy["source"] as? String, "vocab_retro")
        XCTAssertEqual(ploy["note"] as? String, "hand-written", "unknown keys survive")
        XCTAssertEqual(store.applyCorrections(to: "let's play later"), "let's play later")
        XCTAssertEqual(store.terms(), ["InsForge", "Ploy"], "the term itself keeps working")
    }

    func testRemovingAbsentHearsWritesNothing() throws {
        try seed(Self.ploy)
        let store = DictionaryStore(path: path)
        let before = try raw()

        XCTAssertFalse(store.removeHears(["banana"], from: "Ploy"))
        XCTAssertFalse(store.removeHears(["play"], from: "Nope"))
        XCTAssertEqual(try raw(), before)
    }

    // MARK: - keepHears

    func testKeepingRecordsTheDecisionAndChangesNoCorrection() throws {
        try seed(Self.ploy)
        let store = DictionaryStore(path: path)

        XCTAssertTrue(store.keepHears(["play", "employ"], for: "Ploy"))
        XCTAssertTrue(store.keepHears(["PLAY", "place"], for: "Ploy"), "a later keep adds")
        XCTAssertFalse(store.keepHears(["place"], for: "Ploy"), "already kept: no write")

        let ploy = try entries()[1]
        XCTAssertEqual(ploy[DictionaryStore.keptHearsKey] as? [String], ["play", "employ", "place"])
        XCTAssertEqual(ploy["hear"] as? [String], ["play", "employ", "ploy", "place"])
        XCTAssertEqual(store.applyCorrections(to: "let's play later"), "let's Ploy later",
                       "keep is a review decision, not vocabulary")
        XCTAssertEqual(store.learnedEntries()[1].keptHears, ["play", "employ", "place"])
    }

    /// Backward compatible both ways: a file without the key reads as nothing
    /// kept, and an older writer's additive merge carries the key through.
    func testKeptHearsSurviveOtherWritersAndOlderFilesReadAsNothingKept() throws {
        try seed(Self.ploy)
        let store = DictionaryStore(path: path)
        XCTAssertEqual(store.learnedEntries().map(\.keptHears), [[], []])

        store.keepHears(["play"], for: "Ploy")
        store.add(LearnedTerm(term: "Ploy", heard: ["plo"], source: "vocab_retro"))
        store.recordUse(term: "Ploy")

        XCTAssertEqual(try entries()[1][DictionaryStore.keptHearsKey] as? [String], ["play"])
        XCTAssertEqual(DictionaryStore(path: path).learnedEntries()[1].keptHears, ["play"])
    }

    // MARK: - mergeDuplicates

    func testMergingFoldsEveryCopyIntoTheFirst() throws {
        try seed("""
            {"terms": [
              {"term": "Spotnana", "hear": ["spot nana", "spotnara"], "hit_count": 2,
               "last_used": "2026-08-01T00:00:00Z", "learned_at": "2026-07-01T00:00:00Z"},
              {"term": "InsForge", "hear": ["in forge"]},
              {"term": "spotnana", "hear": ["spot nana", "spot nona"], "hit_count": 3,
               "last_used": "2026-09-01T00:00:00Z", "learned_at": "2026-06-01T00:00:00Z",
               "note": "second copy"}
            ]}
            """)
        let store = DictionaryStore(path: path)

        XCTAssertTrue(store.mergeDuplicates(of: "SPOTNANA"))

        let list = try entries()
        XCTAssertEqual(list.map { $0["term"] as? String }, ["Spotnana", "InsForge"])
        XCTAssertEqual(list[0]["hear"] as? [String], ["spot nana", "spotnara", "spot nona"])
        XCTAssertEqual(list[0]["hit_count"] as? Int, 5)
        XCTAssertEqual(list[0]["last_used"] as? String, "2026-09-01T00:00:00Z", "latest use")
        XCTAssertEqual(list[0]["learned_at"] as? String, "2026-06-01T00:00:00Z", "earliest learn")
        XCTAssertEqual(list[0]["note"] as? String, "second copy", "a field only one copy had")
        XCTAssertFalse(store.mergeDuplicates(of: "Spotnana"), "listed once now: nothing to do")
    }

    func testOneLiveCopyMakesTheMergedTermLive() throws {
        try seed("""
            {"terms": [
              {"term": "Krzysztof", "pending": true, "observations": ["Christoph"]},
              {"term": "Krzysztof", "hear": ["kristof"]}
            ]}
            """)
        let store = DictionaryStore(path: path)
        XCTAssertTrue(store.mergeDuplicates(of: "Krzysztof"))

        let entry = try entries()[0]
        XCTAssertNil(entry["pending"])
        XCTAssertNil(entry["observations"])
        XCTAssertEqual(entry["hear"] as? [String], ["kristof", "Christoph"])
        XCTAssertEqual(store.terms(), ["Krzysztof"])
    }

    // MARK: - snapshot / restore

    /// Undo of a delete puts the term back byte for byte, at its old position,
    /// every copy of it, unknown keys and stats included.
    func testRestoringASnapshotUndoesADeleteExactly() throws {
        try seed("""
            {"terms": [
              {"term": "Spotnana", "hear": ["spot nana"], "x-custom": [1, 2.50, null]},
              {"term": "InsForge", "hear": ["in forge"]},
              {"term": "spotnana", "hear": ["spot nona"], "hit_count": 3}
            ]}
            """)
        let store = DictionaryStore(path: path)
        store.removeTerm("InsForge")  // normalize the file through one write first
        store.restore(DictionaryStore.TermSnapshot(key: "insforge", entries: []))
        let normalized = try raw()

        let snapshot = store.snapshot(term: "Spotnana")
        XCTAssertEqual(snapshot.key, "spotnana")
        XCTAssertFalse(snapshot.isEmpty)

        store.removeTerm("Spotnana")
        XCTAssertFalse(try raw().contains("potnana"), "both copies are gone")

        store.restore(snapshot)
        XCTAssertEqual(try raw(), normalized)
        XCTAssertEqual(store.learnedEntries().map(\.term), ["Spotnana", "spotnana"])
    }

    func testRestoringReplacesInPlaceAndAnEmptySnapshotRemoves() throws {
        try seed(Self.ploy)
        let store = DictionaryStore(path: path)
        let before = store.snapshot(term: "Ploy")

        store.removeHears(["play"], from: "Ploy")
        store.restore(before)
        XCTAssertEqual(store.heardPhrases(for: "Ploy"), ["play", "employ", "ploy", "place"])
        XCTAssertEqual(store.learnedEntries().map(\.term), ["InsForge", "Ploy"], "same position")

        let missing = store.snapshot(term: "Qwen")
        XCTAssertTrue(missing.isEmpty)
        store.add(LearnedTerm(term: "Qwen", heard: ["quinn"], source: "manual"))
        store.restore(missing)
        XCTAssertFalse(store.terms().contains("Qwen"), "restoring 'absent' undoes an add")
    }
}
