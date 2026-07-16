"""The floating status pill.

A borderless, non-activating ``NSPanel`` that floats above every app (and full-
screen spaces), shows recording state + a live input meter + a rolling preview
of the streaming transcript, and is draggable with its position persisted.
Unlike Wispr Flow's fixed pill, this one can be moved anywhere.

Every public method is expected to be called on the main thread (the session
routes through :func:`wisprit.ui.call_on_main`).
"""

from __future__ import annotations

import logging

from AppKit import (
    NSBezierPath, NSColor, NSFont, NSFontAttributeName,
    NSForegroundColorAttributeName, NSMakeRect, NSPanel, NSScreen,
    NSStatusWindowLevel, NSView, NSWindowCollectionBehaviorCanJoinAllSpaces,
    NSWindowCollectionBehaviorFullScreenAuxiliary,
    NSWindowStyleMaskNonactivatingPanel, NSTimer,
)
from Foundation import NSMakePoint, NSMakeSize, NSObject, NSString
import objc

from wisprit import runtime

log = logging.getLogger("wisprit.pill")

PILL_W, PILL_H = 240.0, 56.0
_BOTTOM_MARGIN = 120.0

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
        self._text = ""
        return self

    def setDot_(self, rgb):
        self._dot = rgb

    def setLevel_(self, level):
        self._level = max(0.0, min(1.0, float(level)))

    def setText_(self, text):
        self._text = text or ""

    def drawRect_(self, rect):
        bounds = self.bounds()
        # Rounded translucent background.
        bg = NSColor.colorWithCalibratedRed_green_blue_alpha_(0.11, 0.12, 0.14, 0.92)
        bg.set()
        path = NSBezierPath.bezierPathWithRoundedRect_xRadius_yRadius_(
            bounds, PILL_H / 2.0, PILL_H / 2.0)
        path.fill()

        # State dot (left).
        r, g, b = self._dot
        NSColor.colorWithCalibratedRed_green_blue_alpha_(r, g, b, 1.0).set()
        dot = NSBezierPath.bezierPathWithOvalInRect_(NSMakeRect(18, PILL_H / 2 - 5, 10, 10))
        dot.fill()

        # Level meter: five bars scaled by the current input level.
        base_x = 40.0
        for i in range(5):
            frac = self._level * (0.5 + i * 0.14)
            h = 6.0 + frac * 22.0
            y = PILL_H / 2 - h / 2
            NSColor.colorWithCalibratedRed_green_blue_alpha_(r, g, b, 0.85).set()
            bar = NSBezierPath.bezierPathWithRoundedRect_xRadius_yRadius_(
                NSMakeRect(base_x + i * 7.0, y, 4.0, h), 2.0, 2.0)
            bar.fill()

        # Rolling transcript / status text (right of the meter).
        if self._text:
            attrs = {
                NSFontAttributeName: NSFont.systemFontOfSize_(12.0),
                NSForegroundColorAttributeName: NSColor.colorWithCalibratedWhite_alpha_(0.92, 1.0),
            }
            ns = NSString.stringWithString_(self._text)
            text_rect = NSMakeRect(84, PILL_H / 2 - 9, PILL_W - 96, 18)
            ns.drawInRect_withAttributes_(text_rect, attrs)


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
    def _show(self, state: str, text: str = ""):
        if self._panel is None or self._hidden():
            return
        self._cancel_hide_timer()
        self._view.setDot_(_COLORS.get(state, (0.6, 0.6, 0.6)))
        self._view.setText_(text)
        self._view.setNeedsDisplay_(True)
        self._panel.orderFrontRegardless()

    @objc.python_method
    def show_recording(self):
        self._show("recording", "Listening…")

    @objc.python_method
    def update_level(self, level):
        if self._panel is None or self._view is None or self._hidden():
            return
        self._view.setLevel_(level)
        self._view.setNeedsDisplay_(True)

    @objc.python_method
    def update_partial(self, text):
        if self._panel is None or self._view is None or self._hidden():
            return
        self._view.setText_(text or "Listening…")
        self._view.setNeedsDisplay_(True)

    @objc.python_method
    def show_finalizing(self):
        self._show("finalizing", "…")

    @objc.python_method
    def flash_success(self):
        self._show("success", "✓")
        self._schedule_hide(1.0)

    @objc.python_method
    def flash_error(self, msg=""):
        self._show("error", msg or "error")
        self._schedule_hide(2.6)

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
