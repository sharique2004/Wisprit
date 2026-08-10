# Wisprit accuracy results

Every section below is one `Wisprit eval` run, appended by the harness.

**This file is append-only.** Never edit or delete a section, and never reorder
them. A superseded number is not clutter — it is the evidence of what changed,
and the only way to tell "the pipeline improved" from "someone re-ran it until it
looked better". If a row was produced by a mistake, append a new row and say so
in its notes; do not remove the old one.

Every section carries the git sha, OS build, prompt sha256, dictionary size and
scorer version that produced it. Rows are only comparable when those agree —
Apple replaces the on-device refine model in point releases, so a row from a
different `os` build is a different experiment.

**TTS banner rule.** A corpus whose `source` is `tts` prints

> **TTS corpus — plumbing check only, not an accuracy claim**

at the top of its section, and the banner is not optional. `say -v Samantha`
audio is clean, synthetic, single-speaker and has none of the disfluency,
room tone, or microphone variation that real dictation has: it proves the harness
runs end to end and catches plumbing regressions, and it says **nothing** about
how well Wisprit hears people. Numbers from a TTS row must never be quoted as
accuracy — externally or in a commit message. Spike S4 stays open until the
Phase-2 human corpus (`human-v1`) is recorded.

Definitions: [DEFINITIONS.md](DEFINITIONS.md). Accepted numbers and tolerance
bands: [BASELINE.json](BASELINE.json). Machine-readable runs: `runs/*.json`
(committed); per-utterance transcripts are `runs/*.detail.jsonl` (gitignored —
regenerate with `Wisprit eval`).

To add a section:

```sh
swift build
.build/debug/WispritMac eval all --corpus tts-samantha
```

## 2026-08-10T03:48:38Z — tts-samantha/all — apple_live — `refine=off,dict=off`

> **TTS corpus — plumbing check only, not an accuracy claim**

git `d6a3387` · os `25F84` · prompt `9f337b6cd87c093f694672f04327f794509631176edc26cd9fb639b93266b2ec` · dictionary 9 terms · scorer v1 · corpus source `tts`

| stage | n | ref words | errors | WER | CER | term recall | zero-edit |
|---|---:|---:|---:|---:|---:|---:|---:|
| raw | 44 | 406 | 58 | 14.29% | 9.16% | 0.056 | 0.273 |
| corrected | 44 | 406 | 55 | 13.55% | 8.48% | 0.056 | 0.295 |
| refined | 44 | 406 | 55 | 13.55% | 8.48% | 0.056 | 0.295 |
| final | 44 | 406 | 55 | 13.55% | 8.48% | 0.056 | 0.295 |

### By category

| category | n | WER | term recall |
|---|---:|---:|---:|
| proper-nouns | 5 | 31.71% | 0.000 |
| control-names | 4 | 12.90% | 0.250 |
| tech-jargon | 6 | 18.64% | 0.000 |
| homophones | 5 | 0.00% | — |
| addresses | 5 | 12.24% | — |
| spelled-runs | 4 | 8.33% | — |
| numbers-dates | 4 | 5.88% | — |
| postal-address | 1 | 0.00% | — |
| commands | 4 | 0.00% | — |
| disfluency | 5 | 26.83% | — |
| long-form | 1 | 16.67% | 0.000 |

## 2026-08-10T03:48:38Z — tts-samantha/all — apple_live — `refine=off,dict=on`

> **TTS corpus — plumbing check only, not an accuracy claim**

git `d6a3387` · os `25F84` · prompt `9f337b6cd87c093f694672f04327f794509631176edc26cd9fb639b93266b2ec` · dictionary 9 terms · scorer v1 · corpus source `tts`

| stage | n | ref words | errors | WER | CER | term recall | zero-edit |
|---|---:|---:|---:|---:|---:|---:|---:|
| raw | 44 | 406 | 58 | 14.29% | 9.16% | 0.056 | 0.273 |
| corrected | 44 | 406 | 55 | 13.55% | 8.48% | 0.056 | 0.295 |
| refined | 44 | 406 | 55 | 13.55% | 8.48% | 0.056 | 0.295 |
| final | 44 | 406 | 40 | 9.85% | 7.43% | 0.444 | 0.341 |

### By category

| category | n | WER | term recall |
|---|---:|---:|---:|
| proper-nouns | 5 | 14.63% | 0.500 |
| control-names | 4 | 12.90% | 0.250 |
| tech-jargon | 6 | 13.56% | 0.250 |
| homophones | 5 | 0.00% | — |
| addresses | 5 | 10.20% | — |
| spelled-runs | 4 | 8.33% | — |
| numbers-dates | 4 | 5.88% | — |
| postal-address | 1 | 0.00% | — |
| commands | 4 | 0.00% | — |
| disfluency | 5 | 26.83% | — |
| long-form | 1 | 5.56% | 1.000 |

## 2026-08-10T03:49:51Z — tts-samantha/all — apple_live — `refine=on,dict=off`

> **TTS corpus — plumbing check only, not an accuracy claim**

git `d6a3387` · os `25F84` · prompt `9f337b6cd87c093f694672f04327f794509631176edc26cd9fb639b93266b2ec` · dictionary 9 terms · scorer v1 · corpus source `tts`

| stage | n | ref words | errors | WER | CER | term recall | zero-edit |
|---|---:|---:|---:|---:|---:|---:|---:|
| raw | 44 | 406 | 58 | 14.29% | 9.16% | 0.056 | 0.273 |
| corrected | 44 | 406 | 55 | 13.55% | 8.48% | 0.056 | 0.295 |
| refined | 44 | 406 | 52 | 12.81% | 9.80% | 0.222 | 0.364 |
| final | 44 | 406 | 52 | 12.81% | 9.80% | 0.222 | 0.364 |

