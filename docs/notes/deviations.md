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

## Retro-correction (Phase 3)

- **A second `metrics.log` line per utterance, `outcome: "vocab_retro"`.**
  The off-path vocabulary pass finishes 1–2.5 s after insertion, by which time
  the utterance's own row is already on disk and `metrics.log` is append-only —
  so `vocab_ms` / `vocab_hits` / `vocab_delta` / `applied` cannot ride it, and
  attributing them to the *next* utterance's row would be worse than a second
  line. This follows the `outcome: "correction"` precedent (a fourth value
  beyond `paste|type|blocked_secure|error|empty`) and extends it in one way:
  `correction` rows describe an utterance, `vocab_retro` rows do not. They are
  reference-less — nothing but file order ties one to its utterance — and
  `MetricsSummary` therefore drops them before counting anything, or a
  `finalize_ms` of 0.0 would anchor the latency percentiles and every rate in
  `Wisprit stats` would be diluted by roughly the success rate. Pinned by
  `Golden.metricsVocabRetroRow` and `MetricsSummaryTests`.
  Exactly one row is written per completed reconciliation, at the moment
  `applied` is finally known. A plan whose deferred application is dropped
  because the user started speaking again writes **no** row, rather than one
  claiming `applied: false` for an edit that was never attempted.

## Self-correction beyond the Python markers (2026-08-10)

SPEC §postprocessing Tier-1 #5 scopes self-correction to "explicit markers
only … ambiguous cases pass through verbatim", and `postprocess.py` shipped two
of them: `X no wait Y` and `scratch that`. The engine now lives in
`WispritPostProcess/SelfCorrection.swift` (stage 5 is a one-line caller) and
adds a second tier. The Python-generated `Goldens.swift` / `FuzzGoldens.swift`
are untouched and still literal Python output; the new behavior is pinned by
`SelfCorrectionTests.swift`, the `EmojiCommandTests` precedent.

- **Closed-class pairs are the new tier.** "`<X> <connective> <Y>`" keeps Y only
  when X and Y are members of the SAME closed class — weekday, month, clock
  time, cardinal/ordinal number, relative day. "Thursday umm no actually Friday"
  → "Friday". Requiring both sides to be the same *kind of thing* is what makes
  the weak connectives safe: a bare "actually", "sorry" or "no" is a connective
  inside that sandwich and nowhere else, so "that's actually great" and "I
  actually think Friday works" are untouched. Fillers are tolerated anywhere in
  the joint because the live path runs this on raw partials, before stage 1.
- **Cross-class is a veto, not a fall-through.** "Thursday no actually 3
  o'clock" does not type-check as a correction — you cannot correct a weekday
  into a time — so the joint passes verbatim AND no general marker gets a second
  look at it. The one exemption is "no wait": its replacement span is a
  Python-parity contract, so it still deletes whatever it is handed
  ("Thursday no wait 3 o'clock" → "3 o'clock"). The asymmetry is deliberate and
  pinned by `testLegacyMarkerIsExemptFromTheCrossClassVeto`.
- **Two new general markers, one new guard.** "no actually" and "I mean" reuse
  the Python span exactly (the single word before the marker, the marker, the
  joint whitespace, duplicate function word collapsed). They add a
  discourse-hedge guard the legacy marker does not need: "so I mean we should
  go" and "well no actually that's fine" are conversation, not correction, so a
  function word in front of the marker vetoes the rewrite. Bare "actually" is
  NOT a general marker at any price — tier one covers the safe cases.
- **Unconditional, like the rule it extends.** Self-correction has no settings
  key in Python or here, so the new tier did not get one either: same product
  surface, not a new toggle. The live path below inherits that for the same
  reason — a preview that could disagree with the text it previews is worse
  than no preview.
- **The live path is display-only.** `LivePartialCorrection` runs the engine on
  every partial at the single fan-out in `SessionController.begin`, so the
  correction is already in the pill bubble and the input method's marked text
  while the user is still speaking. It edits nothing else: the session keeps no
  partial state, so finalize still runs the whole pipeline over the RAW final,
  and the corrections stage, the refine prompt, `history` and `metrics`'
  `chars`/`raw_chars` all still read exactly what the engine heard. Partials
  longer than 2 000 characters are shown verbatim rather than scanned on the
  session thread; finalize corrects them a moment later either way.
