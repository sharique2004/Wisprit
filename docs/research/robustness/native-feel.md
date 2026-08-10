# Native feel — the audit

**Status:** research input for the robustness argument stage. Everything here is
grounded in the tree as of 2026-08-10 (HEAD `cbc7fb5`, dirty:
`SelfCorrection.swift`) and the *live* `~/.wisprit/metrics.log` (369 rows,
2026-07-15 → 2026-08-10). Where a claim has a number, the number was computed,
not quoted. Where a fix is proposed, it names its mechanism, its measurable
prediction, and its cost. Fantasy options are killed by name in §6 so the
argument stage does not spend time on them.

**Frame.** The design spec (`docs/design/ui-redesign.md`) is unusually good and
mostly *built*: the pill state machine, the Tally waveform, the onboarding
cascade, the Setup page, the menu-bar icon spec all exist and match their
sections. The native-feel gap is therefore not "build the spec" — it is five
specific seams where the implementation stops short of the spec, plus two whole
sensory channels (sound, hidden-pill feedback) the spec never covered.

---

## 1. The live numbers (read 2026-08-10, all 369 rows)

| Metric | Value | Source |
|---|---|---|
| release→text p50 / p90, all rungs | **758.5 ms / 967 ms** (n=298) | `release_to_text_ms` |
| — paste rung | **769 ms / 970 ms** (n=251) | outcome `paste` |
| — im_streaming rung | **263 ms / 328 ms** (n=14) | outcome `im_streaming` |
| — typed rung (terminals) | 395 ms / 975 ms (n=33) | outcome `type` |
| last 60 utterances, all rungs | 719 ms / 875 ms | recency check |
| finalize p50 / p90 | 119 ms / 264 ms | `finalize_ms` |
| insert p50 (non-zero) | **508.7 ms** | `insert_ms` |
| refine when it ran, p50 / p90 / max | 185 ms / 971 ms / 3 388 ms | `ai_ms` where `ai=applied` |
| empty rate (whole log) | 17.3 % (64/369; corrected from 17.7 % per the feasibility re-count) — 63 of 64 rows predate `empty_reason` | `outcome=empty` |
| hold length p50 / p90 | 5.4 s / 52 s | `held_ms` |

**The single most important fact in this audit:** the paste rung's 769 ms is
**≈ 270 ms of work + 500 ms of deliberate sleep.** `Inserter.pasteViaClipboard`
(`Sources/WispritMacInput/Inserter.swift:164-165`) posts ⌘V — at which instant
the text is *visible in the user's document* — and then `Thread.sleep`s
`paste_restore_delay_ms` (default 500, `Settings.swift:72`) before restoring the
clipboard. `SessionController.finish` stamps `tInsert` and calls
`pill?.flashSuccess()` only after `deliver()` returns
(`SessionController.swift:548-566`). Three consequences:

1. **The metric lies about feel.** Felt paste latency is ~270 ms — almost
   identical to the im_streaming rung's measured 263 ms, which contains no
   sleep. The headline "764 ms median" the team carries around overstates the
   felt number by roughly 2×.
2. **The feedback order is inverted.** The user sees their words land, and the
   pill goes on showing the grey `finalizing` sweep for another half-second
   before the checkmark. An indicator that is slower than the thing it
   indicates reads as *lag*, and it is the pill teaching the user that lesson
   ~250 times in this log.
3. **The session thread is blocked** for that 500 ms, so a fast re-press queues
   behind the sleep.

This is the cheapest large feel win in the codebase (item **P1**, §7).

---

## 2. Seams today, walked and graded

Grades: **A** feels inevitable · **B** correct but shy of the spec · **C**
functional, reads as mechanism · **D** actively misleads.

### 2.1 Key-down → pill appears — **A−**

Path: CGEventTap → `HotkeyEventQueue.put` (NSCondition signal, wakes the
blocked `get` immediately — `HotkeyEventQueue.swift:57,64`) → session thread
`begin()` → `pill?.showPrewarming()` **before** `audio.start()`
(`SessionController.swift:326-331`) → `MainThreadPill` hop → `orderFrontRegardless`.
The pill is on screen within a main-thread hop of the key-down — before the mic
opens, before the analyzer's `prepareToAnalyze` (31–54 ms measured, comment at
`SessionController.swift:346`). The `prewarming` state is drawn grey-at-floor
and only turns orange at `showRecording()`, after `audio.start()` succeeded —
the orange rule enforced in code (`PillPalette.isLive` is true only for
`.recording`, `PillGeometry.swift:83`). The design is exactly right.

