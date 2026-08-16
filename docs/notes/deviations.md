# Intentional deviations from SPEC.md / INTERFACES.md

The build spec (`docs/SPEC.md`) and module contracts (`docs/INTERFACES.md`)
were written before the code. Where the implementation deliberately diverges —
because empirical measurement or a design principle said so — it is recorded
here rather than silently. Surfaced by the adversarial review pass.

## 1. Spawn-per-utterance, not a pre-warmed long-lived helper
SPEC/INTERFACES describe an `apple_live` process that stays resident and is
`prewarm()`-ed between utterances. **Not implemented** — `AppleLiveEngine`
spawns a fresh helper on each key-down and tears it down on finalize/cancel.
Reason: measured (docs/notes/asr-notes.md) that a pre-warmed idle process gives
first-partial latency of ~1.26 s vs ~1.28 s cold — i.e. prewarming saves ~20 ms
while adding lifecycle, mic, and context-file complexity. The number that
matters, release-to-final, is ~50–180 ms either way. There is no `prewarm()`
method.

## 2. No ~300 ms rolling pre-buffer (deliberate, for privacy)
SPEC build_plan #4 calls for a ring buffer capturing ~300 ms *before* key-down
so the first syllable isn't clipped. **Not implemented**, because an always-on
pre-buffer requires the microphone to stay live between utterances — which
would defeat the headline privacy feature that the mic is hard-off (orange
indicator dark) except while the key is held. We chose privacy over the last
few milliseconds of leading audio; in practice the natural gap between pressing
Fn and speaking, plus SpeechAnalyzer's own pipeline latency, absorbs it. Users
who clip their first word can simply pause a beat after pressing.

## 3. Number normalization not implemented (verbatim-first)
SPEC mvp_features #4 / §4 list spelled-out-number → digit conversion and
phone-number grouping as a Tier-1 rule. **Deliberately omitted** — converting
"one more" → "1 more" is exactly the surprising edit that erodes trust, against
the verbatim-first principle. Deferred to a future opt-in setting. (Neither the
README nor INTERFACES claims it, so only SPEC is ahead of reality here.)

## 4. Custom-vocabulary `--context` biasing is inert
Confirmed empirically (docs/notes/asr-notes.md, docs/research/local-tech.md §4):
the reused helper uses `SpeechTranscriber`, whose `contextualStrings` Apple does
not honor. Vocabulary correctness comes entirely from `postprocess.py`
dictionary substitutions. `--context` is still passed (harmless; future-proof
for a `DictationTranscriber` helper).

## 5. paste_restore_delay_ms default is 500, not 120
INTERFACES originally said 120 ms. Raised to 500 ms after the research pass:
restoring the clipboard before the target app has read the paste is the #1 bug
across competing tools ("it pasted my old clipboard"). settings.py, bootstrap.py,
and README agree on 500; INTERFACES has been corrected.

## 6. On finalize timeout, the last partial is used (not a batch re-transcribe)
`AsrManager.finalize` returns the streaming result — finals plus the last
volatile partial — on a plain timeout, matching the documented fast path. Batch
re-transcription (mlx-whisper → faster-whisper) is reserved for a helper
**crash** (process exited without `{"t":"done"}`) or a genuinely **empty**
result, which is the resilience case the SPEC intended.

## Known limitation (not fixed)
- With `hotkey: "right_option"`, holding the *left* Option key simultaneously
  can mask the right-Option release edge (both set the generic Alternate flag),
  leaving the trigger stuck until another clean right-Option press. Rare
  (requires holding both Option keys); the watchdog + chord-interrupt reset
  paths mitigate the worst stuck states. Fn (the default) is unaffected.

## Native rewrite (2026-08-05)

- **Batch-fallback chain not ported (accepted, temporary).** The Python
  mlx-whisper → faster-whisper fallback is a stub in the native app
  (`WispritEngine/BatchFallback.swift` returns nil; engine values still parse).
  A crash of the in-process SpeechAnalyzer path currently falls back to the
  last partial + history, not to a second engine. The WhisperKit
  large-v3-turbo slot ships with Phase 3 (Background Assets). Until then the
  README must not claim a fallback chain.
- **"Polish Last with Claude" removed by product decision (permanent).**
  User directive 2026-08-05: Apple Intelligence only, zero network calls.
  Replacement is `WispritPolish` (FoundationModels, 4 modes, eval battery).

## Spoken emoji directives — a stage SPEC never described (2026-08-09)

SPEC §postprocessing Tier-1 #4 lists the spoken-form directives as email/URL
joining, number formatting and "new line"/"period". **`WispritPostProcess` now
also ships a spoken-emoji stage** — "fantastic work fire emoji" → "fantastic
work 🔥" — over a closed 33-name table, regex only, no model. It is post-Python:
`postprocess.py` has no equivalent, so this is an addition rather than a
divergence, and the Python-generated `Goldens.swift` / `FuzzGoldens.swift` are
untouched (they remain literal Python output; the new behavior is pinned by the
hand-written `EmojiCommandTests.swift`, the same precedent the `has_letter_run`
era set for native-only behavior).

Three decisions worth recording:

- **The word "emoji" is required.** A bare "fire" never converts. This is what
  keeps the stage inside the verbatim-first philosophy: like "new line", it is
  an explicit spoken directive, not an inference about what the user meant.
