# Judge — feasibility & evidence

Adversarial review of the four robustness reports (`acoustic.md`,
`personalization.md`, `measurement.md`, `native-feel.md`), 2026-08-10. Lens:
**does the cited mechanism exist on this OS for third parties; is the
prediction falsifiable and sized; do the repo's own prior probes contradict it;
is anything a rebuild of what already exists.**

Method, so the verdicts are attackable on their inputs: I re-read every cited
source line in the tree (all file:line citations below were re-opened, not
trusted), recomputed the live-telemetry statistics from `~/.wisprit/metrics.log`
myself, **independently re-scored the measurement pilot from its surviving
scratchpad artifacts** with my own scorer, confirmed the probe files
(`gainprobe.swift`, `micprobe.swift`, `u1–u3.wav`, the `robustpilot/` fake root)
still exist on disk, and fetched the three load-bearing external citations
(arXiv:2512.17562, the Parakeet TDT v3 model card, Wispr Flow's
supporting-languages page). Anything I could not verify is labeled as such.

**Bottom line first:** these are unusually honest reports. Of ~40
recommendations, I kill **zero**, weaken **five**, and keep the rest — but I
found one internal contradiction between reports that the argument stage must
resolve (the 0.02 threshold, §5.1), one internal inconsistency inside
measurement.md (the "12–14 dB" figure, §3), one systematically understated cost
(Parakeet eval integration, §1.4), and one structural blind spot shared by all
four: they never name that **four of their proposals are gated on the same
missing artifact** — recorded human audio of this user (§6.1).

---

## 0. Verification ledger

Confirmed exactly as claimed (spot list; each was re-opened):

| claim | verification |
|---|---|
| `EvalPaths.settingsHash` omits osBuild | `EvalPaths.swift:156–165`: material is locale/engine/finalize/term-limit only — under a doc comment that promises the exact invariant this breaks. Real bug. |
| `EvalRunner.asrSettings()` hardcodes en-US | `EvalRunner.swift:584` |
| Per-category table is final-stage only | `EvalScoring.swift:130`: `categories(clips(stage: "final"))` |
| `voicedPeakThreshold` 0.02, mirrored twice, reused by mic test | `SpeechAnalyzerEngine.swift:118`, `MetricsSummary.swift:90`, `EmptyReason.swift:48`, `OnboardingMicTest.swift:31` |
| `AsrManager.feed` retains unconditionally, drops to engine until started | `AsrManager.swift:79–83` |
| Paste rung: ⌘V posted → text visible → `sleep(500ms)` → restore; `tInsert` + `flashSuccess` after `deliver()` returns | `Inserter.swift:164–175`, `SessionController.swift:544–560` |
| Live telemetry | Recomputed: 369 rows; paste p50 **769 ms** (n=251); im_streaming p50 **263 ms** (n=14); `peak_level` on exactly 8 rows, 0.0388–0.233; empties 64, 47 sub-1 s, 8 ≥2 s; 25 `timed_out` rows, all empty. Every number matches both reports. |
| Pilot results | Re-scored from surviving artifacts with an independent scorer: orderings replicate — wn5 worst by far (+18.6 pts crude vs their +16.8 refined), aman/tara worst voices, clip+6/r240 within noise, **zero empty transcripts across all 950 clips**. The pilot happened and its numbers are honest. |
| ST 9 English locales / DT `[en_US]` / dual-module 406–439 & 1377–1790 ms / 14/18 vs 8/18 / 82 ms p50 / 562 MB / int4 rejected / 41 FPs | all present in `spikes-s1.md` and `spikes-parakeet.md` as cited |
| SFCustomLanguageModelData zero effect; ST `contextualStrings` byte-identical A/B | `apps-feasibility.md`; probes exist at `docs/research/probes/clm_probe{,2}.swift` |
| Pre-roll rejection | `deviations.md` §2 ("No ~300 ms rolling pre-buffer (deliberate, for privacy)") |
| Apple-Intelligence-only directive | `deviations.md` §"Native rewrite (2026-08-05)" |
| arXiv:2512.17562 | fetched: 4 models × 10 conditions, noisy beat enhanced in all 40, 1.1–46.6 absolute. One nit: the paper's metric is **semWER**, not plain WER — doesn't change the kill. |
| Parakeet v3 model card | fetched: SNR curve 6.34→19.88 and Earnings-22 11.42% exactly as quoted. Note v3 is **25-language multilingual** — worth remembering when arguing its English headroom. |
| Wispr Flow language router | fetched: engine-per-language, accent confidence scoring, "more than half" claim, Hinglish — all on the page as quoted |
| Pill/menu/UI claims | `errorMessageCharacters=40` (`PillGeometry.swift:149`), maxWidth 196 / 6.5 pt advance (`:187,191`), `.truncationMode(.head)` (`PillSurface.swift:77`), zero `NSSound`/`AudioServices` hits, `isSuppressed` guards every show path, `iconSpec` has no secure-input state, `openDoctorInTerminal` drives Terminal via AppleScript (`AppController.swift:745–760`), `pasteLast` styles secure-input as `flashError` (`SessionController.swift:635–637`) |
| `utterance_detail` triple schema, `hit_count×recency` ranking, `contextualTermLimit` cap, Refiner "provably ignores when hinted", post-refine deterministic pass | `History.swift:33–68`, `DictionaryStore.swift` header, `AsrEngine.swift:96–101`, `Refiner.swift:7–11` |
| Eval CLI engine enum is `{speech, dictation}` — **no parakeet** | `EvalCommand.swift:44–46` — this is the §1.4 weakening |

