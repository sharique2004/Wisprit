# What the numbers mean

Every metric in `RESULTS.md` and `BASELINE.json` is defined here, exactly, with
the code that computes it. A number whose definition drifts is worse than no
number: it looks comparable and is not. When a definition changes,
`EvalInfo.scorerVersion` (`Sources/WispritEval/EvalInfo.swift`) is bumped and
every row records which scorer produced it.

Implementations: `Sources/WispritEval/Normalize.swift`,
`Sources/WispritEval/Score.swift`, aggregation in
`Sources/WispritMac/Eval/EvalScoring.swift`.

---

## The reference

Each corpus entry carries one `ref`: **the text the user wanted in their
document**, not a phonetic transcript of the audio. So `sharique at gmail dot
com` is spoken, and `sharique@gmail.com` is the reference.

Every stage is scored against that same reference. This is deliberate and it is
the whole reason the stage table is legible: the raw ASR row includes the
formatting the pipeline is *supposed* to add, so the drop from `raw` to `final`
is exactly what the deterministic stages and the model are worth. A raw WER of
14% next to a final WER of 6% is a working pipeline, not a broken engine.

Stage names are `SessionController.finalizeUtterance` order:

| stage | what produced it |
|---|---|
| `raw` | the engine's final text |
| `corrected` | + spoken-spelling corrections (`SpokenSpellingCorrector` → `CorrectionApplier`) |
| `refined` | + the Apple Intelligence cage (`Refiner`); identical to `corrected` when `refine=off` |
| `final` | + the eight deterministic post-process stages, with the dictionary when `dict=on` |

## Normalization profiles

`NormalizeProfile` decides how much of the surface form a comparison may see.
Every metric names one, so a number is never ambiguous about what it forgave.

### `.asr` — what WER runs over

Formatting-blind. The chain, in order:

1. **NFKC** (`precomposedStringWithCompatibilityMapping`) — folds fullwidth
   digits, ligatures, `…` → `...`.
2. **Quote and dash folding** — curly quotes → ASCII `'`/`"`; en dash, em dash
   and ellipsis → space.
3. **Lowercase**, ICU root locale (never locale-sensitive: a Turkish locale
   would turn `I` into `ı` and move a number).
4. **Symbol ITN** — the three symbols the keep-set would otherwise destroy
   silently: `$1,200.50` → `1,200.50 dollars`, `%` → ` percent `, `3:15` → `3 15`.
5. **Keep-set** — letter, digit, space, apostrophe survive; every other
   character becomes a space. (Promoted verbatim from
   `docs/research/probes/fc_acc.swift:23`, so the probe's published numbers stay
   reproducible.)
6. **Single-letter-run collapse** — two or more consecutive one-letter tokens
   join: `j s o n` → `json`, which makes a spelled run comparable with its glued
   form. Digits are excluded (`3 15` is a clock time). Known cost: `a` and `i`
   are real words, so `did i a b test` collapses to `did iab test` — applied to
   reference and hypothesis alike, so it can hide an error but never invent one.
7. **Phrase rewrite**, greedy longest-match over two *enumerated* tables — there
   is no number parser and no fuzzy matching:
   - **ITN**: cardinals 0–999 and ordinals 1st–31st, canonicalized to the digit
     form (`twenty three` → `23`, `fourteenth` → `14th`). Known collision:
     `second` → `2nd`, so "wait a second" reads as "wait a 2nd" — on both sides.
   - **Variants**, four pairs and only four, each one a decision to stop
     measuring something: `okay`→`ok`, `e mail`→`email`, `git hub`→`github`,
     `postgresql`→`postgres`.

Anything not enumerated above is left exactly as it was.

### `.rendered` — what CER runs over

NFKC, quote folding, whitespace collapse. **Case and punctuation stay**, because
this profile exists to catch the formatter regressing, not the engine.

### `.light` — what zero-edit runs over

Whitespace collapse plus exactly one tolerance: a **trailing** sentence mark
(`. , ! ? ; :` or `…`). That is the edit a user makes without thinking, and
counting it would make the zero-edit rate measure punctuation taste.

## WER — word error rate

Word-level Levenshtein with backtrace over `.asr` tokens; unit costs; ties
resolve diagonal → deletion → insertion, fixed so the same pair always yields
the same alignment and a golden stays a golden.

    WER = (substitutions + deletions + insertions) / reference words

An empty reference scores 0 when the hypothesis is also empty and **1**
otherwise — there is no denominator, and reporting 0 for "invented a sentence
from nothing" would be a lie.

### Micro-average — the only headline rule

Corpus WER is **Σerrors / Σreference-words** across every utterance, never the
mean of per-utterance rates. Summing first is the point: a macro-average lets a
three-word utterance outvote a ninety-word one. `Score.macroAverage` exists so
the two can be printed side by side when they disagree; it is never the headline.

