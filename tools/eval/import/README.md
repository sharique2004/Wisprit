# Real-speech rung — public corpora import + the locale cross-check

The middle rung of the calibration ladder (measurement.md §8.1, FINAL-PLAN R5):
**synthetic matrix → public real speech → human-v1.** TTS accents are
caricatures; these corpora are real human voices with verbatim transcripts,
and they answer two questions *before* any recording session exists:

1. **Does the synthetic accent ordering survive contact with real accented
   speech?** (If not, the accents deck is demoted to voice-QA and
   measurement.md gets an appended correction — that promise is on record.)
2. **The accent lever's go/no-go (R21):** does decoding accent-labeled English
   under matched locale assets (en_IN for India-labeled speech) beat en_US?
   - **Bar (pre-registered):** matched assets ≥ 10 % *relative* WER win on
     Hindi-L1 / India-labeled speech ⇒ the R21 locale-chooser pipeline
     proceeds. Flat ⇒ R21 dies before any UI is built.
   - en_GB on the same audio is the control cross (assets differ, accent
     doesn't match — expect no win).

These rows are scored **raw stage, `.asr` profile only** (read speech, no
formatting targets, term recall inapplicable) and are **never quoted as
Wisprit accuracy claims** — they carry `source: "librispeech"`, the manifest
marker for "public real-speech corpus". Human-v1 remains the only accuracy
ground truth.

## Acquisition — you download, the tools never do

The harness and this importer are zero-network by rule. Download on your own
authority, then point the importer at the local files. All three are
license-clean for local evaluation:

| corpus | what | where | license | size |
|---|---|---|---|---|
| LibriSpeech `test-clean` / `test-other` | read US English, the standard easy/hard pair | openslr.org/12 | CC BY 4.0 | 346 MB / 328 MB |
| L2-ARCTIC v5 | 24 non-native speakers × ~1,130 utterances, 6 L1s (4 Hindi-L1 speakers — the axis the TTS deck flags worst) | psi.engr.tamu.edu/l2-arctic-corpus (release form, free) | CC BY-NC 4.0 | ~8 GB |
| Common Voice (English) | crowd speech with **self-reported accent labels** (`accents` column: India and South Asia, Scotland, southern US, …) | commonvoice.mozilla.org/en/datasets | CC0 | ~80 GB full; the delta segments are smaller |

Suggested local layout: `~/Datasets/LibriSpeech/test-clean`,
`~/Datasets/l2arctic_release_v5`, `~/Datasets/cv-corpus-<ver>/en`.

## Import

```sh
# read US English, easy + hard
python3 tools/eval/import/import_realspeech.py librispeech \
    --root ~/Datasets/LibriSpeech/test-clean --corpus ls-test-clean
python3 tools/eval/import/import_realspeech.py librispeech \
    --root ~/Datasets/LibriSpeech/test-other --corpus ls-test-other

# the accent axis: Hindi-L1 real speech (4 speakers, category "hindi-l1")
python3 tools/eval/import/import_realspeech.py l2arctic \
    --root ~/Datasets/l2arctic_release_v5 --corpus l2arctic-hindi --l1 hindi

# broader self-reported labels, if Common Voice is on disk
python3 tools/eval/import/import_realspeech.py commonvoice \
    --root ~/Datasets/cv-corpus-22.0/en --corpus cv-en-india --accent India
```

Defaults: 200 clips per corpus, deterministically sampled (`--seed 7` is part
of the subset's identity — record any change). Audio is converted to the
pipeline format (LEI16@16000 mono) with the system `afconvert`; existing WAVs
are kept unless `--force`, same sha-cache discipline as every corpus here.

## The locale cross — runbook

`--locale` re-decodes the *same audio* under different locale assets; the
settings hash includes the locale, so nothing collides and re-runs are cached.
Preflight: all nine English ST locales are installed on the dev machine
(`Wisprit doctor`); on other machines install assets first and mind
`maximumReservedLocales`.

```sh
BIN=.build/debug/WispritMac
for locale in en-US en_IN en_GB; do
    $BIN eval asr    --corpus l2arctic-hindi --locale $locale
    $BIN eval stages --corpus l2arctic-hindi --locale $locale --refine off --dict off
    $BIN eval score  --corpus l2arctic-hindi --locale $locale --refine off --dict off --stage raw
done
```

Read the **raw** WER row per locale. Decision per the bars above; the
LibriSpeech corpora run the same way as the ordering/no-lever control
(en_US-matched speech should show no en_IN win — if it does, something other
than accent matching is moving).

Noise replication (optional): the deck's wn/babble constructions compose with
real speech exactly as with TTS — mix them over an imported corpus with the
decklib ops if the noise axis ever needs a real-speech replication.

## What this rung is not

- Not push-to-talk shaped, not your microphones, not your rooms.
- Not a term-recall surface (no `expect.terms`; the dictionary plays no part).
- Not an accuracy claim in any direction. It is the ordering check between
  the TTS deck and human-v1, and the cheapest honest answer to "TTS accents
  are caricatures".
