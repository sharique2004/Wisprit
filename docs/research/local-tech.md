# Local Real-Time Dictation on Apple Silicon — Implementation Survey (mid-2026)

Recovered after the first research agent crashed mid-response; re-run as a
standalone agent. This is the implementation-critical companion to
`wisprflow.md` and `competitors.md`. The **Key implementation
recommendations** at the bottom are wired into `docs/INTERFACES.md` and the
code.

## 1. How OSS dictation apps capture the hotkey and inject text

- **VoiceInk** (Swift, GPL-3): CGEventTap (`.cgSessionEventTap`, `.headInsertEventTap`),
  mask keyDown|keyUp|flagsChanged; models modifier-only shortcuts with a
  sentinel keycode, triggers on modifier release. Injection: CGEvent Cmd-V
  (4 events, 10 ms apart) OR AppleScript System Events. Clipboard restore
  verified by stamping a **private session-marker pasteboard type** and only
  restoring if it still matches.
- **Hex** (Swift/TCA — the most instructive Fn codebase): CGEventTap at
  `.cghidEventTap` `.defaultTap` (active, can suppress), mask includes mouse
  clicks. Fn via `flagsChanged` + `keyCode == kVK_Function (63)`. Watchdog
  re-enables silently-dead taps. **Dirty-chord state**: any other key joining
  Fn blocks the trigger until everything releases — fixes issue #89 where
  arrow keys alone started recording (macOS sets `.maskSecondaryFn` on
  arrow/nav/F-keys even without physical Fn). Injection cascade: Cmd-V
  (keycode via Sauce for layout independence) → AppleScript Edit▸Paste menu
  click → AX `kAXSelectedTextAttribute`. Clipboard write verified by polling
  `changeCount` (5 ms interval, 150 ms timeout); restore after 500 ms.
- **Handy** (Tauri/Rust, ~23k stars): `handy-keys` crate wraps CGEventTap; Fn
  is explicit `Modifiers::FN`. Injection: enigo typing OR clipboard+paste with
  configurable pre/post delays. Ships an **Apple Foundation Models** cleanup
  bridge (Swift `@_cdecl` → Rust) with prompt-injection defenses.
- **WhisperWriter** (Python): pynput hotkey; **pure char-by-char typing**, no
  clipboard — the reference for typed injection (works in terminals, slow,
  can drop chars in Electron without delay).
