# FINAL PLAN — the robustness ruling

Synthesis over the four research reports (`acoustic.md`, `personalization.md`,
`measurement.md`, `native-feel.md`) and three judge verdicts
(`judge-feasibility.md`, `judge-impact.md`, `judge-soul.md`), 2026-08-10.
The argument happened; this document is the ruling. Where judges disagreed,
the tiebreak is recorded in §1.1 with its reason. Nothing below re-argues
evidence — every claim traces to one of the seven documents, all of whose
file:line citations the feasibility judge re-verified against the tree.

**The program in one paragraph.** The portfolio is unusually cheap (≈ two
engineer-weeks of do-now work + one recording weekend) because the research
did its job: every fantasy is dead with citations, and every surviving item
has a pre-registered number. The critical path is not code — it is the
human-v1 recording session, which gates roughly half the value (locale
bake-off, Parakeet ROC, every accuracy claim, the tone axis, the adapter
re-entry read). The do-now work splits cleanly into four parallel tracks with
disjoint file ownership (§2), the gates are named with exact opening
conditions (§3), the kill table is final (§4), and the north-star matrix
states honestly which numbers are TTS tripwires and which are the only ones
that may ever be called accuracy (§5).

---

## 1. THE RULING

Verdicts: **NOW** (implement-now), **GATED** (blocked on a named gate — the
gate is the human corpus unless stated otherwise), **REJECTED**. Judge
column: F = feasibility, I = impact, S = soul; "3/3" means consensus.

