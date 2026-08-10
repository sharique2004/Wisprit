# Spike S1 — engine split, settled

Three questions from [apps-feasibility.md](apps-feasibility.md) had **conflicting probe results
between prior agents**. Re-measured on this machine (M4, macOS 26.5, Xcode 26.6, Swift 6.3.2),
5 Aug 2026, with `say -v Samantha`-synthesized 16 kHz mono Int16 WAVs fed as real-time-paced
100 ms buffers unless noted. Probe sources: `probes/s1/{q1,q2,q3,q4,q5}.swift` (see
"Re-running" at the bottom).

**One root cause explains all three conflicts: Speech objects must not be reused across
utterances.** A `SpeechAnalyzer` reused across utterances silently *corrupts* the transcript; a
`SpeechModule` reused across analyzers *traps the process*. Every prior "hang", "corrupted
results stream", and "partials track end-of-audio" observation is downstream of that, or of
testing on a clip shorter than the partial cadence.

---

## Q1 — resident analyzer + `finalize(through:)` vs session-per-utterance

**Answer: session-per-utterance. The resident analyzer is not "unreliable", it is *silently
lossy* — which is worse.**

14 back-to-back utterances, 1.5 s gaps, one resident `SpeechAnalyzer` whose input stream stays
open, `finalize(through: nil)` at each release (`q1.swift . nil 14`):

| | |
|---|---|
| finalize returned | **14 / 14** — never hung, 39–74 ms |
| transcripts correct | **1 / 14** |

```
utt 1  [u1] 74ms | Hi, Shariq. Please add this to Whisperedendon's Forge before the meeting.
utt 2  [u2] 39ms | ........
utt 3  [u3] 68ms | . to the quick brown fox jumps over the lazy dog.
utt 4  [u1] 66ms | . Please add this to Whisperedendon's Forge before the meeting.
…pattern repeats identically through utt 14
```

Every utterance after the first loses its head. `u2` ("Let's ship the native rewrite this week",
2.0 s) is destroyed **completely and repeatably** — five times out of five. `u1` loses "Hi,
Shariq." `u3` loses "The". The loss is roughly the first 1.2–2.0 s of each utterance, i.e. a
short push-to-talk tap can vanish entirely. So the earlier probe that reported "12/12 at
74–305 ms" was measuring only that `finalize` *returned*; it was not checking the text.

Same audio, same order, fresh module + fresh analyzer per utterance
(`q1.swift . persession 12`) — `builder.finish()` + `finalizeAndFinishThroughEndOfInput()`:

```
utt 1  [u1] prepare= 43ms release->final=108ms | Hi, Shariq. Please add this to Whisperedendon's Forge before the meeting.
utt 2  [u2] prepare= 51ms release->final= 84ms | Let's ship the native rewrite this week.
utt 3  [u3] prepare= 53ms release->final= 69ms | The quick brown fox jumps over the lazy dog.
…12/12 correct
```

**12/12 correct, release→final 69–108 ms, `prepareToAnalyze` 31–54 ms.** Comfortably inside the
sub-400 ms budget with the prewarm on the critical path.

### Both `finalize` variants

- `finalize(through: nil)` — returns reliably (14/14). Corrupts the transcript as above.
- `finalize(through: <CMTime>)` — **reproduced the hang.** With the accumulated end-of-utterance
  `CMTime` it never returned; the process was still wedged after 90 s on utterance 1 and the
  8 s watchdog could not free it (`cancelAll()` does not interrupt the in-flight `finalize`, so
  even observing the hang wedges the harness). Do not pass a `CMTime` target on a live path.

### Module / analyzer reuse (the root cause)

`q4.swift . a`: one `SpeechTranscriber` instance, two successive `SpeechAnalyzer`s. Pass 1
transcribes correctly; **pass 2 traps the process (exit 133, SIGTRAP), no Swift error, no
message.** A module's `results` sequence is bound to the analyzer that finished it. Construct
both fresh, every utterance.

### Alternating configs + `SpeechModels.endRetention()`

`q4.swift . c`: 8 alternating runs (ST-only / ST+DT-in-one-analyzer) at 1.0 s gaps, each with
fresh objects: **0/8 degraded.** ST 79–92 ms, dual 406–439 ms.