Refine battery: **0.856** (weighted)

### By category

| category | n | WER | term recall |
|---|---:|---:|---:|
| proper-nouns | 5 | 31.71% | 0.000 |
| control-names | 4 | 12.90% | 0.250 |
| tech-jargon | 6 | 6.78% | 0.750 |
| homophones | 5 | 0.00% | — |
| addresses | 5 | 12.24% | — |
| spelled-runs | 4 | 8.33% | — |
| numbers-dates | 4 | 2.94% | — |
| postal-address | 1 | 0.00% | — |
| commands | 4 | 35.29% | — |
| disfluency | 5 | 9.76% | — |
| long-form | 1 | 16.67% | 0.000 |

## 2026-08-10T03:50:11Z — tts-samantha/all — apple_live — `refine=on,dict=on`

> **TTS corpus — plumbing check only, not an accuracy claim**

git `d6a3387` · os `25F84` · prompt `9f337b6cd87c093f694672f04327f794509631176edc26cd9fb639b93266b2ec` · dictionary 9 terms · scorer v1 · corpus source `tts`

| stage | n | ref words | errors | WER | CER | term recall | zero-edit |
|---|---:|---:|---:|---:|---:|---:|---:|
| raw | 44 | 406 | 58 | 14.29% | 9.16% | 0.056 | 0.273 |
| corrected | 44 | 406 | 55 | 13.55% | 8.48% | 0.056 | 0.295 |
| refined | 44 | 406 | 52 | 12.81% | 9.80% | 0.222 | 0.364 |
| final | 44 | 406 | 40 | 9.85% | 9.25% | 0.556 | 0.386 |

Refine battery: **0.856** (weighted)

### By category

| category | n | WER | term recall |
|---|---:|---:|---:|
| proper-nouns | 5 | 14.63% | 0.500 |
| control-names | 4 | 12.90% | 0.250 |
| tech-jargon | 6 | 6.78% | 0.750 |
| homophones | 5 | 0.00% | — |
| addresses | 5 | 10.20% | — |
| spelled-runs | 4 | 8.33% | — |
| numbers-dates | 4 | 2.94% | — |
| postal-address | 1 | 0.00% | — |
| commands | 4 | 35.29% | — |
| disfluency | 5 | 9.76% | — |
| long-form | 1 | 5.56% | 1.000 |

## 2026-08-10T04:17:12Z — tts-samantha/all — apple_live — `refine=on,dict=off`

> **TTS corpus — plumbing check only, not an accuracy claim**

git `3912dfe` · os `25F84` · prompt `9f337b6cd87c093f694672f04327f794509631176edc26cd9fb639b93266b2ec` · dictionary 9 terms · scorer v1 · corpus source `tts`

| stage | n | ref words | errors | WER | CER | term recall | zero-edit |
|---|---:|---:|---:|---:|---:|---:|---:|
| raw | 44 | 406 | 58 | 14.29% | 9.16% | 0.056 | 0.273 |
| corrected | 44 | 406 | 55 | 13.55% | 8.48% | 0.056 | 0.295 |
| refined | 44 | 406 | 40 | 9.85% | 5.61% | 0.222 | 0.386 |
| final | 44 | 406 | 40 | 9.85% | 5.61% | 0.222 | 0.386 |

Refine battery: **0.972** (weighted)

### By category

| category | n | WER | term recall |
|---|---:|---:|---:|
| proper-nouns | 5 | 31.71% | 0.000 |
| control-names | 4 | 12.90% | 0.250 |
| tech-jargon | 6 | 6.78% | 0.750 |
| homophones | 5 | 0.00% | — |
| addresses | 5 | 12.24% | — |
| spelled-runs | 4 | 8.33% | — |
| numbers-dates | 4 | 2.94% | — |
| postal-address | 1 | 0.00% | — |
| commands | 4 | 0.00% | — |
| disfluency | 5 | 9.76% | — |
| long-form | 1 | 16.67% | 0.000 |

## 2026-08-10T04:17:32Z — tts-samantha/all — apple_live — `refine=on,dict=on`

> **TTS corpus — plumbing check only, not an accuracy claim**

git `3912dfe` · os `25F84` · prompt `9f337b6cd87c093f694672f04327f794509631176edc26cd9fb639b93266b2ec` · dictionary 9 terms · scorer v1 · corpus source `tts`

| stage | n | ref words | errors | WER | CER | term recall | zero-edit |
|---|---:|---:|---:|---:|---:|---:|---:|
| raw | 44 | 406 | 58 | 14.29% | 9.16% | 0.056 | 0.273 |
| corrected | 44 | 406 | 55 | 13.55% | 8.48% | 0.056 | 0.295 |
| refined | 44 | 406 | 40 | 9.85% | 5.61% | 0.222 | 0.386 |
| final | 44 | 406 | 28 | 6.90% | 5.06% | 0.556 | 0.409 |

Refine battery: **0.972** (weighted)

### By category

| category | n | WER | term recall |
|---|---:|---:|---:|
| proper-nouns | 5 | 14.63% | 0.500 |
| control-names | 4 | 12.90% | 0.250 |
| tech-jargon | 6 | 6.78% | 0.750 |
| homophones | 5 | 0.00% | — |
| addresses | 5 | 10.20% | — |
| spelled-runs | 4 | 8.33% | — |
| numbers-dates | 4 | 2.94% | — |
| postal-address | 1 | 0.00% | — |
| commands | 4 | 0.00% | — |
| disfluency | 5 | 9.76% | — |
| long-form | 1 | 5.56% | 1.000 |

