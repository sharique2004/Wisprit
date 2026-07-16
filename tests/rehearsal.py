"""Headless end-to-end rehearsal of the Wisprit pipeline.

Drives the real AsrManager (streaming apple_live) + postprocess exactly as the
session does at key-release, using `say`-synthesized audio instead of a live
mic — so it needs no microphone, hotkey, or Accessibility grant. Verifies that
the transcript is recognized, cleaned, and dictionary-corrected end to end.

Run: ~/.meetingscribe/venv/bin/python tests/rehearsal.py
"""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import time
import wave
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from wisprit import postprocess, runtime  # noqa: E402
from wisprit.asr import AsrManager  # noqa: E402
from wisprit.dictionary import Dictionary  # noqa: E402
from wisprit.settings import Settings  # noqa: E402


def synth(text: str, path: Path) -> bytes:
    aiff = path.with_suffix(".aiff")
    wav = path.with_suffix(".wav")
    subprocess.run(["say", "-o", str(aiff), text], check=True)
    subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1",
                    str(aiff), str(wav)], check=True)
    with wave.open(str(wav), "rb") as w:
        assert w.getframerate() == runtime.SAMPLE_RATE
        return w.readframes(w.getnframes())


def run_one(mgr: AsrManager, settings, dictionary, phrase: str) -> tuple[str, float]:
    """Feed a phrase through the manager like the session: begin, feed paced
    chunks, then finalize + postprocess. Returns (final_text, release_ms)."""
    with tempfile.TemporaryDirectory() as td:
        pcm = synth(phrase, Path(td) / "u")

    mgr.begin(on_partial=lambda t: None)
    chunk = runtime.CHUNK_FRAMES * 2  # int16 mono
    i = 0
    while i < len(pcm):
        mgr.feed(pcm[i:i + chunk])
        i += chunk
        time.sleep(runtime.CHUNK_FRAMES / runtime.SAMPLE_RATE)  # real-time pace

    t0 = time.monotonic()
    result = mgr.finalize(pcm)
    release_ms = (time.monotonic() - t0) * 1000.0
    text = postprocess.process(result.text, settings, dictionary)
    return text, release_ms, result.engine


def main() -> int:
    # Isolated state so we don't touch the user's config/dictionary.
    with tempfile.TemporaryDirectory() as state:
        cfg_path = Path(state) / "config.json"
        dict_path = Path(state) / "dictionary.json"
        # "hear" lists the actual misrecognitions SpeechAnalyzer produces for
        # each term (it renders "InsForge" as "Win Forge"/"in forge" etc.) —
        # this is how the dictionary net fixes vocabulary the ASR can't bias to.
        dict_path.write_text('{"terms":[{"term":"InsForge",'
                             '"hear":["in forge","ins forge","win forge","inforge"]},'
                             '{"term":"MeetingScribe","hear":["meeting scribe"]}]}')
        settings = Settings(cfg_path)
        dictionary = Dictionary(dict_path)
        mgr = AsrManager(settings, dictionary)

        if not mgr.primary_available():
            print("apple_live helper unavailable — cannot run streaming rehearsal")
            return 1

        cases = [
            ("Hello world this is a test", ["hello", "world", "test"]),
            ("Send this message to the team", ["send", "team"]),
            ("I deployed the fix to in forge today",
             ["InsForge"]),   # dictionary correction must land
        ]
        failures = 0
        for phrase, must_contain in cases:
            text, release_ms, engine = run_one(mgr, settings, dictionary, phrase)
            low = text.lower()
            ok = all(w.lower() in low for w in must_contain)
            print(f"[{'OK ' if ok else 'FAIL'}] ({engine}, {release_ms:5.0f}ms release) "
                  f"{phrase!r}\n         -> {text!r}")
            if not ok:
                failures += 1
        print()
        if failures:
            print(f"{failures}/{len(cases)} rehearsal cases failed")
            return 1
        print(f"All {len(cases)} rehearsal cases passed — pipeline works end to end.")
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