- **It runs after self-correction, not inside the voice-command stage** (stage 6
  of 8, immediately after the family it belongs to). The noun-phrase guard treats
  "that" as a determiner and "that" is also the "scratch that" marker, so run any
  earlier, "nope scratch that fire emoji" reads as the noun phrase "that fire
  emoji", is left verbatim, and the user gets the literal words "fire emoji" once
  the marker is stripped. Sequenced after stage 5, self-correction resolves first
  and the directive fires.
- **Guards err toward verbatim, twice.** A determiner / interrogative /
  preposition in front means the user is *talking about* the emoji ("the fire
  emoji", "a heart emoji", "an eyes emoji", "that fire emoji") — untouched. And a
  spelled letter run overlapping the match is skipped, which as a side effect
  means a glued all-caps "THUMBS UP EMOJI" stays verbatim: an all-caps token is
  formally identical to what ITN emits for a dictated spelling, and the stage
  must never eat one. Mixed-case "Thumbs Up Emoji" converts.

Gated by `emoji_commands` (default `true`), the fourth key `PostProcessOptions`
reads and the third native appendix in `Settings.defaults` (append-only, after
`im_selection_policy`).

## Identity expansion — a native-only stage OUTSIDE `processResult` (2026-08-16)

"my email" → the configured address. Post-Python, like the spoken-emoji stage
above, so `Goldens.swift` / `FuzzGoldens.swift` are untouched and the behavior
is pinned by hand-written tables (`IdentityExpansionTests.swift`,
`SessionIdentityTests.swift`) — the same precedent.

Unlike every other text stage it does **not** live inside
`PostProcess.processResult`. It runs in `SessionController` after
`processResult` AND after `expandSnippets`, and both halves of that position
are load-bearing:

- **After the whole pipeline** so the spliced address can no longer be touched
  by `joinEmail`/`joinURL`, by `ensureSentencePeriod`, or by
  `SmartFormat.applyContextFit`'s `lowercaseOpening`. Each non-interaction is a
  test, not an assumption (`SessionIdentityTests`).
- **After snippets** so a user-authored snippet — an explicit unconditional
  rule — wins a trigger collision by consuming the phrase first. Zero
  precedence code, and reordering the two calls silently flips it.

Three decisions worth recording:

- **Whitelist polarity, never a blocklist.** Nothing expands mid-sentence
  without a NAMED licenser (presentative, locative, hand-over verb + strong
  preposition, addressee-directed frame, dangling copula, coordination). A
  blocklist of referring verbs would fail OPEN on every verb nobody thought of;
  this fails closed. The accepted cost is false negatives ("share my email with
  the team"), which cost a re-dictation. A false fire types a real personal
  address into whatever app is frontmost.
- **Hand-over verbs license; deposit verbs do not.** A hand-over verb's
  prepositional object is the CHANNEL by which something reaches a person
  (`send`, `forward`, `email`, `reach`, `cc`); a deposit verb's is a PLACE the
  speaker owns (`post`, `push`, `upload`, `publish`, `add`, `share`, `sign`).
  "I'll post it on my LinkedIn" and "push it to my GitHub" name a place and
  stay verbatim. `find`/`connect` are licensed by the 2nd-person FRAME ("you
  can find me on my GitHub") rather than by lemma membership.
- **An unset slot is INERT — it never emits, not even a stub.** LinkedIn and
  website ship empty. Blank and absent are the same thing at the API boundary
  (`IdentityValues.value`), on disk (`persist` omits empty values), and in the
  UI (blank input clears before the normalizer can run). Nothing the user has
  not explicitly saved can reach a document: the git-config email is a
  suggestion that fills a field's DRAFT, and `IdentityStore.set` is called from
  exactly one place, the field's save action.

Storage is `~/.wisprit/identity.json` (`{"version":1,"identity":{…}}`), its own
file rather than a snippet kind — `SnippetStore.reload()` drops empty
expansions and `persist()` rebuilds each row as exactly {trigger, expansion},
so a `kind` marker would be destroyed by an unrelated snippet edit. Gated by
`identity_expansion` (default `true`), the fourth native appendix in
`Settings.defaults`, and independently inert while every slot is empty.

**The expanded value reaches `history.sqlite`.** `history.add(text:)` records
what was INSERTED, so where the store used to hold "my email" it now holds the
address — a new class of content in an existing store, not a new store. Kept
deliberately (consistent with snippets, and it is what the user actually put in
their document); the Identity section's copy says so.

## Retro-correction (Phase 3)

- **A second `metrics.log` line per utterance, `outcome: "vocab_retro"`.**
  The off-path vocabulary pass finishes 1–2.5 s after insertion, by which time
  the utterance's own row is already on disk and `metrics.log` is append-only —
  so `vocab_ms` / `vocab_hits` / `vocab_delta` / `applied` cannot ride it, and
  attributing them to the *next* utterance's row would be worse than a second
  line. This follows the `outcome: "correction"` precedent (a fourth value
  beyond `paste|type|blocked_secure|error|empty`) and extends it in one way:
  `correction` rows describe an utterance, `vocab_retro` rows do not. They are
  reference-less — nothing but file order ties one to its utterance — and
  `MetricsSummary` therefore drops them before counting anything, or a
  `finalize_ms` of 0.0 would anchor the latency percentiles and every rate in
  `Wisprit stats` would be diluted by roughly the success rate. Pinned by
  `Golden.metricsVocabRetroRow` and `MetricsSummaryTests`.
  Exactly one row is written per completed reconciliation, at the moment
  `applied` is finally known. A plan whose deferred application is dropped
  because the user started speaking again writes its row at the drop, marked
  `apply_detail: "dropped"` — a proposal must never vanish from the stream
  silently. (Amended 2026-08-12: it previously wrote **no** row, which made a
  dropped plan indistinguishable from a pass that never proposed anything.)
- **The `vocab_retro` diagnosis trio (2026-08-12), appended after `applied`:**
  `vocab_refusal` (the planner gate that proposed nothing,
  `VocabularyRetroRefusal.rawValue`), `rung` (the utterance's insertion
  `outcome`, carried onto its retro row so a paste-rung learn-only row stops
  looking like a failure), and `apply_detail` (why a proposed edit did not
  land: `IMEditDetail.rawValue`, or `not_engaged` / `no_reply` when the input
  method was never asked / never answered, or `dropped` as above). Before
  these, every `vocab_retro` row with `applied: false` was indistinguishable
  from every other — a correct refusal, a real apply failure (transcript 318's
  was logged only at os_log info level, which is memory-only, and was lost),
  or a dropped plan. Telemetry only; reconciliation behavior is unchanged.
  Pinned by `Golden.metricsVocabRetroDiagnosedRow`.

## Self-correction beyond the Python markers (2026-08-10)

SPEC §postprocessing Tier-1 #5 scopes self-correction to "explicit markers
only … ambiguous cases pass through verbatim", and `postprocess.py` shipped two
of them: `X no wait Y` and `scratch that`. The engine now lives in
`WispritPostProcess/SelfCorrection.swift` (stage 5 is a one-line caller) and
adds a second tier. The Python-generated `Goldens.swift` / `FuzzGoldens.swift`
are untouched and still literal Python output; the new behavior is pinned by
`SelfCorrectionTests.swift`, the `EmojiCommandTests` precedent.

- **Closed-class pairs are the new tier.** "`<X> <connective> <Y>`" keeps Y only
  when X and Y are members of the SAME closed class — weekday, month, clock
  time, cardinal/ordinal number, relative day. "Thursday umm no actually Friday"
  → "Friday". Requiring both sides to be the same *kind of thing* is what makes
  the weak connectives safe: a bare "actually", "sorry" or "no" is a connective
  inside that sandwich and nowhere else, so "that's actually great" and "I
  actually think Friday works" are untouched. Fillers are tolerated anywhere in
  the joint because the live path runs this on raw partials, before stage 1.
- **Cross-class is a veto, not a fall-through.** "Thursday no actually 3
  o'clock" does not type-check as a correction — you cannot correct a weekday
  into a time — so the joint passes verbatim AND no general marker gets a second
  look at it. The one exemption is "no wait": its replacement span is a
  Python-parity contract, so it still deletes whatever it is handed
  ("Thursday no wait 3 o'clock" → "3 o'clock"). The asymmetry is deliberate and
  pinned by `testLegacyMarkerIsExemptFromTheCrossClassVeto`.
- **Two new general markers, one new guard.** "no actually" and "I mean" reuse
  the Python span exactly (the single word before the marker, the marker, the
  joint whitespace, duplicate function word collapsed). They add a
  discourse-hedge guard the legacy marker does not need: "so I mean we should
  go" and "well no actually that's fine" are conversation, not correction, so a
  function word in front of the marker vetoes the rewrite. Bare "actually" is
  NOT a general marker at any price — tier one covers the safe cases.
- **Unconditional, like the rule it extends.** Self-correction has no settings
  key in Python or here, so the new tier did not get one either: same product
  surface, not a new toggle. The live path below inherits that for the same
  reason — a preview that could disagree with the text it previews is worse
  than no preview.
- **The live path is display-only.** `LivePartialCorrection` runs the engine on
  every partial at the single fan-out in `SessionController.begin`, so the
  correction is already in the pill bubble and the input method's marked text
  while the user is still speaking. It edits nothing else: the session keeps no
  partial state, so finalize still runs the whole pipeline over the RAW final,
  and the corrections stage, the refine prompt, `history` and `metrics`'
  `chars`/`raw_chars` all still read exactly what the engine heard. Partials
  longer than 2 000 characters are shown verbatim rather than scanned on the
  session thread; finalize corrects them a moment later either way.

## Refine prompt revision: spoken self-correction rule (2026-08-10)

The eval-locked refine prompt gained ONE rule (new rule 4; old rules 4–6
renumbered 5–7, none reworded) for the open-ended remainder of spoken
self-correction — arbitrary words under weak cues, the class the deterministic
`SelfCorrection` engine must not guess at. Sanctioned path followed:
`RefineInstructions.text` and `packaging/wisprit_refine.swift` changed
together (PromptLockTests green, all six load-bearing anchors intact), battery
re-run before and after via `Wisprit eval refine --repeat 3` (greedy sampling
makes repeats deterministic).

**Prompt sha changed — scoreboard rows stamp it.** Every scoreboard row
carries `promptSha256` (sha256 of `RefineInstructions.text`); rows recorded
before this revision carry `9f337b6c…`, rows from now on carry `b2a089b5…`.
A battery/WER comparison across that boundary is a comparison across prompts.

**Battery grew 36 → 40 cases** (`self-correction` category): arbitrary-word
correction under a weak cue ("…marketing sorry to finance"), a mid-sentence
restart with no shared prefix, the 2026-08-09 Vivek/Sharique live failure as a
model-level defense-in-depth case (weight 0.5 — the engine resolves it
deterministically downstream), and a MUST-NOT case where "no" is content
("I said no, actually, and I stand by it").

**Measured, 3 repeats per side, all deterministic:**

- 40-case aggregate: 0.9090 (old prompt) → **0.9485** (revised), floor
  0.9722 − 0.06 = 0.9122 passed on both `Wisprit eval refine` and the
  `WISPRIT_REHEARSAL=1` gate.
- Wins: self-correction-restart 0.00 → 1.00, self-correction-restart-name
  0.00 → 1.00. No regression in the original 36 (every core case back at
  1.00 after two counter-example iterations — see the header comments in
  RefineInstructions.swift for the two new measured failure modes found on
  the way: rule 4 without its hesitation counter-example dropped question
  heads, and a cleaned-question example pair made the model answer the
  translate trap).
- Unmoved: self-correction-weak-cue 0.00 → 0.00 (model punctuates the cue
  and keeps both sides; kept at weight 1 as the visible target),
  self-correction-i-mean 0.50 → 0.50, length-five-clauses 0.67 → 0.67 —
  the two previously-flaky cases did not improve; they also did not regress.
- `BASELINE.json` battery band unchanged at accepted 0.972222 ± 0.06: the
  instruction is to raise it only when the measured aggregate rises above it,
  and 0.9485 on the harder 40-case battery does not. The accepted number
  predates the 4 new cases; the next recorded corpus run re-baselines it.

**Engine guard, same day:** `SelfCorrection`'s hedge-leader veto gained the
say-family ("say", "says", "said", "saying") — a general marker directly
after a verb of saying means the "no" was the thing said, so "I said no,
actually, and I stand by it" now passes verbatim (it was being mangled to
"I and I stand by it"). Leader-exact: "I said Bob no actually Alice" still
corrects on "Bob". Pinned in SelfCorrectionTests.

**Re-baselined, same day:** tts-v1 grew sc-07..10 (the live-failure sentence,
the adjacent name swap, a 3-word-prefix clause restart, and the said-no
MUST-NOT control; 50 → 54 clips), and the recorded corpus run re-centered
every moved `BASELINE.json` band on the new measurements — including the raw
WER band (0.174292 → 0.208678, the one out-of-band move: the new clips' false
starts are insertions against their collapsed references, so the raw stage
worsens by construction while final improves) and the battery band promised
above (0.972222 → 0.948465, the 40-case number). Tolerances unchanged. The
TTS voice cannot say the names cleanly ("Vivek" → "vivague", "Sharique" →
"Shariq"), so the spoken shapes carry the natural pause commas that keep the
marker audible; the collapse itself is name-agnostic and fires anyway, and
dict=on recovers "Sharique" from "Shariq".

## Context awareness (Phase 4, 2026-08-10)

SPEC risk #10 ruled any context awareness "out of bounds without explicit
per-feature consent design". That design now exists and is implemented — this
section records it, plus the two schema additions it made.

**The consent contract, enforced in code rather than copy:**

- `context_awareness` defaults to **false** and is flipped on ONLY by the
  consent flow (`AppController.enableContextAwareness`): menu item / Settings
  button → explanatory sheet (`ContextConsent` — what is read, what is never
  read, where it goes) → `Permissions.requestAccessibilityPrompt()` only when
  the AX path needs it → the flag. Every surface routes through the same flow;
  the menu model tests pin that no menu state offers a consent-free toggle to
  on. Switching OFF is always consent-free.
- **What is read:** the text near the cursor in the focused field, captured at
  key-down. Two readers, tried in order: the input method's wire-v2
  `readContext` (bounded by `IMContextWindow` in the protocol itself, zero
  permissions), else `AXContextReader` — at most FOUR AX calls against the
  focused element (focused element → selected range → character count →
  string-for-range over one clamped window), one serial utility queue, depth 1,
  `AXUIElementSetMessagingTimeout` as the budget. Never a tree walk, never
  another window, never a screenshot.
- **Never read:** apps on `ContextPolicy.defaultExcludedBundleIDs` (password
  managers — the user's `context_excluded_bundle_ids` can extend the list but
  never shrink it below the core set), anything while Secure Event Input is
  active, anything while `WISPRIT_NO_CONTEXT=1` (kill switch, mirrors
  `WISPRIT_NO_IM`).
- **Nothing stored:** the snapshot lives in one generation-stamped slot,
  consumed (or discarded) at finalize, superseded at the next key-down. The
  extracted candidates ride one `reconcileVocabulary(_:extraTerms:)` call and
  die with it: `recordUse` ignores unknown terms and the retro learn fallback
  is `isKnownTerm`-gated, so nothing derived from screen text can reach
  dictionary.json. `ContextSnapshot.description` is redacted by design and
  the integration logs statuses only.

**Metrics: three additive utterance-row fields after the whole existing tail**
(`ctx`, `ctx_ms`, `ctx_terms`). Omitted entirely while the feature is off, so
every previously written row remains a byte-prefix of the new schema — the
same rule as every post-Python addition. `ctx` is a closed status vocabulary
(`read|late|busy|off`), never text.

**`skipped_verbatim_app`: a refine outcome beyond the Python thirteen** (the
`has_letter_run` precedent). `context_verbatim_bundle_ids` (default: the live
`terminal_bundle_ids` ∪ a compiled-in IDE list) skips the refine stage — and
its prewarm — outright when the frontmost app is on it. Its own value rather
than a reuse of `off` because every recorded `off` row means "the setting is
off" and has to keep meaning that; the master toggle still outranks the list.
Only ever more verbatim + faster, so it ships independent of the consent flag:
skipping a model pass reads nothing from anyone's screen.

**Settings keys** (`ContextSettings`) follow the `LiveTypingSettings`
string-key precedent — none of `context_awareness`, `context_max_terms`,
`context_excluded_bundle_ids`, `context_verbatim_bundle_ids` enters the
golden-pinned `Settings.defaults`; the config file preserves them as unknown
keys across builds.

## Edit capture (Phase 5, 2026-08-10)

- **A third non-utterance `metrics.log` line, `outcome: "edit_observed"`** —
  the `vocab_retro` precedent, one phase later. An edit can only be counted
  when the pipeline finally sees what became of text it inserted, which is one
  utterance (IM key-down read), a session close, or the next utterance's
  context snapshot later — long after the utterance's own row was on disk in
  an append-only stream. The line is reference-less by construction (nothing
  but file order ties it to its utterance) and carries exactly two fields
  after the frozen tail: `edit_dist` (character Levenshtein of our committed
  text vs the field now; **0 is the zero-edit observation; omitted entirely**
  when the input method reported `.changed` without text — an edit whose size
  is unknowable joins the denominator and never the numerator) and
  `edit_scope` (`"im"` for the wire-v2 `committedSnapshot`, `"ax"` for the
  next-utterance context-window diff — the evidence ranking is recorded in
  `docs/eval/DEFINITIONS.md`). `engine` is the empty string: no engine
  produced this line, and `edit_scope` names the reader.
  `MetricsSummary.nonUtteranceOutcomes` drops it from every utterance stat and
  counts the zero-edit pair from it BEFORE that filter; pinned by
  `Golden.metricsEditObservedRow` and `MetricsSummaryTests`. An utterance
  nobody observed writes **no** line — never a guessed one — which is the
  whole observable-denominator rule.
- **The wire contract is wider than today's input method.** The app consumes
  `.changed` snapshots that carry `current` text (diffing them through
  `EditObservationGate` into learn proposals), but the shipping
  `IMStreamSession.readCommitted` deliberately sends `.changed` with no text —
  "which edit" would be a guess, and that refusal is pinned in
  `ReadBackTests`. Today, therefore, the IM rung produces zero-edit and
  changed-of-unknown-size observations only; single-token proposals flow from
  the AX scope. A future IM-side anchored relocation can populate `current`
  and light the IM proposal path up with **zero app changes** — the fake peer
  in `SessionEditCaptureTests` already exercises that shape end to end.
- **Propose-first, and the threshold lives in one place.** Accepted proposals
  are only ever *recorded* (`PendingLearnStore`); at ≥2 distinct-utterance
  observations the user sees `transientNotice("New word: <term> — review in
  Dictionary")` plus the Dictionary page's proposals banner and nav-row badge
  — Accept performs `DictionaryStore.add` + `promoteConsumed`, Dismiss is
  forever. `learn_auto_accept` (string-key precedent, default false) turns the
  threshold event into the same silent add the Accept button makes.

## Paste-rung metric correction — a DISCONTINUITY in metrics.log (R6, 2026-08-10)

**What changed.** `Inserter.pasteViaClipboard` posts ⌘V — at which instant the
text is visible in the user's document — and then sleeps
`paste_restore_delay_ms` (500 ms) before restoring the clipboard. Until this
change, `release_to_text_ms` and `insert_ms` were stamped after that sleep, and
the success flash fired after it too: the metric billed the custody window as
latency, and the pill confirmed the paste half a second after the user could
see it (the feedback inversion, native-feel §1 — ~250 rows of the live log).
Now the delivery instant is captured at `postCommandV` (`InsertResult.
deliveredAtMonotonic`), the flash and commit cue fire from inside the delivery
hook BEFORE the sleep, and the sleep + restore stay on the session thread after
the flash — ordering and safety semantics unchanged, including the 500 ms floor
and the changeCount check.

**The honest reading of the numbers.** Live paste `release_to_text_ms` p50
drops from ~770 ms to ~270 ms at this boundary **because the metric was
overstating, not because anything got faster**. This is a METRIC CORRECTION,
not a speedup, and no comparison of `release_to_text_ms` (or `insert_ms`, which
now also stops at delivery) may straddle rows written before and after this
build without saying so. RESULTS.md must carry the same annotation wherever the
paste-rung number is quoted (handed to Track A; the discontinuity is
append-only history — old rows are not rewritten).

**Two additive fields** (append-only tail, after every existing key):

- `restore_ms` — delivery → `insert()` return: the sleep plus the clipboard
  restore, on paste rows only. What used to be silently inside the headline
  number now has its own honest column.
- `repress_queued` — `true` when a press was already queued at the moment the
  restore window closed (omitted otherwise). This is the free counter from the
  R34 ruling (§1.1-T5): **skip-clipboard-restore on fast re-press is REJECTED**
  — the user's clipboard is never traded on an implicit signal — and this
  one-line counter is the only thing that could ever justify revisiting it. If
  it fires more than ~weekly, the sanctioned revival shape is *deferred
  restore* (restore after the next utterance), which keeps the property
  guarantee; the skip stays dead either way.

## Telemetry completion + sound cues + onboarding row (R4/R11/R14, 2026-08-10)

- **`noise_floor` + `first_voiced_ms`** join `peak_level`/`audio_ms` on every
  utterance row (additive tail). `noise_floor` is the quietest ~300 ms window
  on the meter's own scale (RMS×4 clamped, same statistic family as
  `peak_level`, so the pair reads as an SNR proxy); `first_voiced_ms` is
  mic-live → first chunk clearing the voiced threshold, the clipping-exposure
  clock — its p5 owns the verdict on whether cold-start head-loss (closed by
  the R7 replay, `AsrManager.begin`) was ever real exposure. Computed in
  `MicCapture`, threaded through `AudioPort`, omitted when unmeasured.
- **A fourth non-utterance `metrics.log` outcome, `"onboarding"` (R14).** One
  reference-less time-to-wow row per fresh install — first launch → first
  successful dictation, steps skipped, relaunch count (`onboard_ms`,
  `steps_skipped`, `relaunches`) — written through
  `MetricsWriter.writeOnboarding`, the entry point Track D's onboarding model
  calls. `MetricsSummary.nonUtteranceOutcomes` drops it like `vocab_retro` /
  `edit_observed`, or its `finalize_ms: 0` would anchor the latency
  percentiles.
- **Sound cues ship default-OFF (R11), the A-6 gate recorded.** Two synthesized
  cues ≤ 100 ms at ≤ −20 dBFS (mic-open on show-recording, only after
  `audio.start()` succeeded; commit at the delivery instant; no error sounds by
  design), behind a string-keyed `sounds` toggle (`SoundCueSettings`, the
  `LiveTypingSettings` precedent — never enters the golden defaults). The
  plan's intended default is `pill_hidden`-keyed (on exactly when the pill is
  hidden and the cues are the only feedback channel), but that flip is GATED on
  the A-6 cue-bleed eval check — zero transcript delta with the cue PCM mixed
  into matrix clip heads — which has not run; until it passes the fallback is
  `false`, pinned by `SoundCueTests`. The assets are synthesized
  (`SoundCueSynth`, deterministic 16 kHz mono Int16 — the pipeline format, so
  A-6 can mix `samples(for:)` directly) rather than bundled: `Package.swift`
  is orchestrator-owned and declares no resources for the target, and a
  bundled asset would need one.

