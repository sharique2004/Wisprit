"""Global push-to-talk hotkey via a listen-only CGEventTap.

Watches ``flagsChanged`` for the trigger key (Fn by default, right-Option as an
alternate) and ``keyDown`` for Esc / chord interrupts. The tap is **listen-only**
— it never suppresses events, so it cannot cause the "swallowed keystrokes"
class of bug and does not break the system's own double-Fn dictation.

Research-driven correctness (see docs/research/local-tech.md §2):

- Fn is detected **only** as a ``flagsChanged`` event whose keycode is
  ``kVK_Function`` (63). macOS sets the secondary-Fn flag on arrow/nav/F-keys
  even without the physical Fn key, so gating on the flag alone would fire on
  arrow keys (Hex bug #89). Gating on the keycode avoids that entirely.
- **Dirty-chord interrupt**: if any other key is pressed while the trigger is
  held, the gesture is a chord (e.g. Fn+Arrow), not dictation — we cancel.
- ``kCGEventTapDisabledByTimeout`` is handled in-callback (re-enable + reset
  state) and a watchdog re-enables a silently-dead tap.

Install on the **main thread** (its run-loop source is added to the current
CFRunLoop, which is the main NSApplication loop). Standalone test:
``python -m wisprit.hotkey`` prints events until Ctrl-C.
"""

from __future__ import annotations

import logging
import queue
import threading
import time
from dataclasses import dataclass

import Quartz

from wisprit import runtime

log = logging.getLogger("wisprit.hotkey")


@dataclass
class HotkeyEvent:
    kind: str   # "press" | "release" | "cancel" | "esc"
    ts: float   # time.monotonic()


