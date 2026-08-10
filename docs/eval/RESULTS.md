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