Discrepancies found (none fatal, all should be fixed before the argument stage
quotes them):

1. **acoustic.md says "131-utterance human-v1 script set"; the README says
   135.** acoustic faithfully copied `spikes-s1.md:270`, which is stale against
   `tools/eval/scripts/human-v1/README.md:3`. Fix the spike doc.
2. **personalization.md P0-2 says minSimilarity tightens 0.55→0.60; the spike
   says 0.50→0.60** (`spikes-parakeet.md:117`). Citation error, direction
   unaffected.
3. **native-feel.md says 17.7% empty rate; it is 17.3%** (64/369).
4. **measurement.md §7's "12–14 dB hotter" is internally inconsistent** — see
   §3, verdict C9.
5. `LearnPlausibility.swift` lives in `WispritCorrections/`, not
   `WispritDictionary/` as personalization.md implies. Content as quoted.

---

## 1. acoustic.md — verdicts

### A1. Locale bake-off (§1) — **KEEP**, with the gate named and one portability gap
Mechanism verified end to end in code: locale is one settings string threaded
`Settings.swift:57` → `AppController.swift:122` →
`SpeechAnalyzerEngine.swift:46`; the picker exists (`SettingsPage.swift:86–96`);
preflight and installer exist (`AsrPreflight.swift:30–79`); `settingsHash` keys
locale so cached bake-off runs cannot collide (`EvalPaths.swift:156`); the
en-US hardcode is real (`EvalRunner.swift:584`); the DT-assets gotcha is real
(spike: DT installed = `[en_US]` on a machine with 9 ST locales). The
prediction is falsifiable with a named kill criterion ("if deltas are noise,
this section costs one eval run and dies honestly") — the report's best
property. Two weakenings the panel should carry into the argument: **(a)** the
section's cost line omits its actual gate — the bake-off decodes "the same
recorded human audio," which does not exist yet; the real cost is a recording
session (see §6.1, and note the count is 135, not 131). **(b)** the same spike
that supplies the 9-locale fact also records
`AssetInventory.maximumReservedLocales = 5`; on *this* machine 9 are already
installed so the bake-off is unblocked, but the productized "which English do
you speak?" feature must handle machines where nine simultaneous English
assets may not be installable. Unaddressed, cheap to check, not a blocker.

### A2. Gain invariance → kill AGC/pre-gain/normalization (§2) — **KEEP**
The probe artifacts survive in the scratchpad (`gainprobe.swift`, `u1–u3.wav`)
and — decisively — measurement.md's *independent* 550-clip pilot replicates the
direction (g-36 ≈ +2 pts, zero empties; I re-scored it myself from artifacts).
Two independent measurements, one mechanism (log-mel + feature normalization),
converging literature. The kill is safe. The one caveat the report itself
states correctly: this exonerates *digital gain*, not whispering or low SNR.

### A3. `voicedPeakThreshold` miscalibration (§2) — **KEEP**, weaken the floor prediction
The code chain is exactly as claimed (verified, ledger above), and "the engine
transcribed at meter 0.010 while 0.010 < 0.02 is classified benign-silent" is
arithmetically true. But the evidence that the engine hears at 0.003–0.010 is
**digitally scaled clean TTS** — a real mic at that meter level carries a real
noise floor, and measurement.md's own central finding (real "quiet" is low SNR,
not low gain) cuts against the strong reading. The specific prediction "the
5th-percentile voiced-success peak will land well below 0.02 and a ~0.005 floor
reclassifies real failures" may not survive real-mic noise. The
recommendation as *stated* is properly conditioned (wait for ~100 `peak_level`
rows — only 8 exist, verified), so it survives; quote it as "the threshold is
calibrated to a mic heuristic and must be re-derived from telemetry," not as
"0.005 is the right floor." Also see §5.1: native-feel P5 builds on the very
threshold this section undermines, and §6.2 offers a probe that could
obsolete the hand-tuned floor entirely.

