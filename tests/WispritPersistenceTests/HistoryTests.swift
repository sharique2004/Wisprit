import XCTest
import SQLite3
import WispritKit
@testable import WispritPersistence

final class HistoryTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wisprit-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func dbPath(_ name: String = "history.sqlite") -> URL {
        root.appendingPathComponent(name)
    }

    /// Settings backed by a temp config file, used purely to drive
    /// history_enabled / history_limit.
    private func settings(enabled: Bool, limit: Int) throws -> Settings {
        let p = root.appendingPathComponent("cfg-\(UUID().uuidString).json")
        let s = Settings(path: p)
        s.set(SettingsKey.historyEnabled, enabled)
        s.set(SettingsKey.historyLimit, limit)
        return s
    }

    // MARK: schema compatibility with the Python-created database

    func testSchemaMatchesThePythonCreatedDatabase() throws {
        let p = dbPath()
        let history = History(path: p, settings: nil)
        XCTAssertTrue(history.isAvailable)
        history.close()

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(p.path, &db, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close_v2(db) }

        var names: [String] = []
        var transcriptsSQL: String?
        var stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(
            db, "SELECT name, sql FROM sqlite_master ORDER BY name", -1, &stmt, nil), SQLITE_OK)
        while sqlite3_step(stmt) == SQLITE_ROW {
            let name = String(cString: sqlite3_column_text(stmt, 0))
            names.append(name)
            if name == "transcripts", let sql = sqlite3_column_text(stmt, 1) {
                transcriptsSQL = String(cString: sql)
            }
        }
        sqlite3_finalize(stmt)

        XCTAssertEqual(names, Golden.historyMasterNames)
        XCTAssertEqual(transcriptsSQL, Golden.historyTableSQL)

        var info: [(Int, String, String, Int, String?, Int)] = []
        XCTAssertEqual(sqlite3_prepare_v2(db, "PRAGMA table_info(transcripts)", -1, &stmt, nil), SQLITE_OK)
        while sqlite3_step(stmt) == SQLITE_ROW {
            info.append((
                Int(sqlite3_column_int(stmt, 0)),
                String(cString: sqlite3_column_text(stmt, 1)),
                String(cString: sqlite3_column_text(stmt, 2)),
                Int(sqlite3_column_int(stmt, 3)),
                sqlite3_column_text(stmt, 4).map { String(cString: $0) },
                Int(sqlite3_column_int(stmt, 5))))
        }
        sqlite3_finalize(stmt)
        XCTAssertEqual(info.count, Golden.historyTableInfo.count)
        for (got, want) in zip(info, Golden.historyTableInfo) {
            XCTAssertEqual(got.0, want.0); XCTAssertEqual(got.1, want.1)
            XCTAssertEqual(got.2, want.2); XCTAssertEqual(got.3, want.3)
            XCTAssertEqual(got.4, want.4); XCTAssertEqual(got.5, want.5)
        }

        XCTAssertEqual(sqlite3_prepare_v2(db, "PRAGMA journal_mode", -1, &stmt, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
        XCTAssertEqual(String(cString: sqlite3_column_text(stmt, 0)), Golden.historyJournalMode)
        sqlite3_finalize(stmt)
    }

    /// Opening a database the Python already populated must not migrate or
    /// rewrite anything, and existing rows must read back.
    func testOpensAPreExistingPythonDatabaseUnchanged() throws {
        let p = dbPath("legacy.sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(
            p.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, History.schema, nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db,
            "INSERT INTO transcripts (ts, text, engine, duration_ms) "
            + "VALUES (1700000000.5, 'legacy row', 'mlx_whisper', 12.5)",
            nil, nil, nil), SQLITE_OK)
        sqlite3_close_v2(db)

        let history = History(path: p, settings: nil)
        let rows = history.recent(limit: 5)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].text, "legacy row")
        XCTAssertEqual(rows[0].engine, "mlx_whisper")
        XCTAssertEqual(rows[0].ts, 1700000000.5)
        XCTAssertEqual(rows[0].durationMs, 12.5)
        XCTAssertEqual(history.add(text: "swift row", engine: "apple_live", durationMs: 1.0), 2)
        history.close()
    }

    // MARK: add / recent / lastText — golden ids and ordering from the Python run

    func testAddReturnsRowIdsAndSkipsEmptyText() throws {
        let history = History(path: dbPath(), settings: nil)
        XCTAssertEqual(history.add(text: "first", engine: "apple_live", durationMs: 1000.0), 1)
        XCTAssertEqual(history.add(text: "second", engine: "mlx_whisper", durationMs: 250.5), 2)
        XCTAssertEqual(history.add(text: "", engine: "apple_live", durationMs: 10.0), -1)

        let rows = history.recent(limit: 3)
        XCTAssertEqual(rows.map(\.id), [2, 1])
        XCTAssertEqual(rows.map(\.text), ["second", "first"])
        XCTAssertEqual(rows.map(\.engine), ["mlx_whisper", "apple_live"])
        XCTAssertEqual(rows.map(\.durationMs), [250.5, 1000.0])
        XCTAssertEqual(history.lastText(), "second")
        history.close()
    }

    func testRecentWithNonPositiveLimitIsEmpty() throws {
        let history = History(path: dbPath(), settings: nil)
        history.add(text: "x", engine: "e", durationMs: nil)
        XCTAssertEqual(history.recent(limit: 0), [])
        XCTAssertEqual(history.recent(limit: -1), [])
        history.close()
    }

    func testNilDurationRoundTripsAsNull() throws {
        let history = History(path: dbPath(), settings: nil)
        history.add(text: "x", engine: "e", durationMs: nil)
        XCTAssertNil(history.recent(limit: 1)[0].durationMs)
        history.close()
    }

    func testTimestampIsUnixSecondsLikePythonTimeTime() throws {
        let before = Date().timeIntervalSince1970
        let history = History(path: dbPath(), settings: nil)
        history.add(text: "x", engine: "e", durationMs: nil)
        let ts = history.recent(limit: 1)[0].ts
        XCTAssertGreaterThanOrEqual(ts, before)
        XCTAssertLessThanOrEqual(ts, Date().timeIntervalSince1970)
        history.close()
    }

    // MARK: trim / purge

    func testTrimKeepsNewestLimitRowsOldestFirstOut() throws {
        let history = History(path: dbPath(), settings: try settings(enabled: true, limit: 3))
        for i in 0..<6 { history.add(text: "t\(i)", engine: "e", durationMs: Double(i)) }
        let rows = history.recent(limit: 10)
        XCTAssertEqual(rows.map(\.text), ["t5", "t4", "t3"])
        XCTAssertEqual(rows.map(\.id), [6, 5, 4])
        history.close()
    }

    func testPurgeEmptiesButKeepsAutoincrementCounter() throws {
        let history = History(path: dbPath(), settings: try settings(enabled: true, limit: 3))
        for i in 0..<6 { history.add(text: "t\(i)", engine: "e", durationMs: Double(i)) }
        history.purge()
        XCTAssertEqual(history.recent(limit: 10), [])
        XCTAssertNil(history.lastText())
        // Python's purge is DELETE + VACUUM, not DROP: sqlite_sequence survives.
        XCTAssertEqual(history.add(text: "post-purge", engine: "e", durationMs: 1.0), 7)
        history.close()
    }

    func testDisabledHistorySkipsWritesButStillReads() throws {
        let config = try settings(enabled: true, limit: 1000)
        let history = History(path: dbPath(), settings: config)
        XCTAssertEqual(history.add(text: "before", engine: "e", durationMs: 1.0), 1)
        config.set(SettingsKey.historyEnabled, false)
        XCTAssertEqual(history.add(text: "blocked", engine: "e", durationMs: 1.0), -1)
        XCTAssertEqual(history.lastText(), "before")
        history.close()
    }

    func testZeroOrNegativeLimitFallsBackToOneThousand() throws {
        let config = try settings(enabled: true, limit: 1000)
        config.set(SettingsKey.historyLimit, 0)
        let history = History(path: dbPath(), settings: config)
        for i in 0..<5 { history.add(text: "t\(i)", engine: "e", durationMs: nil) }
        XCTAssertEqual(history.recent(limit: 10).count, 5)
        history.close()
    }

    // MARK: robustness

    func testUnopenableDatabaseDegradesToNoOps() throws {
        // A directory where the db file should be: open must fail, not crash.
        let p = dbPath("blocked.sqlite")
        try FileManager.default.createDirectory(at: p, withIntermediateDirectories: true)
        let history = History(path: p, settings: nil)
        XCTAssertFalse(history.isAvailable)
        XCTAssertEqual(history.add(text: "x", engine: "e", durationMs: nil), -1)
        XCTAssertEqual(history.recent(limit: 5), [])
        XCTAssertNil(history.lastText())
        history.purge()
        history.close()
    }

    func testCloseIsIdempotent() throws {
        let history = History(path: dbPath(), settings: nil)
        history.close()
        history.close()
        XCTAssertFalse(history.isAvailable)
    }

    func testTextWithQuotesAndUnicodeRoundTrips() throws {
        let history = History(path: dbPath(), settings: nil)
        let text = "it's a \"quote\"; DROP TABLE transcripts; — é 😀"
        history.add(text: text, engine: "apple_live", durationMs: nil)
        XCTAssertEqual(history.lastText(), text)
        history.close()
    }

    func testConcurrentReadersAndWriters() throws {
        let history = History(path: dbPath(), settings: try settings(enabled: true, limit: 50))
        DispatchQueue.concurrentPerform(iterations: 100) { i in
            if i.isMultiple(of: 2) {
                history.add(text: "c\(i)", engine: "e", durationMs: Double(i))
            } else {
                _ = history.recent(limit: 5)
            }
        }
        XCTAssertEqual(history.recent(limit: 100).count, 50)
        history.close()
    }

    func testOverrideRootDrivesTheDefaultPath() throws {
        let saved = WispritPaths.overrideRoot
        defer { WispritPaths.overrideRoot = saved }
        WispritPaths.overrideRoot = root
        let history = History()
        history.add(text: "x", engine: "e", durationMs: nil)
        history.close()
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("history.sqlite").path))
    }
}
