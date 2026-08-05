import Foundation

/// Every expectation in this file was produced by RUNNING the Python it ports,
/// not by hand. Regenerate with:
///
///     ~/.meetingscribe/venv/bin/python \
///       /private/tmp/claude-501/-Users-shariquekhatri-Wisprit/\
///       08bd5841-5936-4964-a20b-5f526dba0b52/scratchpad/gen_goldens.py
///
/// (the generator drives `wisprit.settings.Settings`, `wisprit.history.History`
/// and a verbatim copy of `session.py::_log_metrics` against a temp state dir,
/// then prints the resulting bytes / sqlite_master rows / JSONL lines.)
enum Golden {

    // MARK: settings

    /// `Settings(p); s.set("enabled", False)` on an empty directory — proves
    /// key order, indent, the six terminal bundle ids, and the trailing newline.
    static let configDefaultsAfterSetEnabledFalse = """
    {
      "hotkey": "fn",
      "hold_debounce_ms": 150,
      "locale": "en-US",
      "finalize_timeout_ms": 1500,
      "filler_removal": true,
      "ensure_sentence_period": false,
      "leading_space": "auto",
      "terminal_bundle_ids": [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.github.wez.wezterm",
        "net.kovidgoyal.kitty",
        "io.alacritty",
        "com.mitchellh.ghostty"
      ],
      "pill_position": null,
      "pill_hidden": false,
      "history_enabled": true,
      "history_limit": 1000,
      "engine": "auto",
      "ai_cleanup": true,
      "ai_cleanup_max_words": 350,
      "ai_cleanup_timeout_ms": 12000,
      "mlx_model": "mlx-community/whisper-large-v3-turbo",
      "paste_restore_delay_ms": 500,
      "enabled": false
    }

    """

    /// Input file was
    /// `{"hotkey":"right_option","future_key":{"a":[1,2.5,null,true]},"zz_unknown":"kept","locale":"en-GB"}`
    /// then `s.set("history_limit", 42)`. Known keys keep DEFAULTS order and the
    /// file's values; unknown keys survive and append in file order; the int 1
    /// stays an int while 2.5 stays a float.
    static let configUnknownRoundtrip = """
    {
      "hotkey": "right_option",
      "hold_debounce_ms": 150,
      "locale": "en-GB",
      "finalize_timeout_ms": 1500,
      "filler_removal": true,
      "ensure_sentence_period": false,
      "leading_space": "auto",
      "terminal_bundle_ids": [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.github.wez.wezterm",
        "net.kovidgoyal.kitty",
        "io.alacritty",
        "com.mitchellh.ghostty"
      ],
      "pill_position": null,
      "pill_hidden": false,
      "history_enabled": true,
      "history_limit": 42,
      "engine": "auto",
      "ai_cleanup": true,
      "ai_cleanup_max_words": 350,
      "ai_cleanup_timeout_ms": 12000,
      "mlx_model": "mlx-community/whisper-large-v3-turbo",
      "paste_restore_delay_ms": 500,
      "enabled": true,
      "future_key": {
        "a": [
          1,
          2.5,
          null,
          true
        ]
      },
      "zz_unknown": "kept"
    }

    """

    /// `s.set("locale", "de-DEé—\\t\\"\\\\")` — ensure_ascii=False keeps é and the
    /// em dash raw while tab/quote/backslash are escaped.
    static let configUnicodeLocaleLine = #"  "locale": "de-DEé—\t\"\\","#

    // MARK: history

    /// `sqlite_master.sql` for the table the Python's `_SCHEMA` creates. SQLite
    /// stores the statement verbatim minus `IF NOT EXISTS`, so this is the
    /// strongest available schema-compatibility assertion.
    static let historyTableSQL = """
    CREATE TABLE transcripts (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        ts          REAL NOT NULL,
        text        TEXT NOT NULL,
        engine      TEXT NOT NULL DEFAULT '',
        duration_ms REAL
    )
    """

    /// `PRAGMA table_info(transcripts)`: (cid, name, type, notnull, dflt_value, pk)
    static let historyTableInfo: [(Int, String, String, Int, String?, Int)] = [
        (0, "id", "INTEGER", 0, nil, 1),
        (1, "ts", "REAL", 1, nil, 0),
        (2, "text", "TEXT", 1, nil, 0),
        (3, "engine", "TEXT", 1, "''", 0),
        (4, "duration_ms", "REAL", 0, nil, 0),
    ]

    /// AUTOINCREMENT bookkeeping table the Python DB also carries.
    static let historyMasterNames = ["sqlite_sequence", "transcripts"]
    static let historyJournalMode = "wal"

    // MARK: metrics

    /// `_log_metrics(47416.04, result(apple_live, 604.44, timed_out=False, 525 chars),
    ///  post_ms=3.29, insert_ms=517.31, outcome="paste", release_to_text_ms=3171.23,
    ///  ai_ms=1923.91, ai_outcome="applied")` at ts 1785871825.3455071.
    static let metricsFull =
        #"{"ts": 1785871825.3455071, "held_ms": 47416.0, "engine": "apple_live", "finalize_ms": 604.4, "timed_out": false, "post_ms": 3.3, "insert_ms": 517.3, "outcome": "paste", "chars": 525, "release_to_text_ms": 3171.2, "ai_ms": 1923.9, "ai": "applied"}"# + "\n"

    /// The `outcome="empty"` branch: no `release_to_text_ms`, `ai_ms`/`ai` present.
    static let metricsEmptyOutcome =
        #"{"ts": 1785872035.681684, "held_ms": 1468.8, "engine": "apple_live", "finalize_ms": 153.0, "timed_out": true, "post_ms": 0.0, "insert_ms": 0.0, "outcome": "empty", "chars": 0, "ai_ms": 220.4, "ai": "off"}"# + "\n"

    /// All three optionals omitted.
    static let metricsMinimal =
        #"{"ts": 1.0, "held_ms": 10.0, "engine": "", "finalize_ms": 0.0, "timed_out": false, "post_ms": 0.0, "insert_ms": 0.0, "outcome": "error", "chars": 0}"# + "\n"

    /// A real line from `~/.wisprit/metrics.log` (Python era) — the stream this
    /// writer must keep appending to.
    static let metricsRealPythonLine =
        #"{"ts": 1785897780.5532238, "held_ms": 46647.7, "engine": "apple_live", "finalize_ms": 103.8, "timed_out": false, "post_ms": 2.9, "insert_ms": 535.2, "outcome": "paste", "chars": 613, "release_to_text_ms": 3188.3, "ai_ms": 2413.8, "ai": "applied"}"#
}
