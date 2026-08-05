"""Golden generator for WispritPersistence. Run with the repo venv python from
the repo root:
    cd ~/Wisprit && ~/.meetingscribe/venv/bin/python <this file>
Emits the exact bytes/JSON/schema the Swift port must reproduce.
"""
import json, os, shutil, sqlite3, sys, tempfile, time
sys.path.insert(0, os.path.expanduser("~/Wisprit"))

root = tempfile.mkdtemp(prefix="wisprit-golden-")

from wisprit import runtime
from wisprit.settings import Settings, DEFAULTS
from wisprit.history import History

out = {}

# ---- 1. settings: pure-defaults file produced by set() on a fresh dir --------
p = os.path.join(root, "config.json")
s = Settings(p)
s.set("enabled", False)
out["config_defaults_after_set_enabled_false"] = open(p, encoding="utf-8").read()

# ---- 2. settings: unknown keys survive a round trip --------------------------
p2 = os.path.join(root, "config2.json")
with open(p2, "w", encoding="utf-8") as fh:
    json.dump({"hotkey": "right_option", "future_key": {"a": [1, 2.5, None, True]},
               "zz_unknown": "kept", "locale": "en-GB"}, fh)
s2 = Settings(p2)
s2.set("history_limit", 42)
out["config_unknown_roundtrip"] = open(p2, encoding="utf-8").read()
out["config_unknown_get_hotkey"] = s2.get("hotkey")
out["config_unknown_get_future_key"] = s2.get("future_key")
out["config_unknown_get_missing"] = s2.get("nope")

# ---- 3. settings: corrupt file keeps defaults, file untouched ----------------
p3 = os.path.join(root, "config3.json")
open(p3, "w", encoding="utf-8").write("{not json")
s3 = Settings(p3)
out["config_corrupt_keeps_defaults"] = s3.as_dict() == DEFAULTS
out["config_corrupt_file_untouched"] = open(p3, encoding="utf-8").read()

# ---- 4. settings: non-object JSON keeps defaults -----------------------------
p4 = os.path.join(root, "config4.json")
open(p4, "w", encoding="utf-8").write("[1,2,3]")
out["config_nonobject_keeps_defaults"] = Settings(p4).as_dict() == DEFAULTS

# ---- 5. settings: unicode is written raw (ensure_ascii=False) ----------------
p5 = os.path.join(root, "config5.json")
s5 = Settings(p5)
s5.set("locale", "de-DEé—\t\"\\")
out["config_unicode"] = open(p5, encoding="utf-8").read()

out["defaults_json"] = json.dumps(DEFAULTS, indent=2, ensure_ascii=False)

# ---- 6. history: schema of a DB the Python just created ----------------------
dbp = os.path.join(root, "history.sqlite")
h = History(dbp)
ids = [h.add("first", "apple_live", 1000.0), h.add("second", "mlx_whisper", 250.5),
       h.add("", "apple_live", 10.0)]
out["history_add_ids"] = ids
out["history_last3"] = [{k: v for k, v in r.items() if k != "ts"} for r in h.last(3)]
out["history_last_text"] = h.last_text()
h.close()
con = sqlite3.connect(dbp)
out["history_sqlite_master"] = con.execute(
    "SELECT type, name, tbl_name, sql FROM sqlite_master ORDER BY name").fetchall()
out["history_journal_mode"] = con.execute("PRAGMA journal_mode").fetchone()[0]
out["history_table_info"] = con.execute("PRAGMA table_info(transcripts)").fetchall()
con.close()

# ---- 7. history: trim to limit, oldest-first ---------------------------------
class FakeSettings:
    def __init__(self, d): self._d = d
    def get(self, k): return self._d.get(k)

dbp2 = os.path.join(root, "trim.sqlite")
h2 = History(dbp2, FakeSettings({"history_enabled": True, "history_limit": 3}))
for i in range(6):
    h2.add(f"t{i}", "e", float(i))
out["history_trim_texts"] = [r["text"] for r in h2.last(10)]
out["history_trim_ids"] = [r["id"] for r in h2.last(10)]
h2.purge()
out["history_after_purge"] = h2.last(10)
out["history_after_purge_last_text"] = h2.last_text()
h2.add("post-purge", "e", 1.0)
out["history_post_purge_id"] = h2.last(1)[0]["id"]
h2.close()

# ---- 8. history: disabled add is a no-op, reads still work -------------------
dbp3 = os.path.join(root, "disabled.sqlite")
h3 = History(dbp3, FakeSettings({"history_enabled": True, "history_limit": 1000}))
h3.add("before", "e", 1.0)
h3._settings = FakeSettings({"history_enabled": False, "history_limit": 1000})
out["history_disabled_add"] = h3.add("blocked", "e", 1.0)
out["history_disabled_read"] = h3.last_text()
h3.close()

# ---- 9. metrics: the exact JSONL line session.py writes ----------------------
def metrics_line(held_ms, engine, finalize_ms, timed_out, chars, post_ms, insert_ms,
                 outcome, ts, release_to_text_ms=None, ai_ms=None, ai_outcome=None):
    entry = {
        "ts": ts,
        "held_ms": round(held_ms, 1),
        "engine": engine,
        "finalize_ms": round(finalize_ms, 1),
        "timed_out": timed_out,
        "post_ms": round(post_ms, 1),
        "insert_ms": round(insert_ms, 1),
        "outcome": outcome,
        "chars": chars,
    }
    if release_to_text_ms is not None:
        entry["release_to_text_ms"] = round(release_to_text_ms, 1)
    if ai_ms is not None:
        entry["ai_ms"] = round(ai_ms, 1)
    if ai_outcome is not None:
        entry["ai"] = ai_outcome
    return json.dumps(entry) + "\n"

out["metrics_full"] = metrics_line(
    47416.04, "apple_live", 604.44, False, 525, 3.29, 517.31, "paste",
    1785871825.3455071, 3171.23, 1923.91, "applied")
out["metrics_empty_outcome"] = metrics_line(
    1468.75, "apple_live", 153.0, True, 0, 0.0, 0.0, "empty",
    1785872035.681684, None, 220.44, "off")
out["metrics_minimal"] = metrics_line(
    10.0, "", 0.0, False, 0, 0.0, 0.0, "error", 1.0)

def dump(o):
    return json.dumps(o, indent=1, ensure_ascii=False, default=str)

print(dump(out))
shutil.rmtree(root, ignore_errors=True)