The minus: the appearance is a **hard cut**. §2.5 specifies a 90 ms fade +
4 pt rise; `Pill.apply` does `setFrame(display:false)` + `orderFrontRegardless`
and `PillSurface` has no visibility animation (`Pill.swift:183-206`,
`PillSurface.swift:50`). No budget number exists for key-down→visible; propose
pinning one (< 50 ms p95) once P2 adds the fade, so a regression is a failed
assertion rather than a vibe.

### 2.2 Partial cadence vs perceived responsiveness — **B+**

First partial arrives ~1.26 s after speech starts (measured figure recorded in
`PartialTail.swift:10-13`); partials then update several times a second. The
seam is masked correctly: the Tally scrolls at 20 Hz from real mic peaks
(`SessionController.startLevelTicker`, 0.05 s), so "is it hearing me?" is
answered instantly by the bars while "what did it hear?" waits for the engine.
The tail is 3 words / 26 chars, monotone-width, quantized to 8 pt — no flicker
(`PillModel.livePartial`, `PillTailGeometry.width`). This is the correct
division of labour and it is already built. First-partial latency itself is
Apple's number, not ours; the gated Parakeet channel is the only lever and it
is out of scope here.

### 2.3 Release → text — **C+** (paste rung), **A−** (im rung)

Covered in §1. Additional detail: during `finalizing`/`refining` the sweep
hairline (900 ms linear loop, `PillSurface.swift:149-171`) is the wait-state
mask, and it works — no spinner, movement without chrome. The failure is purely
the *ending*: text appears mid-sweep, checkmark 500 ms late. The im_streaming
rung has no such gap: `insert_ms` p50 is 2.8 ms there and the committed text is
the volatile text turning solid — the best release→text feel in the app, live
in the log since 2026-08-09 (14 utterances, p50 263 ms).

### 2.4 Refine-stage waits — **A−**

The pill switches to `refining` (sparkles glyph + sweep) only when the refiner
actually runs (`SessionController.swift:474`), so the user is told *which* wait
they are in — the one §2.4 calls "the only one a user can mistake for a hang."
Esc aborts mid-generation in ~100 ms; a queued fn-press finishes the stage
instantly with verbatim text (`Refiner` poll loop, 50 ms interval). Live
`ai_ms` p90 971 ms / max 3.4 s says the state earns its keep. No change needed;
keep sacred.

### 2.5 Error paths — what a starved mic feels like — **C**

The classifier is excellent (`EmptyReason.classify`,
`Sources/WispritEngine/EmptyReason.swift`) and each reason gets distinct copy
(`SessionController.flashEmpty:874-887`): starved → "Microphone delivered no
audio", silent → "Didn't hear anything — is the right mic selected?",
short-hold → a *notice*, not an error ("Hold the key while you speak") — that
last distinction is genuinely thoughtful. Two real problems:

1. **The copy is destroyed by geometry.** Errors get a 40-character budget
   (`PillGeometry.errorMessageCharacters`), but `PillTailGeometry.maxWidth`
   caps the text frame at 196 pt ≈ 30 chars at the measured 6.5 pt advance, and
   the `Text` uses `.truncationMode(.head)` (`PillSurface.swift:77`) — right
   for a live tail, wrong for a diagnosis. "Didn't hear anything — is the right
   mic selected?" (49 chars) is first char-clipped to 40, then head-truncated
   to ~30: the user sees roughly "…— is the right mic…" and *loses the
   diagnosis* ("Didn't hear anything"). Verified by arithmetic against
   `PillTailGeometry.width(forCharacters:)`; §2.4's own numbers contain the
   contradiction (40-char budget, 260.5 pt max panel). Item **P3**.
2. **The reassurance is posthumous.** A dead mic is knowable *during* the hold
   — the level ticker is already delivering zeros to `PillModel.updateLevel` —
   but the user learns about it only after releasing, as a 1.6 s flash. During
   a 30-second dictation into a muted mic, the only live signal is bars sitting
   at dim floor. Item **P5** proposes the live cue.

Also: `pasteLast`'s secure-input branch calls `flashError("secure field — …")`
(`SessionController.swift:635-637`) while the main path has the dedicated
`blockedSecure` lock state with its longer 2.6 s dwell — the same condition
styled two ways. Minutes to unify (**P8**).

