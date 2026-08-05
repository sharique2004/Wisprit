import Foundation
import SQLite3
import WispritKit

/// Transcript history: text-only SQLite log at `~/.wisprit/history.sqlite`.
/// 1:1 port of `wisprit/history.py`, **schema-compatible with the databases the
/// Python era wrote** — the same file is opened by both.
///
/// Deliberately stores ONLY transcript text + metadata, never audio, so the
/// database stays tiny and there is nothing sensitive to leak beyond what was
/// already typed into some app. WAL keeps single-writer inserts fast and
/// readers non-blocking.
///
/// Threading: reads happen on the UI thread (the menu rebuilds recents when it
/// opens) while writes happen on the session thread, so every public method
/// takes the instance lock and the connection is opened `FULLMUTEX`.
/// Every method degrades gracefully — a broken history must never take down
/// dictation.

public struct HistoryEntry: Sendable, Equatable {
    public var id: Int64
    public var ts: Double            // Unix seconds, matching Python's time.time()
    public var text: String
    public var engine: String
    public var durationMs: Double?

    public init(id: Int64, ts: Double, text: String, engine: String, durationMs: Double?) {
        self.id = id; self.ts = ts; self.text = text
        self.engine = engine; self.durationMs = durationMs
    }
}

public final class History: @unchecked Sendable {
    /// Byte-identical to `history.py::_SCHEMA`. SQLite stores the statement text
    /// verbatim in `sqlite_master.sql` (minus `IF NOT EXISTS`), so any edit here
    /// makes a Swift-created DB textually differ from a Python-created one.
    static let schema = """

    CREATE TABLE IF NOT EXISTS transcripts (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        ts          REAL NOT NULL,
        text        TEXT NOT NULL,
        engine      TEXT NOT NULL DEFAULT '',
        duration_ms REAL
    )

    """

    static let defaultLimit = 1000

    /// SQLITE_TRANSIENT — not exposed to Swift as a constant; sqlite copies the
    /// bound bytes, which is what we want for temporary Swift String buffers.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private var db: OpaquePointer?
    private let lock = NSLock()
    private let path: URL
    private let settings: Settings?
    private let log = WLog.logger("history")

    public init(path: URL = WispritPaths.historyPath, settings: Settings? = nil) {
        self.path = path
        self.settings = settings
        do {
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            var handle: OpaquePointer?
            let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
            guard sqlite3_open_v2(path.path, &handle, flags, nil) == SQLITE_OK, handle != nil else {
                if let handle { sqlite3_close_v2(handle) }
                throw HistoryError.open
            }
            self.db = handle
            try exec("PRAGMA journal_mode=WAL")
            try exec("PRAGMA synchronous=NORMAL")
            try exec(History.schema)
        } catch {
            log.error("cannot open history db at \(self.path.path, privacy: .public); history disabled")
            if let db { sqlite3_close_v2(db) }
            db = nil
        }
    }

    deinit { if let db { sqlite3_close_v2(db) } }

    private enum HistoryError: Error { case open, step(String) }

    /// Whether the database is usable. `false` means every call is a safe no-op.
    public var isAvailable: Bool {
        lock.lock(); defer { lock.unlock() }
        return db != nil
    }

    private var isEnabled: Bool { settings?.bool(SettingsKey.historyEnabled) ?? true }

    private var limit: Int {
        if let value = settings?.int(SettingsKey.historyLimit), value > 0 { return value }
        return History.defaultLimit
    }

    // MARK: - Writing

