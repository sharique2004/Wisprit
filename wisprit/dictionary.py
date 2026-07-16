"""Custom vocabulary: ~/.wisprit/dictionary.json.

Serves two roles (belt and suspenders, because the reused ``apple_live`` helper
uses ``SpeechTranscriber``, whose ``contextualStrings`` biasing Apple has
confirmed is a no-op — see docs/research/local-tech.md §4):

1. ``terms()`` — the canonical vocabulary list handed to ``apple_live
   --context`` (harmless if the helper ignores it).
2. ``corrections()`` — compiled, word-boundary, case-insensitive
   substitutions applied *after* recognition by :mod:`wisprit.postprocess`.
   This is the real vocabulary net.

File format::

    {"terms": [
        {"term": "InsForge", "hear": ["in forge", "ins forge"]},
        {"term": "Wispr Flow", "hear": ["whisper flow"]}
    ]}

Every ``term`` also self-corrects its own casing (``insforge`` → ``InsForge``),
and each ``hear`` phrase maps to the canonical ``term``. ``maybe_reload()``
cheaply checks the file mtime so edits are picked up without a restart.
"""

from __future__ import annotations

import json
import logging
import re
from pathlib import Path

from wisprit import runtime

log = logging.getLogger("wisprit.dictionary")


class Dictionary:
    """Load, watch, and compile the custom-vocabulary file."""

    def __init__(self, path=runtime.DICTIONARY_PATH):
        self._path = Path(path)
        self._mtime: float | None = None
        self._terms: list[str] = []
        # Compiled once per (re)load: list of (pattern, replacement).
        self._corrections: list[tuple[re.Pattern, str]] = []
        self._load()

    # --- public API -----------------------------------------------------------

    def terms(self) -> list[str]:
        """Canonical vocabulary terms for ``apple_live --context``."""
        return list(self._terms)

    def corrections(self) -> list[tuple[re.Pattern, str]]:
        """Compiled (pattern, replacement) pairs for post-ASR correction."""
        return list(self._corrections)

    def maybe_reload(self) -> bool:
        """Reload if the file changed on disk. Returns True if reloaded."""
        try:
            mtime = self._path.stat().st_mtime
        except OSError:
            # File vanished — keep whatever we had rather than going empty.
            return False
        if mtime != self._mtime:
            self._load()
            return True
        return False

    def add_term(self, term: str, misrecognitions: list[str] | None = None) -> None:
        """Add or update a term (with optional ``hear`` phrases) and persist."""
        term = (term or "").strip()
        if not term:
            return
        data = self._read_raw()
        entries = data.setdefault("terms", [])
        for entry in entries:
            if isinstance(entry, dict) and entry.get("term", "").lower() == term.lower():
                hears = set(entry.get("hear", []))
                hears.update(misrecognitions or [])
                entry["term"] = term
                entry["hear"] = sorted(h for h in hears if h)
                break
        else:
            entries.append({"term": term, "hear": sorted(misrecognitions or [])})
        self._write_raw(data)
        self._load()

    def remove_term(self, term: str) -> None:
        """Remove a term by its canonical spelling (case-insensitive)."""
        term = (term or "").strip().lower()
        if not term:
            return
        data = self._read_raw()
        entries = data.get("terms", [])
        data["terms"] = [
            e for e in entries
            if not (isinstance(e, dict) and e.get("term", "").lower() == term)
        ]
        self._write_raw(data)
        self._load()

    @property
    def path(self) -> Path:
        return self._path

    # --- internals ------------------------------------------------------------

    def _read_raw(self) -> dict:
        try:
            data = json.loads(self._path.read_text(encoding="utf-8"))
            if isinstance(data, dict):
                return data
            log.error("%s is not a JSON object; treating as empty", self._path)
        except FileNotFoundError:
            pass
        except (OSError, ValueError):
            log.exception("cannot read %s; treating as empty", self._path)
        return {"terms": []}

    def _write_raw(self, data: dict) -> None:
        import os
        import tempfile

        try:
            self._path.parent.mkdir(parents=True, exist_ok=True)
            fd, tmp = tempfile.mkstemp(dir=str(self._path.parent), suffix=".tmp")
            with os.fdopen(fd, "w", encoding="utf-8") as fh:
                fh.write(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
            os.replace(tmp, self._path)
        except OSError:
            log.exception("failed to write dictionary %s", self._path)

    def _load(self) -> None:
        try:
            self._mtime = self._path.stat().st_mtime
        except OSError:
            self._mtime = None

        data = self._read_raw()
        terms: list[str] = []
        # Build correction pairs. Longer phrases first so multi-word
        # misrecognitions win over any single-word overlap.
        raw_pairs: list[tuple[str, str]] = []
        for entry in data.get("terms", []):
            if not isinstance(entry, dict):
                continue
            term = (entry.get("term") or "").strip()
            if not term:
                continue
            terms.append(term)
            # Self-correct the term's own casing (only if it isn't already the
            # exact canonical form — the pattern is case-insensitive).
            raw_pairs.append((term, term))
            for hear in entry.get("hear", []):
                hear = (hear or "").strip()
                if hear:
                    raw_pairs.append((hear, term))

        raw_pairs.sort(key=lambda p: len(p[0]), reverse=True)
        corrections: list[tuple[re.Pattern, str]] = []
        for pattern_src, replacement in raw_pairs:
            try:
                # Word-boundary, case-insensitive. \b works around whitespace
                # inside multi-word phrases too (each token bounded).
                pat = re.compile(
                    r"\b" + re.escape(pattern_src).replace(r"\ ", r"\s+") + r"\b",
                    re.IGNORECASE,
                )
            except re.error:
                log.warning("could not compile correction for %r", pattern_src)
                continue
            corrections.append((pat, replacement))

        self._terms = terms
        self._corrections = corrections
        log.debug("dictionary loaded: %d terms, %d corrections",
                  len(terms), len(corrections))