> **Provenance note (2026-08-09):** the two `2026-08-10T0417*Z` sections above were
> measured in a worktree whose parent commit was `3912dfe`; the obedience-guard
> change they measure was committed immediately afterwards. Numbers are correct;
> the stamped sha is the parent.

## 2026-08-10T07:25:08Z — tts-samantha/all — apple_live — `refine=off,dict=off`

> **TTS corpus — plumbing check only, not an accuracy claim**

git `c8fd080` · os `25F84` · prompt `9f337b6cd87c093f694672f04327f794509631176edc26cd9fb639b93266b2ec` · dictionary 9 terms · scorer v1 · corpus source `tts`

| stage | n | ref words | errors | WER | CER | term recall | zero-edit |
|---|---:|---:|---:|---:|---:|---:|---:|
| raw | 50 | 459 | 80 | 17.43% | 14.34% | 0.056 | 0.240 |
| corrected | 50 | 459 | 77 | 16.78% | 13.73% | 0.056 | 0.260 |
| refined | 50 | 459 | 77 | 16.78% | 13.73% | 0.056 | 0.260 |
| final | 50 | 459 | 76 | 16.56% | 13.57% | 0.056 | 0.260 |

### By category

| category | n | WER | term recall |
|---|---:|---:|---:|
| proper-nouns | 5 | 31.71% | 0.000 |
| control-names | 4 | 12.90% | 0.250 |
| tech-jargon | 6 | 18.64% | 0.000 |
| homophones | 5 | 0.00% | — |
| addresses | 5 | 12.24% | — |
| spelled-runs | 4 | 8.33% | — |
| numbers-dates | 4 | 5.88% | — |
| postal-address | 1 | 0.00% | — |
| commands | 4 | 0.00% | — |
| disfluency | 5 | 26.83% | — |
| self-correction | 6 | 39.62% | — |
| long-form | 1 | 16.67% | 0.000 |

## 2026-08-10T07:25:08Z — tts-samantha/all — apple_live — `refine=off,dict=on`

> **TTS corpus — plumbing check only, not an accuracy claim**

git `c8fd080` · os `25F84` · prompt `9f337b6cd87c093f694672f04327f794509631176edc26cd9fb639b93266b2ec` · dictionary 9 terms · scorer v1 · corpus source `tts`

| stage | n | ref words | errors | WER | CER | term recall | zero-edit |
|---|---:|---:|---:|---:|---:|---:|---:|
| raw | 50 | 459 | 80 | 17.43% | 14.34% | 0.056 | 0.240 |
| corrected | 50 | 459 | 77 | 16.78% | 13.73% | 0.056 | 0.260 |
| refined | 50 | 459 | 77 | 16.78% | 13.73% | 0.056 | 0.260 |
| final | 50 | 459 | 61 | 13.29% | 12.63% | 0.444 | 0.300 |

### By category

| category | n | WER | term recall |
|---|---:|---:|---:|
| proper-nouns | 5 | 14.63% | 0.500 |
| control-names | 4 | 12.90% | 0.250 |
| tech-jargon | 6 | 13.56% | 0.250 |
| homophones | 5 | 0.00% | — |
| addresses | 5 | 10.20% | — |
| spelled-runs | 4 | 8.33% | — |
| numbers-dates | 4 | 5.88% | — |
| postal-address | 1 | 0.00% | — |
| commands | 4 | 0.00% | — |
| disfluency | 5 | 26.83% | — |
| self-correction | 6 | 39.62% | — |
| long-form | 1 | 5.56% | 1.000 |

## 2026-08-10T07:25:08Z — tts-samantha/all — apple_live — `refine=on,dict=off`

> **TTS corpus — plumbing check only, not an accuracy claim**

git `c8fd080` · os `25F84` · prompt `9f337b6cd87c093f694672f04327f794509631176edc26cd9fb639b93266b2ec` · dictionary 9 terms · scorer v1 · corpus source `tts`

| stage | n | ref words | errors | WER | CER | term recall | zero-edit |
|---|---:|---:|---:|---:|---:|---:|---:|
| raw | 50 | 459 | 80 | 17.43% | 14.34% | 0.056 | 0.240 |
| corrected | 50 | 459 | 77 | 16.78% | 13.73% | 0.056 | 0.260 |
| refined | 50 | 459 | 52 | 11.33% | 8.19% | 0.222 | 0.360 |
| final | 50 | 459 | 52 | 11.33% | 8.19% | 0.222 | 0.360 |

### By category

| category | n | WER | term recall |
|---|---:|---:|---:|
| proper-nouns | 5 | 31.71% | 0.000 |
| control-names | 4 | 12.90% | 0.250 |
| tech-jargon | 6 | 6.78% | 0.750 |
| homophones | 5 | 0.00% | — |
| addresses | 5 | 12.24% | — |
| spelled-runs | 4 | 8.33% | — |
| numbers-dates | 4 | 2.94% | — |
| postal-address | 1 | 0.00% | — |
| commands | 4 | 0.00% | — |
| disfluency | 5 | 9.76% | — |
| self-correction | 6 | 22.64% | — |
| long-form | 1 | 16.67% | 0.000 |

## 2026-08-10T07:25:08Z — tts-samantha/all — apple_live — `refine=on,dict=on`

> **TTS corpus — plumbing check only, not an accuracy claim**

git `c8fd080` · os `25F84` · prompt `9f337b6cd87c093f694672f04327f794509631176edc26cd9fb639b93266b2ec` · dictionary 9 terms · scorer v1 · corpus source `tts`

| stage | n | ref words | errors | WER | CER | term recall | zero-edit |
|---|---:|---:|---:|---:|---:|---:|---:|
| raw | 50 | 459 | 80 | 17.43% | 14.34% | 0.056 | 0.240 |
| corrected | 50 | 459 | 77 | 16.78% | 13.73% | 0.056 | 0.260 |
| refined | 50 | 459 | 52 | 11.33% | 8.19% | 0.222 | 0.360 |
| final | 50 | 459 | 40 | 8.71% | 7.70% | 0.556 | 0.380 |

