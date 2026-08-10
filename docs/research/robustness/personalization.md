# Personalization & "training": what can genuinely learn this user's voice, vocabulary, and style on-device

Topic 2 of the robustness research pass, 2026-08-10. Method: full read of the
flywheel code (`WispritDictionary`, `WispritCorrections`, `WispritContext`,
`WispritPersistence`, `WispritRefine`, `WispritParakeet`, the session wiring in
`WispritMac/SessionController.swift`), the eval discipline
(`docs/eval/DEFINITIONS.md`, `RESULTS.md`), the recorded probe results
(`docs/research/apps-feasibility.md`, `spikes-s1.md`, `spikes-parakeet.md`,
`docs/notes/asr-notes.md`), plus external verification of the FoundationModels
adapter story and Apple's speech-personalization surface (sources at the end).

**The one-paragraph verdict.** Nothing on this platform trains an acoustic
model on this user's voice, and nothing will — that entire branch is killed
below, explicitly, mechanism by mechanism. What *can* genuinely learn is the
text layer: the flywheel already captures per-utterance evidence
(`utterance_detail` triples, `PendingLearnStore`, `edit_observed` /
`vocab_retro` metrics rows) that today feeds three built channels (dictionary
regex, `DictationTranscriber` `contextualStrings`, Parakeet CTC term boosting)
— and the highest-value unexploited moves are *statistical*, not neural:
mining the stored triples for recurring per-user misrecognitions to
auto-generate `hear` phrases, and frequency-weighting the biasing lists the
channels already consume. Both have replay-testable predictions on data
already on disk. The glamorous options — FoundationModels LoRA adapters,
refine-prompt few-shot from the user's corrections — are assessed honestly:
one is a treadmill Apple's own docs warn about, the other targets a mechanism
this repo already **measured to be ignored** by the ~3B model.

---

## 1. What the flywheel already captures (data inventory)

Every recommendation below feeds on data that already exists. Exact shapes:

| store | contents | where |
|---|---|---|
| `utterance_detail` (SQLite, joined to `transcripts`) | per-utterance pipeline triple: `raw` (verbatim ASR), `corrected` (+ spoken-spelling corrections), `refined` (+ AI cage), `inserted` (what the user saw), `vocab` (off-path pass outcome), `ai` (refine outcome), `terms_hit` | `WispritPersistence/History.swift:33–68` |
| `PendingLearnStore` (`~/.wisprit/learn_pending.json`) | edit-derived candidates: `{term, observations:[{heard, at}], status}`; ≥2 distinct-utterance threshold; permanent dismissals; 30-day evidence expiry, 200-entry cap | `WispritDictionary/PendingLearnStore.swift` |
| `DictionaryStore` (`~/.wisprit/dictionary.json`) | `{term, hear:[], hit_count, last_used, learned_at, source, pending, observations}` — note **`hit_count × recency` ranking already implemented** for consumers that cap | `WispritDictionary/DictionaryStore.swift:9–14` |
| `metrics.log` | per-utterance rows plus three reference-less row types: `vocab_retro` (`vocab_ms/hits/delta/applied`), `edit_observed` (`edit_dist`, `edit_scope: im\|ax`), `correction` | `docs/notes/deviations.md` §Retro-correction, §Edit capture |
| retained PCM | **transient only** — lives long enough for the off-path vocabulary pass, never persisted. Audio retention is off by design (the headline privacy feature) | `RetainedUtterance`, SPEC §privacy |

Two structural facts that shape everything:

1. **The flywheel is text-only.** No audio survives an utterance. Any
   personalization requiring (audio, reference) pairs — acoustic adaptation,
   ASR fine-tuning, per-user WER measurement on real usage — is impossible
   without a new, explicitly consented, default-off retention setting.
2. **Every learn path is propose-first and evidence-gated** (≥2 distinct
   utterances, phonetic ≥0.70, `CandidateExtractor` shape rules, permanent
   dismissals). The junk-term audit that motivated this (three garbage terms,
   each seen exactly once — `LearnPlausibility.swift:5–13`) is the design
   precedent every new miner below must inherit.

## 2. Already built — what the data feeds today

