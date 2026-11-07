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

/// What the session knew about one delivery once the text had landed: where it
/// went, how long each stage took, and which microphone heard it — one row per
/// transcript in `transcript_meta`.
///
/// Every field is optional because every field is a fact some path cannot
/// know (a fake audio port has no device, a delivery that never reached an app
/// has no bundle id). Nothing here is text the user said.
public struct TranscriptMeta: Sendable, Equatable {
    /// The frontmost app when the text was delivered.
    public var appBundleID: String?
    /// The insertion rung, in `metrics.log`'s `outcome` vocabulary
    /// (`paste`, `type`, `im_streaming`, `blocked_secure`, `error`, …).
    public var outcome: String?
    /// Key-up → text in the field, the number the user feels.
    public var releaseToTextMs: Double?
    /// Recognition's finalize.
    public var finalizeMs: Double?
    /// The cleanup stage (refine), however it ended.
    public var aiMs: Double?
    /// Post-process (punctuation, snippets, identity).
    public var postMs: Double?
    /// Through delivery.
    public var insertMs: Double?
    /// Refine's outcome (`applied`, `off`, `skipped_verbatim_app`, …).
    public var ai: String?
    /// The microphone, as Core Audio names it.
    public var inputDevice: String?

    public init(appBundleID: String? = nil, outcome: String? = nil,
                releaseToTextMs: Double? = nil, finalizeMs: Double? = nil,
                aiMs: Double? = nil, postMs: Double? = nil, insertMs: Double? = nil,
                ai: String? = nil, inputDevice: String? = nil) {
        self.appBundleID = appBundleID; self.outcome = outcome
        self.releaseToTextMs = releaseToTextMs; self.finalizeMs = finalizeMs
        self.aiMs = aiMs; self.postMs = postMs; self.insertMs = insertMs
        self.ai = ai; self.inputDevice = inputDevice
    }
}

/// One transcript with everything the Dictations page shows about it: the row
/// itself, its pipeline triple when `history_detail` captured one, and its
/// delivery facts when the session wrote them. Old rows simply have neither.
public struct DictationRow: Sendable, Equatable {
    public var entry: HistoryEntry
    public var detail: UtteranceDetail?
    public var meta: TranscriptMeta?