### By category

| category | n | WER | term recall |
|---|---:|---:|---:|
| proper-nouns | 5 | 14.63% | 0.500 |
| control-names | 4 | 12.90% | 0.250 |
| tech-jargon | 6 | 6.78% | 0.750 |
| homophones | 5 | 0.00% | — |
| addresses | 5 | 10.20% | — |
| spelled-runs | 4 | 8.33% | — |
| numbers-dates | 4 | 2.94% | — |
| postal-address | 1 | 0.00% | — |
| commands | 4 | 0.00% | — |
| disfluency | 5 | 9.76% | — |
| self-correction | 6 | 22.64% | — |
| long-form | 1 | 5.56% | 1.000 |

## 2026-08-10T09:19:26Z — tts-samantha/all — apple_live — `refine=off,dict=off`

> **TTS corpus — plumbing check only, not an accuracy claim**

git `1ee83a7` · os `25F84` · prompt `9f337b6cd87c093f694672f04327f794509631176edc26cd9fb639b93266b2ec` · dictionary 9 terms · scorer v1 · corpus source `tts`

| stage | n | ref words | errors | WER | CER | term recall | zero-edit |
|---|---:|---:|---:|---:|---:|---:|---:|
| raw | 50 | 459 | 80 | 17.43% | 14.34% | 0.056 | 0.240 |
| corrected | 50 | 459 | 77 | 16.78% | 13.73% | 0.056 | 0.260 |
| refined | 50 | 459 | 77 | 16.78% | 13.73% | 0.056 | 0.260 |
| final | 50 | 459 | 54 | 11.76% | 7.29% | 0.056 | 0.320 |

### By category

| category | n | WER | term recall |
|---|---:|---:|---:|
| proper-nouns | 5 | 31.71% | 0.000 |
| control-names | 4 | 12.90% | 0.250 |
| tech-jargon | 6 | 18.64% | 0.000 |
| homophones | 5 | 0.00% | — |
| addresses | 5 | 12.24% | — |
| spelled-runs | 4 | 8.33% | — |
| numbers-dates | 4 | 5.88% | — |
| postal-address | 1 | 0.00% | — |
| commands | 4 | 0.00% | — |
| disfluency | 5 | 19.51% | — |
| self-correction | 6 | 3.77% | — |
| long-form | 1 | 16.67% | 0.000 |

## 2026-08-10T09:19:26Z — tts-samantha/all — apple_live — `refine=off,dict=on`

> **TTS corpus — plumbing check only, not an accuracy claim**

git `1ee83a7` · os `25F84` · prompt `9f337b6cd87c093f694672f04327f794509631176edc26cd9fb639b93266b2ec` · dictionary 9 terms · scorer v1 · corpus source `tts`

| stage | n | ref words | errors | WER | CER | term recall | zero-edit |
|---|---:|---:|---:|---:|---:|---:|---:|
| raw | 50 | 459 | 80 | 17.43% | 14.34% | 0.056 | 0.240 |
| corrected | 50 | 459 | 77 | 16.78% | 13.73% | 0.056 | 0.260 |
| refined | 50 | 459 | 77 | 16.78% | 13.73% | 0.056 | 0.260 |
| final | 50 | 459 | 39 | 8.50% | 6.36% | 0.444 | 0.360 |

### By category

| category | n | WER | term recall |
|---|---:|---:|---:|
| proper-nouns | 5 | 14.63% | 0.500 |
| control-names | 4 | 12.90% | 0.250 |
| tech-jargon | 6 | 13.56% | 0.250 |
| homophones | 5 | 0.00% | — |
| addresses | 5 | 10.20% | — |
| spelled-runs | 4 | 8.33% | — |
| numbers-dates | 4 | 5.88% | — |
| postal-address | 1 | 0.00% | — |
| commands | 4 | 0.00% | — |
| disfluency | 5 | 19.51% | — |
| self-correction | 6 | 3.77% | — |
| long-form | 1 | 5.56% | 1.000 |

## 2026-08-10T09:20:42Z — tts-samantha/all — apple_live — `refine=on,dict=off`

> **TTS corpus — plumbing check only, not an accuracy claim**

git `1ee83a7` · os `25F84` · prompt `9f337b6cd87c093f694672f04327f794509631176edc26cd9fb639b93266b2ec` · dictionary 9 terms · scorer v1 · corpus source `tts`

| stage | n | ref words | errors | WER | CER | term recall | zero-edit |
|---|---:|---:|---:|---:|---:|---:|---:|
| raw | 50 | 459 | 80 | 17.43% | 14.34% | 0.056 | 0.240 |
| corrected | 50 | 459 | 77 | 16.78% | 13.73% | 0.056 | 0.260 |
| refined | 50 | 459 | 52 | 11.33% | 8.19% | 0.222 | 0.360 |
| final | 50 | 459 | 42 | 9.15% | 5.54% | 0.222 | 0.380 |

Refine battery: **0.972** (weighted)

### By category

| category | n | WER | term recall |
|---|---:|---:|---:|
| proper-nouns | 5 | 31.71% | 0.000 |
| control-names | 4 | 12.90% | 0.250 |
| tech-jargon | 6 | 6.78% | 0.750 |
| homophones | 5 | 0.00% | — |
| addresses | 5 | 12.24% | — |
| spelled-runs | 4 | 8.33% | — |
| numbers-dates | 4 | 2.94% | — |
| postal-address | 1 | 0.00% | — |
| commands | 4 | 0.00% | — |
| disfluency | 5 | 9.76% | — |
| self-correction | 6 | 3.77% | — |
| long-form | 1 | 16.67% | 0.000 |

