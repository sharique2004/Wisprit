# The living notch — how Wisprit shows it is hearing you

Status: shipped on `worktree-agent-a1d7af33b255340f4` (2026-11-06). Replaces the
dashed hairline (`NotchOutline`). Images: `docs/design/notch-listening/`.

## 1. The problem

The old indicator drew a 2 pt black hairline round the housing with white
dashes travelling along it. The plumbing was right (measured: up ~50 ms after
key-down, down ~135 ms after key-up), but:

- it read as a faint dashed line, not as "listening";
- every post-release call (`showFinalizing`, `showRefining`, every flash) just
  hid it, so a refine that ran for 0.4–7 s looked like nothing was happening,
  and success, a miss, an error and a secure-input block all looked the same:
  gone.

## 2. Research

| Reference | What it does | What we took |
|---|---|---|
| iPhone **Dynamic Island** (calls, Voice Memos, Siri on 15 Pro) | A pure-black shape continuous with the sensor housing; compact layout puts identity on the *leading* side and live data (call waveform, timer) on the *trailing* side; the shape leads and content materialises after it; collapse reverses (content out first, then shape); mild spring overshoot. | Black body grown from the housing, glyph left / meter right, shape-first open and content-first fold, ~4 % overshoot. (Observed behaviour; Apple publishes no values. A community recreation uses `spring(response: 0.7, dampingFraction: 0.7)`, which feels too slow for a push-to-talk key.) |
| **boring.notch** (open source; read `NotchShape.swift`, `ContentView.swift`, `sizing/matters.swift`, `MusicVisualizer.swift`, `BoringNotchWindow.swift`) | `NotchShape`: concave top corners (radius 6 closed / 19 open) flaring into the screen edge, convex bottom corners (14 / 24), filled `.black`. Open `.spring(response: 0.42, dampingFraction: 0.8)`, close `.spring(response: 0.45, dampingFraction: 1.0)`, hover `.interactiveSpring(0.38, 0.8)`. Closed live activities widen by `2·max(0, h−12) + 20` (≈ 60 pt at h = 32). Panel at `.mainMenu + 3`, `[.fullScreenAuxiliary, .stationary, .canJoinAllSpaces, .ignoresCycle]`, no shadow, never key. Visualizer: 4 `CAShapeLayer` bars, `transform.scale.y` to a random 0.35–1.0 every 0.3 s, auto-reversing, 24 fps cap. | The shoulder fillet and black fill; under-damped open / critically-damped close; wings ≈ 40 pt (between their 30 pt closed widening and a full open notch); same panel posture (we keep our own `mainMenuWindow + 2` with the `.popUpMenu` fallback). Their bars are random and audio-blind — ours follow the real meter. |
| **NotchNook, Alcove, DynamicLake** | Commercial hover-to-expand "Dynamic Island for Mac" utilities; reviews call Alcove the more polished. No public source or motion specs. | Confirms the idiom users already read as "the notch is alive". Nothing more concrete could be verified. |
| **Apple Intelligence Siri edge glow** (iOS 18 / macOS 15.1+) | The glow appears exactly while the mic is hot and changes character while thinking — recreations describe it as a privacy affordance users learn to trust. | The same contract as Wisprit's orange rule: orange **only** while the mic is live; a calmer, non-orange motion while processing. We do not copy the rainbow (orange is reserved). |
| **Wispr Flow** recording pill | Measured earlier in this repo (`BarSynthesizer.swift`): bars oscillate in place (no scroll), one shared loudness envelope, centre-weighted dome (edges 56 % of centre), per-bar jitter, 130–250 ms retargets. | Shared envelope × dome × per-bar wobble. We use continuous incommensurate sines instead of random retargets so the 60 fps spring has something smooth to chase. |
| superwhisper | Floating recorder window, not a notch surface. | Not studied further. |
| **macOS rendering** | `NSView.displayLink(target:selector:)` (macOS 14+) gives a `CADisplayLink` that follows the view's screen; `preferredFrameRateRange` caps ProMotion; layer edits inside `CATransaction.setDisableActions(true)` are not implicitly animated; `CALayer.render(in:)` skips masks, filters and 3D transforms. | Display link only while visible, capped at 60 fps; plain layers with no masks or filters, so the offscreen renderer draws exactly what the panel shows. |

## 3. Decisions

1. **The notch grows; nothing floats.** A pure-black body (`#000`, not
   `studio`) hangs from the screen's top row with concave shoulders and soft
   bottom corners. On a notched display it is drawn under the housing too, where
   the panel has no pixels, so its silhouette *is* the notch, made wider. It
   never leaves the menu-bar band: the panel is exactly the band's height, so
   window content cannot be covered by construction.