## Parakeet vocabulary channel (Phase 6, 2026-08-10)

Fork (b) of the B-0 spike verdict (docs/research/spikes-parakeet.md), complete
inside `Sources/WispritParakeet/` and **deliberately not linked into
WispritMac** until the human-corpus gate: the transitive binary xcframework
(`NemoTextProcessing.xcframework` via FluidAudio) must not ride every install
for an opt-in feature whose ship decision is scoreboard-gated.

- **Evidence only, structurally.** `ParakeetDecodeOutput` carries the raw TDT
  transcript plus `ParakeetSpotEvidence` (scores, alias, UTF-8 byte range) and
  has NO rescored-text field — "never take the rescorer's rewrite" (23–50
  measured false replacements) cannot regress by accident.
  `ParakeetVocabularyChannel.substituted` splices ONLY applied,
  comparison-passed, byte-aligned candidates whose canonical term was actually
  requested; everything else is the TDT transcript byte-for-byte. The
  downstream FP filter is `VocabularyReconciler`'s gates, unchanged.
- **Model store is the ONE network file.** `ParakeetModelStore.swift` is
  allowlisted in `NetworkInvariantTests` (tokens `URLSession`, `https://`);
  download is explicit-user-invoked, `WISPRIT_NO_NETWORK=1` hard-refuses, and
  every byte is verified against the 33-file SHA-256 manifest in
  `ParakeetManifest`. The manifest is the pin — URLs use `resolve/main`
  because HF model repos re-push and prune history, and a moved ref simply
  fails verification closed. Hashes were recorded from the spike's validated
  caches on this machine.
