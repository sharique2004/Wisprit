# Wisprit

**Fully-local push-to-talk dictation for macOS.** Hold the Fn (🌐) key, speak, release — your words appear at the cursor, cleaned up, in well under half a second. No cloud, no account, no subscription, no telemetry. Audio never leaves this Mac.

Wisprit was born from a competitive research pass on [Wispr Flow](docs/research/wisprflow.md) and the [AI-dictation landscape](docs/research/competitors.md). The headline finding: Wispr's moat is pipeline engineering and LLM cleanup, *not* the acoustic model — and its two biggest user complaints (cloud-only privacy, over-rewriting what you actually said) are structural, not accidental. On an M4 Mac running macOS 26, Apple's on-device SpeechAnalyzer engine plus deterministic cleanup rules can beat Wispr's own latency target locally, with none of that baggage. So this repo does exactly that.

## How it works

```
hold Fn ──▶ mic (16 kHz) ──▶ apple_live helper (SpeechAnalyzer, Neural Engine)
                │                      │  live partial words stream to the pill
release ────────┴──▶ finalize ──▶ rule cleanup (<20 ms) ──▶ paste at cursor
                                                        └──▶ local history (text only)
```

- **Streaming during the hold.** ASR runs on the Neural Engine *while you speak*, so at release only the tail needs finalizing. Target: **<400 ms p90 release-to-text** — vs Wispr's <700 ms p99 engineering target and its 1–2 s user-perceived reality.
- **Verbatim-first.** Default output is the transcript plus deterministic rules only (filler removal, dictionary corrections, "new line" commands, spoken email/URL joining). No LLM ever rewrites your words unless you explicitly ask (opt-in "Polish with Claude" via the local `claude` CLI).
- **Privacy is structural.** No network sockets anywhere in the pipeline. No audio retention. History is transcript text only, in a local SQLite file you can purge from the menu.
- **Fallback chain.** If the SpeechAnalyzer helper dies, Wisprit transparently falls back to mlx-whisper `large-v3-turbo`, then faster-whisper, so dictation never fully dies.

Full design rationale lives in [docs/SPEC.md](docs/SPEC.md); module contracts in [docs/INTERFACES.md](docs/INTERFACES.md).

## Requirements

Wisprit is deliberately a **single-machine app** tuned for this setup:

- Apple Silicon Mac (built and tuned on an M4 MacBook) running **macOS 26 (Tahoe)** — needed for the SpeechAnalyzer API.
- The **MeetingScribe venv** at `~/.meetingscribe/venv` (Python 3.11 with pyobjc, sounddevice, numpy, mlx-whisper, faster-whisper). Wisprit reuses it; there is no separate install step.
- The compiled **`apple_live`** SpeechAnalyzer helper at `~/.meetingscribe/bin/apple_live` (source: `~/MeetingScribe/tools/apple_live.swift`).
- Optional: the `claude` CLI on PATH for the opt-in polish feature (uses your Claude Code subscription — no API key).

## Quick start

```sh
cd ~/Wisprit
./run.command            # or: ~/.meetingscribe/venv/bin/python -m wisprit
```

First launch creates `~/.wisprit/` with a default `config.json` and a starter `dictionary.json`, then macOS will start prompting for permissions. Work through the checklist below, then run the self-check:

```sh
~/.meetingscribe/venv/bin/python -m wisprit doctor
```

Doctor names every missing permission and the exact System Settings pane that fixes it. Don't skip it — most "nothing happens" reports are a missing grant, and the failure is otherwise silent.

## Permissions & setup checklist (one-time, manual)

macOS will not let an app grant these to itself. In order:

