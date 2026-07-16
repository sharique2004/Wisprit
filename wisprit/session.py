"""The dictation state machine.

Consumes ``HotkeyEvent``s from the shared queue and drives one utterance
through capture → streaming ASR → deterministic cleanup → insertion → history,
flashing the pill and logging per-stage latency along the way. Runs on a single
worker thread so the stages are naturally serialized; the loop is crash-proof
(any per-utterance error is logged and the machine returns to IDLE).

States: IDLE → RECORDING → FINALIZING → INSERTING → IDLE, with a CANCEL path
(Esc, chord interrupt, or a sub-debounce tap) that discards audio.
"""

from __future__ import annotations

import json
import logging
import queue
import threading
import time

from wisprit import postprocess, ui
from wisprit.insert import insert_text

log = logging.getLogger("wisprit.session")

IDLE, RECORDING, FINALIZING, INSERTING = "idle", "recording", "finalizing", "inserting"


class Session:
    def __init__(self, events, settings, dictionary, history, asr_manager,
                 hotkey_listener, audio_capture, pill=None, on_state=None):
        self._events = events
        self._settings = settings
        self._dictionary = dictionary
        self._history = history
        self._asr = asr_manager
        self._hotkey = hotkey_listener
        self._audio = audio_capture
        self._pill = pill
        self._on_state = on_state

        self._state = IDLE
        self._press_ts = 0.0
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None

        self._level_stop = threading.Event()
        self._level_thread: threading.Thread | None = None

    # --- lifecycle ------------------------------------------------------------

    def start(self) -> None:
        self._thread = threading.Thread(target=self.run, daemon=True, name="session")
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()

    def run(self) -> None:
        log.info("session loop started")
        while not self._stop.is_set():
            try:
                ev = self._events.get(timeout=0.25)
            except queue.Empty:
                continue
            try:
                self._dispatch(ev)
            except Exception:
                log.exception("error handling %s in state %s; resetting", ev, self._state)
                self._abort("internal error")

    # --- dispatch -------------------------------------------------------------

    def _dispatch(self, ev) -> None:
        kind = ev.kind
        if kind == "press":
            if self._state == IDLE:
                self._begin(ev.ts)
        elif kind == "release":
            if self._state == RECORDING:
                self._finish(ev.ts)
        elif kind in ("cancel", "esc"):
            if self._state in (RECORDING, FINALIZING):
                self._abort("cancelled" if kind == "cancel" else "esc")
        elif kind == "paste_last":
            if self._state == IDLE:
                self.paste_last()

    # --- transitions ----------------------------------------------------------

    def _begin(self, ts: float) -> None:
        if not self._enabled():
            return
        try:
            self._dictionary.maybe_reload()
        except Exception:
            log.exception("dictionary reload failed")

        self._press_ts = ts
        started = self._audio.start()
        if not started:
            self._flash_error("microphone unavailable")
            return
        self._asr.begin(self._on_partial)
        self._set_state(RECORDING)
        self._hotkey.set_recording(True)
        self._pill_call("show_recording")
        self._start_level_ticker()

    def _finish(self, ts: float) -> None:
        self._hotkey.set_recording(False)
        self._stop_level_ticker()
        debounce_ms = self._num("hold_debounce_ms", 150)
        held_ms = (ts - self._press_ts) * 1000.0

        if held_ms < debounce_ms:
            # Accidental brush — discard.
            self._audio.stop()
            self._asr.cancel()
            self._set_state(IDLE)
            self._pill_call("hide")
            return

        self._set_state(FINALIZING)
        self._pill_call("show_finalizing")

        t_rel = time.monotonic()
        full_pcm = self._audio.stop()
        result = self._asr.finalize(full_pcm)
        t_asr = time.monotonic()

        text = postprocess.process(result.text, self._settings, self._dictionary)
        t_post = time.monotonic()

        if not text:
            self._set_state(IDLE)
            self._flash_error("nothing recognized")
            self._log_metrics(held_ms, result, 0.0, 0.0, "empty")
            return

        # History first — a failed insert must never lose words.
        try:
            self._history.add(text, result.engine, held_ms)
        except Exception:
            log.exception("history add failed")

        self._set_state(INSERTING)
        ins = insert_text(text, self._settings)
        t_ins = time.monotonic()

        if ins.ok:
            self._pill_call("flash_success")
        elif ins.method == "blocked_secure":
            self._flash_error("secure field — press ⌘⌃V to paste")
        else:
            self._flash_error(ins.detail or "insert failed")

        self._log_metrics(
            held_ms, result,
            post_ms=(t_post - t_asr) * 1000.0,
            insert_ms=(t_ins - t_post) * 1000.0,
            outcome=ins.method,
            release_to_text_ms=(t_ins - t_rel) * 1000.0,
        )
        self._set_state(IDLE)

    def _abort(self, reason: str) -> None:
        self._hotkey.set_recording(False)
        self._stop_level_ticker()
        try:
            self._audio.stop()
        except Exception:
            log.exception("audio stop during abort failed")
        try:
            self._asr.cancel()
        except Exception:
            log.exception("asr cancel during abort failed")
        self._set_state(IDLE)
        if reason == "esc" or reason == "cancelled":
            self._pill_call("hide")
        else:
            self._flash_error(reason)

    # --- paste-last recovery --------------------------------------------------

    def paste_last(self) -> None:
        """Re-insert the most recent transcript (⌘⌃V / menu). The recovery path
        for a paste that failed the first time."""
        try:
            text = self._history.last_text()
        except Exception:
            log.exception("could not read last transcript")
            text = None
        if not text:
            self._flash_error("no transcript to paste")
            return
        ins = insert_text(text, self._settings)
        if ins.ok:
            self._pill_call("flash_success")
        elif ins.method == "blocked_secure":
            self._flash_error("secure field — can't paste here")
        else:
            self._flash_error(ins.detail or "paste failed")

    # --- helpers --------------------------------------------------------------

    def _on_partial(self, text: str) -> None:
        # Show a rolling tail of the partial in the pill.
        words = text.split()
        tail = " ".join(words[-8:]) if words else ""
        self._pill_call("update_partial", tail)

    def _start_level_ticker(self) -> None:
        self._level_stop.clear()

        def tick():
            while not self._level_stop.wait(0.05):
                self._pill_call("update_level", float(self._audio.level))

        self._level_thread = threading.Thread(target=tick, daemon=True, name="pill-level")
        self._level_thread.start()

    def _stop_level_ticker(self) -> None:
        self._level_stop.set()

    def _enabled(self) -> bool:
        try:
            return bool(self._settings.get("enabled"))
        except Exception:
            return True

    def _num(self, key, default):
        try:
            v = self._settings.get(key)
            return v if isinstance(v, (int, float)) and v >= 0 else default
        except Exception:
            return default

    def _set_state(self, state: str) -> None:
        self._state = state
        if self._on_state:
            try:
                ui.call_on_main(self._on_state, state)
            except Exception:
                log.exception("on_state callback failed")

    def _pill_call(self, method: str, *args) -> None:
        if self._pill is None:
            return
        fn = getattr(self._pill, method, None)
        if fn is None:
            return
        ui.call_on_main(fn, *args)

    def _flash_error(self, msg: str) -> None:
        log.warning("utterance error: %s", msg)
        self._pill_call("flash_error", msg)

    def _log_metrics(self, held_ms, result, post_ms, insert_ms, outcome,
                     release_to_text_ms=None) -> None:
        try:
            from wisprit import runtime
            entry = {
                "ts": time.time(),
                "held_ms": round(held_ms, 1),
                "engine": result.engine,
                "finalize_ms": round(result.finalize_ms, 1),
                "timed_out": result.timed_out,
                "post_ms": round(post_ms, 1),
                "insert_ms": round(insert_ms, 1),
                "outcome": outcome,
                "chars": len(result.text or ""),
            }
            if release_to_text_ms is not None:
                entry["release_to_text_ms"] = round(release_to_text_ms, 1)
            runtime.METRICS_LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
            with open(runtime.METRICS_LOG_PATH, "a", encoding="utf-8") as fh:
                fh.write(json.dumps(entry) + "\n")
        except Exception:
            log.exception("metrics log write failed")
