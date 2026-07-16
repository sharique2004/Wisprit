# Wisprit module contracts

Binding contract for every build agent. Read `docs/SPEC.md` first for the why;
this file is the what. If your implementation must deviate, leave a
`# CONTRACT-DEVIATION:` comment at the site and note it in your final report.

Python: `~/.meetingscribe/venv/bin/python` (3.11; pyobjc, sounddevice, numpy,
mlx-whisper, faster-whisper installed). All code lives in package `wisprit/`.
Shared constants come from `wisprit/runtime.py` (already written — import, don't
redefine). Logging: stdlib `logging`, logger name `wisprit.<module>`.

## Threading model (memorize this)

- **Main thread** runs the AppKit `NSApplication` loop (`app.py`) and owns ALL
  AppKit objects (status item, pill NSPanel, NSPasteboard is exempt/thread-safe
  enough for our snapshot/restore but we still do it from the session thread —
  see insert.py note). The CGEventTap is created on the main thread and its
  run-loop source added to the MAIN CFRunLoop.
- **Session thread** (one `threading.Thread`, started by app.py) runs
  `session.Session.run()` — the state machine. It consumes hotkey events from a
  `queue.Queue` and calls audio/asr/postprocess/insert/history synchronously.
- **Audio callback thread** (sounddevice) only copies PCM into the active
  `AsrEngine.feed()` (which must be non-blocking; internally bounded-queue,
  drop-oldest) and updates a level float.
- **ASR reader thread(s)** parse helper stdout and fire `on_partial(text)`.
- **UI updates from any thread** go through `ui.call_on_main(fn, *args)`:

```python
# wisprit/ui.py (integration agent writes this tiny helper)
from AppKit import NSOperationQueue
def call_on_main(fn, *args):
    NSOperationQueue.mainQueue().addOperationWithBlock_(lambda: fn(*args))
```

Hotkey tap callback must do NOTHING except enqueue `(event, timestamp)` tuples.

## settings.py  (owner: agent D)

```python
DEFAULTS: dict            # exactly the keys below
class Settings:
    def __init__(self, path=runtime.CONFIG_PATH): ...   # loads, merging DEFAULTS
    def get(self, key): ...
    def set(self, key, value): ...                      # persists immediately (atomic write)
    def reload(self): ...
    # attribute-style read access also fine; keep it simple
def load() -> Settings   # module-level singleton accessor
```

DEFAULTS = {
  "hotkey": "fn",                      # "fn" | "right_option"
  "hold_debounce_ms": 150,
  "locale": "en-US",
  "finalize_timeout_ms": 1500,
  "filler_removal": True,
  "ensure_sentence_period": False,
  "leading_space": "auto",             # "auto" | "always" | "never"
  "terminal_bundle_ids": runtime.DEFAULT_TERMINAL_BUNDLE_IDS,
  "pill_position": None,               # [x, y] once user drags it
  "pill_hidden": False,
  "history_enabled": True,
  "history_limit": 1000,
  "engine": "auto",                    # "auto"|"apple_live"|"mlx_whisper"|"faster_whisper"
  "mlx_model": "mlx-community/whisper-large-v3-turbo",
  "paste_restore_delay_ms": 120,
  "enabled": True,                     # master toggle from menu
}

## hotkey.py  (owner: agent A)

```python
class HotkeyEvent:  # dataclass
    kind: str       # "press" | "release" | "esc"
    ts: float       # time.monotonic()

class HotkeyListener:
    def __init__(self, events: queue.Queue, settings): ...
    def install(self) -> bool:      # create listen-only CGEventTap on MAIN thread;
                                    # returns False if tap creation failed (TCC missing)
    def uninstall(self): ...
```

- Listen-only tap (`kCGEventTapOptionListenOnly`) at `kCGHIDEventTap`-session
  level for `flagsChanged` + `keyDown` (keyDown ONLY consulted for Esc while
  recording; never suppress anything).