```
--- SpeechModels.endRetention() ---   (0 ms, no-op cost)
ST post-endRetention 1..3: 117 / 82 / 87 ms, all correct
```

The previously-reported "back-to-back sessions with <4 s gaps corrupt the results stream" did
**not** reproduce once objects are fresh per utterance. `endRetention()` is free and harmless;
keep it as a recovery lever after a timeout/crash, not as a routine cooldown. **There is no
inter-utterance cooldown requirement** — which matters, because a cooldown would have been a
user-visible defect in a push-to-talk product.

Dual-module-in-one-analyzer is confirmed as the slow path (~4.5× ST here on unpaced input,
1377–1790 ms in the earlier real-time-paced probe). It stays off the paste path regardless.

---

## Q2 — do `.fastResults` partials genuinely lead end-of-audio?

**Answer: yes, decisively, on utterances ≥ 8 s. Ship `.fastResults`. The earlier "partials track
end-of-audio" observation was an artifact of a 3.1 s test clip.**

The useful metric is not lag (a partial's `range.end` tracks the fed position to within ~80 ms
in every configuration) but **delivery cadence** — how often a new partial arrives:

| clip | `.fastResults` | first partial | cadence | volatiles before end-of-audio |
|---|---|---|---|---|
| long1 20.4 s | on | **1.03 s** | ~0.95 s | **89 / 95** |
| long1 20.4 s | off | 3.93 s | ~3.80 s | 89 / 95 |
| long2 17.8 s | on | **1.01 s** | ~0.90 s | **78 / 82** |
| long2 17.8 s | off | 3.92 s | ~3.80 s | 69 / 82 |
| u1 3.8 s | on | **1.01 s** | ~0.95 s | 15 / 21 |
| u1 3.8 s | off | 3.92 s | — | **0 / 22** |

Without `.fastResults` the partial period is ~3.8 s. On a 3.1–3.8 s clip that puts the *first*
partial at end-of-audio and nothing before it — exactly "partials track end-of-audio", and
exactly what the earlier probe saw. On a long utterance the same configuration is plainly
leading. With `.fastResults` the period drops to ~0.95 s and the first partial lands at ~1.0 s
regardless of clip length. Final text was identical with and without in every pair.

Release→final showed no consistent penalty (long1 207 ms on / 540 ms off; long2 564 / 413;
u1 58 / 78) — `.fastResults` is a latency knob, not an accuracy or finalize cost.

**Consumer contract (non-obvious, load-bearing):** volatile text is *windowed, not cumulative*.
After an intermediate final the volatiles restart from the post-final range:

```
vol t=12.52s …hen they are fed to the analyzer in real time.
FIN t=12.86s …hen they are fed to the analyzer in real time.
vol t=13.53s  or                      ← restarts, does NOT repeat the finalized prefix
vol t=13.53s  or whether
```

A live-streaming consumer must render `finalizedText + currentVolatile`, never the volatile
alone. `q2.swift` also shows partials arriving in bursts of 4–6 within the same millisecond —
coalesce before touching the field.

---

## Q3 — `contextualStrings` cost at n = 50 / 200 / 500

**Answer: ~3.1 ms/term, entirely in session setup, zero in decoding — and it is off the paste
path anyway. Ship the whole dictionary. No 50-term cap.**

`DictationTranscriber` (`[.shortForm]`, `[.punctuation]`,
`[.volatileResults, .frequentFinalization]`), fresh module + analyzer per run, 5 runs per n,
3.9 s of audio fed unpaced (the off-path shape), median (`q3.swift . fresh 5`):

| n | setup (setContext + prepareToAnalyze + start) | release→final | total | text |
|---|---|---|---|---|
| 0 | 68 ms | 441 ms | 507 ms | Hi **Shari**, please add this to whispered ends forge… |
| 50 | 228 ms | 388 ms | 623 ms | Hi **Sharique**, … |
| 200 | 663 ms | 395 ms | 1064 ms | Hi **Sharique**, … |
| 500 | 1636 ms | 421 ms | 2057 ms | Hi **Sharique**, … |

Marginal cost is linear and stable: 3.2 / 2.98 / 3.14 ms per term at n = 50/200/500. Both prior
numbers (+7 ms/term, +4 ms/term) were high; this config measures **~3.1 ms/term**.

