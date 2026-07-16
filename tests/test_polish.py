"""Tests for the polish output sanitizer (no `claude` CLI needed).

The LLM occasionally leaks self-commentary before its final text; the sanitizer
must strip that while never truncating legitimate multi-paragraph output.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import pytest  # noqa: E402

from wisprit.polish import _sanitize, MODES, MODE_LABELS  # noqa: E402


SANITIZE_CASES = [
    # clean single line — unchanged
    ("So I was gonna go to the store.", "So I was gonna go to the store."),
    # meta paragraph then answer paragraph
    ("The store, and grab milk.\n\nWait — that's wrong. Let me give the correct "
     "output:\n\nI was going to the store to grab milk.",
     "I was going to the store to grab milk."),
    # clean paragraph, then inline meta-prefix + answer
    ("The presentation deck is ready.\n\nActually, cleaned directly: Hi Bob, the "
     "deck is ready. When can you meet?",
     "Hi Bob, the deck is ready. When can you meet?"),
    # single-line inline meta prefix
    ("Actually, cleaned directly: Hi Bob, the deck is ready.",
     "Hi Bob, the deck is ready."),
    # legitimate multi-paragraph email — must NOT truncate
    ("Hello,\n\nPlease wait for the report.\n\nThank you.",
     "Hello,\n\nPlease wait for the report.\n\nThank you."),
    # real text with a colon but no meta keyword — must NOT strip
    ("Actually, the meeting is at 3: everyone should attend.",
     "Actually, the meeting is at 3: everyone should attend."),
    # meta header line then answer
    ("Here's the corrected version:\n\nThe final text.", "The final text."),
    # fully-quoted response unwrapped
    ('"just a quoted line"', "just a quoted line"),
    # empty
    ("", ""),
]


@pytest.mark.parametrize("raw,expected", SANITIZE_CASES)
def test_sanitize(raw, expected):
    assert _sanitize(raw) == expected


def test_modes_and_labels_consistent():
    # Every mode must have a menu label, and vice versa.
    assert set(MODES) == set(MODE_LABELS)
    assert "clean" in MODES
