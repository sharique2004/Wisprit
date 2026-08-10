# Wisprit

**Fully-local push-to-talk dictation for macOS.** Hold the Fn (🌐) key, speak, release — your words appear at the cursor, cleaned up. No cloud, no account, no subscription, no telemetry, no network calls anywhere in the app. Audio never leaves this Mac, and neither does the text.

Wisprit is a native Swift menu-bar app: one signed bundle, an in-process on-device speech engine, on-device Apple Intelligence cleanup, and an embedded palette input method that can type your words into the field *while you are still speaking*. Everything intelligent in it is Apple's on-device stack (SpeechAnalyzer + FoundationModels). Nothing is sent to a server, by design and by construction.

It began as a competitive research pass on [Wispr Flow](docs/research/wisprflow.md) and the [AI-dictation landscape](docs/research/competitors.md). The headline finding: Wispr's moat is pipeline engineering and LLM cleanup, *not* the acoustic model — and its two biggest user complaints (cloud-only privacy, over-rewriting what you actually said) are structural, not accidental. On an M4 Mac running macOS 26, Apple's on-device stack can do the same job locally with none of that baggage. A [second research pass](docs/research/apps-feasibility.md) settled the native architecture; [spike S1](docs/research/spikes-s1.md) settled the engine.

## How it works

```
hold Fn ──▶ mic (16 kHz mono Int16) ──▶ SpeechAnalyzer, in-process, on the Neural Engine
                │                            │  partials stream into the field (Live Typing)
                │                            │  …or into the floating pill
                │                            └  Apple Intelligence session prewarms in parallel
release ────────┴──▶ finalize ──▶ spoken-spelling detector (on the RAW text)
                                       └─▶ AI cleanup (Apple Intelligence, in a validation cage)
                                              └─▶ deterministic rules (dictionary, commands)
                                                     └─▶ insert at the cursor
                                                     └─▶ local history (text only)
```

- **Streaming during the hold.** A fresh `SpeechTranscriber` + `SpeechAnalyzer` per utterance, `.fastResults` on, `prepareToAnalyze` paid on key-down (31–54 ms). At release only the tail needs finalizing: **69–108 ms release→final** measured over 12 back-to-back utterances ([spike S1](docs/research/spikes-s1.md)). Partials arrive from ~1.0 s into the hold at a ~0.95 s cadence.
- **AI cleanup, still fully local.** The on-device Apple Intelligence foundation model fixes what the recognizer misheard — homophones ("right heavy" → "write-heavy"), split words ("data base"), broken casing ("i phone" → "iPhone") — strips fillers contextually, and punctuates, using the surrounding sentence as evidence. It runs *inside a cage*: an eval-locked instruction prompt, greedy sampling, a word-count plausibility guard, an answered-instead-of-cleaned detector, wrapper/preamble stripping, a hard timeout, and skip rules for utterances containing emails/URLs or spelled letter runs. Every failure path returns the verbatim transcript — cleanup can only ever win, never lose words. Toggle it from the menu (**AI Cleanup**) or `ai_cleanup` in config.
- **Deterministic rules still run after the model** (dictionary corrections, "new line" / "new paragraph" / "scratch that", spoken email/URL joining, whitespace and casing tidy) — so your personal vocabulary is guaranteed by regex, not entrusted to a small model.
- **Privacy is structural.** There is no networking code on any path. Audio is transcribed on the Neural Engine, the language model runs on-device, and nothing is retained: history is transcript text only, in a local SQLite file you can purge from the menu. The state directory is `~/.wisprit`, mode 0700.
- **Every stage is interruptible.** Esc aborts up to and including the model pass; a queued Fn press makes cleanup finish *now* with verbatim text so the next utterance isn't stuck behind the model.

Module contracts live in [docs/SWIFT-INTERFACES.md](docs/SWIFT-INTERFACES.md); the original design rationale (Python era, still the behavioral spec for the deterministic stages) is in [docs/SPEC.md](docs/SPEC.md).