- **Dictionary growth**: spoken-spelling learn loop (merge / quarantine /
  reject via `LearnPlausibility`), vocab-retro learn fallback
  (`SessionController.swift:852`, `source: "vocab_retro"`), edit capture →
  `EditObservationGate` → `PendingLearnStore` → Accept/Dismiss UX, optional
  `learn_auto_accept`.
- **`contextualStrings` biasing**: the off-path `VocabularyChannel`
  (`DictationTranscriber` — the only Apple engine that honors it; A/B-verified
  "Hi Cherie" → "Hi Sharique", `apps-feasibility.md` §findings) feeding
  `VocabularyReconciler`'s eleven refusal gates → bounded retro-edits.
- **Parakeet term boosting** (built, gated behind the human-corpus
  scoreboard): `hear` phrases map 1:1 to `CustomVocabularyTerm(text:aliases:)`;
  the spike measured 14/18 term slots recovered vs 8/18 for the recorded
  dict-on pipeline, with the alias field doing the real work ("whisper it" →
  `Wisprit` at similarity 1.0) — `spikes-parakeet.md` §Q2.

The load-bearing observation: **all three channels are fed by the same
`{term, hear:[]}` schema.** Anything that improves the hear-set improves the
regex net, the DT biasing list, and the Parakeet alias list simultaneously.
That is why hear-phrase mining ranks first below.

---

## 3. Ranked recommendations

Ranking axis, per the brief: (measurable prediction, privacy cost,
engineering cost). P0 = do it; the further down, the weaker the case.

### P0-1. Mine the stored triples for per-user misrecognition statistics → auto-generated hear phrases

