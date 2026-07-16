"""Verbatim-first Tier-1 cleanup: deterministic, fast (<20 ms), no LLM.

This is the whole post-ASR pipeline for the MVP. The guiding principle —
answering Wispr Flow's most common complaint that it *rewrites what you said* —
is **conservatism**: only touch text when the intent is unambiguous. Anything
uncertain passes through verbatim. LLM polish is a separate, opt-in tier
(:mod:`wisprit.polish`), never on the insertion path.

Pipeline order (each stage is independent and defensively wrapped):

1. Filler removal — isolated ``um/uh/uhh/erm/uhm`` tokens only (config-gated).
2. Dictionary corrections — canonical-vocabulary substitutions.
3. Spoken email + URL joining — ``a dot b at c dot com`` → ``a.b@c.com``.
4. Voice commands — ``new line`` / ``new paragraph`` and trailing punctuation
   words (``period``, ``question mark`` …).
5. Explicit self-correction — ``X no wait Y`` / ``… scratch that Y`` → keep Y.
6. Whitespace / punctuation spacing cleanup.
7. Optional trailing period + configured leading-space policy.

Deliberately **not** done: converting spelled-out numbers to digits. That is
exactly the kind of surprising edit ("one more" → "1 more") that erodes trust,
so it is left to a future opt-in setting.
"""

from __future__ import annotations

import logging
import re

log = logging.getLogger("wisprit.postprocess")

# Fillers removed only as isolated, word-bounded tokens. Deliberately excludes
# "like", "so", "well", "you know" — removing those context-free mangles meaning.
_FILLER_WORDS = ["um", "umm", "uh", "uhh", "uhm", "erm", "err"]
_FILLER_RE = re.compile(
    r"(?<!\w)(?:" + "|".join(_FILLER_WORDS) + r")(?!\w)[,]?",
    re.IGNORECASE,
)

# Known TLDs for spoken-URL joining. Conservative list — real, common TLDs.
_TLDS = ["com", "org", "net", "io", "ai", "dev", "co", "edu", "gov", "app", "me"]
_TLD_ALT = "|".join(_TLDS)

# Second-level domains where "<name> at <sld> dot <tld>" is almost certainly an
# email (freemail providers). For any other domain we require the local part to
# be explicitly dotted before turning "at" into "@" — otherwise "at" usually
# means "located at" ("visit my site at foo dot dev"), and we must not guess.
_FREEMAIL = {
    "gmail", "googlemail", "yahoo", "ymail", "outlook", "hotmail", "live",
    "icloud", "me", "mac", "proton", "protonmail", "aol", "gmx", "zoho",
    "fastmail", "yandex", "msn", "pm",
}

# "<local> at <domain> dot <tld>" where each part may contain " dot " joiners.
_EMAIL_RE = re.compile(
    r"\b([a-z0-9]+(?:\s+dot\s+[a-z0-9]+)*)\s+at\s+"
    r"([a-z0-9]+(?:\s+dot\s+[a-z0-9]+)*\s+dot\s+(?:" + _TLD_ALT + r"))\b",
    re.IGNORECASE,
)

# "<host> dot <tld>", possibly chained ("sub dot example dot com").
_URL_RE = re.compile(
    r"\b([a-z0-9]+(?:\s+dot\s+[a-z0-9]+)*)\s+dot\s+(" + _TLD_ALT + r")\b",
    re.IGNORECASE,
)

# Line-break voice commands. "new line"/"new paragraph" is dangerously common as
# ordinary speech ("a new line of business"), so we only treat it as a command
# when it is NOT part of a noun phrase — i.e. not preceded by a determiner and
# not followed by a word that continues the phrase grammatically.
_LINEBREAK_RE = re.compile(
    r"(?:(\w+)\s+)?new\s+(line|paragraph)\b(?:\s+(\w+))?", re.IGNORECASE
)
_DETERMINERS = {
    "a", "an", "the", "this", "that", "another", "each", "every", "one",
    "my", "your", "our", "his", "her", "their", "its", "some", "any", "no",
}
_CONTINUATIONS = {
    "of", "in", "on", "at", "to", "for", "with", "from", "by", "and", "or",
    "that", "which", "is", "was", "are", "were", "between", "through", "than",
}

# Trailing spoken punctuation ("... question mark" at the very end).
_TRAILING_PUNCT = [
    (re.compile(r"\s+(?:question\s+mark)[.\s]*$", re.IGNORECASE), "?"),
    (re.compile(r"\s+(?:exclamation\s+(?:point|mark))[.\s]*$", re.IGNORECASE), "!"),
    (re.compile(r"\s+period[.\s]*$", re.IGNORECASE), "."),
    (re.compile(r"\s+(?:full\s+stop)[.\s]*$", re.IGNORECASE), "."),
]

# Self-correction: drop the single word before "no wait" (+ the marker).
_NO_WAIT_RE = re.compile(r"\b[\w']+[,]?\s+no\s+wait[,]?\s+", re.IGNORECASE)
# "scratch that" — keep only what follows the LAST occurrence (greedy).
_SCRATCH_RE = re.compile(r"^.*\bscratch\s+that\b[,.]?\s*", re.IGNORECASE | re.DOTALL)
# Collapse an immediate duplicate of a function word, which self-correction can
# leave behind ("... to InsForge no wait to production" -> "... to to ...").
# Restricted to words whose consecutive repetition is virtually always an
# artifact — "that"/"had" are excluded because "that that"/"had had" are valid.
_DUP_RE = re.compile(
    r"\b(to|the|a|an|of|in|on|at|and|or|for|with|is|was|it|i)\s+\1\b",
    re.IGNORECASE,
)