## Live Typing — words in the field, while you speak

Wisprit ships a palette **input method**, `WispritIM.app`, embedded inside `Wisprit.app`. It is the same machinery Apple's own Dictation uses (`DictationIM.app` is an IMKit palette IM), and no shipping competitor uses it.

When it's on, partials go into the focused field as **marked text** — underlined and provisional, replaced wholesale on every update — and the final text is committed as a single `insertText:`, so ⌘Z undoes a chunk rather than fifty keystrokes. It needs neither Accessibility nor a posted keystroke, and it works in terminals.

Insertion is a five-rung ladder, picked per utterance and cached per app:

| Rung | Tier | What you get |
|---|---|---|
| 1 | `im_streaming` | Live underlined tail in the field + committed final |
| 2 | `im_commit` | Client exists but marked text misbehaved (Java/Swing, Qt, some games) — no live tail, one commit at the end |
| 3 | `paste` | The clipboard dance: pill preview while speaking, paste at the end |
| 4 | `type` | Typed Unicode injection for clipboard-hostile apps (`terminal_bundle_ids`) |
| 5 | `blocked_secure` | Secure Event Input holds the keyboard — nothing can insert |

**Turning it on is a deliberate, one-time act.** `live_typing` defaults to `false` and nothing touches your input sources until you choose **Enable Live Typing…** from the menu. That item copies `WispritIM.app` into `~/Library/Input Methods`, registers it, and raises the system's "wants to activate a third-party input method" dialog — that prompt is the point of the item, not an accident of it. Afterwards the menu row becomes a plain checkbox.

**Honest status:** rungs 1–2 are implemented and unit-tested, but the per-app support matrix (TextEdit / Safari / Chrome / Slack / VS Code / Terminal / Notes / Mail) is still being validated on real fields — that's spike S2. The ladder is built to fail safe: any refusal, unreachable process, or lost client falls through to the paste rung, and history is written *before* insertion, so the worst case is always ⌘⌃V. If you want it off entirely for a process, `WISPRIT_NO_IM=1` disables every input-source call.

Retroactive correction of *already-committed* text needs the client to honour an absolute replacement range (TSMDocumentAccess). Where that isn't available, Wisprit refuses the edit rather than appending the "correction" to the end of your field, and falls back to learning the term.

## Spoken spelling corrections

Say the word, then spell it — Wisprit fixes it, never types the spelling, and remembers it forever:

> "Add Sharique to the invite. Actually, it's S-H-A-R-I-Q-U-E."
>
> → *Add Sharique to the invite.* — the directive is suppressed, the misheard word is rewritten, and `Sharique` (with `"Shariq"` recorded as a misrecognition) lands in your dictionary.

How it actually works, and why it's safe:

- **Detection is a regex, not a model.** Apple's inverse text normalization emits spelled runs as uppercase tokens (`S-H-A-R-I-Q-U-E`; sometimes glued or space-broken — uppercase is the invariant). Measured under 0.1 ms. FoundationModels as the detector was tried and is strictly worse (759–2325 ms, wrong 3–4 out of 10).
- **It runs on the RAW transcript, before AI cleanup.** The model deterministically corrupts spelled runs ("S-H-A-R-I-Q-U-E" → "Sharifue"), so the refine stage also carries a hard letter-run bypass (`has_letter_run` in metrics).
- **Trigger phrases are a confidence booster, never a gate** — "that's spelled" is itself frequently misrecognized ("Let's spell").
- **Antecedent matching** ("which word did they mean?") is a hybrid phonetic scorer: `max(0.6 · DoubleMetaphone-code similarity + 0.4 · Jaro-Winkler, 0.9 · Jaro-Winkler)`, threshold 0.62.
- **Three-way outcome, and only one of them touches text you can already see.** Trigger *and* a confident antecedent → retroactive replace. Confident antecedent, no trigger, run at the tail of this utterance → replace the tail only. Anything weaker — a genuinely dictated "J-S-O-N", or a name mangled past phonetic recovery (Krzysztof → "Cherie", score 0.38) — is **inserted literally** and offered passively. Wisprit never retro-deletes a word without a confident antecedent, because deleting a correct word is the worst failure a dictation app has.
- **Learning needs no phoneme model.** The ASR's own wrong output *is* the pronunciation evidence: it goes straight into the term's `hear` list, which feeds both the regex pass and the `contextualStrings` biasing channel.

