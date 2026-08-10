# The robustness deck (v1)

The per-release tripwire for the axes in "any accent, any volume, any tone":
three TTS corpora, a raw-stage per-axis table, and four RI indices compared
against `BASELINE.json` by `Wisprit eval deck` (exit 3 on violation).
Definitions live in `DEFINITIONS.md` §"The robustness deck"; design and
pilot evidence in `docs/research/robustness/measurement.md` §3–6 and
FINAL-PLAN R3.

**Every number here is a TTS tripwire — deterministic per OS build, useful
for catching regressions in ~2 minutes of ASR, and never an accuracy claim.**

## Contents (frozen per version)

| corpus | cells | clips |
|---|---|---:|
| `tts-accents-v1` | 8 accent voices (samantha, daniel, karen, moira, rishi, aman, tara, tessa) × the 54-line tts-v1 pack; `category` = voice | 432 |
| `tts-stress-v1` | g0, g-12, g-24, g-36, clip+6, wn20/wn10/wn5 (on g-12), bab10, bandlimit8k, whisper-voice, r120, r240; `category` = condition | 702 |
| `tts-corners-v1` | aman-g-24-wn10, aman-r240-bab10, rishi-g-12-wn5 | 162 |
| **total** | | **1,296** |

Audio is gitignored; manifests + `generate.sh` are committed. Recipes are
seeded and `--force`-only (`tools/eval/corpus/decklib/deckgen.py`), so re-runs
never churn sha256s and the ASR cache survives. The ASR cache key includes the
OS build, so a macOS update re-transcribes (~2 min) instead of stamping stale
transcripts with a new build.

## Runbook

```sh
# once per voice-tier change (or never again):
tools/eval/corpus/tts-accents-v1/generate.sh
tools/eval/corpus/tts-stress-v1/generate.sh
tools/eval/corpus/tts-corners-v1/generate.sh

BIN=.build/debug/WispritMac
for c in tts-accents-v1 tts-stress-v1 tts-corners-v1; do
    $BIN eval asr    --corpus $c                                   # ~2 min total
    $BIN eval stages --corpus $c --refine off --dict off           # seconds
    $BIN eval report --corpus $c --refine off --dict off --stage raw
done
$BIN eval deck                                                     # RI vs baseline
```

## Recorded baselines — deck v1, first run

Recorded 2026-08-10, git `6fd929f`, macOS build `25F84`, engine `apple_live`,
**compact voice tiers** (see the tier caveat below), raw stage:

| component | recorded | tolerance | alarm means |
|---|---:|---:|---|
| `ri-noise` (wn5 − g0) | **+16.7 pts** (0.167355) | ±3 pts | the noise cliff moved — expected across OS model swaps; that volatility is signal, look at it |
| `ri-accent` (worst − samantha) | **+3.1 pts** (0.030992, karen) | ±2 pts | a release widened the accent gap |
| `ri-level` (max(g−36, clip+6) − g0) | **+1.7 pts** (0.016529) | alarm > +4 pts | a capture/AGC regression — the engine itself is gain-invariant |
| `ri-empty` (whole deck) | **0** over 1,296 clips | exact | ANY nonzero is news — 0 empties is the replicated baseline |
| tone | — | — | unmeasured until human-v1 pass 4; the deck says so rather than pretending |

Canary (printed in the per-axis table, not an RI component): the
`whisper-voice` cell reads **60.3 % raw WER** — the engine degrades hard on
low-energy phonation, which is exactly why pass 4 exists and why no local
lever is claimed for tone.

**Honest note on the pilot numbers.** The pilot (measurement.md §4) quoted
RI-accent +8.3 (aman) and RI-level +2.4 from **final-stage** scoring of a
50-line pack. Deck v1 records the **raw** stage (per M §6.2.1 — the axes
attack the engine, and final-stage tables conflate engine damage with
pipeline repair) over the current 54-line pack, where the measured accent
spread is +3.1 (karen worst; aman/tara sit at +1.7). RI-noise replicates
almost exactly (+16.7 vs +16.8), RI-empty replicates at 0. The recorded
values above — not the pilot's — are what the tripwire compares against; a
change of stage, pack, or tier is a version bump and a deliberate
re-baseline, never a silent drift.

## The voice-tier caveat (H2)

`say -v '?'` on the recording machine currently lists only **compact** tiers
for all 8 accent voices, and the manifests record that
(`speaker: tts-aman-compact`, …). Part of any per-voice gap is therefore
synthesis fidelity, not accent. When the Enhanced/Premium tiers are installed
(System Settings → Accessibility → Spoken Content → Manage Voices — plan item
H2), regenerate with `--force`, re-run `eval asr` (~2 min), and re-record the
RI baselines in `BASELINE.json` as a deliberate act. Until then, the accent
axis is a *tripwire from this baseline*, and per-voice gaps must not be
quoted as accent findings.

## The cue-bleed gate (A-6 → B-5)

`tools/eval/scripts/cue-bleed/check.py` mixes a sound-cue asset over deck
clip heads and asserts **zero transcript delta** — the pre-registered gate
before sound cues default on when the pill is hidden. With an 80 ms 880 Hz
placeholder beep the check FAILS at −25 dBFS peak (8/54 deltas) **and still
fails at −40 dBFS (3/54)** — utterance heads are sensitive, so the real B-5
asset must be validated with this check at a measured coupling level before
the default flips, and "cue ends before capture starts" may be the only shape
that passes.
