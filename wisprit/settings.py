"""Wisprit configuration: ~/.wisprit/config.json with atomic persistence.

Loads the config file merged over ``DEFAULTS`` so missing keys always resolve;
``set()`` persists immediately via write-to-temp + ``os.replace`` so a crash
mid-write can never truncate the config. Unknown keys found in the file are
preserved (forward compatibility with newer versions editing the same file).
"""

from __future__ import annotations

import copy
import json
import logging
import os
import tempfile
import threading
from pathlib import Path

from wisprit import runtime

log = logging.getLogger("wisprit.settings")

DEFAULTS = {
    "hotkey": "fn",                      # "fn" | "right_option"
    "hold_debounce_ms": 150,
    "locale": "en-US",
    "finalize_timeout_ms": 1500,
    "filler_removal": True,
    "ensure_sentence_period": False,
    "leading_space": "auto",             # "auto" | "always" | "never"
    "terminal_bundle_ids": list(runtime.DEFAULT_TERMINAL_BUNDLE_IDS),
    "pill_position": None,               # [x, y] once user drags it
    "pill_hidden": False,
    "history_enabled": True,
    "history_limit": 1000,
    "engine": "auto",                    # "auto"|"apple_live"|"mlx_whisper"|"faster_whisper"
    "mlx_model": "mlx-community/whisper-large-v3-turbo",
    "paste_restore_delay_ms": 500,      # restore too early = paste of stale clipboard (competitors' #1 bug)
    "enabled": True,                     # master toggle from menu
}


class Settings:
    """Thread-safe view over config.json. Reads are cheap dict lookups;
    every ``set()`` rewrites the file atomically."""

    def __init__(self, path=runtime.CONFIG_PATH):
        self._path = Path(path)
        self._lock = threading.RLock()
        self._data: dict = copy.deepcopy(DEFAULTS)
        self.reload()

    def get(self, key):
        """Return the current value for ``key`` (None if unknown)."""
        with self._lock:
            return self._data.get(key)

    def set(self, key, value):
        """Update ``key`` and persist the full config atomically."""
        with self._lock:
            self._data[key] = value
            self._save()

    def reload(self):
        """Re-read config.json from disk, merging over DEFAULTS.

        A missing file yields pure defaults; a corrupt file logs an error and
        keeps defaults without overwriting the user's file.
        """
        with self._lock:
            data = copy.deepcopy(DEFAULTS)
            try:
                raw = self._path.read_text(encoding="utf-8")
            except FileNotFoundError:
                self._data = data
                return
            except OSError:
                log.exception("cannot read %s; using defaults", self._path)
                self._data = data
                return
            try:
                loaded = json.loads(raw)
                if isinstance(loaded, dict):
                    data.update(loaded)
                else:
                    log.error("%s is not a JSON object; using defaults", self._path)
            except ValueError:
                log.exception("corrupt JSON in %s; using defaults", self._path)
            self._data = data

    def as_dict(self) -> dict:
        """Deep copy of the current effective configuration."""
        with self._lock:
            return copy.deepcopy(self._data)

    def _save(self):
        """Atomic write: temp file in the same directory, fsync, os.replace."""
        # Serialize first so a non-JSON-able value raises before touching disk.
        payload = json.dumps(self._data, indent=2, ensure_ascii=False) + "\n"
        try:
            self._path.parent.mkdir(parents=True, exist_ok=True)
            fd, tmp_path = tempfile.mkstemp(
                dir=str(self._path.parent), prefix=self._path.name, suffix=".tmp"
            )
            try:
                with os.fdopen(fd, "w", encoding="utf-8") as fh:
                    fh.write(payload)
                    fh.flush()
                    os.fsync(fh.fileno())
                os.replace(tmp_path, self._path)
            except BaseException:
                try:
                    os.unlink(tmp_path)
                except OSError:
                    pass
                raise
        except OSError:
            # Disk/permission trouble: keep the in-memory value, stay alive.
            log.exception("failed to persist settings to %s", self._path)

    def __getattr__(self, name):
        # Attribute-style read access: settings.hotkey == settings.get("hotkey").
        # Only called when normal attribute lookup fails; the underscore guard
        # keeps internal attribute misses (and __init__ ordering) safe.
        if name.startswith("_"):
            raise AttributeError(name)
        with self._lock:
            if name in self._data:
                return self._data[name]
        raise AttributeError(f"no setting named {name!r}")


_instance: Settings | None = None
_instance_lock = threading.Lock()


def load() -> Settings:
    """Module-level singleton accessor (default config path)."""
    global _instance
    with _instance_lock:
        if _instance is None:
            _instance = Settings()
        return _instance
