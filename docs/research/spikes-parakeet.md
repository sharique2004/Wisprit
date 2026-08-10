# Spike B-0 — Parakeet TDT v3 via FluidAudio, gated

The Phase-6 gating spike from the accuracy-parity plan: does Parakeet TDT v3 (CoreML, via the
FluidAudio SPM package) emit cased+punctuated text, does its vocabulary boosting beat the
recorded SpeechTranscriber results on the real dictionary, and what does it cost. Measured on
this machine (M4, macOS 26.5.2 / 25F84, Swift 6.3.3 CLT, no Xcode), 10 Aug 2026.

**Everything below is `say -v Samantha` TTS audio (the tts-samantha corpus, 44 clips, 16 kHz
mono Int16, + one 37 s scratch clip), scored against the cached `apple_live` transcripts in
`docs/eval/runs/asr.tts-samantha.apple_live.c1631849.*`. TTS numbers validate plumbing and
relative behaviour, never an accuracy claim — human corpus is Phase 2.** Single machine, single
voice, vendor-default thresholds; WER here is an indicative lowercase/punctuation-stripped
Levenshtein, not the Phase-0 `.asr` profile.

**Pin**: `FluidInference/FluidAudio.git` @ `5390df9752c8fc583596018360c5fd70d6fa6c75`
(`v0.15.5-32-g5390df97`, 2026-08-01) — the same revision MeetingScribe's diarization A/B
validated (`~/MeetingScribe/native/fluiddiarizer/Package.swift`). Probe package (re-runnable):
scratch `parakeet-spike/` (`Package.swift` + `Sources/parakeet-probe/main.swift` + `make_vocab.py`
+ `score.py` + `run.sh`); TDT models reused read-only from
`~/MeetingScribe/native/asr-ab/models/parakeet-tdt-0.6b-v3`.

---

## Verdict

**The casing gate PASSES: Parakeet TDT v3 output is fully cased and punctuated (fork (a) stays
open). But ship it first as the VOCABULARY-CHANNEL REPLACEMENT (fork (b)) — that is where the
measured win is, the parity risk is nil, and two live-path regressions were measured that make
the opt-in live engine a later, scoreboard-gated decision, exactly as Phase 6 already requires.**

The one non-negotiable from the measurements: **never take FluidAudio's rescored text.** Its
rescorer over-fires at every configuration tried (23–50 false replacements across 44 clips).
Consume `ctcTokenEvaluateCandidates` evidence (per-candidate CTC scores + UTF-8 byte ranges)
through the Phase-3 `VocabularyReconciler` gates instead — that combination recovered 13 of the
14 dictionary-reachable terms where the recorded apple_live dict-on pipeline recovered 8.

---

## Q1 — casing, punctuation, spelled runs

**Answer: cased and punctuated, at parity with SpeechTranscriber on ordinary text. Spelled runs
mostly keep the ALL-CAPS hyphenated shape but have two new failure modes.**

Over the 44 clips (raw engine output, no boosting):

| | apple_live (cached) | parakeet raw |
|---|---|---|
| any uppercase | 42/44 | **44/44** |
| starts with capital | 42/44 | **44/44** |
| terminal punctuation | 44/44 | 43/44 |
| contains comma | 12/44 | 12/44 |

Sentence case, commas, question marks, `%`, `1600 Pennsylvania Avenue Northwest, Washington,
D.C.` all come out formatted; ITN is native (digits, `March 14`, `942`). The one miss is an
email clip ending without a period. `PostProcess`'s cased-input assumption holds.