    public init(entry: HistoryEntry, detail: UtteranceDetail? = nil, meta: TranscriptMeta? = nil) {
        self.entry = entry; self.detail = detail; self.meta = meta
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

    /// The third table: per-transcript delivery facts — the app the text went
    /// to and the stage timings — written by the session once the text has
    /// landed.
    ///
    /// The migration is this statement. `transcripts` cannot take a column:
    /// its CREATE statement is byte-pinned against the Python-era file (see
    /// `schema`), and an `ALTER TABLE … ADD COLUMN` rewrites exactly that text
    /// in `sqlite_master`. A side table keyed by the transcript id is the same
    /// "nullable column" without touching it: an existing database gains the
    /// empty table on open, and every row that predates it reads back with no
    /// meta at all — which is what "old rows have no icon" means.
    ///
    /// `transcript_id INTEGER PRIMARY KEY` makes the key the rowid, so the join
    /// is an index lookup and a rewrite is a plain `INSERT OR REPLACE`. Trimmed
    /// and purged with its transcript, explicitly, for the same foreign-keys-off
    /// reason as `utterance_detail`.
    static let metaSchema = """

    CREATE TABLE IF NOT EXISTS transcript_meta (
        transcript_id      INTEGER PRIMARY KEY,
        app_bundle_id      TEXT,
        outcome            TEXT,
        release_to_text_ms REAL,
        finalize_ms        REAL,
        ai_ms              REAL,
        post_ms            REAL,
        insert_ms          REAL,
        ai                 TEXT,
        input_device       TEXT,
        created            REAL
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
    /// Same contract as `detailReady`, for `transcript_meta`.
    private var metaReady = false
    /// Opened `SQLITE_OPEN_READONLY`: no table is created, no pragma is set,
    /// and every write is a no-op. For tools that look at a live user's file
    /// beside the running app (`render-window`), where even an additive
    /// `CREATE TABLE` would be a write the user never asked for.
    private let readOnly: Bool
    private let log = WLog.logger("history")

    public init(path: URL = WispritPaths.historyPath, settings: Settings? = nil,
                detailEnabled: Bool = true, readOnly: Bool = false) {
        self.path = path
        self.settings = settings
        self.detailEnabled = detailEnabled
        self.readOnly = readOnly
        do {
            if !readOnly {
                try FileManager.default.createDirectory(
                    at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            }
            var handle: OpaquePointer?
            let flags = (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
                | SQLITE_OPEN_FULLMUTEX
            guard sqlite3_open_v2(path.path, &handle, flags, nil) == SQLITE_OK, handle != nil else {
                if let handle { sqlite3_close_v2(handle) }
                throw HistoryError.open
            }
            self.db = handle
            if readOnly {
                // A WAL-mode file with no `-shm` beside it (nobody has it open,
                // or it is a copy) cannot be read by a read-only connection,
                // which may not create one. With no writer there is nothing in
                // flight, so reading the file as an immutable snapshot is exact.
                if !tableExists("transcripts") {
                    sqlite3_close_v2(handle)
                    self.db = nil
                    var snapshot: OpaquePointer?
                    var components = URLComponents(url: path, resolvingAgainstBaseURL: false)
                    components?.scheme = "file"
                    components?.queryItems = [URLQueryItem(name: "immutable", value: "1")]
                    let uri = components?.string ?? "file:\(path.path)?immutable=1"
                    guard sqlite3_open_v2(uri, &snapshot,
                                          SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_FULLMUTEX,
                                          nil) == SQLITE_OK, snapshot != nil else {
                        if let snapshot { sqlite3_close_v2(snapshot) }
                        throw HistoryError.open
                    }
                    self.db = snapshot
                }
                // Whatever the file already has is what this connection sees.
                // A table that is not there yet reads as "no detail / no meta".
                guard tableExists("transcripts") else { throw HistoryError.open }
                detailReady = tableExists("utterance_detail")
                metaReady = tableExists("transcript_meta")
                return
            }
            try exec("PRAGMA journal_mode=WAL")
            try exec("PRAGMA synchronous=NORMAL")
            try exec(History.schema)
            do {
                try exec(History.detailSchema)
                detailReady = true
            } catch {
                log.error("cannot create utterance_detail; per-utterance detail disabled")
            }
            do {
                try exec(History.metaSchema)
                metaReady = true
            } catch {
                log.error("cannot create transcript_meta; delivery facts disabled")
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
        guard !text.isEmpty, isEnabled, !readOnly else { return -1 }
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
                if metaReady {
                    // Same rule, same transaction, for the delivery facts.
                    let orphans = try prepare(
                        "DELETE FROM transcript_meta WHERE transcript_id NOT IN "
                        + "(SELECT id FROM transcripts)")
                    defer { sqlite3_finalize(orphans) }
                    guard sqlite3_step(orphans) == SQLITE_DONE else {
                        throw HistoryError.step("meta trim")
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
        guard transcriptId > 0, isEnabled, detailEnabled, !readOnly else { return -1 }
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

    /// The late column: the off-path vocabulary pass finishes seconds after
    /// `addDetail` ran, so its outcome arrives through an UPDATE rather than
    /// riding the insert. Only ever fills `vocab` — every other column was true
    /// at insert time and stays exactly as written.
    ///
    /// Keyed by `transcript_id`, which `addDetail` writes at most once per
    /// transcript. Returns whether a row was actually updated — false covers a
    /// trimmed row, a detail-off install, and the unavailable database alike,
    /// and every one of those is a safe no-op.
    @discardableResult
    public func updateDetail(transcriptId: Int64, vocab: String) -> Bool {
        guard transcriptId > 0, isEnabled, detailEnabled, !readOnly else { return false }
        lock.lock(); defer { lock.unlock() }
        guard let db, detailReady else { return false }
        do {
            let update = try prepare(
                "UPDATE utterance_detail SET vocab = ? WHERE transcript_id = ?")
            defer { sqlite3_finalize(update) }
            sqlite3_bind_text(update, 1, vocab, -1, History.transient)
            sqlite3_bind_int64(update, 2, transcriptId)
            guard sqlite3_step(update) == SQLITE_DONE else {
                throw HistoryError.step("update detail")
            }
            return sqlite3_changes(db) > 0
        } catch {
            log.error("failed to update utterance detail")
            return false
        }
    }

    /// Store one transcript's delivery facts. Returns whether a row was written
    /// — false covers history off, no parent id, a read-only or unavailable
    /// database, and a legacy file whose third table could not be created.
    ///
    /// Not gated on `history_detail`: that flag is about keeping the raw and
    /// intermediate TEXT of an utterance, and nothing here is text the user
    /// said. It is gated on `history_enabled`, like the transcript itself.
    /// Written at most once per transcript; a second write replaces the first.
    @discardableResult
    public func addMeta(transcriptId: Int64, _ meta: TranscriptMeta) -> Bool {
        guard transcriptId > 0, isEnabled, !readOnly else { return false }
        lock.lock(); defer { lock.unlock() }
        guard db != nil, metaReady else { return false }
        do {
            let insert = try prepare(
                "INSERT OR REPLACE INTO transcript_meta "
                + "(transcript_id, app_bundle_id, outcome, release_to_text_ms, finalize_ms, "
                + "ai_ms, post_ms, insert_ms, ai, input_device, created) "
                + "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)")
            defer { sqlite3_finalize(insert) }
            sqlite3_bind_int64(insert, 1, transcriptId)
            bind(insert, 2, meta.appBundleID)
            bind(insert, 3, meta.outcome)
            bind(insert, 4, meta.releaseToTextMs)
            bind(insert, 5, meta.finalizeMs)
            bind(insert, 6, meta.aiMs)
            bind(insert, 7, meta.postMs)
            bind(insert, 8, meta.insertMs)
            bind(insert, 9, meta.ai)
            bind(insert, 10, meta.inputDevice)
            sqlite3_bind_double(insert, 11, Date().timeIntervalSince1970)
            guard sqlite3_step(insert) == SQLITE_DONE else { throw HistoryError.step("insert meta") }
            return true
        } catch {
            log.error("failed to add transcript meta")
            return false
        }
    }

    /// Delete every stored transcript and reclaim file space. Row ids keep
    /// counting up (DELETE leaves `sqlite_sequence` alone) — same as Python.
    public func purge() {
        lock.lock(); defer { lock.unlock() }
        guard db != nil, !readOnly else { return }
        do {
            try exec("DELETE FROM transcripts")
            // "Delete All Transcripts" means all of it: the detail rows hold the
            // same text (and more of it), so leaving them would make the button
            // a lie.
            if detailReady { try exec("DELETE FROM utterance_detail") }
            if metaReady { try exec("DELETE FROM transcript_meta") }
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

    /// Newest-first transcripts, each with its detail and delivery facts when
    /// they exist — the Dictations page's one read.
    ///
    /// LEFT joins, unlike `details`: the transcript is the record here, and a
    /// row with neither table behind it (Python era, detail off, a build before
    /// `transcript_meta`) is still a dictation the user made. A table this file
    /// does not have is simply left out of the statement.
    public func dictations(limit: Int = 50) -> [DictationRow] {
        guard limit > 0 else { return [] }
        lock.lock(); defer { lock.unlock() }
        guard db != nil else { return [] }
        let detailColumns = detailReady
            ? "d.id, d.raw, d.corrected, d.refined, d.inserted, d.vocab, d.ai, d.terms_hit, d.created"
            : "NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL"
        let metaColumns = metaReady
            ? "m.transcript_id, m.app_bundle_id, m.outcome, m.release_to_text_ms, m.finalize_ms, "
                + "m.ai_ms, m.post_ms, m.insert_ms, m.ai, m.input_device"
            : "NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL"
        var sql = "SELECT t.id, t.ts, t.text, t.engine, t.duration_ms, "
            + detailColumns + ", " + metaColumns + " FROM transcripts t "
        if detailReady { sql += "LEFT JOIN utterance_detail d ON d.transcript_id = t.id " }
        if metaReady { sql += "LEFT JOIN transcript_meta m ON m.transcript_id = t.id " }
        // `d.id DESC` breaks the (never expected) tie of two detail rows for
        // one transcript toward the newer one; the dedupe below keeps it.
        sql += "ORDER BY t.id DESC" + (detailReady ? ", d.id DESC" : "") + " LIMIT ?"
        do {
            let stmt = try prepare(sql)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, Int64(limit))
            var out: [DictationRow] = []
            var seen = Set<Int64>()
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = sqlite3_column_int64(stmt, 0)
                guard seen.insert(id).inserted else { continue }
                let ts = sqlite3_column_double(stmt, 1)
                let text = column(stmt, 2) ?? ""
                let engine = column(stmt, 3) ?? ""
                let entry = HistoryEntry(id: id, ts: ts, text: text, engine: engine,
                                         durationMs: double(stmt, 4))
                var detail: UtteranceDetail?
                if sqlite3_column_type(stmt, 5) != SQLITE_NULL {
                    detail = UtteranceDetail(
                        id: sqlite3_column_int64(stmt, 5), transcriptId: id,
                        raw: column(stmt, 6) ?? "", corrected: column(stmt, 7) ?? "",
                        refined: column(stmt, 8) ?? "", inserted: column(stmt, 9) ?? "",
                        vocab: column(stmt, 10), ai: column(stmt, 11),
                        termsHit: History.decodeTerms(column(stmt, 12)),
                        created: sqlite3_column_double(stmt, 13),
                        text: text, engine: engine, ts: ts)
                }
                var meta: TranscriptMeta?
                if sqlite3_column_type(stmt, 14) != SQLITE_NULL {
                    meta = TranscriptMeta(
                        appBundleID: column(stmt, 15), outcome: column(stmt, 16),
                        releaseToTextMs: double(stmt, 17), finalizeMs: double(stmt, 18),
                        aiMs: double(stmt, 19), postMs: double(stmt, 20),
                        insertMs: double(stmt, 21), ai: column(stmt, 22),
                        inputDevice: column(stmt, 23))
                }
                out.append(DictationRow(entry: entry, detail: detail, meta: meta))
            }
            return out
        } catch {
            log.error("failed to read dictations")
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

    private func double(_ stmt: OpaquePointer?, _ index: Int32) -> Double? {
        sqlite3_column_type(stmt, index) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, index)
    }

    private func bind(_ stmt: OpaquePointer?, _ index: Int32, _ value: Double?) {
        if let value { sqlite3_bind_double(stmt, index, value) }
        else { sqlite3_bind_null(stmt, index) }
    }

    /// Whether `sqlite_master` names this table. The read-only open's only
    /// way to learn what the file has without trying to create it.
    private func tableExists(_ name: String) -> Bool {
        guard let stmt = try? prepare(
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?") else { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, name, -1, History.transient)
        return sqlite3_step(stmt) == SQLITE_ROW
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
