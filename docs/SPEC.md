# architecture

## Wisprit Architecture: Python orchestrator + reused Swift SpeechAnalyzer helper (hybrid, streaming-first)

**One-line thesis:** Wispr Flow's moat is pipeline engineering + cleanup, not the acoustic model (Report 1 §7, Report 2 takeaway #1). On an M4 with macOS 26's SpeechAnalyzer already wrapped in a compiled helper, we can beat Wispr's <700 ms p99 target *locally* by streaming ASR **during** the hold, so almost nothing is left to do at key release.

### Process topology

```
┌─────────────────────────────────────────────────────────────────┐
│  wisprit (Python 3.11, existing MeetingScribe venv)             │
│  AppKit run loop on main thread (pyobjc) — menu bar + pill      │
│                                                                 │
│  hotkey.py ── CGEventTap (listen-only) ── flagsChanged: Fn      │
│      │ hold/release/double-tap/Esc events                       │
│      ▼                                                          │
│  session.py (state machine: IDLE→RECORDING→FINALIZING→INSERT)   │
│      │                                                          │
│  audio.py ── sounddevice 16 kHz mono s16 PCM ──────────────┐    │
│                                                            ▼    │
│  asr.py ─ subprocess: MeetingScribe/tools apple_live       │    │
│           (PCM → stdin; NDJSON partial/final ← stdout,     │    │
│            --context <custom dictionary terms>)            │    │
│      │ running transcript accumulates DURING the hold      │    │
│      ▼                                                          │
│  postprocess.py (rule pipeline, <20 ms)                         │
│      ▼                                                          │
│  insert.py (clipboard swap + CGEvent Cmd+V + restore;           │
│             unicode-typing fallback; secure-input guard)        │
│                                                                 │
│  side channels: pill.py (movable NSPanel), history.py (SQLite), │
│  dictionary.py (~/.wisprit/dictionary.json, hot-reload),        │
│  polish.py (async `claude -p` transform, opt-in hotkey),        │
│  asr_batch.py (mlx-whisper large-v3-turbo accuracy re-run)      │
└─────────────────────────────────────────────────────────────────┘
```

### Why this shape wins
1. **Streaming during hold = near-zero release latency.** Wispr does all ASR+LLM+network after release (~1–2 s perceived). Because `apple_live` emits volatile partials while the user is still holding Fn, at release we only wait for SpeechAnalyzer to finalize the tail (~100–250 ms on ANE), run regex rules (<20 ms), and paste (~60 ms). **Target: <400 ms release-to-text p90, <600 ms p99** — better than Wispr on their own metric, with zero network.
2. **Maximal reuse.** The two hardest pieces (streaming ANE ASR with custom-vocab conditioning; batch 60x transcription) already exist as compiled Swift at `/Users/shariquekhatri/MeetingScribe/tools/`. The venv already has sounddevice, mlx-whisper, faster-whisper, numpy. Zero new native code for MVP; zero model downloads (SpeechAnalyzer assets already provisioned by MeetingScribe).
3. **Verbatim-first, cleanup-tiered.** Wispr's #1 quality complaint ("it rewrites what I say", no verbatim mode, Trustpilot 2.7) is solved by default: default output = SpeechAnalyzer's already-punctuated transcript + deterministic rules only. LLM rewriting is opt-in per utterance.
4. **Privacy is structural, not a toggle.** No network sockets anywhere in the pipeline. Audio never persists unless history is enabled (and then transcript-text-only by default, no audio BLOBs — the anti-Wispr 694 MB SQLite). Directly monetizes both Wispr scandals.

