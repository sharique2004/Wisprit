# Judge — impact per engineering dollar, on the scoreboard

Adversarial-judge pass over the four robustness reports (`acoustic.md`,
`personalization.md`, `measurement.md`, `native-feel.md`), 2026-08-10. Lens:
**the eval harness and live metrics.log are the only arbiters.** Every item
below is ranked by (number that moves) ÷ (engineering cost), with the delta and
the date it becomes measurable stated per item. Items whose impact cannot land
on a number — or whose number is dominated by a cheaper item — are demoted or
killed regardless of how good the prose was.

Verdict format: **do-now** (days of work, measurable immediately),
**gated** (blocked on a named gate — mostly the human-v1 recording, twice on
telemetry accumulation, once on another workstream), **never** (killed; the
consolidated kill table at the end covers all four reports plus five
judge-added kills).

---

## 0. The three rulings that reorder everything

1. **The cheapest unblocker in the entire program is not code.** Human-v1
   recording is 3 people × ~1 hour with tooling that already exists
   (`Wisprit eval record`, protocol written, scripts written). It gates the
   per-user locale bake-off, the Parakeet disagreement ROC, every accuracy
   claim, the tone axis, and the adapter re-entry decision — roughly half the
   combined portfolio. No engineering item below has a better
   impact-per-dollar ratio than scheduling this session this week.
2. **Two reports combined de-gate the top accent lever, and neither noticed.**
   `acoustic.md` names locale-matched assets the biggest unaddressed accent
   lever but frames the bake-off as waiting on human-v1. `measurement.md`
   independently proposes the public real-speech rung (L2-ARCTIC: 24 speakers
   incl. Hindi-L1; Common Voice with self-reported India/Scotland/etc.
   labels) as an hours-of-work download. Composed: **decode real
   Hindi-L1/India-labeled English under en_IN vs en_US assets this week**,
   using the one-parameter change both reports already identified
   (`EvalRunner.asrSettings()` hardcodes en-US, `EvalRunner.swift:584`). The
   accent lever's go/no-go number arrives in days, not after a recording
   session. This is the highest-stakes measurement available right now.
3. **The scoreboard must exist before the deltas can.** Most predicted deltas
   across all four reports are quoted against per-axis tables, an emptyRate
   metric, and telemetry fields that are proposed but not landed. The
   measurement report's deck (pilot already proven end-to-end, ~2 min ASR per
   engine per OS build) is therefore not one item among peers — it is the
   precondition for paying out every other item's prediction, and it ranks
   accordingly.

---

## 1. Do-now — ranked

Total bucket cost: **≈ 10–12 engineering days + 3 recording person-hours +
one System Settings session + ~1–4 GB disk.** Everything in this bucket has
either a scoreboard/telemetry number or a binary artifact, named per item.

