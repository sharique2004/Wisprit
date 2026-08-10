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

    /// The second table exists from open, is created separately from `schema`,
    /// and — the point of the whole exercise — the `transcripts` statement is
    /// still byte-for-byte what the Python wrote. Asserted here as well as above
    /// because THIS is the test that would catch someone "just adding a column"
    /// to the pinned schema.
    func testDetailTableIsAdditiveAndLeavesTranscriptsByteIdentical() throws {
        let p = dbPath()
        let history = History(path: p, settings: nil)
        XCTAssertTrue(history.isAvailable)
        history.close()

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(p.path, &db, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close_v2(db) }

        var sql: [String: String] = [:]
        var stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(
            db, "SELECT name, sql FROM sqlite_master ORDER BY name", -1, &stmt, nil), SQLITE_OK)
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let text = sqlite3_column_text(stmt, 1) else { continue }
            sql[String(cString: sqlite3_column_text(stmt, 0))] = String(cString: text)
        }
        sqlite3_finalize(stmt)

        XCTAssertEqual(sql["transcripts"], Golden.historyTableSQL)
        XCTAssertEqual(sql["utterance_detail"], Golden.historyDetailTableSQL)

        var info: [(Int, String, String, Int, String?, Int)] = []
        XCTAssertEqual(sqlite3_prepare_v2(
            db, "PRAGMA table_info(utterance_detail)", -1, &stmt, nil), SQLITE_OK)
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
        XCTAssertEqual(info.count, Golden.historyDetailTableInfo.count)
        for (got, want) in zip(info, Golden.historyDetailTableInfo) {
            XCTAssertEqual(got.0, want.0); XCTAssertEqual(got.1, want.1)
            XCTAssertEqual(got.2, want.2); XCTAssertEqual(got.3, want.3)
            XCTAssertEqual(got.4, want.4); XCTAssertEqual(got.5, want.5)
        }
    }

    /// Opening a Python-era database adds the table without disturbing anything
    /// the Python put there.
    func testLegacyDatabaseGainsTheDetailTableOnOpen() throws {
        let p = dbPath("legacy-detail.sqlite")
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
        XCTAssertEqual(history.recent(limit: 5).map(\.text), ["legacy row"])
        XCTAssertEqual(history.details(limit: 5), [])   // no detail for the old row
        let id = history.add(text: "swift row", engine: "apple_live", durationMs: 1.0)
        history.addDetail(transcriptId: id, raw: "swift roe", corrected: "swift row",
                          refined: "swift row", inserted: "swift row")
        XCTAssertEqual(history.details(limit: 5).map(\.raw), ["swift roe"])
        history.close()
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

    // MARK: - utterance_detail (the flywheel's raw material)

    func testDetailRoundTripsTheWholeTriple() throws {
        let history = History(path: dbPath(), settings: nil)
        let id = history.add(text: "Ship it to InsForge", engine: "apple_live", durationMs: 900.0)
        let detailID = history.addDetail(
            transcriptId: id,
            raw: "ship it to in forge", corrected: "ship it to InsForge",
            refined: "Ship it to InsForge", inserted: "Ship it to InsForge",
            vocab: "applied", ai: "applied", termsHit: ["InsForge", "Wisprit"])
        XCTAssertEqual(detailID, 1)

        let rows = history.details(limit: 5)
        XCTAssertEqual(rows.count, 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.id, 1)
        XCTAssertEqual(row.transcriptId, id)
        XCTAssertEqual(row.raw, "ship it to in forge")
        XCTAssertEqual(row.corrected, "ship it to InsForge")
        XCTAssertEqual(row.refined, "Ship it to InsForge")
        XCTAssertEqual(row.inserted, "Ship it to InsForge")
        XCTAssertEqual(row.vocab, "applied")
        XCTAssertEqual(row.ai, "applied")
        XCTAssertEqual(row.termsHit, ["InsForge", "Wisprit"])   // order preserved
        // Joined from transcripts, so the review UI needs one query, not two.
        XCTAssertEqual(row.text, "Ship it to InsForge")
        XCTAssertEqual(row.engine, "apple_live")
        XCTAssertGreaterThan(row.ts, 0)
        XCTAssertGreaterThan(row.created, 0)
        history.close()
    }

    /// "the vocabulary pass did not run" must not read back as "it ran and said
    /// nothing" — the optional columns stay NULL.
    func testDetailOptionalColumnsStayNil() throws {
        let history = History(path: dbPath(), settings: nil)
        let id = history.add(text: "plain", engine: "e", durationMs: nil)
        history.addDetail(transcriptId: id, raw: "plain", corrected: "plain",
                          refined: "plain", inserted: "plain")
        let row = try XCTUnwrap(history.details(limit: 1).first)
        XCTAssertNil(row.vocab)
        XCTAssertNil(row.ai)
        XCTAssertEqual(row.termsHit, [])
        history.close()
    }

    func testDetailIsNewestFirstAndHonoursLimit() throws {
        let history = History(path: dbPath(), settings: nil)
        for i in 0..<4 {
            let id = history.add(text: "t\(i)", engine: "e", durationMs: nil)
            history.addDetail(transcriptId: id, raw: "r\(i)", corrected: "c\(i)",
                              refined: "f\(i)", inserted: "i\(i)")
        }
        XCTAssertEqual(history.details(limit: 2).map(\.raw), ["r3", "r2"])
        XCTAssertEqual(history.details(limit: 0), [])
        history.close()
    }

    /// The whole reason the cascade is written by hand: SQLite foreign keys are
    /// off, so nothing deletes these rows unless we do.
    func testTrimCascadesDetailsWithTheirTranscripts() throws {
        let history = History(path: dbPath(), settings: try settings(enabled: true, limit: 3))
        for i in 0..<6 {
            let id = history.add(text: "t\(i)", engine: "e", durationMs: nil)
            history.addDetail(transcriptId: id, raw: "r\(i)", corrected: "c\(i)",
                              refined: "f\(i)", inserted: "i\(i)")
        }
        XCTAssertEqual(history.recent(limit: 10).map(\.text), ["t5", "t4", "t3"])
        XCTAssertEqual(history.details(limit: 10).map(\.raw), ["r5", "r4", "r3"])

        // And no orphans are left lying in the table for the join to hide.
        XCTAssertEqual(try detailRowCount(dbPath()), 3)
        history.close()
    }

    /// The join, not just the cascade: a detail whose transcript is gone is a
    /// half-record and must not surface between trims.
    func testDetailWithoutItsTranscriptIsNotReturned() throws {
        let history = History(path: dbPath(), settings: nil)
        history.addDetail(transcriptId: 999, raw: "orphan", corrected: "orphan",
                          refined: "orphan", inserted: "orphan")
        XCTAssertEqual(history.details(limit: 5), [])
        history.close()
    }

    func testPurgeClearsBothTables() throws {
        let history = History(path: dbPath(), settings: nil)
        for i in 0..<3 {
            let id = history.add(text: "t\(i)", engine: "e", durationMs: nil)
            history.addDetail(transcriptId: id, raw: "r\(i)", corrected: "c\(i)",
                              refined: "f\(i)", inserted: "i\(i)")
        }
        history.purge()
        XCTAssertEqual(history.recent(limit: 10), [])
        XCTAssertEqual(history.details(limit: 10), [])
        XCTAssertEqual(try detailRowCount(dbPath()), 0)
        history.close()
    }

    /// The update path for the late `vocab` column: the reconciliation pass
    /// finishes seconds after the detail row was written, and its outcome must
    /// land on THAT row — never as a second row, never on any other column.
    func testUpdateDetailFillsTheLateVocabColumnInPlace() throws {
        let history = History(path: dbPath(), settings: nil)
        let id = history.add(text: "Ship it to InsForge", engine: "apple_live", durationMs: 900.0)
        history.addDetail(transcriptId: id,
                          raw: "ship it to in forge", corrected: "ship it to in forge",
                          refined: "Ship it to in forge", inserted: "Ship it to InsForge",
                          vocab: nil, ai: "applied", termsHit: [])
        XCTAssertNil(history.details(limit: 5).first?.vocab, "NULL until the pass lands")

        XCTAssertTrue(history.updateDetail(transcriptId: id, vocab: "Ship it to InsForge"))

        let rows = history.details(limit: 5)
        XCTAssertEqual(rows.count, 1, "an update, not a second row")
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.vocab, "Ship it to InsForge")
        XCTAssertEqual(row.raw, "ship it to in forge", "every other column stays as written")
        XCTAssertEqual(row.ai, "applied")
        history.close()
    }

    func testUpdateDetailIsAHonestNoOpWithoutARow() throws {
        let history = History(path: dbPath(), settings: nil)
        XCTAssertFalse(history.updateDetail(transcriptId: 99, vocab: "anything"),
                       "no row means no update — a trimmed detail is not resurrected")
        XCTAssertFalse(history.updateDetail(transcriptId: -1, vocab: "anything"))

        let off = History(path: dbPath("updateoff.sqlite"), settings: nil, detailEnabled: false)
        let id = off.add(text: "kept", engine: "e", durationMs: nil)
        XCTAssertFalse(off.updateDetail(transcriptId: id, vocab: "anything"),
                       "detail off wrote no row, so there is nothing to update")
        off.close()
        history.close()
    }

    func testDetailWritesAreAbsentWhenTheFlagIsOff() throws {
        let p = dbPath("nodetail.sqlite")
        let history = History(path: p, settings: nil, detailEnabled: false)
        let id = history.add(text: "kept", engine: "e", durationMs: nil)
        XCTAssertEqual(id, 1)                                  // history still writes
        XCTAssertEqual(history.addDetail(transcriptId: id, raw: "r", corrected: "c",
                                         refined: "f", inserted: "i"), -1)
        XCTAssertEqual(history.details(limit: 5), [])
        XCTAssertEqual(try detailRowCount(p), 0)
        // The table itself is still created, so flipping the flag on needs no
        // migration — and rows written while it was on stay readable.
        XCTAssertEqual(history.recent(limit: 5).map(\.text), ["kept"])
        history.close()
    }

    /// Turning the flag off must not strand the rows written while it was on:
    /// they keep ageing out with their transcripts.
    func testDetailRowsStillTrimAfterTheFlagIsTurnedOff() throws {
        let p = dbPath("flagflip.sqlite")
        let config = try settings(enabled: true, limit: 2)
        let on = History(path: p, settings: config, detailEnabled: true)
        for i in 0..<2 {
            let id = on.add(text: "t\(i)", engine: "e", durationMs: nil)
            on.addDetail(transcriptId: id, raw: "r\(i)", corrected: "c\(i)",
                         refined: "f\(i)", inserted: "i\(i)")
        }
        on.close()

        let off = History(path: p, settings: config, detailEnabled: false)
        off.add(text: "t2", engine: "e", durationMs: nil)   // trims t0
        off.add(text: "t3", engine: "e", durationMs: nil)   // trims t1
        XCTAssertEqual(try detailRowCount(p), 0)
        off.close()
    }

    func testDetailIsSkippedWhenHistoryIsDisabledOrTheIdIsMissing() throws {
        let config = try settings(enabled: true, limit: 1000)
        let history = History(path: dbPath(), settings: config)
        XCTAssertEqual(history.addDetail(transcriptId: -1, raw: "r", corrected: "c",
                                         refined: "f", inserted: "i"), -1)
        config.set(SettingsKey.historyEnabled, false)
        XCTAssertEqual(history.addDetail(transcriptId: 1, raw: "r", corrected: "c",
                                         refined: "f", inserted: "i"), -1)
        history.close()
    }

    func testDetailDegradesWhenTheDatabaseIsUnavailable() throws {
        let p = dbPath("blocked-detail.sqlite")
        try FileManager.default.createDirectory(at: p, withIntermediateDirectories: true)
        let history = History(path: p, settings: nil)
        XCTAssertEqual(history.addDetail(transcriptId: 1, raw: "r", corrected: "c",
                                         refined: "f", inserted: "i"), -1)
        XCTAssertEqual(history.details(limit: 5), [])
        history.close()
    }

    func testDetailTextWithQuotesAndUnicodeRoundTrips() throws {
        let history = History(path: dbPath(), settings: nil)
        let raw = "it's a \"quote\"; DROP TABLE utterance_detail; — é 😀"
        let id = history.add(text: "x", engine: "e", durationMs: nil)
        history.addDetail(transcriptId: id, raw: raw, corrected: raw, refined: raw,
                          inserted: raw, termsHit: ["é 😀", "quote\"s"])
        let row = try XCTUnwrap(history.details(limit: 1).first)
        XCTAssertEqual(row.raw, raw)
        XCTAssertEqual(row.termsHit, ["é 😀", "quote\"s"])
        history.close()
    }

    /// Counts straight out of the file, bypassing the join, so an orphan cannot
    /// hide behind it.
    private func detailRowCount(_ url: URL) throws -> Int {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close_v2(db) }
        var stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(
            db, "SELECT COUNT(*) FROM utterance_detail", -1, &stmt, nil), SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
        return Int(sqlite3_column_int64(stmt, 0))
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
