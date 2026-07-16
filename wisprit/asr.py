"""Speech recognition: streaming SpeechAnalyzer primary + batch fallbacks.

``AppleLiveEngine`` drives the compiled ``apple_live`` helper (see
docs/notes/asr-notes.md for the measured protocol): one subprocess per
utterance, int16 PCM in over stdin, NDJSON ``partial``/``final``/``done`` out,
process exits after stdin EOF. Finals are emitted *during* the hold, so
closing stdin at key-release only flushes a short tail — measured 66–182 ms.

``AsrManager`` is the engine-agnostic facade the session uses. It runs
``AppleLiveEngine`` as primary and transparently falls back to the batch
engines in :mod:`wisprit.asr_batch` (mlx-whisper → faster-whisper) using the
retained full-utterance PCM, so a helper crash or an OS regression never fully
kills dictation.
"""

from __future__ import annotations

import json
import logging
import queue
import subprocess
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable

from wisprit import runtime

log = logging.getLogger("wisprit.asr")

# Feeder queue depth (chunks). Drop-oldest under backpressure so the audio
# callback that calls feed() can never block; a dropped chunk only costs a few
# ms of captions, never the on-disk-equivalent transcript.
_FEED_QUEUE_CHUNKS = 100


@dataclass
class UtteranceResult:
    text: str
    engine: str
    finalize_ms: float
    timed_out: bool = False


@dataclass
class _StreamState:
    finals: list[str] = field(default_factory=list)
    last_partial: str = ""
    done: threading.Event = field(default_factory=threading.Event)


class AppleLiveEngine:
    """Streaming SpeechAnalyzer via the apple_live subprocess."""

    def __init__(self, settings, dictionary):
        self._settings = settings
        self._dictionary = dictionary
        self._proc: subprocess.Popen | None = None
        self._state = _StreamState()
        self._feed_q: queue.Queue = queue.Queue(maxsize=_FEED_QUEUE_CHUNKS)
        self._feeder: threading.Thread | None = None
        self._reader: threading.Thread | None = None
        self._closing = False
        self._context_path: str | None = None

    # --- health / setup -------------------------------------------------------

    def healthy(self) -> bool:
        """True if the helper binary exists and is executable."""
        try:
            return runtime.APPLE_LIVE_BIN.exists() and \
                Path(runtime.APPLE_LIVE_BIN).stat().st_mode & 0o111 != 0
        except OSError:
            return False

    def _write_context(self) -> str | None:
        """Write the dictionary terms to a --context file. Harmless if the
        helper ignores it (it does — see asr-notes.md), but future-proof."""
        try:
            terms = self._dictionary.terms() if self._dictionary else []
        except Exception:
            terms = []
        if not terms:
            return None
        try:
            runtime.STATE_DIR.mkdir(parents=True, exist_ok=True)
            path = runtime.STATE_DIR / "asr_context.json"
            path.write_text(json.dumps({"strings": terms}), encoding="utf-8")
            return str(path)
        except OSError:
            log.exception("could not write context file")
            return None

    # --- lifecycle ------------------------------------------------------------

    def begin(self, on_partial: Callable[[str], None]) -> bool:
        """Spawn a fresh helper and start reader/feeder threads. Returns False
        if the helper could not be launched (caller falls back)."""
        if not self.healthy():
            log.error("apple_live helper missing at %s", runtime.APPLE_LIVE_BIN)
            return False

        self._state = _StreamState()
        self._closing = False
        self._feed_q = queue.Queue(maxsize=_FEED_QUEUE_CHUNKS)
        self._context_path = self._write_context()

        locale = (self._settings.get("locale") if self._settings else None) or "en-US"
        cmd = [
            str(runtime.APPLE_LIVE_BIN), locale,
            str(runtime.SAMPLE_RATE), str(runtime.CHANNELS),
        ]
        if self._context_path:
            cmd += ["--context", self._context_path]

        try:
            self._proc = subprocess.Popen(
                cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL, bufsize=0,
            )
        except OSError:
            log.exception("failed to spawn apple_live")
            self._proc = None
            return False

        self._reader = threading.Thread(
            target=self._read_loop, args=(on_partial,), daemon=True, name="asr-read")
        self._reader.start()
        self._feeder = threading.Thread(
            target=self._feed_loop, daemon=True, name="asr-feed")
        self._feeder.start()
        return True

    def feed(self, pcm: bytes) -> None:
        """Enqueue a PCM chunk for the helper. Never blocks (drop-oldest)."""
        if self._proc is None:
            return
        try:
            self._feed_q.put_nowait(pcm)
        except queue.Full:
            try:
                self._feed_q.get_nowait()
                self._feed_q.put_nowait(pcm)
            except (queue.Empty, queue.Full):
                pass

    def finalize(self, timeout_s: float) -> UtteranceResult:
        """Close stdin, wait for the helper to finalize, assemble the text."""
        t0 = time.monotonic()
        if self._proc is None:
            return UtteranceResult("", "apple_live", 0.0, timed_out=True)

        self._closing = True
        # Signal the feeder to stop and close stdin so the helper flushes.
        try:
            self._feed_q.put_nowait(None)
        except queue.Full:
            try:
                self._feed_q.get_nowait()
                self._feed_q.put_nowait(None)
            except (queue.Empty, queue.Full):
                pass

        got_done = self._state.done.wait(timeout=timeout_s)
        finalize_ms = (time.monotonic() - t0) * 1000.0

        finals = [f.strip() for f in self._state.finals if f.strip()]
        text = " ".join(finals)
        timed_out = not got_done
        if timed_out:
            # Helper didn't emit {"t":"done"} in time — best effort: append the
            # last volatile partial if it adds anything.
            tail = self._state.last_partial.strip()
            if tail and tail not in text:
                text = (text + " " + tail).strip()
            log.warning("apple_live finalize timed out after %.0f ms", finalize_ms)

        self._teardown(kill=timed_out)
        return UtteranceResult(text.strip(), "apple_live", finalize_ms, timed_out)

    def cancel(self) -> None:
        """Discard the current utterance and kill the helper."""
        self._closing = True
        self._teardown(kill=True)

    # --- internals ------------------------------------------------------------

    def _feed_loop(self) -> None:
        proc = self._proc
        if proc is None or proc.stdin is None:
            return
        try:
            while True:
                if self._closing and self._feed_q.empty():
                    break
                try:
                    chunk = self._feed_q.get(timeout=0.2)
                except queue.Empty:
                    continue
                if chunk is None:  # sentinel: end of utterance
                    break
                try:
                    proc.stdin.write(chunk)
                    proc.stdin.flush()
                except (BrokenPipeError, ValueError, OSError):
                    break
        finally:
            try:
                if proc.stdin and not proc.stdin.closed:
                    proc.stdin.close()  # EOF → helper finalizes and exits
            except OSError:
                pass

    def _read_loop(self, on_partial: Callable[[str], None]) -> None:
        proc = self._proc
        if proc is None or proc.stdout is None:
            return
        try:
            for line in proc.stdout:
                if not line:
                    continue
                try:
                    ev = json.loads(line)
                except (ValueError, TypeError):
                    continue
                kind = ev.get("t")
                if kind == "final":
                    txt = ev.get("text", "")
                    if txt:
                        self._state.finals.append(txt)
                elif kind == "partial":
                    txt = ev.get("text", "")
                    if txt:
                        self._state.last_partial = txt
                        try:
                            on_partial(txt)
                        except Exception:
                            log.exception("on_partial callback raised")
                elif kind == "done":
                    break
        except (ValueError, OSError):
            log.exception("apple_live read loop error")
        finally:
            self._state.done.set()

    def _teardown(self, kill: bool) -> None:
        proc = self._proc
        self._proc = None
        if proc is None:
            return
        try:
            if proc.stdin and not proc.stdin.closed:
                try:
                    proc.stdin.close()
                except OSError:
                    pass
            if kill and proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(timeout=1.0)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait(timeout=1.0)
            else:
                try:
                    proc.wait(timeout=2.0)
                except subprocess.TimeoutExpired:
                    proc.kill()
        except Exception:
            log.exception("apple_live teardown error")


