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