Spelled runs, side by side (spoken script → each engine's raw final):

```
sr-01 "J-S-O-N"          apple: The payload is J-S-O-N, not Y-AM-L.
                      parakeet: The payload is JSON, not YAML.          ← run COLLAPSED to the word
sr-02 "S-H-A-R-I-Q-U-E"  apple: My name is S-H-R-I-Q-U-E.
                      parakeet: My name is S-H-R-I-Q-U-E.               ← identical shape (both drop the A — TTS artifact)
sr-03 "K-R-Z-Y-S-Z-T-O-F" apple: Spell it K-R-Z-Y-S-Z-T-O-F please.
                      parakeet: Spell it K-Rz Y-S-Z-T-O-F please.       ← "Rz" breaks the all-caps token
sr-04 "JSON" (word)      apple: We store it in JSON and send it over HTDP.
                      parakeet: We store it in JSON and send it over HTTP.
```

`LetterRunDetector` keys on UPPERCASE tokens and already tolerates the hyphenated/glued shapes
(sr-02 is byte-identical to Apple's). The two regressions for a LIVE-engine role: (1) a spelled
run can collapse straight to the word (`JSON`) — output is *correct* but `hasLetterRun` never
fires, so the learn loop and refine bypass go dark for that utterance; (2) mixed-case glue
(`K-Rz`) breaks the all-caps key mid-run. Neither matters in the vocabulary-channel role.

Also measured, relevant to Wisprit's verbatim-first stance: Parakeet transcribes disfluencies
**verbatim** ("Um, so basically we should uh probably migrate the the database") where
SpeechTranscriber silently drops fillers ("So basically we should probably migrate to the
database"). More verbatim, but it inflates Parakeet's WER against cleaned refs and would change
what refine sees on a live path.

## Q2 — vocabulary boosting vs the recorded SpeechTranscriber results

**Answer: decisively better recall than anything the live path has recorded — 14/18 vs 8/18 —
but only when Wisprit keeps the pen. FluidAudio's own rewriter is not shippable as-is.**

Same 44 clips, same 18 expected-term slots (`expect.terms`), same term-hit rule as
`VocabularyChannel.termHits` (whole-word, case-insensitive). 4 of the 18 are control names
(Krzysztof, Anjali, Priyanka, Thorbjorn) deliberately NOT in any dictionary — the ceiling for a
dictionary-driven config is 14 + however many controls the acoustics get (both engines get only
Priyanka), i.e. **15**.

| config | term recall | WER (indicative) | false replacements |
|---|---|---|---|
| apple_live raw (= dict-off) | 1/18 | 19.6% | — |
| apple_live + dictionary regex (recorded `refine-off.dict-on`) | 8/18 | — | — |
| apple_live recorded best (`refine-on.dict-on`) | 10/18 | — | — |
| parakeet raw, no vocab | 6/18 | 15.6% | — |
| parakeet + 9-term eval dict, vendor defaults | 13/18 | 36.4% | **50** |
| parakeet + 9-term eval dict, `spotterRescueEnabled:false` | **14/18** | 17.3% | 23 |
| parakeet + 138-term dict (eval ∪ live), no-rescue | **14/18** | 26.0% | 41 |

What that 14/18 contains: every proper-noun clip recovered (`Hi Sharique … Wisprit`,
`InsForge`, `MeetingScribe`, `Khatri`, `PostgreSQL` from "Postgres equal", even the mangled
spelled run `S-H-R-I-Q-U-E.` → `Sharique`). The 4 misses = the 3 acoustically-lost control
names (correct behaviour — that is the control arm working) + pn-03 `Sharique`, where the
rescorer overwrote both "Shari" and "Kudari" with `Khatri`.

The `hear` phrases do real work: `CustomVocabularyTerm(text:aliases:)` maps 1:1 to
`{term, hear:[]}` and the alias match is what fires ("whisper it" → `Wisprit` at similarity
1.0 via the alias, not the canonical).

**The over-fire finding.** With vendor defaults the spotter-rescue pass replaces arbitrary
common phrases with vocabulary terms ("What is the population" → `Wisprit`, "Meet me at
example.com" → `Kubernetes`). FluidAudio's own source recommends `spotterRescueEnabled: false`
for short vocabularies (#702/#724) — that cuts 50 FPs to 23, and the 138-term dictionary
(minSimilarity auto-tightens 0.50 → 0.60 above 100 terms) still produces 41, mostly junk-alias
collisions from the live dictionary ("better" → `Letta`, "email" → `RamAIn`, "beta" →
`Letta`, "close." → `Claude`). **Conclusion: take the *evidence*, not the rewrite.** The
evidence API is exactly the Phase-3 input shape:

```
ctcTokenEvaluateCandidates(transcript:tokenTimings:logProbs:frameDuration:cbw:marginSeconds:minSimilarity:)
  -> CandidateEvidenceOutput { baseText, baseWords, candidates: [CandidateEvidence] }
CandidateEvidence: origin, basePhrase, canonicalTerm, matchedAlias, similarity,
  rawVocabularyCTCScore, rawOriginalCTCScore, effectiveBoost,
  wordRange, tokenRange, baseTextUTF8Range,   ← literal byte range into baseText
  startTime, endTime, comparisonPassed, legacyOutcome, reason
```

e.g. pn-01: `{basePhrase:"whisper it", term:"Wisprit", alias:"whisper it", similarity:1.0,
orig_ctc:-15.14, vocab_ctc:-13.71, utf8_range:[30,40], outcome:"applied"}`. Phase-3's gates
(term-anchored blocks only, phonetic ≥0.62, ≤2 edits, never overwrite a known-correct word, no
pure deletes/inserts) are precisely the filter these 23–41 FPs need — every FP above fails at
least one of them, every true hit passes.

## Q3 — latency (M4, warm, per utterance, batch over pre-loaded PCM)

**Answer: batch decode of a full utterance costs about what SpeechTranscriber's release→final
costs. The full boost pass adds ~200 ms off-path. Live streaming is a different integration,
not a flag.**

| stage | min | p50 | p90/max |
|---|---|---|---|
| TDT decode, 2.0–9.7 s clips (44) | 60 ms | 82 ms | p90 106 / max 115 ms |
| TDT decode, 37 s clip | — | ~290 ms | — |
| CTC spot pass (9-term vocab) | — | 91 ms | max 106 ms |
| CTC spot pass (138-term) | 90 ms | 103 ms | max 133 ms |
| rescore (9-term) | — | 8 ms | max 33 ms |
| rescore (138-term) | 60 ms | 105 ms | max 430 ms |
| 37 s clip, spot + rescore (138-term) | — | 441 + 1145 ms | — |

Reference points: cached apple_live `finalizeMs` on the same clips 45/61/237 (min/p50/max);
spike-S1 live release→final 69–108 ms.

Caveats that matter for a live role: **first decode in-process costs 112–534 ms** (ANE
warm-up; steady state 60–115), so prewarm at app start or eat it on utterance 1. And batch
decode at release means **no partials during the hold** — the `im_streaming` live-typing rung
goes dark. FluidAudio's `SlidingWindowAsrManager` pseudo-streams in 10 s chunks (not
push-to-talk shaped); true streaming is a separate English-only 120 m "Parakeet EOU" model —
a different spike entirely. None of this affects the off-path vocabulary-channel role, where
decode+spot+rescore ≈ 300 ms/utterance replaces a DictationTranscriber pass that costs seconds.

## Q4 — footprint

**Answer: the plan's "~66 MB" is wrong by 7×. Budget ~560 MB on disk for the full boosting
stack.**

| asset (HuggingFace repo → files) | size |
|---|---|
| `FluidInference/parakeet-tdt-0.6b-v3-coreml`: Encoder.mlmodelc (int8) | 426 MB |
| " Decoder.mlmodelc + JointDecisionv3.mlmodelc + Preprocessor.mlmodelc + `parakeet_v3_vocab.json` | 37 MB |
| `FluidInference/parakeet-ctc-110m-coreml`: AudioEncoder + MelSpectrogram + tokenizer/vocab | 99 MB |
| **total, int8 + boosting** | **≈ 562 MB** |
| alternative: EncoderInt4.mlmodelc instead of int8 | 285 MB (saves 141 MB) |

int4 was measured and rejected: WER 16.8% vs 15.6%, and it audibly loses exactly the words
Wisprit cares about ("Hi **Shereek**, please add us to **whispered**" vs int8's "Hi Shariq …
whisper it"). Same decode speed. Use int8.

Memory and load (probe process, whole pipeline resident):

| | cold (first ever) | warm |
|---|---|---|
| TDT load | **15.8 s** (CoreML compile, peak RSS 500 MB) | 88–245 ms |
| CTC + vocab load | **54 s** (≈99 MB download + compile) | ~200 ms |
| rescorer create (138 terms) | — | 2–6 ms |
| steady-state RSS | — | 66–97 MB (weights live ANE-side) |

The 15.8 s / 500 MB compile happens once per machine per model version (CoreML cache); ship it
inside the explicit model-download flow, not on first use.

## API reality vs the plan's assumptions (what the integration must know)

* `CustomVocabularyTerm(text:weight:aliases:tokenIds:ctcTokenIds:minSimilarity:)` — exists as
  assumed; `aliases` ⇐ `hear` is the load-bearing field. `weight` untested here.
  `minTermLength` default 3 silently skips shorter terms.
* **"Boosting" at this pin is NOT decode-time biasing.** It is a post-decode pass: a separate
  99 MB CTC model produces log-probs (`CtcKeywordSpotter.spotKeywordsWithLogProbs`), then
  `VocabularyRescorer.ctcTokenRescore` / `ctcTokenEvaluateCandidates` compares constrained CTC
  scores. The TDT decode itself is vocabulary-blind. (A `tokenIds` decode-time path is stubbed
  in the type but nothing in `AsrManager` consumes it.)
* Batch entry points: `AsrModels.load(from: repoDir, version: .v3, encoderPrecision: .int8)`,
  `AsrManager(config: .default)` + `loadModels`, fresh
  `TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)` per utterance,
  `transcribe(_ samples: [Float], decoderState:&, language: .english)` — 16 kHz mono Float;
  `AudioConverter().resampleAudioFile(_:)` matches the pipeline's `PcmFormat.canonical` WAVs
  byte-for-byte.
* **`CustomVocabularyContext.loadWithCtcTokens(from:)` hardcodes the Application Support cache**
  (`~/Library/Application Support/FluidAudio/Models/parakeet-ctc-110m-coreml`). For
  `~/.wisprit/models/` compose it manually: `CtcModels.downloadAndLoad(to:variant:)` +
  `CtcTokenizer.load(from:)` + `encode` each term into `ctcTokenIds` (≈20 lines; the probe
  used the default cache).
* **`AsrModels.load` can silently download**: it routes every model file through
  `ModelHub.loadModels`, which fetches anything missing. `ParakeetModelStore` must verify all
  five files exist *before* calling load, or the zero-network promise breaks —
  `NetworkInvariantTests` should treat the whole `WispritParakeet` target as allowlisted-file
  territory.
* Rescorer config: `VocabularyRescorer.Config(spotterRescueEnabled: false)` is mandatory
  (vendor's own #702/#724 guidance; default ON is also flippable via `FLUID_SPOTTER_RESCUE`
  env, don't rely on that). `ContextBiasingConstants.rescorerConfig(forVocabSize:)` supplies
  minSimilarity (0.50 ≤10 terms / 0.55 / 0.60 >100) and cbw 4.5.
* No sandbox/entitlement surprises: plain process, CoreML+ANE, no mic. SPM fetch pulls one
  binary artifact (`NemoTextProcessing.xcframework` from `FluidInference/text-processing-rs`)
  — the pin's transitive supply chain includes a Rust ITN library.
* macOS 14+ platform requirement; builds clean on CLT-only Swift 6.3.3 with
  `swiftLanguageVersions: [.v5]` (same recipe as MeetingScribe's `fluiddiarizer`).

## What this changes in the plan

1. **Phase 6 ships as the vocabulary-channel replacement first** (fork (b)): Parakeet batch
   decode over `RetainedUtterance.pcm` + CTC evidence → `VocabularyReconciler` (Phase 3),
   replacing the DictationTranscriber pass — recall 14 vs 8 on the recorded results, ~300 ms
   vs seconds, and the reconciler's gates are the FP filter the rescorer lacks. Feed
   `vocabularyEntries()` (term + hear) straight into `CustomVocabularyTerm(text:aliases:)`.
2. **Fork (a) stays open, later**: casing+punctuation pass; latency fits; but it needs the
   `AsrEngineCapabilities` seam (`emitsPunctuation/emitsCasing` true, letter-run collapse and
   verbatim disfluencies adjudicated on the human corpus, live-typing rung dark or EOU-model
   spike) and a human-v1 scoreboard row, which is precisely the Phase-6 exit gate already.
3. **Correct the model-store budget**: ~66 MB → 463 MB (TDT int8) + 99 MB (CTC), one-time
   ~16 s compile on first download, `~/.wisprit/models/` layout must use the manual CTC
   composition above.

## What is NOT proven

TTS-only, one synthetic voice, one machine — every number above is plumbing-grade, not an
accuracy claim; human-v1 (Phase 2) re-measures before any ship decision. Vendor-default
thresholds only (no cbw/minSimilarity sweep). The apple_live comparison rows are the cached
c1631849 run, not a fresh head-to-head on identical settings hashes. `weight`, the `tokenIds`
decode-time stub, `SlidingWindowAsrManager` end-to-end, and the Parakeet EOU streaming model
were not exercised. Memory numbers are probe-process RSS, not the app's. sr-02's dropped "A"
is present in both engines' output and is almost certainly the TTS audio itself.

## Re-running

Scratch probe package (copy into the repo under `tools/` if it should outlive the scratchpad):
`parakeet-spike/{Package.swift, Sources/parakeet-probe/main.swift, make_vocab.py, score.py,
run.sh}` — `run.sh` rebuilds, regenerates both vocab configs from
`tools/eval/fixtures/eval-dictionary.json` (+ `~/.wisprit/dictionary.json`, read-only), runs
all six probe configurations against the tts-samantha corpus, and prints the score tables.
Corpus WAVs regenerate via `tools/eval/corpus/tts-samantha/generate.sh`. TDT models:
`~/MeetingScribe/native/asr-ab/models/parakeet-tdt-0.6b-v3` (read-only) or a fresh
`AsrModels.download`. Probe flags: `--precision int8|int4`, `--vocab`, `--no-rescue`,
`--evidence`, `--language en`.
