import XCTest
import WispritKit
@testable import WispritMac

/// The data inventory (R17): every class of thing Wisprit keeps, sized and
/// deletable, over a temp state dir. The claims worth pinning are the soul
/// ones — the catalog names the same files the stores use, the purge actually
/// removes what it says, and settings are never swept up in a data purge.
final class DataInventoryTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wisprit-inventory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ name: String, bytes: Int) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(repeating: 0x61, count: bytes).write(to: url)
        return url
    }

    // MARK: - the catalog

    /// The inventory is a catalog over files the stores already own — its
    /// names must be `WispritPaths`' names, or the page lists a parallel
    /// universe. Pinned by basename so the check survives any root.
    func testTheCatalogNamesTheStoresOwnFiles() {
        func names(_ id: DataStoreID) -> [String] {
            DataInventory.files(for: id, root: root).map(\.lastPathComponent)
        }
        XCTAssertTrue(names(.transcripts).contains(WispritPaths.historyPath.lastPathComponent))
        XCTAssertEqual(names(.metrics), [WispritPaths.metricsPath.lastPathComponent])
        XCTAssertTrue(names(.dictionary).contains(WispritPaths.dictionaryPath.lastPathComponent))
        XCTAssertEqual(names(.settings), [WispritPaths.configPath.lastPathComponent])
        XCTAssertEqual(names(.learnLedger), ["learn_pending.json"],
                       "PendingLearnStore.defaultPath's basename")
        // The SQLite sidecars ride with the database — a size report that
        // ignored -wal would under-count what is actually on disk.
        XCTAssertTrue(names(.transcripts).contains("history.sqlite-wal"))
        XCTAssertTrue(names(.transcripts).contains("history.sqlite-shm"))
    }

    func testEveryStoreClassHasExactlyOneRowAndOnlySettingsIsUndeletable() {
        let rows = DataInventory.status(root: root)
        XCTAssertEqual(rows.map(\.id), DataStoreID.allCases)
        for row in rows {
            XCTAssertEqual(row.deletable, row.id != .settings, "\(row.id)")
            XCTAssertFalse(row.title.isEmpty)
            XCTAssertFalse(row.summary.isEmpty)
        }
        XCTAssertFalse(DataInventory.deletableClasses.contains(.settings),
                       "deleting preferences is not forgetting dictation")
        XCTAssertEqual(Set(DataInventory.deletableClasses).union([DataStoreID.settings]),
                       Set(DataStoreID.allCases),
                       "delete-everything reaches every store but settings")
    }

    // MARK: - sizes

    func testSizesAreReadFromDiskIncludingDirectoryTrees() throws {
        _ = try write("metrics.log", bytes: 120)
        _ = try write("dictionary.json", bytes: 30)
        _ = try write("dictionary.json.bak", bytes: 20)
        let models = root.appendingPathComponent("models/parakeet", isDirectory: true)
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 500).write(to: models.appendingPathComponent("weights.bin"))

        let rows = Dictionary(uniqueKeysWithValues:
            DataInventory.status(root: root).map { ($0.id, $0) })
        XCTAssertEqual(rows[.metrics]?.byteSize, 120)
        XCTAssertEqual(rows[.metrics]?.exists, true)
        XCTAssertEqual(rows[.dictionary]?.byteSize, 50, "the cleanup backup counts too")
        XCTAssertEqual(rows[.models]?.byteSize, 500, "directory trees are walked")
        XCTAssertEqual(rows[.transcripts]?.exists, false)
        XCTAssertEqual(rows[.transcripts]?.byteSize, 0)
    }

    func testAnEmptyStoreSaysNothingYetNotZeroKB() throws {
        let rows = DataInventory.status(root: root)
        for row in rows {
            XCTAssertEqual(DataInventory.sizeLabel(row), "nothing yet", "\(row.id)")
        }
        _ = try write("metrics.log", bytes: 4096)
        let metrics = DataInventory.status(root: root).first { $0.id == .metrics }!
        XCTAssertNotEqual(DataInventory.sizeLabel(metrics), "nothing yet")
    }

    // MARK: - the purge

    /// metrics.log's FIRST delete surface — the file was purge-immune for
    /// three eras (judge-soul §4.4's verified claim).
    func testPurgeRemovesExactlyTheClassItNames() throws {
        let metrics = try write("metrics.log", bytes: 10)
        let dictionary = try write("dictionary.json", bytes: 10)
        let backup = try write("dictionary.json.bak", bytes: 10)
        let ledger = try write("learn_pending.json", bytes: 10)
        let config = try write("config.json", bytes: 10)

        DataInventory.purge(.metrics, root: root)
        let manager = FileManager.default
        XCTAssertFalse(manager.fileExists(atPath: metrics.path))
        XCTAssertTrue(manager.fileExists(atPath: dictionary.path))

        DataInventory.purge(.dictionary, root: root)
        XCTAssertFalse(manager.fileExists(atPath: dictionary.path))
        XCTAssertFalse(manager.fileExists(atPath: backup.path),
                       "a delete the backup survives is not a delete")

        DataInventory.purge(.learnLedger, root: root)
        XCTAssertFalse(manager.fileExists(atPath: ledger.path))

        XCTAssertTrue(manager.fileExists(atPath: config.path),
                      "settings are never data-purged")
    }

    /// The history database has a live SQLite handle — its purge is the
    /// store's own (`History.purge()`), never a file unlink from here. And
    /// `.settings` may be asked, but nothing happens.
    func testTranscriptsAndSettingsAreNeverFileUnlinked() throws {
        let db = try write("history.sqlite", bytes: 10)
        let config = try write("config.json", bytes: 10)
        DataInventory.purge(.transcripts, root: root)
        DataInventory.purge(.settings, root: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: db.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: config.path))
    }

    func testPurgingTheModelsDirectoryFreesTheTree() throws {
        let models = root.appendingPathComponent("models", isDirectory: true)
        try FileManager.default.createDirectory(
            at: models.appendingPathComponent("parakeet", isDirectory: true),
            withIntermediateDirectories: true)
        DataInventory.purge(.models, root: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: models.path))
    }
}
