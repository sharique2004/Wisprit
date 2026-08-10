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

/// One utterance's pipeline triple, as `utterance_detail` records it, joined to
/// the `transcripts` row it belongs to. This is the flywheel's raw material: the
/// review surface shows it, and the auto-learn gate reasons over it.
public struct UtteranceDetail: Sendable, Equatable {
    public var id: Int64
    public var transcriptId: Int64
    /// Verbatim recogniser output, before anything touched it.
    public var raw: String
    /// After the deterministic post-process + dictionary corrections.
    public var corrected: String
    /// After refine (identical to `corrected` when refine did not run).
    public var refined: String
    /// What actually reached the app — the only string the user ever saw.
    public var inserted: String
    /// Off-path vocabulary-pass outcome, nil when it did not run.
    public var vocab: String?
    /// AI/refine outcome ("applied", "off", "timeout", …), nil when unknown.
    public var ai: String?
    /// Dictionary terms this utterance actually hit.
    public var termsHit: [String]
    public var created: Double
    /// Joined from `transcripts`: the final text history stored.
    public var text: String
    public var engine: String
    public var ts: Double

    public init(id: Int64, transcriptId: Int64, raw: String, corrected: String, refined: String,
                inserted: String, vocab: String?, ai: String?, termsHit: [String],
                created: Double, text: String, engine: String, ts: Double) {
        self.id = id; self.transcriptId = transcriptId
        self.raw = raw; self.corrected = corrected; self.refined = refined
        self.inserted = inserted; self.vocab = vocab; self.ai = ai
        self.termsHit = termsHit; self.created = created
        self.text = text; self.engine = engine; self.ts = ts
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

    /// The native-era second table: one row per utterance holding the pipeline
    /// triple the review and insights surfaces read.
    ///
    /// Deliberately NOT part of `schema` — that string is byte-pinned against the
    /// database the Python wrote, and both eras open the same file, so the
    /// `transcripts` statement must stay exactly what it always was. This one is
    /// created separately at open, so a Python-era database simply gains the
    /// table and keeps working.
    ///
    /// No `REFERENCES transcripts(id) ON DELETE CASCADE`: SQLite enforces foreign
    /// keys only when `PRAGMA foreign_keys=ON`, which is off by default and which
    /// this connection does not set (turning it on would change how a Python-era
    /// writer's inserts behave). A declared cascade would therefore be decoration
    /// that never fires; `add`'s trim deletes the orphans explicitly instead.
    ///
    /// `id` is a plain INTEGER PRIMARY KEY, not AUTOINCREMENT: detail rows are
    /// referenced only by their transcript, so rowid reuse after a trim is
    /// harmless, and it keeps `sqlite_sequence` exactly as the Python left it.
    static let detailSchema = """

    CREATE TABLE IF NOT EXISTS utterance_detail (
        id            INTEGER PRIMARY KEY,
        transcript_id INTEGER NOT NULL,
        raw           TEXT,
        corrected     TEXT,
        refined       TEXT,
        inserted      TEXT,
        vocab         TEXT,
        ai            TEXT,
        terms_hit     TEXT,
        created       REAL
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
    /// `history_detail`, passed in by the integration layer rather than read from
    /// Settings here: the detail table is a product decision about one call site
    /// (the session's post-insert hook), and a store that silently changed its
    /// write behaviour under a caller that never asked for detail would be a
    /// surprise. Same injection shape as `settings` — a constructor parameter.
    private let detailEnabled: Bool
    /// False when the second table could not be created (a legacy database with
    /// a conflicting object, a read-only file). Everything detail then no-ops,
    /// and — critically — `add`'s trim skips the cascade, so a broken second
    /// table can never cost us the transcript log.
    private var detailReady = false
    private let log = WLog.logger("history")

    public init(path: URL = WispritPaths.historyPath, settings: Settings? = nil,
                detailEnabled: Bool = true) {
        self.path = path
        self.settings = settings
        self.detailEnabled = detailEnabled
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
            do {
                try exec(History.detailSchema)
                detailReady = true
            } catch {
                log.error("cannot create utterance_detail; per-utterance detail disabled")
            }
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

                if detailReady {
                    // The details of the transcripts just trimmed go with them,
                    // explicitly and inside this same transaction: foreign keys
                    // are off on this connection, so nothing cascades on its own,
                    // and a reader must never see a detail row whose transcript
                    // has gone. Runs whether or not detail writes are enabled —
                    // turning `history_detail` off must still let the rows that
                    // were already written age out with their transcripts.
                    let orphans = try prepare(
                        "DELETE FROM utterance_detail WHERE transcript_id NOT IN "
                        + "(SELECT id FROM transcripts)")
                    defer { sqlite3_finalize(orphans) }
                    guard sqlite3_step(orphans) == SQLITE_DONE else {
                        throw HistoryError.step("detail trim")
                    }
                }

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

    /// Store one utterance's pipeline triple against the transcript `add`
    /// returned. Returns the detail row id, or -1 if not stored (detail off,
    /// history off, no parent id, or database unavailable).
    ///
    /// Called after `add`, never instead of it: `transcriptId` must be a live
    /// row, or the join in `details` drops the record and the next trim deletes
    /// it. Everything is text — the same sensitivity class as the final text
    /// `transcripts` already stores, which is why the flag defaults on.
    @discardableResult
    public func addDetail(transcriptId: Int64, raw: String, corrected: String, refined: String,
                          inserted: String, vocab: String? = nil, ai: String? = nil,
                          termsHit: [String] = []) -> Int64 {
        guard transcriptId > 0, isEnabled, detailEnabled else { return -1 }
        lock.lock(); defer { lock.unlock() }
        guard let db, detailReady else { return -1 }
        do {
            try exec("BEGIN IMMEDIATE")
            do {
                let insert = try prepare(
                    "INSERT INTO utterance_detail "
                    + "(transcript_id, raw, corrected, refined, inserted, vocab, ai, terms_hit, created) "
                    + "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)")
                defer { sqlite3_finalize(insert) }
                sqlite3_bind_int64(insert, 1, transcriptId)
                bind(insert, 2, raw)
                bind(insert, 3, corrected)
                bind(insert, 4, refined)
                bind(insert, 5, inserted)
                bind(insert, 6, vocab)
                bind(insert, 7, ai)
                bind(insert, 8, History.encodeTerms(termsHit))
                sqlite3_bind_double(insert, 9, Date().timeIntervalSince1970)
                guard sqlite3_step(insert) == SQLITE_DONE else {
                    throw HistoryError.step("insert detail")
                }
                let rowID = sqlite3_last_insert_rowid(db)
                try exec("COMMIT")
                return rowID
            } catch {
                try? exec("ROLLBACK")
                throw error
            }
        } catch {
            log.error("failed to add utterance detail")
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
            // "Delete All Transcripts" means all of it: the detail rows hold the
            // same text (and more of it), so leaving them would make the button
            // a lie.
            if detailReady { try exec("DELETE FROM utterance_detail") }
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

    /// Newest-first per-utterance detail, joined to its transcript.
    ///
    /// The join is an INNER join on purpose: a detail row whose transcript has
    /// been trimmed is a half-record, and the review surface would render it as
    /// an utterance that never happened. Reads work while detail writing is
    /// disabled, so turning `history_detail` off hides nothing already captured.
    public func details(limit: Int = 50) -> [UtteranceDetail] {
        guard limit > 0 else { return [] }
        lock.lock(); defer { lock.unlock() }
        guard db != nil, detailReady else { return [] }
        do {
            let stmt = try prepare(
                "SELECT d.id, d.transcript_id, d.raw, d.corrected, d.refined, d.inserted, "
                + "d.vocab, d.ai, d.terms_hit, d.created, t.text, t.engine, t.ts "
                + "FROM utterance_detail d JOIN transcripts t ON t.id = d.transcript_id "
                + "ORDER BY d.id DESC LIMIT ?")
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, Int64(limit))
            var out: [UtteranceDetail] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(UtteranceDetail(
                    id: sqlite3_column_int64(stmt, 0),
                    transcriptId: sqlite3_column_int64(stmt, 1),
                    raw: column(stmt, 2) ?? "",
                    corrected: column(stmt, 3) ?? "",
                    refined: column(stmt, 4) ?? "",
                    inserted: column(stmt, 5) ?? "",
                    vocab: column(stmt, 6),
                    ai: column(stmt, 7),
                    termsHit: History.decodeTerms(column(stmt, 8)),
                    created: sqlite3_column_double(stmt, 9),
                    text: column(stmt, 10) ?? "",
                    engine: column(stmt, 11) ?? "",
                    ts: sqlite3_column_double(stmt, 12)))
            }
            return out
        } catch {
            log.error("failed to read utterance detail")
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

    /// Bind an optional string, NULL when absent — so "the vocabulary pass did
    /// not run" and "it ran and produced an empty string" stay distinguishable.
    private func bind(_ stmt: OpaquePointer?, _ index: Int32, _ text: String?) {
        if let text { sqlite3_bind_text(stmt, index, text, -1, History.transient) }
        else { sqlite3_bind_null(stmt, index) }
    }

    // MARK: - terms_hit
    //
    // A compact JSON array in one TEXT column: readable by anything that opens
    // the database, and no schema churn when the shape of a hit changes. NULL,
    // not "[]", when nothing was hit — an empty column is honestly empty.

    static func encodeTerms(_ terms: [String]) -> String? {
        guard !terms.isEmpty, let data = try? JSONSerialization.data(withJSONObject: terms)
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decodeTerms(_ text: String?) -> [String] {
        guard let text, let data = text.data(using: .utf8),
              let list = (try? JSONSerialization.jsonObject(with: data)) as? [String]
        else { return [] }
        return list
    }
}
