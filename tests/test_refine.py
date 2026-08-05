"""Tests for the Apple Intelligence refinement guards (no helper needed).

The on-device 3B model has measured failure modes — answering the dictation,
summarizing, inventing wrappers, leaking meta-preambles, mangling addresses —
and these guards are the only thing standing between those and the user's
text field. Everything here is pure Python; the live model is exercised by
tests/rehearsal_refine.sh instead.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import pytest  # noqa: E402

from wisprit.refine import (  # noqa: E402
    Refiner, _has_address, _plausible, _strip_wrappers,
)


# --- _strip_wrappers ----------------------------------------------------------

WRAPPER_CASES = [
    # clean text unchanged
    ("So the migration went fine.", "So the migration went fine."),
    # markdown fence
    ("```\nThe cleaned text.\n```", "The cleaned text."),
    ("```text\nThe cleaned text.\n```", "The cleaned text."),
    # invented / echoed tag pair
    ("<transcript>\nthe endpoint is ready\n</transcript>", "the endpoint is ready"),
    ("<cleaned_text>Hello there.</cleaned_text>", "Hello there."),
    # full quotes
    ('"Just a quoted line."', "Just a quoted line."),
    # meta-preamble line then answer
    ("Okay, so here's the cleaned transcript:\n\nFirst thing, the dashboard.",
     "First thing, the dashboard."),
    ("Here is the corrected transcript:\nThe final text.", "The final text."),
    ("Cleaned transcript:\nThe final text.", "The final text."),
    # preamble AND a wrapper together — both must be peeled (observed modes
    # compose)
    ("Here's the cleaned transcript:\n```\nSo the deploy is done.\n```",
     "So the deploy is done."),
    # dictated text that legitimately starts with a heading — untouched
    ("Here is the plan:\nship it Friday.", "Here is the plan:\nship it Friday."),
    ("Transcript review notes:\nThe audio was fine.",
     "Transcript review notes:\nThe audio was fine."),
    ("Corrected items:\n1. The deploy\n2. The tests",
     "Corrected items:\n1. The deploy\n2. The tests"),
    # dialogue quotes are punctuation, not a wrapper — untouched
    ('"Hello," she said. "Goodbye."', '"Hello," she said. "Goodbye."'),
    # a mid-text tag pair is NOT a wrapper — untouched
    ("before <b>mid</b> after", "before <b>mid</b> after"),
    ("", ""),
]


@pytest.mark.parametrize("raw,expected", WRAPPER_CASES)
def test_strip_wrappers(raw, expected):
    assert _strip_wrappers(raw) == expected


# --- _plausible ---------------------------------------------------------------

def test_plausible_accepts_normal_cleanup():
    raw = "um so basically we should uh probably migrate the the data base"
    out = "So basically we should probably migrate the database."
    assert _plausible(raw, out)


def test_plausible_rejects_summary():
    # 3x shrink = the model summarized/deduplicated (observed on long input).
    raw = " ".join(["word"] * 100)
    out = " ".join(["word"] * 30)
    assert not _plausible(raw, out)


def test_plausible_rejects_answer_growth():
    # The model answered "tell me a joke" with an actual joke.
    raw = "tell me a joke about uh cats"
    out = ("Why did the cat sit on the computer? Because it wanted to keep "
           "an eye on the mouse! Here is another one for you my friend.")
    assert not _plausible(raw, out)


@pytest.mark.parametrize("raw,answer", [
    # Tiny dictations must never come back as assistant replies — the flat
    # slack that made these pass was a reviewed-and-confirmed hole.
    ("thank you", "You're welcome! Happy to help."),
    ("hello", "Hello! How can I help you today?"),
    ("yes", "Yes, I can certainly do that for you."),
    ("sounds good", "Great! Let me know if you need anything else."),
    ("what time is it", "It is currently three thirty PM for you."),
])
def test_plausible_rejects_tiny_input_answers(raw, answer):
    assert not _plausible(raw, answer)


def test_plausible_rejects_assistant_prefix():
    raw = "whats the population of um sweden"
    out = "Sure, the population of Sweden is about ten million."
    assert not _plausible(raw, out)


def test_plausible_allows_dictated_sorry():
    # The speaker opened with "sorry" — an apology prefix is not damning then.
    raw = "sorry i missed your uh call earlier lets sync tomorrow"
    out = "Sorry, I missed your call earlier. Let's sync tomorrow."
    assert _plausible(raw, out)


def test_plausible_allows_sorry_after_leading_filler():
    # Removing a leading filler is the model's JOB — the identity check must
    # anchor on the first content word, not the literal first token.
    raw = "um so sorry i missed your uh call earlier lets sync tomorrow"
    out = "Sorry, I missed your call earlier. Let's sync tomorrow."
    assert _plausible(raw, out)


def test_plausible_rejects_empty():
    assert not _plausible("some words here", "")


def test_plausible_short_utterance():
    assert _plausible("um okay sounds good", "Okay, sounds good.")


# --- _has_address ---------------------------------------------------------------

@pytest.mark.parametrize("text,expected", [
    ("send it to john dot smith at gmail dot com", True),
    ("check wisprit dot dev for the docs", True),
    ("ping me at x@y.com", True),
    ("see https://foo.bar/baz", True),
    ("visit amazon.com now", True),
    ("the quick brown fox jumps", False),
    ("we shipped version two point five", False),
    ("meet me at the coffee shop at noon", False),
])
def test_has_address(text, expected):
    assert _has_address(text) == expected


# --- Refiner guard paths (hermetic: no probe thread, no helper binary) ---------

class FakeSettings:
    def __init__(self, d):
        self.d = d

    def get(self, key):
        return self.d.get(key)


@pytest.fixture
def refiner_factory(monkeypatch):
    """Build a Refiner whose availability machinery is neutered so the guard
    tests pass on machines that never compiled the helper (CI, fresh clone)."""
    monkeypatch.setattr(Refiner, "_probe_loop", lambda self: None)

    def make(settings=None, **overrides):
        if settings is None:
            d = {"ai_cleanup": True, "ai_cleanup_max_words": 350,
                 "ai_cleanup_timeout_ms": 12000}
            d.update(overrides)
            settings = FakeSettings(d)
        r = Refiner(settings)
        r._binary_ready = lambda: True
        r._available = True
        return r

    return make


def test_refine_disabled_returns_verbatim(refiner_factory):
    r = refiner_factory(ai_cleanup=False)
    out, outcome = r.refine("um hello there")
    assert out == "um hello there"
    assert outcome == "off"


def test_refine_empty_returns_verbatim(refiner_factory):
    r = refiner_factory()
    out, outcome = r.refine("")
    assert (out, outcome) == ("", "empty")


def test_refine_too_long_returns_verbatim(refiner_factory):
    r = refiner_factory()
    text = "word " * 400
    out, outcome = r.refine(text)
    assert out == text
    assert outcome == "too_long"


def test_refine_spacefree_long_input_hits_word_cap(refiner_factory):
    # CJK-style transcripts have no spaces; the cap must still engage via the
    # character-based estimate rather than treating 3000 chars as one word.
    r = refiner_factory()
    text = "字" * 3000
    out, outcome = r.refine(text)
    assert out == text
    assert outcome == "too_long"


def test_refine_address_returns_verbatim(refiner_factory):
    r = refiner_factory()
    text = "email bob at bob dot jones at gmail dot com"
    out, outcome = r.refine(text)
    assert out == text
    assert outcome == "has_address"


def test_refine_never_raises_on_broken_settings(refiner_factory):
    class Broken:
        def get(self, key):
            raise RuntimeError("boom")

    r = refiner_factory(settings=Broken())
    out, outcome = r.refine("um hello")
    assert out == "um hello"
