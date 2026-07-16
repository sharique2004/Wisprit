"""Insert transcribed text at the current cursor position.

Three paths, chosen in this order:

1. **Secure input active** — some process (password field, Slack's secure
   entry, sudo prompt) holds Secure Keyboard Entry: we never inject anything
   and return ``blocked_secure``. The transcript survives in history and via
   the paste-last hotkey.
2. **Terminal frontmost** (bundle id in ``terminal_bundle_ids``) — typed
   unicode injection via ``CGEventKeyboardSetUnicodeString``, chunked at most
   20 UTF-16 code units per keyDown/keyUp pair, so bracketed-paste and Cmd+V
   quirks in terminals never apply.
3. **Everything else** — clipboard swap: snapshot the pasteboard (all items,
   all types), write the transcript, post Cmd+V, then restore the snapshot
   only if the pasteboard ``changeCount`` proves nobody else touched it.

Event posting requires the Accessibility TCC grant; without it macOS silently
drops posted events, so we check ``AXIsProcessTrusted`` up front and fail with
an actionable error instead of clobbering the clipboard for a paste that can
never land.

Test mode: ``python -m wisprit.insert "some text"`` — 3 second countdown, then
inserts into whatever is focused.
"""

from __future__ import annotations

import ctypes
import logging
import sys
import time
from dataclasses import dataclass

from AppKit import (
    NSPasteboard,
    NSPasteboardItem,
    NSPasteboardTypeString,
    NSWorkspace,
)
import Quartz

from wisprit import runtime

log = logging.getLogger("wisprit.insert")

# Max UTF-16 code units per synthetic typing event (CGEventKeyboardSetUnicodeString).
TYPE_CHUNK_UTF16_UNITS = 20
# Small pause between typed chunks so slow terminals don't drop input.
TYPE_INTER_CHUNK_SLEEP_S = 0.005
# Community convention: well-behaved clipboard managers (Maccy, Paste, …) skip
# any pasteboard write carrying this type, so our transient dictation writes do
# not pollute the user's clipboard history.
NSPASTEBOARD_TRANSIENT_TYPE = "org.nspasteboard.TransientType"
# Fallback restore delay if the configured value is missing/invalid. Restoring
# sooner than the target app reads the pasteboard is the #1 competitor bug
# ("it pasted my old clipboard"), so the floor is generous.
DEFAULT_RESTORE_DELAY_MS = 500


@dataclass
class InsertResult:
    ok: bool
    method: str          # "paste" | "type" | "blocked_secure" | "error"
    detail: str = ""


def frontmost_bundle_id() -> str | None:
    """Bundle identifier of the frontmost app, or None if undeterminable."""
    try:
        app = NSWorkspace.sharedWorkspace().frontmostApplication()
        if app is None:
            return None
        bundle = app.bundleIdentifier()
        return str(bundle) if bundle else None
    except Exception:
        log.exception("frontmost app lookup failed")
        return None


# --- TCC / secure-input probes ------------------------------------------------

_carbon = None


def secure_input_enabled() -> bool:
    """True if any process holds Secure Keyboard Entry (IsSecureEventInputEnabled)."""
    global _carbon
    try:
        if _carbon is None:
            _carbon = ctypes.CDLL("/System/Library/Frameworks/Carbon.framework/Carbon")
            _carbon.IsSecureEventInputEnabled.restype = ctypes.c_bool
        return bool(_carbon.IsSecureEventInputEnabled())
    except Exception:
        log.exception("IsSecureEventInputEnabled unavailable; assuming not secure")
        return False


def accessibility_trusted() -> bool:
    """True if this process may post CGEvents (Accessibility TCC granted).

    If the check itself is unavailable we return True and let the post be
    attempted rather than falsely refusing to insert.
    """
    try:
        from ApplicationServices import AXIsProcessTrusted
        return bool(AXIsProcessTrusted())
    except Exception:
        try:
            lib = ctypes.CDLL(
                "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices"
            )
            lib.AXIsProcessTrusted.restype = ctypes.c_bool
            return bool(lib.AXIsProcessTrusted())
        except Exception:
            log.exception("AXIsProcessTrusted unavailable; attempting post anyway")
            return True


# --- Typed unicode injection (terminals) ---------------------------------------

def _utf16_chunks(text: str, max_units: int):
    """Yield substrings of ≤ max_units UTF-16 code units, never splitting a
    surrogate pair (astral chars like emoji count as 2 units)."""
    chunk: list[str] = []
    units = 0
    for ch in text:
        n = 2 if ord(ch) > 0xFFFF else 1
        if units + n > max_units and chunk:
            yield "".join(chunk)
            chunk, units = [], 0
        chunk.append(ch)
        units += n
    if chunk:
        yield "".join(chunk)


def _type_unicode(text: str):
    """Post keyDown/keyUp pairs carrying the text as a unicode payload."""
    for chunk in _utf16_chunks(text, TYPE_CHUNK_UTF16_UNITS):
        n_units = sum(2 if ord(c) > 0xFFFF else 1 for c in chunk)
        down = Quartz.CGEventCreateKeyboardEvent(None, 0, True)
        Quartz.CGEventKeyboardSetUnicodeString(down, n_units, chunk)
        Quartz.CGEventPost(Quartz.kCGHIDEventTap, down)
        up = Quartz.CGEventCreateKeyboardEvent(None, 0, False)
        Quartz.CGEventKeyboardSetUnicodeString(up, n_units, chunk)
        Quartz.CGEventPost(Quartz.kCGHIDEventTap, up)
        time.sleep(TYPE_INTER_CHUNK_SLEEP_S)


# --- Clipboard swap + Cmd+V -----------------------------------------------------

