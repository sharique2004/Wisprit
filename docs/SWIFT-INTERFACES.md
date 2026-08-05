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
| `WispritPostProcess` | The seven ordered deterministic stages: filler removal → dictionary corrections (via `CorrectionApplying`) → spoken-email join (freemail/dotted-local guards) → spoken-URL join (11-TLD allowlist) → voice commands (new line/paragraph, scratch that) → whitespace/casing tidy → leading-space policy. `PostProcessOptions` struct owns the config flags. | `postprocess.py` |
| `WispritDictionary` | `DictionaryStore`: load + hot-reload (mtime) of `dictionary.json`; compiled longest-first, `\s+`-relaxed, case-insensitive whole-word corrections; self-casing; conforms to `CorrectionApplying` + `VocabularySource`; `add(_ learned: LearnedTerm)` with additive schema `{source, learned_at, hit_count, last_used}`; atomic writes. | `dictionary.py` |
| `WispritCorrections` | NEW feature, from research §correction-detection: letter-run detector (uppercase-run regex on raw ASR finals, collapsed length ≥3, alphabetic segments, not-already-known via `VocabularySource`); trigger-phrase scan (confidence booster, never a gate); vendored Double Metaphone + Jaro-Winkler; antecedent scorer `max(0.6·codeSim + 0.4·JW, 0.9·JW)`, threshold 0.62; three-way `CorrectionAction` (retroReplace / insertLiterally+offer / tailReplace); emits `LearnedTerm`. Test cases: Sharique/Shariq/Cherie, Krzysztof→"Cherie" (must be no-candidate), J-S-O-N (must never retro-delete), the 12+8 scorer pairs from the research. | (new) |
| `WispritPersistence` | `Settings` (exact DEFAULTS keys, atomic persist, reload); `History` (SQLite via system `SQLite3`, **schema-compatible with existing `~/.wisprit/history.sqlite`**, add/recent/purge/trim-to-limit, text-only); `MetricsWriter` (JSONL, same field names as Python so `metrics.log` stays one stream). | `settings.py`, `history.py`, + metrics emission in `session.py` |
| `WispritRefine` | The Apple Intelligence cage, **in-process** via FoundationModels (no subprocess): prewarm-on-press; the eval-locked instruction prompt from `packaging/wisprit_refine.swift` **verbatim — do not reword**; greedy sampling; word-count plausibility guard; answered-instead-of-cleaned detector; wrapper/preamble stripping fixpoint; hard timeout; `_has_address` skip; **NEW `_has_letter_run` skip** (research: the model corrupts spelled runs); 13-value outcome vocabulary; verbatim-always-wins. Port `tests/rehearsal_refine.sh`'s 8 cases into a Swift-runnable rehearsal battery. | `refine.py`, `packaging/wisprit_refine.swift` |
| `WispritEngine` | FIRST run spike S1 (see below), THEN implement: `AsrEngine` protocol (`begin(onPartial:)`, non-blocking `feed(pcm:)`, `finalize() async -> String`, `cancel()`); `SpeechAnalyzerEngine` (SpeechTranscriber, 16 kHz mono Int16, volatile partials, sub-400 ms finalize); `VocabularyChannel` (DictationTranscriber + `contextualStrings` from `VocabularySource`, **`.frequentFinalization` mandatory** — default options silently yield no final); silence-hallucination drop list and batch-fallback-only-on-crash semantics from `asr.py`/`asr_batch.py`; PCM retention for the off-path reconciliation pass. AVFoundation capture behind `#if os(macOS)` seams so iOS reuses the analyzer layer. | `asr.py`, `asr_batch.py`, `~/MeetingScribe/tools/apple_live.swift` |

## Spike S1 (WispritEngine agent, before writing the engine)

Settle, on this machine, with probes (start from `docs/research/probes/`):
1. Resident analyzer + `finalize(through: nil)` — reliable, or session-per-utterance?
2. `.fastResults`: do partials genuinely lead end-of-audio on utterances ≥ 8 s?
3. `contextualStrings` scale cost on a long-lived DictationTranscriber (n = 50/200/500).
Write findings to `docs/research/spikes-s1.md`; implement whatever won.

## Report format (every agent)

Files written; public API summary; test command + pass counts; golden-parity
status; `// CONTRACT-DEVIATION:` list; anything the integration pass must know.
