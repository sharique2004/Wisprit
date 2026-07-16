"""Transcript history: text-only SQLite log at ~/.wisprit/history.sqlite.

Deliberately stores ONLY transcript text + metadata — never audio — so the
database stays tiny and there is nothing sensitive to leak beyond what was
already typed into some app. WAL journal mode keeps single-writer inserts
fast and readers non-blocking.

Threading: reads happen on the main thread (the status menu rebuilds recents
when it opens) while writes happen on the session thread, so every public
method takes an internal lock. The connection uses ``check_same_thread=False``
because those callers are different threads; the lock serializes them. A
``SystemError`` from a raced connection is not a ``sqlite3.Error`` subclass, so
methods catch ``Exception`` where a failure must never propagate.
"""

from __future__ import annotations

import logging
import sqlite3
import threading
import time
from pathlib import Path

from wisprit import runtime

log = logging.getLogger("wisprit.history")

_SCHEMA = """
CREATE TABLE IF NOT EXISTS transcripts (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    ts          REAL NOT NULL,
    text        TEXT NOT NULL,
    engine      TEXT NOT NULL DEFAULT '',
    duration_ms REAL
)
"""

_DEFAULT_LIMIT = 1000


class History:
    """Append/read/purge access to the transcript log.

    Every method degrades gracefully: if the database could not be opened or
    an operation fails, it logs and returns a safe value instead of raising —
    a broken history must never take down dictation.
    """

    def __init__(self, path=runtime.HISTORY_DB_PATH, settings=None):
        self._path = Path(path)
        self._settings = settings
        self._conn: sqlite3.Connection | None = None
        self._lock = threading.Lock()
        try:
            self._path.parent.mkdir(parents=True, exist_ok=True)
            conn = sqlite3.connect(str(self._path), check_same_thread=False)
            conn.execute("PRAGMA journal_mode=WAL")
            conn.execute("PRAGMA synchronous=NORMAL")
            conn.execute(_SCHEMA)
            conn.commit()
            self._conn = conn
        except (OSError, sqlite3.Error):
            log.exception("cannot open history db at %s; history disabled", self._path)
            self._conn = None

    def _enabled(self) -> bool:
        if self._settings is None:
            return True
        return bool(self._settings.get("history_enabled"))

    def _limit(self) -> int:
        if self._settings is not None:
            value = self._settings.get("history_limit")
            if isinstance(value, int) and value > 0:
                return value
        return _DEFAULT_LIMIT

    def add(self, text, engine, duration_ms) -> int:
        """Store one transcript; returns its row id, or -1 if not stored
        (history disabled, empty text, or database unavailable)."""
        if not text or self._conn is None or not self._enabled():
            return -1
        with self._lock:
            try:
                cur = self._conn.execute(
                    "INSERT INTO transcripts (ts, text, engine, duration_ms) VALUES (?, ?, ?, ?)",
                    (time.time(), text, engine or "", duration_ms),
                )
                row_id = int(cur.lastrowid)
                self._trim()
                self._conn.commit()
                return row_id
            except Exception:  # incl. SystemError from a raced NULL return
                log.exception("failed to add history entry")
                return -1

    def _trim(self):
        """Keep only the newest history_limit rows (called inside add's txn)."""
        self._conn.execute(
            "DELETE FROM transcripts WHERE id NOT IN "
            "(SELECT id FROM transcripts ORDER BY id DESC LIMIT ?)",
            (self._limit(),),
        )

    def last(self, n=5) -> list[dict]:
        """Newest-first list of the last ``n`` entries as dicts
        (id, ts, text, engine, duration_ms). Reads work even when adding is
        disabled — the paste-last recovery path must always function."""
        if self._conn is None or n <= 0:
            return []
        with self._lock:
            try:
                rows = self._conn.execute(
                    "SELECT id, ts, text, engine, duration_ms FROM transcripts "
                    "ORDER BY id DESC LIMIT ?",
                    (n,),
                ).fetchall()
                return [
                    {"id": r[0], "ts": r[1], "text": r[2], "engine": r[3], "duration_ms": r[4]}
                    for r in rows
                ]
            except Exception:
                log.exception("failed to read history")
                return []

    def last_text(self) -> str | None:
        """Text of the most recent transcript, or None if history is empty."""
        if self._conn is None:
            return None
        with self._lock:
            try:
                row = self._conn.execute(
                    "SELECT text FROM transcripts ORDER BY id DESC LIMIT 1"
                ).fetchone()
                return row[0] if row else None
            except Exception:
                log.exception("failed to read last transcript")
                return None

    def purge(self):
        """Delete every stored transcript and reclaim file space."""
        if self._conn is None:
            return
        with self._lock:
            try:
                self._conn.execute("DELETE FROM transcripts")
                self._conn.commit()
                self._conn.execute("VACUUM")
            except Exception:
                log.exception("failed to purge history")

    def close(self):
        """Close the underlying connection (idempotent)."""
        with self._lock:
            if self._conn is not None:
                try:
                    self._conn.close()
                except Exception:
                    log.exception("error closing history db")
                self._conn = None
