"""On-path Apple Intelligence transcript refinement.

Drives the compiled ``wisprit_refine`` helper (packaging/wisprit_refine.swift),
which runs the on-device Foundation Models LLM (macOS 26+, Apple Silicon,
Apple Intelligence enabled). The helper is spawned when recording STARTS so
the model prewarms while the user is still speaking; at finalize the raw
transcript is piped in and the cleaned text read back.

Placement in the pipeline: ASR → **refine** → deterministic postprocess →
insert. The deterministic stage still runs afterwards, so dictionary
corrections (personal vocabulary the ~3B model provably ignores when hinted —
measured, see docs/notes), voice commands, and email/URL joining all keep
working, and any refinement failure simply degrades to today's behavior.

Trust rules (the model is small and occasionally answers/summarizes instead
of cleaning — all observed in testing):

- output stripped of leaked meta-preambles ("here's the cleaned transcript:")
  and invented wrappers (fences, echoed tags, full quoting);
- output must be plausibly the same utterance: word count within
  [40%, 120% + slack] of the input — slack shrinks to 2 words for tiny
  inputs, where "answering instead of cleaning" is likeliest;
- any error, timeout, or crash keeps the verbatim text. Refinement can only
  ever *win* — it must never lose words or block insertion.

The refine call polls the helper instead of blocking, so the session can
interrupt it: Esc aborts the utterance within ~100 ms, and a new fn-press
finishes immediately with the verbatim text so the next dictation isn't
delayed behind the model.
"""

from __future__ import annotations

import json
import logging
import re
import subprocess
import threading
import time

from wisprit import postprocess, runtime

log = logging.getLogger("wisprit.refine")

# Measured on M4 (macOS 26.5): ~20 ms per output word + ~0.5 s fixed. The
# timeout is ~2× the expectation so a healthy run never trips it.
_TIMEOUT_BASE_S = 3.0
_TIMEOUT_PER_WORD_S = 0.045

# How often the poll loop wakes to check the helper and the interrupt.
_POLL_S = 0.05

# A leaked meta-preamble line before the real output. Deliberately shaped like
# the model narrating ("here's the cleaned transcript:", "Corrected text:") —
# a bare keyword is NOT enough, so dictated headings like "Transcript review
# notes:" or "Here is the plan:" survive.
_PREAMBLE_RE = re.compile(
    r"^(?:[^\n]{0,40}\bhere(?:'s| is)\b[^\n]{0,40}\b(?:transcript|text|version|output)\b[^\n]{0,20}"
    r"|[^\n]{0,40}\b(?:cleaned|corrected)\s+(?:transcript|text|version|output)\b[^\n]{0,20})"
    r":\s*\n+",
    re.IGNORECASE,
)

# Invented wrappers the small model sometimes adds despite instructions
# (widely reported): markdown fences, a single XML-ish tag pair, full quotes.
_FENCE_RE = re.compile(r"^```[a-z]*\n(.*?)\n?```$", re.DOTALL)
_TAG_RE = re.compile(r"^<([a-z_-]{1,32})>\s*(.*?)\s*</\1>$", re.DOTALL | re.IGNORECASE)
_QUOTE_PAIRS = {'"': '"', "'": "'", "“": "”", "‘": "’"}

# Utterances containing addresses skip AI entirely: the model eats spoken
# "dot"/"at" joiners before postprocess can assemble them, and capitalizes
# already-formed addresses ("john.smith@…" → "John.Smith@…") — both measured.
# Addresses are rare and highly structured; the deterministic joiners own them.
_FORMED_ADDRESS_RE = re.compile(
    r"(?:@|https?://|\bwww\.|\b[a-z0-9-]+\.(?:" + postprocess._TLD_ALT + r")\b)",
    re.IGNORECASE,
)


def _has_address(raw: str) -> bool:
    return bool(
        _FORMED_ADDRESS_RE.search(raw)
        or postprocess._EMAIL_RE.search(raw)
        or postprocess._URL_RE.search(raw)
    )


