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
import os
import queue
import signal
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


def reap_orphaned_helpers() -> int:
    """Kill any orphaned ``apple_live`` processes (reparented to launchd, ppid==1).

    A Wisprit or MeetingScribe that crashed can leave a helper behind; a pile of
    these can hold the on-device transcriber and hang new helpers. Orphans
    (ppid==1) are always safe to kill — a *live* owner's helper has that owner
    as its parent, so this never touches an actively-recording MeetingScribe.
    Returns the number reaped.
    """
    reaped = 0
    try:
        out = subprocess.run(
            ["pgrep", "-f", str(runtime.APPLE_LIVE_BIN)],
            capture_output=True, text=True, timeout=2.0).stdout.split()
    except Exception:
        return 0
    for pid in out:
        try:
            ppid = subprocess.run(
                ["ps", "-o", "ppid=", "-p", pid],
                capture_output=True, text=True, timeout=2.0).stdout.strip()
            if ppid == "1":
                os.kill(int(pid), signal.SIGKILL)
                reaped += 1
        except (ValueError, ProcessLookupError, PermissionError, OSError):
            continue
    if reaped:
        log.info("reaped %d orphaned apple_live process(es)", reaped)
    return reaped


@dataclass
class UtteranceResult:
    text: str
    engine: str
    finalize_ms: float
    timed_out: bool = False
    crashed: bool = False   # helper exited without emitting {"t":"done"}


@dataclass
class _StreamState:
    finals: list[str] = field(default_factory=list)
    last_partial: str = ""
    done: threading.Event = field(default_factory=threading.Event)
    clean: bool = False     # set True only when the helper emits {"t":"done"}


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

        # Defensive: if a previous utterance somehow left a live process (it
        # shouldn't — the session is IDLE-only), kill it before spawning.
        if self._proc is not None:
            self._teardown(kill=True)

        state = _StreamState()
        feed_q: queue.Queue = queue.Queue(maxsize=_FEED_QUEUE_CHUNKS)
        self._state = state
        self._feed_q = feed_q
        self._closing = False
        self._context_path = self._write_context()

        locale = (self._settings.get("locale") if self._settings else None) or "en-US"
        cmd = [
            str(runtime.APPLE_LIVE_BIN), locale,
            str(runtime.SAMPLE_RATE), str(runtime.CHANNELS),
        ]
        if self._context_path:
            cmd += ["--context", self._context_path]

        try:
            proc = subprocess.Popen(
                cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL, bufsize=0,
            )
        except OSError:
            log.exception("failed to spawn apple_live")
            self._proc = None
            return False
        self._proc = proc

        # Threads capture proc/state/feed_q as locals, so a stale thread from a
        # prior utterance can never touch the next utterance's state.
        self._reader = threading.Thread(
            target=self._read_loop, args=(on_partial, proc, state),
            daemon=True, name="asr-read")
        self._reader.start()
        self._feeder = threading.Thread(
            target=self._feed_loop, args=(proc, feed_q), daemon=True, name="asr-feed")
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

        state = self._state
        got_done = state.done.wait(timeout=timeout_s)
        finalize_ms = (time.monotonic() - t0) * 1000.0

        finals = [f.strip() for f in state.finals if f.strip()]
        text = " ".join(finals)
        timed_out = not got_done
        # done was set but not via a clean {"t":"done"} event → the helper
        # exited early (crash / EOF). The caller re-transcribes from full PCM.
        crashed = got_done and not state.clean
        if timed_out or crashed:
            # Best effort: append the last volatile partial if it adds anything.
            tail = state.last_partial.strip()
            if tail and tail not in text:
                text = (text + " " + tail).strip()
            log.warning("apple_live finalize %s after %.0f ms",
                        "timed out" if timed_out else "helper exited early", finalize_ms)

        self._teardown(kill=timed_out)
        return UtteranceResult(text.strip(), "apple_live", finalize_ms,
                               timed_out=timed_out, crashed=crashed)

    def cancel(self) -> None:
        """Discard the current utterance and kill the helper."""
        self._closing = True
        self._teardown(kill=True)

    # --- internals ------------------------------------------------------------

    def _feed_loop(self, proc, feed_q) -> None:
        if proc is None or proc.stdin is None:
            return
        try:
            while True:
                if self._closing and feed_q.empty():
                    break
                try:
                    chunk = feed_q.get(timeout=0.2)
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

    def _read_loop(self, on_partial: Callable[[str], None], proc, state) -> None:
        if proc is None or proc.stdout is None:
            # Nothing to read — unblock finalize() so it doesn't wait the full
            # timeout, and mark it as a non-clean exit so the caller falls back.
            state.done.set()
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
                        state.finals.append(txt)
                elif kind == "partial":
                    txt = ev.get("text", "")
                    if txt:
                        state.last_partial = txt
                        try:
                            on_partial(txt)
                        except Exception:
                            log.exception("on_partial callback raised")
                elif kind == "done":
                    state.clean = True   # clean finalize, not a crash/EOF
                    break
        except (ValueError, OSError):
            log.exception("apple_live read loop error")
        finally:
            state.done.set()

    def _teardown(self, kill: bool) -> None:
        proc = self._proc
        self._proc = None
        if proc is None:
            return
        try:
            # 1. Close stdin → EOF → the helper finalizes and exits cleanly,
            #    releasing the on-device transcriber. Always do this first, even
            #    when cancelling, so we never abandon a helper mid-stream.
            if proc.stdin and not proc.stdin.closed:
                try:
                    proc.stdin.close()
                except OSError:
                    pass
            # 2. Short grace period for the clean exit (covers the normal case
            #    and a cancelled quick tap — the helper exits in ~150 ms).
            grace = 0.4 if kill else 2.0
            try:
                proc.wait(timeout=grace)
                return
            except subprocess.TimeoutExpired:
                pass
            # 3. Didn't exit — escalate to SIGTERM, then SIGKILL, and ALWAYS
            #    reap so it can never orphan.
            proc.terminate()
            try:
                proc.wait(timeout=0.5)
                return
            except subprocess.TimeoutExpired:
                pass
            proc.kill()
            try:
                proc.wait(timeout=1.0)
            except subprocess.TimeoutExpired:
                log.error("apple_live pid %s would not die", proc.pid)
        except Exception:
            log.exception("apple_live teardown error")


