# Swift module contracts (native rewrite)

Binding contract for every Swift build agent, mirroring the discipline of
[INTERFACES.md](INTERFACES.md) (the Python contract — read it, plus
[research/apps-feasibility.md](research/apps-feasibility.md), before writing code).
If your implementation must deviate, leave a `// CONTRACT-DEVIATION:` comment at
the site and list it in your final report.

## Ground rules (all agents)

- **You own exactly one SPM target** (plus its test target). Never edit
  `Package.swift`, anything in `Sources/WispritKit/`, or another target's files.
  If you need a cross-module type, it either already exists in `WispritKit`
  (`Contracts.swift`) or you request it from the orchestrator in your report.
- **The Python package `wisprit/` is the functional spec.** Port behavior 1:1
  unless `docs/research/apps-feasibility.md` explicitly changes it. The port
  contract (feature catalog, tuning constants, gotchas) is in the research
  digest at the path given in your task prompt.
- **Build/test only your target, with your own scratch path** (other agents are
  building concurrently — a shared `.build` would deadlock you):
  `swift build --target <T> --scratch-path /tmp/wisprit-build-<T>`
  `swift test --filter <T>Tests --scratch-path /tmp/wisprit-build-<T>`
- **Golden parity where a Python module exists:** generate fixtures by running
  the real Python (`~/.meetingscribe/venv/bin/python`), commit them as test
  resources, and assert the Swift port matches byte-for-byte. Do not hand-write
  expected outputs for behavior the Python already defines.
- No third-party dependencies. Vendored public-domain algorithm code (e.g.
  Double Metaphone) is fine, in your own target, with provenance noted.
- Platform: macOS 26 / iOS 26. Everything except `WispritEngine`'s AVFoundation
  capture code must compile for both (no AppKit/UIKit in these targets).

## Target ownership

| Target | Ports / implements | Python spec |
|---|---|---|
| `WispritPostProcess` | The ordered deterministic stages (eight in `PostProcess.process`; the email and URL joins are one stage there, split out here): filler removal → dictionary corrections (via `CorrectionApplying`) → spoken-email join (freemail/dotted-local guards) → spoken-URL join (11-TLD allowlist) → voice commands (new line/paragraph, trailing punctuation words) → self-correction (no wait / scratch that) → spoken emoji (closed 33-name table, the word "emoji" required, determiner + spelled-run guards; after self-correction because "that" is both a determiner and the scratch marker — docs/notes/deviations.md) → whitespace/casing tidy → leading-space policy. `PostProcessOptions` struct owns the config flags. | `postprocess.py` |
| `WispritDictionary` | `DictionaryStore`: load + hot-reload (mtime) of `dictionary.json`; compiled longest-first, `\s+`-relaxed, case-insensitive whole-word corrections; self-casing; conforms to `CorrectionApplying` + `VocabularySource`; `add(_ learned: LearnedTerm)` with additive schema `{source, learned_at, hit_count, last_used}`; atomic writes. | `dictionary.py` |
| `WispritCorrections` | NEW feature, from research §correction-detection: letter-run detector (uppercase-run regex on raw ASR finals, collapsed length ≥3, alphabetic segments, not-already-known via `VocabularySource`); trigger-phrase scan (confidence booster, never a gate); vendored Double Metaphone + Jaro-Winkler; antecedent scorer `max(0.6·codeSim + 0.4·JW, 0.9·JW)`, threshold 0.62; three-way `CorrectionAction` (retroReplace / insertLiterally+offer / tailReplace); emits `LearnedTerm`. Test cases: Sharique/Shariq/Cherie, Krzysztof→"Cherie" (must be no-candidate), J-S-O-N (must never retro-delete), the 12+8 scorer pairs from the research. | (new) |
| `WispritPersistence` | `Settings` (exact DEFAULTS keys, atomic persist, reload); `History` (SQLite via system `SQLite3`, **schema-compatible with existing `~/.wisprit/history.sqlite`**, add/recent/purge/trim-to-limit, text-only); `MetricsWriter` (JSONL, same field names as Python so `metrics.log` stays one stream). | `settings.py`, `history.py`, + metrics emission in `session.py` |
| `WispritRefine` | The Apple Intelligence cage, **in-process** via FoundationModels (no subprocess): prewarm-on-press; the eval-locked instruction prompt from `packaging/wisprit_refine.swift` **verbatim — do not reword**; greedy sampling; word-count plausibility guard; answered-instead-of-cleaned detector; **NEW obeyed-instead-of-cleaned detectors** (`obeyedWithCode`: the reply is code-shaped in a way the utterance was not; `droppedLeadingInstruction`: the leading imperative is gone and the reply is a near-subset of the tail — both caught by the eval harness, both eval-locked by `ObedienceGuardTests`); wrapper/preamble stripping fixpoint; hard timeout; `_has_address` skip; **NEW `_has_letter_run` skip** (research: the model corrupts spelled runs); the 13-value Python outcome vocabulary plus `has_letter_run` and `obeyed`; verbatim-always-wins. Rehearsal battery: the original 8 cases live on verbatim inside `WispritEval.RefineBattery` alongside the scored category cases, gated by `WISPRIT_REHEARSAL=1 swift test --filter RehearsalTests` against `docs/eval/BASELINE.json` and recorded as a scored artifact by `Wisprit eval refine`. | `refine.py`, `packaging/wisprit_refine.swift` |
| `WispritEngine` | FIRST run spike S1 (see below), THEN implement: `AsrEngine` protocol (`begin(onPartial:)`, non-blocking `feed(pcm:)`, `finalize() async -> String`, `cancel()`); `SpeechAnalyzerEngine` (SpeechTranscriber, 16 kHz mono Int16, volatile partials, sub-400 ms finalize); `VocabularyChannel` (DictationTranscriber + `contextualStrings` from `VocabularySource`, **`.frequentFinalization` mandatory** — default options silently yield no final); silence-hallucination drop list and batch-fallback-only-on-crash semantics from `asr.py`/`asr_batch.py`; PCM retention for the off-path reconciliation pass. AVFoundation capture behind `#if os(macOS)` seams so iOS reuses the analyzer layer. | `asr.py`, `asr_batch.py`, `~/MeetingScribe/tools/apple_live.swift` |