Two things settle the question:

1. **The cost is 100 % in setup, 0 % in decoding.** release→final is flat (388–441 ms) across
   n = 0…500. Nothing about the recognition loop gets slower.
2. **The vocabulary channel is off the paste path** — it runs `DictationTranscriber` over
   retained PCM after the live `SpeechTranscriber` result has already been inserted. A 1.6 s
   setup on a background task is invisible to the user.

**No dilution at n = 500**: "Sharique" is still recovered with 520 terms loaded (136 real
dictionary terms + synthetic proper-noun padding), so Apple's "≤ 100 phrases" doc guidance is
advisory, not a cliff. The verifier's conclusion — ship the whole dictionary — is the correct
one, for a reason neither prior agent gave: it isn't that the per-term cost is small, it's that
the per-term cost isn't on a path the user waits for.

`prepareToAnalyze` is what scales, so it must happen **inside** the vocabulary channel's
background task, not in a prewarm on key-down.

### `.frequentFinalization` is mandatory — confirmed

`q4.swift . b`, same audio and module config, only `reportingOptions` varied:

| reportingOptions | final text | volatiles |
|---|---|---|
| `[]` (default) | **NONE** | 1 |
| `[.volatileResults]` | **NONE** | 19 |
| `[.frequentFinalization]` | "Hi Shari, please add this to whispered ends forge…" | 0 |
| `[.volatileResults, .frequentFinalization]` | "Hi Shari, please add this to whispered ends forge…" | 17 |

Silent total data loss without it, exactly as the contract warns. Note `[.volatileResults]`
alone produced 19 volatiles and *no* final — a consumer that only reads `isFinal` gets nothing
while looking perfectly healthy.

---

## Q-extra — asset preflight (for the doctor check)

`q5.swift` on this machine:

```
SpeechTranscriber.isAvailable = true
ST status = supported      DT status = supported      ST+DT status = supported
ST installed = [en_IE, en_CA, en_SG, en_NZ, en_IN, en_AU, en_GB, en_ZA, en_US]
DT installed = [en_US]
reserved = []   maximumReservedLocales = 5
```

**Gotcha: `AssetInventory.status(forModules:)` returns `.supported`, not `.installed`, on a
machine where transcription demonstrably works.** A doctor check keyed on `status == .installed`
would report a false failure. Use `isAvailable` plus membership of the requested locale in
`installedLocales`, and treat `status` as advisory only.

`Preset.progressiveTranscription` = `[.volatileResults, .fastResults]` and
`Preset.progressiveShortDictation` = `[.volatileResults, .frequentFinalization]` +
`[.shortForm]` + `[.punctuation]` — both presets are exactly the configurations this spike
concludes with, so the code uses the explicit option sets and documents the equivalence.

---

## Q-extra 2 — AVAudioConverter output capacity (found while porting capture)

The mic delivers 44.1/48 kHz float32; the analyzer wants 16 kHz Int16. The
non-obvious part is the **output buffer size**: with a roomier output buffer than
the input can fill, `AVAudioConverter` reaches `.noDataNow` with input still
pending and drops it — every call. Measured over 1 s of 48 kHz audio in 100 ms
taps (`conv.swift`):

| output capacity per 4800-frame tap | frames produced (want 16000) |
|---|---|
| 4096 (slack), one convert call | 15056 — **6 % of the audio silently gone** |
| 4096 (slack), looped until dry | 15056 |
| 1600 (exact `ceil(in × ratio)`) | **15760** |

At exact capacity the only loss is the resampler's one-time filter delay — 240
frames at 48 kHz, 120 at 44.1 kHz, **once per capture session, not per chunk**
(verified over 50 chunks: 79760 / 80000 and 79880 / 80000). Two rules follow, both
enforced by tests: size the output buffer exactly, and keep ONE converter for the
whole capture session (a fresh converter per buffer pays the filter delay every
time).

---

## What the engine implements

- **Live path:** fresh `SpeechTranscriber` + fresh `SpeechAnalyzer` per utterance,
  `[.volatileResults, .fastResults]`, `prepareToAnalyze` on key-down,
  `builder.finish()` + `finalizeAndFinishThroughEndOfInput()` on key-up. No object survives an
  utterance. No `finalize(through:)`. No cooldown.