class AsrManager:
    """Engine-agnostic facade: apple_live primary + batch fallback."""

    def __init__(self, settings, dictionary):
        self._settings = settings
        self._dictionary = dictionary
        self._apple = AppleLiveEngine(settings, dictionary)
        self._primary_started = False
        # A crashed/hung helper usually means an orphan is holding the
        # on-device transcriber; when finalize sees that, the next begin()
        # reaps before spawning so the primary engine self-heals.
        self._reap_next_begin = False
        # Clean up any helpers a previous crash/kill left behind, so a fresh
        # launch never starts contending with orphans.
        reap_orphaned_helpers()

    def primary_available(self) -> bool:
        return self._apple.healthy()

    def begin(self, on_partial: Callable[[str], None]) -> None:
        engine = self._settings.get("engine") if self._settings else "auto"
        # In auto/apple_live mode we try the streaming helper; batch modes skip
        # straight to finalize-time transcription of the full PCM.
        if engine in (None, "auto", "apple_live"):
            if self._reap_next_begin:
                # Last utterance's helper died instantly — an orphan from a
                # crashed MeetingScribe can appear MID-SESSION and hold the
                # transcriber (observed: orphan born 14:29 broke dictations at
                # 20:04+ despite the startup reap). ~30 ms, rare path only.
                self._reap_next_begin = False
                reap_orphaned_helpers()
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
            if result.crashed or result.timed_out:
                self._reap_next_begin = True
            # Any streaming result with text (clean or timeout-with-partials) is
            # returned as-is. The batch engines (mlx/faster-whisper) are the
            # recovery path for a genuine helper CRASH only — never for an empty
            # result. On silence the helper legitimately returns nothing, and
            # running Whisper on that silence is slow AND hallucinates stock
            # phrases like "Thank you." A silent push-to-talk must insert nothing.
            if result.text or not result.crashed:
                return result
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