## 2026-08-10T09:21:05Z — tts-samantha/all — apple_live — `refine=on,dict=on`

> **TTS corpus — plumbing check only, not an accuracy claim**

git `1ee83a7` · os `25F84` · prompt `9f337b6cd87c093f694672f04327f794509631176edc26cd9fb639b93266b2ec` · dictionary 9 terms · scorer v1 · corpus source `tts`

| stage | n | ref words | errors | WER | CER | term recall | zero-edit |
|---|---:|---:|---:|---:|---:|---:|---:|
| raw | 50 | 459 | 80 | 17.43% | 14.34% | 0.056 | 0.240 |
| corrected | 50 | 459 | 77 | 16.78% | 13.73% | 0.056 | 0.260 |
| refined | 50 | 459 | 52 | 11.33% | 8.19% | 0.222 | 0.360 |
| final | 50 | 459 | 30 | 6.54% | 5.05% | 0.556 | 0.400 |

Refine battery: **0.972** (weighted)

### By category

| category | n | WER | term recall |
|---|---:|---:|---:|
| proper-nouns | 5 | 14.63% | 0.500 |
| control-names | 4 | 12.90% | 0.250 |
| tech-jargon | 6 | 6.78% | 0.750 |
| homophones | 5 | 0.00% | — |
| addresses | 5 | 10.20% | — |
| spelled-runs | 4 | 8.33% | — |
| numbers-dates | 4 | 2.94% | — |
| postal-address | 1 | 0.00% | — |
| commands | 4 | 0.00% | — |
| disfluency | 5 | 9.76% | — |
| self-correction | 6 | 3.77% | — |
| long-form | 1 | 5.56% | 1.000 |

## 2026-08-10T11:15:45Z — tts-samantha/all — apple_live — `refine=off,dict=off`

> **TTS corpus — plumbing check only, not an accuracy claim**

git `cbc7fb5` · os `25F84` · prompt `b2a089b526058cb6b3251381e389c6359144dca20ba78c596d201171810a29bf` · dictionary 9 terms · scorer v1 · corpus source `tts`

| stage | n | ref words | errors | WER | CER | term recall | zero-edit |
|---|---:|---:|---:|---:|---:|---:|---:|
| raw | 54 | 484 | 101 | 20.87% | 18.09% | 0.056 | 0.241 |
| corrected | 54 | 484 | 98 | 20.25% | 17.51% | 0.056 | 0.259 |
| refined | 54 | 484 | 98 | 20.25% | 17.51% | 0.056 | 0.259 |
| final | 54 | 484 | 56 | 11.57% | 7.16% | 0.056 | 0.333 |

### By category

| category | n | WER | term recall |
|---|---:|---:|---:|
| proper-nouns | 5 | 31.71% | 0.000 |
| control-names | 4 | 12.90% | 0.250 |
| tech-jargon | 6 | 18.64% | 0.000 |
| homophones | 5 | 0.00% | — |
| addresses | 5 | 12.24% | — |
| spelled-runs | 4 | 8.33% | — |
| numbers-dates | 4 | 5.88% | — |
| postal-address | 1 | 0.00% | — |
| commands | 4 | 0.00% | — |
| disfluency | 5 | 19.51% | — |
| self-correction | 10 | 5.13% | — |
| long-form | 1 | 16.67% | 0.000 |

## 2026-08-10T11:15:45Z — tts-samantha/all — apple_live — `refine=off,dict=on`

> **TTS corpus — plumbing check only, not an accuracy claim**

git `cbc7fb5` · os `25F84` · prompt `b2a089b526058cb6b3251381e389c6359144dca20ba78c596d201171810a29bf` · dictionary 9 terms · scorer v1 · corpus source `tts`

| stage | n | ref words | errors | WER | CER | term recall | zero-edit |
|---|---:|---:|---:|---:|---:|---:|---:|
| raw | 54 | 484 | 101 | 20.87% | 18.09% | 0.056 | 0.241 |
| corrected | 54 | 484 | 98 | 20.25% | 17.51% | 0.056 | 0.259 |
| refined | 54 | 484 | 98 | 20.25% | 17.51% | 0.056 | 0.259 |
| final | 54 | 484 | 39 | 8.06% | 6.11% | 0.444 | 0.389 |

### By category

| category | n | WER | term recall |
|---|---:|---:|---:|
| proper-nouns | 5 | 14.63% | 0.500 |
| control-names | 4 | 12.90% | 0.250 |
| tech-jargon | 6 | 13.56% | 0.250 |
| homophones | 5 | 0.00% | — |
| addresses | 5 | 10.20% | — |
| spelled-runs | 4 | 8.33% | — |
| numbers-dates | 4 | 5.88% | — |
| postal-address | 1 | 0.00% | — |
| commands | 4 | 0.00% | — |
| disfluency | 5 | 19.51% | — |
| self-correction | 10 | 2.56% | — |
| long-form | 1 | 5.56% | 1.000 |

## 2026-08-10T11:17:32Z — tts-samantha/all — apple_live — `refine=on,dict=off`

> **TTS corpus — plumbing check only, not an accuracy claim**

git `cbc7fb5` · os `25F84` · prompt `b2a089b526058cb6b3251381e389c6359144dca20ba78c596d201171810a29bf` · dictionary 9 terms · scorer v1 · corpus source `tts`

| stage | n | ref words | errors | WER | CER | term recall | zero-edit |
|---|---:|---:|---:|---:|---:|---:|---:|
| raw | 54 | 484 | 101 | 20.87% | 18.09% | 0.056 | 0.241 |
| corrected | 54 | 484 | 98 | 20.25% | 17.51% | 0.056 | 0.259 |
| refined | 54 | 484 | 65 | 13.43% | 10.27% | 0.222 | 0.352 |
| final | 54 | 484 | 44 | 9.09% | 5.60% | 0.222 | 0.389 |

