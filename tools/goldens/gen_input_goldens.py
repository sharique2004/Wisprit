"""Generate golden fixtures for WispritMacInput by RUNNING the Python it ports.

Two batteries:

1. ``insert._utf16_chunks`` over a set of nasty strings (emoji, ZWJ sequences,
   combining marks, CJK, flags) — pure Python, exact.
2. ``hotkey.HotkeyListener._callback`` driven with synthetic CGEvents. No tap is
   installed and nothing is posted: CGEventCreateKeyboardEvent just allocates an
   event object, and we hand it straight to the callback, which only reads
   fields and enqueues.

Writes a Swift source file (no SPM resource declaration needed).

    ~/.meetingscribe/venv/bin/python gen_input_goldens.py > \
        /Users/shariquekhatri/Wisprit/tests/WispritMacInputTests/GoldenFixtures.swift
"""

import json
import queue
import sys

sys.path.insert(0, "/Users/shariquekhatri/Wisprit")

import Quartz  # noqa: E402

from wisprit import runtime  # noqa: E402
from wisprit.hotkey import HotkeyListener  # noqa: E402
from wisprit.insert import TYPE_CHUNK_UTF16_UNITS, _utf16_chunks  # noqa: E402

# --- 1. chunking --------------------------------------------------------------

CHUNK_CASES = [
    "",
    "hello",
    "a" * 20,
    "a" * 21,
    "a" * 45,
    "The quick brown fox jumps over the lazy dog.",
    "a" * 19 + "\U0001F600",
    "a" * 18 + "\U0001F600\U0001F600",
    "\U0001F600" * 12,
    "a" * 5 + "\U0001F468‍\U0001F469‍\U0001F467‍\U0001F466" + "b" * 5,
    "éclair café 日本語",
    "\U0001F1EF\U0001F1F5" * 6,
    "line one\nline two\ttab",
    "Sharique Khatri — InsForge, MeetingScribe; done.",
]


def chunk_fixtures():
    out = []
    for text in CHUNK_CASES:
        chunks = list(_utf16_chunks(text, TYPE_CHUNK_UTF16_UNITS))
        out.append({"text": text, "chunks": chunks})
    return out


# --- 2. hotkey callback -------------------------------------------------------

FN = runtime.FN_FLAG_MASK
ALT = Quartz.kCGEventFlagMaskAlternate
CMD = Quartz.kCGEventFlagMaskCommand
CTRL = Quartz.kCGEventFlagMaskControl
SHIFT = Quartz.kCGEventFlagMaskShift

FLAGS_CHANGED = Quartz.kCGEventFlagsChanged
KEY_DOWN = Quartz.kCGEventKeyDown
DISABLED_TIMEOUT = Quartz.kCGEventTapDisabledByTimeout
DISABLED_USER = Quartz.kCGEventTapDisabledByUserInput


class FakeSettings:
    def __init__(self, hotkey):
        self._hotkey = hotkey

    def get(self, key):
        return self._hotkey if key == "hotkey" else None


def make_event(type_, keycode, flags):
    ev = Quartz.CGEventCreateKeyboardEvent(None, keycode, True)
    Quartz.CGEventSetType(ev, type_)
    Quartz.CGEventSetFlags(ev, flags)
    assert Quartz.CGEventGetIntegerValueField(ev, Quartz.kCGKeyboardEventKeycode) == keycode
    return ev


