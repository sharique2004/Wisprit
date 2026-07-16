"""TCC permission probes for the three grants Wisprit needs.

- **Accessibility** — required to post the Cmd+V paste event (``insert.py``).
- **Input Monitoring** — required for the listen-only CGEventTap that watches
  the Fn key (``hotkey.py``). Note the research caveat: ``IOHIDCheckAccess`` /
  the preflight can report *denied* while events actually flow (stale TCC
  cache), so the app also treats "events are arriving" as proof of permission.
- **Microphone** — required to capture audio; macOS prompts automatically on
  first capture, but we report the known status in ``doctor``.

All probes are read-only and never prompt, except
:func:`request_accessibility_prompt`, which is invoked explicitly.
"""

from __future__ import annotations

import ctypes
import logging

log = logging.getLogger("wisprit.permissions")


def check_accessibility() -> bool:
    """True if this process is trusted for Accessibility (can post events)."""
    try:
        from ApplicationServices import AXIsProcessTrusted
        return bool(AXIsProcessTrusted())
    except Exception:
        log.exception("AXIsProcessTrusted unavailable")
        return False


def request_accessibility_prompt() -> bool:
    """Trigger the system Accessibility prompt (adds this process to the list).
    Returns the current trusted state."""
    try:
        from ApplicationServices import AXIsProcessTrustedWithOptions
        from Foundation import NSDictionary
        # kAXTrustedCheckOptionPrompt = "AXTrustedCheckOptionPrompt"
        options = NSDictionary.dictionaryWithObject_forKey_(
            True, "AXTrustedCheckOptionPrompt")
        return bool(AXIsProcessTrustedWithOptions(options))
    except Exception:
        log.exception("could not request accessibility prompt")
        return check_accessibility()


def check_input_monitoring() -> str:
    """Return "granted" | "denied" | "undetermined" for Input Monitoring.

    Uses ``IOHIDCheckAccess`` (kIOHIDRequestTypeListenEvent = 1). Per the
    research this can be stale; callers should treat delivered events as proof.
    """
    try:
        iokit = ctypes.CDLL(
            "/System/Library/Frameworks/IOKit.framework/IOKit")
        iokit.IOHIDCheckAccess.restype = ctypes.c_int
        iokit.IOHIDCheckAccess.argtypes = [ctypes.c_uint32]
        # kIOHIDAccessTypeGranted=0, Denied=1, Unknown=2
        result = int(iokit.IOHIDCheckAccess(1))
        return {0: "granted", 1: "denied", 2: "undetermined"}.get(result, "undetermined")
    except Exception:
        log.exception("IOHIDCheckAccess unavailable")
        return "undetermined"


def check_microphone() -> str:
    """Return "granted" | "denied" | "undetermined" | "restricted" for the mic,
    without prompting."""
    try:
        import AVFoundation
        status = AVFoundation.AVCaptureDevice.authorizationStatusForMediaType_(
            AVFoundation.AVMediaTypeAudio)
        # notDetermined=0, restricted=1, denied=2, authorized=3
        return {0: "undetermined", 1: "restricted", 2: "denied", 3: "granted"}.get(
            int(status), "undetermined")
    except Exception:
        log.exception("microphone status unavailable")
        return "undetermined"


def secure_input_active() -> tuple[bool, str | None]:
    """(is_active, best-effort holder name) for Secure Keyboard Entry.

    While active, the event tap system-wide cannot see keys, so the hotkey
    won't fire. We can reliably detect the state; naming the holder is
    best-effort (the API doesn't expose it, so we return None).
    """
    try:
        carbon = ctypes.CDLL("/System/Library/Frameworks/Carbon.framework/Carbon")
        carbon.IsSecureEventInputEnabled.restype = ctypes.c_bool
        return bool(carbon.IsSecureEventInputEnabled()), None
    except Exception:
        log.exception("IsSecureEventInputEnabled unavailable")
        return False, None