2. **Content rides the edges.** Each wing's content is positioned from the
   body's outer edge, so on open it slides out from *behind the camera* and on
   fold it slides back under it.
3. **Left = state, right = voice.** Left wing: the tally dot (orange only while
   the mic is live), then a sparkle, check, `?`, ear, `!` or lock. Right wing:
   seven 2.4 pt bars. Seven thin bars read as a voice; five read as a battery
   meter (compared side by side).
4. **Colour carries the state for peripheral vision** (the notch is never where
   you are looking): orange alive = hearing; white ripple = working; green =
   landed; ochre = needs you; red + shake = failed.
5. **No text.** Notices and live partials are dropped. A glanceable icon
   language replaces the pill's copy.
6. **Everything is pure.** `NotchLifecycle` (state + deadlines) and
   `NotchChoreography` (springs → `NotchFrame`) take time as an argument. The
   app drives them from a display link, the tests from a loop, the renderer from
   a script — one code path.

## 4. Geometry (14-inch MacBook Pro: housing 185 × 32 pt, menu bar 33 pt)

| | value |
|---|---|
| panel | housing + 2 × (wing 40 + shoulder 6 + motion pad 10) = 297 × 33 pt, top = screen top |
| open body | 265 × 33 pt (housing + 2 × 40; takes the 1 pt sliver under the housing) |
| folded body | 181 × 32 pt: 4 pt narrower than the housing, same depth, larger corner radius — wholly behind the camera |
| corners | bottom 11 pt, shoulders 6 pt (scaled by openness); cubic handles at 0.62·r for an eased, squircle-like curvature |
| content | centred 21.5 pt in from each outer edge |
| meter | 7 bars × 2.4 pt, pitch 4 pt (26.4 pt field), floor = 2.4 pt (a dot), peak 17 pt |
| tally | 8 pt dot; halo 12–26 pt following the voice; one 8→26 pt ring on mic-open |
| no notch | compact virtual notch 90 × menu-bar height (≤ 28), dropping out of the top edge from a zero-height sliver |

## 5. Motion

| what | value |
|---|---|
| open | spring response 0.36 s, damping 0.72 (≈ 4 % overshoot), launch velocity 3.2/s so it moves within 30 ms; > 97 % open by 250 ms |
| content reveal | `smoothstep` of openness 0.3 → 0.8, times a 0.16 s critically-damped fade |
| fold | content fades first (0.16 s); body follows after 70 ms on a spring of 0.30 s, damping 1.0; ~250 ms total; hard stop 0.6 s |
| level envelope | attack τ 35 ms, release τ 160 ms on `WaveformBuffer.shaped(level)` |
| bars | spring 0.13 s / 0.6; target = breath + (1 − breath) · envelope · dome · (0.32 + 0.68 · wobble) |
| silence | breathing swell travelling across the row, 2.2 s period, 5–18 % of travel; bars at 50 % alpha: clearly alive, clearly quieter than speech |
| speech | per-bar wobble from two incommensurate sines (2.1–5.3 Hz) per bar; warm underglow behind the meter rises with the voice |
| mic opens | dot pops 0.55 → 1 (spring 0.3 / 0.5), turns grey → orange, sends one ring (550 ms, ease-out cubic) |
| tint changes | 180 ms crossfade (orange → white at key-up) |
| finalizing | white ripple: a Gaussian bump crossing the row every 1.05 s, height + brightness |
| refining | sparkle glyph glinting in time with a slower 1.5 s ripple |
| success | check draws on (0.3 s); row nods (lifts to 42 % of the dome, centre-out stagger 30 ms) then settles to green dots; body breathes out a touch |
| missed | `?`, grey dots, head-shake 2.2 pt at 7.5 Hz decaying τ 0.15 s |
| error | `!` red, red dots, red ember wash in both wings, shake 3.5 pt at 9 Hz |
| too quiet / blocked | ear / lock in ochre (`attention`), ochre wash; no shake — nothing failed |
| frame clock | `NSView.displayLink`, 30–60 fps range, only while visible; ~15 µs main-thread work per frame (debug build) |

## 6. States