The biasing channel is real, and it is the reason learning improves *recognition* and not just correction: `DictationTranscriber` + `contextualStrings` flipped "Hi Cherie" → "Hi Sharique" in an A/B probe on this machine, where `SpeechTranscriber` produced byte-identical output with and without the same context. That channel runs off the paste path, over retained PCM, after your text is already inserted — it costs ~3.1 ms/term in setup and nothing in decoding, so the whole dictionary ships, no cap.

## Requirements

- Apple Silicon Mac (built and tuned on an M4) running **macOS 26 (Tahoe)** or later — required for SpeechAnalyzer and FoundationModels.
- **Apple Intelligence enabled** (System Settings ▸ Apple Intelligence & Siri) for the on-path cleanup and Polish. Without it, dictation still runs the full deterministic pipeline; doctor reports it as a warning, not a failure.
- Xcode 26 / Swift 6 toolchain to build.
- Nothing else. No Python, no venv, no downloaded models, no external helpers — the app is one self-contained bundle.

## Build & run

```sh
cd ~/Wisprit
./scripts/build_app.sh --install     # → /Applications/Wisprit.app
open /Applications/Wisprit.app
```

`build_app.sh` release-builds `WispritMac`, assembles `Wisprit.app` (LSUIElement agent, mic + speech usage strings, icon), builds and embeds `WispritIM.app` at `Contents/Library/InputMethods/`, ad-hoc signs, and registers with LaunchServices. Useful flags: `--out DIR`, `--debug`, `--no-im`.

**Use `--install`, or pick one path and stay there.** TCC grants attach to a bundle *at a path*; assembling into a different directory creates a different identity and macOS silently drops the grants.

Then run the self-check:

```sh
/Applications/Wisprit.app/Contents/MacOS/Wisprit doctor
```

Doctor names every missing permission and the exact System Settings pane that fixes it, and exits non-zero until the required ones are green. Don't skip it — most "nothing happens" reports are a missing grant, and the failure is otherwise silent.

### Permissions checklist (one-time, manual)

macOS will not let an app grant these to itself. In order:

1. **System Settings ▸ Keyboard ▸ "Press 🌐 key to" → "Do Nothing"** — frees the Fn key for push-to-talk; otherwise macOS Dictation or the emoji picker intercepts it.
2. **Privacy & Security ▸ Microphone** → enable for **Wisprit** (you're prompted on first launch).
3. **Privacy & Security ▸ Accessibility** → add and enable `Wisprit.app` — required to post the ⌘V paste event.
4. **Privacy & Security ▸ Input Monitoring** → add and enable `Wisprit.app` — required for the event tap that watches the Fn key; without it the tap installs and silently sees nothing.
5. If the macOS **Dictation shortcut** is also bound to Fn: System Settings ▸ Keyboard ▸ Dictation → change it, or Off.
6. Re-run `Wisprit doctor` until it says **READY**.
7. *Optional:* menu ▸ **Enable Live Typing…** to install the input method and approve the one activation dialog.

What doctor checks: Accessibility, Input Monitoring, post-event access (`CGPreflightPostEventAccess`), Microphone, Secure Keyboard Entry, `SpeechTranscriber` availability + installed locale assets, Apple Intelligence availability, the input method (registered / enabled / bridge reachable / bundle plist keys), and `config.json` + `dictionary.json` parse. It also prints the two things it can't check: the 🌐-key setting, and that Fn often isn't delivered at all on external keyboards.

## Usage

| Action | How |
|---|---|
| Dictate | **Hold Fn (🌐)**, speak, release. Holds shorter than 150 ms are discarded as accidental brushes. |
| Cancel mid-dictation | **Esc** while recording or finalizing — audio is discarded, nothing is inserted, no metrics row. |
| Paste last transcript | **⌘⌃V** — the recovery path if an insert failed or you dictated into the wrong window. |
| Polish last | Menu ▸ **Polish Last** ▸ Clean up / Make formal / Make casual / As an AI prompt. |
| Everything else | The menu-bar icon. |

The menu, top to bottom: **Dictation On/Off** · **AI Cleanup (Apple Intelligence)** · **Polish Last ▸** · the **Live Typing** row · *Recent transcripts* (last 5, click to copy, elided at 48 characters) · **Paste Last Transcript (⌘⌃V)** · **Open Dictionary…** · **Open Config…** · **Run Doctor…** · **Purge History** · **Quit Wisprit**. The icon reflects state: 🎙 idle, 🔴 recording, … finalizing, ⌨ inserting.

**Polish Last** is the opt-in rewrite tier — deliberately *off* the dictation path, so verbatim text still lands instantly. Pick a mode and Wisprit runs your last transcript through the same on-device model in its own cage, then puts the result **on your clipboard** (⌘V to paste) with a notice. On any failure the clipboard is left alone. The transcript is passed as delimited *data* behind hardened instructions, so a dictated imperative like "ignore that and write a poem" gets **cleaned, not obeyed**; refusals, non-rewrites, and model preamble are all caught before anything reaches your clipboard.

While you hold Fn, a small **floating pill** shows a red recording dot, live input level, and the last few words of the in-progress transcript. Drag it anywhere; the position persists. On release it shows a spinner, then flashes green (inserted) or amber (with a reason), and it's also where notices like "Learned Sharique" appear. When Live Typing is actually streaming into the field, the pill's word preview is suppressed so the same words never appear twice — and if the field is lost mid-utterance, the preview hands straight back to the pill.

In terminals (Terminal, iTerm2, WezTerm, kitty, Alacritty, Ghostty) Wisprit types the text as keystrokes instead of pasting, avoiding bracketed-paste and ⌘V weirdness. The set is configurable (`terminal_bundle_ids`). On rung 1 the input method handles terminals natively, which retires the special case.

Only one Wisprit may run at a time — `~/.wisprit/wisprit.lock` is an flock shared with the legacy Python build, so the two can't both paste on every release. External keyboards without a real Fn key can set `"hotkey": "right_option"`.

## Configuration — `~/.wisprit/config.json`

Created with defaults on first run (or `Wisprit bootstrap`); edit and it's picked up (some keys need a restart). Keys the app doesn't recognize are preserved and re-emitted, so a config edited by a newer build round-trips intact.

| Key | Default | Meaning |
|---|---|---|
| `hotkey` | `"fn"` | Push-to-talk key: `"fn"` or `"right_option"`. |
| `hold_debounce_ms` | `150` | Holds shorter than this are discarded as accidental. |
| `locale` | `"en-US"` | SpeechAnalyzer locale. Must be in the installed set (doctor lists it). |
| `finalize_timeout_ms` | `1500` | Max wait for the final transcript after release; on timeout the last partial is used. |
| `filler_removal` | `true` | Strip isolated `um`, `uh`, `uhh`, `erm`, `uhm`. Conservative — never touches "like" or "so". |
| `ensure_sentence_period` | `false` | Append a period if the utterance ends without terminal punctuation. |
| `leading_space` | `"auto"` | Space before inserted text: `"auto"`, `"always"`, `"never"`. |
| `terminal_bundle_ids` | Terminal, iTerm2, WezTerm, kitty, Alacritty, Ghostty | Apps that get typed injection instead of paste. |
| `pill_position` | `null` | `[x, y]` once you drag the pill; `null` = bottom-center. |
| `pill_hidden` | `false` | Hide the pill entirely (the menu-bar glyph still mirrors state; the level ticker is skipped). |
| `history_enabled` | `true` | Keep transcript text in `~/.wisprit/history.sqlite`. |
| `history_limit` | `1000` | Max stored transcripts; oldest trimmed. |
| `engine` | `"auto"` | `"auto"`/`"apple_live"` use SpeechAnalyzer. `"mlx_whisper"` / `"faster_whisper"` are accepted for config compatibility but currently map to an unbuilt batch slot — see [Roadmap](#roadmap). |
| `ai_cleanup` | `true` | On-path Apple Intelligence refinement (also the menu toggle). |
| `ai_cleanup_max_words` | `350` | Longer transcripts skip cleanup — input, instructions and output share one 4096-token context. Also the Polish word cap. |
| `ai_cleanup_timeout_ms` | `12000` | Hard cap on the model pass; verbatim text wins on timeout. |
| `mlx_model` | `"mlx-community/whisper-large-v3-turbo"` | Vestigial: read by nothing in the native build, kept so an existing config round-trips. |
| `paste_restore_delay_ms` | `500` | Delay before restoring your original clipboard after the paste. Generous on purpose: restoring too early makes the target app paste your *old* clipboard — the #1 bug across competing tools. |
| `enabled` | `true` | Master toggle (also in the menu). |

Live Typing keys (seeded with the rest; toggled from the menu):

| Key | Default | Meaning |
|---|---|---|
| `live_typing` | `false` | Rungs 1–2 of the insertion ladder. Set by **Enable Live Typing…** / the **Live Typing** checkbox. Nothing touches an input source while this is off. |
| `im_selection_policy` | `"warm"` | `"warm"` keeps the palette source selected between utterances (what keeps the process hot); `"per_utterance"` selects on Fn-down and releases on Fn-up, paying a cold start. |

## Custom dictionary — `~/.wisprit/dictionary.json`

Your vocabulary, used twice: as `contextualStrings` biasing for the vocabulary channel, and — the guaranteed net — as post-ASR whole-word corrections. The file hot-reloads on the next key-down after you save it, no restart.

```json
{
  "terms": [
    { "term": "InsForge",   "hear": ["in forge", "ins forge"] },
    { "term": "Wispr Flow", "hear": ["whisper flow", "wisper flow"] },
    { "term": "Sharique",   "hear": ["Shariq", "Cherie"],
      "source": "spoken_spelling", "learned_at": "2026-08-05T09:12:00Z",
      "hit_count": 3, "last_used": "2026-08-05T11:44:10Z" }
  ]
}
```

- `term` — the canonical spelling you want in your text. Every term also self-corrects casing (`"insforge"` → `"InsForge"`).
- `hear` — misrecognitions to correct (case-insensitive, whole words only, longest match first).
- `source`, `learned_at`, `hit_count`, `last_used` — **additive** extension fields written by the learn loop. `source` is `spoken_spelling` for a term Wisprit learned from you spelling it out, `manual` otherwise. `hit_count` × recency ranks the vocabulary list. Hand-written entries that predate these fields round-trip byte-identically, including keys this build has never heard of.

First run seeds the file with this machine's known vocabulary (Wisprit, Wispr Flow, InsForge, MeetingScribe, Claude, Anthropic, MLX, Sharique, Khatri, hackathon, Penn State). **Open Dictionary…** opens it in your editor.

Other files in `~/.wisprit/`: `history.sqlite` (transcript text only), `metrics.log` (one JSON line per utterance: stage latencies, insertion tier, AI outcome), `wisprit.log`, `wisprit.lock`.

## Troubleshooting

| Symptom | Cause & fix |
|---|---|
| Dictation stopped working after a rebuild | **The TCC identity gotcha, now bundle-shaped.** Accessibility and Input Monitoring grants attach to the bundle at its path. Assembling into `./dist` and then into `/Applications` is two identities; so is moving the app. Fix: build with `--install` so the path stays `/Applications/Wisprit.app`, then re-add it in both panes (remove the stale entry first). `Wisprit doctor` prints the executable path it's actually running from, and names what's missing. |
| Fn does nothing at all | System Settings ▸ Keyboard ▸ **"Press 🌐 key to" must be "Do Nothing"**; also move or disable the macOS Dictation shortcut if it's on Fn. On most external/non-Apple keyboards Fn isn't delivered to apps at all — set `"hotkey": "right_option"`. |
| Hotkey silently dead, doctor says the tap is fine | A **ghost tap**: the event tap exists but delivers nothing, which is what a revoked or half-granted Input Monitoring looks like. A 3-second watchdog re-enables a disabled tap and logs a one-shot ghost warning rather than spamming every tick. If you see it, re-grant Input Monitoring to the current bundle and relaunch. |
| Hotkey dead only in one app (often Slack, or at password prompts) | That app has **Secure Keyboard Entry** on, which blinds event taps system-wide while it's focused — and defeats the input-method rungs too (TN2150). Wisprit detects it and says so on the pill instead of failing silently, but it cannot be engineered around. Your words are never lost: dictate elsewhere, or use ⌘⌃V later. In Slack: Slack menu ▸ uncheck Secure Keyboard Entry. |
| Live Typing row says "Enable Live Typing…" after you already enabled it | macOS hasn't registered the input method, or the activation dialog wasn't approved. Choose the item again — it re-registers — or log out and back in. Doctor's three Live Typing rows (input method / bridge / bundle) tell you which stage failed. |
| Live Typing enabled but doctor says the bridge isn't answering | The input method process only launches when Wisprit selects it, which happens when you start dictating. Hold the dictation key once, then re-run doctor. |
| Words appear twice, or in the wrong place, with Live Typing | Report the app — that's exactly the per-app matrix spike S2 is validating. Immediate workaround: uncheck **Live Typing** (drops to paste), or launch with `WISPRIT_NO_IM=1` to disable every input-source call for that process. |
| Clipboard contents occasionally clobbered | A **clipboard manager** racing the restore window (Wisprit swaps your clipboard for ~500 ms around the paste, verifies `changeCount` before restoring, and marks the write `org.nspasteboard.TransientType` so well-behaved managers skip it). Every transcript is saved to history *before* insertion, so nothing is lost — but if your manager misbehaves, raise `paste_restore_delay_ms` or exclude it from watching transient changes. |
| Pasted text garbled or bracketed in a terminal | Wisprit should be *typing* into terminals, not pasting. If you use one that isn't in the default set, add its bundle ID to `terminal_bundle_ids`. |
| Doctor: "SpeechTranscriber" red | Either the API is unavailable on this machine, or your `locale` isn't in the installed asset set — doctor lists what is installed. Note that `AssetInventory.status` is printed but **advisory only**: it reports `supported`, not `installed`, on machines where transcription demonstrably works, so it is never used as a gate. |
| Noticeable pause after release, or truncated tails | Check `~/.wisprit/metrics.log` for the slow stage. A finalize exceeding `finalize_timeout_ms` falls back to the last partial (`timed_out: true`). If the model pass is the culprit, lower `ai_cleanup_timeout_ms` or turn **AI Cleanup** off — verbatim text is always the fallback. |
| A spelled name got typed out literally instead of correcting a word | By design: no antecedent scored above 0.62, so Wisprit inserted the letters rather than deleting a word it wasn't sure about. Add the term to `dictionary.json` (or say it again in a sentence where the misheard version is present). |
| Mic indicator stays on between dictations | It shouldn't — the input stream is fully closed on release. If the orange dot persists, another app holds the mic; check Control Center. |

## How it compares (honestly)

Drawn from the research pass in [docs/research/competitors.md](docs/research/competitors.md) — mid-2026 snapshot.

| | **Wisprit** | Wispr Flow | Superwhisper | VoiceInk | Handy |
|---|---|---|---|---|---|
| Price | Free (your own repo) | $12–15/mo | $8.49/mo or $249 lifetime | $39.99 once / free from source | Free (MIT) |
| Processing | 100% local (Neural Engine + on-device LLM) | Cloud only — no offline mode | Local-first, optional cloud/BYOK | Local, optional BYOK cloud | Local only |
| Live text while speaking | **Yes — underlined, in the field itself** (input-method tier); pill preview otherwise | No — block paste after release | No | No | No |
| Release→final (ASR) | **69–108 ms measured** ([spike S1](docs/research/spikes-s1.md)); cleanup adds a variable on-device model pass, not yet benchmarked end-to-end | <700 ms p99 target; ~1–2 s perceived | Model/hardware-dependent | Model-dependent | 2–5 s reported |
| Cleanup philosophy | On-device Apple Intelligence in a validation cage (verbatim wins on any doubt); deterministic rules after; on-device Polish opt-in | Best-in-class LLM cleanup, but rewrites what you said; no verbatim mode | Custom modes + BYOK prompts (config-heavy) | BYOK "AI Enhancement" | None — raw transcript |
| Custom vocabulary | Yes — ASR biasing **and** post-ASR correction, hot-reload, **learned by spelling a word aloud** | Yes, plus passive learning | Via mode prompts | Limited | No |
| Privacy posture | No network code on any path, no telemetry, text-only history, mic hard-off between utterances | Screenshot/tracking controversies; cloud subprocessors; 2.7/5 Trustpilot | Good (local-first, closed source) | Good (GPLv3) | Excellent (MIT, zero telemetry) |
| Platforms | macOS 26+, Apple Silicon (iOS in progress) | Mac, Windows, iOS, Android | Mac, iOS, Windows | Mac | Mac, Windows, Linux |
| Where it's weaker | No mobile yet; manual TCC setup; English-first; hands-free mode still on the roadmap; per-app Live Typing coverage still being validated | — | — | — | — |

The honest summary: if you need cross-device sync, 100+ languages, or Wispr's zero-config prose polish, Wisprit isn't that. If you want Wispr's core interaction — hold a key, talk, get clean text — with live text in the field, a dictionary that learns names when you spell them, and the structural guarantee that nothing you say ever reaches a server, that's exactly what this is.

## Changes from the Python prototype

The Python package in [`wisprit/`](wisprit/) is the **legacy reference implementation**. It is kept in-repo because the Swift core was ported against it 1:1, with its test fixtures as the golden-parity suite. It is not the shipping app and its workflow is not documented here. What changed:

- **The engine is in-process — no helpers, no interpreter.** The `apple_live` subprocess, the `wisprit_refine` self-compiling helper, and the MeetingScribe venv are all gone. `Contents/MacOS/Wisprit` is the real compiled executable, which is also what makes TCC grants stick to one stable identity.
- **Polish is on-device.** The old "Polish with Claude" shelled out to the `claude` CLI; its replacement is **Polish Last** — the same four modes (Clean up / Make formal / Make casual / As an AI prompt), same menu keys, running on Apple Intelligence. Wisprit makes no network calls of any kind.
- **The fallback chain is not ported.** mlx-whisper and faster-whisper are gone with the venv; the batch-recovery slot is a stub that reports itself unavailable, and WhisperKit large-v3-turbo is planned for it ([Roadmap](#roadmap)). Until it ships there is **no second engine** — the previous README's "dictation never fully dies" claim no longer holds. Batch recovery was already crash-only (never triggered by an empty or silent result), so behavior on silence is unchanged: nothing is inserted.
- **Live partials in the pill are real.** In the Python build `livePartial` was a silent no-op; the native engine's partial contract delivers monotonically growing text, and it renders — in the pill, or straight into the field on rung 1.
- **New: spoken-spelling correction and the learn loop**, plus the `has_letter_run` refine bypass they depend on.
- **New: the insertion ladder and the embedded input method.** Rungs 3–5 are the Python `insert.py` cascade, kept byte-for-byte.
- **Doctor's checks moved with the code**: the `apple_live` probe, the mlx-whisper import check, and the `swiftc`/helper-binary checks are replaced by `SpeechTranscriber` availability + installed locales, FoundationModels availability, and the three input-method checks. Every remedy string carried over unchanged.
- **`metrics.log` is one continuous stream** across the cutover — same field names, same AI outcome vocabulary (plus `has_letter_run`), same `history.sqlite` schema and `config.json` keys. `wisprit.lock` is shared, so the two builds cannot run at once.

## Roadmap

Phases are from [docs/research/apps-feasibility.md](docs/research/apps-feasibility.md).

- **Now (Phase 2):** live in-field streaming + corrections on Mac. Implemented; per-app validation (spike S2) in progress.
- **Next (Phase 3):** the **iOS app** — container app + App Intents first, then a keyboard extension streaming `setMarkedText` partials. Not started. The architecture is constrained by a hard fact: keyboard extensions cannot access the microphone, so the container app must be the recorder. Also Phase 3: **WhisperKit large-v3-turbo** as the long-tail-language batch engine, shipped as an on-demand asset pack.
- **Phase 4 — distribution.** The primary channel is **Developer ID + notarized direct download**, which is what every serious competitor uses and what the input method requires: App Store Guideline 2.4.5(ii) forbids installing into `~/Library/Input Methods`, and `TISRegisterInputSource` accepts no other location. A reduced **Mac App Store SKU** is possible as an optional second channel — it would enter the insertion ladder at rung 3 and give up the Fn hotkey (`RegisterEventHotKey` can't bind Fn), so it is a maybe, not a plan. Today's builds are ad-hoc signed for development.
- **Standing risk:** every macOS point release can silently change the refine model and the ITN spelling behavior. Both the refine prompt and the correction detector have eval batteries that must be re-run per OS update.

## Development

```sh
swift build                                   # whole package
swift test                                    # eleven test targets, all offline
swift test --filter WispritCorrectionsTests   # one target
WISPRIT_REHEARSAL=1 swift test --filter RehearsalTests   # live Apple Intelligence batteries
./scripts/build_app.sh                        # → ./dist/Wisprit.app
./scripts/build_im.sh --visible               # input method you can select by hand
```

CLI surface of the app binary:

```sh
Wisprit                  # the menu-bar app
Wisprit doctor           # permission + engine checklist (exit 0 when ready)
Wisprit bootstrap        # create ~/.wisprit and seed config + dictionary
Wisprit hotkey [secs]    # print raw hotkey events   (needs WISPRIT_MANUAL_INPUT=1)
Wisprit insert "text"    # insert after a 3 s countdown (same gate)
Wisprit --version
```

The manual smoke tests that post real events or touch real input sources are gated behind `WISPRIT_MANUAL_INPUT=1` / `WISPRIT_MANUAL_IM=1` so they can never fire during an ordinary `swift test`. The live Apple Intelligence batteries are gated behind `WISPRIT_REHEARSAL=1` for the same reason: the refine one scores every case in `WispritEval.RefineBattery` against `docs/eval/BASELINE.json`, and `Wisprit eval refine` is what records a new accepted number.

Repo layout: `Sources/` (one SPM target per concern — core targets are platform-neutral for the iOS shell, `WispritMac*` are the macOS shell, `WispritIM*` the input method), `tests/` (mirrored test targets + the Python-era fixtures), `scripts/` (bundle builders), `docs/` (contracts, spikes, research), `wisprit/` (legacy Python reference implementation), `packaging/` (icon generator, privacy manifest, and Python-era leftovers).