# An output that *starts* like an assistant reply means the model answered the
# dictation instead of cleaning it — the whole output is untrustworthy.
_ASSISTANT_PREFIX_RE = re.compile(
    r"^(?:here(?:'s| is)\b|certainly\b|sure[,!]|of course\b|i'm sorry\b|"
    r"i am sorry\b|sorry[, ]|as an ai\b|i can(?:'t|not) help\b|great question\b|"
    r"you're welcome\b|you are welcome\b|happy to help\b|glad to help\b|"
    r"how can i (?:help|assist)\b|great[,!] |no problem[,!.])",
    re.IGNORECASE,
)

# Words ignored when comparing the utterance's opening word — the model is
# *supposed* to delete these, so they can't anchor the identity check.
_LEAD_FILLERS = {"um", "umm", "uh", "uhh", "uhm", "erm", "hmm",
                 "so", "okay", "ok", "well", "and", "like"}


def _first_content_word(text: str) -> str:
    for word in text.split():
        bare = word.strip(".,!?\"'“”‘’").lower()
        if bare and bare not in _LEAD_FILLERS:
            return bare
    return ""


def _unwrap_once(out: str) -> str:
    m = _FENCE_RE.match(out)
    if m:
        return m.group(1).strip()
    m = _TAG_RE.match(out)
    if m:
        return m.group(2).strip()
    if len(out) >= 2:
        closing = _QUOTE_PAIRS.get(out[0])
        if closing and out[-1] == closing:
            inner = out[1:-1]
            # Only a true full wrap: the same quote chars inside mean the
            # quotes are dialogue punctuation, not a wrapper.
            if out[0] not in inner and closing not in inner:
                return inner.strip()
    return out


def _strip_wrappers(text: str) -> str:
    """Deterministically peel meta-preambles and invented wrappers.

    Runs to a fixpoint (≤3 passes) because the failure modes compose — a
    preamble line followed by fenced content was observed as two separate
    modes and can co-occur.
    """
    out = (text or "").strip()
    for _ in range(3):
        prev = out
        out = _PREAMBLE_RE.sub("", out, count=1).strip()
        out = _unwrap_once(out)
        if out == prev:
            break
    return out


def _plausible(raw: str, refined: str) -> bool:
    """True when ``refined`` is plausibly the same utterance as ``raw``.

    Cleanup only removes fillers/stutters and fixes words, so the output word
    count stays close to the input's. A big shrink means the model summarized
    or dropped sentences; a big growth means it answered or hallucinated.
    Both observed in testing — both must fall back to verbatim. An output that
    opens like an assistant reply ("Sure, here's…") is rejected outright, and
    tiny inputs get almost no growth slack — "thank you" must never come back
    as "You're welcome! Happy to help.".
    """
    if not refined:
        return False
    if _ASSISTANT_PREFIX_RE.match(refined):
        # Only damning when the speaker didn't open that way themselves
        # ("um so sorry I missed your call" must still be cleanable).
        if _first_content_word(raw) != _first_content_word(refined):
            return False
    n_raw = len(raw.split())
    n_ref = len(refined.split())
    lower = int(n_raw * 0.4)
    upper = int(n_raw * 1.2) + (2 if n_raw < 6 else 8)
    return lower <= n_ref <= upper


