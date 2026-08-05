"""Generate Swift golden literals by running the real wisprit.postprocess.

Run: ~/.meetingscribe/venv/bin/python <this file> > Tests/WispritPostProcessTests/Goldens.swift
"""
import json
import os
import sys
import tempfile

sys.path.insert(0, "/Users/shariquekhatri/Wisprit")

from wisprit.postprocess import process          # noqa: E402
from wisprit.dictionary import Dictionary        # noqa: E402


class FakeSettings:
    def __init__(self, **kw):
        self._d = {
            "filler_removal": True,
            "ensure_sentence_period": False,
            "leading_space": "auto",
        }
        self._d.update(kw)

    def get(self, key):
        return self._d.get(key)


# --- default-option sweep ------------------------------------------------------

DEFAULT_INPUTS = [
    # tests/test_postprocess.py FILLER_CASES
    "um hello world",
    "so um I think uh we should go",
    "uh, let's start",
    "well um yeah",
    "erm okay",
    "this is umm a test",
    "the museum was empty",
    "humble beginnings",
    "ermine fur",
    "a rumble in the distance",
    # UNTOUCHED
    "I like summer",
    "so we can do this",
    "you know the answer already",
    "well, that is interesting",
    "the period at the end of an era",
    "she scratched the surface",
    "a new line of business opened downtown",
    "meet at the dot matrix printer",
    "he said hello",
    "let's talk about the comma splice problem",
    "err on the side of caution",
    "to err is human",
    # EMAIL_CASES
    "sharique dot khatri at gmail dot com",
    "reach me at a dot b dot c at foo dot io",
    "john at gmail dot com",
    "ping me at someone at outlook dot com",
    "email me at john at example dot com",
    "contact support at company dot org",
    # URL_CASES
    "go to example dot com",
    "visit my site at portfolio dot dev",
    "the repo is github dot com",
    "sub dot example dot org",
    "connect the dot puzzle",
    # voice commands
    "first line new line second line",
    "intro new paragraph body",
    "are you coming question mark",
    "watch out exclamation point",
    "that is the end period",
    "stop right there exclamation mark",
    # self-correction
    "meet at three no wait four pm",
    "send it to Bob no wait Alice",
    "the total is ten no wait twelve dollars",
    "call him tomorrow scratch that today",
    "draft the email scratch that write the memo",
    "please wait for me",
    "I can hardly wait",
    "no I disagree",
    # whitespace
    "hello   world",
    "hello , world",
    "wait   .  stop",
    "line one \n line two",
    "  leading and trailing  ",
    # --- extra sweep: fillers -------------------------------------------------
    "um",
    "um um um",
    "UM Hello UH world",
    "Umm, okay then",
    "uhm... right",
    "erm, erm, erm",
    "album umbrella umpire",
    "uh-huh",
    "he said um, and then uh, nothing",
    # --- extra sweep: email/url ----------------------------------------------
    "first dot last at proton dot me",
    "a dot b at c dot d dot com",
    "info at fastmail dot com",
    "Sharique dot Khatri at GMAIL dot COM",
    "reach out at hello at zoho dot com please",
    "the docs live at docs dot python dot org",
    "check news dot ycombinator dot com now",
    "team at acme dot co",
    "my handle at msn dot com",
    "server dot local dot lan",
    "he is at home",
    "x dot y at unknownhost dot xyz",
    "openai dot com and anthropic dot com",
    "grab it from cdn dot example dot net",
    "ship it to ops at gov dot gov",
    # --- extra sweep: voice commands / linebreaks ----------------------------
    "another new line of code",
    "new line hello",
    "hello new line",
    "hello new paragraph",
    "we opened a new paragraph in the doc",
    "the new line that we drew",
    "add one new line and one new paragraph",
    "is this working question mark ",
    "wow exclamation point.",
    "that is all full stop",
    "period",
    "say it question mark now",
    # --- extra sweep: self-correction ----------------------------------------
    "it's three no wait four",
    "meet at three, no wait, four pm",
    "scratch that",
    "first scratch that second scratch that third",
    "go to the the store",
    "we need to to to fix it",
    "I said that that was fine",
    "he had had enough",
    "send it to Bob no wait to Alice",
    # --- extra sweep: whitespace / edges -------------------------------------
    "  ",
    "\n\n\n",
    "a\n\n\n\n\nb",
    "hello\t\tworld",
    "one  ,  two  .  three",
    "trailing space \n",
    "tabs\tand   spaces",
    "hello ; world : again ! yes ?",
    "line one\n   \nline two",
    "MiXeD CaSe StAyS",
    "digits 123 456 stay",
    "unicode café naïve résumé",
    "emoji \U0001f389 stays put",
    # --- extra sweep: combined ------------------------------------------------
    "um so I pushed the fix to production no wait to staging",
    "uh email me at first dot last at gmail dot com question mark",
    "visit example dot com new line then uh call me",
    "um scratch that go to github dot io",
]