- **Streaming consumer:** `finalizedText + currentVolatile`, coalesced.
- **Vocabulary channel:** `DictationTranscriber` + full-dictionary `contextualStrings`,
  `.frequentFinalization` mandatory, own analyzer, background task over retained PCM, never in
  the same analyzer as the live module.
- **Recovery:** `SpeechModels.endRetention()` after a timeout or crash (free, harmless), not
  routinely.
- **Doctor:** `isAvailable` + `installedLocales`; `AssetInventory.status` advisory only.

## Re-running

```
cd docs/research/probes/s1
say -v Samantha -o u1.wav --file-format=WAVE --data-format=LEI16@16000 "Hi Sharique, please add this to Wisprit and InsForge before the meeting."
# …u2/u3/long1/long2 as in the header comments; terms.json = dictionary terms padded to 520
swiftc -O -parse-as-library q1.swift -o q1   # ./q1 . nil 14 | ./q1 . cmtime 14 (HANGS) | ./q1 . persession 12
swiftc -O -parse-as-library q2.swift -o q2   # ./q2 long1.wav 1  /  ./q2 long1.wav 0
swiftc -O -parse-as-library q3.swift -o q3   # ./q3 . fresh 5
swiftc -O -parse-as-library q4.swift -o q4   # ./q4 . a  (traps) | ./q4 . b | ./q4 . c
swiftc -O -parse-as-library q5.swift -o q5   # ./q5
swiftc -O conv.swift -o conv                 # ./conv  (AVAudioConverter capacity, no @main)
```

`-parse-as-library` is required — every probe uses `@main` in a file with top-level comments.

**Caveat carried from the parent research:** all audio is `say`-synthesized. Directions and
orders of magnitude are trustworthy; absolute WER and the biasing win need re-validation on
human speech (spike S4).

**S4 status: tooling ready — recording pending.** `Wisprit eval record` / `eval verify` and the
131-utterance `human-v1` script set exist (`tools/eval/scripts/human-v1/`, protocol in its
README). Nothing above is re-validated until that audio is recorded and the held-split baseline
is on the scoreboard.

---

# S1-b — the "every utterance after the second comes back empty" incident (5 Aug 2026)

A real user, real microphone, on this machine: utterance 1 SUCCESS (paste, finalize 175 ms),
utterance 2 SUCCESS 76 s later (paste, 21 chars, finalize 14 ms), then **utterances 3–7 over the
next 50 s ALL `outcome=empty` with `finalize_ms` pinned at the 1500 ms budget**
(`~/.wisprit/metrics.log`, ts 1785971800–1785971842 = 16:16:40–16:17:22 local). No error-level
`os_log` lines. The suspicion on entry was the vocabulary channel: `completeCorrection` fires
`AsrManager.reconcileVocabulary()` after each success, `VocabularyChannel.reconcile` never calls
`SpeechModels.endRetention()`, and the parent research flagged "rapid-session degradation".

**That suspicion was wrong. The ASR engine was never poisoned — it was starved. The default
input device changed from a 48 kHz mic to a 24 kHz Bluetooth one between the last success and
the first failure, and `MicCapture` reused one `AVAudioEngine` for the app's lifetime, so its
input chain stayed wired for 48 kHz and the tap silently stopped delivering buffers forever.**

## The matrix (fed PCM, no microphone anywhere)