### 2.6 Secure Keyboard Entry — the dead seam — **D** (by nature), remediable to C

While another app holds Secure Keyboard Entry, macOS suppresses the event tap
entirely: Wisprit cannot even know the key was pressed, so *no* pill state can
fire. The Hub shows an excellent banner (`SetupChecklist.secureInputNotice`) —
but the user experiencing "I pressed the key and literally nothing happened" is
not looking at the Hub. The one channel that still works is the menu-bar icon.
Today `StatusIconState` knows `dictationEnabled` and `needsSetup` only. Item
**P9**: a lock-badged menu icon while `IsSecureEventInputEnabled()` — sampled
cheaply (the doctor already reads it; the menu already re-samples state on
every open and state change). Prediction: the recurring "Wisprit is dead in
Slack" support moment becomes a glance.

### 2.7 First run — permission cascade → time-to-wow — **B**

The cascade (`OnboardingModel.swift`) is the strongest first-run flow in the
local-dictation category on paper: mic grant → **mic test** (proof macOS handed
over a live input — gated on a real voiced peak ≥ 0.02, six-second silence
before Skip appears) → 🌐-key check *before* Input Monitoring (the only step
resolvable without a system prompt, and auto-skipped on right-⌥) → grant →
grant → **practice moment** with live underline → optional Live Typing. Wispr's
two praised moves (gated cascade, practice moment) are both present, plus the
mic test Wispr lacks.

The honest cost: worst case is **three System Settings visits and one
mandatory relaunch** (Input Monitoring binds at launch — `relaunchNote`,
`SetupChecklist.swift:185-187`) before the wow. The relaunch is macOS
mechanics, not ours (killed in §6), and resume-after-relaunch works
(`onboarding_step` persisted, `shouldAutoOpen` re-raises). What is missing is
*measurement*: nothing records first-launch → first `didDictate`. Item **P10**
adds one metrics row so "time-to-wow" becomes a number the eval culture can
watch instead of a story.

### 2.8 Menu-bar glyph — **A**