## macOS shell targets (Phase 1b)

| Target | Ports / implements | Python spec |
|---|---|---|
| `WispritMacInput` | `HotkeyMonitor`: listen-only CGEventTap exactly per `hotkey.py` — Fn = flagsChanged keycode 63 **AND** flag 0x800000 (flag-only misfires on nav keys); `right_option` alternate (port its documented left-Option masking bug as-is); edge-tracked press/release; dirty-chord cancel; Esc only while recording; global ⌘⌃V paste-last; tap-disable recovery in-callback + 3.0 s watchdog; callback does NOTHING but enqueue. `Inserter`: the full `insert.py` cascade — secure-input block, `AXIsProcessTrusted` gate with exact remedy text, typed unicode injection for terminal bundle IDs (≤20 UTF-16 units, never split a surrogate, 5 ms between chunks), clipboard dance (full snapshot, transient marker, changeCount-conditional restore after `paste_restore_delay_ms`). `InsertResult{ok, method: paste/type/blocked_secure/error, detail}`, never throws. | `hotkey.py`, `insert.py` |
| `WispritMacUI` | `Pill`: `pill.py` 1:1 (26×26 non-activating NSPanel, status level, all-spaces, drag-persist callback, exact colors/radii/auto-hide timings) **PLUS the real `livePartial(text:)`** — display the last few words while recording (the Python was a silent no-op; the engine's onPartial contract delivers monotonically-growing text ready to render). `StatusMenu`: `app.py` menu 1:1 (state glyphs, rebuild-on-open, Dictation toggle, AI Cleanup tri-state row, last-5 recents click-copies 48-char elided, Paste Last, Open Dictionary/Config, Run Doctor, Purge History, Quit) driven entirely by injected closures — no core-target imports. All UI main-thread; expose `callOnMain` discipline. | `pill.py`, `app.py` (UI parts) |
| `WispritMac` | Executable. `SessionController`: `session.py` state machine 1:1 (150 ms debounce silent discard; press: `maybeReload` → audio start → engine begin (partials → pill) → refiner.begin prewarm; release: finalize → **CorrectionDetector.decide on the RAW final, before refine** → refine (interrupt hook: Esc=cancel, queued-press=hurry/preempted) → postprocess → second cancel check → history-before-insert → insert → pill result → one metrics JSONL line). Correction handling v1: suppress directives from output; apply `tailReplace`/same-utterance `retroReplace` before insertion; cross-utterance `retroReplace` = learn + pill notice ("Learned Sharique") — in-field retro-edit of committed text arrives with the Phase-2 IM tier. `Bootstrap` (seed config from `Settings.defaults` via WispritJSON — no literal duplication; seed dictionary per `bootstrap.py`; reuse existing `~/.wisprit` untouched). `Doctor` CLI subcommand: every check in `doctor.py` natively (mic, Input Monitoring probe, AX trust, `CGPreflightPostEventAccess`, `SpeechTranscriber.isAvailable` + locale assets via AsrDoctor, FoundationModels availability, secure-input holder, config/dictionary parse) with exact System Settings remedies. Single-instance via fcntl flock on the SAME `~/.wisprit/wisprit.lock` (guards against the Python app running simultaneously). `scripts/build_app.sh`: release build → assemble `Wisprit.app` (Info.plist: LSUIElement, mic + speech-recognition usage strings) → ad-hoc codesign for dev (Developer ID signing is Phase 4). | `session.py`, `bootstrap.py`, `doctor.py`, `app.py` (wiring), `packaging/make_app.sh` |

## Spike S1 (WispritEngine agent, before writing the engine)

Settle, on this machine, with probes (start from `docs/research/probes/`):
1. Resident analyzer + `finalize(through: nil)` — reliable, or session-per-utterance?
2. `.fastResults`: do partials genuinely lead end-of-audio on utterances ≥ 8 s?
3. `contextualStrings` scale cost on a long-lived DictationTranscriber (n = 50/200/500).
Write findings to `docs/research/spikes-s1.md`; implement whatever won.

## Report format (every agent)

Files written; public API summary; test command + pass counts; golden-parity
status; `// CONTRACT-DEVIATION:` list; anything the integration pass must know.