- **OpenWhispr** (Electron + Swift helpers — closest to Wisprit's shape): a
  standalone Swift binary watches Fn via `NSEvent.addGlobalMonitorForEvents`
  + emits `FN_DOWN`/`FN_UP`/`FN_INTERRUPTED` tokens on stdout; a `fast-paste`
  Swift helper posts Cmd-V after checking `AXIsProcessTrusted()`. Changelog
  notes fixing "stale clipboard restores during paste" — the classic race.

## 2. CGEventTap + Fn/Globe on macOS 26 — the hard-won quirks

- **Fn arrives only as `flagsChanged` with `keyCode == 63`** and the
  `.maskSecondaryFn` flag. **Never trust the flag alone** — arrows/nav/F-keys
  set it without the physical Fn key (Hex bug #89). Gate on keycode 63, and
  implement an interrupt/dirty-chord state so Fn+arrow doesn't fire dictation.
- **macOS 26 regression**: `NSEvent.addGlobalMonitorForEvents` has actor-runtime
  bus-error crash reports; prefer a CGEventTap. The tap callback runs on a
  CFRunLoop thread — hop to main before touching UI.
- **External keyboards**: most third-party keyboards handle Fn in firmware and
  **never send it to macOS**. Fn push-to-talk silently doesn't exist for many
  external-keyboard users → always offer a non-Fn alternate hotkey
  (Wisprit: `right_option`).
- **"Press 🌐 key to → Do Nothing"** is mandatory or a bare Fn press pops the
  emoji picker / Apple's own dictation. Conversely, if you *suppress* Fn
  flagsChanged you break the user's system double-Fn dictation — so use a
  **listen-only** tap and suppress nothing (Fn produces no character; there is
  nothing to swallow).
- **TCC**: listen-only tap → **Input Monitoring**; active tap → Accessibility
  (which implies Input Monitoring). `IOHIDCheckAccess` can report *denied*
  while events actually flow (stale cache) — if events arrive, you have
  permission. TCC is keyed to code-signing identity: re-signing/venv changes
  silently reset grants and produce "tap alive, zero events" ghosts.
- **`kCGEventTapDisabledByTimeout`**: on disable, reset pressed-key state (so
  you don't get stuck "recording") and `tapEnable(true)`; also run a ~5 s
  watchdog since disable callbacks aren't guaranteed. Keep the callback fast —
  the timeout fires when your callback stalls the pipeline.

## 3. Clipboard-paste insertion — timing and failure catalog

Synthesis of VoiceInk/Hex/Handy/OpenWhispr:
1. Snapshot **all** pasteboard items and types (not just the string).
2. Write text; verify the write via `changeCount` vs baseline.
3. Small settle (~100 ms) before Cmd-V.
4. **Restore no sooner than ~300–500 ms after paste** — restoring early is the
   #1 reported bug ("pasted my *old* clipboard"); apps read the pasteboard
   asynchronously after Cmd-V. Wisprit default: 500 ms.
5. **Conditional restore**: only restore if the pasteboard still holds your
   text (changeCount unchanged / session-marker present). Mark writes with
   `org.nspasteboard.TransientType` so clipboard managers skip them.

Where Cmd-V fails: Secure Keyboard Entry (detect `IsSecureEventInputEnabled`,
name the holder, don't inject); remote-desktop/game apps (Parsec); non-QWERTY
layouts with a hardcoded keycode; some Electron builds; terminals + bracketed
paste (insert single-line, no trailing newline; make "press Enter" explicit).
Fall back to typed unicode injection (`CGEventKeyboardSetUnicodeString`) for
secure/terminal/never-touch-clipboard contexts.

## 4. Engine quality/latency (dictation-critical)

| Engine | LibriSpeech clean WER | End-of-speech latency | Notes |
|---|---|---|---|
| Apple SpeechAnalyzer (macOS 26) | ~2.1% | 150–400 ms | **cased + punctuated output**, zero model download, ~30 locales |
| Parakeet TDT v2/v3 | ~2.1–2.5% | **~80 ms** | best on disfluent speech; ~155× RT ANE; not installed |
| whisper-large-v3-turbo (mlx) | ~5% | 200–500 ms (batch, ~1 s/utterance) | fallback only, not streaming; ~100 locales |

Key finding: **raw WER has converged** for clean close-mic dictation.
SpeechAnalyzer's punctuation is its practical edge for a dictation product.
Parakeet is the low-latency/disfluent-speech upgrade path if SpeechAnalyzer
disappoints. mlx-whisper earns its place only as batch fallback + long-tail
languages.

**CRITICAL correction for Wisprit**: `contextualStrings` vocabulary biasing is
supported by `DictationTranscriber` but **NOT by `SpeechTranscriber`**
(Apple-confirmed, dev forums 801877). The reused `apple_live` helper uses
`SpeechTranscriber`, so its `--context` biasing is likely a no-op. Wisprit
therefore relies on **post-ASR dictionary corrections** (`postprocess.py`) as
the real vocabulary net, and still passes `--context` (harmless if ignored).
Promoting the helper to `DictationTranscriber`, or Parakeet with prompt
biasing, is a v2 option if jargon accuracy is poor.

## 5. Local LLM cleanup

OSS apps (Handy, FreeFlow, Tambourine) use a small LLM to strip fillers, fix
punctuation, and honor "scratch that" self-corrections. **Top failure mode:
the model answers the dictated question instead of cleaning it** ("remind me
to…" → assistant reply). Mitigations: conservative scope (punctuation/fillers/
casing/repeats only), delimit transcript as data, strict role framing,
hold-to-talk design. Apple Foundation Models (`SystemLanguageModel`) is usable
from third-party Swift (Handy ships it) but has non-disableable guardrails
(`guardRailViolation`), one-request-per-session rate limiting, and a 4096-token
window — always keep a raw-transcript fallback. Qwen3-4B-4bit via mlx-lm:
~1–2 s/utterance on M4, ~3 GB RAM.

For Wisprit MVP this stays **deterministic rules only** (verbatim-first,
answering Wispr's over-rewriting complaint). LLM polish is opt-in via the
`claude` CLI; a resident Foundation-Models / mlx-lm tier is v2.

## Key implementation recommendations (wired into the build)

- Fn detection strictly on `flagsChanged` keycode 63; dirty-chord interrupt so
  Fn+other-key cancels; listen-only tap (suppress nothing); handle
  tapDisabled + run a watchdog; offer right-option alternate hotkey.
- Clipboard: snapshot all types; transient marker; restore at ~500 ms only if
  changeCount unchanged; typed-unicode fallback for terminals; block on secure
  input and name the holder.
- Keep SpeechAnalyzer primary (16 kHz mono, volatile results), mlx-whisper as
  batch fallback; rely on postprocess dictionary corrections, not
  SpeechTranscriber contextualStrings.
- Cleanup deterministic + verbatim-first for MVP; conservative, data-delimited
  prompts if/when an LLM tier is added.
