"""Tiny main-thread dispatch helper.

All AppKit objects (status item, pill panel) must be touched only on the main
thread, but the session state machine, ASR reader, and audio callback all run
on worker threads. Route every UI mutation through :func:`call_on_main`.
"""

from __future__ import annotations

import logging

log = logging.getLogger("wisprit.ui")


def call_on_main(fn, *args) -> None:
    """Run ``fn(*args)`` on the main thread's run loop (non-blocking)."""
    try:
        from AppKit import NSOperationQueue
        NSOperationQueue.mainQueue().addOperationWithBlock_(lambda: _safe(fn, args))
    except Exception:
        # No AppKit run loop (headless test) — run inline as a best effort.
        _safe(fn, args)


def _safe(fn, args) -> None:
    try:
        fn(*args)
    except Exception:
        log.exception("main-thread callback raised")