Refine battery: **0.948** (weighted)

### By category

| category | n | WER | term recall |
|---|---:|---:|---:|
| proper-nouns | 5 | 31.71% | 0.000 |
| control-names | 4 | 12.90% | 0.250 |
| tech-jargon | 6 | 6.78% | 0.750 |
| homophones | 5 | 0.00% | — |
| addresses | 5 | 12.24% | — |
| spelled-runs | 4 | 8.33% | — |
| numbers-dates | 4 | 2.94% | — |
| postal-address | 1 | 0.00% | — |
| commands | 4 | 0.00% | — |
| disfluency | 5 | 9.76% | — |
| self-correction | 10 | 5.13% | — |
| long-form | 1 | 16.67% | 0.000 |

## 2026-08-10T11:18:03Z — tts-samantha/all — apple_live — `refine=on,dict=on`

> **TTS corpus — plumbing check only, not an accuracy claim**

git `cbc7fb5` · os `25F84` · prompt `b2a089b526058cb6b3251381e389c6359144dca20ba78c596d201171810a29bf` · dictionary 9 terms · scorer v1 · corpus source `tts`

| stage | n | ref words | errors | WER | CER | term recall | zero-edit |
|---|---:|---:|---:|---:|---:|---:|---:|
| raw | 54 | 484 | 101 | 20.87% | 18.09% | 0.056 | 0.241 |
| corrected | 54 | 484 | 98 | 20.25% | 17.51% | 0.056 | 0.259 |
| refined | 54 | 484 | 65 | 13.43% | 10.27% | 0.222 | 0.352 |
| final | 54 | 484 | 30 | 6.20% | 4.98% | 0.556 | 0.426 |

Refine battery: **0.948** (weighted)

### By category

| category | n | WER | term recall |
|---|---:|---:|---:|
| proper-nouns | 5 | 14.63% | 0.500 |
| control-names | 4 | 12.90% | 0.250 |
| tech-jargon | 6 | 6.78% | 0.750 |
| homophones | 5 | 0.00% | — |
| addresses | 5 | 10.20% | — |
| spelled-runs | 4 | 8.33% | — |
| numbers-dates | 4 | 2.94% | — |
| postal-address | 1 | 0.00% | — |
| commands | 4 | 0.00% | — |
| disfluency | 5 | 9.76% | — |
| self-correction | 10 | 2.56% | — |
| long-form | 1 | 5.56% | 1.000 |

## 2026-08-10T11:48:36Z — tts-accents-v1/all — apple_live — `refine=off,dict=off`

> **TTS corpus — plumbing check only, not an accuracy claim**

git `6fd929f` · os `25F84` · prompt `b2a089b526058cb6b3251381e389c6359144dca20ba78c596d201171810a29bf` · dictionary 9 terms · scorer v1 · corpus source `tts`

| stage | n | ref words | errors | WER | CER | term recall | zero-edit | empty |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| raw | 432 | 3872 | 885 | 22.86% | 18.66% | 0.125 | 0.169 | 0.00% |
| corrected | 432 | 3872 | 878 | 22.68% | 18.30% | 0.125 | 0.174 | 0.00% |
| refined | 432 | 3872 | 878 | 22.68% | 18.30% | 0.125 | 0.174 | 0.00% |
| final | 432 | 3872 | 546 | 14.10% | 8.48% | 0.125 | 0.241 | 0.00% |

### By category (raw stage)

| category | n | WER | term recall | empty |
|---|---:|---:|---:|---:|
| samantha | 54 | 20.87% | 0.056 | 0.00% |
| daniel | 54 | 23.35% | 0.167 | 0.00% |
| karen | 54 | 23.97% | 0.000 | 0.00% |
| moira | 54 | 23.14% | 0.111 | 0.00% |
| rishi | 54 | 23.14% | 0.111 | 0.00% |
| aman | 54 | 22.52% | 0.222 | 0.00% |
| tara | 54 | 22.52% | 0.222 | 0.00% |
| tessa | 54 | 23.35% | 0.111 | 0.00% |

## 2026-08-10T11:48:38Z — tts-stress-v1/all — apple_live — `refine=off,dict=off`

> **TTS corpus — plumbing check only, not an accuracy claim**

git `6fd929f` · os `25F84` · prompt `b2a089b526058cb6b3251381e389c6359144dca20ba78c596d201171810a29bf` · dictionary 9 terms · scorer v1 · corpus source `tts`

| stage | n | ref words | errors | WER | CER | term recall | zero-edit | empty |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| raw | 702 | 6292 | 1677 | 26.65% | 21.67% | 0.064 | 0.192 | 0.00% |
| corrected | 702 | 6292 | 1665 | 26.46% | 21.16% | 0.064 | 0.195 | 0.00% |
| refined | 702 | 6292 | 1665 | 26.46% | 21.16% | 0.064 | 0.195 | 0.00% |
| final | 702 | 6292 | 1168 | 18.56% | 11.83% | 0.064 | 0.256 | 0.00% |

### By category (raw stage)