def _snapshot_pasteboard(pb) -> list[dict]:
    """Best-effort copy of every pasteboard item's data, keyed by type."""
    snapshot: list[dict] = []
    try:
        for item in (pb.pasteboardItems() or []):
            entry = {}
            for type_ in (item.types() or []):
                try:
                    data = item.dataForType_(type_)
                except Exception:
                    continue
                if data is not None:
                    entry[str(type_)] = data
            if entry:
                snapshot.append(entry)
    except Exception:
        log.exception("pasteboard snapshot failed")
    return snapshot


def _restore_pasteboard(pb, snapshot: list[dict]) -> bool:
    """Write a snapshot back. Empty snapshot restores an empty pasteboard."""
    try:
        items = []
        for entry in snapshot:
            item = NSPasteboardItem.alloc().init()
            for type_, data in entry.items():
                item.setData_forType_(data, type_)
            items.append(item)
        pb.clearContents()
        if items:
            return bool(pb.writeObjects_(items))
        return True
    except Exception:
        log.exception("pasteboard restore failed")
        return False


def _post_cmd_v():
    """Post Cmd+V (virtual keycode for V, layout-independent for shortcuts)."""
    down = Quartz.CGEventCreateKeyboardEvent(None, runtime.KVK_ANSI_V, True)
    Quartz.CGEventSetFlags(down, Quartz.kCGEventFlagMaskCommand)
    Quartz.CGEventPost(Quartz.kCGHIDEventTap, down)
    up = Quartz.CGEventCreateKeyboardEvent(None, runtime.KVK_ANSI_V, False)
    Quartz.CGEventSetFlags(up, Quartz.kCGEventFlagMaskCommand)
    Quartz.CGEventPost(Quartz.kCGHIDEventTap, up)


def _paste_via_clipboard(text: str, settings, bundle: str | None) -> InsertResult:
    pb = NSPasteboard.generalPasteboard()
    snapshot = _snapshot_pasteboard(pb)
    pb.clearContents()
    # Declare both the string type and the transient marker so clipboard
    # managers ignore this write, then set the string payload.
    pb.declareTypes_owner_([NSPasteboardTypeString, NSPASTEBOARD_TRANSIENT_TYPE], None)
    if not pb.setString_forType_(text, NSPasteboardTypeString):
        # Nothing was pasted and the old contents are gone; put them back.
        _restore_pasteboard(pb, snapshot)
        return InsertResult(False, "error", "pasteboard write failed")
    our_change_count = pb.changeCount()

    _post_cmd_v()

    delay_ms = settings.get("paste_restore_delay_ms")
    if not isinstance(delay_ms, (int, float)) or delay_ms < 0:
        delay_ms = DEFAULT_RESTORE_DELAY_MS
    time.sleep(delay_ms / 1000.0)

    if pb.changeCount() == our_change_count:
        restored = _restore_pasteboard(pb, snapshot)
        detail = "clipboard restored" if restored else "clipboard restore failed"
    else:
        # Another app (clipboard manager?) mutated the pasteboard meanwhile;
        # restoring now would clobber THEIR write, so we leave it alone.
        detail = "clipboard changed externally; restore skipped"
        log.warning("pasteboard changeCount moved during paste window; not restoring")
    if bundle:
        detail = f"{detail} (target {bundle})"
    return InsertResult(True, "paste", detail)


# --- Public entry point ----------------------------------------------------------

def insert_text(text, settings) -> InsertResult:
    """Insert ``text`` at the cursor of the frontmost app.

    Never raises: every failure comes back as an ``InsertResult`` so the
    session loop can flash the pill and move on. The transcript is expected to
    already be in history before this is called — a failed insert never loses
    words.
    """
    if not text:
        return InsertResult(False, "error", "empty text")

    try:
        if secure_input_enabled():
            return InsertResult(
                False,
                "blocked_secure",
                "Secure Keyboard Entry is active (password field or an app "
                "like Slack holds it); not injecting. Use paste-last once it clears.",
            )

        if not accessibility_trusted():
            return InsertResult(
                False,
                "error",
                "Accessibility permission missing for this process "
                f"({sys.executable}). macOS silently drops posted events without "
                "it. Grant it in System Settings → Privacy & Security → "
                "Accessibility, then retry.",
            )

        bundle = frontmost_bundle_id()
        terminals = settings.get("terminal_bundle_ids") or []
        if bundle and bundle in terminals:
            _type_unicode(text)
            return InsertResult(True, "type", f"typed into {bundle}")
        return _paste_via_clipboard(text, settings, bundle)
    except Exception as exc:
        log.exception("insert_text failed")
        return InsertResult(False, "error", f"{type(exc).__name__}: {exc}")


# --- Standalone test mode ---------------------------------------------------------

def _main(argv: list[str]) -> int:
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")
    text = " ".join(argv) if argv else "Hello from Wisprit insert test."

    from wisprit import settings as settings_mod
    cfg = settings_mod.load()

    bundle = frontmost_bundle_id()
    print(f"frontmost app : {bundle or 'unknown'}")
    print(f"secure input  : {'ACTIVE — insertion will be blocked' if secure_input_enabled() else 'off'}")
    trusted = accessibility_trusted()
    print(f"accessibility : {'granted' if trusted else 'NOT granted — posts would be dropped'}")

    print(f"\nInserting {text!r} into the focused field in:")
    for i in (3, 2, 1):
        print(f"  {i}...")
        time.sleep(1)

    result = insert_text(text, cfg)
    status = "OK" if result.ok else "FAILED"
    print(f"\n{status}: method={result.method}" + (f" — {result.detail}" if result.detail else ""))
    return 0 if result.ok else 1


if __name__ == "__main__":
    raise SystemExit(_main(sys.argv[1:]))
