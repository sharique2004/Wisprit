"""The floating status indicator.

A tiny, borderless, non-activating ``NSPanel`` that floats above every app (and
full-screen spaces) as a minimal "Wisprit is listening" dot — it does NOT show
the transcript (the text goes straight to your cursor). It just pulses with your
voice while recording and flashes a colour on finish. Draggable; position
persists.

Every public method is expected to be called on the main thread (the session
routes through :func:`wisprit.ui.call_on_main`).
"""

from __future__ import annotations

import logging

from AppKit import (
    NSBezierPath, NSColor, NSMakeRect, NSPanel, NSScreen,
    NSStatusWindowLevel, NSView, NSWindowCollectionBehaviorCanJoinAllSpaces,
    NSWindowCollectionBehaviorFullScreenAuxiliary,
    NSWindowStyleMaskNonactivatingPanel, NSTimer,
)
from Foundation import NSMakePoint, NSObject
import objc

from wisprit import runtime

log = logging.getLogger("wisprit.pill")

# A small circular indicator — just big enough to notice, never a text window.
PILL_W, PILL_H = 26.0, 26.0
_BOTTOM_MARGIN = 90.0

_COLORS = {
    "recording": (0.93, 0.26, 0.28),   # red
    "finalizing": (0.60, 0.62, 0.66),  # gray
    "success": (0.30, 0.78, 0.45),     # green
    "error": (0.95, 0.66, 0.22),       # amber
}


class _PillView(NSView):
    def initWithFrame_(self, frame):
        self = objc.super(_PillView, self).initWithFrame_(frame)
        if self is None:
            return None
        self._dot = (0.6, 0.6, 0.6)
        self._level = 0.0
        return self

    def setDot_(self, rgb):
        self._dot = rgb

    def setLevel_(self, level):
        self._level = max(0.0, min(1.0, float(level)))

    def drawRect_(self, rect):
        b = self.bounds()
        cx, cy = b.size.width / 2.0, b.size.height / 2.0
        r, g, bl = self._dot

        # Faint translucent halo so the dot reads on any background.
        NSColor.colorWithCalibratedWhite_alpha_(0.0, 0.28).set()
        halo = NSBezierPath.bezierPathWithOvalInRect_(
            NSMakeRect(1, 1, b.size.width - 2, b.size.height - 2))
        halo.fill()

        # The dot itself grows subtly with input level while recording.
        base = 6.0
        radius = base + self._level * 5.0
        NSColor.colorWithCalibratedRed_green_blue_alpha_(r, g, bl, 0.95).set()
        dot = NSBezierPath.bezierPathWithOvalInRect_(
            NSMakeRect(cx - radius, cy - radius, radius * 2, radius * 2))
        dot.fill()


class Pill(NSObject):
    """Controller owning the panel and its view."""

    def initWithSettings_(self, settings):
        self = objc.super(Pill, self).init()
        if self is None:
            return None
        self._settings = settings
        self._panel = None
        self._view = None
        self._hide_timer = None
        self._build()
        return self

    # --- construction ---------------------------------------------------------

    @objc.python_method
    def _build(self):
        try:
            frame = NSMakeRect(0, 0, PILL_W, PILL_H)
            panel = NSPanel.alloc().initWithContentRect_styleMask_backing_defer_(
                frame, NSWindowStyleMaskNonactivatingPanel, 2, False)
            panel.setLevel_(NSStatusWindowLevel)
            panel.setOpaque_(False)
            panel.setBackgroundColor_(NSColor.clearColor())
            panel.setHasShadow_(True)
            panel.setMovableByWindowBackground_(True)
            panel.setCollectionBehavior_(
                NSWindowCollectionBehaviorCanJoinAllSpaces
                | NSWindowCollectionBehaviorFullScreenAuxiliary)
            panel.setHidesOnDeactivate_(False)
            panel.setDelegate_(self)

            view = _PillView.alloc().initWithFrame_(frame)
            panel.setContentView_(view)
            self._panel = panel
            self._view = view
            self._restore_position()
        except Exception:
            log.exception("pill construction failed; running without a pill")
            self._panel = None
            self._view = None

    @objc.python_method
    def _restore_position(self):
        pos = None
        try:
            pos = self._settings.get("pill_position")
        except Exception:
            pos = None
        if pos and isinstance(pos, (list, tuple)) and len(pos) == 2:
            self._panel.setFrameOrigin_(NSMakePoint(float(pos[0]), float(pos[1])))
            return
        screen = NSScreen.mainScreen()
        if screen is None:
            return
        sf = screen.frame()
        x = sf.origin.x + (sf.size.width - PILL_W) / 2.0
        y = sf.origin.y + _BOTTOM_MARGIN
        self._panel.setFrameOrigin_(NSMakePoint(x, y))

    # --- NSWindowDelegate ------------------------------------------------------

    def windowDidMove_(self, notification):
        if self._panel is None:
            return
        try:
            origin = self._panel.frame().origin
            self._settings.set("pill_position", [float(origin.x), float(origin.y)])
        except Exception:
            log.exception("could not persist pill position")

    # --- public state API (main thread) ---------------------------------------

    @objc.python_method
    def _hidden(self) -> bool:
        try:
            return bool(self._settings.get("pill_hidden"))
        except Exception:
            return False

    @objc.python_method
    def _show(self, state: str):
        if self._panel is None or self._hidden():
            return
        self._cancel_hide_timer()
        self._view.setDot_(_COLORS.get(state, (0.6, 0.6, 0.6)))
        self._view.setNeedsDisplay_(True)
        self._panel.orderFrontRegardless()

    @objc.python_method
    def show_recording(self):
        self._view.setLevel_(0.0)
        self._show("recording")

    @objc.python_method
    def update_level(self, level):
        if self._panel is None or self._view is None or self._hidden():
            return
        self._view.setLevel_(level)
        self._view.setNeedsDisplay_(True)

    @objc.python_method
    def update_partial(self, text):
        # The indicator intentionally does not display the transcript — the text
        # goes straight to the cursor. Kept for API compatibility; no-op.
        return

    @objc.python_method
    def show_finalizing(self):
        self._view.setLevel_(0.0)
        self._show("finalizing")

    @objc.python_method
    def flash_success(self):
        self._show("success")
        self._schedule_hide(0.6)

    @objc.python_method
    def flash_error(self, msg=""):
        # No text on the tiny indicator; the reason is logged by the session.
        self._show("error")
        self._schedule_hide(1.6)

    @objc.python_method
    def hide(self):
        self._cancel_hide_timer()
        if self._panel is not None:
            self._panel.orderOut_(None)

    # --- auto-hide timer -------------------------------------------------------

    @objc.python_method
    def _schedule_hide(self, seconds: float):
        self._cancel_hide_timer()
        try:
            self._hide_timer = NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(
                seconds, self, b"_hideFired:", None, False)
        except Exception:
            log.exception("could not schedule pill hide")

    @objc.python_method
    def _cancel_hide_timer(self):
        if self._hide_timer is not None:
            try:
                self._hide_timer.invalidate()
            except Exception:
                pass
            self._hide_timer = None

    def _hideFired_(self, timer):
        self.hide()