1. **System Settings → Keyboard → "Press 🌐 key to" → set to "Do Nothing"** — frees the Fn key for Wisprit's push-to-talk; otherwise macOS Dictation or the emoji picker intercepts it.
2. **System Settings → Privacy & Security → Microphone** → enable for the terminal app / venv python3 that runs Wisprit (you'll be prompted automatically on first recording).
3. **System Settings → Privacy & Security → Accessibility** → add and enable the venv python3 binary (`~/.meetingscribe/venv/bin/python`) — required for posting the Cmd+V paste event.
4. **System Settings → Privacy & Security → Input Monitoring** → add and enable the same venv python3 binary — required for the event tap that watches the Fn key; without it the tap silently fails.
5. If the macOS **Dictation shortcut** is also bound to Fn: System Settings → Keyboard → Dictation → set the shortcut to something else, or Off.
6. Verify SpeechAnalyzer language assets are installed (they should be, from MeetingScribe): run `python -m wisprit doctor`, which pipes 2 s of silence through `apple_live` and reports status.
7. *Optional (recommended once stable):* start Wisprit at login via the launchd template — see [Autostart](#autostart-launchd).
8. **After ANY Python/venv update or recreation: re-grant Accessibility and Input Monitoring to the new python3 binary.** TCC grants are per-binary; doctor will detect and name the missing grant. This is the #1 gotcha — see Troubleshooting.

## Usage

| Action | How |
|---|---|
| Dictate | **Hold Fn (🌐)**, speak, release. Holds shorter than 150 ms are ignored (accidental brushes). |
| Cancel mid-dictation | **Esc** while recording — audio is discarded, nothing is inserted. |
| Paste last transcript | **Cmd+Ctrl+V** — the recovery path if a paste failed or you dictated into the wrong window. |
| Everything else | Menu bar icon: enable/disable, last 5 transcripts (click to copy), paste last, open dictionary/config, run doctor, purge history, quit. |

Opt-in **"Polish with Claude"** (LLM tone transforms via the local `claude` CLI, no API key) is the first planned post-MVP feature — the deterministic verbatim pipeline ships first, on purpose.

While you hold Fn, a small **floating pill** shows a red recording dot, live input level, and the last few words of the in-progress transcript — streaming feedback Wispr never shows. Drag the pill anywhere; the position persists. On release it briefly shows a spinner, then flashes green (inserted) or amber (with a reason).

In terminals (Terminal, iTerm2, WezTerm, kitty, Alacritty, Ghostty) Wisprit types the text as keystrokes instead of pasting, avoiding bracketed-paste and Cmd+V weirdness. The set is configurable (`terminal_bundle_ids`).

Hands-free toggle (double-tap Fn) is planned as the first post-MVP follow-up; external keyboards without a real Fn key can set `"hotkey": "right_option"` today.

## Configuration reference — `~/.wisprit/config.json`

Created with defaults on first run; edit and it's picked up (some keys need a restart).

| Key | Default | Meaning |
|---|---|---|
| `hotkey` | `"fn"` | Push-to-talk key: `"fn"` or `"right_option"` (external keyboards). |
| `hold_debounce_ms` | `150` | Holds shorter than this are discarded as accidental. |
| `locale` | `"en-US"` | SpeechAnalyzer locale. |
| `finalize_timeout_ms` | `1500` | Max wait for the final transcript after release; on timeout the last partial is used. |
| `filler_removal` | `true` | Strip isolated `um`, `uh`, `uhh`, `erm`, `uhm` tokens. Conservative — never touches "like" or "so". |
| `ensure_sentence_period` | `false` | Append a period if the utterance ends without terminal punctuation. |
| `leading_space` | `"auto"` | Space before inserted text: `"auto"`, `"always"`, or `"never"`. |
| `terminal_bundle_ids` | Terminal, iTerm2, WezTerm, kitty, Alacritty, Ghostty | Apps that get typed injection instead of paste. |
| `pill_position` | `null` | `[x, y]` once you drag the pill; `null` = bottom-center. |
| `pill_hidden` | `false` | Hide the pill entirely (menu-bar icon still mirrors state). |
| `history_enabled` | `true` | Keep transcript text in `~/.wisprit/history.sqlite`. |
| `history_limit` | `1000` | Max stored transcripts; oldest trimmed. |
| `engine` | `"auto"` | `"auto"` (apple_live with fallback), or force `"apple_live"` / `"mlx_whisper"` / `"faster_whisper"`. |
| `mlx_model` | `"mlx-community/whisper-large-v3-turbo"` | Model for the mlx-whisper fallback/accuracy path. |
| `paste_restore_delay_ms` | `500` | Delay before restoring your original clipboard after the paste. Kept generous because restoring too early makes the target app paste your *old* clipboard — the #1 bug across competing tools. |
| `enabled` | `true` | Master toggle (also in the menu). |

## Custom dictionary — `~/.wisprit/dictionary.json`

Your vocabulary, applied twice: terms are fed to the ASR engine for recognition biasing (`apple_live --context`), *and* enforced as post-ASR corrections. The file hot-reloads on save — no restart.

```json
{
  "terms": [
    { "term": "InsForge",   "hear": ["in forge", "ins forge"] },
    { "term": "Wispr Flow", "hear": ["whisper flow", "wisper flow"] }
  ]
}
```

- `term` — the canonical spelling you want in your text.
- `hear` — misrecognitions to correct (case-insensitive, whole words only). Every `term` also self-corrects casing automatically (`"insforge"` → `"InsForge"`), so `hear` is only for genuinely different-sounding output.

First run seeds it with this machine's known vocabulary (InsForge, MeetingScribe, Wispr Flow, Claude, Anthropic, MLX, Sharique, Khatri, …). Add terms from the menu bar or edit the file directly.

Other files in `~/.wisprit/`: `history.sqlite` (transcript text only), `metrics.log` (per-utterance stage latencies, one JSON line each), `wisprit.log` (app log).

## Autostart (launchd)

A launchd agent template ships at [`packaging/com.wisprit.app.plist`](packaging/com.wisprit.app.plist). It is inert until you install it, and the file's header comments contain the exact install/status/uninstall commands. Run Wisprit manually at least once first — launchd can't answer TCC permission prompts for you.

## Troubleshooting

| Symptom | Cause & fix |
|---|---|
| Dictation stopped working after updating/recreating the Python venv | **The TCC identity gotcha.** Accessibility and Input Monitoring grants attach to the exact python3 *binary*. A new venv or Python update is a new binary, so macOS silently revokes everything and the event tap just fails. Fix: re-add `~/.meetingscribe/venv/bin/python` in both panes (remove the stale entry first). `python -m wisprit doctor` names exactly what's missing. |
| Fn does nothing at all | System Settings → Keyboard → **"Press 🌐 key to" must be "Do Nothing"**; also move or disable the macOS Dictation shortcut if it's on Fn. On most external/non-Apple keyboards the Fn key isn't delivered to apps at all — set `"hotkey": "right_option"` in config.json. |
| Hotkey dead only in one app (often Slack, or at password prompts) | That app has **Secure Keyboard Entry** enabled, which blinds event taps system-wide while it's focused. Wisprit detects this and says so on the pill instead of failing silently — but it cannot be engineered around (Wispr has the same constraint). Your words are never lost: dictate elsewhere or use Cmd+Ctrl+V later. In Slack: Slack menu → uncheck Secure Keyboard Entry. |
| Clipboard contents occasionally clobbered | A **clipboard manager** is racing Wisprit's restore window (it swaps your clipboard for ~500 ms around the paste, verified via changeCount before restoring, and marks the write `org.nspasteboard.TransientType` so well-behaved managers skip it). Every transcript is saved to history *before* pasting, so nothing is ever lost — but if your manager misbehaves, raise `paste_restore_delay_ms` or exclude the manager from watching transient changes. |
| Pasted text garbled or bracketed in a terminal | Wisprit should be *typing* into terminals, not pasting. If you use a terminal not in the default set, add its bundle ID to `terminal_bundle_ids`. |
| "apple_live helper not found / probe failed" from doctor | The compiled helper is missing at `~/.meetingscribe/bin/apple_live`. Rebuild it from `~/MeetingScribe/tools/apple_live.swift` (see MeetingScribe docs). Until then Wisprit runs on the slower mlx-whisper fallback. |
| Noticeable pause after release, or truncated tails | Check `~/.wisprit/metrics.log` for the slow stage. Finalization exceeding `finalize_timeout_ms` falls back to the last partial (`timed_out: true` in metrics). For jargon-dense dictation, try `"engine": "mlx_whisper"` — slower but sometimes more accurate. |
| Mic indicator stays on between dictations | It shouldn't — the input stream is fully closed on release. If the orange dot persists, another app holds the mic; check Control Center. |

## How it compares (honestly)

Drawn from the full research pass in [docs/research/competitors.md](docs/research/competitors.md) — mid-2026 snapshot.

| | **Wisprit** | Wispr Flow | Superwhisper | VoiceInk | Handy |
|---|---|---|---|---|---|
| Price | Free (your own repo) | $12–15/mo | $8.49/mo or $249 lifetime | $39.99 once / free from source | Free (MIT) |
| Processing | 100% local (Neural Engine) | Cloud only — no offline mode | Local-first, optional cloud/BYOK | Local, optional BYOK cloud | Local only |
| Live partial text while speaking | **Yes** (pill preview) | No — block paste after release | No | No | No |
| Release-to-text | **<400 ms p90 target** (streaming during hold) | <700 ms p99 target; ~1–2 s perceived | Model/hardware-dependent | Model-dependent | 2–5 s reported |
| Cleanup philosophy | Verbatim-first deterministic rules; LLM polish strictly opt-in | Best-in-class LLM cleanup, but rewrites what you said; no verbatim mode | Custom modes + BYOK prompts (config-heavy) | BYOK "AI Enhancement" | None — raw transcript |
| Custom vocabulary | Yes — ASR biasing **and** post-ASR correction, hot-reload | Yes, plus passive learning | Via mode prompts | Limited | No |
| Privacy posture | No network sockets, no telemetry, text-only history, mic hard-off between utterances | Screenshot/tracking controversies; 11+ cloud subprocessors; 2.7/5 Trustpilot | Good (local-first, closed source) | Good (GPLv3) | Excellent (MIT, zero telemetry) |
| Platforms | **This one Mac** (macOS 26, Apple Silicon) | Mac, Windows, iOS, Android | Mac, iOS, Windows | Mac | Mac, Windows, Linux |
| Where it's weaker | Single-machine by design; no mobile; manual TCC setup; hands-free mode & always-on LLM cleanup still on the roadmap; English-first for now | — | — | — | — |

The honest summary: if you need cross-device sync, 100+ languages, or Wispr's zero-config prose polish, Wisprit isn't that. If you want Wispr's core interaction — hold a key, talk, get clean text — with lower latency, live feedback, a movable pill, an editable dictionary, and the structural guarantee that your voice never leaves your Mac, that's exactly what this is.

## Development

```sh
PY=~/.meetingscribe/venv/bin/python
$PY -m wisprit            # full app (menu bar + pill)
$PY -m wisprit doctor     # permission & pipeline self-check
$PY -m wisprit hotkey     # print raw hotkey events until Ctrl-C
$PY -m wisprit insert "hello"   # 3 s countdown, then inserts into the focused app
$PY -m pytest tests/      # postprocess fixture suite
```

Repo layout: `wisprit/` (the package — one module per concern, contracts in [docs/INTERFACES.md](docs/INTERFACES.md)), `docs/` (spec + research), `packaging/` (launchd template), `run.command` (launcher).