- **The silent-download hole is double-locked.** `AsrModels.load` routes files
  through ModelHub, which fetches anything missing; `ParakeetLiveDecoder`
  (1) requires `ParakeetModelStore.state() == .verified` before any FluidAudio
  call and (2) sets `ModelHub.offlineMode = true`, FluidAudio's own refusal.
  CTC assets load via `CtcModels.loadDirect` + `CtcTokenizer.load(from:)`
  (never `loadWithCtcTokens`, which hardcodes the Application Support cache);
  terms are CTC-tokenized by hand into `ctcTokenIds`.
  `spotterRescueEnabled: false` per the vendor's own #702/#724 guidance.
- **Doctor row without linking.** WispritMac reports "Parakeet models: not
  downloaded (optional)" / partial (warn) / verified from PATH ONLY:
  `~/.wisprit/models/parakeet` + its `verified.json` marker
  (`Doctor.parakeetModelsState` in DoctorProbes.swift mirrors the convention
  documented on `ParakeetManifest`; drift is pinned on both sides by tests).
- **Adoption recipe** (also in the `ParakeetVocabularyChannel.swift` header):
  one Package.swift line adding `"WispritParakeet"` to WispritMac's
  dependencies (orchestrator-owned), then a factory registration that builds
  `ParakeetVocabularyChannel(decoder: ParakeetLiveDecoder(modelsDir:
  ParakeetModelStore.productionModelsDir), terms: dictionary terms +
  heardPhrases)`, calls `warmup()` off-path at app start, and maps
  `ParakeetReconciliation` → `VocabularyReconciliation` field-for-field in the
  `AsrPort` adapter (`ParakeetReconciling` mirrors the reconcile surface for
  exactly this).
