# Judge — product soul and privacy

Adversarial pass over the four robustness reports (`acoustic.md`,
`personalization.md`, `measurement.md`, `native-feel.md`), 2026-08-10. Lens:
Wisprit's identity — zero network, verbatim-first, consent-first, mic hard-off
between holds, one small bundle, every failure degrades to what the user
already has. Two attack directions were run on every recommendation: (1) does
it erode the identity, even slightly; (2) is it *too timid* — is dogma
masquerading as principle where a consent-first design would unlock real value
(the repo's own precedent: AX context awareness, which turned "we never read
your screen" into "we read exactly this, with your explicit yes, and here is
the kill switch").

Repo facts checked for this pass (not taken from the reports):
`History.purge()` deletes `transcripts` + `utterance_detail`
(`Sources/WispritPersistence/History.swift:336–349`); **`metrics.log` has no
delete surface anywhere** (`MetricsWriter` is append-only; "Delete All
Transcripts" leaves every metrics row); the consent house style already
exists in code — the Phase-4 `ctx*` metrics fields are "Omitted entirely
while the consent flag is off — the default-off install never grows a byte…
the STATUS vocabulary only, never text"
(`Sources/WispritPersistence/MetricsWriter.swift:57–61`). That sentence is
the bar every new persisted field in these reports must meet, and one
proposal fails it (§2.3).

---

## 1. Verdict summary

| # | Item (source) | Verdict | One line |
|---|---|---|---|
| A1 | Locale picker + per-user bake-off (acoustic §1) | **KEEP, reshaped** | Soul-positive (ask, don't infer) — but run the bake-off on *ephemeral* audio; see §4.1 |
| A2 | Kill AGC / pre-gain / NS / vpio (acoustic §2) | **KEEP — constitutive** | Refusing to rewrite the user's signal *is* verbatim-first at the acoustic layer |
| A3 | `voicedPeakThreshold` recalibration (acoustic §2) | **KEEP, strengthen** | Add the engine-based mic test (§4.2) — pass on evidence, not on a proxy threshold |
| A4 | Replay retained head at engine install (acoustic §3) | **KEEP** | The model privacy-preserving fix: same audio, same window, zero new retention |
| A5 | `first_voiced_ms` metric (acoustic §3) | KEEP | Measure exposure before building; local scalar |
| A6 | Pre-roll stays dead (acoustic §3, §5) | **KEEP, argument strengthened** | See §3.1 — opt-in does not rescue it either |
| A7 | Parakeet "accuracy mode" (acoustic §4) | **WEAKEN** | Log-only v1: keep. Silent post-insert splice: kill. §2.1 |
| A8 | Acoustic kill list ×9 (acoustic §5) | KEEP | All correctly dead; do not reopen |
| B1 | P0-1 hear-phrase mining (personalization) | **KEEP** | Propose-first, term-scoped, zero new data; the soul-compatible "learning" |
| B2 | P0-2 frequency-weighted biasing (personalization) | KEEP | Zero privacy surface; measured motivation |
| B3 | P0-3 personal eval corpus (personalization) | **WEAKEN** | Kill the per-session consent variant; deliberate-activity shape only. §2.2 |
| B4 | P1-4 deterministic style rules (personalization) | KEEP | Inspectable, dismissible rules — the anti-drift personalization |
| B5 | P1-5 per-app vocabulary profiles (personalization) | **WEAKEN harder** | Its purge claim is half-true — the metrics key is purge-immune. §2.3 |
| B6 | P2-6 few-shot / P2-7 generic adapter deferrals | KEEP | Deferrals correct; bundle-soul note in §3.4 |
| B7 | Personalization kill list ×7 | KEEP | Including the mlx-lm kill-by-directive with its named reversal condition — the honest way to record product law |
| C1 | Synthetic matrix + enhanced voices + corners (measurement) | KEEP | Dev-side; zero user-facing surface |
| C2 | osBuild in ASR cache key (measurement §6.2.4) | **KEEP — soul item** | Provenance honesty is the eval culture's identity; a cache that lies is a small betrayal of the same principle as a pill that lies |
| C3 | `peak_level`/`audio_ms`/noise-floor on every metrics row | KEEP, with purge note | Scalars, not content — but they land in a purge-immune file; see §4.4 |
| C4 | Public-corpora rung, human-v1, measurement kill list | KEEP | Dev-side; consented recording |
| D1 | Native-feel P1 (feedback order) | **KEEP — top of the whole program** | The pill currently lies ~250 times in the log; truth-in-feedback is the soul |
| D2 | P2 (transitions), P3 (truncation), P5 (live dead-mic cue), P6/P7 (mechanism leaks), P8, P9 (secure lock icon), P10 | KEEP | All either remove mechanism or extend the honesty contract |
| D3 | P4 sound design | KEEP, two conditions | Cue-bleed check + default policy; §3.3 |
| D4 | P11 skip-clipboard-restore on fast re-press | **KILL (park)** | Trades the user's clipboard on an implicit signal; §2.4 |
| D5 | Native-feel kill list ×8 | KEEP | Streaming-universal, haptics, idle chrome, share cards: all correctly dead |

---

## 2. Kills and hard weakenings — where the reports erode the soul

### 2.1 Accuracy mode: the silent-splice variant dies; the rest survives on conditions

Acoustic §4 is carefully staged (log-only ROC before any user-visible
behavior — keep that, it is the right discipline). But the user-visible stage
as sketched ("surface the existing retro-correction machinery") smuggles in a
category change the report does not name. Today's retro-corrections splice
toward the *user's own approved dictionary terms* — the anchor is something
the user explicitly owns, and the pill already distinguishes "Fixed X"
(document changed) from "Learned X" (dictionary changed). A
disagreement-triggered re-decode splices toward *a second model's opinion*,
with no user-owned anchor. Silently changing words the user has already seen,
because two models argued, is precisely the "the app rewrites what I said"
failure that verbatim-first exists to refuse — and the class of complaint
that dominates Wispr's reviews.

Conditions for the user-visible stage, if the ROC earns one:

1. **Explicit mode, honest name.** "Accuracy mode" as a setting the user
   turns on is good consent design; a default-on background second-guesser is
   not. Never default-on.
2. **Notice-based, never silent.** Every disagreement-driven edit gets the
   same visible notice as vocab-retro, and the reconciler's refusal-gate
   discipline applies unchanged.
3. **The 562 MB never becomes load-bearing.** Optional download, and every
   behavior the user had before the download still works identically without
   it ("every failure degrades to what the user already has" applies to
   *absence*, not just failure).
4. Re-decode happens inside the existing `RetainedUtterance` transient
   window. It already does per the design; pin it in the diff so it stays
   true.

A soul-compatible reshaping the report missed is in §4.5.

### 2.2 P0-3 personal eval corpus: kill the per-session variant

The report offers "per-utterance or per-session" contribution. The
per-session shape dies here. A session toggle the user flips and forgets is
the quiet-accumulation failure mode — an hour later there are dozens of
voice clips of possibly-sensitive dictation (messages, names, health, the
things people dictate) sitting in `~/.wisprit`, kept by a decision the user
no longer remembers making. That is a voice profile assembled by default
drift, which is the exact shape of thing "consent-first" exists to make
impossible. The first feature that ever stores voice must be the most
deliberate surface in the app, not the most convenient.

Required shape:

- **Deliberate activity, not an ambient toggle**: the existing
  `Wisprit eval record` flow — the user sits down *to record*, reads
  scripts or dictates freeform knowing each clip is kept, reviews via
  `eval verify`. No contribution path exists from ordinary dictation.
- **Hard cap** (the report's own 50-clip number is fine) and a **visible
  inventory**: list, play, delete-each, delete-all. If the user cannot see
  and destroy every clip in one place, the feature is not consent-first, it
  is consent-once.
- **Say the backup sentence.** `~/.wisprit` is inside the user's home;
  Time Machine and cloud folder sync will carry these clips. One sentence in
  the consent sheet ("these recordings live in your home folder and follow
  your backups") is the difference between informed and technically-informed.
- **Measurement only, never training** stays a bright line (the report
  already draws it; keep it in the consent copy, not just the docs).
- One consent surface, not two: acoustic §1's bake-off and P0-3 both
  propose consented recording. They must be the same flow with the same
  inventory, or the app grows two subtly different voice-retention stories.

### 2.3 P1-5 per-app profiles: the purge claim is half-true — verified

Personalization P1-5 says the bundle-ID field is "purge-covered" — true for
`utterance_detail` (verified: `History.purge()` deletes it,
`History.swift:341–344`), **false for the proposed "additive metrics key"**:
`metrics.log` has no purge, no delete surface, and survives "Delete All
Transcripts" untouched. As proposed, P1-5 would create a timestamped,
purge-immune log of which app the user dictated into — the Wispr
1,688-app-events scandal class, in the one file the delete button does not
reach. The report names the scandal class and then routes the data around
the purge anyway.

Conditions (beyond the report's own ranking-behind-P0s, which stands):

- The bundle-ID **metrics** key ships only under the `ctx*` house style:
  omitted entirely unless a consent flag is on, so the default install never
  grows a byte of app log — or it does not ship in metrics at all
  (`utterance_detail` alone serves the stated mechanism, and that table is
  purge-covered).
- Do not build until a P0 item demonstrates a measured need for the app
  dimension. Its prediction is the weakest in its report by the report's own
  admission; weakest prediction plus the only narrative cost equals last,
  and "last" may mean never.

### 2.4 Native-feel P11: kill (park indefinitely)

Skipping clipboard restore because a re-press arrived trades the user's
property on an *implicit* signal. `pasteLast` making that trade is fine — it
is an explicit user command whose documented meaning involves the clipboard.
A fast second dictation is not a request to abandon the user's clipboard; a
password-manager entry or a screenshot silently replaced by a transcript
because the user dictated twice quickly is a real harm with no confirming
act. The report itself prices P11 at "multi-day (for the care, not the
code)" — the care is the tell. Alternatives if the queued-press stall ever
matters in the log (today it is theoretical): restore *later* instead of
never (defer restore to after the next utterance completes), which keeps the
property guarantee at the cost of a longer window. Until the stall shows up
in `metrics.log` as a felt problem, P11 stays dead.

---

## 3. Keeps worth defending — so the argument stage does not reopen them

### 3.1 The pre-roll kill, with a stronger argument than the reports gave

Acoustic §3 prices the pre-roll honestly (~50 ms + anticipation speech) and
keeps it dead on the privacy headline. Two additions that close the
"opt-in?" escape hatch the panel will probe:

1. **The OS tattles, correctly.** An always-on pre-roll keeps the mic live
   between holds, so macOS's own orange microphone indicator burns
   permanently while Wisprit runs. The product would be visually
   indistinguishable from the surveillance-ware it defines itself against —
   in the system's own trust UI, which Wisprit cannot style.
2. **The pill grammar cannot represent it.** Mic-orange iff mic-open is a
   code-enforced predicate (`PillPalette.isLive`) and the app's deepest
   honesty contract. "Mic live but not recording, trust us" requires a third
   state that dilutes the light for every user, opted-in or not. Opt-in does
   not contain the damage, because the *grammar* is shared.

So: not "dead because privacy dogma" — dead because 50 ms cannot buy back
the two honesty surfaces it would spend.

### 3.2 The conditioning kills (A2) are the soul, stated as such

Kill-AGC / kill-NS / kill-vpio is not merely empirically supported (gain
probe; the 40/40 enhancement study) — it is identity. A capture path that
rewrites the signal before the engine hears it is the acoustic version of an
over-editing refiner. The reports' framing ("the capture path's only jobs:
don't drop samples, don't add latency, meter honestly") should be quoted
verbatim in the argument stage as product law. Likewise A4 (head-replay) is
the house model of a fix: it closes a race using only audio already inside
the consented window, and it should be the example cited whenever someone
proposes solving a capture problem by widening capture.

### 3.3 Sound design (P4): keep, with two conditions

The mic-open cue tied to `showRecording` extends the tally-light honesty
contract into a second sense, and for `pill_hidden` users it is the only
feedback channel — this is removing a silence that *hurts*, not adding
chrome. Two conditions:

1. **Cue-bleed check.** The mic-open cue fires at the exact moment capture
   goes live, from the machine's own speakers. Before shipping, run the
   cheap eval: mix the cue asset into the head of matrix clips at realistic
   coupling levels and confirm zero transcript delta. Probably a no-op
   (100 ms low-gain chime vs a gain-invariant engine) — but "the app's own
   feedback perturbs the transcript" is exactly the kind of self-inflicted
   wound the conditioning kills exist to prevent, so buy the certainty; it
   costs minutes on the existing harness.
2. **Default policy follows the feedback budget.** Sounds default-on when
   the pill is hidden (they carry the whole burden), default-off when the
   pill is visible (the pill already answers; a default-on chime in an
   open-plan office is the app drawing attention to itself — the opposite of
   native). One toggle, defaulted per `pill_hidden`, never two settings.

### 3.4 The bundle-soul rule, extracted from three reports

Parakeet (562 MB), a generic FM adapter (160 MB), enhanced TTS voices
(dev-side): each report handles its download honestly, but nobody states the
shared rule. State it once: **optional weight never becomes load-bearing.**
The default install stays one small bundle, complete; every optional
download must leave behavior identical in its absence; and no accuracy claim
in marketing or scoreboard may quietly assume an optional component. This is
the "degrades to what the user already has" axiom applied to disk instead of
failure, and it is the test any future "just bundle it" argument must fail.

---

## 4. Missed opportunities — where the reports are too timid

The repo's own precedent (AX context) proves the pattern: a consent-first
design can unlock value the dogmatic reading forbids. Five places the
reports stopped short:

### 4.1 The ephemeral locale bake-off — no retention needed at all

Acoustic §1 routes the bake-off through recorded human-v1 clips, which
drags it into P0-3's voice-retention consent class. Unnecessary. The
reference for a bake-off is *the script the user reads* — so onboarding can
say "read these five sentences," decode the audio under every installed
English locale **in memory**, score each against the known script, show the
winner ("Your English: en-IN — 14% fewer errors on your voice"), install DT
assets for the winner, and discard the audio. Zero retention, zero new
consent surface, and the §1 measurement becomes a shipped moment of visible
intelligence instead of a lab procedure. Cost: the same
`EvalRunner.asrSettings()` locale parameterization §1 already requires,
plus an onboarding step. The stored-corpus bake-off remains available for
the consented-eval user; the ephemeral one is the one everyone gets.

### 4.2 Pass the mic test on evidence, not on a threshold

Acoustic §2 proves the engine transcribes perfectly at meter peak 0.010
while `OnboardingMicTest.passLevel` fails users below 0.02 — then proposes
waiting for ~100 telemetry rows to recalibrate the proxy. Skip the proxy.
The mic test already captures audio; feed it to the transcriber and pass
when words come back. "We heard you" demonstrated by *hearing them* is
strictly more honest than any threshold, needs no telemetry wait, and can
never fail a quiet speaker the engine could serve. Keep the meter as the
progress bar; make the engine the judge. (The 0.02 floor keeps its one
legitimate job — the cheap engine-release heuristic — exactly as §2
recommends.)

### 4.3 A live "this is noisy" honesty cue — the only noise lever left standing

Read together, the reports create a paradox they never name: measurement.md
shows additive noise is the dominant failure axis (11.8% → 28.5% at SNR 5),
while acoustic.md correctly kills every noise mitigation (NS, vpio, AGC).
So the product's entire answer to its worst axis is currently *nothing*.
The honest lever nobody proposed: measurement.md already specs a
per-utterance noise-floor estimate for telemetry — surface it. When the
(level, floor) proxy predicts the cliff, tell the user, in the pill's
notice register, after commit: "Noisy here — expect errors." Same school as
the tally light and P5's dead-mic cue: never rewrite the signal, always
tell the truth about conditions. Calibrate the trigger against the matrix's
wn cells (the mapping is exactly what C3's field was built for), predict
that flagged utterances show elevated edit rates in `edit_observed`, and
ship it as coaching, not apology.

### 4.4 One inventory, one purge — make consent-first visible

Verified this pass: "Delete All Transcripts" purges history, but
`metrics.log` is untouchable, dictionary/ledgers have only per-item
removal, and the reports now propose more stores (eval clips, mining
ledgers, style rules). Every report gestures at "the purge covers it";
collectively they are building a data estate the purge does not cover. The
missed feature is small and identity-defining: one Settings surface that
lists every class of thing Wisprit keeps (transcripts, metrics, dictionary,
ledgers, eval clips — with sizes), each with its own delete, plus
delete-everything. It is the AX-consent precedent generalized: the app that
asks before reading should also show what it kept and delete on command.
Wispr's scandal was not collecting data so much as users discovering it;
the inventory is how Wisprit makes discovery a feature. Cost: a page over
stores that all already know their own files. Also fold in: derived data
(hear phrases mined by P0-1 from since-purged history) survives a history
purge by design — fine, because the dictionary is user-owned and visible,
but the inventory page is where that sentence gets said.

### 4.5 Disagreement as honesty, not correction

If A7's ROC shows disagreement predicts error, the first user-visible
product need not be *editing* at all: badge low-confidence utterances in
History ("this one may have errors"), where the user already reviews text.
Reference-free quality estimation surfaced as candor — no splice, no
verbatim-first tension, no notice fatigue — and it builds the same trust
that makes an eventual opt-in accuracy mode credible. Cheaper than the
correction path, shippable the day the ROC exists, and it converts the
562 MB question from "let a second model rewrite you" to "let a second
model warn you," which is an easier consent story in exactly the way this
product should prefer.

---

## 5. Cross-report tensions the panel should not score as hits

- **Gain numbers differ, verdict does not.** Acoustic's probe reads
  "gain-invariant to ×0.003"; measurement's g-36 cell costs +2.4 pts
  (≈1.5 s.e., borderline). Different corpora, same conclusion: gain is a
  non-axis and all level conditioning stays dead. Do not relitigate.
- **The noise paradox** (§4.3) is real but is an argument for the honesty
  cue and the locale/engine levers, not for reopening NS.
- **Two consented-recording proposals** (acoustic bake-off, P0-3) must merge
  into one surface (§2.2), and the ephemeral bake-off (§4.1) removes most
  of the first one's retention need.
- **`EvalRunner` locale parameterization** is required independently by
  acoustic §1, the matrix, and §4.1 — one small change, three reports'
  dependencies; sequence it first.

---

## 6. The soul tests

Rules the argument stage can apply to any proposal, distilled from what
survived this pass:

1. **The light never lies** — in any channel. Pill, menu icon, sound, and
   metric must each report only what is true, at the moment it is true
   (D1's inverted feedback and C2's stale-cache provenance are the same sin
   at different layers).
2. **Never rewrite the signal; refuse or inform.** No gain, no suppression,
   no silent second-guessing of inserted text. The app may decline, degrade,
   or warn — it may not editorialize what the user said, in audio or in
   text, without a visible act.
3. **Voice persists only by deliberate act, per clip,** with a visible
   inventory and a working delete. No ambient toggles, no session-scoped
   drift.
4. **Ask, don't infer.** The locale picker over accent detection; consent
   sheets over quiet accumulation. When the answer is stable and personal,
   one honest question beats any classifier.
5. **Optional weight never becomes load-bearing.** The small bundle is
   complete; downloads add, never underpin.
6. **Everything learned is inspectable, dismissible, and forgettable — and
   "forget" must actually reach every store.** A purge button that misses a
   file is a lie with a UI.
7. **New persisted fields meet the ctx house style:** default-off installs
   never grow a byte; status vocabulary, never content.

The four reports are, on the whole, remarkably soul-compatible — the
strongest recommendations in each (A2/A4, B1, C2, D1) are *enforcements* of
the identity, not trades against it. The kills above remove the three places
where convenience leaked in (silent splice, session-scoped voice retention,
purge-immune app logging, implicit clipboard forfeiture), and the missed
opportunities show the identity has headroom left: the most native thing
this app can keep doing is telling the truth slightly more often than any
user expects.