### A4. Replay retained head at engine install (§3, fix 1) — **KEEP**, but invert its order with fix 2
Feasibility is better than the report argues: burst-feeding audio
faster-than-realtime into SpeechTranscriber is already proven safe *by the
repo's own eval harness*, which feeds unpaced at ~35× realtime and gets
identical transcripts (spike-verified) — so replaying a 100–200 ms head at
install is a mechanism with an existing existence proof, a point the report
missed in its own favor. The "~10 lines" sizing is optimistic about the
interleave hazard (a live chunk arriving between started-flag flip and replay
would land out of order), but the report names the hazard and the locks exist.
The real problem is **internal ordering**: fix 2 is titled "measure exposure
before building anything else" and carries the kill criterion ("if p5 > 300 ms,
clipping is a phantom and no further work is justified") — which logically
precedes fix 1, yet fix 1 is ranked above it. Land `first_voiced_ms` first (or
both in one change); do not let the argument stage schedule the splice before
the metric exists.

### A5. `first_voiced_ms` metric (§3, fix 2) — **KEEP**, merge with measurement.md's instrumentation
Same schema, same rows, same append-only rule as measurement.md §7's
`peak_level`/`audio_ms`/noise-floor asks. Four fields, one metrics change, two
reports — ship as one diff (§5.4).

### A6. Pre-roll stays dead — **KEEP**
`deviations.md` §2 verified; the new ~50 ms number makes the standing rejection
cheaper, exactly as claimed.

### A7. Noise suppression / vpio kill — **KEEP**
The 40/40 citation checks out by direct fetch (with the semWER nit). vpio's
AEC-without-far-end and AGC-already-dead reasoning is sound. Capture path taps
raw hardware format (`MicCapture.swift:126`, verified).

### A8. "Accuracy mode" — disagreement-gated selective re-decode (§4) — **WEAKEN**
The premises hold: different error profiles verified in the spike (14/18 vs
8/18), model-card numbers verified by fetch, disagreement-as-error-signal is
real literature, and the measure-before-behavior structure (log the score,
build the ROC, only then ship UX) is the right shape. Two understatements:
**(a) the eval harness cannot run Parakeet.** The CLI engine enum is
`{speech, dictation}` (`EvalCommand.swift:44–46`); "one extra column" is
actually "add a third engine to EvalRunner (linking `WispritParakeet` — whose
`NemoTextProcessing` supply chain is the stated reason it is unlinked from the
app) or resurrect the spike's out-of-repo `run.sh` harness and reconcile two
scorers." Days, not hours, and a policy decision about what the eval binary
links. **(b)** the ROC needs human-v1 decoded by both engines — the same
unrecorded corpus as A1 (§6.1). Neither kills the idea; both belong in its
cost line before the panel prices it.