# Space before sentence punctuation; multiple spaces.
_SPACE_BEFORE_PUNCT_RE = re.compile(r"\s+([,.;:!?])")
_MULTISPACE_RE = re.compile(r"[ \t]{2,}")
_SPACE_AROUND_NEWLINE_RE = re.compile(r"[ \t]*\n[ \t]*")


def _remove_fillers(text: str) -> str:
    return _FILLER_RE.sub("", text)


def _apply_dictionary(text: str, dictionary) -> str:
    if dictionary is None:
        return text
    try:
        for pattern, replacement in dictionary.corrections():
            text = pattern.sub(lambda m, r=replacement: r, text)
    except Exception:
        log.exception("dictionary correction failed; leaving text unchanged")
    return text


def _join_dotted(phrase: str) -> str:
    """Turn 'a dot b dot c' into 'a.b.c'."""
    parts = re.split(r"\s+dot\s+", phrase, flags=re.IGNORECASE)
    return ".".join(p.strip() for p in parts if p.strip())


def _join_email(text: str) -> str:
    def repl(m: re.Match) -> str:
        local_raw, domain_raw = m.group(1), m.group(2)
        sld = re.split(r"\s+dot\s+", domain_raw, flags=re.IGNORECASE)[0].strip().lower()
        local_is_dotted = bool(re.search(r"\s+dot\s+", local_raw, re.IGNORECASE))
        # Only turn "at" into "@" when we are confident it is an address:
        # either the local part was spelled with dots, or the domain is a known
        # freemail provider. Otherwise "at" is left alone (the URL pass still
        # joins the "<domain> dot <tld>" tail).
        if not (local_is_dotted or sld in _FREEMAIL):
            return m.group(0)
        return f"{_join_dotted(local_raw)}@{_join_dotted(domain_raw)}"
    return _EMAIL_RE.sub(repl, text)


def _join_url(text: str) -> str:
    def repl(m: re.Match) -> str:
        host = _join_dotted(m.group(1))
        return f"{host}.{m.group(2).lower()}"
    return _URL_RE.sub(repl, text)


def _apply_linebreaks(text: str) -> str:
    def repl(m: re.Match) -> str:
        prev, kind, nxt = m.group(1), m.group(2).lower(), m.group(3)
        # Noun-phrase guards: "a new line of ...", "the new paragraph that ...".
        if prev and prev.lower() in _DETERMINERS:
            return m.group(0)
        if nxt and nxt.lower() in _CONTINUATIONS:
            return m.group(0)
        brk = "\n\n" if kind == "paragraph" else "\n"
        return f"{prev + ' ' if prev else ''}{brk}{' ' + nxt if nxt else ''}"
    return _LINEBREAK_RE.sub(repl, text)


def _voice_commands(text: str) -> str:
    text = _apply_linebreaks(text)
    for pattern, punct in _TRAILING_PUNCT:
        text = pattern.sub(punct, text)
    return text


def _self_correct(text: str) -> str:
    text = _NO_WAIT_RE.sub("", text)
    if re.search(r"\bscratch\s+that\b", text, re.IGNORECASE):
        text = _SCRATCH_RE.sub("", text)
    # Repeat until stable so "to to to" fully collapses.
    while True:
        collapsed = _DUP_RE.sub(r"\1", text)
        if collapsed == text:
            break
        text = collapsed
    return text


def _cleanup_whitespace(text: str) -> str:
    text = _SPACE_AROUND_NEWLINE_RE.sub("\n", text)
    text = _SPACE_BEFORE_PUNCT_RE.sub(r"\1", text)
    text = _MULTISPACE_RE.sub(" ", text)
    # Collapse 3+ newlines to a paragraph break.
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text.strip()


def _apply_leading_space(text: str, policy: str) -> str:
    if not text:
        return text
    if policy == "always":
        return text if text.startswith((" ", "\n")) else " " + text
    if policy == "never":
        return text.lstrip(" ")
    return text  # "auto" — leave as produced (already stripped)


def process(text: str, settings=None, dictionary=None) -> str:
    """Run the full deterministic cleanup pipeline.

    ``settings`` and ``dictionary`` are optional so the function is trivially
    unit-testable; when omitted, filler removal is on, no dictionary
    corrections are applied, no trailing period is forced, and leading space is
    "auto". Never raises.
    """
    if not text:
        return ""

    def _get(key, default):
        if settings is None:
            return default
        try:
            value = settings.get(key)
        except Exception:
            return default
        return default if value is None else value

    filler_removal = bool(_get("filler_removal", True))
    ensure_period = bool(_get("ensure_sentence_period", False))
    leading_space = _get("leading_space", "auto")

    try:
        if filler_removal:
            text = _remove_fillers(text)
        text = _apply_dictionary(text, dictionary)
        text = _join_email(text)
        text = _join_url(text)
        text = _voice_commands(text)
        text = _self_correct(text)
        text = _cleanup_whitespace(text)
        if ensure_period and text and text[-1] not in ".!?:\n":
            text = text + "."
        text = _apply_leading_space(text, leading_space)
    except Exception:
        log.exception("postprocess failed; returning best-effort text")
    return text