class AsrManager:
    """Engine-agnostic facade: apple_live primary + batch fallback."""

    def __init__(self, settings, dictionary):
        self._settings = settings
        self._dictionary = dictionary
        self._apple = AppleLiveEngine(settings, dictionary)
        self._primary_started = False

    def primary_available(self) -> bool:
        return self._apple.healthy()

    def begin(self, on_partial: Callable[[str], None]) -> None:
        engine = self._settings.get("engine") if self._settings else "auto"
        # In auto/apple_live mode we try the streaming helper; batch modes skip
        # straight to finalize-time transcription of the full PCM.
        if engine in (None, "auto", "apple_live"):
            self._primary_started = self._apple.begin(on_partial)
        else:
            self._primary_started = False

    def feed(self, pcm: bytes) -> None:
        if self._primary_started:
            self._apple.feed(pcm)

    def finalize(self, full_pcm: bytes) -> UtteranceResult:
        timeout_s = 1.5
        if self._settings:
            ms = self._settings.get("finalize_timeout_ms")
            if isinstance(ms, (int, float)) and ms > 0:
                timeout_s = ms / 1000.0

        if self._primary_started:
            result = self._apple.finalize(timeout_s)
            if result.text and not result.timed_out:
                return result
            # Empty or timed-out streaming result: try the batch fallback if we
            # have the audio, else return whatever we got.
            fallback = self._batch(full_pcm)
            if fallback is not None:
                return fallback
            return result

        # Batch-only path (engine override or primary unavailable).
        fallback = self._batch(full_pcm)
        return fallback or UtteranceResult("", "none", 0.0, timed_out=True)

    def cancel(self) -> None:
        if self._primary_started:
            self._apple.cancel()
        self._primary_started = False

    def _batch(self, full_pcm: bytes) -> UtteranceResult | None:
        if not full_pcm:
            return None
        from wisprit import asr_batch
        t0 = time.monotonic()
        engine = self._settings.get("engine") if self._settings else "auto"
        if engine == "faster_whisper":
            text = asr_batch.transcribe_faster(full_pcm, self._settings)
            name = "faster_whisper"
        else:
            text = asr_batch.transcribe_mlx(full_pcm, self._settings)
            name = "mlx_whisper"
            if not text:  # mlx failed — last-ditch CPU path
                text = asr_batch.transcribe_faster(full_pcm, self._settings)
                name = "faster_whisper"
        if not text:
            return None
        return UtteranceResult(text.strip(), name, (time.monotonic() - t0) * 1000.0)