| # | Item | Source | Cost | The number that moves | Predicted delta | Measurable when |
|---|---|---|---|---|---|---|
| J1 | Fold osBuild into `EvalPaths.settingsHash` | M §6.2.4 | **one line** | cache provenance (prevents every future deck number being stale after an OS model swap) | post-update runs re-transcribe (~2 min); wn5 cell moves >±3 pts across model swaps while g0 stays within ±1.5 (M §8.3.3) | next macOS update |
| J2 | **Schedule and run human-v1 recording** | M §8.2, gate for A§1/A§4/P0-3/P2-7 | 3 × ~1 h people-time, ~zero code | creates the only numbers the repo permits as accuracy; opens the entire gated bucket | n/a — this *is* the measurement | the week it runs |
| J3 | Enhanced/Premium voice downloads **then** the robustness deck: `tts-accents-v1` + `tts-stress-v1` + corners + bandlimit8k cell + raw-stage category table + `emptyRate` + RI deck v1 | M §3, §5.7, §6.1–6.2 | 2–3 days (+1–4 GB) | the per-axis scoreboard itself | baselines locked: RI-noise +16.8 / RI-accent +8.3 / RI-level +2.4 / RI-empty 0; any nonzero matrix empty rate is news; per-release re-run ≈ 2 min | day it lands |
| J4 | Telemetry completion: `peak_level` + `audio_ms` on every row, noise-floor field, `first_voiced_ms` | M §7 + A §3.2 (merged — the reports double-counted this) | ~half day | classification of the 17.3 % live empty rate; clipping-exposure distribution; starts G3's 100-row clock | ≥80 % of sub-second empties show normal levels (finger slips, M §8.3.4); if `first_voiced_ms` p5 > 300 ms, clipping work beyond J7 is dead | 1–2 weeks of normal use |
| J5 | Real-speech rung + **locale cross**: LibriSpeech/L2-ARCTIC/Common Voice importer; parameterize `EvalRunner` locale; decode accented subsets under en_IN/en_GB vs en_US assets | M §8.1 × A §1 | 2–3 days | the accent lever's go/no-go | if the lever is real: ≥10 % relative WER win for matched assets on Hindi-L1 speech (A's own bar); if flat: the lever demotes before any UI is built. Also tests M §8.3.2 (synthetic accent ordering survives real speech, else the accent deck demotes to voice-QA) | days |
| J6 | Paste-rung feedback inversion fix (flash + stamp before the 500 ms restore sleep) | N P1 | hours | live `release_to_text_ms`, paste rung | p50 ~770 → ~270 ms — an honest re-measure, not a speedup; annotate the discontinuity in RESULTS and split out `restore_ms`. Also add the restore-window re-press counter here (see N-P11 kill) | immediately, n grows daily |
| J7 | Retained-head replay at engine install + delayed-`begin` regression test | A §3.2 fix 1 | ~half day (~10 lines + test) | cold-start head-loss (deterministic test); `first_voiced_ms` co-reads exposure | **honest expected live delta ≈ 0** — the race is usually won; justified by cost, not impact. Must not be sold as an accuracy win | test passes day one |
| J8 | P0-1 **replay probe only** — mine hear-phrases from first half of the existing history DB, replay second half; do not build the miner yet | P P0-1 | ~1 day scripting | new catches per 100 utterances on the user's own history | kill bar is the report's own: < a handful of catches/100 ⇒ the feature dies before its UX is built. Judge caveat: ~300 texted utterances from one user — underpowered is a likely and acceptable outcome | day it runs |
| J9 | Seam batch: error-truncation fix (N P3), live dead-mic cue (N P5), Doctor→Setup routing (N P6), engine-token caption (N P7), `pasteLast` style unify (N P8) | N §7 | ~1 day total | P5 is the metric carrier: in-hold warning for the ≥2 s starved-empty class (8 real losses incl. a 19.4 s hold) | P5: long-hold empties become warned-during-hold; proxy = count of holds ≥10 s with zero voiced ticks that ran to completion → ~0. P3: width unit test. P6/P7/P8: snapshot tests | immediately |
| J10 | Sound cues (mic-open, commit) with settings toggle | N P4 | 1 day, hard cap | none — admitted; justification is a **functional gap**, not taste: `pill_hidden` is a shipped setting under which the user currently has zero feedback channel | binary matrix artifact: pill visible/hidden × sound on/off; cue never fires when `audio.start()` fails | manual, day one |
| J11 | Secure-input lock state on the menu-bar icon | N P9 | 1 day, hard cap | none — binary artifact: password field focused → icon lock ≤ 2 s | closes the recurring "dead in Slack" moment; the only surviving feedback channel gets a state | manual, day one |
| J12 | Time-to-wow onboarding metrics row | N P10 | hours | first-launch → first `didDictate` | judge caveat: **n ≈ 0 until new installs exist** — land it whenever onboarding is next touched, not as dedicated work | first fresh install |
| J13 | §2.5 pill transitions (7 missing rows) | N P2 | 1 day, hard cap; **after J6** (its own sequencing note) | none on the scoreboard | demanded artifacts: spec-table compliance 7-missing → 0, before/after screen recordings, zero-redraw regression test still green. Ranked last precisely because it moves no number | manual, day one |

**Sequencing constraints (violating these wastes money):**

- **J3 order is internal**: download Enhanced voices *before* generating the
  accent corpus, or the corpus regenerates at the new tier and the sha-keyed
  cache churns (the "re-scoring is free" property dies).