    /// Store one transcript; returns its row id, or -1 if not stored (history
    /// disabled, empty text, or database unavailable).
    @discardableResult
    public func add(text: String, engine: String, durationMs: Double?) -> Int64 {
        guard !text.isEmpty, isEnabled else { return -1 }
        lock.lock(); defer { lock.unlock() }
        guard let db else { return -1 }
        do {
            // IMMEDIATE, not the Python's implicit DEFERRED: the write lock is
            // taken up front so a concurrent reader can never force a busy
            // upgrade failure mid-insert. Same visible result, no BUSY retry.
            try exec("BEGIN IMMEDIATE")
            do {
                let insert = try prepare(
                    "INSERT INTO transcripts (ts, text, engine, duration_ms) VALUES (?, ?, ?, ?)")
                defer { sqlite3_finalize(insert) }
                sqlite3_bind_double(insert, 1, Date().timeIntervalSince1970)
                sqlite3_bind_text(insert, 2, text, -1, History.transient)
                sqlite3_bind_text(insert, 3, engine, -1, History.transient)
                if let durationMs { sqlite3_bind_double(insert, 4, durationMs) }
                else { sqlite3_bind_null(insert, 4) }
                guard sqlite3_step(insert) == SQLITE_DONE else { throw HistoryError.step("insert") }
                let rowID = sqlite3_last_insert_rowid(db)

                // Trim inside the same transaction, exactly as the Python does,
                // so a reader never sees an over-length window.
                let trim = try prepare(
                    "DELETE FROM transcripts WHERE id NOT IN "
                    + "(SELECT id FROM transcripts ORDER BY id DESC LIMIT ?)")
                defer { sqlite3_finalize(trim) }
                sqlite3_bind_int64(trim, 1, Int64(limit))
                guard sqlite3_step(trim) == SQLITE_DONE else { throw HistoryError.step("trim") }

                try exec("COMMIT")
                return rowID
            } catch {
                try? exec("ROLLBACK")
                throw error
            }
        } catch {
            log.error("failed to add history entry")
            return -1
        }
    }

    /// Delete every stored transcript and reclaim file space. Row ids keep
    /// counting up (DELETE leaves `sqlite_sequence` alone) — same as Python.
    public func purge() {
        lock.lock(); defer { lock.unlock() }
        guard db != nil else { return }
        do {
            try exec("DELETE FROM transcripts")
            try exec("VACUUM")            // must run outside a transaction
        } catch {
            log.error("failed to purge history")
        }
    }

    // MARK: - Reading
    //
    // Reads work even when adding is disabled — the paste-last recovery path
    // must always function.

    /// Newest-first list of the last `limit` entries.
    public func recent(limit: Int = 5) -> [HistoryEntry] {
        guard limit > 0 else { return [] }
        lock.lock(); defer { lock.unlock() }
        guard db != nil else { return [] }
        do {
            let stmt = try prepare(
                "SELECT id, ts, text, engine, duration_ms FROM transcripts ORDER BY id DESC LIMIT ?")
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, Int64(limit))
            var out: [HistoryEntry] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(HistoryEntry(
                    id: sqlite3_column_int64(stmt, 0),
                    ts: sqlite3_column_double(stmt, 1),
                    text: column(stmt, 2) ?? "",
                    engine: column(stmt, 3) ?? "",
                    durationMs: sqlite3_column_type(stmt, 4) == SQLITE_NULL
                        ? nil : sqlite3_column_double(stmt, 4)))
            }
            return out
        } catch {
            log.error("failed to read history")
            return []
        }
    }

    /// Text of the most recent transcript, or nil if history is empty.
    public func lastText() -> String? {
        lock.lock(); defer { lock.unlock() }
        guard db != nil else { return nil }
        do {
            let stmt = try prepare("SELECT text FROM transcripts ORDER BY id DESC LIMIT 1")
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return column(stmt, 0)
        } catch {
            log.error("failed to read last transcript")
            return nil
        }
    }

    public func close() {
        lock.lock(); defer { lock.unlock() }
        if let db { sqlite3_close_v2(db) }
        db = nil
    }

    // MARK: - SQLite plumbing

    private func exec(_ sql: String) throws {
        guard let db else { throw HistoryError.open }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw HistoryError.step(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        guard let db else { throw HistoryError.open }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw HistoryError.step(String(cString: sqlite3_errmsg(db)))
        }
        return stmt
    }

    private func column(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard let bytes = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: bytes)
    }
}