`iconSpec(for:)` ships: template `mic` idle, **non-template orange `mic.fill`
while recording** (sanctioned orange #2), template `mic.fill` working,
`mic.slash` disabled, `exclamationmark.circle` needs-setup, with the collision
priority the spec ordered (`StatusMenuModel.swift:283-300`). Emoji glyphs are
gone from the bar. Decision pure, tested, sampled without main-thread TCC reads
(`AppController.swift:579-581`). Nothing to do.

### 2.9 Live Typing enable friction — **B+**

One menu click → `InputMethodInstaller.plan()/run()` → the system's own
"wants to activate" dialog → done; idempotent no-op path flips the setting
silently (`AppController.enableLiveTyping:679-703`). TIS mutation happens
nowhere else, by construction. The per-app silent downgrade
(imStreaming → imCommit → paste) is documented in the one honest sentence that
prevents "the feature is broken" (`liveTypingPerAppNote`). Remaining friction
is the failure copy: "Could not enable Live Typing — run Doctor" points at a
*terminal ritual* when a Setup page now exists (**P6**).

### 2.10 Sound design — **absent**; the convention says it should exist

There is zero audio feedback in the app (`grep NSSound/AudioServices` — no
hits). The conventions: macOS built-in dictation plays a start cue;
Superwhisper's docs state "Audio cues will still notify you when recording
starts and when processing completes" even with its recording window disabled
([superwhisper.com/docs/get-started/settings-advanced](https://superwhisper.com/docs/get-started/settings-advanced)),
and its changelog ships refinements to those sounds — in this category sound
is table stakes, not garnish. The clinching internal fact: **`pill_hidden` is a
shipped setting, and a hidden pill suppresses every state** (`PillModel.show`
guards on `isSuppressed`, all show paths) — a pill-hidden user currently
dictates with *no feedback channel at all* except a 16 pt menu icon. Item
**P4**: two sub-100 ms cues — mic-open (played on `showRecording`, i.e. only
once the mic is truly open, same honesty contract as the orange) and commit —
low-gain, `Settings` toggle, and under `pill_hidden` they carry the whole
feedback burden. Error states deliberately get **no** sound (the visual alarm
body + shake is enough; a failure buzzer would make a starved mic feel like a
slot machine).

### 2.11 Haptics — killed, see §6.

### 2.12 The §2.5 transition table — **the largest spec/build gap** — **C**

Implemented: the sweep, the one-shot alarm shake, Reduce Motion handling for
both, the deliberate no-interpolation of bar heights (correct — the 50 ms tick
*is* the animation, `TallyWaveform.swift:95-98`). **Not implemented — verified
by absence of any `.animation`/`NSAnimationContext` on these paths:** the
90 ms appear fade+rise; the prewarming→listening 140 ms tint crossfade (color
snaps); the 120 ms width spring (panel `setFrame` snaps between quantized
widths, `Pill.swift:191-196`); the finalize desaturate + 6 ms/bar staggered
collapse (`waveform.collapse()` zeroes all slots in one frame); the
`committed` contraction spring (260.5 → 28 pt as a hard cut); the 160 ms
hide sink (orderOut, instant). Seven of ten table rows missing. Each absence
is a hard cut at a moment of state change — exactly where "native" apps spend
their motion budget. Item **P2**. The constraint that must survive: silence
still costs zero redraws, and nothing may animate on the 20 Hz level path.

### 2.13 Restore clamp / edge flip — **A**

Both §2.6 positioning guards are built and correct (`Pill.swift:138-171`),
including the subtle "preferredOrigin survives the edge flip" detail. Nothing
to do.

---

## 3. Invisible-technology principles — where mechanism leaks, where silence hurts

The exemplar the spec names — mic-orange if-and-only-if the mic is open — is
enforced in code, not convention (`PillPalette.isLive`, one predicate). The
audit looked for places that break the same contract in either direction.

**Shows mechanism, should be silent:**

| Leak | Where | Fix |
|---|---|---|
| `apple_live` config token in every Home row caption ("14:32 · 11 words · apple_live · 0.4s") | `HomeSource.caption`, `HomeSource.swift:69-74`; mandated by spec §3.3 | Map to human words ("on-device") or drop when there is only one engine; keep mono styling. **P7** |
| "Run Doctor…" menu item spawns a **Terminal window** running the CLI | `AppController.openDoctorInTerminal:747-760` | Route to the Setup page (`openWindow(tab: .setup)`), which is the same doctor rendered natively; keep the CLI for terminal users. **P6** |
| "Could not enable Live Typing — run Doctor" pill notice | `AppController.swift:699` | "— see Setup", open the page. **P6** |
| Insights' `empty_reason`/`ai`/`outcome` vocabulary strings | by design, §1.4 mono rule | Keep. This is the Instrument school being itself; machine text labelled as machine text is honesty, not leakage. |

**Silent, should reassure:**

| Gap | Evidence | Fix |
|---|---|---|
| Dead/muted mic during the hold | level ticker already delivering zeros; user learns only after release | **P5** live cue |
| Everything, when `pill_hidden` | all pill states suppressed | **P4** sound |
| Secure-input key-swallowing | event tap never fires; Hub banner unseen | **P9** menu-bar lock |
| Text landed but pill still says "finishing" | §1, feedback inversion | **P1** |

**Correctly silent — keep sacred:** the per-app insertion-tier downgrade (the
Settings read-only fallback list is the right disclosure surface, not a
per-utterance toast); clipboard restore (including the changeCount check that
declines to clobber a clipboard manager's write, `Inserter.swift:168-175`);
history-before-insert; the transient-pasteboard marker; the retro-correction
notices already distinguishing "Fixed X" (document changed) from "Learned X"
(dictionary changed) — `applyVocabularyRetro:837-841` — which is precisely the
truth-in-feedback discipline this whole section is about.

---

## 4. Competitor feel — what they are praised for, what we already do better

From `docs/research/competitors.md`, `wisprflow-ui.md`, and fresh checks:

**Praised elsewhere, missing here:** (1) *Streaming-insertion feel* — Aqua's
signature ("text appears as you speak"); Wisprit has it, but only on the IM
rung (14 of the last 60 utterances). The lever is rung coverage plus P1's
fixed paste-rung feedback, not new machinery. (2) *Audio cues* — Superwhisper
(§2.10). (3) *Idle presence* — Wispr's collapsed hover-expand bar; Wisprit's
pill is hidden at idle by design. Defensible: push-to-talk needs no idle
chrome; do not adopt. (4) Wispr's share-cards/percentiles/"time saved" —
structurally impossible without a network and already correctly refused
(spec §7).

**Already better — keep sacred, defend in any future diff:** one native
bundle vs Wispr's Electron (~800 MB idle criticized in the research); the
push-to-talk grammar (release = confirm, Esc = cancel — no 18 px buttons on a
28 pt pill); ⌘Z-clean single-undo commits on the IM rung; verbatim-first
refine cage (Wispr's #1 output complaint is over-editing); the mic-orange
tally-light honesty; "No network calls. Ever." as a checklist row rather than
a marketing page; consent-gated context awareness (the exact opposite of the
screenshot scandal that is Wispr's biggest trust liability); Esc responsive
inside the longest stage.

---

## 5. What already meets the bar (so the panel doesn't relitigate it)

Prewarming-before-mic-open; the orange rule as a predicate; the Tally's
zero-redraw silence discipline (`WaveformBuffer.push` returning false, pinned
by test); quantized monotone tail width; the empty-reason classifier and its
short-hold-is-coaching distinction; the refining state; blockedSecure as a
lock (not an alarm) with a longer dwell and the remedy in the message; the
onboarding mic test; Setup/Doctor single-source-of-truth; menu-bar iconSpec;
positioning guards; the restraint list in spec §7.

---

## 6. Fantasy options, killed by name

| Option | Why it is dead |
|---|---|
| **Streaming insertion into every app** (make rung 1 universal) | Marked-text acceptance is the *target app's* decision; terminals and many Electron fields refuse it. `InsertionLadder`'s downgrade is the ceiling macOS offers. The felt-latency gap between rungs is closed by P1 (~270 ms ≈ 263 ms), so universality buys almost nothing anyway. |
| **Shrink `paste_restore_delay_ms` to make paste "fast"** | The sleep is not the felt latency (text lands before it); shortening it reintroduces the #1 competitor bug ("it pasted my old clipboard") the 500 ms floor exists to prevent (`Inserter.swift:39-42`). Fix the feedback (P1), not the safety margin. |
| **Trackpad haptics on key-down/commit** | `NSHapticFeedbackManager` actuates the *trackpad*, is HIG-scoped to direct trackpad interaction (alignment, drag), does nothing on desktops or external keyboards, and firing it while hands are on keys is noise from the wrong limb. Not a degraded option — a category error. |
| **Removing the mid-onboarding relaunch** | Input Monitoring binds at process launch. macOS mechanics; the flow already resumes correctly after relaunch. |
| **Speculative typing of partials on the paste rung** (type then fix) | Destroys the ⌘Z-clean commit and risks mangling fields Wisprit doesn't own; the IM rung already does provisional text *correctly* via marked text. |
| **Animated waveform in the menu bar** | Timer-driven NSStatusItem redraws on the main thread while the CGEventTap is live — the exact budget §2.7 forbids spending. The pill is the tally. |
| **Faster first partials from Apple's engine** | `SpeechAnalyzer` cadence is Apple's. The only lever is the gated Parakeet channel — a different workstream, out of scope for feel polish. |
| **Cutting release→text below ~150 ms via pipeline heroics** | finalize p50 is already 119 ms and the p90 tail (264 ms) is engine-side. Post-P1 the felt number is ~270 ms across rungs; the remaining floor belongs to Apple's finalize, not to us. |

---

## 7. Ranked polish list

Each: the seam → the fix → effort (hours / day / multi-day) → how to verify
the feel change.

| # | Seam | Fix (mechanism) | Effort | Verification |
|---|---|---|---|---|
| **P1** | Checkmark + metric trail visible text by 500 ms on the paste rung (§1) | In `pasteViaClipboard`, capture "text delivered" at `postCommandV`; return it in `InsertResult` so `finish()` stamps `release_to_text_ms` there and flashes success immediately; sleep+restore stay on the session thread after the flash (semantics unchanged, ordering preserved). Optionally write `restore_ms` separately. | hours | Live metrics: paste `release_to_text_ms` p50 falls ~770 → ~270 ms with no pipeline change (the honest number, not an improvement claim — say so in RESULTS notes). Manual: checkmark lands within one frame of the pasted text. Existing InserterTests extended for the new timestamp. |
| **P2** | Seven missing §2.5 transitions — every state change is a hard cut (§2.12) | Animate panel frame via `NSAnimationContext`/`animator()` for width & appear/hide; SwiftUI `withAnimation` for tint crossfade, staggered collapse (precomputed per-bar delays in the model, not 15 view identities), committed contraction. Level-tick path stays animation-free; silence-is-free property untouched. | day | Manual against the §2.5 table + Reduce Motion pass (snap, static sweep, no shake — already half-built). Regression guard: idle-visible pill still emits zero renders (existing WaveformBuffer test). |
| **P3** | Error copy double-truncated; head-truncation cuts the diagnosis (§2.5.1) | Error/blockedSecure states: `truncationMode(.tail)` + either raise a dedicated `errorMaxWidth` (≈ 280 pt fits the 40-char budget) or cut copy to ≤ 28 chars ("No audio from mic", "Nothing heard — check mic"). One place: `showMessageState` + `PillSurface`. | hours | `PillModelTests`: rendered `bubbleWidth` fits `message.count × characterWidth` for every `flashEmpty` string. Manual: mute mic, read the flash. |
| **P4** | Zero audio feedback; `pill_hidden` users have no channel at all (§2.10) | Two cues ≤ 100 ms, low-gain (`NSSound`, bundled assets): mic-open on `showRecording` (honesty: only after `audio.start()` succeeded), commit on success. `sounds` Settings toggle; no error sounds. | day (asset taste is the cost) | Manual matrix: pill visible/hidden × sound on/off; cue never fires when `audio.start()` fails. Convention check against macOS dictation + Superwhisper stands in §2.10. |
| **P5** | Dead mic discovered only after release (§2.5.2) | In `PillModel.updateLevel`, track consecutive sub-threshold ticks while `.recording`; after ~2 s show muted tail "No audio — check mic" (notice styling, not orange, clears on first voiced tick). Pure model change, testable headless. | hours | `PillModelTests`: 40 silent ticks → tail present; one voiced tick → gone. Manual: mute mic mid-hold. |
| **P6** | Doctor-as-Terminal-ritual: "Run Doctor…" spawns Terminal; failure copy says "run Doctor" (§3) | Menu item → `openWindow(tab: .setup)` (rename "Open Setup…"); keep `wisprit doctor` CLI; fix the Live Typing failure notice to open Setup. | hours | Menu click lands on Setup page; StatusMenuModel test updated for the row. |
| **P7** | `apple_live` config token in Home captions (§3) | Display-map engine ids in `HomeSource.caption` ("on-device"); omit entirely while only one engine ships. | hours | Snapshot of caption strings in `HomeSourceTests`. |
| **P8** | Same condition, two styles: `pasteLast` secure-input uses `flashError` not `flashBlockedSecure` | One-line switch in `pasteLast`. | minutes | Existing pill tests. |
| **P9** | Secure input renders the app silently dead; only surviving channel unused (§2.6) | `StatusIconState.secureInput` + lock-badged template icon; sample `IsSecureEventInputEnabled()` where icon state is already sampled, plus a low-rate idle poll (never while a key is held — same discipline as `noteSessionState`). | day | Manual: focus a password field → icon changes ≤ 2 s; release → clears. Unit: `iconSpec` priority test (`secureInput` above `recording`? No — below `needsSetup`, above `idle`; decide in the diff). |
| **P10** | Time-to-wow is a story, not a number (§2.7) | Write one `onboarding` metrics row: first-launch ts → first `didDictate` delta, steps skipped, relaunch count. | hours | Row appears in `metrics.log` on a fresh `~/.wisprit`; summarized in `MetricsSummary` later if wanted. |
| **P11** | Fast re-press queues behind the restore sleep (post-P1 residue) | Only after P1: check `events` for a queued press before sleeping; if present, skip restore (clipboard already carries the transcript — the same trade `pasteLast` makes). Ordering-sensitive; needs its own test. | multi-day (for the care, not the code) | Session test: press during restore window starts next utterance < 100 ms; clipboard state asserted both branches. |

**Sequencing note.** P1 before P2 (P2's `committed` timing looks wrong until
the checkmark stops arriving late); P4 and P9 are independent; P11 only after
P1 has soaked, since it trades a safety behaviour on an explicit signal.

---

## 8. What this audit could not verify

- Wispr Flow's own sound behaviour (docs silent; no install at hand) — the
  convention claim rests on macOS dictation + Superwhisper, which is enough.
- The felt quality of P2's animations — a taste pass on real hardware is the
  verification; the table only guarantees the motion exists.
- im_streaming's 263 ms p50 is n=14 from one machine and two days of use;
  treat it as directional until the rung has a few hundred rows.
- Whether `updateLevel`'s prewarming→recording promotion
  (`PillModel.swift:174-176`) ever races `showRecording` in practice; benign
  either way (both end in `.recording`), noted for the owning workstream.