- **J1 before J3**: lock cache correctness before the deck's baselines are
  recorded, or the first OS update poisons them.
- **J5's locale parameterization is the same change G1 needs** — do it once.
- **J6 before J13** (native-feel's own note: committed-state timing looks
  wrong until the checkmark stops arriving late).
- **J4 starts two clocks**: G3's 100-row `peak_level` gate (~1–2 weeks at the
  observed ~14 utterances/day) and J7's exposure verdict.

**What the do-now bucket buys, stated as the scoreboard's end state:** four RI
baselines tracked per release; the accent lever decided on real speech; the
headline latency metric honest at ~270 ms; the 17 % empty rate decomposed into
finger-slips vs real loss; and every gated decision below waiting on a named
number with a named arrival date.

---

## 2. Gated — do when the named gate opens

### Gate: human-v1 recorded (opened by J2)

| Item | Source | Cost | Decision number | Bar |
|---|---|---|---|---|
| G1. Per-user locale bake-off + chooser UI | A §1 | small: N−1 decode passes (minutes) + DT-asset dual-install + Settings copy | per-locale WER on the user's own recordings | ship the chooser if best locale ≤ en-US −10 % relative; else the section "costs one eval run and dies honestly" (A's words, held to). **Cost the panel must not forget**: `DictationTranscriber` assets are en_US-only on this machine — locale switch without a second `assetInstallationRequest` silently breaks the vocabulary channel (A §1 gotcha). J5 may kill G1 before it ever runs — that is the point of J5 |
| G2. Parakeet bundle: dual-engine decode of human-v1 → disagreement ROC → accuracy-mode go/no-go; plus per-voice-spread prediction (M §8.3.1) and the weighted-biasing re-run (P0-2: 138 terms/41 FPs → top-100 by hit_count×recency) | A §4 + M §8.3.1 + P P0-2 | matrix per engine ≈ +2 min ASR; ROC is one extra cached column; biasing re-run is `run.sh` | utterance-level disagreement vs reference WER | accuracy mode ships only if a threshold catches ≥50 % of worst-decile utterances at ≤10 % FPR (A's bar); log-only before any user-visible behavior. P0-2 adoption rides the same gate because its payoff is 90 % on the Parakeet channel; its DT-side benefit at 138 terms (~0.4 s off-path setup) does not justify standalone work |
| G3′. Reverb/IR convolution cell | M §5.4 | ~1 day | pass-3 real-conditions delta vs synthetic bracket | add **only if** human pass-3 damage lands outside the (g-24 + wn) bracket — M's own rule; pre-building it is speculation |
| G4. P0-3 personal eval corpus (in-app consented clip retention) | P P0-3 | low-medium | per-user WER on real, unscripted usage | **judge demotion**: partially dominated — scripted human-v1 via existing `eval record` needs zero new code and answers most per-user questions. Build the in-app consent flow only if scripted passes prove insufficient for a specific claim someone is trying to make |
| G5. Generic FM adapter re-entry check | P P2-7 | n/a (a reading of a number) | refined-stage WER/CER on human-v1 | re-enter only if refine leaves ≥2 WER pts on the table **and** three rounds of prompt engineering fail (P's own bar). Until that number exists this item consumes zero minutes |

### Gate: telemetry accumulation (opened by J4, ~1–2 weeks)

| Item | Source | Cost | Decision number | Bar |
|---|---|---|---|---|
| G6. Threshold recalibration: decouple `OnboardingMicTest.passLevel` and the `silent` classification floor from `voicedPeakThreshold`; lower classification floor toward ~0.005 | A §2.3 | hours | 5th-percentile voiced-success `peak_level` over ~100 rows | prediction: p5 lands well below 0.02; quiet-speech failures reclassify `silent` → `produced_nothing` (visible instead of vanishing); mic-test false-fails for quiet speakers end. Both reports independently measured the engine fine at 0.016/0.010/0.003 — the strongest cross-report convergence after the gain result, so this is near-certain to fire; it waits only for its n |

### Gate: another workstream (IM anchored relocation)

| Item | Source | Cost | Bar |
|---|---|---|---|
| G7. P1-4 deterministic style rules | P P1-4 | medium | supply-gated, not mechanism-gated: today's IM rung sends `.changed` without text, so evidence is AX-scope-only and sparse. Park until the wire carries text; then the pre-registered prediction is per-rule-class `zeroEditRate` movement. Do not build the taxonomy speculatively |

### Gate: J8's probe number

| Item | Source | Bar |
|---|---|---|
| G8. P0-1 full miner + promotion UX | P P0-1 | build only on a passing replay number (≥ a handful of catches/100). Second check before shipping: `dict=on` eval arm shows term-recall gain confined to proper-noun/jargon categories, WER elsewhere unchanged |

---

## 3. Never — the consolidated kill table

No argument time on any of these. Source column names the report that killed
it; the last five are judge-added.

| Killed option | Why (one line) | Source |
|---|---|---|
| Retraining/fine-tuning Apple's acoustic model | no API at any privilege level; OS-owned assets | A §5.1, M §6.3, P §4.1 |
| `SFCustomLanguageModelData` / custom pronunciations | probed twice on this machine, zero measured effect; **keep the 1-command per-OS re-probe** | A §5.2, P §4.4 |
| `contextualStrings` on live `SpeechTranscriber` | measured no-op; Apple-confirmed DT-only | A §5.3, M §6.3 |
| AGC / pre-gain / level normalization | engine gain-invariant over ~50 dB — **independently replicated** (A's probe ×0.003; M's g-36 cell +2.4 pts, zero empties); boosting measurably worsened words | A §2/§5.4, M §5.2 |
| Noise suppression / vpio | enhancement degraded ASR in 40/40 published configurations; vpio bundles dead AEC + dead AGC + onset gating | A §5.5 |
| Always-on pre-roll ring buffer | buys ~50 ms + anticipation speech at the cost of the headline privacy property; measurement made the rejection cheap | A §3/§5.6 |
| Automatic accent/locale detection v1 | no LID in Speech framework; LID ≠ accent ID; dual-decode costs 406–1790 ms measured | A §5.7 |
| Whisper-mode model | nothing local to ship; the shippable subset is G6 + meter honesty | A §5.8 |
| Parakeet int4 encoder | loses exactly the proper nouns the product exists for | A §5.9 |
| Per-user FM adapter trained on-device | no in-app training path; dies at every macOS point release (26.4 precedent) | P §4.2 |
| Speaker adaptation / voice enrollment for ASR | verified absent from every Apple surface | P §4.3 |
| Local fine-tune of Parakeet/Whisper on user audio | inference-only CoreML; NVIDIA-only upstream; requires refused audio retention | P §4.5 |
| mlx-lm LoRA open-weights formatter | killed by the standing 2026-08-05 Apple-Intelligence-only directive; reversal condition named, not recommended | P §4.6 |
| Anything cloud | product thesis | P §4.7 |
| Voice-cloning TTS for better synthetic accents | upgrades a caricature; real accented speech is a free download (J5) | M §6.3 |
| Real-time-paced matrix runs | same transcripts, 35× the wall time | M §6.3 |
| Blended single-number robustness score | hides the regressing axis; four-component deck instead | M §6.3 |
| Universal streaming insertion | target-app decision; post-J6 the felt gap is ~7 ms | N §6 |
| Shrinking `paste_restore_delay_ms` | the sleep is not the felt latency; the floor prevents the #1 competitor bug | N §6 |
| Trackpad haptics | category error — wrong limb, wrong hardware | N §6 |
| Removing the mid-onboarding relaunch | Input Monitoring binds at launch; macOS mechanics | N §6 |
| Speculative typing of partials on paste rung | destroys ⌘Z-clean commit | N §6 |
| Animated menu-bar waveform | main-thread redraws next to the event tap | N §6 |
| Faster first partials / sub-150 ms heroics | Apple's cadence; finalize p50 is already 119 ms | N §6 |
| **P1-5 per-app vocabulary profiles** | **judge kill (for now)**: weakest prediction in the personalization portfolio ("weak offline… live before/after" with no bar stated) and the only item carrying a privacy-narrative cost (partial app log — the Wispr scandal class). Dominated. Revisit only if a *measured* per-app recall problem appears | judge |
| **P2-6 refine few-shot from corrections** | **judge kill (until two conditions)**: the mechanism was already measured ignored by the ~3B model; the deterministic alternative wins every expressible case; permanent eval tax (battery doubles per OS release). Conditions to reopen: G7's taxonomy hits an inexpressible class **and** a battery-with-exemplars score exists first | judge, hardening P's own P2 |
| **N-P11 re-press restore skip** | **judge kill (until measured)**: multi-day of care for an event whose frequency nobody measured. J6 adds the counter for free (minutes); build only if it fires more than ~weekly | judge |
| **TTS locale-cross as a decision input** | **judge scope-trim on J5**: decoding en_IN *TTS voices* under en_IN *assets* is a plumbing check only — a synthetic caricature failing to improve kills nothing. The decision input is the real-speech cross (L2-ARCTIC/Common Voice). Do not let the cheap version substitute for the meaningful one | judge |
| **Dedicated `condition` manifest field now** | M's own deferral, promoted to a kill-for-now: `category`=condition is zero-code and proven in the pilot; touch `Corpus.swift` only when the schema is next opened anyway | judge, per M §6.1 |

---

## 4. Cross-examination notes (what the panel should know before attacking)

1. **Strongest result in the program**: the gain-invariance finding was
   measured twice, independently, by two different authors with two different
   methods (per-session ST probe vs the full eval harness), agreeing to the
   decibel. The AGC/pre-gain/NS kill cluster is beyond appeal.
2. **Convergent finding #2**: `voicedPeakThreshold` miscalibration. Acoustic
   measured perfect transcripts at meter 0.010 and 0.003; measurement's g-36
   cell (median level 0.016) transcribes at +2.4 pts with zero empties; the
   live floor ever observed is 0.039. Three numbers, one conclusion, one
   gated fix (G6).
3. **The one real inter-report miss**: neither the acoustic nor the
   measurement author connected the real-speech rung to the locale bake-off
   (ruling 0.2 / J5). It is the only place in the four reports where
   composing two findings changes a gate.
4. **Honesty citations the panel should preserve**: acoustic's admission that
   the engine-ready-race analysis is composed arithmetic, not end-to-end
   observation (why J7 must not be sold as an accuracy win, and why its
   expected live delta is ~0); native-feel's admission that im_streaming's
   263 ms is n=14; personalization's built-in kill bar on P0-1 (held to, as
   J8); measurement's TTS banner discipline (extended, never fought).
5. **Metric-comparability break**: J6 redefines `release_to_text_ms` on the
   paste rung. The ~770 → ~270 move is a *correction of a lying metric*, not
   an improvement, and must be annotated as such in RESULTS with `restore_ms`
   split out — otherwise the scoreboard shows a fake 2× win and the eval
   culture takes damage worth more than the fix.
6. **Where the feel items stand under this lens**: J10/J11/J13 move no
   scoreboard number and say so. They survive in the do-now tail because each
   closes a *functional* gap (zero feedback channel under `pill_hidden`;
   silent death under Secure Keyboard Entry) or a *spec-compliance* gap with
   a binary artifact (7 missing transition rows), each hard-capped at one
   day. Any expansion beyond those caps should be refused until a proxy
   metric exists.
7. **Budget sanity**: the entire do-now bucket is ≈ two engineer-weeks. The
   single most expensive gated item (G2, the Parakeet bundle) was already
   built and measured to the point where its remaining cost is dominated by
   the recording session that gates it. There is no item anywhere in the four
   reports whose honest cost exceeds a week except the killed ones — the
   portfolio is unusually cheap, which is itself evidence the reports did
   their jobs.

---

## 5. The one-line program

Run J1–J5 this week (cache line, recording session, deck, telemetry, real-speech
locale cross); J6–J13 next week; open the human-v1 gate and let G1–G8 spend
only what their pre-registered numbers authorize; spend zero minutes on the
kill table.