### A9. Kill list (§5, nine entries) — **KEEP all nine**
Every repo-citable kill was re-verified against its source (ledger above);
the external ones (AGC far-field-only, enhancement-degrades) check out. This
list does its job: nothing on it deserves argument time. One addition: kill #7
(auto accent detection) is over-argued — it is also killable one level
earlier, because per-user locale choice answers the question once, offline,
which the report itself says in §1.

---

## 2. personalization.md — verdicts

### B1. P0-1 hear-phrase mining from stored triples — **KEEP**
The data exists exactly as described (`utterance_detail` with
raw/corrected/refined/inserted/vocab/ai/termsHit — verified in
`History.swift:33–68`); the alignment machinery exists; the ledger discipline
it inherits is real (the SHARHUUE bill is verbatim in
`LearnPlausibility.swift`, though in `WispritCorrections/`, not
`WispritDictionary/`). The chronological-replay prediction is falsifiable on
data already on disk with a named kill criterion, and the
safe-by-construction argument (only adds hear evidence to user-approved terms)
is structurally sound. One supply caveat to add: `history_enabled` is a
setting and `history_limit` defaults to 1000 rows (`Settings.swift:66–67`,
verified) — the miner starves silently for history-off users and its evidence
window is capped; say so in the design.

### B2. P0-2 frequency-weighted biasing — **KEEP** (fix the 0.50 citation)
`hit_count × recency` ranking confirmed as built-but-unconsumed
(`DictionaryStore.swift` header states it exists *for consumers that cap*; the
cap parameter exists at `AsrEngine.swift:96–101`; nothing passes it). The
Parakeet 41-FP evidence is verified; note the tightening is 0.50→0.60, not
0.55→0.60. Also worth arming the proposal with: `apps-feasibility.md` records
the "no 50-term cap" verdict as **config-sensitive and contested between two
probes** — which strengthens the case that the cap should exist and be
adaptive rather than trusting the no-cap measurement forever.

### B3. P0-3 consented personal eval corpus — **KEEP**, and promote
Correctly identified as the measurement enabler with a real privacy cost,
honestly priced. The judge's addition: this is not merely one report's P0 —
it is the same gate as A1's bake-off, A8's ROC, and measurement §8.2's
calibration. See §6.1; the argument stage should treat it as the program's
critical path, not as one item in one report's ranking.

### B4. P1-4 deterministic style rules — **KEEP**
Ranked correctly on supply, not mechanism: the IM rung's `.changed`-without-
text refusal is pinned in `ReadBackTests.swift` (verified), so the data
starvation claim is true. The conservative rule-taxonomy warning is right.

### B5. P1-5 per-app vocabulary profiles — **KEEP** as ranked
The one nonzero privacy-narrative item, ranked behind zero-cost items for
exactly that reason. Nothing to attack; the report attacked itself correctly.

### B6. P2-6 refine few-shot — **KEEP** (the negative assessment)
The two key facts verified: `Refiner.swift:9–10` records the ~3B model
provably ignoring hinted vocabulary, and the pipeline comment at
`Refiner.swift:7–11` confirms the deterministic dictionary pass runs *after*
refine — so vocabulary few-shot is redundant by construction, exactly as
argued. The eval-lock tax (prompt-hash provenance doubling) is real. The
report's own bar — demand the battery-with-exemplars number before argument
time — is the correct disposal.

