# The robustness matrix — measuring "any accent, any volume, any tone" locally, today

Research for Topic 3 of the robustness program. Written 10 Aug 2026 against git
`d6a3387`-era tree, macOS 25F84 (26.5.2), M4. **Everything measured below was
measured on this machine with the repo's own harness** (`.build/debug/WispritMac
eval`, pointed at a scratchpad fake root via `WISPRIT_EVAL_ROOT` — the repo tree
was not touched). Pilot corpora and run artifacts lived in the session
scratchpad and are ephemeral; every recipe needed to regenerate them is in this
document.

**TTS banner, up front and non-negotiable (this repo's own rule,
`docs/eval/RESULTS.md`):** every number in this document from synthetic audio is
a *plumbing and direction-finding* number, never an accuracy claim. This
document extends the spikes-s1 caveat discipline; nothing here fights it.

---

## 1. Verdicts first

1. **The matrix is cheap. Stunningly cheap.** The unpaced two-phase runner
   transcribes ~35× faster than real time on this machine: **50 fresh clips
   (167 s of audio) in 4.8 s wall; 950 pilot clips in 93 s.** The binding cost
   of synthetic robustness measurement is corpus *generation* (~3 min for 950
   clips, mostly `say`), not ASR. Re-scoring is free (cached, sha-keyed).
   Anyone arguing the matrix is too expensive to run per-release is wrong by
   two orders of magnitude.
2. **I ran a 950-clip pilot of the matrix end-to-end today.** Headline
   direction-finding results (final stage, `refine=off,dict=off`, details §4):
   accent voices cost **+2.4 to +8.3 WER points** over Samantha (en-IN voices
   worst); pure digital gain is a **non-axis down to −36 dB** (+2.4 pts, zero
   empty transcripts, zero timeouts); hard clipping at +6 dB is a **measured
   no-op**; **additive noise is the axis that matters** (SNR 5 dB: 11.8% →
   28.5% WER, a 2.4× degradation).
3. **The volume axis as commonly imagined ("scale the PCM") is mostly a
   fantasy** — Apple's frontend normalizes level almost perfectly. Real "too
   quiet" is *low SNR*, not low gain. The physically honest quiet cell is
   `gain-down + fixed-level noise floor`, which the matrix below encodes.
4. **The scoreboard already carries per-axis breakdown** via the manifest
   `category` field — encode `condition` as the category and the per-axis table
   falls out of the existing `eval score` renderer with zero code. Three real
   gaps remain: the category table renders only the `final` stage; there is no
   empty-transcript rate metric; and **the ASR cache does not key on osBuild**,
   so a macOS update silently serves stale transcripts under a new provenance
   stamp (§6.3 — this is a genuine footgun, found reading `EvalPaths.swift`).
5. **Live telemetry says this user dictates 12–14 dB quieter than the TTS
   corpus** (`~/.wisprit/metrics.log`, §7): real `peak_level` 0.039–0.233
   (median 0.156) vs 0.59–0.77 for unscaled `say` output. Every TTS number
   published so far was measured in a level regime the user never occupies.
   The matrix's −12 dB cell, not its 0 dB cell, is the realistic one.
6. **The calibration ladder is: synthetic matrix → public real-speech corpora →
   human-v1.** The manifest schema already anticipates the middle rung
   (`CorpusSource.librispeech`). Synthetic axes become trustworthy tripwires
   only after the human passes confirm they rank-order conditions the same way
   (§8).

---

## 2. What exists today (inventory, so the argument stage doesn't re-litigate it)

| piece | where | state |
|---|---|---|
| Two-phase runner (`asr` cached by audio sha → `stages` replay → `score`/`report`) | `Sources/WispritMac/Eval/EvalRunner.swift` | working; measured 0.098 s/clip ASR unpaced |
| Corpus schema: `id, audio, sha256, ref, category, speaker, source, mic, split, expect{terms, refineBypass}, verified` | `Sources/WispritEval/Corpus.swift` | `category` drives the per-axis table; `source` is mandatory (TTS banner); `mic`/`split` exist for human passes |
| Per-category breakdown (WER + term recall) | `EvalScoring.categories` | **final stage only** (§6.1) |
| Baseline bands per (corpus, config, stage, metric) | `docs/eval/BASELINE.json`, `Scoreboard.compare` | new corpora get their own bands; exit 3 on violation |
| TTS-caveat discipline | `docs/eval/RESULTS.md` banner rule, `spikes-s1.md` §"Caveat carried" | extended here, not fought |
| tts-v1 script pack | `tools/eval/scripts/tts-v1.txt` | **50 lines, 12 categories** (incl. 6 self-correction added after the last published RESULTS section, which shows n=44) |
| human-v1 protocol, recording pending | `tools/eval/scripts/human-v1/README.md` | 135 utterances × 13 files × 3 passes (internal / Bluetooth / real-conditions ~70-utterance subset); ~25 min/pass |
| Parakeet channel, built and gated | `docs/research/spikes-parakeet.md` | second engine for the matrix eventually; decode ~82 ms/clip, so a per-engine matrix costs about the same again |
| `WISPRIT_EVAL_ROOT` | `EvalPaths.repoRoot` | lets the whole matrix run against a disposable root — this is how the pilot ran without touching the repo |

---

## 3. The voice inventory on this machine (`say -v '?'`, run 10 Aug 2026)

English voices actually installed, by locale:

| locale | voices installed | note |
|---|---|---|
| en_US | Samantha, plus Albert/Fred/Kathy/Junior/Ralph (legacy MacinTalk) and the novelty set (Bad News, Bahh, Bells, Boing, Bubbles, Cellos, Good News, Jester, Organ, Superstar, Trinoids, **Whisper**, Wobble, Zarvox), plus Eddy/Flo/Grandma/Grandpa/Reed/Rocko/Sandy/Shelley (US) | Samantha is the only production-quality en_US voice installed |
| en_GB | **Daniel**, plus Eddy/Flo/Grandma/Grandpa/Reed/Rocko/Sandy/Shelley (UK) | |
| en_AU | **Karen** | |
| en_IE | **Moira** | |
| en_IN | **Rishi, Aman, Tara** | three distinct en-IN voices — the best-covered accent |
| en_ZA | **Tessa** | |

So **8 usable accent voices ship installed**: Samantha (US), Daniel (GB), Karen
(AU), Moira (IE), Rishi/Aman/Tara (IN), Tessa (ZA). All verified synthesizing
`LEI16@16000` WAVE (the pipeline-native format) today.

**Quality-tier caveat that the adversarial panel will raise, so raise it
first:** none of the installed voices shows an "(Enhanced)"/"(Premium)" suffix
in `say -v '?'` — these are the **compact** tiers. Part of any per-voice WER
gap is therefore synthesis *fidelity*, not accent. System Settings →
Accessibility → Spoken Content → System Voice → Manage Voices offers
Enhanced/Premium downloads of the same names (Daniel, Karen, Moira, Rishi,
Tessa at minimum; the Vocalizer catalog also carries additional en-GB/AU/IN/US
voices such as Kate, Serena, Oliver, Lee, Matilda, Veena, Isha, Ava — exact
availability must be read off Settings on this OS build, there is no CLI to
enumerate undownloaded voices). Downloaded voices become `say`-addressable
(e.g. "Daniel (Enhanced)"). **Siri voices never become `say`-addressable** and
are out of reach for this matrix. Recommendation: download the
Enhanced/Premium variant of each of the 8 accents once (~100–500 MB each,
one-time, still fully local) and pin the matrix to the highest installed tier
per accent; record the tier in the manifest `speaker` field
(`tts-daniel-enhanced`). The novelty voices are excluded from the accent axis
(they are caricatures of *machines*, not accents) — with one optional
exception: **Whisper** is a genuinely whisper-mode voice and is the only
synthetic probe of the "tone" axis available at all (§5.6).

---

## 4. The pilot: the matrix was run today, end-to-end, with the repo's own scorer

Design: two corpora in a scratchpad fake root, scripts = the full 50-line
tts-v1 pack, manifest `category` = condition so the existing per-category table
becomes the per-axis table. Scored by the real harness (`.asr` normalization
profile, micro-averaged WER — not an approximation).

**Corpus A `tts-accents-pilot`** — 8 voices × 50 scripts, `say -r 175`,
`LEI16@16000`. 400 clips.
**Corpus B `tts-stress-pilot`** — Samantha × 11 conditions × 50 scripts. 550
clips. Conditions: `g0` (as-synthesized), `g-12/g-24/g-36` (PCM × 10^(dB/20)),
`clip+6` (×2.0 then int16 clamp — every clip's true peak is 0.72–0.83 at g0, so
this clips hard), `wn20/wn10/wn5` (white Gaussian noise added to the **g-12**
signal at RMS-SNR 20/10/5 dB), `bab10` (multi-voice babble at SNR 10: a track
concatenated from Daniel/Karen/Rishi clips reading *different* scripts, tiled
and mixed onto g-12), `r120/r240` (fresh `say -r 120 / 240` synthesis).

Measured costs (M4): generation 168 s for all 950 clips (400 `say` calls
threaded ×6, 550 pure-Python PCM variants + sha256). ASR: 38.8 s (400 clips) +
54.1 s (550 clips). Stages `refine=off` + score: seconds.

### Results (final stage, `refine=off,dict=off`, n=50 clips ≈ 420 ref words per cell)

> **TTS corpus — plumbing and direction-finding only, not an accuracy claim.**

Accent axis:

| voice (compact tier) | WER | Δ vs Samantha |
|---|---:|---:|
| samantha (en_US) | 11.76% | — |
| daniel (en_GB) | 14.16% | +2.4 |
| moira (en_IE) | 14.38% | +2.6 |
| rishi (en_IN) | 14.38% | +2.6 |
| tessa (en_ZA) | 14.60% | +2.8 |
| karen (en_AU) | 15.47% | +3.7 |
| tara (en_IN) | 18.30% | +6.5 |
| aman (en_IN) | 20.04% | +8.3 |

Stress axes (Samantha):

| condition | WER | eval `peakLevel` (median) | empty | timeouts |
|---|---:|---:|---:|---:|
| g0 | 11.76% | 0.998 | 0 | 0 |
| clip+6 (hard-clipped) | 11.33% | 1.000 | 0 | 0 |
| r240 (fast) | 12.20% | 0.964 | 0 | 0 |
| g-12 | 12.85% | 0.251 | 0 | 0 |
| r120 (slow) | 13.07% | 0.982 | 0 | 0 |
| g-24 | 13.73% | 0.063 | 0 | 0 |
| g-36 | 14.16% | 0.016 | 0 | 0 |
| wn20 (SNR 20) | 15.25% | 0.252 | 0 | 0 |
| bab10 (babble SNR 10) | 15.25% | 0.255 | 0 | 0 |
| wn10 (SNR 10) | 18.95% | 0.256 | 0 | 0 |
| **wn5 (SNR 5)** | **28.54%** | 0.267 | 0 | 0 |

Internal consistency check: stress `g0` = accents `samantha` = 11.76% (same
audio recipe through two independently generated corpora). Statistical honesty:
at ~420 ref words/cell the standard error on a ~13% WER is ≈1.6 points —
**deltas under ~2 points (daniel, r240, clip+6) are within noise; the en-IN
gaps (+6.5, +8.3) and the whole noise axis (+3.5 to +16.8) are solidly real.**
Every cell is deterministic given the same audio and OS build (refine off), so
these reproduce exactly until the OS model changes.

What the pilot *proves*: the mechanism works end to end today — generation,
manifests, sha-keyed caching, per-axis scoring — and the axes separate cleanly.
What it *cannot* prove: that any of these numbers predict human-speech
behaviour (§5, §8).

---

## 5. What each axis can and cannot conclude

### 5.1 Accents (TTS) — direction-finding only, with a named confound
Mechanism: an accented TTS voice realizes different phoneme inventories, vowel
qualities and lexical stress; the recognizer's handling of those realizations
is genuinely exercised. But (a) TTS accents are *caricatures* — clean,
canonical, zero L2 disfluency, none of the phonetic variance of real speakers;
(b) the compact-voice fidelity confound (§3) means part of each gap is
synthesis quality. A large per-voice gap (aman +8.3) is a **flag worth
chasing**; a small gap is **not evidence of accent robustness**. Equality
across voices would not license "any accent works". Directional use only:
rank-ordering, regression tripwires, and before/after deltas when an
accent-relevant change lands (e.g. Parakeet, which was trained on far more
accent-diverse data — a measurable prediction: Parakeet's per-voice spread on
this same corpus should be narrower than apple_live's; the corpus can test that
the day the channel is measured, at ~82 ms/clip).

### 5.2 Volume (digital gain) — physically real, and measured to be a solved axis
Scaling PCM is *exactly* what a lower mic gain delivers, so this axis
transfers. And the measured answer is: Apple's frontend normalizes level so
well that −36 dB (eval level 0.016 — well below the quietest real utterance in
metrics.log, 0.039) costs only +2.4 points and produces **zero** empty
transcripts. Two consequences. First: **the "quiet user" failure mode is not
gain, it is SNR** — a real quiet recording has the same room/electronics noise
floor under a smaller signal. Digital gain scales the (near-zero) TTS noise
floor down with the signal, which is physically wrong for simulating quiet
speech. The honest quiet cell is `g-24 + noise at fixed absolute level`,
i.e. exactly the `wn*`-on-`g-12` construction the pilot used. Second: the gain
axis is still worth keeping (cheap) as a **capture-path tripwire** — it holds
flat today, so any future regression (an AGC change, a resampler bug like the
2026-08-05 Bluetooth 24 kHz starvation incident in `spikes-s1.md`) trips it
while clean cells stay green.

### 5.3 Clipping — physically real, measured harmless at 2×
Int16 clamp after ×2 gain is the same nonlinearity a hot mic produces. Measured
no-op (11.33% vs 11.76%). Keep one cell (it costs nothing) but stop theorizing
about near-clip robustness — on this engine, today, it is a non-problem.
Caveat: TTS speech is spectrally cleaner than real speech; real clipping
interacts with room noise. The human real-conditions pass owns the final word.

### 5.4 Additive noise — the axis that matters, and the most transferable
Additive mixing at controlled SNR is physically real for background noise
(modulo reverb — see below). Measured: the engine degrades gracefully to SNR 10
and falls off a cliff by SNR 5 (28.5%, 2.4×). Babble at SNR 10 was *milder*
than white at SNR 10 (15.25 vs 18.95) — plausibly because babble energy is
bursty and leaves spectral gaps; white noise is a *harsher* test at equal SNR.
Both belong in the matrix: white for a controlled dial, babble (buildable
entirely locally from other TTS voices, as the pilot did) as the café proxy.
Two named gaps: **no reverb** (a real café at 60 cm convolves the voice with a
room impulse response; additive-only noise understates the damage — the
human-v1 pass-3 protocol at 60 cm is the ground truth here), and SNR computed
over whole-clip RMS (including silences) — fine for comparability, stated so
nobody thinks it's speech-active SNR.

### 5.5 Rate — weakest synthetic axis after tone
`say -r` stretches/compresses phone durations without the coarticulation,
reduction and slurring of real fast speech. Measured near-flat (+0.4/+1.3 pts,
within ~noise). Conclude nothing beyond "the engine doesn't trip over uniform
tempo change". Real-rate robustness comes only from human pass 3 ("faster than
passes 1 and 2. Real dictation is quicker than reading" — the protocol already
mandates it).

### 5.6 Tone — the axis synthetic audio mostly cannot reach
Pitch, prosody, vocal effort (whisper/shout), emotion: `say` offers no honest
control (embedded `[[pbas]]`/`[[rate]]` TUNE commands work only on legacy
MacinTalk voices, which are useless as speech). Two cheap probes exist —
the **Whisper** novelty voice (a real whisper-mode synthesis: worth one 50-clip
cell as a canary for low-energy phonation) and gain (already covered) — and
after that this axis belongs entirely to the human corpus. Say so in the
scoreboard rather than pretending coverage: the robustness index (§6.2) should
list "tone: unmeasured until human-v1" explicitly.

### 5.7 The axis nobody asked for but the incident log demands: bandwidth/codec
The worst live failure recorded (5 consecutive empties, 2026-08-05, root-caused
in spikes-s1) was a Bluetooth device dropping the input rate to 24 kHz —
a *bandwidth/resampling* failure, not accent/volume/tone. Synthetically cheap:
resample base clips 16 kHz → 8 kHz → 16 kHz (HFP-like band-limiting). Add one
cell. Prediction: today it costs a few points; a capture-path regression makes
it explode while clean cells stay green. The human Bluetooth pass (pass 2,
"not optional" per the README) is the real-world calibration.

---

## 6. The production matrix, its size, and the scoring additions

### 6.1 Corpus design (concrete recommendation)

Full cross-product is unnecessary and muddies attribution. Ship a **star
design + worst-case corners**, one corpus per axis family, `category` =
condition (this is the zero-code path; a dedicated `condition` manifest field
is cleaner long-term but touches `Corpus.swift`/`EvalScoring` — defer until the
schema is next opened anyway):

| corpus | cells | clips | one-time gen | ASR (measured rate) |
|---|---|---:|---:|---:|
| `tts-accents-v1` | 8 voices (highest installed tier) × 50 | 400 | ~3 min | ~40 s |
| `tts-stress-v1` | g0, g-12, g-24, g-36, clip+6, wn20/wn10/wn5 (on g-12), bab10, bandlimit8k, whisper-voice, r120, r240 | 650 | ~2 min | ~65 s |
| `tts-corners-v1` | worst accent (aman) × g-24 × wn10; aman × r240 × bab10; rishi × wn5 — 3 corner cells | 150 | ~1 min | ~15 s |
| **total** | | **1,200** | **~6 min** | **~2 min** |

Storage: 1,200 × ~3.35 s × 32 KB/s ≈ **130 MB**, gitignored like all corpus
audio (manifests committed, `generate` script committed — same contract as
`tts-samantha/generate.sh`, including the `--force`-only regeneration rule so
sha-keyed caches survive re-runs).

Runtime accounting, stated honestly:
- **ASR passes: ~2 min per engine** for the whole matrix (measured 0.098
  s/clip). Per-engine: apple_live today; ×2 when the Parakeet channel is
  measured; the `dictation` engine (`VocabularyChannel`) is slower per clip —
  budget separately if it joins.
- **Stages `refine=off` + score + report: seconds.** Free to re-run on every
  pipeline change — this is the cached-two-phase payoff: the 1,200 transcripts
  are transcribed once per (audio, engine, settings, **OS build** — see 6.3)
  and re-scored forever.
- **Stages `refine=on`: ~0.45 s/clip** (measured on the repo runs: ai_ms) →
  ~9 min per config over 1,200 clips, and stochastic. Run refine-on over the
  matrix on demand, not per-commit; the robustness axes are mostly an
  engine/capture question and `refine=off` rows are deterministic.
- Full re-transcription is only owed when the OS model or engine settings
  change. `--realtime` stays off (spike-verified: same samples, same text; it
  only buys latency numbers at 1 wall-second per audio-second — 67 min for
  this matrix — pay it only for latency studies).

### 6.2 Scoring additions

1. **Per-axis table at raw stage, not just final.** `EvalScoring.categories`
   renders the category table from the `final` stage only
   (`EvalScoring.swift:130`). Robustness axes mostly attack the *engine*; the
   final-stage table conflates engine damage with pipeline repair. Add the same
   table at `raw` (or a `--stage` flag on `score`). Cheap; pure; testable.
2. **Empty-transcript rate as a first-class metric.** The live failure mode
   the user actually hits (`outcome: empty`, 17% of live utterances, §7) is
   invisible in WER (an empty hypothesis scores as deletions, indistinguishable
   from garbled text) and absent from `StageMetrics`. Add `emptyRate` per
   stage and per category. The pilot's all-zeros across 950 stressed clips is
   the baseline band: **any** nonzero empty rate in the matrix is news.
3. **Robustness index, versioned as `robustness-deck v1`.** One scalar worth
   tracking release-over-release, defined over a frozen cell list, micro-WER,
   raw stage, `refine=off,dict=off`:
   - `RI-noise` = WER(wn5) − WER(g0)  — measured today: **+16.8 pts**
   - `RI-accent` = max-over-voices WER − Samantha WER — today: **+8.3 pts**
   - `RI-level` = max(WER(g-36), WER(clip+6)) − WER(g0) — today: **+2.4 pts**
   - `RI-empty` = empty rate over the whole deck — today: **0**
   - tone: **unmeasured until human-v1** (print the row anyway, as "—").
   Report the four components, not a blended scalar — a blend hides which axis
   regressed, and the panel would rightly ask what a 0.3-weighted accent point
   means. Baseline bands slot into the existing `BASELINE.json` mechanism per
   (corpus, config); wider tolerances than clean corpora (these cells sit on
   the model's cliff edge — wn5 especially will move across OS builds; that
   volatility is *signal*, it is what the deck exists to catch).
4. **Fold osBuild into the ASR cache key.** `EvalPaths.settingsHash` hashes
   locale/engine/timeout/term-limit but not the OS build, while DEFINITIONS.md
   itself documents that macOS point releases replace the model ("26.4 rebuilt
   it"). Today, after an OS update, `eval asr` serves every cached transcript
   from the *old* model and `report` stamps the *new* `osBuild` on the row —
   a provenance lie the scoreboard was explicitly designed to prevent. One
   line in `settingsHash` fixes it and correctly invalidates every cache. (The
   cost: a full re-transcribe per OS update — 2 minutes, see above.)
5. **Manifest hygiene for the matrix:** keep `expect.terms` in the accents
   corpus (term recall per voice is the Phase-3/4 biasing metric cut by
   accent); keep script categories recoverable by id prefix so content-category
   analysis stays possible even while `category` carries the condition.

### 6.3 What the matrix does NOT need (fantasy options, killed by name)

- **Training/fine-tuning Apple's acoustic model.** No API exists, on any tier.
  SpeechAnalyzer models arrive with the OS and are replaced by the OS. Dead.
- **`contextualStrings` biasing on the live path as a robustness lever.**
  Measured inert for `SpeechTranscriber` (spike S1, `docs/notes/deviations.md`
  §4). Biasing exists only on the `dictation`/Parakeet channels. Dead for live.
- **Higher-fidelity synthetic accents via local voice-cloning TTS (XTTS et
  al.).** Gigabytes of models and hours of setup to upgrade a caricature to a
  better caricature, while real accented speech is a free download away (§8.1)
  and human-v1 is the actual answer. Not worth it now; revisit only if the
  middle rung proves unusable.
- **Real-time-paced matrix runs.** Same transcripts, 35× the wall time.
  Measured and documented in the runner itself. Dead for accuracy work.
- **A blended single-number robustness score.** Hides the regressing axis;
  killed in favor of the four-component deck (§6.2.3).
- **Treating +6 dB/clipping as a live concern on this engine** — measured
  no-op; keep the cheap cell, stop arguing about it.

---

## 7. Live telemetry: what this user's real conditions already say

`~/.wisprit/metrics.log`, read 10 Aug 2026: **369 utterances, 2026-07-15 →
2026-08-10.** Engines: apple_live 357, mlx_whisper 5, apple_dictation 7.

- **Outcomes: paste 251, type 33, im_streaming 14, vocab_retro 7, empty 64 —
  a 17.3% empty rate.** Empty-rate by day is improving but noisy: 41% on
  07-15, 22% 07-16, then typically 0–25%, most recently 5% (08-09, n=22) and
  1/9 (08-10).
- **The empties are mostly sub-second taps:** 47/64 had `held_ms` < 1 s
  (median 628 ms) vs a 10.1 s median hold for text-producing utterances. Those
  are accidental/aborted presses, not recognition failures — a reason the
  empty-rate metric must be reported alongside a hold-duration split, or it
  slanders the engine.
- **8 empties held ≥ 2 s are the real losses**, including a **19.4 s hold that
  produced nothing** (07-16 15:09) and a 4-in-2-minutes cluster on 08-05
  16:16–16:17 — the documented Bluetooth 24 kHz starvation incident
  (spikes-s1). The longest consecutive-empty run is 12 (07-15, first day,
  pre-fixes). `timed_out` is true on 25 rows, all of them empties: the
  finalize watchdog and the empty outcome are the same event class live.
- **`peak_level` exists on only the 8 most recent rows** (field landed
  ~08-06): 0.039–0.233, median 0.156 (this is `PcmFormat.level` = RMS×4, the
  same statistic the eval harness stamps per clip — deliberately comparable).
  The one `empty_reason` row so far: `produced_nothing` at level 0.0388 with
  785 ms of audio — short *and* quiet, confounded.
- **The calibration this gives the matrix:** unscaled `say` output measures
  0.59–0.77 on the same scale — the TTS corpus as generated is **12–14 dB
  hotter than this user's real speech**. The matrix's g-12 cell (level ≈ 0.25)
  brackets the user's loud end; g-24 (0.063) sits at the user's median-to-quiet
  range; the user's observed floor (0.039) is *between* the g-24 and g-36
  cells, both of which transcribe fine. Conclusion: at this user's real
  levels, level alone is not the problem — consistent with §5.2.

Instrumentation asks (mechanism, prediction, cost — all small):
- `peak_level` + `audio_ms` on **every** row (they exist; 361/369 rows predate
  them). Prediction: the empty/held<1s cluster shows normal levels (finger
  slips), the held≥2s empties show low level or short `audio_ms` (capture
  loss). Cost: none, the fields are already being written by current builds.
- A **noise-floor estimate** per utterance (RMS of the quietest ~300 ms
  window): turns live audio into an (level, floor) pair → an SNR proxy →
  directly maps each real utterance onto the matrix's noise axis. That is the
  bridge that lets metrics.log validate wn-cell relevance without recording
  anyone. Cost: a few lines in the capture path, one field per row.

---

## 8. The calibration ladder: how synthetic numbers become trustworthy

### 8.1 Middle rung the schema already anticipates: public real-speech corpora
`CorpusSource` enumerates `librispeech` today. A one-time download (fully
local thereafter, license-clean) buys real human speech before any recording
session happens: LibriSpeech test-clean/test-other (read US English, the
standard easy/hard pair), and for the accent axis specifically **L2-ARCTIC**
(24 non-native speakers, 6 L1 backgrounds) or Mozilla **Common Voice** English
filtered by its self-reported accent label (India, Scotland, southern-US...).
Caveats stated plainly: read speech, clean mics, not push-to-talk shaped, refs
are verbatim (no formatting targets — score raw stage with `.asr` profile
only, term recall inapplicable). What it is for: checking that the *synthetic
accent ordering* survives contact with real accented voices (does apple_live
really degrade more on Indian-accented English than on British?), and giving
the noise axis a real-speech replication (mix the same wn/bab conditions onto
LibriSpeech clips — additive noise composes with real speech exactly as with
TTS). This rung is hours of work, not days, and it is the cheapest honest
answer to "TTS accents are caricatures".

### 8.2 Ground truth: human-v1 (recording pending)
The protocol (`tools/eval/scripts/human-v1/README.md`) already encodes the
robustness passes: pass 1 internal-quiet, pass 2 Bluetooth ("not optional" —
it is the only pass that can see the 24 kHz class of failure), pass 3
real-conditions (~70-utterance subset, café/music background, 60 cm, faster
pace). Three speakers minimum, accent spread explicitly requested, split by
speaker with spk01=dev. How it calibrates the matrix, concretely:

- **Accent axis:** per-speaker WER spread on held speakers vs per-voice spread
  in `tts-accents-v1`. The synthetic axis is validated as a tripwire if the
  *direction* agrees (accented held speakers degrade where accented voices
  degrade, category-wise); it is never promoted to an accuracy claim.
- **Volume/noise axes:** pass 3 vs pass 1 delta per speaker is the real
  number; the matrix's (g-24 + wn10)-style cells should bracket it. If pass-3
  damage lands far outside the synthetic bracket, the missing physics is
  reverb/distance — add an IR-convolution cell then, not before.
- **Rate/tone:** human-only (§5.5, §5.6). Pass 3's "faster than reading"
  instruction and natural per-speaker pitch spread are the first real data;
  the synthetic deck prints "—" for tone until then.
- **Rule of engagement (extends the existing discipline):** synthetic deck =
  per-commit tripwire; public corpora = per-release check that the tripwire
  still points the right way; human-v1 = the only numbers ever quoted as
  accuracy, with the dev/held split enforced by speaker exactly as
  DEFINITIONS.md already mandates.

### 8.3 Measurable predictions this ladder makes (so the panel can attack them)
1. Parakeet's per-voice spread on `tts-accents-v1` will be narrower than
   apple_live's (+8.3 max today). Testable in ~40 s of ASR the day the channel
   runs the matrix.
2. L2-ARCTIC will reproduce the *ordering* (Indian-accented > British-accented
   degradation vs US baseline) if the synthetic accent axis is meaningful; if
   it does not, the accent deck gets demoted to voice-QA and this document
   says so in an appended correction.
3. The wn5 cell will move by more than ±3 WER points across the next macOS
   model swap while g0 moves within ±1.5 — noise cells are where model churn
   shows. (This is precisely why the deck's baseline tolerances must be wider
   than clean-corpus ones.)
4. With `peak_level`/`audio_ms` on every live row, ≥80% of sub-second empties
   will show normal levels (finger slips, not audio loss). If instead they
   show zero-ish levels, the capture path has a start-of-stream bug and the
   matrix's bandlimit/gain cells become the regression net for its fix.

---

## 9. Reproduction recipes (everything needed to promote the pilot to `tts-*-v1`)

- Fake-root pattern for experiments: any directory with `Package.swift` +
  `tools/eval/` satisfies `EvalPaths.isCheckout`; export `WISPRIT_EVAL_ROOT`
  and the entire harness (asr/stages/score, caches, runs) operates there.
  `score` prints without touching RESULTS.md; only `report`/`all` append — and
  they append to the fake root, not the repo.
- Accent generation = `tts-samantha/generate.sh` recipe with
  `WISPRIT_TTS_VOICE=<voice>` (the script already parameterizes voice and rate
  via env; per-voice output dirs and manifest concatenation are the only new
  parts). Gain/clip: `sample × 10^(dB/20)`, int16-clamped. Noise: Gaussian at
  RMS-SNR vs the g-12 signal, seeded per (condition, clip) for reproducible
  sha256s. Babble: concatenate other-voice clips reading different scripts,
  tile, mix at RMS-SNR. Bandlimit: resample 16 k→8 k→16 k. All pure-Python
  (wave/struct/random, no dependencies) at ~0.1 s/clip; or the same math in
  Swift on `WavFile`/`PcmFormat` (`PcmFormat.level` is the shared level
  statistic) if the generator should live next to the harness.
- Determinism note for the generator: seed every stochastic condition and
  never regenerate without `--force` (same contract as `generate.sh`), or the
  sha-keyed ASR cache churns and the "re-scoring is free" property dies.

---

## 10. Summary table: recommendation → mechanism → prediction → cost

| recommendation | mechanism | measurable prediction | cost |
|---|---|---|---|
| Ship `tts-accents-v1` + `tts-stress-v1` + corners (1,200 clips, §6.1) | axes isolate engine stressors; category=condition reuses existing scoreboard | per-axis WER table per release; deck deltas reproduce ±0 (refine=off) within one OS build | ~6 min gen once, ~2 min ASR per engine per OS build, 130 MB disk |
| Download Enhanced/Premium tiers of the 8 accents | removes compact-fidelity confound from accent axis | per-voice gaps shrink but ordering holds if gaps are accent-driven | ~1–4 GB disk, one Settings session |
| Add raw-stage per-axis table + emptyRate + robustness deck (§6.2) | attribution: engine damage vs pipeline repair; live failure mode made visible | RI-noise +16.8 / RI-accent +8.3 / RI-level +2.4 / RI-empty 0 become tracked baselines | small pure-Swift changes in `EvalScoring`/`Scoreboard` + bands |
| Fold osBuild into ASR cache key (§6.2.4) | cache correctness across model swaps | post-OS-update runs re-transcribe (2 min) instead of lying | one line in `EvalPaths.settingsHash` |
| Add bandlimit-8k cell (§5.7) | simulates the measured Bluetooth failure class | trips on capture-path regressions while clean cells stay green | ~1 min gen, 15 s ASR |
| peak_level/audio_ms on every metrics row + noise-floor field (§7) | maps live conditions onto matrix cells without recording anyone | classifies the 17% empty rate into finger-slips vs capture loss | a few lines, one field |
| Public real-speech rung: LibriSpeech + L2-ARCTIC/Common Voice (§8.1) | real speech validates synthetic orderings before human-v1 exists | prediction 2 in §8.3 | one download session + a manifest importer for `source: librispeech` |
| Record human-v1 (already planned; §8.2) | the only accuracy ground truth; calibrates every synthetic axis | pass-3 deltas bracketed by stress cells, or reverb cell gets added | 3 people × ~1 h each |

The synthetic matrix cannot certify "any accent, any volume, any tone". It can
make regressions on those axes visible within two minutes, for free, forever —
and it tells the human corpus exactly where to aim. That is what it is for.