# (name, hotkey setting, recording flag, [(type, keycode, flags), ...])
SCENARIOS = [
    ("fn press then release", "fn", False, [
        (FLAGS_CHANGED, 63, FN),
        (FLAGS_CHANGED, 63, 0),
    ]),
    ("fn flag on nav keys never arms", "fn", False, [
        (FLAGS_CHANGED, 126, FN),
        (FLAGS_CHANGED, 123, FN),
        (FLAGS_CHANGED, 63, FN),
        (FLAGS_CHANGED, 63, 0),
    ]),
    ("keycode 63 without fn flag", "fn", False, [
        (FLAGS_CHANGED, 63, CMD),
    ]),
    ("dirty chord cancels and silences release", "fn", False, [
        (FLAGS_CHANGED, 63, FN),
        (KEY_DOWN, 123, FN),
        (FLAGS_CHANGED, 63, 0),
    ]),
    ("second chord key emits nothing", "fn", False, [
        (FLAGS_CHANGED, 63, FN),
        (KEY_DOWN, 123, 0),
        (KEY_DOWN, 124, 0),
    ]),
    ("trigger keycode keydown is not a chord", "fn", False, [
        (FLAGS_CHANGED, 63, FN),
        (KEY_DOWN, 63, FN),
        (FLAGS_CHANGED, 63, 0),
    ]),
    ("esc while not recording", "fn", False, [
        (KEY_DOWN, 53, 0),
    ]),
    ("esc while recording", "fn", True, [
        (KEY_DOWN, 53, 0),
    ]),
    ("esc during hold is a chord", "fn", True, [
        (FLAGS_CHANGED, 63, FN),
        (KEY_DOWN, 53, 0),
    ]),
    ("cmd ctrl v pastes last", "fn", False, [
        (KEY_DOWN, 9, CMD | CTRL),
    ]),
    ("cmd v alone is ignored", "fn", False, [
        (KEY_DOWN, 9, CMD),
        (KEY_DOWN, 9, CTRL),
        (KEY_DOWN, 9, 0),
    ]),
    ("cmd ctrl shift v still pastes", "fn", False, [
        (KEY_DOWN, 9, CMD | CTRL | SHIFT),
    ]),
    ("cmd ctrl v during hold is a chord", "fn", False, [
        (FLAGS_CHANGED, 63, FN),
        (KEY_DOWN, 9, CMD | CTRL),
    ]),
    ("repeat flags while held", "fn", False, [
        (FLAGS_CHANGED, 63, FN),
        (FLAGS_CHANGED, 63, FN | SHIFT),
        (FLAGS_CHANGED, 63, 0),
    ]),
    ("release without press", "fn", False, [
        (FLAGS_CHANGED, 63, 0),
    ]),
    ("tap disabled mid hold", "fn", False, [
        (FLAGS_CHANGED, 63, FN),
        (DISABLED_TIMEOUT, 0, 0),
        (FLAGS_CHANGED, 63, 0),
    ]),
    ("tap disabled by user input mid hold", "fn", False, [
        (FLAGS_CHANGED, 63, FN),
        (DISABLED_USER, 0, 0),
    ]),
    ("tap disabled while idle", "fn", False, [
        (DISABLED_TIMEOUT, 0, 0),
    ]),
    ("tap disabled after chord does not double cancel", "fn", False, [
        (FLAGS_CHANGED, 63, FN),
        (KEY_DOWN, 123, 0),
        (DISABLED_TIMEOUT, 0, 0),
    ]),
    ("right option press release", "right_option", False, [
        (FLAGS_CHANGED, 61, ALT),
        (FLAGS_CHANGED, 61, 0),
    ]),
    ("right option ignores left option keycode", "right_option", False, [
        (FLAGS_CHANGED, 58, ALT),
    ]),
    ("right option masking bug with left option held", "right_option", False, [
        (FLAGS_CHANGED, 58, ALT),
        (FLAGS_CHANGED, 61, ALT),
        (FLAGS_CHANGED, 61, ALT),
        (FLAGS_CHANGED, 61, 0),
    ]),
    ("fn ignores right option events", "fn", False, [
        (FLAGS_CHANGED, 61, ALT),
        (FLAGS_CHANGED, 61, 0),
    ]),
]


