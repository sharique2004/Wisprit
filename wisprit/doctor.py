"""`wisprit doctor` — diagnose the environment and permissions.

Prints a human checklist and returns exit 0 only when the required set is
green. TCC grants attach to the *interpreter binary* running Wisprit, so this
also prints that path (grants silently reset if the venv is recreated).
"""

from __future__ import annotations

import json
import subprocess
import sys
import time
from pathlib import Path

from wisprit import permissions, runtime

OK = "\033[32m✓\033[0m"
BAD = "\033[31m✗\033[0m"
WARN = "\033[33m!\033[0m"


def _line(mark: str, label: str, detail: str = "") -> None:
    print(f"  {mark}  {label}" + (f"  — {detail}" if detail else ""))


def _live_helper_contention() -> str:
    """Describe any other apple_live process currently running.

    Another instance — typically an orphan left by a crashed MeetingScribe —
    holds the on-device transcriber, which makes every fresh helper exit
    within milliseconds. Run when the probe fails so the report names the
    cause instead of just the symptom.
    """
    try:
        out = subprocess.run(
            ["pgrep", "-fl", str(runtime.APPLE_LIVE_BIN)],
            capture_output=True, text=True, timeout=2.0).stdout.strip()
    except Exception:  # noqa: BLE001
        return ""
    if not out:
        return ""
    pids = ", ".join(line.split()[0] for line in out.splitlines())
    return (f"; another apple_live is running (pid {pids}) and may be holding "
            "the transcriber — quit MeetingScribe, or if it has crashed, "
            f"run: kill {pids}")