def _estimated_words(raw: str) -> int:
    """Word count that stays meaningful for space-free scripts (CJK locales),
    where ``split()`` sees one giant token; budgets/timeouts use this."""
    return max(len(raw.split()), len(raw) // 6)


class Refiner:
    """Owns the helper lifecycle for one utterance at a time.

    Thread model: ``begin``/``refine``/``cancel`` run on the session thread;
    ``availability`` is read by the menu (main thread). ``_lock`` guards the
    process handle; the availability probe runs on a background thread.
    """

    def __init__(self, settings):
        self._settings = settings
        self._lock = threading.Lock()
        self._proc: subprocess.Popen | None = None
        # None = unknown (binary may still be compiling), True/False = probed.
        self._available: bool | None = None
        self._unavailable_reason = ""
        threading.Thread(target=self._probe_loop, daemon=True,
                         name="refine-probe").start()

    # --- availability -----------------------------------------------------

    @property
    def availability(self) -> bool | None:
        return self._available

    @property
    def unavailable_reason(self) -> str:
        return self._unavailable_reason

    def _binary_ready(self) -> bool:
        try:
            return runtime.REFINE_BIN.exists() and \
                runtime.REFINE_BIN.stat().st_mode & 0o111 != 0
        except OSError:
            return False

    def _probe_loop(self) -> None:
        """Resolve availability in the background and keep it fresh.

        Waits for bootstrap to compile the helper (up to ~3 min — after that
        availability goes False so the menu stops offering a dead toggle),
        then runs ``--check``. While unavailable — model assets still
        downloading, Apple Intelligence switched off — it re-checks every
        5 min so the feature comes back without a relaunch. Exits once
        available; refine() flips availability off again if the helper later
        reports the model gone (assets evicted / setting disabled).
        """
        start = time.monotonic()
        while True:
            waited = time.monotonic() - start
            if self._binary_ready():
                ok, reason = self._run_check()
                self._available = ok
                self._unavailable_reason = reason
                if ok:
                    return
            elif waited > 180.0:
                self._available = False
                self._unavailable_reason = \
                    "helper not compiled (is swiftc installed?)"
            time.sleep(5.0 if waited < 180.0 else 300.0)

    def _run_check(self) -> tuple[bool, str]:
        try:
            proc = subprocess.run(
                [str(runtime.REFINE_BIN), "--check"],
                capture_output=True, text=True, timeout=15.0)
            info = json.loads((proc.stdout or "").strip().splitlines()[-1])
            if info.get("available"):
                return True, ""
            reason = str(info.get("reason", "unknown"))
            log.warning("Apple Intelligence unavailable: %s", reason)
            return False, reason
        except Exception:
            log.exception("refine availability probe failed")
            return False, "availability probe failed"

    def enabled(self) -> bool:
        """True when refinement should run: setting on, helper compiled, and
        Apple Intelligence not known-unavailable (unknown ⇒ try anyway)."""
        try:
            if not bool(self._settings.get("ai_cleanup")):
                return False
        except Exception:
            return False
        return self._binary_ready() and self._available is not False

    # --- lifecycle ----------------------------------------------------------

    def begin(self) -> None:
        """Spawn the helper at record start so the model prewarms during the
        hold. Failure is silent — refine() will retry or fall back."""
        if not self.enabled():
            return
        with self._lock:
            if self._proc is not None:
                self._kill_locked()
            try:
                self._proc = subprocess.Popen(
                    [str(runtime.REFINE_BIN)],
                    stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                    stderr=subprocess.DEVNULL, bufsize=0,
                )
            except OSError:
                log.exception("failed to spawn wisprit_refine")
                self._proc = None

    def refine(self, raw: str, interrupt=None) -> tuple[str, str]:
        """Clean ``raw`` through Apple Intelligence.

        Returns ``(text, outcome)`` where outcome is ``"applied"`` or a
        skip/failure reason; ``text`` is always safe to insert. Never raises.

        ``interrupt`` (optional) is polled ~20×/s while the model runs and
        may return ``"cancel"`` (Esc — the caller will discard the utterance)
        or ``"hurry"`` (a new dictation is queued — finish NOW with verbatim
        text). Anything else keeps waiting.
        """
        try:
            return self._refine_inner(raw, interrupt)
        except Exception:
            log.exception("refine failed; keeping verbatim text")
            self.cancel()
            return raw, "error"

    def _refine_inner(self, raw: str, interrupt) -> tuple[str, str]:
        if not raw or not raw.strip():
            self.cancel()
            return raw, "empty"
        if not self.enabled():
            self.cancel()
            return raw, "off"
        if _has_address(raw):
            self.cancel()
            return raw, "has_address"

        words = _estimated_words(raw)
        max_words = self._num("ai_cleanup_max_words", 350)
        if words > max_words:
            # Latency is generation-bound (~20 ms/word, serialized system-wide
            # — parallel chunking measured to NOT help), and the shared context
            # is 4096 tokens. Long dictations keep the fast deterministic path.
            self.cancel()
            return raw, "too_long"

        with self._lock:
            proc = self._proc
            self._proc = None
        if proc is None or proc.poll() is not None:
            # Not prewarmed (first run after enabling, or helper died) —
            # spawn now and pay the ~0.3 s setup inline.
            if proc is not None:
                self._reap(proc)
            try:
                proc = subprocess.Popen(
                    [str(runtime.REFINE_BIN)],
                    stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                    stderr=subprocess.DEVNULL, bufsize=0,
                )
            except OSError:
                log.exception("failed to spawn wisprit_refine")
                return raw, "spawn_failed"

        # Transcript ≤ ~350 words ≈ a few KB — far below the 64 KB pipe
        # buffer, so this write can't block. A dead helper raises here; the
        # poll loop below then collects whatever error JSON it left behind.
        try:
            proc.stdin.write(raw.encode("utf-8"))
            proc.stdin.close()
        except OSError:
            pass

        cap_s = self._num("ai_cleanup_timeout_ms", 12000) / 1000.0
        deadline = time.monotonic() + min(
            cap_s, _TIMEOUT_BASE_S + _TIMEOUT_PER_WORD_S * words)

        # Poll instead of blocking so Esc / a new dictation can interrupt a
        # multi-second generation. The helper's reply (one JSON line, ≤ a few
        # KB) fits the pipe buffer, so it never blocks on stdout before exit.
        while proc.poll() is None:
            if time.monotonic() >= deadline:
                log.warning("wisprit_refine timed out (%d words)", words)
                self._reap(proc)
                return raw, "timeout"
            if interrupt is not None:
                why = interrupt()
                if why == "cancel":
                    self._reap(proc)
                    return raw, "cancelled"
                if why == "hurry":
                    self._reap(proc)
                    return raw, "preempted"
            time.sleep(_POLL_S)

        try:
            out = proc.stdout.read() or b""
        except OSError:
            out = b""
        finally:
            try:
                proc.stdout.close()
            except OSError:
                pass

        try:
            lines = [l for l in out.decode("utf-8").splitlines() if l.strip()]
            reply = json.loads(lines[-1])
        except (ValueError, IndexError):
            log.warning("wisprit_refine produced no parseable reply")
            return raw, "bad_reply"

        if not reply.get("ok"):
            err = str(reply.get("error"))
            log.warning("wisprit_refine error: %s", err[:200])
            if "unavailable" in err.lower():
                # Apple Intelligence got disabled / assets evicted mid-session:
                # stop spawning helpers until a probe or relaunch recovers.
                self._available = False
                self._unavailable_reason = err[:120]
            return raw, "helper_error"

        refined = _strip_wrappers(str(reply.get("text") or ""))
        if not _plausible(raw, refined):
            log.warning("refined text implausible (%d → %d words); keeping verbatim",
                        len(raw.split()), len(refined.split()))
            return raw, "implausible"
        return refined, "applied"

    def cancel(self) -> None:
        """Kill any live helper (record cancelled, refine skipped, shutdown)."""
        with self._lock:
            self._kill_locked()

    # --- internals ------------------------------------------------------------

    def _kill_locked(self) -> None:
        proc = self._proc
        self._proc = None
        if proc is not None:
            self._reap(proc)

    @staticmethod
    def _reap(proc: subprocess.Popen) -> None:
        try:
            proc.kill()
        except OSError:
            pass
        try:
            proc.communicate(timeout=1.0)
        except Exception:
            log.warning("wisprit_refine pid %s would not reap", proc.pid)

    def _num(self, key, default):
        try:
            v = self._settings.get(key)
            return v if isinstance(v, (int, float)) and v > 0 else default
        except Exception:
            return default