Per-category rows use the same rule within the category.

## CER — character error rate

The same alignment over `.rendered` characters, aggregated the same way:
Σcharacter-errors / Σreference-characters. This is the formatter's metric —
casing, punctuation and hyphenation all count.

## Term recall

For each expected term in a clip's `expect.terms`, whole-word and
case-insensitive presence in the hypothesis. The matching rule is a deliberate
copy of `VocabularyChannel.termHits`:

    \b + words escaped and joined with \s+ + \b, .caseInsensitive

so the offline scoreboard and the live telemetry count the same thing.
(`WispritEval` may depend only on `WispritKit`, so the regex is duplicated rather
than imported — keep the two in sync.)

Aggregated **micro**: Σterms-found / Σterms-expected over the clips that expect
any. A corpus where no clip expects a term reports `—`, not `1.000`: a rate over
an empty denominator is not a rate.

This is the metric that moves when ASR biasing lands (Phase 3/4). The
`control-names` category — names deliberately absent from
`tools/eval/fixtures/eval-dictionary.json` — is the arm that proves recall came
from recognition and not from the dictionary inventing names.

## Zero-edit rate

Wispr Flow's own headline metric: the share of utterances the user would not
have had to touch.

    zero-edit(utterance) = tokens(ref, .light) == tokens(hyp, .light)

**Observable-denominator rule.** Offline, every clip is observable — the
reference is known — so the denominator is every scored utterance and `n` is
always reported next to the rate.

Live (Phase 5) it is *not*: an edit can only be counted where the pipeline can
still see the text it inserted. The IM rungs can re-read their own committed run;
the paste/type rungs need Phase-4 context; a secure field can never be observed.
So the live rate is

    zero-edit / utterances whose outcome was actually observed

with the unobserved ones excluded from the denominator rather than assumed
clean, and `n` reported every time. An unobserved utterance is never counted as
zero-edit — that is precisely how this metric gets quietly inflated.

## Provenance stamped on every row

An accuracy number without these is a rumour: the on-device model is replaced in
macOS point releases (26.4 rebuilt it), the prompt is eval-locked, and the
dictionary changes under the user's hands.

| field | source |
|---|---|
| `gitSha` | `git rev-parse --short HEAD` |
| `osBuild` | `sw_vers -buildVersion` |
| `promptSha256` | sha256 of `RefineInstructions.text` |
| `dictionaryTerms` | `DictionaryStore.terms().count` for `tools/eval/fixtures/eval-dictionary.json` |
| `scorerVersion` | `EvalInfo.scorerVersion` |
| `corpusSource` | `human` \| `tts` \| `librispeech`, required on every manifest line |

`corpusSource` is required by the manifest parser and carried into the row so a
TTS number can never masquerade as an accuracy claim. A mixed corpus reports as
`tts` if it contains any TTS: an over-broad banner is better than a suppressed one.

## Configurations

A row's `config` is the pipeline configuration it measured, spelled exactly:

    refine=off,dict=off    refine=off,dict=on
    refine=on,dict=off     refine=on,dict=on

`dict` switches the dictionary in the **post-process** stage only. The corrector
and the refine cage keep the dictionary as a *vocabulary* (is this spelled run
already a known term?) in both, because that is a different job from rewriting
text and is not what the flag measures.

## Baseline bands

`BASELINE.json` holds accepted numbers per (corpus, config) as
`{stage, metric, accepted, tolerance}`. A run violates a band when

- `wer` / `cer` (lower is better): `observed > accepted + tolerance`
- everything else (higher is better): `observed < accepted - tolerance`
- or the run did not produce the metric at all — silently dropping a metric is
  how a regression hides.

Bands exist because the refine stage is stochastic; a hard equality would make
the scoreboard flap. A `(corpus, config)` with no record is a new configuration,
not a regression, and yields no violations.

Recorded tolerances follow the source of the variance, not a house style:
`refine=off` rows are deterministic given the same audio and build (±0.015 WER
absorbs an ASR model refresh), while `refine=on` rows ride an on-device model
Apple replaces in point releases (±0.035 WER, ±0.09 on the rate metrics).

The refine battery is recorded under the pseudo-record
`corpus: "refine-battery", config: "cases"`, which no corpus run can match. That
is deliberate: the battery scores the *prompt*, not a corpus, so attaching its
band to a real (corpus, config) would make every `eval report` that re-renders
from a cached replay — and therefore carries no battery number — look like a
regression. `RehearsalTests` scans every record for battery bands and gates on
the lowest floor, so the pseudo-record is still found.

`Wisprit eval report` exits **3** when a band is violated (1 = the run failed,
2 = bad arguments).
