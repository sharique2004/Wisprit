# Intentional deviations from SPEC.md / INTERFACES.md

The build spec (`docs/SPEC.md`) and module contracts (`docs/INTERFACES.md`)
were written before the code. Where the implementation deliberately diverges —
because empirical measurement or a design principle said so — it is recorded
here rather than silently. Surfaced by the adversarial review pass.

## 1. Spawn-per-utterance, not a pre-warmed long-lived helper
SPEC/INTERFACES describe an `apple_live` process that stays resident and is
`prewarm()`-ed between utterances. **Not implemented** — `AppleLiveEngine`
spawns a fresh helper on each key-down and tears it down on finalize/cancel.
Reason: measured (docs/notes/asr-notes.md) that a pre-warmed idle process gives
first-partial latency of ~1.26 s vs ~1.28 s cold — i.e. prewarming saves ~20 ms
while adding lifecycle, mic, and context-file complexity. The number that
matters, release-to-final, is ~50–180 ms either way. There is no `prewarm()`
method.

## 2. No ~300 ms rolling pre-buffer (deliberate, for privacy)
SPEC build_plan #4 calls for a ring buffer capturing ~300 ms *before* key-down
so the first syllable isn't clipped. **Not implemented**, because an always-on
pre-buffer requires the microphone to stay live between utterances — which
would defeat the headline privacy feature that the mic is hard-off (orange
indicator dark) except while the key is held. We chose privacy over the last
few milliseconds of leading audio; in practice the natural gap between pressing
Fn and speaking, plus SpeechAnalyzer's own pipeline latency, absorbs it. Users
who clip their first word can simply pause a beat after pressing.

## 3. Number normalization not implemented (verbatim-first)
SPEC mvp_features #4 / §4 list spelled-out-number → digit conversion and
phone-number grouping as a Tier-1 rule. **Deliberately omitted** — converting
"one more" → "1 more" is exactly the surprising edit that erodes trust, against
the verbatim-first principle. Deferred to a future opt-in setting. (Neither the
README nor INTERFACES claims it, so only SPEC is ahead of reality here.)

## 4. Custom-vocabulary `--context` biasing is inert
Confirmed empirically (docs/notes/asr-notes.md, docs/research/local-tech.md §4):
the reused helper uses `SpeechTranscriber`, whose `contextualStrings` Apple does
not honor. Vocabulary correctness comes entirely from `postprocess.py`
dictionary substitutions. `--context` is still passed (harmless; future-proof
for a `DictationTranscriber` helper).

## 5. paste_restore_delay_ms default is 500, not 120
INTERFACES originally said 120 ms. Raised to 500 ms after the research pass:
restoring the clipboard before the target app has read the paste is the #1 bug
across competing tools ("it pasted my old clipboard"). settings.py, bootstrap.py,
and README agree on 500; INTERFACES has been corrected.

## 6. On finalize timeout, the last partial is used (not a batch re-transcribe)
`AsrManager.finalize` returns the streaming result — finals plus the last
volatile partial — on a plain timeout, matching the documented fast path. Batch
re-transcription (mlx-whisper → faster-whisper) is reserved for a helper
**crash** (process exited without `{"t":"done"}`) or a genuinely **empty**
result, which is the resilience case the SPEC intended.

## Known limitation (not fixed)
- With `hotkey: "right_option"`, holding the *left* Option key simultaneously
  can mask the right-Option release edge (both set the generic Alternate flag),
  leaving the trigger stuck until another clean right-Option press. Rare
  (requires holding both Option keys); the watchdog + chord-interrupt reset
  paths mitigate the worst stuck states. Fn (the default) is unaffected.

## Native rewrite (2026-08-05)

- **Batch-fallback chain not ported (accepted, temporary).** The Python
  mlx-whisper → faster-whisper fallback is a stub in the native app
  (`WispritEngine/BatchFallback.swift` returns nil; engine values still parse).
  A crash of the in-process SpeechAnalyzer path currently falls back to the
  last partial + history, not to a second engine. The WhisperKit
  large-v3-turbo slot ships with Phase 3 (Background Assets). Until then the
  README must not claim a fallback chain.
- **"Polish Last with Claude" removed by product decision (permanent).**
  User directive 2026-08-05: Apple Intelligence only, zero network calls.
  Replacement is `WispritPolish` (FoundationModels, 4 modes, eval battery).

## Spoken emoji directives — a stage SPEC never described (2026-08-09)

SPEC §postprocessing Tier-1 #4 lists the spoken-form directives as email/URL
joining, number formatting and "new line"/"period". **`WispritPostProcess` now
also ships a spoken-emoji stage** — "fantastic work fire emoji" → "fantastic
work 🔥" — over a closed 33-name table, regex only, no model. It is post-Python:
`postprocess.py` has no equivalent, so this is an addition rather than a
divergence, and the Python-generated `Goldens.swift` / `FuzzGoldens.swift` are
untouched (they remain literal Python output; the new behavior is pinned by the
hand-written `EmojiCommandTests.swift`, the same precedent the `has_letter_run`
era set for native-only behavior).

Three decisions worth recording:

- **The word "emoji" is required.** A bare "fire" never converts. This is what
  keeps the stage inside the verbatim-first philosophy: like "new line", it is
  an explicit spoken directive, not an inference about what the user meant.
- **It runs after self-correction, not inside the voice-command stage** (stage 6
  of 8, immediately after the family it belongs to). The noun-phrase guard treats
  "that" as a determiner and "that" is also the "scratch that" marker, so run any
  earlier, "nope scratch that fire emoji" reads as the noun phrase "that fire
  emoji", is left verbatim, and the user gets the literal words "fire emoji" once
  the marker is stripped. Sequenced after stage 5, self-correction resolves first
  and the directive fires.
- **Guards err toward verbatim, twice.** A determiner / interrogative /
  preposition in front means the user is *talking about* the emoji ("the fire
  emoji", "a heart emoji", "an eyes emoji", "that fire emoji") — untouched. And a
  spelled letter run overlapping the match is skipped, which as a side effect
  means a glued all-caps "THUMBS UP EMOJI" stays verbatim: an all-caps token is
  formally identical to what ITN emits for a dictated spelling, and the stage
  must never eat one. Mixed-case "Thumbs Up Emoji" converts.

Gated by `emoji_commands` (default `true`), the fourth key `PostProcessOptions`
reads and the third native appendix in `Settings.defaults` (append-only, after
`im_selection_policy`).
