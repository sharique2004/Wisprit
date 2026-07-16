# apple_live empirical measurements (M4, macOS 26.5)

Measured 2026-07-15 by feeding `say`-synthesized 16 kHz mono PCM into
`~/.meetingscribe/bin/apple_live` in real-time-paced 100 ms chunks, then
closing stdin. Drives the design of `wisprit/asr.py`.

## Protocol confirmed
- argv: `apple_live <locale> <sample_rate_hz> <channels> [--context file.json]`
- stdin: raw interleaved **int16** PCM.
- stdout NDJSON: `{"t":"partial",...}` (volatile), `{"t":"final",...}` (stable),
  then `{"t":"done"}` after stdin EOF, then the process **exits 0**.
- So the lifecycle is **one process per utterance**; closing stdin finalizes.

## Latency (the numbers that matter)
| Metric | Value | Notes |
|---|---|---|
| cold spawn → first partial | ~1.28 s | inherent SpeechAnalyzer pipeline delay |
| prewarmed (idle 3 s) → first partial | ~1.26 s | **prewarming barely helps** — model warms on audio, not spawn |
| **stdin close → exit (finalize)** | **66–182 ms** | across 0.5 s–5.4 s utterances |

Release-to-final of **~70–180 ms** is the decisive result: because finals are
emitted *during* the hold, closing stdin only flushes the short tail. Add
<5 ms postprocess + ~60–100 ms clipboard paste → **~200–300 ms release-to-text**,
comfortably under Wispr Flow's 700 ms target, fully local.

Consequence for the design:
- **Spawn fresh per utterance** on key-down; do not bother with a prewarmed idle
  process (it saves ~20 ms and complicates lifecycle/mic/context handling).
- The live pill partial preview lags speech by ~1.25 s — fine as feedback; the
  release-time final is fast and is what lands in the app.
- `finalize()` waits up to `finalize_timeout_ms` (default 1500 ms, generous vs
  the measured ~180 ms) for `{"t":"done"}`; on timeout, fall back to the
  accumulated finals + last partial and mark `timed_out=True`.

## Output quality
- **Punctuation and capitalization are emitted natively** and are good:
  `"Hello, world."`, `"Let's grab coffee at three."`, `"Testing."`
- Assemble the utterance by joining all `final` segment texts with a space.

## Custom vocabulary — `--context` is a NO-OP (as the research predicted)
With `--context {"strings":["InsForge","MeetingScribe","Wisprit"]}` the output
was still `"Inns Forge"`, `"Meeting Scribe"`, `"whispered"`. This confirms
docs/research/local-tech.md §4: `SpeechTranscriber` ignores `contextualStrings`
(only `DictationTranscriber` honors it). **Therefore vocabulary correctness
comes entirely from `postprocess.py` dictionary substitutions**, not the helper.
We still pass `--context` (harmless) so a future `DictationTranscriber` helper
would light up automatically.

## Fallback
`mlx-whisper large-v3-turbo` on the retained full-utterance PCM is the batch
fallback (engine-agnostic `AsrManager`), used if apple_live is missing/unhealthy
or finalize yields empty text. faster-whisper is the CPU tertiary.
