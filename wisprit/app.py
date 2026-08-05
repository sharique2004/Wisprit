"""Wisprit menu-bar app: wires every component and runs the AppKit loop.

Layout of responsibilities:

- main thread: NSApplication run loop, the status-bar item + menu, and the
  CGEventTap (its run-loop source lives on this loop).
- session thread: the state machine (started here, runs on its own thread).
- audio/ASR threads: spawned lazily per utterance by the session.

Run: ``~/.meetingscribe/venv/bin/python -m wisprit``
"""

from __future__ import annotations

import fcntl
import logging
import queue
import subprocess
import threading

from AppKit import (
    NSApplication, NSApplicationActivationPolicyAccessory, NSMenu, NSMenuItem,
    NSPasteboard, NSPasteboardTypeString, NSStatusBar, NSVariableStatusItemLength,
)
from Foundation import NSObject
import objc

from wisprit import bootstrap, doctor, polish, runtime
from wisprit.audio import AudioCapture
from wisprit.dictionary import Dictionary
from wisprit.history import History
from wisprit.hotkey import HotkeyListener
from wisprit.insert import insert_text
from wisprit.asr import AsrManager
from wisprit.refine import Refiner
from wisprit.session import Session
from wisprit import settings as settings_mod

log = logging.getLogger("wisprit.app")

_STATE_GLYPH = {
    "idle": "🎙", "recording": "🔴", "finalizing": "…",
    "inserting": "⌨", }


