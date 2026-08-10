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

## SpeechDetector probe — gating-only IN PRACTICE on this build (2026-08-10)

Probe: `docs/research/probes/speechdetector_probe.swift` (FINAL-PLAN B-6/R16,
judge-feasibility §6.2). Question: can Apple's `SpeechDetector` module replace
the hand-tuned `voicedPeakThreshold` with an engine-calibrated
silent-vs-speech verdict over retained PCM? M4, macOS 26.5.

The TYPE is verdict-shaped — the SDK swiftinterface declares
`init(detectionOptions:reportResults:)` and a `results` stream of `Result`
carrying `range: CMTimeRange` + `speechDetected: Bool`. The behaviour is not:

- **Detector-only analyzer is not a supported topology.** The process TRAPS
  (`Speech/SpeechDetector.swift:223: Fatal error: Cannot create
  SpeechDetector-only worker; use with a transcriber module`) — a trap, not a
  catchable error, so no off-path detector-only pass can even be attempted
  safely. Reproduce: `./sdp --detector-only`.
- **Co-located with a SpeechTranscriber, `reportResults: true`, results are
  NEVER delivered.** All three sensitivity levels × {2 s digital silence,
  clean `say` speech (meter peak 1.0), speech ×0.01 (peak 0.011), speech
  ×0.003 (peak 0.003)}: the `results` stream yielded nothing on every speech
  case and on silence at low/medium; at `sensitivity: .high` on silence it
  errored (`SFSpeechErrorDomain Code=1 "RecogRejected"`). Meanwhile the
  co-located transcriber transcribed every speech case perfectly — including
  ×0.01 and ×0.003, an incidental third replication of the gain-invariance
  result (robustness/acoustic.md §2).

**Verdict for R16: gating-only in practice on this OS build.** The
engine-calibrated-VAD shortcut does NOT open; the `EmptyReason` floor
recalibration stays on the R26 path (derive the classification floor from p5
of voiced-success `peak_level` once ~100 rows exist — the fields land with
R4's telemetry completion). Keep the probe as the one-command per-OS re-probe:
if a future build starts delivering `speechDetected` verdicts, R16 reopens
and obsoletes the constant.