class HotkeyListener:
    """Listen-only CGEventTap producing HotkeyEvents onto a queue."""

    def __init__(self, events: queue.Queue, settings):
        self._events = events
        self._settings = settings
        self._tap = None
        self._source = None
        self._runloop = None

        # Gesture state (touched only from the tap callback thread + setters).
        self._trigger_down = False
        self._armed = False
        self._recording = False
        self._rec_lock = threading.Lock()

        self._watchdog: threading.Thread | None = None
        self._watchdog_stop = threading.Event()

        hotkey = (settings.get("hotkey") if settings else None) or "fn"
        if hotkey == "right_option":
            self._trigger_keycode = runtime.KVK_RIGHT_OPTION
            self._trigger_mask = Quartz.kCGEventFlagMaskAlternate
        else:
            self._trigger_keycode = runtime.KVK_FUNCTION
            self._trigger_mask = runtime.FN_FLAG_MASK

    # --- public API -----------------------------------------------------------

    def set_recording(self, recording: bool) -> None:
        """Session tells us whether an utterance is in progress (gates Esc)."""
        with self._rec_lock:
            self._recording = recording

    def install(self) -> bool:
        """Create and enable the tap on the current (main) run loop.
        Returns False if the tap could not be created (Input Monitoring not
        granted) — the app then surfaces an actionable permission error."""
        mask = (Quartz.CGEventMaskBit(Quartz.kCGEventFlagsChanged)
                | Quartz.CGEventMaskBit(Quartz.kCGEventKeyDown))
        try:
            self._tap = Quartz.CGEventTapCreate(
                Quartz.kCGSessionEventTap,
                Quartz.kCGHeadInsertEventTap,
                Quartz.kCGEventTapOptionListenOnly,
                mask,
                self._callback,
                None,
            )
        except Exception:
            log.exception("CGEventTapCreate raised")
            self._tap = None
        if not self._tap:
            log.error("event tap creation failed — Input Monitoring likely not granted")
            return False

        self._source = Quartz.CFMachPortCreateRunLoopSource(None, self._tap, 0)
        self._runloop = Quartz.CFRunLoopGetCurrent()
        Quartz.CFRunLoopAddSource(self._runloop, self._source, Quartz.kCFRunLoopCommonModes)
        Quartz.CGEventTapEnable(self._tap, True)

        self._watchdog_stop.clear()
        self._watchdog = threading.Thread(target=self._watchdog_loop, daemon=True,
                                          name="hotkey-watchdog")
        self._watchdog.start()
        log.info("hotkey tap installed (trigger=%s)", self._settings.get("hotkey")
                 if self._settings else "fn")
        return True

    def uninstall(self) -> None:
        self._watchdog_stop.set()
        try:
            if self._tap:
                Quartz.CGEventTapEnable(self._tap, False)
            if self._source and self._runloop:
                Quartz.CFRunLoopRemoveSource(self._runloop, self._source,
                                             Quartz.kCFRunLoopCommonModes)
        except Exception:
            log.exception("error uninstalling hotkey tap")
        self._tap = None
        self._source = None

    # --- internals ------------------------------------------------------------

    def _emit(self, kind: str) -> None:
        try:
            self._events.put_nowait(HotkeyEvent(kind, time.monotonic()))
        except queue.Full:
            log.warning("hotkey event queue full; dropping %s", kind)

    def _callback(self, proxy, type_, event, refcon):
        # Keep this FAST — it runs on the event pipeline; stalling triggers
        # kCGEventTapDisabledByTimeout.
        try:
            if type_ in (Quartz.kCGEventTapDisabledByTimeout,
                         Quartz.kCGEventTapDisabledByUserInput):
                # Re-enable and reset gesture so we never get stuck "recording".
                if self._tap:
                    Quartz.CGEventTapEnable(self._tap, True)
                if self._trigger_down and self._armed:
                    self._emit("cancel")
                self._trigger_down = False
                self._armed = False
                return event

            keycode = Quartz.CGEventGetIntegerValueField(
                event, Quartz.kCGKeyboardEventKeycode)

            if type_ == Quartz.kCGEventFlagsChanged:
                if keycode == self._trigger_keycode:
                    flags = Quartz.CGEventGetFlags(event)
                    now_down = bool(flags & self._trigger_mask)
                    if now_down and not self._trigger_down:
                        self._trigger_down = True
                        self._armed = True
                        self._emit("press")
                    elif not now_down and self._trigger_down:
                        was_armed = self._armed
                        self._trigger_down = False
                        self._armed = False
                        if was_armed:
                            self._emit("release")
                return event

            if type_ == Quartz.kCGEventKeyDown:
                # Global "paste last transcript": ⌘⌃V (only when idle, i.e. not
                # holding the trigger). Listen-only, so we don't suppress it.
                if keycode == runtime.KVK_ANSI_V and not self._trigger_down:
                    flags = Quartz.CGEventGetFlags(event)
                    need = Quartz.kCGEventFlagMaskCommand | Quartz.kCGEventFlagMaskControl
                    if (flags & need) == need:
                        self._emit("paste_last")
                        return event
                # Chord interrupt: another key pressed during the trigger hold.
                if self._trigger_down and self._armed and keycode != self._trigger_keycode:
                    self._armed = False
                    self._emit("cancel")
                    return event
                # Esc cancels an in-progress utterance (e.g. toggle mode, or a
                # finalize we want to abort).
                if keycode == runtime.KVK_ESCAPE:
                    with self._rec_lock:
                        recording = self._recording
                    if recording:
                        self._emit("esc")
                return event
        except Exception:
            log.exception("hotkey callback error")
        return event

    def _watchdog_loop(self) -> None:
        is_enabled = getattr(Quartz, "CGEventTapIsEnabled", None)
        was_ok = True  # edge-trigger so a persistently-inert tap logs once, not every cycle
        while not self._watchdog_stop.wait(3.0):
            try:
                if not (self._tap and is_enabled):
                    continue
                if is_enabled(self._tap):
                    was_ok = True
                    continue
                Quartz.CGEventTapEnable(self._tap, True)
                if was_ok:
                    # First disable in this streak. A tap that keeps needing
                    # re-enabling is almost always a "ghost tap" — created but
                    # inert because Input Monitoring isn't granted.
                    log.warning("event tap disabled; re-enabling. If this "
                                "repeats, grant Input Monitoring to this python "
                                "binary (run `wisprit doctor`).")
                    # A silent disable may have dropped a release edge — reset
                    # the gesture like the in-callback handler, or we get stuck
                    # in a permanent "recording" state.
                    if self._trigger_down and self._armed:
                        self._emit("cancel")
                    self._trigger_down = False
                    self._armed = False
                was_ok = False
            except Exception:
                log.exception("watchdog error")


def _main() -> int:
    import signal

    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")
    from wisprit import settings as settings_mod
    cfg = settings_mod.load()
    q: queue.Queue = queue.Queue()
    listener = HotkeyListener(q, cfg)
    if not listener.install():
        print("FAILED to install hotkey tap. Grant Input Monitoring to this "
              "python binary in System Settings → Privacy & Security → Input "
              "Monitoring, then retry.")
        return 1
    listener.set_recording(True)  # so Esc prints in test mode
    print(f"Listening for '{cfg.get('hotkey')}' hold/release. Ctrl-C to quit.")

    def printer():
        while True:
            ev = q.get()
            print(f"  {ev.ts:10.3f}  {ev.kind}")
    threading.Thread(target=printer, daemon=True).start()

    signal.signal(signal.SIGINT, lambda *_: Quartz.CFRunLoopStop(Quartz.CFRunLoopGetCurrent()))
    Quartz.CFRunLoopRun()
    listener.uninstall()
    return 0


if __name__ == "__main__":
    raise SystemExit(_main())
