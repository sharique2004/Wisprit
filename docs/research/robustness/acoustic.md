# Acoustic robustness — what actually moves accent/volume/tone performance

Research pass for the "top-notch accuracy, any accent any volume any tone" goal,
2026-08-10. Scope: the engines Wisprit actually has (SpeechAnalyzer live path,
DictationTranscriber vocabulary channel, gated Parakeet TDT v3) plus the capture
path that feeds them. Two new measurements were taken for this report (§2, §3 —
probe sources and re-run instructions in the appendix); everything else cites
either this repo's recorded measurements or external published work, and says
which. **TTS-derived numbers are direction-and-mechanism evidence only, per the
repo's own banner rule (docs/eval/RESULTS.md); nothing here is an accuracy
claim until human-v1 re-measures it.**

The one-paragraph verdict: the biggest *unaddressed* lever is **locale-matched
model assets for accented speakers** (§1) — cheap, already 90 % plumbed, and
testable per-user with the existing eval harness. **Volume is a solved
non-problem for the engine and a real problem for Wisprit's own thresholds**:
new measurement shows SpeechTranscriber is gain-invariant over ~50 dB, so every
form of level conditioning (AGC, pre-gain, normalization) is a kill — but the
same measurement shows `voicedPeakThreshold` misclassifies speech the engine
can hear perfectly (§2). First-syllable clipping has a measured hard floor of
~50 ms after key-down plus an already-mitigated engine-ready race; the
privacy-preserving fix is a one-line buffer replay, and the honest answer for
speech *before* key-down is "the pre-roll stays dead, by design" (§3).
Parakeet's published noise-robustness data and the disagreement-signal
literature make a *selective* re-decode ("accuracy mode") the one hedge worth
an experiment; a wholesale second engine is not (§4). Six fantasy options are
named and killed with citations in §5 so the panel does not have to.

---

## 1. Locale assets — the accent lever

### What exists today, in this codebase

- Locale is a plain settings key, default `"en-US"`
  (`Sources/WispritPersistence/Settings.swift:57`), threaded
  `Settings.locale` → `AsrSettings(locale:)`
  (`Sources/WispritMac/AppController.swift:122`) →
  `SpeechTranscriber(locale: Locale(identifier: settings.locale), ...)`
  (`Sources/WispritEngine/SpeechAnalyzerEngine.swift:46`). One string switches
  the entire live path.
- Preflight and installation are already built: `AsrDoctor.check(locale:)`
  validates against `SpeechTranscriber.installedLocales`, and
  `AsrDoctor.installAssets(locale:)` wraps
  `AssetInventory.assetInstallationRequest(supporting:)`
  (`Sources/WispritEngine/AsrPreflight.swift:30–79`).
- The Settings window already shows a locale `Picker` over
  `facts.installedLocales` whenever more than one is installed
  (`Sources/WispritMac/Window/SettingsPage.swift:86–96`).
- Measured on this machine (spike S1, q5 — docs/research/spikes-s1.md):
  **nine English locale assets installed for SpeechTranscriber**
  (`en_IE, en_CA, en_SG, en_NZ, en_IN, en_AU, en_GB, en_ZA, en_US`), and
  `AssetInventory.maximumReservedLocales = 5`. Apple ships regional English as
  *separate model assets*, not a cosmetic tag — that is the mechanism this
  whole section rests on.

So "per-user locale choice" is not a feature to build; it is a feature to
*surface and validate*. What is missing is any evidence loop telling a user
which locale is right for their voice, and one plumbing gap (below).

### The gotcha the panel should not find first

`SpeechTranscriber` has nine English locales installed here, but
`DictationTranscriber.installedLocales` on the same machine is **`[en_US]`
only** (spike S1 q5). The vocabulary channel
(`Sources/WispritEngine/VocabularyChannel.swift`) runs DictationTranscriber
with the *same* `AsrSettings.locale`. Flip the live locale to `en-IN` today
and the off-path vocabulary pass will preflight-fail or run against a missing
asset. Any locale-switch feature must install assets for **both** module types
(one more `assetInstallationRequest` supporting a `DictationTranscriber`
module), or degrade the vocabulary channel gracefully. Similarly,
`EvalRunner.asrSettings()` hardcodes `locale: "en-US"`
(`Sources/WispritMac/Eval/EvalRunner.swift:584–585`) — the eval harness cannot
express a locale bake-off until that becomes a parameter (the cache key
already includes the locale via `settingsHash`, so cached runs will not
collide once it does).