`tests/WispritEngineTests/RapidSessionMatrixTests.swift`, env-gated so the normal suite never
pays for it. One `AsrManager` for the whole run (the production topology — `SessionController`
holds a single manager), `say`-synthesized clips fed as real-time-paced 100 ms 16 kHz Int16
chunks, 138 contextual terms (the size of the user's real `dictionary.json`), gap measured from
the production rows (release→next press was 3.7–4.1 s, not the 5–8 s the ts column suggests):

```
WISPRIT_LIVE_ASR=1 WISPRIT_MATRIX=b swift test --filter RapidSessionMatrixTests \
    --scratch-path /tmp/wisprit-build-WispritEngine
```

| cfg | shape | empties | finalize ms |
|---|---|---|---|
| a | control, no reconcile, 8 utt @ 4.0 s | **0 / 8** | 62–101 |
| b | reconcile detached after every success (production), 8 utt @ 4.0 s | **0 / 8** | 54–122 |
| b′ | as b, 0.5 s gaps — reconcile genuinely in flight at *every* `begin` | **0 / 8** | 73–102 |
| b″ | as b, **500** terms, **0.0 s** gap, 10 utt — maximum overlap | **0 / 10** | 43–98 |
| c | as b + `SpeechModels.endRetention()` after each reconcile | **0 / 8** | 71–98 |

**The production shape does not reproduce, in any configuration, including ones far more hostile
than production.** Reconcile took 552–1399 ms at 138 terms and 1964–2536 ms at 500 terms; under
b″ it genuinely overlapped the next utterance's analyzer every time (`inflight=1`, twice
`inflight=2`). The live path did not care. Spike S1's original finding stands: fresh objects per
utterance is sufficient, and there is no cooldown requirement.

One real defect did surface in b″: with 500 terms at a 0 s gap, `reconcile` **itself** failed
(returned nil from its `catch`) on 4 of 10 passes. It never harmed the live path, but it used to
leave a failed DictationTranscriber session's cached engine behind.

## What actually produces the production signature

Config d — the same engine, given nothing:

| input | finalize | outcome | timedOut | crashed | partials |
|---|---|---|---|---|---|
| no audio at all | **1500.9 ms** | EMPTY | false | false | 0 |
| 3 s digital silence | **1500.9 ms** | EMPTY | false | false | 0 |
| normal speech | 72.5 ms | ok | false | false | 13 |

Production rows: `finalize_ms` 1500.0–1502.0, `outcome=empty`, `timed_out=false`. **Byte-identical
to a starved analyzer, and nothing like a wedged one** (a wedge sets `timedOut=true`). The 1500 ms
was not the analyzer working and failing; it was `finalize()` waiting out its whole budget on a
drain condition that could never be satisfied, because `TranscriptSink.isDrained()` requires a
final to have landed and no final ever lands when there is no audio. That also explains the
missing log line: with `timedOut=false` and `crashed=false`, `finalize` took the **soft** teardown
branch, which logs nothing and — crucially — never calls `endRetention`. The premise that
"endRetention fired and the stream stayed dead anyway" was false; it never fired.

## Root cause, from the production log

The failure was 2 minutes before the investigation, so `log show` still had it. Wisprit PID 86025:

```
16:15:14  Input render format:  1 ch, 48000 Hz, Float32     ← utterance 1, SUCCESS
16:16:27  setPlayState Started Input                        ← utterance 2, SUCCESS
16:16:32  setPlayState Stopped Input                        ← utterance 2 released
16:16:35  Input render format:  1 ch, 24000 Hz, Float32     ← utterance 3, FIRST EMPTY
          setPlayState IOState: [1, 0]. BT device UIDS: { "00-C5-85-7D-4D-59:input" }
16:16:40 / :48 / 17:03 / :11 / :22   session: utterance error: nothing recognized   (×5)
```

The default input became a **24 kHz Bluetooth** device between the last success and the first
failure. `AVAudioEngine.h` documents precisely what happens next:

> When the engine's I/O unit observes a change to the audio input or output hardware's channel
> count or sample rate, the engine **stops itself** … The nodes remain attached and connected
> with **previously set formats**. However, the app **must reestablish connections** … in an
> input node chain, connections must follow the hardware sample rate.

`MicCapture` held **one `AVAudioEngine` for the app's lifetime**, re-installing a tap per
utterance with a format read from that stale engine, and never observed
`AVAudioEngineConfigurationChangeNotification`. So after the device change the input chain was
permanently wrong, the tap delivered nothing, `start()` still returned `true`, and every
subsequent press produced a perfectly healthy-looking 1.5 s of nothing — until the app was
relaunched. Five failures, then the user gave up; there was no path in the code that could ever
have recovered.

There were no `engine.capture` or `engine.apple_live` log lines in the whole window, which is
itself the finding: **a totally dead microphone was indistinguishable from a quiet user**, in the
logs and in `metrics.log` alike.

## The fix