| phase | left wing | right wing | leaves when | at the latest |
|---|---|---|---|---|
| hidden | — | — | prewarm / record / processing / result | — |
| listening, mic not live (`showPrewarming`) | grey dot | grey breathing dots | `record`, or any closing call | 4 s (`prewarmTimeout`) |
| listening, mic live (`showRecording` + 20 Hz levels) | orange dot + halo (+ ring once) | orange meter | `showFinalizing`, a result, dismiss, session idle (+150 ms) | 3 s after the last level tick |
| processing · finalizing | small grey dot | white ripple | a result, dismiss, session idle (+150 ms) | 15 s after the last processing call |
| processing · refining | sparkle | slower white ripple | as above | as above |
| result · success | green check | green dots after a nod | dwell 0.62 s | — |
| result · missed | `?` | grey dots, small shake | dwell 1.0 s | — |
| result · too quiet | ochre ear | ochre low row, wash | dwell 1.7 s | — |
| result · error | red `!` | red dots, wash, shake | dwell 1.7 s | — |
| result · blocked secure | ochre lock | ochre dots, wash | dwell 2.4 s | — |
| collapsing | content fades, body folds | | the view reports folded | 0.6 s |

`showIdle`/`hide` fold immediately from any phase. `pill_hidden` hides at once,
without animation.

## 7. Turning off, provably

- **Every phase has a deadline** (table above). `NotchLifecycle.advance(to:)` past
  it always moves toward hidden, two hops at most. Worst case from any
  signal to hidden is 15.6 s (`worstCaseToHidden`). A fuzz test plays 2000
  random signal sequences (any order, stale, unstamped) and checks every one
  ends hidden within that bound.
- **Two clocks.** The display link renders and advances while visible; a 4 Hz
  heartbeat timer independently runs the deadlines, polls `pill_hidden`, and
  renders if the link has gone quiet for 200 ms. Both are torn down at hidden.
  Neither one is needed for the other to turn the notch off.
- **Stale calls cannot resurrect it.** `MainThreadPill` stamps each port call
  with a `NotchSequence` number *on the calling thread* before hopping to
  main. Opening signals older than the newest processing/terminal signal,
  processing signals older than the newest terminal one, and anything older
  than the open utterance are dropped. Levels never open anything.
- **The session's own word.** `AppController` forwards `session.onStateChange(.idle)`
  as `.sessionIdle`. It folds a live or processing notch after a 150 ms grace
  (the empty path reports idle *before* flashing the miss), never cuts a
  result short, and catches the correction-only exit, which ends with
  nothing but a `transientNotice`.
- **`pill_hidden`** is read on the calling thread (no hop when hidden), on
  every opening call in the indicator, and by the heartbeat; the Settings
  toggle also calls `hideImmediately()`.
- A new press always starts grey: a `prewarm` can never inherit an old orange.

## 8. Accessibility

- **Reduce Motion:** no morph (the body cross-fades in at full size), no bar
  motion (a fixed low dome), no ring, no shake, no glyph pop. The voice still
  shows, as the halo's brightness. Processing pulses opacity in place.
- **Increase Contrast:** a 1 pt white rim at 50 % on the silhouette (not the
  top edge), and bars at ≥ 90 % opacity.
- Both are re-read when `accessibilityDisplayOptionsDidChange` fires.

## 9. Verification

- `swift test --filter WispritMacUITests` covers geometry (8 tests), lifecycle
  (24), choreography (16) and the panel itself plus rendered pixels (9). The
  pixel tests check the orange rule on the real layer tree: orange present
  while live, zero orange pixels in prewarm, finalizing, refining and too-quiet.
- `Wisprit notch-demo --render DIR` produces every PNG in
  `docs/design/notch-listening/` offscreen, deterministically.
- `Wisprit notch-demo --shots DIR` drives the real panel on the real notch
  through five scripted utterances; the `live-*.png` files are crops of those
  captures.
- `WISPRIT_PREVIEW_NOTCH=listening|prewarming|finalizing|refining|success|missed|tooQuiet|error|blockedSecure`
  pins one state in the running app for screenshots (`1` = listening).

## 10. Open questions

- The hardware housing's bottom radius is not exposed by AppKit. The folded
  body uses 11 pt and sits 2 pt inside each side, which hides it for any
  housing radius up to ~11 pt. The backdrop in the renders assumes 9 pt.
- Wings cover ~40 pt of menu bar on each side of the notch while out. On a
  crowded menu bar that covers a status item or the end of the app menus for
  the length of a dictation.
- The blocked-secure remedy (⌘⌃V) is no longer spelled out on screen.
  The lock says *what* happened, not *what to do*.
- The 3 s silence watchdog assumes the session's 20 Hz level ticker. A
  configuration with `levelTickInterval == nil` (only the session tests use
  one) would fold a held key after 3 s. The app always arms the ticker.
- Motion was verified from frame-by-frame filmstrips and live stills. The
  springs have not yet been judged by a person watching them at full speed on
  this Mac.
