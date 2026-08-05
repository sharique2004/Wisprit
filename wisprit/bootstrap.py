"""First-run state bootstrap for Wisprit.

Creates ``~/.wisprit`` and seeds it with a default ``config.json`` and a
starter ``dictionary.json``. Strictly non-destructive: files that already
exist are never touched, so user edits survive every launch. ``app.py``
calls :func:`ensure_state_dir` before anything else.

Standalone use (defaults to the real state dir, or point it anywhere)::

    ~/.meetingscribe/venv/bin/python -m wisprit.bootstrap [state_dir]
"""

from __future__ import annotations

import json
import logging
import os
import shutil
import subprocess
import sys
from pathlib import Path

from wisprit import runtime

log = logging.getLogger("wisprit.bootstrap")

# Starter vocabulary for dictionary.json — names SpeechAnalyzer is likely to
# fumble on this machine. ``term`` is fed to apple_live --context for
# recognition biasing; ``hear`` entries become post-ASR word-boundary
# corrections (see docs/INTERFACES.md, dictionary.py). Deliberately
# conservative: no ``hear`` entry that collides with a common English word.
_SEED_TERMS = [
    {"term": "Wisprit", "hear": ["whisper it", "wisp rit"]},
    {"term": "Wispr Flow", "hear": ["whisper flow", "wisper flow"]},
    {"term": "InsForge", "hear": ["in forge", "ins forge"]},
    {"term": "MeetingScribe", "hear": ["meeting scribe"]},
    {"term": "Claude", "hear": ["clod"]},
    {"term": "Anthropic", "hear": ["and thropic", "anthropik"]},
    {"term": "MLX", "hear": ["m l x", "em el ex"]},
    {"term": "Sharique", "hear": ["shariq", "sharik", "shreek"]},
    {"term": "Khatri", "hear": ["katri", "kathri"]},
    {"term": "hackathon", "hear": ["hacker thought", "hacker thoughts",
                                    "hack a thon", "hackerthon", "hacker thon"]},
    {"term": "Penn State", "hear": ["pen state", "penn state university"]},
]


def _default_config() -> dict:
    """Return the default config mapping for a fresh config.json.

    The canonical source is ``wisprit.settings.DEFAULTS`` (owned by the
    settings module). If that module is unavailable or broken — a phased
    build, a partially damaged install — fall back to the identical defaults
    documented in docs/INTERFACES.md so a first run still produces a valid,
    editable config.json instead of crashing before the app can even start.
    """
    try:
        from wisprit.settings import DEFAULTS

        return dict(DEFAULTS)
    except Exception as exc:  # ImportError now, or a future settings bug
        log.warning(
            "wisprit.settings unavailable (%s); seeding config.json from "
            "the contract defaults in docs/INTERFACES.md",
            exc,
        )
        return {
            "hotkey": "fn",
            "hold_debounce_ms": 150,
            "locale": "en-US",
            "finalize_timeout_ms": 1500,
            "filler_removal": True,
            "ensure_sentence_period": False,
            "leading_space": "auto",
            "terminal_bundle_ids": list(runtime.DEFAULT_TERMINAL_BUNDLE_IDS),
            "pill_position": None,
            "pill_hidden": False,
            "history_enabled": True,
            "history_limit": 1000,
            "engine": "auto",
            "ai_cleanup": True,
            "ai_cleanup_max_words": 350,
            "ai_cleanup_timeout_ms": 12000,
            "mlx_model": "mlx-community/whisper-large-v3-turbo",
            "paste_restore_delay_ms": 500,
            "enabled": True,
        }


def _write_json_atomic(path: Path, payload: dict) -> None:
    """Write JSON via a temp file + rename so a crash never leaves half a file."""
    tmp = path.parent / (path.name + ".tmp")
    tmp.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    os.replace(tmp, path)