- Fn detection: flagsChanged where `keycode == runtime.KVK_FUNCTION`; press =
  FN flag newly set, release = newly cleared (track previous flags).
  `hotkey == "right_option"`: keycode KVK_RIGHT_OPTION with option-flag edges.
- Emit "press" immediately on key-down edge; session enforces the 150 ms
  debounce (discards on release-too-soon). Emit "esc" only while a
  `self.recording` flag (set/cleared by session via a thread-safe setter) is
  true.
- Handle `kCGEventTapDisabledByTimeout`/`ByUserInput` by re-enabling the tap.
- `python -m wisprit.hotkey` test mode: install tap, print events until Ctrl-C.

## permissions.py + doctor.py  (owner: agent A)

```python
def check_accessibility() -> bool        # AXIsProcessTrusted()
def check_input_monitoring() -> str      # "granted"|"denied"|"undetermined" via IOHIDCheckAccess
def check_microphone() -> str            # AVCaptureDevice authorizationStatusForMediaType_ (avoid prompting)
def secure_input_active() -> tuple[bool, str|None]   # IsSecureEventInputEnabled + best-effort holder name
def request_accessibility_prompt()       # AXIsProcessTrustedWithOptions prompt=True
```

`doctor.py` — `run() -> int` prints a human checklist: each permission, the
exact System Settings pane to fix it, apple_live binary presence + a 2-second
silence probe through it (spawn, feed 2 s of zeros, expect clean exit),
mlx-whisper importability, config/dictionary validity. Exit code 0 only if the
required set is green. Include the "Press 🌐 key to → Do Nothing" reminder
(cannot be checked programmatically — print as a WARN with instructions).

## audio.py  (owner: agent B)

```python
class AudioCapture:
    level: float                       # 0..1 RMS-ish of last chunk, read by pill
    def __init__(self, on_chunk: Callable[[bytes], None]): ...  # int16 mono 16 kHz bytes
    def start(self): ...               # opens/starts sounddevice.InputStream
    def stop(self) -> bytes: ...       # stops stream, returns full utterance PCM
                                       # (also kept internally for fallback engines)
```

- Create the InputStream lazily; investigate whether keeping a stopped stream
  instance alive shows the macOS orange mic indicator — if it does, close it
  fully on stop. Mic must be visibly OFF between utterances (privacy feature).
- Chunks: `runtime.CHUNK_FRAMES` frames; convert to bytes with `.tobytes()`.

## asr.py  (owner: agent B)

```python
class UtteranceResult:  # dataclass
    text: str
    engine: str          # "apple_live" | "mlx_whisper" | "faster_whisper"
    finalize_ms: float
    timed_out: bool      # True if we fell back to last partial

class AppleLiveEngine:
    def __init__(self, settings, dictionary): ...
    def prewarm(self): ...             # spawn helper: [APPLE_LIVE_BIN, locale, "16000", "1", --context ctx.json]
    def begin(self, on_partial): ...   # arm reader thread; uses prewarmed proc or spawns
    def feed(self, pcm: bytes): ...    # non-blocking; bounded queue, drop-oldest (copy MeetingScribe pattern)
    def finalize(self, timeout_s) -> UtteranceResult: ...
        # close stdin -> helper flushes finals, emits {"t":"done"}, exits.
        # Assemble text = join of ALL final events (they arrive during streaming
        # too). timeout -> use finals + last trailing partial, timed_out=True.
        # After finalize, prewarm() the next process.
    def cancel(self): ...              # kill proc, discard, prewarm next
    def healthy(self) -> bool

class AsrManager:                      # engine-agnostic facade used by session
    def __init__(self, settings, dictionary): ...
    def begin(self, on_partial): ...
    def feed(self, pcm): ...
    def finalize(self, full_pcm: bytes) -> UtteranceResult: ...
        # if primary unhealthy/failed -> asr_batch fallback using full_pcm
    def cancel(self): ...
```