### B7. P2-7 generic FM adapter — **KEEP** the deferral
The adapter facts match Apple's documented toolkit story (version-locked
adapters, entitlement for deployment, developer-time training) and the repo
has lived the treadmill (`RefineInstructions.swift:9`: "Apple swaps the
on-device model; 26.4 did" — verified). Deferral with a named re-entry
condition (≥2 WER points left on the table on human-v1 refined stage) is the
right shape. Note the re-entry condition is also gated on §6.1.

### B8. Kill list (seven entries) — **KEEP all seven**
Kills 1–3 are verified-absent API surfaces; kill 4 keeps the cheap per-OS
re-probe (probes on disk, verified); kill 6 is killed by standing product law
with the reversal condition named, which is the honest way to kill it. The
rung-4-ceiling framing is argument, not recommendation, and it is fair.

---

## 3. measurement.md — verdicts

This is the best-evidenced report of the four: its pilot artifacts survive in
the scratchpad and I re-scored them independently — the orderings replicate
(noise ≫ accent > everything; aman/tara worst voices; zero empties across 950
stressed clips). That is a stronger position than any of the other three
reports occupy.

### C1. Ship `tts-accents-v1` + `tts-stress-v1` + corners (§6.1) — **KEEP**
Costs are measured, not estimated; the zero-code `category`=condition trick is
proven in the surviving pilot; the star-design argument against the full
cross-product is right. The TTS banner discipline is maintained throughout.

### C2. Enhanced/Premium voice downloads — **KEEP**
Cheap, removes a named confound, honestly flags that the catalog can't be
enumerated from CLI. Voice inventory claim spot-checked against `say -v '?'`.

### C3. Raw-stage table + `emptyRate` + four-component RI deck (§6.2.1–3) — **KEEP**
Final-stage-only confirmed at `EvalScoring.swift:130`; no empty-rate metric
exists in `StageMetrics` (verified); the refusal to blend the four components
into one scalar is correct and pre-empts the obvious attack. The deck's
baseline volatility argument (wn5 as model-churn detector) is a genuinely good
idea.

### C4. Fold osBuild into the ASR cache key (§6.2.4) — **KEEP**, prioritize
Confirmed real by code read, and aggravated: the `settingsHash` doc comment
explicitly promises "add a field and every cached transcript is correctly
invalidated" — the field that DEFINITIONS.md itself says moves transcripts is
missing. One line, 2-minute re-transcribe cost, prevents a provenance lie.
The single cheapest correctness fix in all four reports.

### C5. Bandlimit-8k cell (§5.7) — **KEEP**
The motivating incident is real (I found the 08-05 empty cluster in the log);
the cell is nearly free and maps to the one failure class the live log has
actually recorded.

### C6. `peak_level`/`audio_ms` on every row + noise-floor field (§7) — **KEEP**, merge with A5
Same appeal as A5: one metrics diff, both reports satisfied. The noise-floor
field is the bridge that maps live audio onto the wn cells without retaining
audio — the best instrumentation idea in the program.

### C7. Public real-speech rung (LibriSpeech/L2-ARCTIC/Common Voice, §8.1) — **KEEP**
`CorpusSource.librispeech` verified in the schema; the work is a manifest
importer; the falsifiable prediction (accent *ordering* must reproduce or the
accent deck gets demoted, with a promised appended correction) is exactly the
right contract for synthetic evidence.

### C8. Record human-v1 — **KEEP**, elevate (§6.1)
The report lists it as one rung; it is the program's critical path.

### C9. The "12–14 dB quieter" figure (§7) — **WEAKEN**
Internal inconsistency: `PcmFormat.level` is `min(1.0, RMS×4)` — clamped
(verified at `PcmFormat.swift:86`) — and the report's own pilot table puts
unscaled `say` output at eval peakLevel **0.998** (at the clamp), yet §7
quotes unscaled `say` at **0.59–0.77** "on the same scale." Both cannot be the
same statistic on the same audio, and dB arithmetic against a clamped meter is
invalid near the top. The *conclusion* survives on the unclamped side — the
user's live range 0.039–0.233 (recomputed, exact) sits far below any TTS
regime, so "g-12 is the realistic cell" stands — but the specific "12–14 dB"
number should not be quoted until someone states which statistic 0.59–0.77 is.

### C10. "Deltas under ~2 points are within noise" — **WEAKEN** (mildly)
The ±1.6-pt s.e. is a per-word binomial computation; ASR errors cluster by
utterance, so the true s.e. is larger and the noise floor is closer to 2–3
pts. None of the conclusions the report actually drew depend on a sub-2-pt
delta (the axes it calls real are +6.5 to +16.8), so this is a framing fix,
not a result change.

### C11. Kill list (§6.3, six entries) — **KEEP all six**
Voice-cloning TTS, realtime pacing, blended scalar, live contextualStrings,
acoustic-model training, clipping-as-concern: each killed with either a repo
measurement or a measured no-op. Nothing to add.

---

## 4. native-feel.md — verdicts

### D1. P1 — fix the paste-rung feedback inversion — **KEEP**
The highest-confidence single item in the program. Every element verified:
⌘V posted, *then* 500 ms sleep, *then* restore (`Inserter.swift:164–175`);
`tInsert` stamped and `flashSuccess` fired only after `deliver()` returns
(`SessionController.swift:544–560`); paste p50 769 ms vs im 263 ms recomputed
from the log exactly. The mechanism (capture delivery timestamp inside
`InsertResult`, flash before the restore sleep) changes no safety semantics.
The honest-metric note (the p50 "falls" to ~270 ms because the metric was
overstating, not because anything got faster) is exactly the right RESULTS
discipline.

### D2. P2 — the seven missing §2.5 transitions — **KEEP**
Verified by reading `Pill.apply` (`Pill.swift:183–206`): `setFrame(display:false)`
+ `orderFrontRegardless`/`orderOut`, no `NSAnimationContext`, no `.animation`
on the tint/width/collapse paths. The constraint carried (level-tick path stays
animation-free, silence stays zero-redraw, Reduce Motion) is the right one.
Effort "a day" is plausible; the verification being a taste pass is honestly
stated.

### D3. P3 — error-copy double truncation — **KEEP**
Confirmed by arithmetic on verified constants: 40-char budget
(`PillGeometry.swift:149`) vs 196 pt cap at 6.5 pt/char (`:187,191`) ≈ 28
chars, with `.head` truncation (`PillSurface.swift:77`) eating the diagnosis
first. The proposed test (rendered width fits every `flashEmpty` string) is
the right pin.

### D4. P4 — sound design — **KEEP**
Zero `NSSound`/`AudioServices` hits verified; `pill_hidden` is a real setting
(`Settings.swift:64`) and `PillModel` suppresses every show path on it
(verified at `:170,190`) — so the "a hidden-pill user has no feedback channel"
claim is code-true, which makes this more than taste. The honesty contract
(mic-open cue only after `audio.start()` succeeded, mirroring the orange rule)
is the right design constraint. Superwhisper convention: cited, not
re-verified here; the internal argument stands on its own.

### D5. P5 — live "No audio — check mic" tail — **KEEP the goal, WEAKEN the trigger**
The gap is real (the level ticker delivers zeros all hold long; the user
learns at release +1.6 s — path verified). But as specified, the cue keys on
"consecutive sub-threshold ticks" against the same 0.02 floor that acoustic §2
just measured as ~2 orders of magnitude above the engine's actual floor — a
genuinely quiet speaker whose words are transcribing fine would stare at
"No audio — check mic" for the whole hold. This is the one direct
cross-report contradiction (§5.1). The fix is cheap: clear/suppress the cue
when partials are arriving (engine evidence beats meter evidence), and key the
meter floor to whatever A3's telemetry recalibration lands on. With that
amendment, keep.

### D6–D8. P6 (Doctor → Setup page), P7 (engine token in captions), P8 (pasteLast style unification) — **KEEP all three**
Each verified in code: Terminal AppleScript at `AppController.swift:745–760`
with the "run Doctor" failure copy at `:699`; `HomeSource.caption` appends the
raw engine string (`HomeSource.swift:69–74`); `pasteLast` styles secure-input
as `flashError` while the main path has `flashBlockedSecure`
(`SessionController.swift:635–637` vs `:551–557`). Minutes-to-hours each,
pure de-leakage.

### D9. P9 — secure-input lock on the menu-bar icon — **KEEP**
`StatusIconState` verified to carry only `dictationEnabled`/`needsSetup`/state
(no secure-input awareness); `IsSecureEventInputEnabled()` is a public API the
doctor already reads. The sampling discipline (never while a key is held) is
the right constraint. This is the only channel that survives the event-tap
suppression, so the mechanism claim is airtight.

### D10. P10 — time-to-wow metrics row — **KEEP**
One row, closes a real measurement hole, matches the eval culture.

### D11. P11 — skip restore on queued re-press — **KEEP the deferral, or defer harder**
The report itself sequences it after P1 soaks and prices it multi-day "for the
care." It trades the #1-competitor-bug safety margin
(`Inserter.swift:39–42`'s reason for the 500 ms floor) on an inferred signal.
Correctly last; the argument stage should feel free to drop it entirely — P1
removes the *felt* cost of the sleep, leaving only the fast-re-press edge
case, whose frequency nobody has measured. If it proceeds, demand the
frequency measurement first (a queued-press-during-restore counter is one
line).

### D12. Kill list (§6, eight entries) — **KEEP all eight**
Each mechanism claim checked: marked-text acceptance is app-side truth;
shrinking the restore delay reintroduces a documented bug class; trackpad
haptics are HIG-scoped to trackpad interaction and do nothing for keyboard
hands (correct — category error, not degraded option); Input Monitoring binds
at launch (correct macOS behavior); menu-bar animation burns the forbidden
budget; partial cadence and the finalize floor belong to Apple. The
"streaming everywhere buys almost nothing post-P1" kill is quantitatively
supported by the 263 ≈ 270 ms convergence (n=14 caveat honestly carried).

---

## 5. Cross-report conflicts the argument stage must resolve

1. **The 0.02 threshold (A3 vs D5).** acoustic.md §2 demonstrates the meter
   floor is miscalibrated relative to the engine; native-feel P5 proposes a new
   user-facing nag *keyed on that same floor*. Neither cites the other.
   Resolution is easy (P5 clears on partial arrival; floor comes from A3's
   telemetry recalibration) but it must be resolved in one place, or the
   program ships a new feature on a constant one of its own reports killed.
2. **fix-1-before-fix-2 (acoustic §3).** The replay splice is ranked above the
   metric whose stated purpose is to decide whether the splice is justified.
   Land `first_voiced_ms` first.
3. **The recording gate is named nowhere but load-bearing everywhere** — §6.1.
4. **Instrumentation must be one diff, not two.** A5 (`first_voiced_ms`) and
   C6 (`peak_level`/`audio_ms`/noise-floor) touch the same append-only metrics
   schema for the same rows. One change, reviewed once.
5. **Stale numbers to reconcile before anything is quoted upward:** 131 vs 135
   utterances; 0.50 vs 0.55 minSimilarity; 17.3 vs 17.7% empty rate; the
   12–14 dB figure (C9).

## 6. What the researchers missed

### 6.1 The critical path is a recording session, and no report says so
Four of the program's highest-value items are gated on the same missing
artifact: the locale bake-off (A1), the disagreement ROC (A8), the per-user
scoreboard (B3), and the synthetic-axis calibration (C8) all require consented
recorded human audio that does not exist. Each report treats the gap as its
own local footnote; none names the convergence. The dominating move — cheaper
than most single recommendations above — is: **schedule the human-v1 recording
session (this user + the protocol's accent-spread speakers), and the moment
spk01's pass-1 audio exists, the bake-off, the ROC groundwork, and the
per-user WER row all unblock simultaneously.** Additionally, A1 does not need
the full 135-utterance × 3-pass protocol for its first cut: ~20–30 verified
clips of this user decode across 9 locales in minutes and either justify or
kill the locale chooser same-day. Decouple the mini bake-off from the full
protocol.

### 6.2 `SpeechDetector` was cited as a kill-list witness and never considered as a tool
personalization.md names the SpeechAnalyzer module roster ("transcribers +
`SpeechDetector`") to prove nothing is trainable — and that is the only
mention of `SpeechDetector` in the entire repo. Apple ships a
voice-activity-detection *module* in the same framework the app already uses,
and two reports are fighting about a hand-tuned RMS threshold (A3, D5) that a
VAD verdict could replace with an engine-calibrated one: run `SpeechDetector`
off-path over the already-retained PCM of empty utterances and let *it* decide
silent-vs-produced-nothing. Probe first — its API may be gating-only rather
than verdict-reporting, and the dual-module cost measurements (406+ ms) bound
the wrong topology (this is off-path, post-hoc, empties-only) — but the probe
is an afternoon, and if it lands it obsoletes the entire threshold-
recalibration debate. This is the one genuinely missed mechanism.

### 6.3 Minor misses (each one line)
- A1's productized form needs a `maximumReservedLocales = 5` story for
  non-dev machines (§1, A1).
- B1 should state its dependency on `history_enabled` and the 1000-row cap.
- A8's cost line must include the eval-harness Parakeet integration and the
  linking-policy decision (§1, A8).
- The burst-feed existence proof (unpaced eval = faster-than-realtime feeding
  with identical transcripts) strengthens A4 and nobody used it.

## 7. Verdict summary

| # | Recommendation | Verdict |
|---|---|---|
| A1 | Locale bake-off | **keep** (name the recording gate; reserved-locales gap) |
| A2 | Gain-invariance; kill AGC/pre-gain | **keep** |
| A3 | Threshold recalibration | **keep** (weaken the 0.005 prediction) |
| A4 | Head-replay at install | **keep** (after A5, not before) |
| A5 | `first_voiced_ms` | **keep** (merge with C6) |
| A6 | Pre-roll stays dead | **keep** |
| A7 | NS/vpio kill | **keep** |
| A8 | Accuracy mode / disagreement ROC | **weaken** (harness cost, recording gate) |
| A9 | Kill list ×9 | **keep all** |
| B1 | Hear-phrase mining | **keep** (history-off caveat) |
| B2 | Frequency-weighted biasing | **keep** (fix 0.50 citation) |
| B3 | Personal eval corpus | **keep**, promote to critical path |
| B4 | Style rules | **keep** |
| B5 | Per-app profiles | **keep** as ranked |
| B6 | Few-shot negative assessment | **keep** |
| B7 | Generic adapter deferral | **keep** |
| B8 | Kill list ×7 | **keep all** |
| C1 | Matrix corpora | **keep** (verified from artifacts) |
| C2 | Enhanced voices | **keep** |
| C3 | Raw table + emptyRate + RI deck | **keep** |
| C4 | osBuild cache key | **keep**, do first |
| C5 | Bandlimit cell | **keep** |
| C6 | Live instrumentation | **keep** (merge with A5) |
| C7 | Public-corpus rung | **keep** |
| C8 | Human-v1 | **keep**, elevate |
| C9 | "12–14 dB" figure | **weaken** (clamp inconsistency) |
| C10 | ±1.6-pt noise floor | **weaken** (clustering) |
| C11 | Kill list ×6 | **keep all** |
| D1 | Paste feedback inversion | **keep** — highest confidence |
| D2 | §2.5 transitions | **keep** |
| D3 | Error truncation | **keep** |
| D4 | Sound design | **keep** |
| D5 | Live dead-mic cue | **keep goal, weaken trigger** (conflict with A3) |
| D6–D8 | Setup routing, caption, pasteLast style | **keep all** |
| D9 | Secure-input menu lock | **keep** |
| D10 | Time-to-wow row | **keep** |
| D11 | Skip-restore on re-press | **keep deferral / drop** |
| D12 | Kill list ×8 | **keep all** |

Killed outright by this review: nothing. The four reports killed their own
fantasies with citations that survive re-verification — the panel's time is
better spent on §5's conflicts and §6.1's sequencing than on re-litigating any
individual recommendation.