def hotkey_fixtures():
    out = []
    for name, hotkey, recording, steps in SCENARIOS:
        q = queue.Queue()
        listener = HotkeyListener(q, FakeSettings(hotkey))
        listener.set_recording(recording)
        emitted = []
        for type_, keycode, flags in steps:
            listener._callback(None, type_, make_event(KEY_DOWN, keycode, flags), None)
            while True:
                try:
                    ev = q.get_nowait()
                except queue.Empty:
                    break
                emitted.append(ev.kind)
        out.append({
            "name": name,
            "hotkey": hotkey,
            "recording": recording,
            "steps": [{"type": t, "keycode": k, "flags": f} for t, k, f in steps],
            "emits": emitted,
        })
    return out


# --- emit Swift ---------------------------------------------------------------

def swift_string(s):
    return json.dumps(s, ensure_ascii=False)


def main():
    chunks = chunk_fixtures()
    hotkeys = hotkey_fixtures()

    print('import Foundation')
    print('@testable import WispritMacInput')
    print()
    print('/// GENERATED — every expectation here was produced by RUNNING the Python')
    print('/// this target ports (`wisprit/insert.py::_utf16_chunks` and')
    print('/// `wisprit/hotkey.py::HotkeyListener._callback`, the latter fed synthetic')
    print('/// CGEvents with no tap installed and nothing posted). Regenerate with:')
    print('///')
    print('///     ~/.meetingscribe/venv/bin/python \\')
    print('///       /private/tmp/claude-501/-Users-shariquekhatri-Wisprit/\\')
    print('///       08bd5841-5936-4964-a20b-5f526dba0b52/scratchpad/gen_input_goldens.py \\')
    print('///       > tests/WispritMacInputTests/GoldenFixtures.swift')
    print('///')
    print('/// Do not hand-edit: a diff here is a real port divergence.')
    print('enum Golden {')
    print()
    print('    struct ChunkCase { let text: String; let chunks: [String] }')
    print()
    print('    /// `_utf16_chunks(text, 20)` from insert.py.')
    print('    static let chunkCases: [ChunkCase] = [')
    for case in chunks:
        chunk_lits = ", ".join(swift_string(c) for c in case["chunks"])
        print(f'        ChunkCase(text: {swift_string(case["text"])}, chunks: [{chunk_lits}]),')
    print('    ]')
    print()
    print('    struct HotkeyCase {')
    print('        let name: String')
    print('        let trigger: TriggerKey')
    print('        let recording: Bool')
    print('        let steps: [TapInput]')
    print('        let emits: [HotkeyEventKind]')
    print('    }')
    print()
    print('    /// Each scenario replayed through the real `HotkeyListener._callback`.')
    print('    static let hotkeyCases: [HotkeyCase] = [')
    for case in hotkeys:
        trigger = ".rightOption" if case["hotkey"] == "right_option" else ".fn"
        steps = []
        for step in case["steps"]:
            t, k, f = step["type"], step["keycode"], step["flags"]
            if t == FLAGS_CHANGED:
                steps.append(f'.flagsChanged(keycode: {k}, flags: {hex(f)})')
            elif t == KEY_DOWN:
                steps.append(f'.keyDown(keycode: {k}, flags: {hex(f)})')
            elif t == DISABLED_TIMEOUT:
                steps.append('.tapDisabled(reason: .timeout)')
            elif t == DISABLED_USER:
                steps.append('.tapDisabled(reason: .userInput)')
            else:
                raise SystemExit(f"unhandled event type {t}")
        kinds = ", ".join(
            {"press": ".press", "release": ".release", "cancel": ".cancel",
             "esc": ".esc", "paste_last": ".pasteLast"}[k]
            for k in case["emits"])
        print(f'        HotkeyCase(name: {swift_string(case["name"])},')
        print(f'                   trigger: {trigger},')
        print(f'                   recording: {str(case["recording"]).lower()},')
        print(f'                   steps: [{", ".join(steps)}],')
        print(f'                   emits: [{kinds}]),')
    print('    ]')
    print('}')


if __name__ == "__main__":
    main()