- `--context` file: write `{"strings": dictionary.terms()}` to a temp file
  under STATE_DIR when dictionary changes; pass if non-empty.
- **Empirically verify** with `say`-synthesized audio (no mic/TCC needed):
  `say -o /tmp/t.aiff "..."` → `afconvert -f WAVE -d LEI16@16000 -c 1` → feed
  the PCM in 100 ms chunks with real-time pacing, close stdin, measure
  close→done latency. Record findings (spawn cold-start ms, finalize ms,
  whether finals arrive mid-stream, punctuation quality) in
  `docs/notes/asr-notes.md`. Also verify prewarmed-process-waits-on-stdin works.

## asr_batch.py  (owner: agent B)

```python
def transcribe_mlx(pcm: bytes, settings) -> str      # mlx_whisper.transcribe on float32 array
def transcribe_faster(pcm: bytes, settings) -> str   # faster-whisper tertiary
```
Lazy-import heavy deps inside functions. No temp WAV needed for mlx-whisper —
it accepts a numpy float32 array at 16 kHz.

## dictionary.py  (owner: agent C)

```python
class Dictionary:
    def __init__(self, path=runtime.DICTIONARY_PATH): ...
    def terms(self) -> list[str]                    # canonical vocab for --context
    def corrections(self) -> list[tuple[re.Pattern, str]]  # compiled, word-boundary, case-insensitive
    def maybe_reload(self) -> bool                  # mtime check; True if changed
    def add_term(self, term, misrecognitions=None); def remove_term(self, term)
```

dictionary.json format:
```json
{"terms": [{"term": "InsForge", "hear": ["in forge", "ins forge"]},
            {"term": "Wispr Flow", "hear": ["whisper flow"]}]}
```
`hear` entries → corrections mapping misrecognition→term; every `term` also
self-corrects casing (e.g. "insforge"→"InsForge").

## postprocess.py  (owner: agent C)

```python
def process(text: str, settings, dictionary) -> str
```
Deterministic pipeline, in order: (1) strip filler tokens (um, uh, uhh, erm,
uhm — isolated word-boundary tokens only, config-gated); (2) dictionary
corrections; (3) spoken-email ("X dot Y at gmail dot com" → x.y@gmail.com) and
spoken-URL ("foo dot com/org/io/net/ai") joining; (4) voice commands at
utterance level: "new line"/"new paragraph" → "\n"/"\n\n", trailing
"period|comma|question mark|exclamation point" → punctuation; (5) explicit
self-correction: "X no wait Y" / "X scratch that Y" / trailing "scratch that"
→ keep Y (conservative regex; ambiguous → passthrough); (6) whitespace/join
cleanup around punctuation; (7) optional trailing period
(`ensure_sentence_period`). Target <20 ms; pure stdlib. Must be fully covered
by `tests/test_postprocess.py` fixtures (table-driven; ~40+ cases including
no-op cases proving conservatism, e.g. "I like summer" keeps "like").

## insert.py  (owner: agent D)

```python
class InsertResult:  # dataclass
    ok: bool; method: str  # "paste"|"type"|"blocked_secure"|"error"; detail: str = ""

def frontmost_bundle_id() -> str | None          # NSWorkspace.sharedWorkspace().frontmostApplication()
def insert_text(text, settings) -> InsertResult
```
- Secure input active → return blocked_secure, never inject.
- Terminal bundle IDs (settings) → typed injection: CGEventKeyboardSetUnicodeString
  chunked ≤20 UTF-16 units per keyDown/keyUp pair, small inter-chunk sleep.
- Otherwise clipboard method: snapshot pasteboard items (all types, best-effort),
  record changeCount, write plain string, post Cmd+V (CGEventCreateKeyboardEvent
  keycode KVK_ANSI_V with kCGEventFlagMaskCommand, post keyDown+keyUp to
  kCGHIDEventTap), sleep paste_restore_delay_ms, restore snapshot ONLY if
  changeCount is still ours. NSPasteboard from the session thread is acceptable
  here (documented pattern); guard with try/except and never crash the session.