- **Live integration test** (`WISPRIT_PARAKEET_LIVE=1`-gated, skips cleanly)
  runs the real models via the spike's read-only caches symlinked into a temp
  models dir. Measured on this machine: real-manifest `state()` = verified,
  warmup 506 ms warm, reconcile 348 ms on pn-01, alias hit "whisper"/"whisper
  it" → `Wisprit` recovered — the spike's numbers reproduced through the
  shipping code path.

## Refine content-loss guard (2026-08-14)

**`dropped_content`: a refine outcome beyond the Python thirteen** (the
`has_letter_run` / `obeyed` / `skipped_verbatim_app` precedent). Measured on
200 LibriSpeech test-clean clips through the real pipeline: raw ASR WER 2.68%,
**refined** WER 3.59% — the cleanup stage made real speech 34% relatively
worse. The word-count band could not see it because its floor is a RATIO
(0.4×), so the slack grows with the utterance: the worst clip
(ls-5142-33396-0052) lost a ten-word trailing clause ("…and a sword would not
be ashamed to hang at your side." → "…and a sword.") and was still `applied`.

- **The discriminator is measured, not guessed.** Over 254 refine outputs on
  two corpora (LibriSpeech real speech + the tts-samantha battery corpus),
  unique content-word loss never exceeded 2 for a legitimate cleanup — filler
  removal, stutter collapse, ITN — *unless* the input carried a spoken
  self-correction; every damaging output scored 3, 3, 3 or 9. Threshold: 3.
- **Loss counts a multiset difference over non-stop words**, with a 4-character
  stem tolerance so inflection fixes and ITN rewrites ("founded"/"found",
  "eleven percent"/"11%") are not losses. The stop set is `leadFillers` plus
  the closed-class function words and greeting interjections; every word added
  to it makes the guard MORE permissive, which is the safe direction — this
  detector's only job is a multi-content-word clause drop.
- **Prompt rule 4 is exempt.** A cued self-correction ("no / no actually /
  sorry / I mean / rather / scratch that / make that / I said / actually")
  legitimately deletes three or more content words, so a cue anywhere in the
  INPUT suppresses the guard outright. The cue is read from the input only —
  the model may not license its own deletion.
- **Ordering:** last in the accept chain, after `plausible` and both obedience
  detectors. An executed instruction also loses content words, and `obeyed` is
  what every recorded row called it; `dropped_content` reports the failure
  nothing else names.
- **Polish shares it for `.cleanUp` only** (that mode already delegates to
  `RefineGuards.plausible`; WispritPolish depends on WispritRefine). The tone
  modes are *supposed* to replace content words wholesale, so their bands stay
  the guard.

## Backtrack + Smart Formatting (2026-08-14)

Wispr Flow's cleanup layer is a cloud LLM. Wisprit keeps the deterministic
path as the source of truth and extends it so the same spoken shapes resolve
without waiting on Apple Intelligence — and still resolve when refine is off,
skipped, or implausible.

- **Compatible closed classes.** A bare number may correct a clock time
  ("at 5 actually 6 pm" → "at 6 pm") and a weekday may correct a relative day
  ("Friday actually tomorrow" → "tomorrow"). Weekday ↔ clock stays a veto.
- **Parallel prepositional restatement.** "send it to marketing sorry to
  finance" → "send it to finance". The repeated preposition is the evidence
  that makes "sorry" / "actually" safe on arbitrary nouns.
- **Same-frame restatement** requires a pause ("as a gift, as a present") so
  two roles listed without hesitation ("as a child as a parent") stay
  verbatim.
- **New markers:** "I meant", "wait no"; retract-all "forget that" / "never
  mind" (utterance-initial idiom readings stay verbatim).
- **Sandwich-only connectives:** "wait" and "instead" fire only on
  closed-class pairs ("Thursday wait Friday", "three instead five").
- **Past-day restatement:** "yesterday" + pause + today/tonight/tomorrow
  (or the reverse) keeps the later day when the survivor ends the
  utterance or a prepositional tail. "today, tomorrow and Friday" and
  "yesterday, tomorrow I'll fly" stay verbatim.
- **Smart Formatting** (mid-utterance punctuation, numbered lists from
  sequence+verb, "next line" / "press enter", messaging trailing-period,
  context-aware mid-sentence casing, Flow punctuation names including
  tilde / degree / trademark) is gated by `smartFormatting`, default
  **OFF** in `PostProcessOptions()` so the Python goldens / fuzz stay a
  differential net. The app opts in. Self-correction is still unconditional.
  Spoken punctuation runs after emoji so "star emoji" stays a glyph.
- **Snippets** live in `~/.wisprit/snippets.json` (`SnippetStore`), expanded
  after postprocess on the session path. Dictionary page edits them.
- **Release grace:** the app keeps the mic open 120 ms after key-up so the
  in-flight tap buffer is not clipped. Tests leave the grace at 0.
- **"Not X Y" restatement.** Same-utterance "the pet itself not a pet
  pill" → "the pill itself". A follow-up that is only the cue
  ("not a pet pill") retro-edits the earlier word when live typing
  still owns the run. Function-word "not" ("I did not go") and
  "X or not X" ("writing or not writing any code") stay.
- **Empty pill is a miss, not an alarm.** Silence / produced-nothing /
  a short hold flash `missed` (studio body, muted ink, flattened dots,
  no warning glyph). Starved / timeout / crash still alarm.
- **Persistent Flow bar.** The pill stays on the desktop as a compact
  idle capsule (48 pt, five cream dots) and expands while you talk.
  Success / miss / notice settle back to idle instead of hiding.
  `pill_hidden` still removes it.
- **Quiet speech.** `voicedPeakThreshold` and the dead-mic floor sit at
  0.01 / 0.005 so a quiet speaker is not classified as silence and does
  not get a "no audio" nag while they are still talking.
- **Term echo.** A distinctive term already in the utterance
  (HackerRank, InsForge) snaps a later ASR split of itself
  ("had the rank", "inns forge") back to that spelling. "had the
  rank of …" stays verbatim.
- **Verb-form restatement.** "it was given, giving me" → "it was
  giving me". Needs a be-auxiliary, a pause, and an -ed/-en vs
  -ing pair that share a stem. "the driver, driving" and "we
  shipped, shipping tomorrow" stay.
- **Software-compound twin.** "function for holdback" → "function
  for rollback" when the utterance is already about a
  function/method or a HackerRank-style test. A financial
  holdback stays.
- **Release grace, R33 shape.** The 120 ms is now `keyup_grace_ms`
  (`KeyupGraceSettings`, one definition; the app reads it at wiring time)
  and is spent in ≤20 ms slices instead of one sleep: Esc aborts INSIDE the
  grace (faster than the old Esc-during-finalize path — the utterance never
  reaches the analyzer), a queued press cuts it short, and anything over
  500 ms is clamped. `pill.showFinalizing()` now fires AFTER the grace, so
  the pill never claims to be finalizing while the mic is still hot.
- **Converter tail.** `PcmDownconverter.flush()` drains the resampler's
  end-of-stream tail (240 frames at 48 kHz, 120 at 44.1 kHz — the delta
  `PcmFormatTests` already pinned as missing) and `MicCapture.stop()`
  delivers it as a final chunk. Skipped when the session delivered zero
  bytes, so the wedged-mic "delivered no audio" log survives. The
  converter is terminal after a flush.
- **Microphone prestart (R33).** The mic opens on the hotkey tap's own
  queue at KEY-DOWN, not in `SessionController.begin()`: a press queued
  behind a busy pipeline used to lose 0.7–1.5 s of speech (worst case the
  batch-rescue budget). `AsrManager.armCapture()` gates it — it refuses
  while an utterance is still recording, so the mic is never started
  un-armed — and `startUtterance()` now PRESERVES an armed retention
  buffer so the existing head replay splices the pre-roll into the new
  engine. Key-up stops a prestarted mic (`isRecordingUtterance` false), so
  "mic live only while the key is held" still holds for the queued press.
  `MicCapture.start()` is idempotent; `start`/`stop` are serialized.
- **Clipboard custody is asynchronous (R33; revokes an R6 pin).** The
  500 ms restore window moved off the session thread onto a static serial
  custody queue shared by every `Inserter`, with a barrier before the next
  snapshot and a required drain at quit. Consequences: `insert()`'s paste
  detail is now `restore scheduled` (the restored / failed / changed-
  externally strings became log lines), `restore_ms` collapses to ~0 while
  the field stays, and `repress_queued` — sampled at delivery — is now
  near-constant false. `InserterTests`' synchronous-restore assertions
  ("the restore semantics are unchanged") were rewritten around a gated
  drain; the ordering they pinned is now guaranteed by the queue.
- **Mid-utterance device switch is visible (2026-08-05, finally).**
  `MicCapture` reports the reconfiguration to `AsrManager`, which stamps
  `UtteranceResult.sawConfigurationChange` on the value `finalize()`
  returns (both the streaming and batch-only paths). It adds one rescue
  trigger — clean AND non-empty, i.e. a silent truncation; bare
  `configurationChanged` would batch-transcribe a silent hold and break
  the b0a763f rule — a `device_changed` empty-reason (after `starved`,
  before the level clause), a `config_changed` metrics field (appended
  last, omitted when nil), and a post-delivery pill notice on the
  NON-empty case, which is the one the rescue cannot fix: the post-switch
  audio was never captured.
- **Input device policy.** `input_device_policy` = `warn` (default) |
  `prefer_builtin` | `off`. Narrowband = classic Bluetooth under 32 kHz
  (HFP/SCO: CVSD 8 k, mSBC 16 k, the incident's 24 k); Bluetooth LE is
  deliberately exempt. `warn` shows one pill notice per device appearance,
  AFTER `showRecording()` (from `.prewarming` the pill would flash success
  and then wipe the bubble). `prefer_builtin` pins the AUHAL to the
  built-in input, best-effort, and only while the default input is
  narrowband classic-BT. `wisprit doctor` gains a warn-only input row.