| # | Item (source) | Verdict | Judges | Why (one line) |
|---|---|---|---|---|
| R1 | osBuild folded into `EvalPaths.settingsHash` (M §6.2.4) | **NOW — first** | 3/3 keep, I ranks first | One line; prevents every future deck number being a provenance lie after an OS model swap. |
| R2 | Human-v1 recording session (M §8.2, gate for ~half the program) | **NOW** (people-time) | 3/3, F+I elevate to critical path | 3 speakers × ~1 h; the only source of numbers the repo permits as accuracy; opens every Gate-1 item. |
| R3 | Robustness deck: enhanced voices → `tts-accents-v1` + `tts-stress-v1` + corners + bandlimit8k + raw-stage table + `emptyRate` + RI deck v1 (M §3–6) | **NOW** | 3/3 keep (F re-scored the pilot independently) | Proven end-to-end in the pilot; ~2 min ASR per engine per OS build; the scoreboard every other delta pays into. |
| R4 | Telemetry completion: `peak_level` + `audio_ms` every row, noise-floor field, `first_voiced_ms` (M §7 + A §3, merged) | **NOW** | 3/3, one diff not two | Classifies the 17.3 % live empty rate; starts the G6 clock; decides whether clipping work was ever needed. |
| R5 | Real-speech rung + locale cross: LibriSpeech/L2-ARCTIC/Common Voice importer; `EvalRunner` locale parameterization; decode accent-labeled real speech under en_IN/en_GB vs en_US (M §8.1 × A §1, composed by I) | **NOW** | I's composition, F+S concur | The accent lever's go/no-go arrives in days on real speech — before any recording session and before any UI is built. |
| R6 | Paste-rung feedback inversion fix + `restore_ms` split + re-press counter (N P1) | **NOW** | 3/3 — F: "highest confidence in the program"; S: "top of the whole program" | The pill lies ~250 times in the log; felt latency is ~270 ms, metric says 770; truth-in-feedback is the soul. |
| R7 | Retained-head replay at engine install + delayed-`begin` test (A §3 fix 1) | **NOW** | 3/3; F inverts order vs metric; I: "expected live delta ≈ 0" | ~Half day, closes the cold-start race deterministically; justified by cost, never sold as an accuracy win; R4's metric renders the verdict on exposure. |
| R8 | P0-1 hear-phrase mining — **replay probe only** (P P0-1, trimmed by I) | **NOW** (probe) | 3/3 keep mechanism; I trims to probe-first | 1 day of scripting against data already on disk; the report's own kill bar decides whether the miner is ever built (→ G8). |
| R9 | Seam batch: error truncation (N P3), Doctor→Setup (P6), caption de-leak (P7), `pasteLast` style unify (P8) | **NOW** | 3/3 | Pure de-leakage, minutes-to-hours each, all code-verified. |
| R10 | Live dead-mic cue (N P5) — **amended trigger** | **NOW** | F: keep goal / weaken trigger; S keep; I keep | Ships with engine-evidence trigger (partials suppress/clear the cue) — resolution of the 0.02 conflict, §1.1-T4. |
| R11 | Sound cues, mic-open + commit (N P4) | **NOW** | 3/3; S adds two conditions | `pill_hidden` users currently have zero feedback channel; ships with cue-bleed eval check + default-on only when pill hidden. |
| R12 | Secure-input lock state on menu-bar icon (N P9) | **NOW** | 3/3 | The only feedback channel that survives event-tap suppression gets a state; closes "dead in Slack". |
| R13 | §2.5 pill transitions, 7 missing rows (N P2) | **NOW** (after R6) | 3/3; I: hard 1-day cap | Every state change is a hard cut today; motion budget spent exactly where native apps spend it; no scoreboard number, binary spec artifact. |
| R14 | Time-to-wow onboarding metrics row (N P10) | **NOW** (rider) | 3/3; I: land when onboarding next touched | One row; n≈0 until fresh installs exist — rides Track D, not dedicated work. |
| R15 | Engine-evidence mic test (S §4.2, judge-added) | **NOW** | S proposes; consistent with F's A3 verdict | Pass onboarding on transcription evidence, not a proxy threshold; strictly more honest, needs no telemetry wait; supersedes the mic-test half of A3. |
| R16 | SpeechDetector off-path probe (F §6.2, judge-added) | **NOW** (probe) | F proposes | An afternoon; if the VAD module reports verdicts, it obsoletes the entire hand-tuned-floor debate (G6). |
| R17 | Data inventory page — one purge that reaches every store (S §4.4, judge-added) | **NOW** | S proposes; unopposed | `metrics.log` is purge-immune today; "forget must reach every store" is identity; a page over stores that already know their files. |
| R18 | Doc hygiene: 135 not 131; 0.50→0.60; 17.3 %; retire "12–14 dB"; noise floor is 2–3 pts not ±1.6 (F §0.discrepancies, C9, C10) | **NOW** | F found; I/S concur | Fix before anything is quoted upward. |
| R19 | Kill AGC / pre-gain / NS / vpio (A §2) | **LAW** (nothing to build) | 3/3 — S: "constitutive" | Measured twice independently, converging literature; recorded as product law: capture path never rewrites the signal. |
| R20 | Pre-roll stays dead (A §3/§5) | **LAW** | 3/3; S strengthens (OS orange light, pill grammar) | ~50 ms cannot buy back the two honesty surfaces it would spend; opt-in does not rescue it. |
| R21 | Per-user locale bake-off + chooser UI, incl. ephemeral onboarding form + DT dual-install + reserved-locales story (A §1 + S §4.1) | **GATED** (spk01 clips; go-signal from R5) | 3/3 keep, reshaped | Mini bake-off needs only ~20–30 verified spk01 clips; ephemeral in-memory form removes the retention need; R5 may kill it before it runs — that is the point of R5. |
| R22 | Parakeet bundle: eval-harness engine integration, dual-decode of human-v1, disagreement ROC, per-voice-spread prediction (A §4 + M §8.3.1) | **GATED** | F weakens (harness cost), I gates, S reshapes | Bar: disagreement catches ≥50 % of worst-decile at ≤10 % FPR, log-only first; harness integration is days + a linking-policy decision, priced in. |
| R23 | Accuracy-mode user-visible shape: History disagreement badge first (S §4.5); explicit opt-in notice-based correction later; silent splice never | **GATED** (on R22 ROC) | S's reshaping adopted, §1.1-T6 | "Let a second model warn you" before "let it rewrite you"; verbatim-first admits no silent second-guessing. |
| R24 | P0-2 frequency-weighted biasing (P P0-2) | **GATED** (with R22) | F+S keep / I gates — **tiebreak: I**, §1.1-T2 | The number it moves (41 FPs, minSimilarity tightening) lives on the gated Parakeet channel; standalone DT payoff is ~0.4 s of off-path setup. |
| R25 | P0-1 full miner + promotion UX | **GATED** (on R8's probe number) | 3/3 | Build only on ≥ a handful of catches/100; then `dict=on` arm must show gains confined to proper-noun/jargon categories. |
| R26 | Threshold recalibration of `EmptyReason` silent floor (A §2 / G6) | **GATED** (telemetry: ~100 `peak_level` rows, opened by R4) | 3/3; F weakens the 0.005 prediction | Derive the floor from p5 of voiced successes — from data, not a priori; near-certain to fire; possibly obsoleted by R16. |
| R27 | Noise honesty cue — "Noisy here — expect errors" (S §4.3, judge-added) | **GATED** (R4's noise-floor field + deck calibration) | S proposes | The only lever left standing on the dominant axis after the conditioning kills; calibrate trigger against wn cells; predict elevated `edit_observed` on flagged rows. |
| R28 | Reverb/IR convolution cell (M §5.4) | **GATED** (human pass-3 result) | 3/3 | Add only if pass-3 damage lands outside the (g-24 + wn) synthetic bracket. |
| R29 | In-app consented clip retention (P P0-3 productized) | **GATED** (demonstrated insufficiency of scripted passes) | F promotes / I demotes / S reshapes — **split ruling**, §1.1-T3 | The recording session (R2) is the critical path both meant; the in-app flow waits, and if built takes S's shape: per-clip deliberate act, 50-cap, visible inventory (rides R17), backup sentence, measurement-never-training. |
| R30 | Deterministic style rules (P P1-4) | **GATED** (IM anchored-relocation workstream) | 3/3 | Supply-gated, not mechanism-gated; do not build the taxonomy speculatively. |
| R31 | Generic FM adapter re-entry (P P2-7) | **GATED** (human-v1 refined-stage number) | 3/3 defer | Re-enter only if refine leaves ≥2 WER pts that three rounds of prompt engineering cannot recover; consumes zero minutes until then. |
| R32 | Per-app vocabulary profiles (P P1-5) | **REJECTED** (for now) | F keep-as-ranked / I kill / S weaken-harder — **tiebreak: I+S**, §1.1-T1 | Weakest prediction in its portfolio paired with the only privacy-narrative cost; proposed metrics key routes an app log around the purge. |
| R33 | Refine few-shot from corrections (P P2-6) | **REJECTED** (reopen conditions named) | 3/3 effectively | Mechanism measured ignored by the ~3B model; deterministic pass wins every expressible case; permanent eval tax. |
| R34 | Skip-clipboard-restore on fast re-press (N P11) | **REJECTED** | F defer-or-drop / I kill-until-measured / S kill — §1.1-T5 | Trades the user's clipboard on an implicit signal; the free counter lands in R6; "restore later" is the alternative if it ever fires. |
| R35 | All four reports' kill lists (A §5 ×9, P §4 ×7, M §6.3 ×6, N §6 ×8) | **REJECTED** (stand) | 3/3, every entry re-verified by F | Final; consolidated in §4 so nobody re-litigates. |

### 1.1 The tiebreaks — where judges disagreed, the ruling and why

- **T1 — Per-app profiles (R32).** Feasibility kept it as ranked;
  impact killed it; soul showed its purge claim is half-true (`metrics.log`
  has no delete surface). **Ruling: rejected for now.** Impact's dominance
  argument plus soul's verified purge-immunity outweigh a "keep" that was
  already last-ranked by its own author. Re-entry requires (a) a *measured*
  per-app recall deficit and (b) ctx-house-style consent gating or
  `utterance_detail`-only storage — never a bare metrics key.
- **T2 — Weighted biasing (R24).** Feasibility and soul kept; impact gated
  it with the Parakeet bundle. **Ruling: gated.** The measured motivation
  (41 false replacements, the 0.50→0.60 tightening) is entirely on the
  Parakeet channel; the DT-side benefit at 138 terms is ~0.4 s of off-path
  session setup. Carry feasibility's note: the no-cap verdict was
  config-sensitive and contested between probes, so when this lands, the cap
  should be adaptive, not another constant.
- **T3 — Personal eval corpus (R2 / R29).** Feasibility promoted it to
  critical path; impact demoted it as dominated by scripted recording; soul
  killed the per-session variant. **Ruling: split — they were arguing about
  different halves.** The *recording session* via the existing
  `Wisprit eval record` CLI is the critical path (R2, now, zero new code,
  inherently deliberate). The *in-app retention flow* is gated (R29) and, if
  ever built, takes soul's shape. The per-session ambient toggle is dead
  permanently (§4).
- **T4 — The 0.02 threshold conflict (A3 vs N P5).** Acoustic proved the
  meter floor sits ~2 orders of magnitude above the engine's real floor;
  native-feel proposed a new user-facing nag keyed on that same floor.
  **Ruling: wherever the audio is already in hand, engine evidence beats any
  proxy.** Concretely: (a) the dead-mic cue (R10) ships now but is
  suppressed/cleared the moment a partial arrives; (b) the onboarding mic
  test (R15) switches to engine-as-judge now — no telemetry wait; (c) the
  `EmptyReason` classification floor recalibrates only from accumulated
  telemetry (R26), with the exact floor read off p5 of voiced successes, not
  the 0.005 guess; (d) 0.02 keeps its one legitimate job — the cheap
  engine-release heuristic, where a false negative is harmless.
- **T5 — Re-press restore skip (R34).** Three different dispositions, one
  direction. **Ruling: rejected.** The report's own "multi-day for the care"
  is the tell; the counter that would ever justify it costs one line inside
  R6. If it fires more than ~weekly, the revival shape is *deferred restore*
  (restore after the next utterance), which keeps the property guarantee.
- **T6 — Accuracy-mode shape (R22/R23).** Acoustic staged log-only → splice
  via retro-correction; soul killed the silent splice as a category error
  against verbatim-first and offered the History badge. **Ruling: soul's
  ladder adopted.** Log-only ROC → History badge ("this one may have
  errors") → explicit opt-in, notice-based correction mode, never default-on,
  never silent, 562 MB never load-bearing. The splice-without-notice variant
  is in §4 permanently.
- **T7 — Replay-vs-metric ordering (A §3).** Feasibility demanded the
  metric land before the splice. **Ruling: both land in Track B's first
  week, metric first or same diff** — the replay proceeds on cost grounds
  (~half day, deterministic test) per impact, but `first_voiced_ms` owns the
  verdict on whether clipping was ever real exposure, and the replay is
  never reported as an accuracy improvement.
- **T8 — The "12–14 dB" figure (C9).** **Ruling: retired as a quotable
  number** (the clamp inconsistency is real). The operational conclusion
  survives on the recomputed live side: the user's real peaks are
  0.039–0.233, so the matrix's g-12/g-24 cells — not g0 — are the realistic
  operating regime.
- **T9 — Locale-lever sequencing (composition, not conflict).** Impact's
  real-speech cross (R5, now) + feasibility's mini spk01 bake-off (first
  20–30 clips, Gate 1) + soul's ephemeral onboarding form (post-go-signal)
  assemble into one three-stage pipeline: *decide the lever on real public
  speech → confirm on the user's own voice → productize with zero
  retention.* Each stage can kill the next before money is spent.

---

## 2. IMPLEMENT-NOW WORKPLAN

Four parallel-safe tracks with **disjoint file ownership** — the orchestrator
can run one agent per track concurrently. Cross-track dependencies are listed
at the end; there are only four. Effort classes: `hours` / `half-day` /
`day` / `days`.

### Track H — human actions (no agent; the user)

| id | action | when |
|---|---|---|
| H1 | Schedule and run **human-v1 recording**: 3 speakers (≥2 non-US accents; spk01 = this user), 3 passes per protocol, plus the new pass-4 quiet-voice subset (§3.0). **Record spk01 pass-1 first** — its first 20–30 verified clips open Gate 1 same-day. | this week |
| H2 | System Settings session: download **Enhanced/Premium tiers** of the 8 accent voices (Samantha, Daniel, Karen, Moira, Rishi, Aman, Tara, Tessa). Must precede Track A's corpus generation or the sha-keyed cache churns. | day 0 |

### Track A — measurement & harness

**Owns:** `Sources/WispritMac/Eval/**`, `Sources/WispritEval/**`,
`tools/eval/**`, `docs/eval/**`, plus the doc-hygiene edits in
`docs/research/` and `docs/notes/`.

| id | change | metric it must move | effort | order |
|---|---|---|---|---|
| A-1 (R1) | Add osBuild to the hash material in `EvalPaths.settingsHash` (`EvalPaths.swift:156–165`). | Cache provenance: post-OS-update runs re-transcribe (~2 min) instead of stamping stale transcripts with a new `osBuild`. | hours | **first commit** |
| A-2 (R5a) | Parameterize locale: `EvalRunner.asrSettings()` (`EvalRunner.swift:584`) + a CLI flag on `EvalCommand`. | Enabler — required by A-4 now and by R21's bake-off later; cache keys already include locale so runs cannot collide. | hours | after A-1 |
| A-3 (R3) | The deck: generators under `tools/eval/` for `tts-accents-v1` (8 voices × 50, highest installed tier, tier recorded in `speaker`), `tts-stress-v1` (g0/g-12/g-24/g-36, clip+6, wn20/10/5 on g-12, bab10, bandlimit8k, whisper-voice, r120/r240), `tts-corners-v1` (3 corner cells). Seeded, `--force`-only regeneration. Scoring: raw-stage category table (`--stage` on `score`; today `EvalScoring.swift:130` is final-only), `emptyRate` per stage/category, RI deck v1 rows in `docs/eval/BASELINE.json` with wider tolerances. | Baselines locked: RI-noise +16.8, RI-accent +8.3, RI-level +2.4, RI-empty 0. Any nonzero deck empty rate is news; per-release re-run ≈ 2 min/engine. | days (2–3) | after A-1 and H2 |
| A-4 (R5) | Real-speech rung: manifest importer for LibriSpeech test-clean/other + L2-ARCTIC / Common Voice accent-labeled subsets (`CorpusSource.librispeech` exists in `Corpus.swift`); decode Hindi-L1 / India-labeled English under en_IN vs en_US assets (and en_GB cross as control). Raw stage, `.asr` profile only. | **The accent lever's go/no-go**: matched assets ≥10 % relative WER win on Hindi-L1 speech ⇒ R21 proceeds; flat ⇒ R21 dies before UI. Secondary: synthetic accent ordering reproduces on real speech, else the accents deck is demoted to voice-QA (with an appended correction, as promised). | days (2–3) | after A-2 |
| A-5 (R8) | P0-1 replay probe: script (tooling, no app source) that splits the existing history DB chronologically, mines hear-phrase candidates from half 1 via the existing LCS machinery, replays half 2 through `DictionaryStore.applyCorrections` v1-vs-v2. Note the `history_enabled` / 1000-row-cap supply caveat in the write-up. | New catches per 100 utterances on the user's own history. Kill bar: < a handful/100 ⇒ R25 never gets built. Underpowered (n≈300) is an acceptable outcome. | day | anytime |
| A-6 (R11 cond.) | Cue-bleed check: mix Track B's cue asset into matrix clip heads at realistic coupling levels; assert zero transcript delta before sounds go default-on-when-hidden. | Binary: zero delta. | hours | after B-5 |
| A-7 (R18) | Doc hygiene: `spikes-s1.md` 131→135; personalization 0.50→0.60 context; 17.3 %; retire the 12–14 dB figure with a one-line correction in `measurement.md`; note the 2–3 pt noise floor. | Nothing quoted upward is stale. | hours | anytime |

### Track B — session core (capture, insertion, telemetry, sound)

**Owns:** `Sources/WispritMac/SessionController.swift`,
`Sources/WispritMacInput/**`, `Sources/WispritEngine/**`,
`Sources/WispritPersistence/MetricsWriter.swift`,
`Sources/WispritPersistence/Settings.swift`, their tests, and probe files
under `docs/research/probes/`.

| id | change | metric it must move | effort | order |
|---|---|---|---|---|
| B-1 (R6) | Paste feedback inversion: capture "text delivered" at `postCommandV` inside `InsertResult` (`Inserter.swift:164`); `SessionController.finish` stamps `release_to_text_ms` and fires `flashSuccess` **before** the 500 ms restore sleep; write `restore_ms` separately; add the queued-press-during-restore counter (one line). Hand the RESULTS.md annotation text to Track A: this is a **metric correction, not a speedup**, and must be recorded as a discontinuity. | Live paste `release_to_text_ms` p50 ~770 → ~270 ms; checkmark lands within one frame of pasted text. | hours + tests | **first** (unblocks C-3) |
| B-2 (R4) | Telemetry completion, one diff: `peak_level` + `audio_ms` on every row; `noise_floor` (RMS of quietest ~300 ms window, computed in `MicCapture`); `first_voiced_ms` (mic-live → first ≥-threshold chunk). Additive keys per the append-only rule; also expose a writer entry point for the onboarding row (Track D consumes). | Decomposes the 17.3 % empty rate (prediction: ≥80 % of sub-second empties at normal levels); starts R26's 100-row clock (~1–2 weeks at ~14 utt/day); `first_voiced_ms` p5 > 300 ms ⇒ clipping is a phantom. | half-day | early (starts two clocks) |
| B-3 (R7) | Retained-head replay: at `AsrManager.begin` install, splice `retention.data` ahead of live chunks (order-preserving, under the existing feed lock — the burst-feed existence proof is the unpaced eval harness). Add the delayed-`begin` regression test (clip with word at t=0, artificially late install). | Deterministic cold-start head-loss test passes. Expected live delta ≈ 0 — never reported as an accuracy win. | half-day | after/with B-2 |
| B-4 (R9d) | `pasteLast` secure-input branch → `flashBlockedSecure` (one-line switch at `SessionController.swift:635–637`). | Existing pill tests. | minutes | anytime |
| B-5 (R11) | Sound cues: mic-open fired on the show-recording event **only after `audio.start()` succeeded** (the orange rule in a second sense); commit cue on success; no error sounds. One `sounds` toggle in `Settings.swift`, **defaulted by `pill_hidden`** (on when hidden, off when visible). Bundled low-gain assets ≤100 ms. | Manual matrix: pill visible/hidden × sound on/off; cue never fires on failed start. Default-on-when-hidden waits for A-6's cue-bleed pass. | day (cap) | anytime |
| B-6 (R16) | `SpeechDetector` probe: run the module off-path over retained PCM of empty utterances — does it report a usable silent-vs-speech verdict (vs gating-only)? Probe under `docs/research/probes/`, findings appended to `docs/notes/asr-notes.md`. | Binary probe outcome; if verdict-reporting, it replaces R26's hand-tuned floor with an engine-calibrated one. | half-day | anytime |

### Track C — pill & feel

**Owns:** `Sources/WispritMacUI/Pill.swift`, `PillSurface.swift`,
`PillModel.swift`, `PillGeometry.swift`, `TallyWaveform.swift`, their tests.
(**Not** `StatusMenuModel.swift` — that is Track D's.)

| id | change | metric it must move | effort | order |
|---|---|---|---|---|
| C-1 (R9a) | Error truncation: `.tail` truncation for error/blockedSecure states + dedicated `errorMaxWidth` (≈280 pt for the 40-char budget) or copy cut to ≤28 chars. | `PillModelTests`: rendered bubble width fits every `flashEmpty` string. | hours | anytime |
| C-2 (R10) | Live dead-mic cue, **amended trigger**: ~2 s of consecutive sub-floor ticks while `.recording` **and no partial has arrived** → muted notice tail "No audio — check mic"; clears on first voiced tick **or first partial**. Pure `PillModel` change, headless-testable. | Proxy: count of holds ≥10 s with zero voiced ticks that ran to completion → ~0. Unit: 40 silent ticks → tail; one partial → gone. | hours | anytime |
| C-3 (R13) | The seven §2.5 transitions: `NSAnimationContext`/`animator()` for appear fade+rise, width spring, hide sink; SwiftUI `withAnimation` for tint crossfade, staggered collapse (precomputed per-bar delays in the model), committed contraction. Reduce Motion honored; the 20 Hz level path stays animation-free; zero-redraw silence test stays green. | Spec-table compliance 7-missing → 0; before/after screen recordings; existing `WaveformBuffer` regression test green. | day (cap) | **after B-1** |

### Track D — trust & shell (menu bar, onboarding, settings surfaces)

**Owns:** `Sources/WispritMac/AppController.swift`,
`Sources/WispritMacUI/StatusMenuModel.swift`,
`Sources/WispritMac/Window/**` (SettingsPage, OnboardingMicTest,
OnboardingModel, SetupChecklist, HomeSource), their tests.

| id | change | metric it must move | effort | order |
|---|---|---|---|---|
| D-1 (R12) | `StatusIconState.secureInput` + lock-badged template icon; sample `IsSecureEventInputEnabled()` where icon state is already sampled + low-rate idle poll, never while a key is held. Priority: below `needsSetup`, above `idle`/`recording`-adjacent — decide in the diff with a unit test on `iconSpec` priority. | Manual: password field focused → lock ≤ 2 s; released → clears. | day (cap) | anytime |
| D-2 (R9b+c) | Doctor→Setup routing: menu item becomes "Open Setup…" → `openWindow(tab: .setup)` (CLI stays); Live Typing failure copy "— see Setup" opens the page. Caption de-leak: `HomeSource.caption` maps engine ids to human words ("on-device") or omits while one engine ships. | StatusMenuModel row test; `HomeSourceTests` caption snapshot. | hours | anytime |
| D-3 (R15) | Engine-evidence mic test: `OnboardingMicTest` feeds its captured audio to the transcriber and passes when words come back; meter stays as the progress bar; `passLevel` proxy retired from the pass decision. | Quiet-speaker false-fail becomes impossible by construction; existing six-second-silence Skip behavior preserved. | half-day | anytime |
| D-4 (R17) | Data inventory page: one Settings surface listing every persisted class — transcripts, metrics, dictionary, learn ledgers, (future) eval clips — with sizes, per-class delete, delete-everything. Gives `metrics.log` its first delete surface. States the derived-data sentence (mined hear phrases survive a history purge because the dictionary is user-owned and visible). | Every store class visible and deletable in one place; purge reaches every file. | days (1–2) | anytime |
| D-5 (R14) | Time-to-wow row: first-launch → first `didDictate` delta + steps skipped + relaunch count, written via Track B's writer entry point from `OnboardingModel`. | Row appears on a fresh `~/.wisprit`. | hours | **after B-2** |

### Cross-track dependencies (all four of them)

1. **H2 → A-3 generation** (voices before corpus, or the cache churns).
2. **B-1 → C-3** (committed-state timing looks wrong until the checkmark
   stops arriving late — native-feel's own sequencing note).
3. **B-2 → D-5** (Track B owns `MetricsWriter`; D calls the new entry point).
4. **B-5 → A-6 → sounds default-on-when-hidden** (cue-bleed certainty before
   the default flips).

Everything else is order-free within its track. Total do-now budget:
≈ 10–12 engineering days across four agents (≈ one wall-clock week) plus
H1/H2 people-time.

---

## 3. GATED ITEMS — what opens each gate

### 3.0 The human-v1 session: exactly what it must contain (protocol deltas)

The existing protocol (`tools/eval/scripts/human-v1/README.md`: 135
utterances × 13 files, 3 speakers minimum, passes internal / Bluetooth /
real-conditions, `eval verify` mandatory, spk01 = dev) stands. Four
extensions, to be added to the README before recording:

1. **Speaker spread made concrete:** the three speakers must include **≥2
   non-US accents**, at least one Indian-English speaker (the axis the TTS
   deck flags worst: aman +8.3, tara +6.5 — and spk01 likely covers it).
2. **Pass 4 — quiet voice (new):** a ~30-utterance subset (proper nouns +
   everyday + numbers files), internal mic, quiet room, deliberately soft
   speech shading to near-whisper. Mic label `internal-quiet`. This is the
   only way the tone/vocal-effort axis ever gets a number (acoustic §2's
   honest whisper story; measurement §5.6's "tone: unmeasured until
   human-v1"). ~10 min per speaker; spk01 mandatory, others encouraged.
3. **Recording order:** spk01 pass-1 first, verified immediately — its
   first 20–30 clips open Gate 1 the same day (feasibility §6.1's decoupled
   mini bake-off).
4. **Pass 2 (Bluetooth) stays non-optional** — it is the only pass that can
   see the 24 kHz starvation class; pass 3 keeps its faster-pace
   instruction (the only real rate data).

### Gate 1 — human-v1 recorded (opened by H1)

| item | unblocked by | decision number and bar |
|---|---|---|
| R21 locale chooser pipeline | spk01 pass-1 first 20–30 verified clips (+ A-2) | Stage 1: decode spk01's clips across all 9 installed ST locales (minutes, cached). Ship the chooser pipeline only if best locale ≤ en-US −10 % relative **and** R5/A-4 showed the lever on real public speech. Stage 2 (product): the **ephemeral onboarding bake-off** — read 5 sentences, decode in memory under installed locales, show the winner, install DT assets for the winner (second `assetInstallationRequest` — DT is en_US-only today), discard audio; handle `maximumReservedLocales = 5` on non-dev machines. Zero retention. |
| R22 Parakeet bundle | full corpus, both engines | Pre-work: add a `parakeet` engine to the eval CLI (`EvalCommand.swift` enum + `EvalRunner`), which forces the linking-policy decision on `NemoTextProcessing` — days, not hours (feasibility A8). Then: dual-decode human-v1, disagreement ROC. Bar: threshold catches ≥50 % of worst-decile utterances at ≤10 % FPR, else accuracy mode dies at the cost of one eval run. Also: per-voice-spread prediction on `tts-accents-v1` (Parakeet narrower than apple_live's +8.3), and the R24 weighted-biasing re-run (top-100 by `hit_count×recency` vs all-138: equal-or-better recall, strictly fewer FPs). |
| R23 disagreement badge → opt-in mode | R22's ROC passing | Badge in History first (no text changes, pure candor). Explicit "Accuracy mode" setting later: never default-on, every edit notice-based through the reconciler's refusal gates, re-decode inside the `RetainedUtterance` window (pin in the diff), 562 MB optional-never-load-bearing. |
| R28 reverb/IR cell | pass-3 scored | Add only if pass-3 damage lands outside the (g-24 + wn) synthetic bracket. |
| R31 adapter re-entry read | refined-stage WER/CER on human-v1 | Re-enter only if refine leaves ≥2 WER pts that three rounds of prompt engineering cannot recover. A reading, not a project. |
| North-star human column (§5) | all passes scored | The only numbers ever quoted as accuracy, dev/held split by speaker per DEFINITIONS.md. |

### Gate 2 — telemetry accumulation (opened by B-2; ~100 `peak_level` rows ≈ 1–2 weeks)

| item | bar |
|---|---|
| R26 `EmptyReason` silent-floor recalibration + decoupling from `voicedPeakThreshold` | p5 of voiced-success `peak_level` sets the classification floor (prediction: well below 0.02; quiet-speech failures reclassify `silent` → `produced_nothing`, becoming visible). Hours of work once the n exists. Check B-6's SpeechDetector probe first — if the VAD verdict works, use it instead of any constant. |
| R27 noise honesty cue | Needs the `noise_floor` field live plus the deck's (level, floor) → wn-cell mapping. Ship as a post-commit notice in the pill's notice register; pre-registered prediction: flagged utterances show elevated `edit_observed` rates. Coaching, never apology; never rewrites the signal. |

### Gate 3 — A-5's probe number

| item | bar |
|---|---|
| R25 full hear-phrase miner + promotion UX | ≥ a handful of new catches/100 utterances on the chronological replay; then the `dict=on` eval arm must show term-recall gains confined to proper-noun/jargon categories with WER elsewhere unchanged. Inherits every ledger discipline (≥2 distinct utterances, phonetic floor, permanent dismissals, terms-only — never mints a canonical term). |

### Gate 4 — other workstreams

| item | gate |
|---|---|
| R30 style rules (P1-4) | IM anchored-relocation lands (the wire carries text, so evidence stops being AX-only-and-sparse). Then: per-rule-class `zeroEditRate` prediction, ≥3-observation threshold, conservative taxonomy (substitution / casing / terminal punctuation). |
| R29 in-app clip retention | A specific claim someone is trying to make that scripted `eval record` passes cannot serve. Shape is fixed by the soul verdict: deliberate per-clip act, 50-clip cap, visible inventory on R17's page, the backup sentence in the consent copy, measurement-never-training as a bright line, one consent surface shared with anything else that records. |

---

## 4. REJECTED — the kill list (final; do not re-litigate)

Every entry was re-verified by the feasibility judge against its source.
Consolidated from all four reports plus the judge-added and ruling-added
kills.

**No API / no mechanism exists:**
| killed | why |
|---|---|
| Training/fine-tuning Apple's acoustic model | No API at any privilege level; OS-owned assets. |
| Speaker adaptation / voice enrollment for ASR | Absent from every Apple surface (Personal Voice = TTS; Vocal Shortcuts = intents). |
| Per-user FM adapter trained on-device | No in-app training path; adapter dies at every macOS point release (26.4 precedent). |
| Local fine-tune of Parakeet/Whisper on user audio | Inference-only CoreML; NVIDIA-only upstream; requires refused audio retention. |

**Measured dead on this machine:**
| killed | why |
|---|---|
| `SFCustomLanguageModelData` / custom pronunciations | Probed twice, zero effect. **Keep the one-command per-OS re-probe** (probes on disk). |
| `contextualStrings` on live `SpeechTranscriber` | Measured no-op; Apple-confirmed DT-only. |
| AGC / pre-gain / level normalization | Engine gain-invariant over ~50 dB, independently replicated twice; boosting measurably worsened words. Product law (R19). |
| Noise suppression / vpio | 40/40 published configurations degraded; vpio bundles dead AEC + dead AGC + onset gating. Product law (R19). |
| Parakeet int4 encoder | Loses exactly the proper nouns the product exists for. |
| Clipping as a live concern | Measured no-op at +6 dB; keep the cheap cell, stop arguing. |

**Killed by product identity (with the honest reversal condition recorded):**
| killed | why |
|---|---|
| Always-on pre-roll ring buffer | Buys ~50 ms + anticipation speech; costs the headline privacy property, the OS's own orange-light truthfulness, and the pill grammar. Opt-in does not rescue it (shared grammar). |
| mlx-lm LoRA open-weights formatter | Killed by the 2026-08-05 Apple-Intelligence-only directive; reversal condition named in personalization §4.6 — if that directive ever reverses, this rung (not FM adapters) is the honest next step. |
| Anything cloud | Product thesis. |
| Silent disagreement-splice of inserted text | Verbatim-first admits no invisible second-guessing; only the badge → opt-in notice-based ladder (R23). |
| Per-session ambient voice-retention toggle | Quiet-accumulation shape; voice persists only by deliberate per-clip act. |
| Skip-clipboard-restore on fast re-press (N P11) | User property traded on an implicit signal; counter ships in R6; "restore later" is the only revival shape. |

**Killed by dominance / measurement discipline:**
| killed | why |
|---|---|
| Automatic accent/locale detection v1 | No LID in the Speech framework; LID ≠ accent ID; dual-decode costs 406–1790 ms measured; one honest question (the picker/bake-off) answers it once, offline. |
| Whisper-mode model | Nothing local to ship; the shippable subset is R26 + meter honesty + pass-4 measurement. |
| Voice-cloning TTS for synthetic accents | Upgrades a caricature; real accented speech is a free download (A-4). |
| Real-time-paced matrix runs | Same transcripts, 35× the wall time. |
| Blended single-number robustness score | Hides the regressing axis; the four-component deck instead. |
| TTS locale-cross as a decision input | Synthetic caricature under matched assets decides nothing; the decision input is the real-speech cross (A-4). |
| Dedicated `condition` manifest field now | `category`=condition is zero-code and pilot-proven; touch `Corpus.swift` when the schema next opens anyway. |
| Per-app vocabulary profiles (R32) | Weakest prediction + only privacy-narrative cost + purge-immune metrics routing. Re-entry conditions in §1.1-T1. |
| Refine few-shot from corrections (R33) | Mechanism measured ignored by the ~3B model; deterministic pass wins every expressible case; permanent eval-battery tax. Reopen only if R30's taxonomy hits an inexpressible class **and** a battery-with-exemplars number exists first. |

**Feel-side kills (native-feel §6, all stand):** universal streaming
insertion (target-app decision; post-R6 the felt gap is ~7 ms); shrinking
`paste_restore_delay_ms` (the sleep is not the felt latency; the floor
prevents the #1 competitor bug); trackpad haptics (wrong limb, wrong
hardware — category error); removing the mid-onboarding relaunch (Input
Monitoring binds at launch); speculative typing of partials on the paste
rung (destroys ⌘Z-clean commit); animated menu-bar waveform (main-thread
redraws beside the event tap); faster first partials / sub-150 ms heroics
(Apple's cadence; finalize p50 is already 119 ms).

---

## 5. THE NORTH-STAR TABLE

Two evidence classes, never mixed: **TTS tripwire** numbers exist today, are
deterministic per OS build, and are *never* accuracy claims — their job is to
catch regressions in ~2 minutes. **Human bars** are pre-registered targets
for human-v1; they become the only quotable accuracy numbers once recorded,
scored raw-stage on held speakers per DEFINITIONS.md. Bars marked ◇ are set
a priori and get one honest revision when the first human numbers exist (the
revision is recorded, not silent).

| axis | TTS tripwire (measured today; alarm condition) | human bar = "top notch" | evidence status |
|---|---|---|---|
| **Accent** | RI-accent +8.3 (aman); alarm if any release grows it >2 pts or real-speech ordering breaks | Every pass-1 speaker (≥2 non-US accents) raw WER ≤ 6 % ◇; max−min speaker spread ≤ 3 pts ◇; if R5 shows the lever, locale-matched assets close ≥ half of any accented speaker's gap vs en-US | TTS measured; L2-ARCTIC days away; human unmeasured |
| **Volume / level** | RI-level +2.4 (g-36 vs g0); alarm >+4 (a capture/AGC regression, since the engine is gain-invariant) | Pass-4 quiet-voice within +5 pts of same-speaker pass-1 ◇; mic test passes any speaker the engine can transcribe (R15, by construction) | Gain axis solved (2× replicated); real quiet voice unmeasured until pass 4 |
| **Noise** (the dominant axis) | RI-noise +16.8 (wn5 − g0); wn5 expected to move >±3 across OS model swaps — that volatility is signal | Pass-3 café subset ≤ 2× same-speaker pass-1 WER ◇; noise cue (R27) fires on cliff-predicted utterances, flagged rows show elevated `edit_observed` | TTS measured; the only levers standing are honesty (R27) + engine choice (R22) — signal mitigation is dead by law |
| **Tone / vocal effort** | whisper-voice cell as canary only; deck prints "—" (honest: synthetic audio cannot reach this axis) | Pass-4 measured and published, whatever it says ◇; no local lever exists if it is bad (whisper stacks killed) — candor is the deliverable | **Unmeasured until human-v1**; the deck says so explicitly |
| **Rate** | r120/r240 within noise (uniform tempo is not real fast speech) | Pass-3 fast-pace penalty reported jointly with noise (confounded by design of the pass) ◇ | TTS near-flat; human is the only real data |
| **Bandwidth / Bluetooth** | bandlimit8k cell within +4 of g0 ◇ baseline at first run; alarm on any growth (the 24 kHz starvation class) | Pass-2 ≤ same-speaker pass-1 + 3 pts ◇; **zero** starvation empties across all pass-2 sessions | Incident-motivated; cell lands with A-3 |
| **Empties** | RI-empty = 0 across the whole deck (950-clip pilot baseline); any nonzero is news | Live: holds ≥ 2 s ending empty < 1 % over rolling 30 days (today ≈ 2.6 %: 8 real losses); sub-second finger-slips excluded by the R4 split | Live telemetry, decomposition lands with B-2 |
| **Term recall** (the product's reason to exist) | tts-accents corpus keeps `expect.terms` per voice; baseline at A-3 first run | Human-v1 proper-noun category, dict-on: ≥ 95 % term slots ◇; Parakeet-channel adoption decided by R22's bars, not vibes | TTS 14/18 vs 8/18 (plumbing-grade); human unmeasured |
| **Personalization** | replay probe (A-5): ≥ a handful of catches/100 to earn the miner | `zeroEditRate` on observed utterances trends up after each shipped learn feature; absolute bar set after 90 days of post-R4 data (refusing to invent one now is the honest move) | Live metric exists; supply improves with the IM workstream (R30) |
| **Feel** (native = seamless) | — (no TTS analog) | Paste rung honest `release_to_text_ms` p50 ≤ 300 ms (post-R6 ≈ 270); im rung ≤ 300 (263 today, n=14 — needs a few hundred rows); key-down→pill < 50 ms p95 once pinned with C-3; checkmark within one frame of text; 7/7 spec transitions present; zero feedback-dead states (`pill_hidden` → sound, secure input → menu lock) | Live metrics + binary artifacts; the metric-correction discontinuity must stay annotated in RESULTS |
| **Trust / honesty** (the soul axes) | — | The light never lies in any channel; voice persists only by deliberate act; one inventory page reaches every store (R17); optional weight never load-bearing; new persisted fields meet the ctx house style | Enforced by the seven soul tests (judge-soul §6), adopted as review criteria for every diff in §2 |

**What "top notch, any accent any volume any tone" honestly means under this
plan:** on the axes where local levers exist (accent via locale assets and
engine choice, level via already-solved invariance, capture races, feedback
truth), the numbers above are aggressive and reachable; on the axes where no
local lever exists (deep noise, whisper, tone), the product's promise is
calibrated candor — it measures, warns, and never fakes. The TTS deck keeps
all of it from regressing for two minutes of compute per release, and
human-v1 is the only place any of it becomes a claim.