| category | n | WER | term recall | empty |
|---|---:|---:|---:|---:|
| g0 | 54 | 20.87% | 0.056 | 0.00% |
| g-12 | 54 | 21.49% | 0.056 | 0.00% |
| g-24 | 54 | 22.31% | 0.056 | 0.00% |
| g-36 | 54 | 22.52% | 0.056 | 0.00% |
| clip+6 | 54 | 20.45% | 0.056 | 0.00% |
| wn20 | 54 | 24.38% | 0.167 | 0.00% |
| wn10 | 54 | 27.48% | 0.056 | 0.00% |
| wn5 | 54 | 37.60% | 0.000 | 0.00% |
| bab10 | 54 | 22.73% | 0.056 | 0.00% |
| bandlimit8k | 54 | 23.35% | 0.111 | 0.00% |
| whisper-voice | 54 | 60.33% | 0.000 | 0.00% |
| r120 | 54 | 22.11% | 0.056 | 0.00% |
| r240 | 54 | 20.87% | 0.111 | 0.00% |

## 2026-08-10T11:48:41Z — tts-corners-v1/all — apple_live — `refine=off,dict=off`

> **TTS corpus — plumbing check only, not an accuracy claim**

git `6fd929f` · os `25F84` · prompt `b2a089b526058cb6b3251381e389c6359144dca20ba78c596d201171810a29bf` · dictionary 9 terms · scorer v1 · corpus source `tts`

| stage | n | ref words | errors | WER | CER | term recall | zero-edit | empty |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| raw | 162 | 1452 | 408 | 28.10% | 21.95% | 0.093 | 0.123 | 0.00% |
| corrected | 162 | 1452 | 408 | 28.10% | 21.89% | 0.093 | 0.123 | 0.00% |
| refined | 162 | 1452 | 408 | 28.10% | 21.89% | 0.093 | 0.123 | 0.00% |
| final | 162 | 1452 | 302 | 20.80% | 13.31% | 0.093 | 0.173 | 0.00% |

### By category (raw stage)

| category | n | WER | term recall | empty |
|---|---:|---:|---:|---:|
| aman-g-24-wn10 | 54 | 25.41% | 0.111 | 0.00% |
| aman-r240-bab10 | 54 | 25.41% | 0.056 | 0.00% |
| rishi-g-12-wn5 | 54 | 33.47% | 0.111 | 0.00% |

## 2026-08-10 — ANNOTATION: paste-rung metric correction (R6 discontinuity)

Not a run. As of git `6fd929f`+R6, `release_to_text_ms` and `insert_ms` stop
at the delivery instant (`postCommandV`) instead of after the 500 ms
clipboard-restore sleep, and the success flash fires at delivery. Live paste
`release_to_text_ms` p50 drops ~770 → ~270 ms at this boundary **because the
metric was overstating, not because anything got faster** — a METRIC
CORRECTION, not a speedup. No `release_to_text_ms`/`insert_ms` comparison may
straddle rows written before and after this build without saying so; the
restore window now has its own field (`restore_ms`). Full record:
`docs/notes/deviations.md` §"Paste-rung metric correction".

## 2026-08-10T12:34:50Z — tts-samantha/all — apple_live — `refine=off,dict=off`

> **TTS corpus — plumbing check only, not an accuracy claim**

git `6fd929f` · os `25F84` · prompt `b2a089b526058cb6b3251381e389c6359144dca20ba78c596d201171810a29bf` · dictionary 9 terms · scorer v1 · corpus source `tts`

| stage | n | ref words | errors | WER | CER | term recall | zero-edit | empty |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| raw | 54 | 484 | 101 | 20.87% | 18.09% | 0.056 | 0.241 | 0.00% |
| corrected | 54 | 484 | 98 | 20.25% | 17.51% | 0.056 | 0.259 | 0.00% |
| refined | 54 | 484 | 98 | 20.25% | 17.51% | 0.056 | 0.259 | 0.00% |
| final | 54 | 484 | 56 | 11.57% | 7.16% | 0.056 | 0.333 | 0.00% |

### By category

| category | n | WER | term recall | empty |
|---|---:|---:|---:|---:|
| proper-nouns | 5 | 31.71% | 0.000 | 0.00% |
| control-names | 4 | 12.90% | 0.250 | 0.00% |
| tech-jargon | 6 | 18.64% | 0.000 | 0.00% |
| homophones | 5 | 0.00% | — | 0.00% |
| addresses | 5 | 12.24% | — | 0.00% |
| spelled-runs | 4 | 8.33% | — | 0.00% |
| numbers-dates | 4 | 5.88% | — | 0.00% |
| postal-address | 1 | 0.00% | — | 0.00% |
| commands | 4 | 0.00% | — | 0.00% |
| disfluency | 5 | 19.51% | — | 0.00% |
| self-correction | 10 | 5.13% | — | 0.00% |
| long-form | 1 | 16.67% | 0.000 | 0.00% |

## 2026-08-10T12:34:50Z — tts-samantha/all — apple_live — `refine=off,dict=on`

> **TTS corpus — plumbing check only, not an accuracy claim**

git `6fd929f` · os `25F84` · prompt `b2a089b526058cb6b3251381e389c6359144dca20ba78c596d201171810a29bf` · dictionary 9 terms · scorer v1 · corpus source `tts`

| stage | n | ref words | errors | WER | CER | term recall | zero-edit | empty |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| raw | 54 | 484 | 101 | 20.87% | 18.09% | 0.056 | 0.241 | 0.00% |
| corrected | 54 | 484 | 98 | 20.25% | 17.51% | 0.056 | 0.259 | 0.00% |
| refined | 54 | 484 | 98 | 20.25% | 17.51% | 0.056 | 0.259 | 0.00% |
| final | 54 | 484 | 39 | 8.06% | 6.11% | 0.444 | 0.389 | 0.00% |

### By category