OPTION_VARIANTS = [
    ("fillerOff", dict(filler_removal=False), [
        "um hello",
        "um so I think uh we should go",
        "the museum was empty",
        "uh, let's start",
    ]),
    ("ensurePeriod", dict(ensure_sentence_period=True), [
        "this is a sentence",
        "already done!",
        "ends with colon:",
        "are you coming question mark",
        "",
        "um",
        "hello new paragraph world",
    ]),
    ("leadingAlways", dict(leading_space="always"), [
        "appended",
        "  padded",
        "um hello",
        "",
    ]),
    ("leadingNever", dict(leading_space="never"), [
        "appended",
        "  padded",
        "um hello",
        "",
    ]),
    ("leadingAlwaysPeriod", dict(leading_space="always", ensure_sentence_period=True), [
        "chained options here",
    ]),
]

DICT_TERMS = [
    {"term": "InsForge", "hear": ["in forge", "ins forge"]},
    {"term": "Wispr Flow", "hear": ["whisper flow"]},
    {"term": "Claude", "hear": ["clod"]},
    {"term": "PostgreSQL", "hear": ["post grass sequel"]},
]

DICT_INPUTS = [
    "i deployed to in forge today",
    "switching from whisper flow",
    "using insforge here",
    "an old clodhopper",
    "clod said hello",
    "we run post   grass   sequel in prod",
    "um so I pushed the fix to in forge no wait to production",
    "ins forge and in forge and INSFORGE",
    "wispr flow versus whisper flow",
    "email insforge at gmail dot com",
]


def swift_str(s):
    out = []
    for ch in s:
        if ch == "\\":
            out.append("\\\\")
        elif ch == '"':
            out.append('\\"')
        elif ch == "\n":
            out.append("\\n")
        elif ch == "\t":
            out.append("\\t")
        elif ch == "\r":
            out.append("\\r")
        elif ord(ch) < 0x20:
            out.append("\\u{%X}" % ord(ch))
        else:
            out.append(ch)
    return '"' + "".join(out) + '"'


def emit_pairs(name, pairs):
    print(f"    static let {name}: [(raw: String, expected: String)] = [")
    for raw, expected in pairs:
        print(f"        ({swift_str(raw)}, {swift_str(expected)}),")
    print("    ]")
    print()


def main():
    print("// GENERATED — do not hand-edit. Regenerate with:")
    print("//   ~/.meetingscribe/venv/bin/python pp_gen_goldens.py > Tests/WispritPostProcessTests/Goldens.swift")
    print("// Every expectation below is the literal return value of the Python")
    print("// wisprit.postprocess.process() run on this machine.")
    print()
    print("enum Goldens {")

    emit_pairs("defaults", [(t, process(t, FakeSettings())) for t in DEFAULT_INPUTS])

    for name, kw, inputs in OPTION_VARIANTS:
        emit_pairs(name, [(t, process(t, FakeSettings(**kw))) for t in inputs])

    with tempfile.TemporaryDirectory() as td:
        p = os.path.join(td, "dictionary.json")
        with open(p, "w") as fh:
            json.dump({"terms": DICT_TERMS}, fh)
        d = Dictionary(p)
        emit_pairs("dictionary", [(t, process(t, FakeSettings(), d)) for t in DICT_INPUTS])

    print("}")


main()