### Data flow per utterance
1. User presses Fn → tap fires → pill turns red → audio stream opens → `apple_live` (pre-warmed, long-lived subprocess) starts receiving PCM. Warm start <50 ms because the helper and analyzer stay resident between utterances.
2. Partials accumulate; pill shows a live waveform + last few words (streaming feedback Wispr lacks).
3. User releases Fn → audio flushed + EOF-marked → wait for final NDJSON result (bounded 1.5 s timeout; on timeout, use last partial).
4. Rules pipeline runs → text pasted at cursor → clipboard restored → transcript saved to history → pill flashes green and fades.
5. Esc at any point cancels (audio discarded). `Cmd+Ctrl+V` re-pastes last transcript (Wispr's recovery path, kept).

### Config & state (all local, human-readable)
- `~/.wisprit/config.json` — hotkey, pill position, cleanup tier, history on/off
- `~/.wisprit/dictionary.json` — custom vocab: fed to `apple_live --context` AND used as post-ASR regex corrections (belt and suspenders)
- `~/.wisprit/history.sqlite` — transcripts (text only) for search/re-paste; user-purgeable from menu

### What we deliberately do NOT build
- No accessibility-tree scraping of other apps, no screenshots, no app/URL tracking (Wispr's liability). App-awareness in v2 uses ONLY the frontmost app's bundle ID (NSWorkspace) — a name, not content.
- No CGEventTap in *intercepting* mode for regular keys — listen-only tap on flagsChanged/keyDown avoids Wispr's "swallowed 145 spacebars" class of bug entirely (we never suppress events; Fn produces no character so there is nothing to suppress).
- No Electron, no accounts, no telemetry.

# asr_choice

**Primary: reuse the compiled `apple_live` SpeechAnalyzer helper** (`/Users/shariquekhatri/MeetingScribe/tools/apple_live.swift`, already built) as a long-lived subprocess — PCM in over stdin, NDJSON partial/final captions out.

Why it wins over the alternatives for THIS machine:
- **It streams.** This is the decisive property. parakeet-mlx and mlx-whisper are batch-on-release: even at 100–300x realtime, a 30 s utterance costs 300–800 ms of GPU decode after release, plus model residency in unified memory. SpeechAnalyzer has been transcribing all along on the **Neural Engine** (leaving GPU/CPU free), so release-to-final is ~100–250 ms regardless of utterance length. Report 2 confirms Tahoe's SpeechAnalyzer benchmarks ~55% faster than Whisper-class and is the "first-class fast local engine" apps like Hex/VoiceInk build on.
- **It already solves custom vocabulary** via `--context` — this directly patches Apple Dictation's documented weakness ("no custom vocabulary", Report 2 §11) and replicates Wispr's dictionary-biased ASR mechanism.
- **Zero build risk.** Compiled, tested in MeetingScribe, model assets already downloaded.
- Accuracy: modern on-device engines have converged with Whisper-class on close-mic single-speaker dictation (Report 1 §3: dictation is the easy regime; Report 2: "raw ASR accuracy has largely converged"). The dictionary + rules layer closes the jargon gap.

**Fallback: mlx-whisper 0.4.3 with `large-v3-turbo`** (already installed in the venv), invoked two ways:
1. **Accuracy mode** (menu toggle / per-utterance modifier `Fn+A` planned for v2): record to a buffer, transcribe on release. ~2.7% WER class, better on heavy accents/jargon-dense speech; costs ~0.5–1.5 s but user explicitly opted in.
2. **Automatic resilience**: if `apple_live` crashes, fails health-check at startup, or a macOS update breaks SpeechAnalyzer, asr.py transparently falls back to buffered mlx-whisper so dictation never fully dies. faster-whisper (also installed) is the tertiary emergency path (CPU, no MLX dependency).

**Rejected: parakeet-mlx as primary.** It is the HN raw-speed favorite (Hex), but it's not installed, adds a new dependency + model download, is batch-mode (worse release latency than streaming SpeechAnalyzer for long utterances), and has known language-detection quirks (Report 2 §5). Revisit in v2 only if SpeechAnalyzer accuracy disappoints on code/technical vocabulary.

# interaction_design

**Hotkey scheme (mirrors Wispr defaults exactly, per user request):**
- **Hold Fn (🌐) = push-to-talk.** Press → record; release → finalize + insert. Implemented with a **listen-only** Quartz CGEventTap on `flagsChanged` watching `kCGEventFlagMaskSecondaryFn` (Fn is deliverable on Apple-built keyboards — this M4 MacBook qualifies). Debounce: ignore holds <150 ms (accidental brushes).
- **Double-tap Fn (<400 ms apart) = hands-free toggle**; single tap or Fn again stops. (v1.1 — ships right after MVP.)
- **Esc = cancel** current recording, discard audio (keyDown watched only while RECORDING, never suppressed).
- **Cmd+Ctrl+V = paste last transcript** (recovery path for failed pastes, same binding as Wispr).
- **Fn+P (while idle, on selection) / menu item = "Polish with Claude"** — opt-in LLM transform of the last transcript (v2 expands this).
- Fallback binding **Right-Option hold** available in config.json for external keyboards (Wispr's known Fn gotcha).
- Setup requirement: System Settings → Keyboard → "Press 🌐 key to" = **Do Nothing**, so Fn doesn't trigger Apple Dictation/emoji (see manual steps).
- Known limitation surfaced honestly: apps with Secure Keyboard Entry active (Slack option, password prompts) blind the event tap — detect via `IsSecureEventInputEnabled()` and show a pill tooltip explaining why dictation is unavailable, instead of failing silently like Wispr.

**On-screen indicator:** small pill (~72×26 pt) rendered as a borderless, non-activating `NSPanel` (pyobjc): `ignoresMouseEvents` off, joins all Spaces, floats above full-screen apps, **draggable with position persisted** — default bottom-center like Wispr, but movable, which is a documented user demand (PillFloat exists solely because Wispr's isn't). States: idle-hidden → recording (red dot + live input-level bars + rolling last ~6 words of the partial transcript — streaming feedback Wispr lacks) → finalizing (spinner, should be <400 ms) → success flash green / error flash amber with reason. Menu-bar icon mirrors state for users who hide the pill.

**Text insertion (same mechanism Wispr chose, hardened):**
1. Snapshot `NSPasteboard.general` (all types) + `changeCount`.
2. Write transcript to pasteboard; post CGEvent Cmd+V (`kVK_ANSI_V` + command flag) via `CGEventPost(kCGHIDEventTap)` — virtual keycode, so non-QWERTY layout bugs (Wispr's known issue) don't apply for posting; we post the *keycode for V*, which macOS maps correctly for paste shortcuts on virtually all layouts, and layout re-detection is a non-goal for a single-user app.
3. After 120 ms, if `changeCount` unchanged by another app, restore original clipboard. Text is ALSO always saved to history first, so a failed paste never loses words (Wispr's data-loss failure mode).
4. **Terminal fallback:** if frontmost bundle ID ∈ {Terminal, iTerm2, WezTerm, kitty, Alacritty, Ghostty} — configurable set — use `CGEventKeyboardSetUnicodeString` typed injection (chunked 20 chars/event) instead of paste, avoiding bracketed-paste/Cmd+V weirdness (the Claude Code paste-breakage bug class from Report 1).
5. **Secure fields:** if secure event input is enabled, never inject; keep transcript on the "paste last" hotkey and notify via pill.

# postprocessing

**Philosophy: verbatim-first. Deterministic rules on every utterance; LLM only on explicit request.** This directly answers Wispr's top quality complaint (over-rewriting, no verbatim mode) and keeps the latency budget trivially safe.

**Tier 1 — runs on EVERY utterance (pure Python regex/string ops, budget 20 ms, measured typically <5 ms):**
1. **Punctuation & capitalization** — mostly free: SpeechAnalyzer emits punctuated, cased text natively. Rules only patch edge cases (ensure sentence-final period toggleable; capitalize after newline). ~1 ms.
2. **Filler removal** — token-level regex kill-list (`um, uh, uhh, erm, you know` as isolated tokens; conservative — never touch "like"/"so" since context-free removal is how you mangle meaning), off-switch in config. ~1 ms.
3. **Custom dictionary enforcement** — case-insensitive word-boundary replace of known misrecognitions → canonical forms from dictionary.json (e.g. "in forge" → "InsForge", "wisper" → "Wispr"). Same file feeds `apple_live --context`, so this is the second net. ~2 ms.
4. **Spoken-form normalization** — "at" between name-like tokens + domain → email (`sharique dot khatri at gmail dot com` → `sharique.khatri@gmail.com`); "dot com/org/io" URL joining; number formatting (spelled-out numbers ≥ threshold → digits, phone-number grouping); "new line"/"new paragraph" voice commands → literal breaks; "period/comma/question mark" as explicit trailing dictation commands. ~5 ms.
5. **Self-correction (rule-based subset)** — detect explicit markers only: "X, no wait, Y" / "X — actually, Y" / "scratch that" → keep Y. Regex-safe patterns only; ambiguous cases pass through verbatim. ~1 ms.
6. Whitespace/join cleanup, smart leading-space depending on whether prior char context is unknown (default: no leading space). ~1 ms.

**Tier 2 — `claude` CLI polish, OPT-IN per invocation (Fn+P / menu / auto for utterances >N words if user enables):**
- `claude -p` with a tight system prompt: "Fix transcription artifacts, apply requested tone, preserve wording and meaning; output only the text." Modes: Clean / Formal / Casual / Prompt-engineer (mirrors Wispr's Opt+1/Opt+2 transforms).
- Latency: 2–6 s (CLI startup + generation) — **explicitly outside the insert path.** Two UX shapes: (a) transform-in-place: verbatim text lands instantly, polished version replaces it via select-all-typed diff when ready is too invasive → instead polished result goes to clipboard + notification, user pastes; (b) scratchpad window shows before/after diff (Wispr's Opt+O idea). No API key needed — uses the Claude Code subscription, matching the user's established local-ish pattern (Screener, ATS Scanner).

**Tier 3 (v2) — resident small local LLM (mlx-lm + Qwen3-4B-Instruct 4-bit):** the path to Wispr-grade always-on cleanup (implicit self-corrections, tone-per-app) at 100+ tok/s on M4, ~200–400 ms for short utterances, applied async-with-replacement or gated to utterances >12 words. Not in MVP: it's the only stage that could reintroduce the "rewrote what I said" failure, so it ships behind a default-off toggle after the verbatim core is trusted.

**End-to-end latency budget (release → text visible), streaming primary path:**
| Stage | Budget |
|---|---|
| Audio flush + EOF to helper | 30 ms |
| SpeechAnalyzer finalization (tail already decoded) | 100–250 ms |
| Tier-1 rules | ≤20 ms |
| Clipboard write + Cmd+V post + app paint | 60–100 ms |
| **Total p50 / p99** | **~250 ms / <600 ms** |

vs Wispr's <700 ms p99 engineering target and 1–2 s user-perceived reality — and the user additionally sees live partial words *during* the hold, which Wispr never shows.

# mvp_features

[
  "Hold-Fn push-to-talk with listen-only CGEventTap; Esc to cancel; \u2265150 ms hold debounce (Wispr's core UX, minus its event-suppression bug class)",
  "Streaming ASR via existing apple_live SpeechAnalyzer helper (pre-warmed subprocess, Neural Engine, NDJSON partials) \u2014 release-to-text <400 ms p90, beating Wispr's 700 ms p99 target locally",
  "Custom dictionary (~/.wisprit/dictionary.json): terms fed to apple_live --context for recognition biasing AND applied as post-ASR corrections; hot-reload on file change; editable from menu (Wispr's dictionary, fully local)",
  "Verbatim-first Tier-1 cleanup on every utterance: filler removal, dictionary enforcement, email/URL/number normalization, explicit self-correction markers, voice commands for newline/punctuation \u2014 all deterministic, all <20 ms (answers Wispr's #1 complaint: over-rewriting)",
  "Clipboard-swap paste insertion with changeCount-verified clipboard restore, unicode-typing fallback for terminals, secure-input detection with honest pill notification (Wispr's insertion method, hardened against its documented failure modes)",
  "Movable, position-persisted floating pill with recording state, input level, and LIVE partial-word preview (fixes Wispr's fixed pill AND its no-streaming-feedback complaint in one widget)",
  "Menu-bar app: enable/disable, last-5 transcripts with click-to-copy, open dictionary, open settings, quit",
  "Paste-last-transcript hotkey (Cmd+Ctrl+V) + text-only SQLite history so a failed paste never loses words (Wispr's data-loss failure mode, eliminated)",
  "Automatic ASR fallback chain: apple_live \u2192 buffered mlx-whisper large-v3-turbo \u2192 faster-whisper, so dictation survives helper crashes or OS breakage",
  "Zero network at runtime, no telemetry, no audio retention by default \u2014 the structural answer to both Wispr privacy scandals"
]

# v2_features

[
  "Hands-free toggle mode via double-tap Fn (Wispr's hands-free mode) \u2014 actually v1.1, first follow-up",
  "Claude-CLI polish transforms with before/after diff view: Clean / Formal / Casual / Prompt-engineer modes on the last transcript (Wispr's Opt+1/Opt+2 transforms + Opt+O diff, powered by the existing Claude Code subscription, no API key)",
  "Resident local LLM cleanup tier (mlx-lm + Qwen3-4B 4-bit): implicit self-correction rewriting and always-on prose smoothing for long utterances, default OFF, ~200\u2013400 ms async (Wispr's fine-tuned-Llama layer, localized)",
  "Tone-per-app: map frontmost bundle ID (NSWorkspace name only \u2014 never window content) to a cleanup style (Mail/Slack\u2192formal-ish, Messages\u2192casual, IDEs/terminals\u2192verbatim+code-vocab) (Wispr's app-category tone matching without its surveillance)",
  "Accuracy mode: per-utterance mlx-whisper large-v3-turbo re-transcription toggle for jargon-dense dictation; evaluate parakeet-mlx here too (Superwhisper/Hex model-choice pattern)",
  "Auto-learn proper nouns: watch user's immediate manual corrections of pasted text (opt-in, local diff of clipboard/history) and suggest dictionary additions (Wispr's passive learning, consent-first)",
  "Snippets: voice-triggered text expansion ('sign off' \u2192 email signature) from a local snippets.json (Wispr Snippets)",
  "Dictation-to-agent mode: verbatim + code-vocabulary profile tuned for talking to Claude Code/Cursor panes \u2014 the underserved niche all of HN is circling (Report 2 takeaway #4)",
  "History search UI (local web page \u00e0 la user's other apps, or simple AppKit window) with full-text search over transcripts, per-entry delete and purge-all",
  "Multilingual/code-switching support: SpeechAnalyzer locale selection in settings; auto-language via mlx-whisper accuracy mode",
  "Scratchpad window: dictate into a floating buffer first, edit, then send \u2014 for long-form composition (Wispr Scratchpad)",
  "Optional .app bundling (py2app or a thin Swift launcher) for cleaner TCC identity and login-item autostart"
]

# risks

[
  "Fn-key capture is the single biggest MVP risk: flagsChanged delivery for kCGEventFlagMaskSecondaryFn can vary by keyboard/OS build, and the 'Press \ud83c\udf10 key to: Do Nothing' setting MUST be set or macOS dictation/emoji picker fights us. Mitigation: build hotkey.py first with a standalone test script; Right-Option fallback binding ready in config.",
  "TCC identity fragility: Accessibility/Input Monitoring/Microphone grants attach to the invoking binary (the venv python3). Re-creating the venv or updating Python silently revokes permissions and the event tap just returns NULL. Mitigation: explicit startup self-check that reports exactly which permission is missing; document the venv-python path; v2 .app bundle fixes this properly.",
  "SpeechAnalyzer finalization latency tail: on very long utterances or under memory pressure, final-result delivery may exceed the 1.5 s timeout. Mitigation: timeout falls back to last volatile partial (measure how often on day one); accuracy-mode re-run available.",
  "SpeechAnalyzer accuracy on code/technical jargon is unproven for this user's vocabulary (Apple engines historically weak on jargon, Report 2 \u00a711). Mitigation: --context dictionary + Tier-1 corrections; if still poor, promote mlx-whisper or parakeet-mlx to primary \u2014 asr.py is engine-agnostic by design.",
  "CGEventTap can be disabled by the OS (kCGEventTapDisabledByTimeout) if our callback ever stalls. Mitigation: callback does nothing but enqueue to a thread-safe queue; re-enable-on-disable handler; watchdog thread.",
  "Clipboard race: another app (clipboard manager!) mutating the pasteboard during our 120 ms swap window can clobber restore. Mitigation: changeCount check, history-first persistence, paste-last recovery hotkey; document known conflict with clipboard managers.",
  "apple_live subprocess lifecycle: stdin-EOF semantics vs long-lived reuse must match how MeetingScribe drives it \u2014 if the helper finalizes only on process exit, warm-start design needs a restart-per-utterance variant (~100\u2013300 ms spawn cost) or a small Swift tweak to accept an in-band flush marker. Verify in component 3 before building around it.",
  "Secure Keyboard Entry (Slack setting, password fields, some terminals) blinds the event tap system-wide while active \u2014 dictation hotkey simply won't fire. Mitigation: detect IsSecureEventInputEnabled and tell the user which app holds it; cannot be engineered around (same constraint Wispr has).",
  "claude CLI polish latency (2\u20136 s) and subscription rate limits make it unsuitable for every-utterance use \u2014 keep it strictly opt-in or the app will feel broken (Wispr's day-two-drop perception risk).",
  "Scope creep toward Wispr's surveillance features: any future 'context awareness' must stay bundle-ID-only. Reading window content via AX is both the accuracy shortcut and the exact thing that torched Wispr's trust \u2014 treat as out of bounds without explicit per-feature consent design."
]

# manual_setup_steps

[
  "System Settings \u2192 Keyboard \u2192 'Press \ud83c\udf10 key to' \u2192 set to 'Do Nothing' (frees the Fn key for Wisprit's push-to-talk; otherwise macOS Dictation/emoji picker intercepts it)",
  "System Settings \u2192 Privacy & Security \u2192 Microphone \u2192 enable for the terminal app / venv python3 that runs Wisprit (prompted automatically on first recording)",
  "System Settings \u2192 Privacy & Security \u2192 Accessibility \u2192 add and enable the venv python3 binary (required for posting the Cmd+V paste event via CGEventPost)",
  "System Settings \u2192 Privacy & Security \u2192 Input Monitoring \u2192 add and enable the venv python3 binary (required for the CGEventTap that watches the Fn key; without it the tap silently returns NULL)",
  "If macOS Dictation shortcut is also bound to Fn: System Settings \u2192 Keyboard \u2192 Dictation \u2192 set shortcut to something else or Off",
  "One-time verification that SpeechAnalyzer language assets are installed (they should be, from MeetingScribe): run the provided `wisprit doctor` check, which pipes 2 s of silence through apple_live and reports status",
  "Optional (recommended): add Wisprit to Login Items (System Settings \u2192 General \u2192 Login Items) once stable, via the provided launchd plist or the run script",
  "After ANY Python/venv update or recreation: re-grant Accessibility and Input Monitoring to the new python3 binary (TCC grants are per-binary; `wisprit doctor` will detect and name the missing grant)"
]

# build_plan

Repo: `/Users/shariquekhatri/Wisprit`, package `wisprit/`, reusing the MeetingScribe venv and helpers at `/Users/shariquekhatri/MeetingScribe/tools/`. Build order is risk-first: the two components that can kill the design (Fn capture, apple_live lifecycle) come before anything cosmetic. Each component is independently runnable/testable.

1. **`wisprit/hotkey.py`** — Quartz CGEventTap (listen-only) for Fn hold/release, double-tap detection, Esc-while-recording; emits events to a queue; tap re-enable watchdog; standalone `python -m wisprit.hotkey` test mode that prints events. **De-risks the #1 risk first.**
2. **`wisprit/permissions.py`** + **`wisprit/doctor.py`** — TCC self-checks (AXIsProcessTrusted, IsSecureEventInputEnabled, tap-creation probe, mic probe, apple_live silence probe); `wisprit doctor` CLI that names exactly what's missing and the System Settings pane to fix it.
3. **`wisprit/asr.py`** — apple_live subprocess manager: spawn from `/Users/shariquekhatri/MeetingScribe/tools/` (compile step documented if only .swift exists), feed PCM, parse NDJSON partial/final, --context injection from dictionary, utterance finalize semantics (verify flush-vs-restart behavior HERE, per risk list), crash detection. Standalone test: mic → live captions in terminal.
4. **`wisprit/audio.py`** — sounddevice 16 kHz mono s16 capture with start/stop, level metering for the pill, and a rolling pre-buffer (~300 ms before keydown so first syllables aren't clipped).
5. **`wisprit/postprocess.py`** — Tier-1 rule pipeline (fillers, dictionary corrections, email/URL/number normalization, explicit self-corrections, voice commands, whitespace) + **`tests/test_postprocess.py`** with a table of utterance→expected fixtures (the only component where unit tests pay for themselves immediately).
6. **`wisprit/dictionary.py`** — dictionary.json load/watch/hot-reload; canonical-term list for --context; correction-pattern compiler for postprocess.
7. **`wisprit/insert.py`** — pasteboard snapshot/restore with changeCount verification, CGEvent Cmd+V post, unicode-typing fallback for the terminal bundle-ID set, secure-input guard. Standalone test: inserts a fixed string into TextEdit.
8. **`wisprit/history.py`** — SQLite text-only transcript log, last-N accessor, paste-last support, purge.
9. **`wisprit/session.py`** — the state machine wiring 1+3+4+5+7+8 together (IDLE→RECORDING→FINALIZING→INSERTING→IDLE, cancel path, finalize timeout→last-partial fallback, per-stage latency instrumentation logged to `~/.wisprit/metrics.log`).
10. **`wisprit/pill.py`** — pyobjc NSPanel pill: states, live level bars, rolling partial-words preview, drag-to-move with persisted position, joins all Spaces.
11. **`wisprit/app.py`** — AppKit main run loop + NSStatusItem menu (enable/disable, last-5 transcripts, open dictionary/settings, doctor, quit); `python -m wisprit` entrypoint; **`wisprit/settings.py`** for config.json.
12. **`wisprit/asr_batch.py`** — mlx-whisper large-v3-turbo buffered fallback + faster-whisper tertiary; wired into asr.py's failover.
13. **`wisprit/polish.py`** — async `claude -p` transform of last transcript (Clean/Formal/Casual/Prompt modes), result to clipboard + notification. Ships dark behind a menu item; v2 expands.
14. **Packaging/ops** — `run.command`, launchd plist template, `README.md` with the manual TCC steps, `~/.wisprit/` bootstrap with sensible default config.json + starter dictionary.json (seed with user's known vocabulary: InsForge, MeetingScribe, Wispr, etc.).

Definition of done for MVP: hold Fn, speak a 20-word sentence with one 'um' and one dictionary term, release → correct text appears in TextEdit, Slack, and iTerm2 in <500 ms, clipboard intact, entry visible in history, all with Wi-Fi turned off.