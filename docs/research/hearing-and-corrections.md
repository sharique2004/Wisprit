# Wisprit: Hear Better, Correct Smarter

## Context

Two complaints drive this work:

1. **The headphone mic must actually be used.** Commit b6752aa pins the built-in Mac mic whenever Bluetooth headphones are connected, because opening a headset mic drops the Bluetooth link to HFP and "starves ASR." But Sharique wears headphones *specifically* when they can only speak softly or are in a crowded place — exactly the situations where a mic sitting on the desk/laptop hears worst and the mic in their ear hears best. The pinning defeats the purpose. We need a way to use the headphone mic without destroying transcription quality.

2. **Corrections are dumb.** The deterministic dictionary works but is brittle; the Apple Intelligence (FoundationModels) refine stage underperforms. Liberty granted to (a) harden the harness around Apple Intelligence and/or (b) ship a small local model that doesn't heat up the machine.

Overall goal: increase end-to-end accuracy of what the app hears and what it types. Deliverable: a researched plan with multiple directions to choose from.

## External research findings (verified 2026-08)

### Bluetooth / capture side (researched, with confidence levels)
- **The pinning premise is half-wrong.** Bandwidth is NOT the problem: mSBC wideband is 16 kHz — *exactly* the pipeline's canonical rate (SpeechAnalyzer's `bestAvailableAudioFormat` and Whisper's native rate). What actually hurts, in order: codec artifacts (~64 kbps lossy), SCO packet loss/concealment (worse in crowded 2.4 GHz spaces), the headset's own non-defeatable AGC/NS, and only lastly bandwidth. What the current policy ignores entirely: **mic proximity** — a ~6-inch earbud mic vs an ~18-inch laptop mic is a large SNR advantage for a soft speaker in a crowd, plausibly exceeding the codec penalty. (No published built-in-vs-AirPods WER data exists; we must measure ourselves.)
- **AirPods appear to macOS as two devices**: 48 kHz output-only + 16 kHz (sometimes reported 8 kHz = CVSD fallback vs mSBC) input-only; opening the input collapses output to headset mode. Empirically checkable in minutes via `kAudioStreamPropertyPhysicalFormat`.
- **iOS 26 "AirPods high-quality recording"** (48 kHz, H2-chip AirPods Pro 2 / AirPods 4, on-device beamforming + voice isolation): SDK header marks the opt-in API (`bluetoothHighQualityRecording`) **iOS-only / macOS-unavailable**, while Apple marketing says "across iPhone, iPad, and Mac." Most likely: firmware benefits reach the Mac, but the 48 kHz link mode is first-party-gated on macOS. **Testable in under an hour on this machine** (compare Voice Memos vs our capture format with AirPods).
- **Latency is the sleeper issue**: SCO channel bring-up adds 1–3 s before first audio, compounding macOS mic-hardware wake (2–5 s cold). On Bluetooth, push-to-talk will swallow opening words without a warming strategy — and warming (holding the mic open) conflicts with both output quality and Wisprit's mic-hard-off privacy invariant. Wispr Flow's stance: warn about AirPods (delay + accuracy), don't block.
- **Skip list (verified)**: LE Audio/LC3 (Apple hasn't shipped it), aptX Voice (never negotiated), VPIO (AEC we don't need + the AGC/NS that measurably hurts ASR + a known macOS bug with BT output/built-in input), programmatic Voice Isolation (`preferredMicrophoneMode` is read-only; only `showSystemUserInterface(.microphoneModes)` exists), unconditional denoising before ASR (literature: enhancement often *raises* WER for noise-robust models — consistent with Wisprit's own R19 measurements).
- **Silero VAD is the standout cheap win**: 309k params, RTF ~0.004 (~0.4 % of one core), Core ML ports exist (FluidInference/silero-vad-coreml — same FluidAudio family already in `Sources/WispritParakeet/`). Energy-threshold detection fails in both of the user's scenarios (soft speech = under threshold; crowd = floor over threshold); a real VAD fixes both directions and sharpens the too-faint/marginal classification.
- Genuinely *whispered* speech is a modeling problem (~45 % WER raw in research), not a mic-choice problem; softly-spoken speech is where proximity wins.

### Seam/word-loss fixes (known audit finding: engine is fine at 2.68% WER, seams lose words)
- **LocalAgreement-2** (ufal/whisper_streaming, IWSLT 2022): only commit the prefix that two consecutive decodes agree on; the rest stays provisional. Eliminates boundary truncation. https://github.com/ufal/whisper_streaming, https://arxiv.org/abs/2307.14743
- **Overlapping context windows**: carry a tail of audio from the previous chunk into the next decode and merge on token overlap; prevents words split at fixed boundaries.
- Cut chunks at VAD-detected silence, never at fixed timers, when latency budget allows.

### ASR-side vocabulary biasing (fix errors before they're made)
- Whisper `initial_prompt`: biases decoding toward listed proper nouns; only last ~224 tokens count, most influence at the end; it's a lexical-bias channel, not instructions. Effective for names/jargon per multiple studies. https://github.com/openai/whisper/discussions/1477, https://arxiv.org/abs/2410.18363
- Trie-based decode-time biasing with synthetic multi-pronunciations is the stronger research technique (https://arxiv.org/abs/2508.17796) but needs decoder integration.
- **Qwen3-ASR 0.6B/1.7B** (Jan 2026 tech report): ASR model with an LLM decoder that takes *free-text context for biasing* as a first-class input; streaming mode 2.54 WER on LibriSpeech; MLX ports exist (mlx-qwen3-asr, qwen3-asr-mlx, antirez's C port, a Swift port). https://github.com/moona3k/mlx-qwen3-asr/, https://arxiv.org/abs/2601.21337
- **Parakeet TDT 0.6B v2/v3** (NVIDIA): 25 languages, ~6% WER multilingual (better on English), extremely fast (RTF in the thousands; ~80 ms mic-to-text end-to-end in shipping Mac dictation apps), MLX port (senstella/parakeet-mlx) and a Core ML/ANE Swift port (FluidAudio/FluidInference) that runs on the Neural Engine at very low power. https://github.com/senstella/parakeet-mlx, https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v2-coreml

### Confidence-gated correction (stop correcting what wasn't misheard)
- whisper.cpp exposes per-token log-probability (`plog`/`p`); word confidence = mean of its tokens' probabilities. Segment `avg_logprob`, `no_speech_prob`, compression ratio are standard hallucination filters. https://github.com/ggml-org/whisper.cpp/blob/master/examples/server/server.cpp
- Literature: gate LLM correction on low-confidence words only; correcting high-confidence spans is where overcorrection/hallucination comes from ("Robust ASR Error Correction with Conservative Data Filtering", https://arxiv.org/abs/2407.13300; confidence-interfacing survey https://arxiv.org/abs/2407.21414).

### Generative error correction (GER) — the smarter correction layer
- Established paradigm: give an LLM the n-best ASR hypotheses (not just the top-1) plus task prompt; it reconstructs the intended text, beating any single hypothesis. https://www.emergentmind.com/topics/generative-error-correction-ger-with-llms, https://arxiv.org/abs/2405.10025
- Known failure mode: overcorrection / fluent hallucination → mitigate with conservative filtering + confidence gating + verbatim-return guard (Wisprit already has a verbatim guard, commit cab9c33).

### Small local models that run cool
- **Gemma 3 270M**: purpose-built for task-specific fine-tuning (Google's own case study is punctuation restoration — i.e., exactly a text-correction task); QAT INT4 checkpoints; negligible power (Google cites <1% battery for 25 conversations on a phone). Fine-tune with LoRA/Unsloth, run via MLX or llama.cpp. https://developers.googleblog.com/en/introducing-gemma-3-270m/
- **Qwen3 0.6B / Gemma 3 1B class** at 4-bit via MLX: ~100+ tok/s on M-series, sub-second for a 50-token correction burst; MLX has the best sustained throughput of local runtimes on Apple Silicon (arxiv 2511.05502). Short bursts ≈ no thermal impact; it's sustained load that heats laptops.
- **FoundationModels (Apple Intelligence)** harness levers, in order of power:
  1. **Guided generation (`@Generable`/`@Guide`)** — constrained decoding, not JSON-by-hope. Schema shape is enforced at decode time; property order matters; keep schemas minimal.
  2. **Custom LoRA adapters** — Apple ships an adapter training toolkit (train on a 32 GB+ Apple Silicon Mac or Linux GPU; package as asset packs). Caveat: adapters are pinned to a base-model version and break across OS updates until retrained — real maintenance burden. https://developer.apple.com/apple-intelligence/foundation-models-adapter
  3. Session prewarming, greedy sampling for determinism, English instructions, small focused prompts (3B model, limited context).

## Codebase findings

### Audio capture path (mapped)

- **Engine is Apple SpeechAnalyzer/SpeechTranscriber** (macOS 26), fed 16 kHz mono Int16 (`PcmFormat.canonical`) — chosen because it equals the analyzer's `bestAvailableAudioFormat`. Capture is `AVAudioEngine` + tap, fresh engine per utterance ([MicCapture.swift:155](Sources/WispritEngine/MicCapture.swift)), 100 ms buffers, `PcmDownconverter` with exact-capacity output + `flush()` tail recovery.
- **Headphone pinning (b6752aa)**: `InputDevicePolicy.shouldPinBuiltIn` ([InputDevice.swift:86](Sources/WispritEngine/InputDevice.swift)) pins the built-in mic when input is classic-BT narrowband (<32 kHz) **or** when input *and* output are both classic BT (rate ignored — "the advertised rate lies until HFP is up"). BluetoothLE transport is deliberately exempt (LE Audio/LC3 is wideband). Pin is per-recording via `kAudioOutputUnitProperty_CurrentDevice` on the AUHAL ([MicCapture.swift:320](Sources/WispritEngine/MicCapture.swift)); system default input never touched. User setting `input_device_policy`: `prefer_builtin` (new default) / `warn` / `off`. Under the default the user gets **no pill indication** the mic was swapped (Doctor only).
- **No VPIO/AGC/NS anywhere — by measured law** (R19 in `docs/research/robustness/FINAL-PLAN.md`): engine is level-invariant over ~50 dB; enhancement degraded ASR in 40/40 published configs; push-to-talk has no far-end to cancel. Any plan touching this must say it is re-litigating a settled measurement. Insertion seam if ever needed: `MicCapture.start()` between converter construction and tap install.
- **No true VAD** — a single RMS `voicedPeakThreshold = 0.01` used for classification/telemetry. Quiet-speech handling (015cc58): *rescue-path-only* peak normalization (target 0.5, cap 30 dB, window `[0.01, 0.25)` peak) applied before the batch re-transcription rescue; live AGC was tested and rejected (WER got worse). Plus "too faint" pill copy via `MarginalAudio` (peak < 0.12 and SNR < ~14 dB).
- **Seams: a drop problem, not a window problem.** The live path streams into one continuous analyzer session (no decode windows, overlap would do nothing). Real drop sites, ranked by the explorer:
  1. `SpeechAnalyzerEngine.finalize` line 166: `discardAll()` **throws away the queued utterance tail** when the pump can't drain within the finalize budget — unmetriced, warning-log only. **Highest-value lead.**
  2. `PcmChunkQueue` drop-oldest at 100 chunks (10 s); `droppedChunks` counter exists but is **never read**.
  3. Cold-start head race (mitigated by head-replay splice), exact-capacity resampler (fixed), flush-tail edge cases, 120 ms key-up grace, and an irreducible ~45–55 ms HAL spin-up head loss (privacy cost).
- **`Sources/WispritParakeet/` already exists**: a FluidAudio(Parakeet)-based *vocabulary channel*, off the hot path, not yet a WispritMac dependency.

### Transcription + correction stack (mapped)

- **Three Apple recognizers**: live `SpeechTranscriber` (fresh analyzer per utterance, volatile+fast results, windowed `TranscriptSink`), batch-rescue `SpeechTranscriber` over retained PCM (`AppleBatchTranscriber` + hallucination filter; rescue "may add words, never lose them"), and the off-path **`DictationTranscriber` vocabulary channel** ([VocabularyChannel.swift](Sources/WispritEngine/VocabularyChannel.swift)) — the only real biasing channel: `AnalysisContext.contextualStrings` costs ~3.1 ms/term at prepare, zero at decode, whole dictionary ships. **Live `SpeechTranscriber` provably ignores `contextualStrings`** (measured, noted at [DictionaryStore.swift:10](Sources/WispritDictionary/DictionaryStore.swift)).
- **Parakeet TDT v3 module exists, complete and tested but unlinked** (`Sources/WispritParakeet/`, FluidAudio pinned); adoption recipe written in `ParakeetVocabularyChannel.swift:16-30`. Standing rule: never take the vendor rescorer's rewritten text (measured 23–50 false replacements / 44 clips) — only CTC evidence judged by `VocabularyReconciler` gates (1–3 tokens → exactly one known term; pure inserts/deletes refused).
- **Dictionary applier**: exact-string, relaxed-whitespace, custom word-edges (hyphen-excluding), longest-first with a UTF-16 claim mask, idempotent by construction. **No fuzzy matching** — yet `DoubleMetaphone`, `Jaro-Winkler`, and `PhoneticScorer` (with calibrated floors 0.60/0.62) already live in `WispritKit` and are used by six *other* systems. Applied 3×: live partials (display-only, 2000-char budget, idempotence required), PostProcess stage 2 of 9, off-path retro.
- **Refine stage**: `SystemLanguageModel` (permissive guardrails), greedy, **plain string prompt — no `@Generable` anywhere**, one session per utterance, prewarm at record-start. `RefineGenerating` protocol = clean swap point ([AppController.swift:121](Sources/WispritMac/AppController.swift)). The `Refiner` cage: 6 pre-flight skips, 8 output guards (plausibility band, obedience, dropped-content, paraphrase via PhoneticScorer 0.60), all failures return verbatim. Prompt is byte-locked (`PromptLockTests`); live battery floor 0.888465 (`WISPRIT_REHEARSAL=1`, ~40 cases, model-independent assertions).
- **Learning loops already exist**: spoken-spelling corrector (phonetic antecedent ≥ 0.62, 2-sighting pending quarantine), EditCapture correction-memory (`learn_pending.json`, ≥2 observations, auto-accept off), off-path reconcile with `recordUse`, and `history.sqlite` storing the raw/corrected/refined/inserted quadruple per utterance — ready-made fine-tuning/eval data.
- **Change contract**: idempotent, verbatim-on-doubt, never throws, deterministic stages < 20 ms, metrics outcome for every refusal, corpus/battery coverage added *before* the change; re-run batteries after macOS point releases.
- Insertion seams identified: `CorrectionApplying` decorator (fuzzy layer), `RefineGenerating` swap (local model), stage gap at `SessionController.swift:629-637`, vocabulary-channel `extra:` terms, `RetroEditPlanner` for post-insertion edits.

## Decided direction (Sharique's choices, 2026-08-24)

1. **Mic rule, verbatim intent:** *headphones connected → use the headphone mic (AirPods, any Bluetooth, any wired); nothing connected → Mac mic.* No adaptive chooser. Dual capture approved as crowd insurance **only if** it can't override the headset mic — the Mac mic may silently *rescue* a failed/marginal utterance, never replace a good one.
2. **Corrections:** Fuzzy → edit-script → Parakeet (recommended order). Local model deferred until battery + field data says Apple-constrained-to-edits still loses.
3. **Hearing fixes:** all four tiers.
4. **A/B:** Sharique will record the six-cell corpus in their own voice.

### Workstream 1 — The headphone mic (decided shape)

**The rule as implemented:**
- Headset with a mic present (wired/USB needs nothing — it is simply not pinned away anymore; classic-BT is the case with machinery) → **headset mic is the input, always**. The `prefer_builtin` pin stops being the default; `shouldPinBuiltIn` survives only behind the opt-in setting.
- True-CVSD exception handled by *honesty, not override*: if the cached negotiated rate for a device is < 16 kHz (genuine 8 kHz CVSD), still use it per the rule, but show the one-time pill notice recommending the Mac mic, with the setting one click away. No silent swaps in either direction, ever.
- Nothing connected → system default (built-in) exactly as today.
- **Dual capture (classic-BT primaries only):** a second `MicCapture` pinned to built-in feeds *only a retention buffer*. One new rescue rung: when the headset utterance hits `needsRescue` or comes back marginal, batch-transcribe the secondary PCM under the existing "may add words, never lose them" contract. This is what makes the simple rule safe in the two hard Bluetooth moments — SCO first-words (built-in wakes in ~50 ms while SCO takes 1–3 s) and packet-loss in crowded 2.4 GHz. Both engines stop at key-up; orange-dot invariant untouched.
- First-words UX: grey "Connecting headset mic…" pill state until the first buffer arrives on classic-BT; pill notice naming the mic when it changes; Doctor reports actual mic + negotiated rate + whether output is playing. Opt-in bounded warm-hold setting (default off; orange-dot tradeoff stated in copy).

**Phase 0 (measurement, ~half a day, still first):**
- `wisprit miclab` probe command (new `Sources/WispritMac/MicLab.swift`): open each mic, log negotiated post-open format (the truth once SCO is up), SCO bring-up time (`first_chunk_ms`), 5 s of floor/peak. Settles 8 vs 16 vs 48 kHz empirically.
- AirPods-HQ test: if the post-open input format reads 48 kHz on this Mac, the whole HFP tradeoff dissolves — re-evaluate everything (expected: 16 kHz, API is SDK-marked macOS-unavailable).
- WER A/B in the user's own voice via existing `eval record --mic` machinery: six cells (`internal/airpods × quiet/soft/cafe`); needs a ~30-line `--mic` filter added to `eval asr`/`score` (mirroring `--categories`). Decision gate: the **soft and cafe cells** are what matter.
- Production attribution (~20 lines, lands regardless): add `inputDevice`/`inputTransport`/`negotiatedRateHz` to `MetricsRecord`.

**Implementation map (decided shape = flip-the-default + dual-capture rescue; adaptive chooser rejected):**
- [InputDevice.swift](Sources/WispritEngine/InputDevice.swift) — default policy semantics, `NarrowbandWarner` copy rework, negotiated-rate cache.
- [MicCapture.swift](Sources/WispritEngine/MicCapture.swift) — `firstChunk` stamp for the connecting state, post-open negotiated-format read, reuse for the secondary capture.
- [AsrManager.swift](Sources/WispritEngine/AsrManager.swift) — `secondaryPcm` threading + one cross-mic rescue rung + `rescueSource` metric.
- [AppController.swift](Sources/WispritMac/AppController.swift) — `preferredDevice` wiring, secondary-capture construction behind a `dual_capture` setting (on only when primary is classic-BT), warner enablement.
- [SessionController.swift](Sources/WispritMac/SessionController.swift) — policy default, connecting-pill state, mic-name notices, metrics threading.
- Settings/Doctor pages + the b6752aa test suites (`InputDevicePolicyTests`, `SessionControllerTests`, `DoctorTests`, `HubShellTests`) reworked for the new default.
- Effort: ~1–2 days for the rule flip + UX; +3–5 days for dual-capture rescue.

### Workstream 2 — Smarter corrections (decided order: A1 → A2 → B1, then evidence)

Key structural fact (verified): any generator conforming to `RefineGenerating` and returning text **inherits the entire Refiner cage for free** (all guards, timeouts, Esc, verbatim fallback). Injection point: `AppController.makeGenerator()` (:568). And SpeechAnalyzer already outputs cased+punctuated text — today's full-text re-emission by the refine model mostly *re-derives what the ASR already gave*, which is pure paraphrase surface.

**Option A — "Harness, not model" (two independently shippable parts).**
- **A1 — Phoneme-aware fuzzy dictionary decorator** (2–4 days, near-zero risk): new `FuzzyVocabularyCorrector: CorrectionApplying` wrapping the exact masked pass; fuzzy fills only unclaimed spans; substitution-only, term-anchored, floors ≥ 0.85 phonetic / ≥ 0.90 JW hear-phrase near-miss, common-word + known-term vetoes (idempotence falls out), ambiguity refusal; < 5 ms budget. Improves every configuration including refine-off, live partials, verbatim apps. All primitives (DoubleMetaphone, PhoneticScorer, calibrated floors) already exist — assembly, not research.
- **A2 — Span-targeted refine via guided generation** (~1–1.5 weeks): new `EditScriptGenerator` using `@Generable` edit-list output (`[{find, replace}]`) + deterministic `EditScriptApplier` with per-edit guards (find must anchor exactly; ≤8 edits ≤4 words; accept only if replace is a dictionary term, phonetically plausible ≥ 0.60, filler/cue deletion, or punctuation-only). Paraphrase/obedience/summarization become **unrepresentable**, and the dictionary finally becomes evidence the model path can use. Locked prompt untouched (new prompt gets its own lock + separate battery band before any default flips). Deferred A2b: enable transcriber confidence attributes and require substitution edits to overlap low-confidence spans.

**Option B — "Second opinion" (Parakeet).**
- **B1 — Link the module** (3–5 days): one Package.swift line + recipe in `ParakeetVocabularyChannel.swift:16-30`; replaces the off-path DictationTranscriber reconcile: measured recall 14 vs 8 dictionary hits, ~300 ms vs seconds (retro edits land while text is still owned). Models download-on-demand, opt-in.
- **B2 — GER-lite disagreement mask** (~1–2 weeks, composes with A2): align live final vs Parakeet transcript; **agreement spans become untouchable for refine** (strongest "ASR was right" signal available), disagreement spans resolved only by existing gated machinery (fuzzy/reconciler), else verbatim. Run Parakeet decode concurrently with refine → ~0 added insertion latency.

**Option C — "Own the corrector" (local model, same cage).**
- **C1** (~1–1.5 weeks): Qwen3-0.6B-Instruct 4-bit via MLX-Swift as a `LocalModelGenerator: RefineGenerating`; weights downloaded on demand (~400 MB, ParakeetModelStore pattern, checksums, no network on the dictation path); `refine_backend = apple | apple_edits | local | auto` — **`auto` alone fixes "Apple Intelligence unavailable ⇒ refine silently off"**. Sub-second bursts ≈ no thermal load; log `thermalState` per call so "doesn't heat up" is measured, not asserted. Battery is model-independent → same rehearsal harness scores it; ship `local` only if its band ≥ Apple's.
- **C2** (+2–3 weeks, only on evidence): fine-tune Gemma 3 270M QAT-INT4 or Qwen3-0.6B LoRA to emit A2's EditScript, trained on history.sqlite correction pairs + DoubleMetaphone-guided synthetic mishears (all on-machine; no cloud). Skip Apple's adapter toolkit (adapters break at every base-model update).

**Planner recommendation: A1 → A2 → B1 → then decide B2 vs C1 on battery + field evidence.** A2's EditScriptApplier is the shared contract Apple, local, and the agreement mask all plug into; C first would be the highest effort with unproven payoff while A strictly shrinks the problem C would solve.



### Workstream 3 — Hear better / stop losing words (one tiered plan, not options)

- **Tier 1 — Tail-discard metric + rescue (~half day, highest value/risk ratio).** The one truncation the machinery cannot see today: pump misses the finalize budget → `discardAll()` throws the queued tail away → finalize completes cleanly → `needsRescue` never fires ([SpeechAnalyzerEngine.swift:162-168](Sources/WispritEngine/SpeechAnalyzerEngine.swift) — verified). Fix: count discarded chunks → `UtteranceResult.discardedTailMs` → new `needsRescue` clause (`discard > 0 && !text.isEmpty`, mirroring the config-change clause; silence never rescues) → batch rescue over the complete retained PCM under the existing "may add words, never lose them" guard. Warm batch pass is 60–260 ms. Metric `tail_discard_ms`.
- **Tier 2 — Wire `droppedChunks` (rides Tier 1's diff).** Same read site, same rescue shape for mid-utterance queue drops; `dropped_audio_ms` metric; Doctor + stats rows; eval detail rows assert zero under burst feed (~35× realtime = harshest backpressure test). No capacity change until a nonzero reading exists.
- **Tier 3 — Real VAD: Silero CoreML via FluidAudio (2–3 days), strictly off the audio path.** Apple's SpeechDetector is empirically closed on this machine (probe on record: traps detector-only, delivers no verdicts co-located; re-probe each macOS update). `VadModelStore` (ParakeetModelStore pattern, explicit download, ~1–2 MB) + `VadMonitor` fed a second chunk reference; publishes speech-probability/first-speech/ratio. Consumers: honest empty/marginal classification (soft speech under RMS floor but VAD-speech → visible defect, not "silent"; loud room with no speech → honestly silent, no "too faint" nag), telemetry, Tier 4 endpointing, and the future mic-arbitration comparator. **Never gates or rewrites audio** (engine transcribes at peak 0.003; a gate would lose exactly the soft speech this protects).
- **Tier 4 — Adaptive key-up grace (~1 day, depends on Tier 3).** Phase A 0–120 ms unconditional (tap physics); Phase B extends only while trailing audio is still speech (RMS-vs-floor OR VAD probability), ends at ~150–200 ms trailing silence, hard-capped by the existing 500 ms clamp; `grace_extended_ms` metric; toggle `keyup_grace_adaptive` default on. Stops cutting the last syllable on fast key release.
- **Tier 5 — Measurement**: keyup-cut harness (replay clips truncated at end−X ms, score last-word recall — calibrates trailing-silence hold from data), VAD recall harness over `tts-stress-v1` bands vs the RMS threshold, plus noise-only clips for false positives.
- **Non-goals (explicit)**: denoising before ASR, live AGC/pre-gain (R19, measured twice), overlap windowing/LocalAgreement (no windows in a continuous session), VAD-gating the feed, recovering the ~50 ms HAL-wake head loss (accepted privacy cost).

## Build sequence

| Phase | What | Effort |
|---|---|---|
| 0 | `miclab` probe + AirPods-HQ test + eval `--mic` filter + device metrics; Sharique records the six-cell A/B corpus; publish findings under `docs/research/probes/` | ~half day + ~30 min recording |
| 1 | Mic rule flip: headset mic when connected, honest UX (connecting pill, mic-name notice, CVSD warning-not-pin), Doctor rework, test-suite updates | 1–2 days |
| 2 | Hearing Tiers 1+2: tail-discard + dropped-chunks metrics & rescue triggers (one diff) | ~1 day |
| 3 | Dual-capture cross-mic rescue (classic-BT primaries) | 3–5 days |
| 4 | Corrections A1: `FuzzyVocabularyCorrector` (+ its unit corpus first) | 2–4 days |
| 5 | Corrections A2: `EditScriptGenerator` + `EditScriptApplier` + `refine_backend` switch (+ battery cases and a separate baseline band first; default flips only on evidence) | 1–1.5 weeks |
| 6 | Hearing Tiers 3+4: Silero VAD off-path + adaptive key-up grace (+ VAD/keyup-cut harnesses) | 3–4 days |
| 7 | Corrections B1: link Parakeet, upgrade the vocabulary channel to ~300 ms retro | 3–5 days |
| 8 | Decision gate: B2 (agreement mask) vs C1 (local Qwen3-0.6B behind the same cage) from battery + field metrics | — |

Phases 1–2 are independent and can land in either order; 3 depends on 1; 5 depends on 4 only for shared eval plumbing; 6–7 are independent of each other.

## Program: what has to go, what changes, what's added

**Goes (deleted/reverted):**
- The silent `prefer_builtin` default from b6752aa (the predicate survives as opt-in + true-CVSD auto-pin).
- The silent tail-discard (becomes metriced + rescued).
- Refine's full-text re-emission as the only mode (superseded by edit-script backend once its battery band proves out).
- The fiction that the dictionary is exact-match-only (fuzzy decorator over the same store).

**Stays untouched (deliberately):**
- R19 no-enhancement law, mic-hard-off privacy invariant, the locked refine prompt + battery floor, the Refiner cage, `DictionaryStore` internals, VocabularyReconciler gates.

**Added:** miclab probe + eval `--mic` filter + device metrics; connecting-pill state + honest mic copy; negotiated-rate cache; (B) secondary retention capture + cross-mic rescue rung; FuzzyVocabularyCorrector; EditScriptGenerator + EditScriptApplier + `refine_backend` switch; Parakeet link + (later) agreement mask; tail-discard/dropped-chunks rescue triggers; VadModelStore + VadMonitor; adaptive key-up grace; (optional) LocalModelGenerator (Qwen3-0.6B 4-bit MLX) behind the same cage with `auto` fallback.

## Verification (every phase)

```bash
swift test                                                  # full offline suite (~1764 tests)
WISPRIT_REHEARSAL=1 swift test --filter RehearsalTests      # live refine battery vs BASELINE floor
./dist/Wisprit.app/Contents/MacOS/Wisprit eval all --corpus tts-samantha   # 4-config matrix vs bands
./dist/Wisprit.app/Contents/MacOS/Wisprit eval deck         # robustness tripwires
```
Plus per-change: new battery/corpus cases land BEFORE the change they judge; new metrics fields for every new decision path; the six-cell mic WER A/B decides Workstream 1's default.

At execution start, this plan (research + decisions) also gets committed into the repo as `docs/research/hearing-and-corrections.md` so the reasoning lives with the code, following the existing `docs/research/` convention. No Co-Authored-By trailers on any commit.