**Mechanism.** A batch job (off-path, e.g. at app idle or on the Insights
page's schedule) walks `utterance_detail` rows: align `raw` against
`corrected`/`inserted` with the *existing* LCS machinery
(`EditObservationGate.longestCommonSubsequence`,
`VocabularyReconciler`'s block logic — no new algorithms). For each mismatch
block whose resolved side is a known dictionary term, the raw side is a
**candidate hear phrase for that term**. Route candidates through the same
ledger discipline as edit capture: recorded in `PendingLearnStore` (or a
sibling ledger keyed `(term, heard)`), promoted to the term's `hear[]` only at
≥2 distinct-utterance observations, dismissals permanent, never for a term the
user dismissed. Two sub-cases:

- *Already-caught misrecognitions* (the regex fixed it): no action — the hear
  phrase exists. But **count them**: `{term, heard, count, last_seen}` is the
  per-user misrecognition statistic nothing currently aggregates, and it is
  the input to P0-2's weighting.
- *Not-caught misrecognitions* (recovered by the vocab channel, retro pass,
  or the user's own edit, visible as raw→inserted diffs anchored on a term):
  these are exactly the hear phrases the dictionary is missing.

**Why this is safe by construction.** It only ever *adds hear evidence to
terms the user already approved* — it can never mint a canonical term, so the
biasing-pollution failure mode (`LearnPlausibility`'s SHARHUUE bill) is
structurally excluded. The phonetic floor (≥0.62, same scorer) still applies
to keep "different word choice" out of `hear[]`.

**Measurable prediction (replay-based — needs no new recording).** Take the
user's own history DB; split triples chronologically; mine hear phrases from
the first half; replay the second half's `raw` strings through
`DictionaryStore.applyCorrections` with hear-set v1 vs v2. Prediction: v2
converts a strictly larger share of the recurring misrecognition classes of
known terms, with zero new false substitutions on utterances containing no
term (the whole-word regex + phonetic gate make FPs near-impossible to
construct). Offline, the same enriched dictionary is a `dict=on` eval run:
term recall on human-v1 should rise on exactly the proper-noun/tech-jargon
categories, WER elsewhere unchanged. If the replay shows < a handful of new
catches per hundred utterances, the feature did not earn its complexity —
that is the kill criterion, and it is cheap to evaluate *before* building the
promotion UX.

**Privacy cost: zero new.** Reads data already on disk, writes to files the
user already owns and can already purge. Nothing leaves the machine.

**Engineering cost: low-medium.** The alignment, scoring, ledger, and UX all
exist; this is a batch orchestrator plus tests (est. small: one module + one
golden-pinned test file). The one real design question is where the
statistic lives (a third ledger file vs. additive keys on dictionary
entries — the additive-key precedent favors the latter for counts, a ledger
for candidates).

### P0-2. Frequency-weighted biasing: spend the term-list budget where this user's usage is

**Mechanism.** `hit_count × recency` ranking is already computed
(`DictionaryStore.swift:13–14`) — nothing consumes it meaningfully yet
because the S1 verdict was "ship the whole dictionary, no 50-term cap." That
verdict has an expiry date: it was measured at ~138 terms. Two consumers now
have *measured* reasons to curate:

- **Parakeet channel**: FluidAudio auto-tightens `minSimilarity` 0.50 → 0.60
  (corrected: the spike records 0.50, not 0.55 — `spikes-parakeet.md:117`)
  above 100 terms, and the 138-term spike run produced 41 false replacements,
  "mostly junk-alias collisions from the live dictionary ('better' → `Letta`,
  'email' → `RamAIn`)" (`spikes-parakeet.md` §Q2). Feeding the top-N terms by
  hit_count×recency (plus every term seen in the current context snapshot)
  keeps the vocabulary under the tightening threshold and drops the aliases
  that never fire for this user.
- **DT `contextualStrings`**: ~3.1 ms/term session setup
  (`VocabularyChannel.swift:30`) — fine at 138, not at 1,000. A growing
  auto-learned dictionary needs the ranking as its pressure valve.

Additionally: P0-1's per-`(term, heard)` counts allow **hear-phrase
pruning** — an alias that has produced 0 hits and ≥1 false replacement in the
evidence stream is a deletion candidate (propose-first, like everything).

**Measurable prediction.** Re-run the spike harness (`run.sh` exists,
re-runnable) with live-dictionary top-100-by-weight vs all-138: prediction is
equal or better recall on terms the user actually uses, strictly fewer FPs,
and offline the reconciler's refusal-rate mix shifts (fewer
`notADictionaryTerm` blocks entering). On the DT side: session setup time
scales down linearly with the cap, measurable in `vocab_ms`.

**Privacy cost: zero.** **Engineering cost: low** — the ranking exists; this
is plumbing a cap parameter that already exists (`AsrEngine.swift:98`) plus
the Parakeet term-list builder.

### P0-3. Per-user eval: an opt-in retained-clip corpus (the measurement enabler)

**Mechanism.** The brief's goal is "any accent, any volume, any tone" — for
*this user*. Nothing in the pipeline can currently measure any per-user
number on real audio because audio is never retained. The eval harness
already has everything else: `Wisprit eval record` with speaker splits,
`corpusSource: human` provenance, category scripts
(`tools/eval/scripts/human-v1/`). Add a default-off, explicitly consented
"contribute this clip to my private eval set" action (per-utterance or
per-session, stored under `~/.wisprit/`, purgeable, never transmitted —
consistent with the Phase-4 consent-sheet precedent). References come free:
the *user's own final edit* (observed via the existing edit-capture rungs) is
the reference candidate, human-verified via the existing
`Wisprit eval verify` flow.

**Why it ranks this high despite doing nothing by itself:** every other item
in this report — and most of the other robustness topics — currently
predicts against TTS numbers that the repo itself bans from accuracy claims.
A 50-clip personal corpus turns "personalization works" from an argument
into a scoreboard row. It is the difference between shipping P0-1/P0-2 on
faith and shipping them with a per-user WER/term-recall delta.

**Measurable prediction:** not applicable — this *is* the measurement.
**Privacy cost: real but consented and local** (audio on disk, user-owned;
the first feature that stores voice — it must be as loudly opt-in as context
awareness). **Engineering cost: low-medium** (consent sheet + storage +
`eval record` integration; the harness exists).

### P1-4. Deterministic per-user style rules from edit observations (the honest "learning your style")

**Mechanism.** Wispr's "learning from edits → preference policies" reduces,
for a single user, to a small set of *recurring deterministic edits*: the
user always writes "e-mail" as "email", always lowercases "internet", always
strips the terminal period in chat apps (the `.light` profile already treats
that one as taste). The `edit_observed` stream + triple diffs can mine
recurring identical single-token or punctuation-class edits exactly like
P0-1 mines misrecognitions — same ledgers, same ≥N distinct-utterance
threshold (style likely wants ≥3), same propose-first UX ("Always write
X as Y? — applies as a dictionary-style rule"). Accepted rules join the
deterministic post-process, not the model.

**Honest limits, named:** today's IM rung deliberately reports `.changed`
without text (`ReadBackTests` pins the refusal), so single-token style
evidence flows only from the AX scope, which requires context consent and
yields sparse observations. This item's data supply is thin until the
IM-side anchored relocation lands (the wire contract already allows it,
`deviations.md` §Edit capture). Rank it P1 on supply, not on mechanism.

**Measurable prediction:** live zero-edit rate over *observed* utterances
(`MetricsSummary.zeroEditRate`, denominator rules already defined) rises for
the app/rule classes learned; each accepted rule's hit count is loggable per
utterance. Offline: none (style is per-user by definition; the shared corpus
cannot see it) — which is why the prediction must be the live observed-rate
one, stated in advance per rule class.

**Privacy: zero new** (rides existing consented readers).
**Engineering: medium** (a rule-class taxonomy — substitution, casing,
terminal-punctuation — must be designed conservatively; arbitrary learned
regexes are how a dictation app starts surprising its user).

### P1-5. Per-app vocabulary profiles

**Mechanism.** The pipeline already reads the frontmost bundle ID for the
insertion ladder and the verbatim-app skip; the triples do not record it.
One additive field (`app` bundle-ID string on `utterance_detail`, additive
metrics key — the append-only schema precedent) enables: per-app
`hit_count` shading of P0-2's ranking (the Xcode vocabulary is not the Mail
vocabulary), and per-app Parakeet term subsets. Bundle ID only — a name, not
content — consistent with the SPEC's standing context rule.

**Measurable prediction:** weak offline (the corpus has no app dimension);
live, per-app term recall via `terms_hit`-by-app before/after. **Privacy:
near-zero but nonzero** — the triples become a partial app-usage log; the
history purge already covers it, but the panel should note Wispr's 1,688
app-tracking events made exactly this class of data a scandal; the field
must ship documented and inside the existing purge. **Engineering: low.**
Ranked below the P0s because its prediction is the weakest of the
statistical items and it inherits a real (if small) privacy narrative cost.

### P2-6. The refine prompt as a personalization surface: bounded few-shot from the user's accepted corrections

**Assessed honestly, mostly negative.** The idea: append ≤5 exemplar pairs
(raw → user-approved final, drawn from accepted `PendingLearnStore`
proposals and dictionary hear evidence) to `RefineInstructions`, per user,
bounded to ~300–400 tokens.

- **Budget feasibility: yes.** Instructions ≈ 500 tokens, transcript ≤350
  words (`RefineConfiguration.maxWords`), response cap 2,800
  (`RefinePrompt.maximumResponseTokens`) inside the 4,096 shared context —
  a 400-token exemplar block fits with headroom at the default `maxWords`.
- **Eval-lock feasibility: solvable but real work.** `promptSha256` is
  provenance on every eval row; a per-user prompt breaks row comparability.
  The fix is mechanical — stamp `promptTemplateSha256` + `exemplarSetHash`
  separately, and extend `RehearsalTests` to run the battery with a
  representative synthetic exemplar block injected — but it is a permanent
  tax on the eval discipline: every battery run doubles (with/without
  exemplars), per OS point release.
- **The evidence is against the payoff.** This repo already measured the
  ~3B model **ignoring hinted personal vocabulary** ("dictionary corrections
  (personal vocabulary the ~3B model provably ignores when hinted —
  measured)", `Refiner.swift:9–10`), and FoundationModels-as-detector was
  measured "wrong 3–4/10, never joined letters correctly"
  (`apps-feasibility.md`). Vocabulary few-shot is also *redundant by
  pipeline order*: the deterministic dictionary pass runs after refine and
  already wins every case a vocabulary exemplar could win. What remains is
  *style* few-shot — untested, plausibly small, and largely subsumed by
  P1-4's deterministic rules, which are cheaper, inspectable, and cannot
  hallucinate.

**Recommendation:** do not build until P1-4's rule taxonomy hits a class
deterministic rules cannot express (tone, phrasing). If built: style-scoped
exemplars only, battery-gated, with a pre-registered prediction on the
refine battery score and the `.rendered` CER metric (the formatter's
metric), and an automatic fall-back to the static prompt when the battery
with-exemplars score drops below the recorded floor. **Privacy: zero**
(on-device, exemplars are the user's own data). **Engineering: medium-high
for the eval scaffolding, low for the prompt splice.**

### P2-7. A generic (not per-user) FoundationModels adapter for the refine stage

The adapter story on macOS 26, verified against Apple's own materials
(sources below):

- **It exists and is real.** The Foundation Models Adapter Training Toolkit
  (v26.0.0) trains LoRA rank-32 adapters for the on-device ~3B model;
  training runs on an Apple-silicon Mac with ≥32 GB or a Linux GPU box,
  Python 3.11+; output is a `.fmadapter` package (~160 MB) loaded via
  `SystemLanguageModel.Adapter(fileURL:)`; deployment in a shipping app
  requires the `com.apple.developer.foundation-model-adapter` entitlement
  (Account-Holder-requested), though **local testing needs no entitlement**;
  Apple recommends 100–1,000 training pairs for basic tasks, 5,000+ for
  complex ones, delivered via Background Assets.
- **The treadmill is documented by Apple, and this repo has already lived
  it.** "Each adapter is compatible with a single specific system model
  version… you must train a different adapter for every version of the
  system model." macOS point releases replace the base model —
  `RefineInstructions.swift:8–9` records that 26.4 did exactly that, and the
  eval bands already carry wider tolerances for `refine=on` rows because of
  it. The toolkit's last release is additionally **not compatible with
  OS 27+**, i.e. the toolkit itself lags the OS.
- **The headroom is small and unproven.** The refine battery already scores
  0.972 weighted on the current prompt; the cage converts every model
  failure into verbatim text. An adapter's win would have to show up as
  refined-stage WER/CER on human-v1 — which does not exist yet (P0-3).

**Verdict: defer with a named re-entry condition.** A *generic
dictation-cleanup* adapter (trained once, on synthetic + consented corpus
pairs, shipped to all users) is mechanically feasible and needs no per-user
anything — but it costs a 160 MB download, an entitlement, a per-OS-release
retraining pipeline, and a second eval battery, against a stage that is
currently near its measured ceiling. Re-enter only if human-v1 shows the
refined stage leaving ≥2 WER points on the table that three rounds of
prompt engineering (Apple's own first recommendation) cannot recover.

---

## 4. Killed options — named, with the mechanism that kills each

The argument stage should not spend a minute on any of these.

1. **Training/fine-tuning Apple's acoustic model (SpeechAnalyzer /
   SpeechTranscriber / DictationTranscriber).** No API exists at any level:
   the models are system assets (`AssetInventory`-managed), there is no
   weight access, no update API, no enrollment API. The module roster is
   transcribers + `SpeechDetector` — nothing trainable. **Dead on arrival.**
2. **Per-user FoundationModels adapter trained on-device on the user's own
   (raw, edited) pairs.** Training is a developer-time Python-toolkit
   workflow (≥32 GB Mac or Linux GPU, hours), not an in-app API; there is no
   supported on-device training path; the adapter dies at every base-model
   refresh (26.4 precedent — for *every user's* adapter simultaneously,
   retrainable only on their own machine); and the data supply
   (100–1,000 *quality* pairs) takes months of dictation to accumulate.
   Even as a hobbyist path for this one user's machine it fails the product
   bar: an app whose accuracy silently degrades on every macOS point release
   until a retraining job runs is the opposite of "as though this is how
   things were meant to be used." **Killed.**
3. **Speaker adaptation / voice enrollment for ASR via any Apple surface.**
   Verified absent: *Personal Voice* is speech **synthesis** from enrollment
   (accessibility TTS), not recognition; *Vocal Shortcuts* maps trained
   phrases to App Intents (triggering, not transcription); Siri's speaker
   profiles are not exposed; *Voice Control* custom vocabulary is a
   user-level accessibility store that does not touch SpeechAnalyzer
   results for third parties. There is no enrollment, no voice profile, no
   speaker-conditioning input anywhere in the `Speech` framework surface.
   **Killed — with one standing cheap probe, next item.**
4. **`SFCustomLanguageModelData` (phrase counts + custom pronunciations) —
   the one API that *looks* like per-user LM personalization.** Probed twice
   on this machine against `DictationTranscriber` via
   `.customizedLanguage(modelConfiguration:)`: builds, exports, prepares
   (0.87 s, 6.55 MB) — **zero measurable effect** on macOS 26.5
   (`apps-feasibility.md` §findings; probes preserved at
   `docs/research/probes/clm_probe{,2}.swift`, including 1000-count phrase
   weighting and dual pronunciations). Also no system G2P API survives to
   generate phonemes. **Killed as a lever — kept as a per-OS-release
   re-probe** (one command, probes exist), because phrase-count LM biasing
   is exactly the right mechanism if Apple ever wires it into
   SpeechAnalyzer, and it would slot directly under P0-2's weighting.
5. **Local fine-tuning of Parakeet (or Whisper) on user audio.** Triple
   kill: the shipped Parakeet is compiled CoreML — inference-only, no
   trainable path (`MLUpdateTask` does not apply to a 0.6B conformer);
   upstream NeMo training requires NVIDIA hardware; and the training data
   (hours of per-user audio with references) requires the audio retention
   the product structurally refuses by default. P0-3's consented eval
   corpus is deliberately scoped to *measurement*, not training — 50 clips
   evaluate; they do not fine-tune anything. **Killed.**
6. **A resident fine-tuned open-weights formatter (mlx-lm LoRA on a
   Qwen-class model) — the true local ceiling of the Wispr ladder.**
   Technically feasible on an M4 (LoRA on 4B-class models is
   hours-not-days, runs locally, zero runtime network) and it is the only
   rung that could ever replicate Wispr's fine-tuned-formatter quality with
   per-user weights. It is killed **by a standing product decision, not by
   physics**: the 2026-08-05 directive "Apple Intelligence only, zero
   network calls" (`deviations.md` §Native rewrite) removed exactly this
   class of dependency, and it would also reintroduce a multi-GB model
   download plus a training loop the user must babysit. If the user ever
   reverses that directive, this rung — not FM adapters — is the honest
   next step, because it has no entitlement, no base-model treadmill, and
   trains on the machine it runs on. Until then: **killed, with the
   reversal condition named.**
7. **Anything cloud** (per-user models on a server, federated anything).
   Structurally excluded by the product thesis; not argued further.

## 5. The Wispr contrast, and where the local ladder tops out

Wispr's personalization stack (from `docs/research/wisprflow.md`): cloud ASR
conditioned on speaker qualities + screen context + an LLM proper-noun
extractor; a fine-tuned Llama formatter trained on ~1B words/month of edit
triples; passive dictionary auto-add; device-stored personalization context;
per-user preference policies ("never make the same mistake twice") with
per-user fine-tunes as the stated direction.

The honest local-only equivalent ladder, bottom to top:

| rung | Wispr's version | local-only equivalent | status |
|---|---|---|---|
| 0 | dictionary + auto-add | `DictionaryStore` + propose-first learn loops | **built** |
| 1 | passive learning from corrections | P0-1 hear-phrase mining + per-user misrecognition stats | unexploited, cheapest win |
| 2 | context/proper-noun conditioning of ASR | DT `contextualStrings` + Parakeet CTC evidence + context-snapshot terms, all weighted by P0-2 | built + gated; weighting unexploited |
| 3 | preference policies from edit triples | P1-4 deterministic style rules | unexploited, supply-limited today |
| 4 | fine-tuned formatter (cloud, millions of users) | static caged prompt on the Apple ~3B (+ P2-6 few-shot, doubtful; + P2-7 generic adapter, deferred) | **this is the ceiling** |
| 5 | per-user model fine-tunes | killed items 2/5/6 above | **no local rung exists** under current product law |

Where it tops out, stated plainly: **local-only personalization ends at rung
4, and rung 4's model is not ours** — Apple owns the weights, replaces them
per point release, and the only supported specialization (adapters) is a
developer-time artifact, not a user-time one. Everything above rung 4
requires either audio retention plus non-Apple training stacks (killed) or
reversing the Apple-Intelligence-only directive (named, not recommended).
The compensating asymmetry, and the reason this ceiling is acceptable: rungs
1–3 are *exactly* the rungs Wispr's own users credit for the
"essentially perfect after it learns" experience (dictionary + passive
learning + context), they compound across all three recognition channels
simultaneously, and every one of them is measurable on this machine with
data that never leaves it.

## 6. What the adversarial panel should attack, pre-answered

- *"The replay prediction (P0-1) can overfit to the user's history."* The
  chronological split exists to prevent exactly that; the promotion
  threshold (≥2 distinct utterances) and phonetic floor are held fixed, not
  tuned per replay. And hear phrases are per-term whole-word regexes — the
  FP surface is structurally tiny; the eval `dict=on` arm double-checks.
- *"TTS numbers again."* Correct: every offline number cited (14/18, 41 FPs,
  3.1 ms/term) is plumbing-grade, said so at the source, and P0-3 exists
  precisely to retire this objection. The P0 items' *primary* predictions
  are replay/live metrics on the user's own data, not TTS.
- *"Per-app profiles are the start of the Wispr surveillance slope."* The
  field is a bundle-ID string the insertion path already reads, additive,
  purge-covered, documented — but the objection has teeth (it is a partial
  app log), which is why P1-5 is ranked behind items with zero narrative
  cost, and ships only with the same append-only-schema + purge guarantees.
- *"Few-shot was killed by one measurement; maybe the hint format was
  wrong."* Possible — but the burden is on the exemplar format to beat the
  battery, the scaffolding to test it is priced in at P2-6, and the
  deterministic alternative (P1-4) wins every case that is expressible as a
  rule. The panel should demand the battery-with-exemplars number before
  any argument time is spent.
- *"The adapter kill is too quick — a generic adapter is how you fix accent
  robustness in the refine stage."* No: the refine stage never hears audio;
  accents live in ASR, where no trainable surface exists (kill #1). An
  adapter can only improve text-to-text cleanup, whose measured battery
  score is 0.972 with guards that already convert failure to verbatim.

## Sources

- Repo evidence: `docs/notes/deviations.md`, `docs/eval/DEFINITIONS.md`,
  `docs/eval/RESULTS.md`, `docs/research/apps-feasibility.md`,
  `docs/research/spikes-s1.md`, `docs/research/spikes-parakeet.md`,
  `docs/research/local-tech.md`, `docs/research/wisprflow.md`, and the
  source files cited inline.
- [Apple — Get started with Foundation Models adapter training](https://developer.apple.com/apple-intelligence/foundation-models-adapter/)
  (toolkit 26.0.0, hardware, LoRA, 160 MB, entitlement, per-model-version
  retraining, "prompt engineering first" guidance).
- [Apple docs mirror — Loading and using a custom adapter with Foundation Models](https://github.com/livingston/apple-docs/blob/main/documentation/FoundationModels/loading-and-using-a-custom-adapter-with-foundation-models.md)
  (`SystemLanguageModel.Adapter(fileURL:)`, local testing without
  entitlement, Background Assets delivery, draft-model compile).
- [Apple Developer Forums — adapter incompatible with newer base model](https://developer.apple.com/forums/thread/794839)
  (version-coupling reproduced in the wild, even across betas).
- [Apple — WWDC25: Bring advanced speech-to-text to your app with SpeechAnalyzer](https://developer.apple.com/videos/play/wwdc2025/277/)
  (module roster: transcribers + detector; no enrollment surface).
- [AFMTrainer (GUI over Apple's toolkit)](https://github.com/scouzi1966/AFMTrainer)
  (independent confirmation of toolkit workflow and requirements).
- [Blake Crosley — Foundation Models custom adapters: when to train one](https://blakecrosley.com/blog/foundation-models-custom-adapters) and
  [Datawizz — Training Apple Foundation Model adapters](https://docs.datawizz.ai/afm/apple-foundation-model-adapters)
  (rank 32, dataset sizing, macOS 26 `afm` testing).
- [Blake Crosley — Accessibility as platform (Personal Voice, Vocal Shortcuts)](https://blakecrosley.com/blog/accessibility-platform-features)
  (Personal Voice = synthesis; Vocal Shortcuts = App Intent phrases).