class WispritApp(NSObject):
    def initWithComponents_(self, components):
        self = objc.super(WispritApp, self).init()
        if self is None:
            return None
        (self._settings, self._dictionary, self._history, self._session,
         self._hotkey, self._pill, self._refiner) = components
        self._status_item = None
        self._menu = None
        self._build_menu()
        return self

    # --- menu construction ----------------------------------------------------

    @objc.python_method
    def _build_menu(self):
        bar = NSStatusBar.systemStatusBar()
        self._status_item = bar.statusItemWithLength_(NSVariableStatusItemLength)
        self._status_item.button().setTitle_(_STATE_GLYPH["idle"])

        menu = NSMenu.alloc().init()
        menu.setDelegate_(self)         # rebuild dynamic items on open
        menu.setAutoenablesItems_(False)
        self._menu = menu
        self._status_item.setMenu_(menu)
        self._rebuild_menu()

    @objc.python_method
    def _rebuild_menu(self):
        menu = self._menu
        menu.removeAllItems()

        enabled = bool(self._settings.get("enabled"))
        item = self._add(menu, f"Dictation {'On' if enabled else 'Off'}",
                         b"toggleEnabled:")
        item.setState_(1 if enabled else 0)

        # Apple Intelligence on-path cleanup. availability None means the
        # probe hasn't finished (or the helper is still compiling) — show the
        # toggle; refinement self-disables until it is actually usable.
        if self._refiner is not None and self._refiner.availability is False:
            item = self._add(menu, "AI Cleanup unavailable — run Doctor", None)
            item.setEnabled_(False)
        else:
            ai_on = bool(self._settings.get("ai_cleanup"))
            item = self._add(menu, "AI Cleanup (Apple Intelligence)",
                             b"toggleAiCleanup:")
            item.setState_(1 if ai_on else 0)

        menu.addItem_(NSMenuItem.separatorItem())

        header = self._add(menu, "Recent transcripts", None)
        header.setEnabled_(False)
        recents = []
        try:
            recents = self._history.last(5)
        except Exception:
            log.exception("history read failed")
        if not recents:
            self._add(menu, "  (none yet)", None).setEnabled_(False)
        for row in recents:
            preview = (row.get("text") or "").replace("\n", " ")
            if len(preview) > 48:
                preview = preview[:47] + "…"
            mi = self._add(menu, "  " + preview, b"copyRecent:")
            mi.setRepresentedObject_(row.get("text") or "")

        menu.addItem_(NSMenuItem.separatorItem())
        self._add(menu, "Paste Last Transcript  (⌘⌃V)", b"pasteLast:")
        self._add_polish_submenu(menu)
        self._add(menu, "Open Dictionary…", b"openDictionary:")
        self._add(menu, "Open Config…", b"openConfig:")
        self._add(menu, "Run Doctor…", b"runDoctor:")
        self._add(menu, "Purge History", b"purgeHistory:")
        menu.addItem_(NSMenuItem.separatorItem())
        self._add(menu, "Quit Wisprit", b"quit:")

    @objc.python_method
    def _add(self, menu, title, selector):
        item = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
            title, selector, "")
        if selector is not None:
            item.setTarget_(self)
        menu.addItem_(item)
        return item

    @objc.python_method
    def _add_polish_submenu(self, menu):
        parent = self._add(menu, "Polish Last with Claude", None)
        if not polish.available():
            parent.setEnabled_(False)
            parent.setTitle_("Polish Last (claude CLI not found)")
            return
        submenu = NSMenu.alloc().init()
        submenu.setAutoenablesItems_(False)
        for mode in ("clean", "formal", "casual", "prompt"):
            item = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
                polish.MODE_LABELS[mode], b"polishLast:", "")
            item.setTarget_(self)
            item.setRepresentedObject_(mode)
            submenu.addItem_(item)
        parent.setSubmenu_(submenu)

    # NSMenuDelegate — refresh recents/enabled state each time the menu opens.
    def menuNeedsUpdate_(self, menu):
        self._rebuild_menu()

    # --- state glyph ----------------------------------------------------------

    @objc.python_method
    def update_state(self, state):
        if self._status_item is not None:
            self._status_item.button().setTitle_(_STATE_GLYPH.get(state, "🎙"))

    # --- actions (Objective-C selectors) --------------------------------------

    def toggleEnabled_(self, sender):
        self._settings.set("enabled", not bool(self._settings.get("enabled")))
        self._rebuild_menu()

    def toggleAiCleanup_(self, sender):
        self._settings.set("ai_cleanup",
                           not bool(self._settings.get("ai_cleanup")))
        self._rebuild_menu()

    def copyRecent_(self, sender):
        text = sender.representedObject()
        if text:
            pb = NSPasteboard.generalPasteboard()
            pb.clearContents()
            pb.setString_forType_(text, NSPasteboardTypeString)

    def pasteLast_(self, sender):
        # Enqueue onto the session thread so the clipboard swap stays serialized
        # with any in-flight dictation (never two paste transactions at once).
        self._session.request_paste_last()

    def polishLast_(self, sender):
        mode = sender.representedObject() or "clean"
        # The claude call takes seconds — run it off the main thread, then land
        # the result on the clipboard from the main thread.
        threading.Thread(target=self._do_polish, args=(mode,), daemon=True,
                         name="polish").start()

    @objc.python_method
    def _do_polish(self, mode):
        text = None
        try:
            text = self._history.last_text()
        except Exception:
            log.exception("polish: could not read last transcript")
        if not text:
            self._notify("Wisprit", "No transcript to polish yet.")
            return
        ok, result = polish.polish(text, mode)
        if not ok:
            self._notify("Wisprit — polish failed", result)
            return

        def land():
            pb = NSPasteboard.generalPasteboard()
            pb.clearContents()
            pb.setString_forType_(result, NSPasteboardTypeString)
        from wisprit import ui
        ui.call_on_main(land)
        preview = result.replace("\n", " ")
        if len(preview) > 60:
            preview = preview[:59] + "…"
        self._notify(f"Polished ({polish.MODE_LABELS.get(mode, mode)}) — ⌘V to paste",
                     preview)

    @objc.python_method
    def _notify(self, title, message):
        # Best-effort user notification; never let it break the caller.
        try:
            safe_t = title.replace('"', "'")
            safe_m = (message or "").replace('"', "'")
            subprocess.Popen([
                "osascript", "-e",
                f'display notification "{safe_m}" with title "{safe_t}"',
            ])
        except Exception:
            log.exception("notification failed")

    def openDictionary_(self, sender):
        subprocess.Popen(["open", str(runtime.DICTIONARY_PATH)])

    def openConfig_(self, sender):
        subprocess.Popen(["open", str(runtime.CONFIG_PATH)])

    def runDoctor_(self, sender):
        # Open a Terminal window running the doctor so the user can read it.
        py = runtime.VENV_PYTHON
        cmd = f'{py} -m wisprit doctor; echo; read -n1 -r -p "Press any key to close…"'
        subprocess.Popen([
            "osascript", "-e",
            f'tell application "Terminal" to do script "{cmd}"',
            "-e", 'tell application "Terminal" to activate',
        ])

    def purgeHistory_(self, sender):
        try:
            self._history.purge()
        except Exception:
            log.exception("purge failed")
        self._rebuild_menu()

    def quit_(self, sender):
        try:
            self._session.stop()
            self._hotkey.uninstall()
        except Exception:
            log.exception("shutdown error")
        NSApplication.sharedApplication().terminate_(self)


# Held open for the whole process lifetime so the flock persists; released
# automatically when the process exits.
_lock_fd = None


