import XCTest
import SQLite3
import WispritKit
@testable import WispritPersistence

/// `transcript_meta` — the Dictations page's delivery facts (target app, stage
/// timings, mic) — and the joined read the page uses.
///
/// The migration is additive by construction: a database of any era gains the
/// empty table on open, `transcripts` keeps its byte-pinned statement, and a
/// row that predates the table reads back with no meta.
final class HistoryMetaTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wisprit-meta-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func dbPath(_ name: String = "history.sqlite") -> URL {
        root.appendingPathComponent(name)
    }

    private func settings(enabled: Bool = true, limit: Int = 1000) -> Settings {
        let s = Settings(path: root.appendingPathComponent("cfg-\(UUID().uuidString).json"))
        s.set(SettingsKey.historyEnabled, enabled)
        s.set(SettingsKey.historyLimit, limit)
        return s
    }

    private func masterSQL(_ path: URL) -> [String: String] {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(path.path, &db, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close_v2(db) }
        var stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(
            db, "SELECT name, sql FROM sqlite_master", -1, &stmt, nil), SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        var out: [String: String] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let sql = sqlite3_column_text(stmt, 1) else { continue }
            out[String(cString: sqlite3_column_text(stmt, 0))] = String(cString: sql)
        }
        return out
    }

    private let meta = TranscriptMeta(appBundleID: "com.apple.Notes", outcome: "paste",
                                      releaseToTextMs: 412, finalizeMs: 260, aiMs: 140,
                                      postMs: 3, insertMs: 9, ai: "applied",
                                      inputDevice: "MacBook Pro Microphone")

    // MARK: - the migration

    func testTheMetaTableIsCreatedAndTranscriptsStaysByteIdentical() {
        let p = dbPath()
        History(path: p).close()
        let sql = masterSQL(p)
        XCTAssertEqual(sql["transcript_meta"], Golden.historyMetaTableSQL)
        XCTAssertEqual(sql["transcripts"], Golden.historyTableSQL,
                       "the delivery facts must never be a column on the pinned table")
        XCTAssertEqual(sql["utterance_detail"], Golden.historyDetailTableSQL)
    }

    /// An existing database — Python era, or a native one from before the
    /// table — gains it on open, and its old rows read back with no meta.
    func testAnExistingDatabaseGainsTheTableAndOldRowsHaveNoMeta() throws {
        let p = dbPath("legacy.sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(
            p.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, History.schema, nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, History.detailSchema, nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db,
            "INSERT INTO transcripts (ts, text, engine, duration_ms) "
            + "VALUES (1700000000.5, 'old row', 'apple_live', 900)", nil, nil, nil), SQLITE_OK)
        sqlite3_close_v2(db)

        let history = History(path: p)
        let rows = history.dictations(limit: 5)
        XCTAssertEqual(rows.map(\.entry.text), ["old row"])
        XCTAssertNil(rows[0].meta, "old rows simply have no icon")
        XCTAssertNil(rows[0].detail)

        let id = history.add(text: "new row", engine: "apple_live", durationMs: 1200)
        XCTAssertTrue(history.addMeta(transcriptId: id, meta))
        XCTAssertEqual(history.dictations(limit: 5).first?.meta, meta)
        history.close()
        XCTAssertEqual(masterSQL(p)["transcript_meta"], Golden.historyMetaTableSQL)
    }

    // MARK: - writing and reading

    func testTheJoinedReadCarriesDetailAndMetaWhenTheyExist() {
        let history = History(path: dbPath())
        let a = history.add(text: "first", engine: "apple_live", durationMs: 1000)
        let b = history.add(text: "Second, written.", engine: "apple_live", durationMs: 2000)
        history.addDetail(transcriptId: b, raw: "second written", corrected: "second written",
                          refined: "Second, written.", inserted: "Second, written.",
                          ai: "applied")
        history.addMeta(transcriptId: b, meta)

        let rows = history.dictations(limit: 10)
        XCTAssertEqual(rows.map(\.entry.id), [b, a], "newest first")
        XCTAssertEqual(rows[0].detail?.raw, "second written")
        XCTAssertEqual(rows[0].detail?.inserted, "Second, written.")
        XCTAssertEqual(rows[0].meta, meta)
        XCTAssertNil(rows[1].detail)
        XCTAssertNil(rows[1].meta)
        XCTAssertEqual(rows[1].entry.durationMs, 1000)
        history.close()
    }

    func testNilFieldsStayNilRatherThanBecomingZero() {
        let history = History(path: dbPath())
        let id = history.add(text: "x", engine: "apple_live", durationMs: nil)
        history.addMeta(transcriptId: id, TranscriptMeta(appBundleID: "com.apple.Notes"))
        let read = history.dictations(limit: 1).first?.meta
        XCTAssertEqual(read?.appBundleID, "com.apple.Notes")
        XCTAssertNil(read?.releaseToTextMs)
        XCTAssertNil(read?.inputDevice)
        XCTAssertNil(history.dictations(limit: 1).first?.entry.durationMs)
        history.close()
    }

    func testASecondWriteReplacesTheFirst() {
        let history = History(path: dbPath())
        let id = history.add(text: "x", engine: "apple_live", durationMs: 1)
        history.addMeta(transcriptId: id, TranscriptMeta(appBundleID: "one"))
        history.addMeta(transcriptId: id, TranscriptMeta(appBundleID: "two"))
        XCTAssertEqual(history.dictations(limit: 5).count, 1)
        XCTAssertEqual(history.dictations(limit: 5).first?.meta?.appBundleID, "two")
        history.close()
    }

    func testNothingIsWrittenWithoutALiveParentOrWithHistoryOff() {
        let on = History(path: dbPath("on.sqlite"))
        XCTAssertFalse(on.addMeta(transcriptId: -1, meta))
        on.close()

        let off = History(path: dbPath("off.sqlite"), settings: settings(enabled: false))
        XCTAssertFalse(off.addMeta(transcriptId: 1, meta))
        off.close()
    }

    /// Delivery facts are not text the user said, so the detail flag — which
    /// is about keeping raw and intermediate text — does not gate them.
    func testMetaIsWrittenWhenDetailCaptureIsOff() {
        let history = History(path: dbPath(), detailEnabled: false)
        let id = history.add(text: "x", engine: "apple_live", durationMs: 1)
        XCTAssertEqual(history.addDetail(transcriptId: id, raw: "x", corrected: "x",
                                         refined: "x", inserted: "x"), -1)
        XCTAssertTrue(history.addMeta(transcriptId: id, meta))
        history.close()
    }

    func testTrimTakesTheMetaWithItsTranscript() {
        let history = History(path: dbPath(), settings: settings(limit: 2))
        let first = history.add(text: "one", engine: "e", durationMs: 1)
        history.addMeta(transcriptId: first, meta)
        let second = history.add(text: "two", engine: "e", durationMs: 1)
        history.addMeta(transcriptId: second, meta)
        history.add(text: "three", engine: "e", durationMs: 1)
        history.close()

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(dbPath().path, &db, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close_v2(db) }
        var stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(
            db, "SELECT transcript_id FROM transcript_meta ORDER BY transcript_id", -1, &stmt, nil),
                       SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        var ids: [Int64] = []
        while sqlite3_step(stmt) == SQLITE_ROW { ids.append(sqlite3_column_int64(stmt, 0)) }
        XCTAssertEqual(ids, [second], "the trimmed transcript's meta went with it")
    }

    func testPurgeClearsTheMeta() {
        let history = History(path: dbPath())
        let id = history.add(text: "x", engine: "e", durationMs: 1)
        history.addMeta(transcriptId: id, meta)
        history.purge()
        let again = history.add(text: "y", engine: "e", durationMs: 1)
        XCTAssertNil(history.dictations(limit: 5).first { $0.entry.id == again }?.meta)
        XCTAssertTrue(history.dictations(limit: 5).allSatisfy { $0.meta == nil })
        history.close()
    }

    // MARK: - read-only

    /// `render-window` opens the user's live file beside the running app; a
    /// read-only open must not create the new table, or anything else.
    func testAReadOnlyOpenCreatesNothingAndWritesNothing() {
        let p = dbPath("ro.sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(
            p.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, History.schema, nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db,
            "INSERT INTO transcripts (ts, text, engine, duration_ms) VALUES (1, 'kept', 'e', 1)",
            nil, nil, nil), SQLITE_OK)
        sqlite3_close_v2(db)

        let history = History(path: p, readOnly: true)
        XCTAssertTrue(history.isAvailable)
        XCTAssertEqual(history.dictations(limit: 5).map(\.entry.text), ["kept"])
        XCTAssertEqual(history.recent(limit: 5).map(\.text), ["kept"])
        XCTAssertEqual(history.add(text: "nope", engine: "e", durationMs: 1), -1)
        XCTAssertFalse(history.addMeta(transcriptId: 1, meta))
        history.purge()
        history.close()

        let sql = masterSQL(p)
        XCTAssertNil(sql["transcript_meta"])
        XCTAssertNil(sql["utterance_detail"])
        XCTAssertEqual(History(path: p, readOnly: true).recent(limit: 5).map(\.text), ["kept"],
                       "purge on a read-only open is a no-op")
    }

    /// A WAL-mode copy with no `-shm` beside it — nobody has it open — is read
    /// as a snapshot rather than failing.
    func testAReadOnlyOpenReadsAWALFileThatNobodyHasOpen() throws {
        let source = dbPath("source.sqlite")
        let writer = History(path: source)
        let id = writer.add(text: "in the wal", engine: "e", durationMs: 1)
        writer.addMeta(transcriptId: id, meta)
        writer.close()   // checkpoints; the file stays in WAL mode
        let copy = dbPath("copy.sqlite")
        try FileManager.default.copyItem(at: source, to: copy)

        let reader = History(path: copy, readOnly: true)
        XCTAssertTrue(reader.isAvailable)
        XCTAssertEqual(reader.dictations(limit: 5).first?.meta, meta)
        reader.close()
    }
}