| category | n | WER | term recall | empty |
|---|---:|---:|---:|---:|
| proper-nouns | 5 | 14.63% | 0.500 | 0.00% |
| control-names | 4 | 12.90% | 0.250 | 0.00% |
| tech-jargon | 6 | 13.56% | 0.250 | 0.00% |
| homophones | 5 | 0.00% | — | 0.00% |
| addresses | 5 | 10.20% | — | 0.00% |
| spelled-runs | 4 | 8.33% | — | 0.00% |
| numbers-dates | 4 | 5.88% | — | 0.00% |
| postal-address | 1 | 0.00% | — | 0.00% |
| commands | 4 | 0.00% | — | 0.00% |
| disfluency | 5 | 19.51% | — | 0.00% |
| self-correction | 10 | 2.56% | — | 0.00% |
| long-form | 1 | 5.56% | 1.000 | 0.00% |

## 2026-08-10T12:36:27Z — tts-samantha/all — apple_live — `refine=on,dict=off`

> **TTS corpus — plumbing check only, not an accuracy claim**

git `6fd929f` · os `25F84` · prompt `b2a089b526058cb6b3251381e389c6359144dca20ba78c596d201171810a29bf` · dictionary 9 terms · scorer v1 · corpus source `tts`

| stage | n | ref words | errors | WER | CER | term recall | zero-edit | empty |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| raw | 54 | 484 | 101 | 20.87% | 18.09% | 0.056 | 0.241 | 0.00% |
| corrected | 54 | 484 | 98 | 20.25% | 17.51% | 0.056 | 0.259 | 0.00% |
| refined | 54 | 484 | 65 | 13.43% | 10.27% | 0.222 | 0.352 | 0.00% |
| final | 54 | 484 | 44 | 9.09% | 5.60% | 0.222 | 0.389 | 0.00% |

Refine battery: **0.948** (weighted)

### By category

| category | n | WER | term recall | empty |
|---|---:|---:|---:|---:|
| proper-nouns | 5 | 31.71% | 0.000 | 0.00% |
| control-names | 4 | 12.90% | 0.250 | 0.00% |
| tech-jargon | 6 | 6.78% | 0.750 | 0.00% |
| homophones | 5 | 0.00% | — | 0.00% |
| addresses | 5 | 12.24% | — | 0.00% |
| spelled-runs | 4 | 8.33% | — | 0.00% |
| numbers-dates | 4 | 2.94% | — | 0.00% |
| postal-address | 1 | 0.00% | — | 0.00% |
| commands | 4 | 0.00% | — | 0.00% |
| disfluency | 5 | 9.76% | — | 0.00% |
| self-correction | 10 | 5.13% | — | 0.00% |
| long-form | 1 | 16.67% | 0.000 | 0.00% |

## 2026-08-10T12:36:55Z — tts-samantha/all — apple_live — `refine=on,dict=on`

> **TTS corpus — plumbing check only, not an accuracy claim**

git `6fd929f` · os `25F84` · prompt `b2a089b526058cb6b3251381e389c6359144dca20ba78c596d201171810a29bf` · dictionary 9 terms · scorer v1 · corpus source `tts`

| stage | n | ref words | errors | WER | CER | term recall | zero-edit | empty |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| raw | 54 | 484 | 101 | 20.87% | 18.09% | 0.056 | 0.241 | 0.00% |
| corrected | 54 | 484 | 98 | 20.25% | 17.51% | 0.056 | 0.259 | 0.00% |
| refined | 54 | 484 | 65 | 13.43% | 10.27% | 0.222 | 0.352 | 0.00% |
| final | 54 | 484 | 30 | 6.20% | 4.98% | 0.556 | 0.426 | 0.00% |

Refine battery: **0.948** (weighted)

### By category

| category | n | WER | term recall | empty |
|---|---:|---:|---:|---:|
| proper-nouns | 5 | 14.63% | 0.500 | 0.00% |
| control-names | 4 | 12.90% | 0.250 | 0.00% |
| tech-jargon | 6 | 6.78% | 0.750 | 0.00% |
| homophones | 5 | 0.00% | — | 0.00% |
| addresses | 5 | 10.20% | — | 0.00% |
| spelled-runs | 4 | 8.33% | — | 0.00% |
| numbers-dates | 4 | 2.94% | — | 0.00% |
| postal-address | 1 | 0.00% | — | 0.00% |
| commands | 4 | 0.00% | — | 0.00% |
| disfluency | 5 | 9.76% | — | 0.00% |
| self-correction | 10 | 2.56% | — | 0.00% |
| long-form | 1 | 5.56% | 1.000 | 0.00% |

## 2026-08-10 — SHIP VERIFY v2.3.0: matrix + deck reproduction (not a new baseline)

Post-integration verification with all four robustness tracks in the tree
(working tree over git `6fd929f`, macOS build `25F84`).

**Matrix (tts-samantha, 4 configs, live model, cached ASR under the
osBuild-keyed hash `00449f59`):** the 12:34–12:36Z sections above. Every
final-stage number reproduced the `BASELINE.json` accepted values exactly —
WER/CER/term-recall/zero-edit byte-identical across all four configs, refine
battery 0.9485 (3/3 passes identical) — zero violations, zero drift.

**Robustness deck (`eval deck`, raw stage, 1,296 clips, all cached):**

| component | verify run | recorded baseline | verdict |
|---|---:|---:|---|
| ri-noise | +16.7 pts (wn5 − g0) | +16.7 ± 3 | green |
| ri-accent | +3.1 pts (karen) | +3.1 ± 2 | green, same worst voice |
| ri-level | +1.7 pts | +1.7, alarm > +4 | green |
| ri-empty | 0.00% over 1,296 | 0 exact | green |
| tone | — | — | unmeasured until human-v1, as designed |

`eval deck` exit 0. Per-cell tables matched the 11:48Z first-run sections
above cell-for-cell (same transcripts — the cache key held, which is itself
the A-1 provenance property doing its job). `WISPRIT_REHEARSAL=1` battery
0.9485 against floor 0.8885.