def _acquire_single_instance() -> bool:
    """True if we got the lock; False if another Wisprit is already running.

    Two instances would each install an event tap and each paste on every
    Fn-release — the double-paste bug. This makes a second launch a no-op.
    """
    global _lock_fd
    try:
        runtime.STATE_DIR.mkdir(parents=True, exist_ok=True)
        fd = open(runtime.STATE_DIR / "wisprit.lock", "w")
        fcntl.flock(fd.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        _lock_fd = fd
        return True
    except OSError:
        return False


def _configure_logging():
    try:
        runtime.STATE_DIR.mkdir(parents=True, exist_ok=True)
        logging.basicConfig(
            level=logging.INFO,
            format="%(asctime)s %(levelname)s %(name)s: %(message)s",
            handlers=[logging.FileHandler(runtime.LOG_PATH), logging.StreamHandler()],
        )
    except Exception:
        logging.basicConfig(level=logging.INFO)


def main() -> int:
    _configure_logging()
    if not _acquire_single_instance():
        log.error("Another Wisprit instance is already running — exiting so we "
                  "don't double-paste. Quit the other one from its menu first.")
        try:
            subprocess.Popen([
                "osascript", "-e",
                'display notification "Another copy is already running." '
                'with title "Wisprit"'])
        except Exception:
            pass
        return 0
    try:
        bootstrap.ensure_state_dir()
    except OSError:
        log.exception("could not create state dir %s", runtime.STATE_DIR)

    cfg = settings_mod.load()
    dictionary = Dictionary()
    history = History(settings=cfg)
    asr = AsrManager(cfg, dictionary)
    refiner = Refiner(cfg)

    # Slow provisioning off the startup path: compile/refresh the Apple
    # Intelligence helper (~5–15 s with swiftc on first run; a no-op when
    # current) and prefetch the CPU-fallback Whisper model, which the
    # dictation path itself is forbidden from downloading.
    def _provision():
        bootstrap.ensure_refine_helper()
        bootstrap.prefetch_fallback_model()

    threading.Thread(target=_provision, daemon=True, name="provision").start()

    events: queue.Queue = queue.Queue()
    hotkey = HotkeyListener(events, cfg)
    audio = AudioCapture(on_chunk=asr.feed)

    app = NSApplication.sharedApplication()
    app.setActivationPolicy_(NSApplicationActivationPolicyAccessory)

    from wisprit.pill import Pill
    pill = Pill.alloc().initWithSettings_(cfg)

    controller_holder = {}

    def on_state(state):
        ctrl = controller_holder.get("c")
        if ctrl is not None:
            ctrl.update_state(state)

    session = Session(events, cfg, dictionary, history, asr, hotkey, audio,
                      pill=pill, on_state=on_state, refiner=refiner)

    controller = WispritApp.alloc().initWithComponents_(
        (cfg, dictionary, history, session, hotkey, pill, refiner))
    controller_holder["c"] = controller
    app.setDelegate_(controller)

    if not hotkey.install():
        log.error("Hotkey tap failed to install — grant Input Monitoring & "
                  "Accessibility to %s, then relaunch. Run `wisprit doctor`.",
                  runtime.VENV_PYTHON)
        # Keep running so the menu bar can show and the user can open doctor.

    # Even when the tap "installs", it stays inert until Input Monitoring is
    # granted, and paste needs Accessibility, and capture needs Microphone —
    # all three are per-identity, so a new launcher (e.g. Wisprit.app) must be
    # granted them even if the python binary already was. Surface that on first
    # launch and proactively raise the mic prompt.
    from wisprit import permissions
    try:
        # Triggers the microphone prompt for THIS identity if undetermined.
        from AVFoundation import AVCaptureDevice, AVMediaTypeAudio
        AVCaptureDevice.requestAccessForMediaType_completionHandler_(
            AVMediaTypeAudio, lambda granted: None)
    except Exception:
        log.exception("could not request microphone access")

    missing = []
    if not permissions.check_accessibility():
        missing.append("Accessibility")
    if permissions.check_input_monitoring() != "granted":
        missing.append("Input Monitoring")
    if permissions.check_microphone() == "denied":
        missing.append("Microphone")
    if missing:
        log.warning("Permissions incomplete (%s) — dictation won't work until "
                    "these are granted to this app in System Settings ▸ Privacy "
                    "& Security. Run `wisprit doctor` for the checklist.",
                    ", ".join(missing))
        try:
            permissions.request_accessibility_prompt()
        except Exception:
            log.exception("could not raise the accessibility prompt")

    session.start()
    log.info("Wisprit ready — hold %s to dictate.", cfg.get("hotkey"))
    app.run()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
