"""Table-driven tests for the deterministic postprocess pipeline.

Run: ~/.meetingscribe/venv/bin/python -m pytest tests/test_postprocess.py

The suite is heavy on *conservatism* cases (inputs that must pass through
untouched), because over-editing is the exact failure mode Wisprit exists to
avoid.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import pytest  # noqa: E402

from wisprit.postprocess import process  # noqa: E402
from wisprit.dictionary import Dictionary  # noqa: E402


# --- a settings stub so we can flip individual options ------------------------

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


# --- filler removal -----------------------------------------------------------

FILLER_CASES = [
    ("um hello world", "hello world"),
    ("so um I think uh we should go", "so I think we should go"),
    ("uh, let's start", "let's start"),
    ("well um yeah", "well yeah"),
    ("erm okay", "okay"),
    ("this is umm a test", "this is a test"),
    # Conservatism: real words that merely CONTAIN a filler substring survive.
    ("the museum was empty", "the museum was empty"),
    ("humble beginnings", "humble beginnings"),
    ("ermine fur", "ermine fur"),
    ("a rumble in the distance", "a rumble in the distance"),
]


@pytest.mark.parametrize("raw,expected", FILLER_CASES)
def test_filler_removal(raw, expected):
    assert process(raw, FakeSettings()) == expected


def test_filler_removal_disabled():
    assert process("um hello", FakeSettings(filler_removal=False)) == "um hello"


# --- conservatism: these must never change ------------------------------------

UNTOUCHED = [
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
]


@pytest.mark.parametrize("text", UNTOUCHED)
def test_untouched(text):
    # No settings, no dictionary: default pipeline should be a near no-op here.
    assert process(text, FakeSettings()) == text


# --- spoken email -------------------------------------------------------------

EMAIL_CASES = [
    # Local part spelled with dots -> unambiguous email.
    ("sharique dot khatri at gmail dot com",
     "sharique.khatri@gmail.com"),
    ("reach me at a dot b dot c at foo dot io",
     "reach me at a.b.c@foo.io"),
    # Single-token local + known freemail domain -> email.
    ("john at gmail dot com", "john@gmail.com"),
    ("ping me at someone at outlook dot com", "ping me at someone@outlook.com"),
    # Single-token local + non-freemail domain -> "at" is locational; only the
    # domain tail is joined, "at" stays a word (conservative).
    ("email me at john at example dot com", "email me at john at example.com"),
    ("contact support at company dot org", "contact support at company.org"),
]


@pytest.mark.parametrize("raw,expected", EMAIL_CASES)
def test_spoken_email(raw, expected):
    assert process(raw, FakeSettings()) == expected


# --- spoken URL ---------------------------------------------------------------

URL_CASES = [
    ("go to example dot com", "go to example.com"),
    ("visit my site at portfolio dot dev", "visit my site at portfolio.dev"),
    ("the repo is github dot com", "the repo is github.com"),
    ("sub dot example dot org", "sub.example.org"),
]


@pytest.mark.parametrize("raw,expected", URL_CASES)
def test_spoken_url(raw, expected):
    assert process(raw, FakeSettings()) == expected


def test_url_conservative_non_tld():
    # "dot" followed by a non-TLD word is left alone.
    assert process("connect the dot puzzle", FakeSettings()) == "connect the dot puzzle"


# --- voice commands -----------------------------------------------------------

def test_new_line_command():
    assert process("first line new line second line", FakeSettings()) == \
        "first line\nsecond line"


def test_new_paragraph_command():
    assert process("intro new paragraph body", FakeSettings()) == "intro\n\nbody"


TRAILING_PUNCT_CASES = [
    ("are you coming question mark", "are you coming?"),
    ("watch out exclamation point", "watch out!"),
    ("that is the end period", "that is the end."),
    ("stop right there exclamation mark", "stop right there!"),
]


@pytest.mark.parametrize("raw,expected", TRAILING_PUNCT_CASES)
def test_trailing_punctuation(raw, expected):
    assert process(raw, FakeSettings()) == expected


# --- self-correction ----------------------------------------------------------

SELFCORRECT_CASES = [
    ("meet at three no wait four pm", "meet at four pm"),
    ("send it to Bob no wait Alice", "send it to Alice"),
    ("the total is ten no wait twelve dollars", "the total is twelve dollars"),
    ("call him tomorrow scratch that today", "today"),
    ("draft the email scratch that write the memo", "write the memo"),
]


@pytest.mark.parametrize("raw,expected", SELFCORRECT_CASES)
def test_self_correction(raw, expected):
    assert process(raw, FakeSettings()) == expected


SELFCORRECT_AMBIGUOUS = [
    # "wait" without "no" is not a correction marker.
    ("please wait for me", "please wait for me"),
    ("I can hardly wait", "I can hardly wait"),
    # "no" alone is not a marker.
    ("no I disagree", "no I disagree"),
]


@pytest.mark.parametrize("text", SELFCORRECT_AMBIGUOUS)
def test_self_correction_conservative(text):
    assert process(text, FakeSettings()) == text


# --- whitespace / punctuation spacing -----------------------------------------

WHITESPACE_CASES = [
    ("hello   world", "hello world"),
    ("hello , world", "hello, world"),
    ("wait   .  stop", "wait. stop"),
    ("line one \n line two", "line one\nline two"),
    ("  leading and trailing  ", "leading and trailing"),
]


@pytest.mark.parametrize("raw,expected", WHITESPACE_CASES)
def test_whitespace(raw, expected):
    assert process(raw, FakeSettings()) == expected


# --- options ------------------------------------------------------------------

def test_ensure_period_adds_period():
    assert process("this is a sentence", FakeSettings(ensure_sentence_period=True)) == \
        "this is a sentence."


def test_ensure_period_no_double():
    assert process("already done!", FakeSettings(ensure_sentence_period=True)) == \
        "already done!"


def test_leading_space_always():
    assert process("appended", FakeSettings(leading_space="always")) == " appended"


def test_leading_space_never():
    # Even if input had leading space, "never" strips it.
    assert process("  padded", FakeSettings(leading_space="never")) == "padded"


def test_empty_and_none():
    assert process("", FakeSettings()) == ""
    assert process(None, FakeSettings()) == ""


def test_no_settings_no_dictionary():
    # process() must work with everything omitted.
    assert process("um hello world") == "hello world"


# --- dictionary integration ---------------------------------------------------

def _dict(tmp_path, terms):
    import json
    p = tmp_path / "dictionary.json"
    p.write_text(json.dumps({"terms": terms}))
    return Dictionary(p)


def test_dictionary_corrections(tmp_path):
    d = _dict(tmp_path, [
        {"term": "InsForge", "hear": ["in forge", "ins forge"]},
        {"term": "Wispr Flow", "hear": ["whisper flow"]},
    ])
    assert process("i deployed to in forge today", FakeSettings(), d) == \
        "i deployed to InsForge today"
    assert process("switching from whisper flow", FakeSettings(), d) == \
        "switching from Wispr Flow"


def test_dictionary_self_casing(tmp_path):
    d = _dict(tmp_path, [{"term": "InsForge", "hear": []}])
    # Even without a "hear" entry, wrong casing of the term is corrected.
    assert process("using insforge here", FakeSettings(), d) == "using InsForge here"


def test_dictionary_does_not_overreach(tmp_path):
    d = _dict(tmp_path, [{"term": "Claude", "hear": ["clod"]}])
    # Word-boundary: "clodhopper" must not become "Claudehopper".
    assert process("an old clodhopper", FakeSettings(), d) == "an old clodhopper"


def test_dictionary_hot_reload(tmp_path):
    import json
    p = tmp_path / "dictionary.json"
    p.write_text(json.dumps({"terms": []}))
    d = Dictionary(p)
    assert process("hello foobar", FakeSettings(), d) == "hello foobar"
    # Rewrite with a mtime bump.
    os.utime(p, None)
    p.write_text(json.dumps({"terms": [{"term": "FooBar", "hear": ["foobar"]}]}))
    # Force a distinct mtime so maybe_reload notices even on coarse clocks.
    os.utime(p, (os.stat(p).st_atime + 2, os.stat(p).st_mtime + 2))
    assert d.maybe_reload() is True
    assert process("hello foobar", FakeSettings(), d) == "hello FooBar"


# --- combined realistic utterance ---------------------------------------------

def test_combined(tmp_path):
    d = _dict(tmp_path, [{"term": "InsForge", "hear": ["in forge"]}])
    raw = "um so I pushed the fix to in forge no wait to production"
    assert process(raw, FakeSettings(), d) == "so I pushed the fix to production"