- `python -m wisprit.insert "text"` test mode: 3 s countdown then inserts into
  whatever is focused.

## history.py  (owner: agent D)

```python
class History:
    def __init__(self, path=runtime.HISTORY_DB_PATH, settings=None): ...
    def add(self, text, engine, duration_ms) -> int   # no-op if disabled
    def last(self, n=5) -> list[dict]                 # id, ts, text, engine
    def last_text(self) -> str | None
    def purge(self): ...
```
SQLite WAL, text only, trim to history_limit. Thread-confined to session thread
(document it; use check_same_thread=False but serialize via session).

## session.py  (owner: integration agent)

State machine IDLE→RECORDING→FINALIZING→INSERTING→IDLE (+CANCELLED path).
Consumes hotkey queue; debounce (<hold_debounce_ms press→release = discard,
prewarm reused); wires audio→asr feed; on release: `audio.stop()` →
`asr.finalize(full_pcm)` → `postprocess.process` → `insert.insert_text` →
`history.add`; per-stage ms logged to METRICS_LOG_PATH (one JSON line per
utterance). Esc during RECORDING/FINALIZING → cancel. Errors → pill error
state, never crash the loop. Master `enabled` toggle short-circuits presses.

## pill.py  (owner: integration agent)

Borderless non-activating NSPanel (~240×64 px max), joins all Spaces + floats
over full-screen (`NSWindowCollectionBehaviorCanJoinAllSpaces |
FullScreenAuxiliary`, level `NSStatusWindowLevel`), draggable
(`movableByWindowBackground`), position persisted to settings. API (all called
via ui.call_on_main): `show_recording()`, `update_level(float)`,
`update_partial(text)` (rolling last ~6 words), `show_finalizing()`,
`flash_success()`, `flash_error(msg)`, `hide()`. Default position
bottom-center of the main screen. Hidden entirely when `pill_hidden`.

## app.py + __main__.py  (owner: integration agent)

`app.py: main()` — bootstrap.ensure_state_dir(), Settings, Dictionary, History,
AsrManager (prewarm), NSApplication + NSStatusItem menu (Enabled ✓, Last 5
transcripts → click copies to clipboard, Paste Last Transcript, Open
Dictionary/Config, Run Doctor, Purge History, Quit), HotkeyListener on main
thread, Session thread start, then `NSApp.run()`. Status icon: SF Symbol or
text glyph reflecting state. `__main__.py`: `python -m wisprit [doctor|hotkey|insert ...]`
dispatch; bare = app.

## bootstrap.py + packaging  (owner: agent E)

`ensure_state_dir()` — create ~/.wisprit, write default config.json (from
settings.DEFAULTS) and starter dictionary.json (seed terms: InsForge,
MeetingScribe, Wispr Flow, Wisprit, Claude, Anthropic, MLX, Sharique, Khatri)
if missing. Also: `run.command` (chmod +x; `exec ~/.meetingscribe/venv/bin/python -m wisprit`
from the repo dir), `packaging/com.wisprit.app.plist` launchd template
(disabled-by-default instructions), `README.md` (what it is, the research
one-liner, install/permissions walkthrough from docs/SPEC.md
manual_setup_steps, usage, config/dictionary reference, troubleshooting table,
comparison blurb vs Wispr Flow), `.gitignore` (pycache, .DS_Store, *.log).

## Testing constraints for agents

- You CAN run: unit tests, `say`-synthesized-audio ASR probes, doctor checks,
  import smoke tests. Use `~/.meetingscribe/venv/bin/python` for everything.
- You CANNOT interactively grant TCC (Accessibility/Input Monitoring/Mic) — tap
  creation and event posting may legitimately fail in your sandbox; code must
  degrade with clear errors, and doctor must explain. Do NOT "fix" a TCC
  failure by weakening code.
- Never `pip install` anything new without noting it; the target set is already
  installed.