def ensure_state_dir(state_dir: Path = runtime.STATE_DIR) -> Path:
    """Create the Wisprit state directory and seed default files if missing.

    Idempotent. Creates ``state_dir`` (default ``~/.wisprit``) with 0700
    permissions — transcripts are personal — then writes ``config.json``
    (from settings defaults) and a starter ``dictionary.json`` only if each
    is absent. Returns the state directory path. Raises ``OSError`` if the
    directory cannot be created or written; callers decide how fatal that is.
    """
    state_dir = Path(state_dir)
    state_dir.mkdir(parents=True, exist_ok=True)
    try:
        os.chmod(state_dir, 0o700)
    except OSError as exc:
        log.warning("could not restrict %s to 0700: %s", state_dir, exc)

    config_path = state_dir / runtime.CONFIG_PATH.name
    if not config_path.exists():
        _write_json_atomic(config_path, _default_config())
        log.info("wrote default config: %s", config_path)

    dictionary_path = state_dir / runtime.DICTIONARY_PATH.name
    if not dictionary_path.exists():
        _write_json_atomic(dictionary_path, {"terms": _SEED_TERMS})
        log.info("wrote starter dictionary (%d terms): %s", len(_SEED_TERMS), dictionary_path)

    return state_dir


def ensure_refine_helper(force: bool = False) -> bool:
    """Compile the Apple Intelligence refine helper if missing or stale.

    Builds ``packaging/wisprit_refine.swift`` into ``~/.wisprit/bin`` when the
    binary is absent or older than its source. Compiles to a temp path and
    ``os.replace``s so an in-flight helper is never half-overwritten. Slow
    (~5–15 s) — app.py runs this on a background thread. Returns True when a
    usable binary exists afterwards; never raises.
    """
    src, dst = runtime.REFINE_SRC, runtime.REFINE_BIN
    try:
        if not src.exists():
            log.warning("refine helper source missing: %s", src)
            return dst.exists()
        if dst.exists() and not force and dst.stat().st_mtime >= src.stat().st_mtime:
            return True
        swiftc = shutil.which("swiftc")
        if swiftc is None:
            log.warning("swiftc not found — AI cleanup unavailable (install "
                        "Xcode or the Command Line Tools)")
            return dst.exists()
        dst.parent.mkdir(parents=True, exist_ok=True)
        # pid-unique temp so a concurrent compile (doctor + app launch) can
        # never interleave writes into the same file before the rename.
        tmp = dst.with_name(f"{dst.name}.build.{os.getpid()}")
        proc = subprocess.run(
            [swiftc, "-O", "-o", str(tmp), str(src)],
            capture_output=True, text=True, timeout=300,
        )
        if proc.returncode != 0:
            log.error("wisprit_refine compile failed: %s",
                      (proc.stderr or "").strip()[:500])
            tmp.unlink(missing_ok=True)
            return dst.exists()
        os.chmod(tmp, 0o755)
        os.replace(tmp, dst)
        log.info("compiled refine helper: %s", dst)
        return True
    except Exception:
        log.exception("ensure_refine_helper failed")
        return dst.exists()


def prefetch_fallback_model() -> bool:
    """Download the faster-whisper "small" model into the HF cache.

    ``asr_batch.transcribe_faster`` loads with ``local_files_only=True`` so
    the dictation path can never block on the network (a mid-dictation HF
    download once hung finalize until the user killed the app). This
    prefetch — run on a background thread at app start — is the only place
    that model may be downloaded. Idempotent: a complete cache is a fast
    no-op. Returns True when the model is locally available; never raises.
    """
    try:
        from huggingface_hub import snapshot_download

        snapshot_download("Systran/faster-whisper-small")
        log.info("faster-whisper fallback model present in HF cache")
        return True
    except Exception as exc:  # noqa: BLE001 — offline is a normal condition
        log.warning("faster-whisper prefetch failed (%s: %s) — the CPU "
                    "fallback engine stays unavailable until a launch with "
                    "network succeeds", type(exc).__name__, exc)
        return False


def _main(argv: list[str]) -> int:
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")
    target = Path(argv[1]).expanduser() if len(argv) > 1 else runtime.STATE_DIR
    try:
        state_dir = ensure_state_dir(target)
    except OSError as exc:
        print(f"bootstrap failed for {target}: {exc}", file=sys.stderr)
        return 1
    for name in (runtime.CONFIG_PATH.name, runtime.DICTIONARY_PATH.name):
        path = state_dir / name
        print(f"{path}: {'ok' if path.exists() else 'MISSING'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(_main(sys.argv))