def _probe_apple_live() -> tuple[bool, str]:
    """Feed 2 s of silence through apple_live; expect a clean exit."""
    if not runtime.APPLE_LIVE_BIN.exists():
        return False, f"helper not found at {runtime.APPLE_LIVE_BIN}"
    try:
        proc = subprocess.Popen(
            [str(runtime.APPLE_LIVE_BIN), "en-US", str(runtime.SAMPLE_RATE),
             str(runtime.CHANNELS)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            bufsize=0,
        )
    except OSError as exc:
        return False, f"could not spawn helper: {exc}"
    try:
        silence = b"\x00\x00" * (runtime.SAMPLE_RATE * 2)  # 2 s int16 mono
        proc.stdin.write(silence)
        proc.stdin.close()
        rc = proc.wait(timeout=15)
        if rc == 0:
            return True, "streams and exits cleanly"
        err = (proc.stderr.read() or b"").decode(errors="replace").strip()
        return False, f"exit {rc}: {err[:120]}" + _live_helper_contention()
    except subprocess.TimeoutExpired:
        proc.kill()
        return False, "helper did not exit (timeout)" + _live_helper_contention()
    except Exception as exc:  # noqa: BLE001
        return False, f"{type(exc).__name__}: {exc}"


def _probe_refine() -> tuple[str, str]:
    """Check the Apple Intelligence cleanup helper. Returns (status, detail)
    where status is 'ok' | 'warn' | 'bad'."""
    if not runtime.REFINE_BIN.exists():
        import shutil
        if shutil.which("swiftc") is None:
            return "warn", ("helper not compiled and swiftc not found — "
                            "install Xcode or the Command Line Tools")
        return "warn", "helper not compiled yet (compiles on next app launch)"
    try:
        proc = subprocess.run(
            [str(runtime.REFINE_BIN), "--check"],
            capture_output=True, text=True, timeout=15,
        )
        info = json.loads((proc.stdout or "").strip().splitlines()[-1])
    except Exception as exc:  # noqa: BLE001
        return "bad", f"--check failed: {type(exc).__name__}: {exc}"
    if not info.get("available"):
        return "warn", (f"Apple Intelligence unavailable: "
                        f"{info.get('reason', 'unknown')} — enable it in "
                        "System Settings ▸ Apple Intelligence & Siri")
    # Round-trip a tiny transcript to prove end-to-end generation works.
    try:
        t0 = time.monotonic()
        proc = subprocess.run(
            [str(runtime.REFINE_BIN)],
            input="um hello this is a uh test",
            capture_output=True, text=True, timeout=30,
        )
        reply = json.loads((proc.stdout or "").strip().splitlines()[-1])
        ms = (time.monotonic() - t0) * 1000.0
    except subprocess.TimeoutExpired:
        # The very first generation after enabling Apple Intelligence pages
        # the whole model in and can exceed 30 s — transient, not broken.
        return "warn", ("cleanup probe timed out — the first model load can "
                        "be slow; re-run doctor")
    except Exception as exc:  # noqa: BLE001
        return "bad", f"cleanup probe failed: {type(exc).__name__}: {exc}"
    if not reply.get("ok"):
        return "warn", f"model error: {str(reply.get('error'))[:120]}"
    return "ok", f"cleans a short transcript in {ms:.0f} ms"


def run() -> int:
    print(f"\nWisprit doctor  (v{runtime.VERSION})\n" + "─" * 44)
    print(f"  interpreter: {sys.executable}")
    print("  (TCC permissions are granted to THIS binary; if you recreate the")
    print("   venv you must re-grant Accessibility and Input Monitoring.)\n")

    ok = True

    # --- permissions ---------------------------------------------------------
    acc = permissions.check_accessibility()
    _line(OK if acc else BAD, "Accessibility",
          "can post the paste keystroke" if acc else
          "MISSING → System Settings ▸ Privacy & Security ▸ Accessibility")
    ok = ok and acc

    im = permissions.check_input_monitoring()
    im_ok = im == "granted"
    _line(OK if im_ok else (WARN if im == "undetermined" else BAD), "Input Monitoring",
          {"granted": "hotkey tap can see the Fn key",
           "denied": "MISSING → System Settings ▸ Privacy & Security ▸ Input Monitoring",
           "undetermined": "not yet determined (grant on first run, or in Input Monitoring)"}[im])
    # Input Monitoring can read stale; Accessibility implies it, so don't fail
    # hard when Accessibility is granted.
    if not im_ok and not acc:
        ok = False

    mic = permissions.check_microphone()
    mic_ok = mic == "granted"
    _line(OK if mic_ok else (WARN if mic in ("undetermined",) else BAD), "Microphone",
          {"granted": "capture allowed",
           "undetermined": "will prompt on first recording",
           "denied": "MISSING → System Settings ▸ Privacy & Security ▸ Microphone",
           "restricted": "restricted by policy"}[mic])
    if mic == "denied":
        ok = False

    secure, _ = permissions.secure_input_active()
    _line(WARN if secure else OK, "Secure Keyboard Entry",
          "ACTIVE right now — the hotkey won't fire until it clears "
          "(a password field or an app like Slack holds it)"
          if secure else "not active")

    # --- helpers & engine ----------------------------------------------------
    live_ok, live_detail = _probe_apple_live()
    _line(OK if live_ok else BAD, "apple_live (SpeechAnalyzer)", live_detail)
    # Not fatal: batch fallback exists. But warn.
    mlx_ok = True
    try:
        import mlx_whisper  # noqa: F401
    except Exception as exc:  # noqa: BLE001
        mlx_ok = False
        mlx_detail = f"unavailable ({type(exc).__name__}) — fallback engine won't work"
    else:
        mlx_detail = "available (batch fallback)"
    _line(OK if mlx_ok else WARN, "mlx-whisper fallback", mlx_detail)
    if not live_ok and not mlx_ok:
        ok = False  # no working ASR at all

    # Not fatal either: dictation degrades to the deterministic pipeline.
    ai_status, ai_detail = _probe_refine()
    _line({"ok": OK, "warn": WARN, "bad": BAD}[ai_status],
          "AI cleanup (Apple Intelligence)", ai_detail)

    # --- state files ---------------------------------------------------------
    cfg_ok = _valid_json(runtime.CONFIG_PATH)
    _line(OK if cfg_ok else WARN, "config.json",
          str(runtime.CONFIG_PATH) if cfg_ok else
          f"missing/invalid at {runtime.CONFIG_PATH} (run once to create)")
    dict_ok = _valid_json(runtime.DICTIONARY_PATH)
    _line(OK if dict_ok else WARN, "dictionary.json",
          str(runtime.DICTIONARY_PATH) if dict_ok else
          f"missing/invalid at {runtime.DICTIONARY_PATH} (run once to create)")

    # --- non-checkable reminders --------------------------------------------
    print("\n  Reminders (can't be auto-checked):")
    print(f"  {WARN}  System Settings ▸ Keyboard ▸ \"Press 🌐 key to\" → \"Do Nothing\"")
    print(f"       (otherwise a bare Fn press opens emoji/dictation over Wisprit)")
    print(f"  {WARN}  On external keyboards Fn often isn't sent to macOS — switch")
    print(f"       hotkey to \"right_option\" in config.json if Fn never fires.")

    print("─" * 44)
    print(f"  {'READY' if ok else 'NOT READY — resolve the ✗ items above'}\n")
    return 0 if ok else 1


def _valid_json(path: Path) -> bool:
    try:
        json.loads(path.read_text(encoding="utf-8"))
        return True
    except Exception:
        return False


if __name__ == "__main__":
    raise SystemExit(run())