### Evidence that accent-matched assets matter

No vendor publishes per-locale WER for Apple's models — Apple least of all. So
the external evidence is about the *mechanism*, and the honest position is
that the size of the win on Apple's specific assets is unmeasured until we
measure it:

- Acoustic-model mismatch is the dominant, repeatedly-replicated accent
  penalty: Koenecke et al., PNAS 2020, measured WER 0.35 vs 0.19 (≈2×) for
  Black vs white US speakers across five commercial ASR systems and traced the
  gap to the acoustic model, not the language model
  ([pnas.org](https://www.pnas.org/doi/10.1073/pnas.1915768117)).
- The industry consensus band for accented/noisy real-world audio is 8–12 %
  WER vs 2–3 % on clean matched speech (already recorded in this repo,
  docs/research/wisprflow.md §3).
- Wispr Flow — the competitor whose polish is the bar — does exactly this at
  larger scale: "Flow dynamically selects the most accurate ASR engine for
  each language", plus **"accent confidence scoring to compare multiple
  transcriptions and choose the most likely match"**, claiming error rates cut
  "by more than half in internal testing", with dedicated handling for
  accent-heavy pairs (Hinglish)
  ([wisprflow.ai/research/supporting-languages](https://wisprflow.ai/research/supporting-languages)).
  Their router is a cloud ensemble; Wisprit's local analog is exactly one
  knob — which of Apple's nine English asset sets decodes this user — and that
  knob is currently pinned to `en-US` for everyone.

### Auto-detection: what the API does and does not offer

**There is no language- or accent-identification API in the Speech
framework.** SpeechTranscriber requires an explicit locale; third-party
integrations state this plainly ("automatic language detection is not
available", [local-whisper](https://github.com/gabrimatic/local-whisper)), and
the community workaround is running *multiple transcribers concurrently*
plus an external language-ID model (VoxLingua107 ECAPA via MLX, ~15 ms per
10 s — [Itsuki, Medium 2026](https://medium.com/@itsuki.enjoy/swift-speechtranscriber-support-multi-language-without-manual-locale-switching-b626b547bd74)).
Two facts kill auto-detection for Wisprit v1:

1. **Language ID answers the wrong question.** VoxLingua-class models
   discriminate *languages*; en-IN vs en-US is one language. There is no
   shipped, local, English-*accent* classifier of production quality. Building
   one is research, not integration.
2. **Running two live locales concurrently is priced out by this repo's own
   measurements.** Two modules in one analyzer cost 406–439 ms unpaced /
   1377–1790 ms paced release→final (spike S1 Q1/Q4 — measured for ST+DT, and
   the cost is the dual-module topology, not the module type). Two *separate*
   analyzers would double ANE work per utterance for a decision that per-user
   settings answer once, offline.

### Recommendation — the locale bake-off

**Mechanism**: decode the *same recorded human audio* once per installed
English locale and put the WER side by side; the accent-matched asset either
wins on that user's voice or it does not. Everything required exists:
`Wisprit eval record` / `eval verify` and the 135-utterance human-v1 script
set (docs/research/spikes-s1.md, S4 status), the append-only scoreboard, and
per-run settings hashes. Consent is inherent — eval recording is an explicit
user act, and no dictation audio is retained otherwise (`RetainedUtterance`
dies with its utterance; history.sqlite stores text).

**Measurable prediction**: for an accented speaker, raw-stage WER on human-v1
differs measurably across locale assets, and the best locale is stable across
re-runs (same settings hash ⇒ cached, so the marginal cost of N locales is
N−1 decode passes, minutes not hours). If en-IN ≤ en-US −10 % relative for an
Indian-English speaker, ship the chooser prominently; if the deltas are noise,
this whole section costs one eval run and dies honestly.

**Cost**: make `EvalRunner.asrSettings()` locale-parametric (small); install
DT assets alongside ST for the chosen locale (one preflight call); UI copy for
"which English do you speak?" in onboarding or Settings (the picker exists).
No new engine, no new model, no network beyond Apple's own asset download.

---

## 2. Audio conditioning — volume is the engine's solved problem and our threshold bug

### New measurement: SpeechTranscriber is gain-invariant over ~50 dB

Probe (this report, appendix): three `say -v Samantha` 16 kHz clips, digitally
scaled before feeding a fresh per-session SpeechTranscriber (the
`SpeechAnalyzerEngine` topology, `[.volatileResults, .fastResults]`), M4,
macOS 26.5.2. `peak` is the exact production meter — max per-100 ms-chunk
`PcmFormat.level` (RMS×4, clamped), the number `voicedPeakThreshold`
gates on.

| scale | peak (meter) | u1 transcript delta vs ×1.0 | u2 | u3 |
|---|---|---|---|---|
| ×1.0 | 1.00 | — (baseline) | — | — |
| ×0.25 | 0.25 | identical | identical | identical |
| ×0.10 | 0.10 | identical | identical | "The"→"a" |
| ×0.03 | 0.030 | 1 proper-noun cluster shifts | identical | "The"→"A" |
| ×0.01 | **0.010** | same as ×0.03 | identical | identical |
| ×0.003 | **0.003** | 2 words shift ("Shariq"→"Cherie") | identical | identical |
| ×0.01 then ×20 boost | 0.20 | identical to ×1.0 | **"ship"→"shift"** (regression) | drops "The" |

Three conclusions, in order of importance:

1. **Digital level does not matter to the engine until ~×0.003 (−50 dB).**
   Perfect transcripts at meter peak 0.010; first real degradation at 0.003,
   and even that is one word. Mechanism: modern end-to-end ASR front-ends are
   log-mel with feature normalization — a global gain is an additive constant
   in log-spectral space that normalization removes. This is why AGC research
   only ever shows wins for *far-field* capture, and shows losses elsewhere
   ([Prabhavalkar et al., Google](https://research.google.com/pubs/archive/43289.pdf);
   [trainable-frontend/PCEN](https://static.googleusercontent.com/media/research.google.com/en//pubs/archive/45911.pdf)).
2. **Pre-gain is not merely useless — it measurably perturbed output.**
   Boosting ×0.01 audio ×20 (clip-free) changed "ship"→"shift" on u2 and
   dropped a word on u3, while the *unboosted* ×0.01 audio was perfect.
   Rounding/requantization is not free. Any "help quiet speakers with gain"
   feature has negative expected value on this evidence.
3. **`voicedPeakThreshold = 0.02` is calibrated to a mic heuristic, not to the
   engine.** The engine transcribes perfectly at peak 0.010 — under the
   threshold — yet `EmptyReason.classify` labels an empty result at that level
   `silent` ("the user did not speak", benign,
   `Sources/WispritEngine/EmptyReason.swift:48`), and
   `OnboardingMicTest.passLevel` reuses the same 0.02
   (`Sources/WispritMac/Window/OnboardingMicTest.swift:31`) — so a
   soft-spoken user on a quiet mic can *fail the mic test* while the engine
   would have heard them fine. Production telemetry is too thin to recalibrate
   from yet: only 8 of 369 metrics rows carry `peak_level` (the field is
   days old); voiced successes so far sit at 0.13–0.23 and the one recorded
   `produced_nothing` at 0.0388. **Recommendation**: keep the threshold for
   the *recovery* decision it was built for (it only gates "release the cached
   engines", where a false negative is cheap), but decouple the onboarding
   pass level and the `silent` copy from it once ~100 rows of `peak_level`
   exist; prediction: the 5th-percentile voiced-success peak will land well
   below 0.02, and lowering the classification floor to ~0.005 will reclassify
   real quiet-speech failures from "benign silence" to `produced_nothing`,
   where they become visible instead of vanishing.

**Honest limits of the probe**: digital attenuation of clean TTS is not a
whisper. Real quiet speech changes articulation (no voicing, different
formants) and lowers SNR against real room tone; the probe isolates *gain*
only, and gain is exonerated. Whispered-speech accuracy is a training-data
property Wisprit cannot buy locally — even Wispr Flow, with a dedicated cloud
stack, ships whisper support with an explicit elevated-error disclaimer
(docs/research/wisprflow.md §2). The honest whisper story for v1: the pill's
meter already shows the user they are registering (×4 boost exists precisely
so quiet speech moves it, `PcmFormat.level`), the threshold fix above stops
mislabeling them, and human-v1 should include a quiet-voice recording session
so the real penalty is a number instead of a fear.

### Noise suppression / Apple's voice-processing AudioUnit: keep it off

Wisprit taps the raw input node in hardware format
(`Sources/WispritEngine/MicCapture.swift:126`); there is no vpio in the path.
That is correct, and the evidence is unusually clean:

- Enhancement front-ends *degrade* modern ASR. A 2025 systematic study ran
  denoising ahead of four modern systems (Whisper, **Parakeet**, Gemini,
  Parrotlet) across nine noise conditions: the original noisy audio beat the
  enhanced audio in **40 of 40 configurations**, by 1.1–46.6 points absolute
  ([arXiv:2512.17562](https://arxiv.org/abs/2512.17562)). The mechanism is
  identified in prior work: the *artifact* component of enhancement, not
  residual noise, drives the loss
  ([arXiv:2201.06685](https://arxiv.org/abs/2201.06685)), and suppression
  objectives trade speech distortion against noise in ways tuned for human
  listeners, not ASR ([arXiv:2111.11606](https://arxiv.org/abs/2111.11606)).
  Models trained on varied noisy data (Whisper-class, Parakeet's 660 kh,
  presumably Apple's) already contain the robustness that enhancement tries
  to bolt on, minus the artifacts.
- Apple's `kAudioUnitSubType_VoiceProcessingIO` is the telephony bundle —
  AEC + NS + AGC for full-duplex calls
  ([Apple docs](https://developer.apple.com/documentation/audiotoolbox/kaudiounitsubtype_voiceprocessingio)).
  Push-to-talk dictation has no far-end signal to cancel, so its AEC is dead
  weight; its AGC is killed by the gain-invariance measurement above; its
  gating/ducking attacks exactly the onset audio §3 is trying to protect.
  Every part of it is wrong for this product.

**Kill AGC, kill NS, kill vpio** (formally in §5). The capture path's only
jobs are: don't drop samples (the `PcmDownconverter` capacity work already
measured and fixed this), don't add latency, and meter honestly.

---

## 3. First-syllable clipping — measured, and smaller than feared

### Where the loss actually occurs (measured on this machine)

New measurement (probe in appendix; fresh `AVAudioEngine` per run, exactly the
`MicCapture.start()` shape, 48 kHz hardware, 5 runs):

| stage | measured |
|---|---|
| `AVAudioEngine.start()` returns (capture live) | **42.7–51.1 ms** after call |
| first 100 ms tap buffer delivered | 148.7–157.4 ms after call (= ~50 ms start + 100 ms accumulation) |

Sequenced against `SessionController.begin`
(`Sources/WispritMac/SessionController.swift:314–382`): key-down →
`audio.start()` (~45–51 ms, blocking) → `liveTyping.beginUtterance()` →
`context.beginCapture()` → `asr.begin()` (blocking;
`prepareToAnalyze` 31–54 ms measured in spike S1, plus format query and
`analyzer.start`). So:

- **Hard loss**: speech in the ~45–55 ms between key-down and the HAL I/O
  proc going live is *never captured*. This is the true, irreducible cost of
  mic-hard-off privacy, and it is ~one phoneme, not a syllable.
- **The engine-ready race is real but usually won.** `AsrManager.feed` drops
  chunks to the engine until `begin` installs the session
  (`Sources/WispritEngine/AsrManager.swift:79–83`) — but the *first tap
  buffer only arrives ~150 ms after key-down*, and install completes at
  ~90–130 ms (audio.start + asr.begin, sequential). In the steady state
  nothing is lost. The race is only lost under cold-start jitter (first
  utterance after launch, model reload after a hard teardown) — and when it
  is lost, the head chunks silently vanish from the live transcript while
  the retention buffer keeps them (`retention.append` runs unconditionally).
- **What the rejected pre-roll would actually have bought**: recovery of
  speech *before* key-down (user anticipating the key) plus the ~50 ms start
  window. docs/notes/deviations.md §2 rejected it because it requires the mic
  live between holds. That reasoning survives this measurement: the always-on
  mic buys ~50 ms of tail plus user-anticipation speech, at the cost of the
  product's headline privacy property. **The pre-roll stays dead.**

### Privacy-preserving fixes, ranked

1. **Replay the retained head into the engine at install** (the fix the task
   brief hypothesized, confirmed viable by code reading). At the moment
   `AsrManager.begin` installs the engine, hand it
   `retention.data` accumulated since mic-live before live chunks resume.
   Requires no early mic, no privacy change — the audio is already captured
   and already retained; today it is simply withheld from the live engine
   when the race is lost. *Mechanism*: closes the engine-ready race
   deterministically instead of probabilistically. *Prediction*: zero effect
   on steady-state transcripts (the race is already won there); eliminates
   head-loss on cold-start utterances — testable by feeding a clip whose
   first word starts at t=0 with an artificially delayed `begin`.
   *Cost*: ~10 lines in `AsrManager` (order-preserving splice), no UI, no
   new state. The one risk — double-feeding chunks — is bounded by the
   existing `PcmChunkQueue` ownership (feed and install are both
   session-thread-adjacent; needs the same lock discipline `feed` already
   has).
2. **Measure exposure before building anything else.** Add
   `first_voiced_ms` (mic-live → first chunk with level ≥ threshold) to the
   utterance metrics row — the meter pass already computes the level per
   chunk (`MicCapture` line 130), so this is a timestamp diff, additive
   schema per the repo's append-only rule. *Prediction*: the distribution
   will show how often users speak within 150 ms of key-down (the population
   actually exposed to clipping); if p5 > 300 ms, clipping is a phantom and
   no further work is justified.
3. **The UX absorber already exists**: the pill fades in grey and turns
   orange on the first level tick (`SessionController.begin` comment, §2.4).
   The "speak when it's orange" contract is the zero-engineering mitigation;
   onboarding copy can state it once.

**Killed**: keeping a stopped-but-allocated `AVAudioEngine` warm between
utterances to shave the ~45 ms. The 2026-08-05 incident (spike S1-b) is the
proof this exact shape strands users on device changes; the fresh-engine-per-
utterance rule is load-bearing correctness (`MicCapture.swift` header), and
45 ms is not worth reopening it.

---

## 4. Parakeet TDT v3 as the robustness hedge

### What published data actually says

Nothing head-to-head exists — Apple publishes no WER at all, so any
"Parakeet is more/less accent-robust than SpeechAnalyzer" claim from public
sources is unfoundable. What *is* published, and useful:

- Parakeet TDT 0.6B v3 reports a full **SNR degradation curve** on its model
  card — 6.34 % average WER clean → 7.12 at SNR 10 → 8.23 at SNR 5 → 11.66 at
  SNR 0 → 19.88 at SNR −5
  ([nvidia/parakeet-tdt-0.6b-v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3)).
  It also posts **Earnings-22 11.42 %** — a corpus of real-world global-
  accented English — alongside LibriSpeech clean 1.93 %. That 6× spread
  between clean and accented-real-world is the accent problem quantified on
  the one engine Wisprit can inspect.
- This repo's spike (docs/research/spikes-parakeet.md) already established the
  *different-error-profile* premise on TTS: Parakeet transcribes disfluencies
  verbatim where SpeechTranscriber deletes them, collapses spelled runs
  differently, and recovers proper nouns the live path misses (14/18 vs 8/18
  term slots with the vocabulary evidence path). Different error profiles are
  precisely the precondition for ensemble/disagreement methods to work.

### Disagreement as the trigger: the evidence is good

The task's hypothesis — "when both engines exist, does disagreement predict
error?" — matches an established literature: cross-system disagreement is a
reference-free error signal ("when two complementary ASR systems disagree on
a region, that region is most likely an error" — complementary-ASR error
detection; segment-level QE for system combination,
[Jalalvand et al.](https://dl.acm.org/doi/10.1016/j.csl.2017.06.003); and a
2026 clinical-domain study using cross-model disagreement to prioritize
human review,
[Frontiers in AI](https://www.frontiersin.org/journals/artificial-intelligence/articles/10.3389/frai.2026.1829902/full)).
ROVER-style *voting* needs ≥3 systems; with exactly two, the honest product
shape is **selective re-decode**: use disagreement to decide which utterances
get a second look, not to pick a winner word-by-word.

### The "accuracy mode" proposal, priced

**Mechanism**: after live insertion, batch-decode `RetainedUtterance.pcm`
with Parakeet (measured p50 82 ms decode on 2–10 s clips, ~300 ms with the
CTC vocabulary pass, spike Q3 — off the paste path by construction).
Normalize both texts with the existing `.asr` profile and compute word-level
disagreement. Below threshold: do nothing. Above threshold: surface the
existing retro-correction machinery (the reconciler already knows how to
splice byte-aligned evidence, and `outcome: "correction"` rows already
exist), or — more conservative v1 — just *log* the disagreement score to
metrics and build the ROC curve before any user-visible behavior ships.

**Measurable prediction**: on human-v1 with both engines decoded (the eval
harness caches per `(audio_sha, engine, settings_hash)`, so this is one
extra column), utterance-level disagreement correlates with reference WER
strongly enough that a threshold catches ≥50 % of the worst-decile
utterances at ≤10 % false-positive rate. If it does not, accuracy mode dies
before it ships, at the cost of one eval run.

**Costs, stated fully** (all already measured in spikes): 562 MB disk int8 +
CTC (the plan's 66 MB was wrong by 7×), one-time ~16 s CoreML compile inside
the explicit download flow, 112–534 ms first in-process decode (prewarm at
app start), `NemoTextProcessing.xcframework` in the transitive supply chain
— which is exactly why `WispritParakeet` is built but unlinked, and why this
whole section stays behind the human-corpus gate the repo already imposes.
The **live-engine** fork (Parakeet replacing SpeechAnalyzer on the paste
path) stays parked: no partials during the hold (dark `im_streaming` rung),
letter-run collapse breaks the learn loop, and disfluency-verbatim changes
what refine sees — all recorded in the spike verdict. Nothing in the
published data justifies reopening it before human-v1.

---

## 5. Kill list — named so the panel doesn't have to

| # | Fantasy | Why it is dead | Evidence |
|---|---|---|---|
| 1 | **Retraining/fine-tuning Apple's acoustic model** | No API exists, at any privilege level. The model is an OS asset; the only inputs Apple exposes are locale choice, module presets, and (DT only) `contextualStrings`. | Speech framework surface, spike S1 q5 |
| 2 | **`SFCustomLanguageModelData` / `CustomPronunciation`** | Builds, exports, prepares — and has **zero measured effect**. Two probes on this machine. Also no system grapheme→phoneme API remains to feed it. | docs/research/apps-feasibility.md:37; probes `clm_probe.swift`, `clm_probe2.swift` |
| 3 | **`contextualStrings` on the live `SpeechTranscriber`** | Measured no-op ("InsForge" → "Inns Forge" with the term loaded); Apple-confirmed DT-only (forums 801877). Vocabulary correctness lives in the reconciler, where it already works. | docs/notes/asr-notes.md; docs/research/local-tech.md §4 |
| 4 | **AGC / pre-gain / level normalization in the capture path** | Engine is gain-invariant over ~50 dB (this report, §2); boosting *changed words for the worse* in 2 of 3 clips; literature shows AGC wins only far-field. | §2 probe; Google AGC/multi-style-training papers |
| 5 | **Noise suppression / vpio ahead of the engine** | 40/40 configurations degraded across four modern ASR systems incl. Parakeet; artifact component identified as the cause; vpio additionally bundles AGC (dead per #4) and AEC (no far-end exists) and gates onsets (§3's enemy). | arXiv:2512.17562, 2201.06685, 2111.11606 |
| 6 | **Always-on pre-roll ring buffer** | Requires mic live between holds; buys ~50 ms plus anticipation speech. The privacy property is the product. Already rejected (deviations §2) — this report adds the number that makes the rejection cheap. | §3 measurement; docs/notes/deviations.md §2 |
| 7 | **Automatic accent/locale detection, v1** | No LID in the Speech framework; off-the-shelf LID discriminates languages, not English accents; dual-locale live decode costs 406–1790 ms per the repo's own dual-module measurements. Per-user choice + bake-off answers the same question once, offline. | §1; spike S1 Q1/Q4 |
| 8 | **A "whisper mode" model** | No local whispered-speech model exists to ship; the cloud leader acknowledges elevated whisper error rates with a dedicated stack. The shippable subset is §2's threshold fix + meter honesty. | docs/research/wisprflow.md §2 |
| 9 | **Parakeet int4 encoder to halve the hedge's footprint** | Measured: loses exactly the proper nouns the product exists to get right ("Shereek"/"whispered" vs int8's correct decode), for 141 MB. | docs/research/spikes-parakeet.md Q4 |

---

## Appendix — new probes, re-running, and what is NOT proven

**Probe 1 — capture-start latency** (`micprobe.swift`, scratchpad): fresh
`AVAudioEngine` + tap in hardware format per run (the exact
`MicCapture.start()` shape), measures `start()` return and first tap buffer.
5 runs, 48 kHz input: start 42.7–51.1 ms, first buffer 148.7–157.4 ms
(100 ms of that is tap accumulation). Run: `swiftc -O -parse-as-library
micprobe.swift -o micprobe && ./micprobe` (needs mic permission).

**Probe 2 — gain sensitivity** (`gainprobe.swift`, scratchpad): three
`say -v Samantha` 16 kHz clips (`u1/u2/u3`, the spike-S1 sentences), Int16
samples digitally scaled ×1.0…×0.003 plus a ×0.01→×20 boost arm, each fed
100 ms-chunked to a fresh per-session SpeechTranscriber
(`[.volatileResults, .fastResults]`, en-US), finals joined. Full transcript
table in §2. Run: `swiftc -O -parse-as-library gainprobe.swift -o gainprobe
&& ./gainprobe .` after generating the WAVs with the `say` lines from
docs/research/spikes-s1.md "Re-running".

**Not proven, stated plainly:**

- Every probe here is single-machine (M4, macOS 26.5.2) and TTS-fed. The gain
  probe isolates digital gain only — it says nothing about real whispered
  articulation or low-SNR-against-room-tone, and its transcript deltas at
  ×0.003 are one voice, n=3 clips. Direction and mechanism are trustworthy;
  magnitudes are not accuracy claims.
- The locale-assets win (§1) is *mechanism-supported but locally unmeasured*:
  no en-IN vs en-US decode of accented human audio has been run in this repo.
  The bake-off is designed to be the measurement; until it runs, §1 is a
  hypothesis with a cheap, decisive test — not a result.
- The engine-ready race analysis (§3) is from code reading plus two measured
  latencies composed arithmetically; the composed claim ("install beats the
  first chunk in steady state") has not been observed end-to-end with
  instrumentation in the app. The `first_voiced_ms` metric is how it becomes
  observed.
- Disagreement-predicts-error (§4) is established in the literature and
  *plausible* here given the spike's error-profile evidence, but the ROC on
  Wisprit's two specific engines does not exist until human-v1 is decoded by
  both. The proposal is deliberately structured so that measurement precedes
  any user-visible behavior.
- Production `peak_level` telemetry is 8 rows old. Every threshold
  recommendation in §2 is conditioned on accumulating ~100 rows first.