`Sources/WispritEngine/MicCapture.swift` — **a capture session never outlives one utterance.**
`start()` builds a fresh `AVAudioEngine`, so the input chain is established against the format the
hardware has *now*; that is the only state that is correct by construction, and it removes the
"sticky forever" property entirely. It also registers an
`AVAudioEngineConfigurationChangeNotification` observer on that engine (flag-only — the header
warns the engine must not be deallocated from the handler), counts delivered bytes, and logs
loudly when a session ends having received none.

`Sources/WispritEngine/SpeechAnalyzerEngine.swift` — **drain on the analyzer's own signal, and
recover from a real wedge.** The `isDrained()` poll is replaced by waiting for the collector task
to finish (it exits when `module.results` ends, which is the analyzer stating nothing more is
coming), still capped by the budget. An utterance is now classified with two new inputs — bytes
fed and peak input level:

* `starvedInput` (< one 100 ms chunk ever reached the analyzer) is reported on `UtteranceResult`
  and logged as a capture fault. It does **not** trigger engine recovery: resetting the ASR cannot
  fix a dead microphone.
* audible speech in (`peak ≥ 0.02`) and *nothing* out — no final, no volatile — is now treated as
  a failure like a timeout or crash: any volatile tail is kept instead of discarded, a warning is
  logged, and `teardown(hard:)` runs `cancelAndFinishNow()` + `endRetention()` so the next
  utterance cannot inherit a suspect cached engine.

The peak-level gate is load-bearing and measured: 3 s of digital silence also yields zero results,
so emptiness alone cannot separate a wedged analyzer from a user who did not speak. Without the
gate every silent press would release the cached engines — a routine cooldown, which this spike
rejected.

`Sources/WispritEngine/VocabularyChannel.swift` — `endRetention()` on the reconcile **failure**
path only (the 4-of-10 case from b″), matching the live path's existing "recovery lever after a
failure, never routine" rule. **No idle-delay knob was added to `AsrSettings`:** the matrix
exonerated reconcile at 0 s gaps and 500 terms, so serializing it would have been a speculative
fix to a problem that does not exist.

Measured after the fix (config d, same harness):

| input | before | after |
|---|---|---|
| no audio at all | 1500.9 ms, EMPTY | **4.1 ms**, EMPTY, `starvedInput=true` |
| 3 s digital silence | 1500.9 ms, EMPTY | **38.7 ms**, EMPTY, `starvedInput=false` |
| normal speech | 72.5 ms, ok | 58.2 ms, ok |

A dead microphone now costs 4 ms and says so, instead of costing 1.5 s per press and saying
nothing.

## Recovery — one bad utterance must never strand the user

Config p injects the production failure (two consecutive starved sessions) into the middle of a
production-shaped run:

```
utt 1 fed      104.1 ms  ok      | utt 5 fed       56.9 ms  ok
utt 2 fed       75.9 ms  ok      | utt 6 fed       74.0 ms  ok
utt 3 STARVED    4.1 ms  EMPTY   | utt 7 fed      101.1 ms  ok
utt 4 STARVED    4.1 ms  EMPTY   | utt 8 fed       74.8 ms  ok
```

Starvation is reported exactly when real, and utterances 5–8 are unaffected.

## Verification

* production shape (config b, assertions on), **2 fresh runs: 8/8 non-empty both times**,
  finalize 65–100 ms.
* configs a / b / b′ / b″ / c / p as tabulated above — 0 empties everywhere.
* `swift test --filter WispritEngineTests --scratch-path /tmp/wisprit-build-WispritEngine`
  → **67 tests, 0 failures** (and 67/0 again with `WISPRIT_LIVE_ASR=1`, live models included).
* `swift test --scratch-path /tmp/wisprit-build-agentfix` → **705 tests, 0 failures**, 19 skipped.

## What is NOT proven

The device-change → wedged-tap chain is established from the production log plus Apple's
documented behaviour, not from a headless repro: the constraint for this investigation was fed
PCM only, so `MicCapture` was never run against a real microphone or a real device switch. The
fix is sound by construction (a fresh engine cannot carry a stale graph), but the live check that
would close the loop is: connect/disconnect a Bluetooth mic between two utterances on the fixed
build and confirm the second still transcribes, with `capturedBytes > 0`.
