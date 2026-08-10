# Wisprit UI redesign — design + architecture spec

**Status:** normative. This document is the single source of truth for the UI
rebuild. Where it names a number, use that number. Where it names a file, that
is the file to create or modify.

**Companions:** [`docs/research/wisprflow-ui.md`](../research/wisprflow-ui.md)
(the measured competitive bar), [`docs/SWIFT-INTERFACES.md`](../SWIFT-INTERFACES.md)
(target ownership, frozen), [`site/styles.css`](../../site/styles.css) (the
shipped brand identity), [`README.md`](../../README.md) (product behaviour).

**Direction (settled — do not relitigate):** take Wispr Flow's *structure* and
*quality bar* — hub window with sidebar + inset rounded content card, capsule
waveform pill, insights page, gated permission cascade with a practice moment,
toggle-first settings whose gated sections disappear. Take none of its skin.
Wisprit's identity is the site's: cool aluminum ground, ink text, mic-orange
strictly for live states, a display serif used sparingly. Where Wispr is
Electron-flat by necessity, Wisprit is native and uses real macOS materials,
SF Symbols, full dark mode, and the system accent in the one place macOS users
expect it.

**Design school:** *Instrument* — a precision measuring device, not a
productivity app. Cool metal ground, monospace for machine-produced text,
proportional for prose, a single hardware-tally orange, numerals in a serif.
Depth is value steps and hairlines, not shadows.

---

## 0. Reading order for a build agent

| If you are building | Read |
|---|---|
| The pill | §1, §2, §6.1–6.3, §6.7 step 2–3 |
| The Hub shell | §1, §3.1–3.2, §6.1–6.5, §6.7 step 4 |
| Home / Dictionary / Insights / Settings / Setup | §1, §3.3–3.7, §6.4, §6.7 steps 5–9 |
| Onboarding | §1, §4, §6.7 step 10 |
| Menu bar | §1.7, §5, §6.7 step 11 |

**Hard rule for every agent:** §6.6 lists files the accuracy workstream is
editing right now. Do not edit them. Where this spec needs a change inside one,
it is written as a *request* with an exact description and a fallback that works
without it.

---

## 1. Design tokens

All tokens live in one new file, `Sources/WispritMacUI/Theme.swift`, as an
`enum Theme` of static `Color`s built from a `Color(light:dark:)` helper (see
§6.2). Nothing in the UI may use a literal color, `Color.blue`, `.red`,
`.green`, `.orange`, or `.quaternary` — those are the current window's
placeholders and they all go.

### 1.1 Palette — light

| Token | Hex | Use |
|---|---|---|
| `ground` | `#F5F6F8` | Window background, sidebar base, the ring around the content card |
| `groundRecessed` | `#EDEFF3` | Under-card wells, progress tracks, empty chart plates |
| `surface` | `#FFFFFF` | The content card, sheets, popover bodies, list rows |
| `surfaceRaised` | `#FFFFFF` | Sheets and popovers (identical fill; separated by shadow only) |
| `fillSubtle` | `#E7EAEE` | Chips, token pills, hover fills, unselected segment |
| `fillHover` | `#EDEFF2` | Row hover |
| `hairline` | `#E3E6EA` | Every 1 pt divider and card stroke (site `--line`) |
| `hairlineStrong` | `#D4D8DD` | Field borders, keycap edges |
| `ink` | `#191C20` | Primary text (site `--ink`) |
| `inkSecondary` | `#5A626C` | Secondary text, descriptions (site `--muted`) |
| `inkTertiary` | `#8A929C` | Metadata, group headers, axis labels — **≥ 11 pt medium only** |
| `inkQuaternary` | `#B4BAC2` | Disabled glyphs, chart gridlines — never text |
| `hot` | `#F07818` | **LIVE ONLY.** See §1.6 |
| `hotDeep` | `#D4650E` | Pressed/hover state of a `hot` fill |
| `hotText` | `#B4500A` | The only orange allowed as text on light (≈5.2:1) |
| `hotWash` | `#FDF6EF` | Tint behind a live row — one place only (§3.3) |
| `positive` | `#1F8A54` | Doctor `.ok` |
| `attention` | `#A16207` | Doctor `.warn` — **glyph and text only, never a fill wider than 16 pt** |
| `critical` | `#C4342B` | Doctor `.bad`, destructive actions, the unexplained-empty alarm |
| `studio` | `#0E1013` | The pill body, in both appearances |
| `studioInk` | `#E8EAED` | Text on `studio` |
| `studioMuted` | `#9AA3AD` | Secondary text on `studio` |
| `studioStroke` | `#FFFFFF` @ 14% | The pill's 1 pt rim |

### 1.2 Palette — dark

Chrome darker than card, matching macOS convention and Wispr's own two-tone
relationship.

| Token | Hex | Notes |
|---|---|---|
| `ground` | `#131619` | |
| `groundRecessed` | `#0E1114` | |
| `surface` | `#1B1F24` | Content card |
| `surfaceRaised` | `#21262C` | Sheets, popovers |
| `fillSubtle` | `#23272D` | |
| `fillHover` | `#1E2126` | |
| `hairline` | `#2A2F36` | |
| `hairlineStrong` | `#3A4048` | |
| `ink` | `#E9ECF0` | |
| `inkSecondary` | `#9AA3AD` | site `--studio-muted` |
| `inkTertiary` | `#6C757F` | |
| `inkQuaternary` | `#4A525B` | |
| `hot` | `#FF8A2B` | Brightened; `#F07818` goes muddy on near-black |
| `hotDeep` | `#F07818` | |
| `hotText` | `#FF9E4F` | |
| `hotWash` | `#2A1B0E` | |
| `positive` | `#46C98A` | |
| `attention` | `#D9A441` | |
| `critical` | `#FF6B5E` | |
| `studio*` | unchanged | The pill floats over arbitrary content; it is appearance-independent |

**Contrast contract.** `ink` on `surface` ≥ 13:1 both modes. `inkSecondary` on
`surface` ≥ 5.5:1. `inkTertiary` is a 3:1 token: legal at 11 pt medium and
above, illegal for body copy. `hot` on any light background is **2.9:1 and is
never text** — use `hotText`.

### 1.3 Type scale

Body stack is the system font (`Font.system`). SF Pro Text below 20 pt, SF Pro
Display at and above — `Font.system` picks this automatically.

| Role | Size / weight | Tracking | Use |
|---|---|---|---|
| `numeralXL` | Instrument Serif 40 | −0.4 | The one big number on a page (Home word count, a hero stat tile) |
| `numeralL` | Instrument Serif 28 | −0.2 | Insights tile values |
| `pageTitle` | 22 semibold | −0.2 | Content-card page header |
| `sectionTitle` | 15 semibold | 0 | Settings group headers, card headers |
| `rowTitle` | 13 medium | 0 | List row primary text |
| `body` | 13 regular | 0 | Descriptions, transcript prose |
| `caption` | 11 regular | +0.1 | Timestamps, chart labels |
| `captionEmph` | 11 medium | +0.3 | Day-group headers, badges |
| `mono` | SF Mono 11 regular | 0 | Machine text (§1.4) |
| `monoEmph` | SF Mono 12 medium | 0 | Latency readouts, metrics footer |

Three-level minimum on every page: `pageTitle` → `rowTitle` → `caption`.

**The serif appears in exactly two situations and nowhere else:** (a) numerals
in `numeralXL`/`numeralL`, (b) the onboarding cover title. Never a paragraph,
never a button, never a label. It ships as one file, one weight.

Bundling: add `InstrumentSerif-Regular.ttf` to `Contents/Resources/` and
`ATSApplicationFontsPath = Resources` to the Info.plist in
`packaging/make_app.sh` (see §6.7 step 1). `Theme.serif(_ size:)` must fall
back to `.system(size:design:.serif)` when the family is absent, so `swift run`
outside the bundle still renders.

### 1.4 The mono rule

**Monospace means "this text was produced by a machine and is still
provisional or is a literal value."** Proportional means "this is prose a human
said."

| Monospace | Proportional |
|---|---|
| The pill's live partial tail | Home's committed transcripts |
| The onboarding practice field's live text | Dictionary terms |
| Latency values, counts, percentages | Settings labels and descriptions |
| File paths, config keys, bundle IDs | Onboarding copy |
| `empty_reason` / `ai` / `outcome` vocabulary strings | |

### 1.5 Spacing, radii, sizing

4 pt grid; prefer 8 pt steps. Legal values: `2, 4, 8, 12, 16, 20, 24, 32, 40,
48, 64`. Nothing else appears in a `padding` or `spacing`.

| Radius | Value | Use |
|---|---|---|
| `rChip` | 3 | Inline chips, badges |
| `rControl` | 6 | Search fields, small buttons, sidebar selection |
| `rRow` | 8 | List rows, inner wells |
| `rButton` | 10 | Primary/secondary buttons |
| `rGroup` | 12 | Grouped blocks, sheet corners |
| `rTile` | 16 | Insights tiles |
| `rCard` | 18 | **The content card** |
| `rCapsule` | h/2 | The pill, tokens, the sidebar status dot |

Minimum hit target 28 × 28 for a row-trailing icon button (macOS convention,
not iOS's 44); 32 pt minimum row height; 44 pt when the row carries a
description line.

### 1.6 The orange rule (load-bearing)

`hot` / `hotDeep` / `hotText` / `hotWash` appear **if and only if the
microphone is currently open.** Three sanctioned sites:

1. The pill's waveform bars while `listening`.
2. The menu-bar icon while recording.
3. The Hub sidebar's status dot, and the onboarding mic-test bars — both of
   which are live-audio surfaces.

Everything else — selection, emphasis, primary buttons, warnings, charts, the
Insights palette, the streak heatmap — uses ink values, `positive`,
`attention`, `critical`, or the system accent. A reviewer seeing orange
anywhere else rejects the diff. This is what makes the app read as an
instrument with a tally light rather than "an app with an orange theme."

Corollary: **Doctor `.warn` is not amber-orange.** `attention` `#A16207` is a
dark ochre, used as glyph tint and text only, never as a fill.

### 1.7 Materials and elevation

One rule: **vibrancy only where the surface sits over content the app does not
own.**

| Surface | Treatment |
|---|---|
| Hub sidebar | `NSVisualEffectView`, material `.sidebar`, blending `.behindWindow`, state `.followsWindowActiveState`. This is the whole native-advantage moment. |
| Hub titlebar band | Transparent; inherits the sidebar material on the left and `ground` on the right |
| Content card | **Flat** `surface` + 1 pt `hairline` stroke. No material, no shadow — transcripts must be legible at any desktop |
| Insights tiles, settings groups | Flat; separated by hairlines and 20 pt gaps. **No nested cards** |
| Sheets / popovers | System default (`.regularMaterial` behind, system shadow) |
| The pill | **No material.** Opaque `studio` at 92% + 1 pt `studioStroke` rim + shadow `y 4, blur 14, #000 @ 28%`. Vibrancy over an unknown app's content is unpredictable and the pill must read on white and on black |

Depth is value steps + hairlines. The only drop shadows in the entire app are
the pill's, and the system's on sheets and popovers.

### 1.8 Iconography

SF Symbols only. No emoji anywhere in the UI (this retires the current
`🎙/🔴/…/⌨` menu-bar glyphs — see §5).

| Context | Config |
|---|---|
| Sidebar nav | `.font(.system(size: 15, weight: .regular))`, `.symbolRenderingMode(.hierarchical)` |
| List-row leading | 13 pt, `.medium` weight |
| Row-trailing actions | 12 pt, `.regular`, `inkTertiary` → `ink` on hover |
| Status glyphs (Doctor) | 15 pt, `.semibold`, filled variants for `ok`/`bad`, **outlined** for `warn` |
| Hero glyphs | 34 pt, `.light`, hierarchical |

Never `.palette` rendering except the Tally. Never `.multicolor`. Symbol and
color always co-vary so state survives greyscale (the existing `StatusDot`
already does this — keep the principle, restyle the colors).

---

## 2. The Pill

### 2.1 What it is now, and what changes

`Sources/WispritMacUI/Pill.swift` draws a 26 × 26 dot whose radius is
`6 + level × 5`, with a grey capsule bubble to its right. That is a faithful
port of `pill.py`. It is replaced by a **capsule waveform** driven by the real
mic peak level the engine already computes.

The state machine (`PillModel`), the text logic (`PartialTail`), the width
quantisation (`PillBubbleGeometry`), the panel plumbing and the drag-persist
contract are all correct and are **kept**. What changes is the drawn surface,
the geometry constants, the palette, and three new states.

### 2.2 Geometry (concrete)

```
                         96.0
   ┌───────────────────────────────────────────────┐
   │                                               │
   │   ▎ ▎ ▍ ▊ █ ▊ ▍ ▎ ▁ ▂ ▅ █ ▆ ▃ ▁                │  28.0   radius 14.0
   │                                               │
   └───────────────────────────────────────────────┘
    ↑11.75                                    11.75↑
        │← 15 bars · width 2.5 · pitch 5.0 →│
                 field = 72.5
```

| Constant | Value | Derivation |
|---|---|---|
| `height` | 28.0 | 4 pt grid; up from 26 to fit a legible meter |
| `radius` | 14.0 | h/2 — full capsule, as Wispr |
| `widthListening` | 96.0 | aspect 3.43 : 1 (Wispr measures 3.46 : 1) |
| `barCount` | 15 | Odd, so there is a true center bar |
| `barWidth` | 2.5 | 0.089·h (Wispr: 0.080·h) |
| `barPitch` | 5.0 | 0.179·h (Wispr: 0.152·h — ours is airier because we have 15 bars, not 10) |
| `barFieldWidth` | 72.5 | `15 × 5.0 − 2.5` |
| `barPeak` | 14.0 | 0.50·h (Wispr: 0.509·h) |
| `barFloor` | 2.5 | = `barWidth`, so silence is **a perfect dot**. This is the single best detail in Wispr's pill; it is kept |
| `sideInset` | 11.75 | `(96 − 72.5) / 2` |
| `barCountCompact` | 7 | Meter width when a text tail is present |
| `barFieldCompact` | 32.5 | `7 × 5.0 − 2.5` |
| `tailGap` | 8.0 | Between meter and text |
| `textInset` | 12.0 | Leading and trailing |
| `widthWithTail(w)` | `64.5 + w` | `12 + 32.5 + 8 + w + 12` |
| `tailMinWidth` | 44.0 | → panel 108.5 |
| `tailMaxWidth` | 196.0 | → panel 260.5 |
| `tailWidthStep` | 8.0 | Unchanged from today: quantisation is the anti-flicker mechanism |
| `bottomMargin` | 90.0 | Unchanged |

All bars are fully-rounded capsules (`cornerRadius = barWidth / 2`), centered on
the pill's vertical midline, growing symmetrically up and down.

### 2.3 Level → bars: the scrolling peak buffer

The engine gives **one scalar at 20 Hz** (`AudioPort.level`, ticked by
`SessionController.startLevelTicker` at `levelTickInterval = 0.05`). Fifteen
bars all bouncing to the same scalar looks like a toy. Instead the waveform
**scrolls**: a 15-slot ring buffer, newest on the right.

```swift
// Sources/WispritMacUI/WaveformBuffer.swift — pure, tested in WispritMacUITests
public struct WaveformBuffer: Equatable, Sendable {
    public static let levelReference = 0.35   // typical speech peak; voiced floor is 0.02
    public static let gamma = 0.7             // perceptual expansion of the quiet end
    public static let quantum = 1.0 / 64.0    // below this a push is a no-op

    public init(slots: Int)
    /// Shift left, append the shaped level. Returns false when the shaped value
    /// is identical to the previous newest slot AND every slot is already at
    /// floor — i.e. nothing to redraw.
    @discardableResult public mutating func push(_ level: Double) -> Bool
    /// 0…1 per slot, oldest first.
    public var normalized: [Double] { get }
    public mutating func collapse()           // all slots → 0, for finalizing
}
```

Shaping: `shaped(l) = clamp01(pow(clamp01(l / 0.35), 0.7))`, then quantised to
1/64. Bar height = `barFloor + (barPeak − barFloor) × shaped`. Bar alpha =
`0.45 + 0.55 × shaped`, so silence recedes to dim dots and speech is full
`hot`.

Two properties `WispritMacUITests` must pin:

1. **Scroll semantics.** `push(a); push(b)` leaves `normalized.last == shaped(b)`
   and `normalized[13] == shaped(a)`.
2. **Silence is free.** Fifteen consecutive `push(0)` calls produce exactly one
   `true` return (the first that changes anything); the rest return `false` and
   must not cause a redraw. This is what keeps a 20 Hz meter off the main
   thread's back while the hotkey tap is live.

### 2.4 States

| State | Panel | Body | Meter | Text | Exit |
|---|---|---|---|---|---|
| `hidden` | ordered out | — | — | — | — |
| `prewarming` | 96 × 28 | fades in 0 → 92% over 90 ms | 15 bars at floor, `studioMuted`, **not orange** | none | first level tick → `listening` |
| `listening` | 96 × 28 | `studio` 92% | 15 orange bars, scrolling | none | partial → `listening+tail`; release → `finalizing` |
| `listening+tail` | `64.5 + w` | same | 7 orange bars | mono 11, `studioInk` @ 92%, head-truncated | as above |
| `finalizing` | width held | same | bars desaturate to `studioMuted` over 120 ms, then collapse to floor with a 6 ms per-bar stagger | cleared | done → `committed` / `error` |
| `refining` | width held | same | as `finalizing` | leading 9 pt `sparkles` glyph, `studioMuted` | as above |
| `committed` | contracts to 28 × 28 circle | same | replaced by 13 pt `checkmark`, `studioInk` | none | 600 ms → `hidden` |
| `error` | width held, min 140 | `#2A1416` @ 94% | replaced by 13 pt `exclamationmark.triangle`, `critical` | mono 11, `critical`, ≤ 40 chars | 1600 ms → `hidden` |
| `blockedSecure` | width held, min 180 | `#2A1416` @ 94% | 13 pt `lock.fill`, `attention` | `"Secure input — ⌘⌃V to paste"` | 2600 ms → `hidden` |
| `notice` | `64.5 + w` | `studio` 92% | 11 pt `sparkle` glyph | mono 11, `studioInk` | 1600 ms → `hidden` or clear-bubble |

`prewarming`, `refining` and `blockedSecure` are new. `error` is not new but is
**newly legible** — see §2.7.

The `finalizing` state also draws a **sweep hairline**: a 1.5 pt capsule inset
12 pt from each side, 3 pt above the bottom edge, `studioMuted` @ 30%, with a
24 pt highlight at `studioInk` @ 70% translating left→right on a 900 ms
`.linear` repeating animation. No spinner, no rotation.

### 2.5 Transitions

| From → To | Duration | Curve |
|---|---|---|
| `hidden` → `prewarming` | 90 ms | `.easeOut` (opacity + 4 pt rise) |
| `prewarming` → `listening` | 140 ms | bar tint crossfade `.easeInOut` |
| level tick (bar heights) | 50 ms | `.linear` — matches the tick, so the scroll is continuous |
| newest bar entry | 160 ms | `.spring(response: 0.16, dampingFraction: 0.72)` |
| width change (tail grows) | 120 ms | `.spring(response: 0.28, dampingFraction: 0.9)` |
| `listening` → `finalizing` | 120 ms desaturate, then 6 ms × index stagger collapse | `.easeIn` |
| `finalizing` → `committed` | 140 ms | `.spring(response: 0.22, dampingFraction: 0.86)` |
| `committed` hold | 260 ms | — |
| any → `hidden` | 160 ms | `.easeIn` (opacity + 3 pt sink) |
| `→ error` | 100 ms | `.easeOut`, plus a single 2 pt horizontal shake (2 cycles, 180 ms total) |

**Reduce Motion** (`NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`):
the scroll animation is dropped (bars snap), the sweep hairline becomes a
static 40%-filled track, the shake is dropped, and `committed` cross-fades
instead of contracting. Durations survive; only motion goes.

### 2.6 Positioning

Existing behaviour is correct and is kept: default bottom-center at
`bottomMargin = 90`, persisted `pill_position` after a drag, origin fixed so
growth is rightward only. Two additions, both bug guards:

1. **Restore clamp.** If the saved origin is not inside any current
   `NSScreen.visibleFrame` (display disconnected, resolution change), fall back
   to the default placement rather than restoring an off-screen panel.
2. **Edge flip.** If `origin.x + newWidth > screen.visibleFrame.maxX − 8`, grow
   *leftward* instead — keep the right edge pinned. The dot stays where the
   user put it either way.

### 2.7 Existing code → new design

| File | Verdict | Detail |
|---|---|---|
| `WispritMacUI/PillModel.swift` | **Keep, extend** | The state machine is right. Add `.prewarming`, `.refining`, `.blockedSecure`; hold a `WaveformBuffer`; retain the error message instead of discarding it; add `showPrewarming()`, `showRefining()`, `flashBlockedSecure(_:)` |
| `PillRender` | **Extend** | Replace `dotRadius: Double` with `bars: [Double]`; add `message: String`; keep `isVisible`, `state`, `level`, `bubble`, `bubbleWidth`, `totalWidth`, `height` |
| `PillState` | **Extend** | Add three cases. Keep raw values of the existing five — `StatusMenuModelTests`/`PillModelTests` assert on them |
| `PillPalette` | **Replace** | The `pill.py` calibrated RGB triples go. Keep the `PillColor` value type (it is AppKit-free and usable from the pure target); source values from `Theme` |
| `PillGeometry` | **Replace constants, keep functions** | `clampLevel` unchanged. `successHideDelay 0.6`, `errorHideDelay 1.6`, `noticeDuration 1.6`, `bottomMargin 90` unchanged. Add `blockedSecureHideDelay = 2.6`. Everything dimensional is replaced per §2.2 |
| `PillBubbleGeometry` | **Rename + retune** | → `PillTailGeometry`. Keep `width(forCharacters:)` and the `widthStep = 8` quantisation **verbatim** — it is the anti-flicker mechanism and it is already tested. Retune `minWidth 40 → 44`, `maxWidth 184 → 196`, `height 20 → 28`, `gap 4 → 8` |
| `PartialTail.swift` | **Keep verbatim** | 3 words / 26 chars is right. `notice(_:maxCharacters:)` is already parameterised — errors call it with `40` |
| `Pill.swift` — `Pill` class | **Keep** | `Configuration`, panel construction, `restorePosition`, `windowDidMove`, `schedule`/`cancelTimer`, the "running without a pill" fallback: all correct. Add the §2.6 clamps |
| `Pill.swift` — `PillView: NSView` | **Delete** | Replaced by `NSHostingView(rootView: PillSurface(render:))` |
| `MainThread.swift` | **Keep verbatim** | |

**Performance requirement (non-negotiable).** The waveform is drawn with
`Canvas`, not 15 `RoundedRectangle`s. Fifteen shape views re-identified at
20 Hz on the same main thread that carries the CGEventTap is the one way this
redesign could make dictation worse. One `Canvas`, one draw pass, no view
identity:

```swift
Canvas(opaque: false, colorMode: .nonLinear, rendersAsynchronously: false) { ctx, size in
    for (i, v) in bars.enumerated() { ctx.fill(capsulePath(i, v, size), with: .color(barColor(v))) }
}
```

Combined with `WaveformBuffer.push` returning `false` on silence and
`PillModel` skipping `emit()` in that case, an idle-but-visible pill costs zero
redraws.

---

## 3. The Hub

### 3.1 Window

```swift
// MainWindowController.show(), replacing the current NSWindow setup
contentRect: NSRect(x: 0, y: 0, width: 1040, height: 700)
styleMask:   [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
minSize:     NSSize(width: 900, height: 600)
title:                    "Wisprit"        // KEEP — see the existing comment, it is load-bearing
titleVisibility:          .hidden
titlebarAppearsTransparent: true
isMovableByWindowBackground: true
isReleasedWhenClosed:     false
setFrameAutosaveName:     "WispritMainWindow"
```

Everything else in `MainWindowController` — the `.accessory → .regular`
activation flip, the one-way policy, the LaunchServices bounce with its
measured 0.25 s settle, `makeFirstResponder(nil)`, `windowWillClose`'s
`deactivate()` — is **kept verbatim**. That code encodes measurements; do not
touch it. Only the four lines above and the `contentView` root change.

### 3.2 Shell geometry

```
┌──────────────────────────────────────────────────────────────────────────┐
│ ● ● ●                     │                                              │ 52  titlebar band
│  (traffic lights)         │                                              │
├───────────────────────────┼──────────────────────────────────────────────┤
│                           │ ┌──────────────────────────────────────────┐ │
│  ○ Home                   │ │                                          │ │
│  ○ Dictionary             │ │            content card                  │ │
│  ○ Insights               │ │            surface, r18, 1pt hairline    │ │
│                           │ │            inset 10 all sides            │ │
│                           │ │            padding 24 / 20 / 24          │ │
│                           │ │                                          │ │
│  ─────────────────────    │ │                                          │ │
│  ○ Setup            (•)   │ │                                          │ │
│  ○ Settings               │ │                                          │ │
│                           │ │                                          │ │
│  ● Ready                  │ └──────────────────────────────────────────┘ │
└───────────────────────────┴──────────────────────────────────────────────┘
 ← 216 sidebar (.sidebar material) →│← 824 detail (ground) →
```

| Element | Value |
|---|---|
| Sidebar width | 216 fixed (`navigationSplitViewColumnWidth(min: 200, ideal: 216, max: 240)`) |
| Titlebar band | 52 pt; sidebar content begins below it |
| Nav row height / pitch | 32 / 36 |
| Nav row inset | 12 leading, 10 trailing |
| Selection | capsule `rControl` filled `Color.accentColor.opacity(0.16)`; symbol `Color.accentColor`; label `ink` |
| Content card | inset 10 all sides, radius 18, `surface`, 1 pt `hairline`, no shadow |
| Card padding | 24 horizontal, 20 top, 24 bottom |
| Content width | 1040 − 216 − 20 − 48 = **756** |
| Page header | 52 pt tall inside the card: `pageTitle` left, actions right |

**The system-accent exception.** Sidebar selection is the one place Wisprit
defers to the user's macOS accent color. Everywhere else uses tokens. Justify
it once, here, and nowhere else.

**Sidebar footer** (28 pt, above the bottom edge): a 6 pt dot + 11 pt label.
`Ready` (dot `positive`) · `Listening` (dot `hot`, the third sanctioned orange)
· `Needs setup` (dot `critical`) · `Dictation off` (dot `inkTertiary`). Driven
by `SessionController.State` + `SetupSummary.hero`.

**Nav items.** `WispritWindowModel.Tab` becomes:

| Case | Title | Symbol | Group |
|---|---|---|---|
| `home` | Home | `house` | top |
| `dictionary` | Dictionary | `character.book.closed` | top |
| `insights` | Insights | `chart.bar.xaxis` | top |
| `setup` | Setup | `checklist` | pinned bottom |
| `settings` | Settings | `gearshape` | pinned bottom |

`setup` carries a 6 pt trailing badge dot (`critical` when any
`SetupItem.isBlocking`, `attention` when any essential item is `.warn`, absent
otherwise).

> **Integration note.** `Tab.rawValue` is parsed by `WindowLaunch.parse` in
> `Main.swift` (`Wisprit window <page>`), and `Main.swift` is owned by the
> accuracy workstream. See §6.6 for the sequencing and the compatibility
> aliases (`status → setup`, `history → home`).

### 3.3 Home

```
┌────────────────────────────────────────────────────────────────────────────┐
│ Home                                            [ ⌕ Search transcripts   ] │ 52
├────────────────────────────────────────────────────────────────────────────┤
│                                                                            │
│  14,208                                     ┌────────────────────────────┐ │
│  ────────                                   │ TODAY                      │ │
│  words dictated · 62-day streak             │ 1,204 words · 38 dictations│ │
│                                             ├────────────────────────────┤ │
│  TODAY                                      │ SPEAKING RATE              │ │
│  ┌──────────────────────────────────────┐   │ 148 wpm  (median, last 30) │ │
│  │ Let's ship the pill redesign before  │   ├────────────────────────────┤ │
│  │ the demo on Thursday.                │   │ STREAK                     │ │
│  │ 14:32 · 11 words · apple_live · 0.4s │   │ 62 days                    │ │
│  │                      ⧉  ⌫  +  🗑     │   │ ▪▪▪▫▪▪▪ ▪▪▪▪▪▪▪ ▪▪▫▪▪▪▪ …  │ │
│  └──────────────────────────────────────┘   │ 18 weeks                   │ │
│  ┌──────────────────────────────────────┐   └────────────────────────────┘ │
│  │ Add Sharique to the invite.          │        ↑ 240 pt rail             │
│  │ 14:28 · 5 words · apple_live · 0.3s  │                                  │
│  └──────────────────────────────────────┘                                  │
│                                                                            │
│  YESTERDAY                                                                 │
│  ┌──────────────────────────────────────┐                                  │
│  …                                                                         │
└────────────────────────────────────────────────────────────────────────────┘
   ← 492 list →  ← 24 →  ← 240 rail →
```

**Component inventory**

| Component | File | Spec |
|---|---|---|
| `HeadlineCount` | `Window/HomeView.swift` | `numeralXL` serif count + `body` `inkSecondary` sub-line. Count = lifetime words from history |
| `TranscriptSearchField` | shared | 240 pt, `rControl`, `fillSubtle`, 12 pt `magnifyingglass` leading. Binds `model.historySearch` (new) |
| `DayGroupHeader` | shared | `captionEmph` `inkTertiary`, 20 pt above / 8 pt below. Labels: `Today`, `Yesterday`, then `EEEE, d MMM` |
| `TranscriptRow` | replaces the one in `RootView.swift` | 13 pt `body`, `lineLimit(3)`, `.textSelection(.enabled)`; caption line `HH:mm · N words · engine · D.Ds`; hover reveals 4 trailing icon buttons at 12 pt: `doc.on.doc` (copy), `text.insert` (paste at cursor via `session.requestPasteLast`-style path), `text.badge.plus` (add selection to dictionary), `trash` (delete this entry) |
| `StatTile` | `WispritMacUI/StatTile.swift` | `captionEmph` `inkTertiary` label, `numeralL` serif value, optional `caption` sub-line. 240 × 72 |
| `StreakGrid` | `WispritMacUI/StreakGrid.swift` | 18 weeks × 7 days, cell 8, gap 2 → 178 × 68. Four intensity steps of `ink` at α 0.08 / 0.22 / 0.45 / 0.75. Today's cell gets a 1 pt `ink` ring. **Not orange** |

**Data.** Rows come from `History.recent(limit:)` → `[HistoryEntry{id, ts, text,
engine, durationMs}]`, already paged by `WispritWindowModel.loadHistory` /
`loadMoreHistory` (page size 50). Word count is derived
(`text.split(whereSeparator: \.isWhitespace).count`). Streak, "words today" and
speaking rate are derived from `ts` + word count + `durationMs`.

**Do not** put the insertion tier on a Home row. The tier lives in
`metrics.log`, not in the history table; joining the two by timestamp is
fragile and would lie whenever a row was written but insertion failed. Tiers
appear on Insights only.

`Delete this entry` requires a `History.delete(id:)` that does not exist today.
Until `WispritPersistence` grows it, the `trash` action is **absent** (not
disabled). Requested in §6.6.

**Empty state.** No history: a single 96 pt-tall centered block — 28 pt
`waveform` glyph in `inkQuaternary`, `sectionTitle` "Nothing here yet.", `body`
"Hold 🌐 anywhere you can type." plus a `KeycapView` (§4.4). No illustration,
no button.

### 3.4 Dictionary

```
┌────────────────────────────────────────────────────────────────────────────┐
│ Dictionary        [ ⌕ Search              ]  [ Sort ⌄ ]      [ + Add Term ] │ 52
├────────────────────────────────────────────────────────────────────────────┤
│  Sharique                        ✦ Learned   ·  14×  ·  2 days ago      ⋯  │ 44
│  hears  “Shariq”  “Cherie”                                                 │
│ ───────────────────────────────────────────────────────────────────────────│
│  InsForge                                    ·  3×                      ⋯  │
│  hears  “in forge”  “ins forge”                                            │
│ ───────────────────────────────────────────────────────────────────────────│
│  Krzysztof                       ◷ Pending                [Accept] [Dismiss]│
│  hears  “Christoph”                                                        │
│ ───────────────────────────────────────────────────────────────────────────│
└────────────────────────────────────────────────────────────────────────────┘
```

| Element | Spec |
|---|---|
| Row | 44 pt (two lines), 12 pt vertical padding, hairline separator, `fillHover` on hover |
| Term | `rowTitle` |
| `hears` line | `caption` `inkTertiary` label + heard phrases as chips: `rChip`, `fillSubtle`, 11 pt, 6 pt h-padding. Max 3, then `+N` |
| Badges | trailing, `captionEmph` |
| Sort menu | A–Z · Recently used (`lastUsed`) · Recently added (`learnedAt`) · Most used (`hitCount`) |
| Search | Matches term **and** heard phrases — `DictionaryRow.matches(_:)` already does this. Bind `model.dictionarySearch` |
| `⋯` | Menu: Edit… · Delete… (destructive, confirm) |

**Badges, mapped to real data.**

| Badge | Glyph | Source | Availability |
|---|---|---|---|
| Learned | `sparkles`, `positive` | `DictionaryRow.isLearned` (`source == "spoken_spelling"`) | **Ships today** |
| Used N× | none | `DictionaryRow.hitCount > 0` | **Ships today** |
| Pending | `clock`, `attention` | `source == "offered"` | **Needs a session-layer write, no schema change** — see below |
| Starred | `star.fill`, `attention` | `DictionaryRow.starred` | **Needs a `WispritDictionary` change** — see below |

*Pending* is nearly free. `WispritCorrections`' three-way outcome already has an
"insert literally + offer" branch; if the session persisted that offer as
`LearnedTerm(term:heard:source: "offered")`, the badge and its Accept/Dismiss
actions come for nothing — `source` is a free string and the store already
round-trips unknown values. Accept rewrites `source` to `spoken_spelling` via
the existing `DictionaryEdit.plan` → `.rebuild` path; Dismiss calls
`DictionaryEditor.delete`. **Request this from the session/corrections
workstream (§6.6). Until it lands, no row ever carries the badge and nothing
breaks.**

*Starred* requires `DictionaryStore` to persist a `starred` bool and
`DictionaryRow` to expose it. That is another agent's target. **Until it lands,
omit the badge and the "Starred first" sort option entirely** — do not render a
disabled control.

**Add / Edit sheet.** 420 × 300, `rGroup`. Term field (13 pt, `rControl`);
"Wisprit sometimes hears" multi-line field (the existing
`DictionaryEdit.parseHearField` / `formatHearField` comma-or-newline contract is
kept); and a live preview strip — `mono` 11, `groundRecessed`, `rRow` — showing
the first heard phrase rewritten to the term. Footer: Cancel · Save
(`.defaultAction`). All writes go through `DictionaryEditor.save(original:term:
hear:)`, which already plans merge-vs-rebuild and says so; surface that: when
the plan is `.rebuild`, the sheet shows a `caption` `attention` line
*"Renaming or removing a phrase resets this term's learn date and use count."*
That is honest and it is already computable.

### 3.5 Insights

Two-column grid of 370 pt tiles (16 pt gap) inside the 756 pt content width;
tiles 3 and 4 span both columns.

```
┌────────────────────────────────────────────────────────────────────────────┐
│ Insights                            [ 7 days | 30 days | All time ]        │ 52
├────────────────────────────────────────────────────────────────────────────┤
│ ┌─────────────────────────┐  ┌──────────────────────────────────────────┐  │
│ │ UTTERANCES              │  │ RELEASE → TEXT                           │  │
│ │ 1,842                   │  │ 214 ms                                   │  │
│ │ ▁▃▂▅▇▄▃▂▆█▃▂▁▄▆▃▂▅▇▄▃▂  │  │ p50  ▓▓▓▓▓▓▓▓░░░░░░░░░░░░░  214           │  │
│ │ last 30 days            │  │ p90  ▓▓▓▓▓▓▓▓▓▓▓▓▓▓░░░░░░░  391           │  │
│ └─────────────────────────┘  │                    ┆ 400 ms reference     │  │
│                              └──────────────────────────────────────────┘  │
│ ┌──────────────────────────────────────────────────────────────────────┐   │
│ │ WHERE THE WORDS WENT                                                 │   │
│ │ ████████████████████████▓▓▓▓▓▓▓▓▓▒▒▒▒▒░░░░▚▚                         │   │
│ │ ■ im_streaming 1,102  ■ paste 508  ■ type 96  ■ im_commit 41  ▚ empty 95│ │
│ └──────────────────────────────────────────────────────────────────────┘   │
│ ┌──────────────────────────────────────────────────────────────────────┐   │
│ │ EMPTIES, EXPLAINED                              95 · 5.2% of holds   │   │
│ │ short_hold        ████████████████████ 41                            │   │
│ │ silent            ██████████ 22                                      │   │
│ │ produced_nothing  ██████ 14                                          │   │
│ │ starved           ███ 7                                              │   │
│ │ unclassified 11 — logged before reasons existed                      │   │
│ │ ─────────────────────────────────────────────────────────────────    │   │
│ │ ⚠ 6 unexplained (0.3%) — audible speech, clean finish, no text       │   │
│ └──────────────────────────────────────────────────────────────────────┘   │
│ ┌─────────────────────────┐  ┌───────────────────────────┐                 │
│ │ AI CLEANUP              │  │ VOCABULARY AT WORK        │                 │
│ │ cleaned      ████ 812   │  │ Sharique   ██████████ 14  │                 │
│ │ verbatim     ███ 640    │  │ InsForge   ████ 6         │                 │
│ │ skipped_...  ██ 210     │  │ Wispr Flow ██ 3           │                 │
│ │ timed_out    ▌ 12       │  │ 4 terms learned by ear    │                 │
│ └─────────────────────────┘  └───────────────────────────┘                 │
│ finalize p50 88 ms · p90 141 ms · timed out 12 (0.7%) · last 30 days       │ mono 11
└────────────────────────────────────────────────────────────────────────────┘
```

**Every tile, and exactly which field feeds it.** Source is
`MetricsSummary.summarize(MetricsWriter.readAll(), window:now:)` unless noted.

| Tile | Fields | Availability |
|---|---|---|
| Utterances | `summary.total`; sparkline from `MetricsSummary.windowed(rows:in:now:)` binned by `ts` | `ts` present on every row since the Python era. **Always available** |
| Release → text | `releaseToTextMsP50`, `releaseToTextMsP90` | **Optional.** Written only on rows that put text in front of the user. Both are `Double?`. Nil → sparse placeholder |
| Where the words went | `outcomes: [String: Int]` via `MetricsSummary.ranked` | `outcome` present on every row. Vocabulary: `im_streaming`, `im_commit`, `paste`, `type`, `blocked_secure`, `error`, `correction`, `empty`. **Always available** |
| Empties, explained | `empty`, `emptyRate`, `emptyReasons`, `unclassifiedEmpty`, `unexplainedEmpty`, `unexplainedEmptyRate` | `empty_reason` is post-Python. `unclassifiedEmpty` is reported **separately and never merged** — `MetricsSummary` is explicit about this and the UI must honour it |
| AI cleanup | `aiOutcomes: [String: Int]` | Only on rows where refine ran. **Tile is hidden entirely when `aiOutcomes.isEmpty`** — the gated-section rule |
| Vocabulary at work | `DictionaryRow.hitCount`, `DictionaryRow.isLearned` — from `DictionaryEditor.rows()`, **not** metrics | Hidden when every `hitCount == 0` |
| Footer strip | `finalizeMsP50`, `finalizeMsP90`, `timedOut`, `timedOutRate`, `summary.window.label` | `finalize_ms` and `timed_out` present since the Python era |

**Not available, and therefore not designed:**

- **Per-app breakdown.** `metrics.log` carries no bundle identifier. Wispr has
  this bar chart; we do not have the data. Adding a `bundle_id` field is a
  session-layer change with a privacy question attached — out of scope.
- **Global percentile / "faster than 87% of users".** There is no network, by
  construction. Never.
- **Words per minute against a population.** Same reason. Home's speaking-rate
  tile is self-relative and says so.
- **Time saved.** A fabricated number. Omitted deliberately (§7).

**The sparse-data contract (one rule, applied everywhere).** A tile whose
primary metric has fewer than **5** contributing rows renders: its label, a
dashed 1 pt `hairline` plate (`rRow`, height = the chart's normal height,
`groundRecessed` fill), and one line of 11 pt `inkTertiary` naming what it
needs — e.g. *"Needs 5 dictations. You have 2."* Never a zero. Never a chart
of one bar. Never a fake trend line.

**Chart color.** A five-step ink ramp, generated once in `Theme`:
`chartRamp = [ink α1.0, α0.72, α0.52, α0.36, α0.24]`, plus `critical` α 0.55
reserved for the `empty` segment and `positive` for nothing. No orange, no
categorical rainbow. Series are distinguished by ramp position and by an
always-visible label — never by hue alone.

**Window control.** Segmented, three options → `MetricsWindow(days: 7)`,
`MetricsWindow(days: 30)`, `MetricsWindow.all`. Default `30`. Persisted in
memory only, not in config.

**Threading.** `MetricsWriter.readAll()` parses the entire file. It runs on
`Task.detached(priority: .utility)`, is cached against the file's
`contentModificationDate`, and refreshes **only while the Insights page is
front-most and no dictation is in flight** — the same discipline
`WispritWindowModel` already applies to its 2-second tick.

> `DoctorFacts.metrics` already carries a `MetricsSummary` over
> `MetricsWindow(days: 14)`, produced by `Doctor.recentMetrics()`. Do **not**
> reuse it for Insights: it is a fixed window and it rides the expensive full
> probe. Insights owns its own read.

### 3.6 Settings

Toggle-first. Groups are hairline-separated lists **inside** the content card,
each with a `sectionTitle` header and 20 pt of air between groups. No nested
cards.

Row anatomy: `rowTitle` label, optional `body` `inkSecondary` description
beneath, control right-aligned. 32 pt without description, 44 pt with.

| Group | Row | Key | Control | Notes |
|---|---|---|---|---|
| **Dictation** | Dictation enabled | `enabled` | Toggle | master |
| | Dictation key | `hotkey` | Segmented `fn` / `right_option` | `WindowSettings.HotkeyOption`; description = `.explanation` |
| | Ignore taps shorter than | `hold_debounce_ms` | Slider 0–600 step 25 + `mono` readout | `WindowSettings.clampHoldDebounce` |
| | Language | `locale` | Menu from `DoctorFacts.installedLocales` | **New surface.** Hidden when `installedLocales.count < 2` |
| **Text** | Remove filler words | `filler_removal` | Toggle | |
| | End sentences with a period | `ensure_sentence_period` | Toggle | **New surface** |
| | Space before inserted text | `leading_space` | Segmented Automatic / Always / Never | |
| | Apps that get typed text | `terminal_bundle_ids` | Disclosure → editable list | **New surface**; `mono` rows |
| **AI cleanup** | Clean up with Apple Intelligence | `ai_cleanup` | Toggle | **Gated — see below** |
| | ▸ Skip transcripts longer than | `ai_cleanup_max_words` | Stepper 100–1000 step 50 | **New surface**, inside `Advanced`, visible only when `ai_cleanup` is on |
| | ▸ Give up after | `ai_cleanup_timeout_ms` | Stepper 4000–30000 step 1000 | as above |
| **Live Typing** | Type into the field as I speak | `live_typing` | Toggle | **Gated — see below** |
| | ▸ Keep the input source warm | `im_selection_policy` | Segmented warm / per_utterance | **New surface**, inside `Advanced` |
| | Apps that fall back to pasting | — | Read-only list from `Ports.liveTypingFallbacks()` → `[BundleVerdict]` | Hidden when empty |
| **The pill** | Show the floating pill | `pill_hidden` (inverted) | Toggle | |
| | Reset its position | `pill_position` | Button → `settings.set(.pillPosition, .null)` | **New surface**; disabled when already null |
| **History & privacy** | Save transcripts | `history_enabled` | Toggle | |
| | Keep at most | `history_limit` | Menu 100 / 500 / 1,000 / 5,000 | **New surface** |
| | Delete all transcripts… | — | Destructive button + confirm using `model.historyDeletionWarning` verbatim | |
| | *(static)* | — | `network.slash` glyph + "No network calls. Ever. Audio and text never leave this Mac." | Brand moment; 3 lines; no control |
| **Advanced** (collapsed) | Clipboard restore delay | `paste_restore_delay_ms` | Slider 100–2000 step 50 | `WindowSettings.clampPasteRestore` |
| | Give up on the final after | `finalize_timeout_ms` | Stepper 500–5000 step 250 | **New surface** |
| | Speech engine | `engine` | Menu, `auto` / `apple_live` only | **The unbuilt `mlx_whisper`/`faster_whisper` values are not offered** |
| | Reveal config.json / metrics.log / dictionary.json | — | Three `Button`s → `NSWorkspace.activateFileViewerSelecting` | |
| | Version | — | `LabeledContent`, `WispritVersion.string` | |

`mlx_model` is never surfaced — it is vestigial and the README says so.

**The gated-section rule** (Wispr's move, made honest):

- **Structurally impossible → the section does not exist.** No Apple
  Intelligence on this Mac (`facts.aiAvailable == false` *and* `facts.aiReason`
  indicates unsupported hardware) → the AI cleanup group is absent. No bundled
  input method (`LiveTypingMenuStatus.unsupported`) → the Live Typing group is
  absent.
- **Missing but fixable → one row, not a disabled control.** The group collapses
  to a single row: `sectionTitle` + one `body` line of explanation + a primary
  button wired to the matching `SetupFixKind`. Apple Intelligence switched off
  in System Settings → *"Turn on Apple Intelligence to let Wisprit clean up
  what it hears."* + **Open Apple Intelligence** (`.openAppleIntelligenceSettings`).
  Input method not installed / needs enable / needs update →
  *"Wisprit can type into the field while you speak. This installs a small
  input method and macOS will ask you to approve it."* + **Enable Live
  Typing…** (`.enableLiveTyping`).
- **Never render a disabled toggle.** The current `SettingsView` does exactly
  that for Live Typing; it goes.

Advanced sub-rows use a `DisclosureGroup` whose label is `caption` `inkTertiary`
"Advanced", 8 pt indent, and are only present when their parent toggle is on.

**Write path.** Every control goes through the existing
`WispritWindowModel.setX` setters, which already write through to `Settings`
one key per call. New keys need new setters on `WispritWindowModel` following
the identical shape (`@Published private(set)` mirror + `settings.set` +
`reloadSettings()` on appear). Extend `WindowSettings.writtenKeys` — it is the
list a test asserts against.

### 3.7 Setup (Doctor)

```
┌────────────────────────────────────────────────────────────────────────────┐
│ Setup                                        [ Copy diagnostics ] [ ↻ ]    │ 52
├────────────────────────────────────────────────────────────────────────────┤
│ ⚠  Slack is holding Secure Keyboard Entry. Dictation is blocked while it   │ ← banner, only
│    is focused.                                                             │   when non-nil
├────────────────────────────────────────────────────────────────────────────┤
│                                                                            │
│    ✓   Ready — hold 🌐 to dictate                                          │ 34pt glyph
│        Live Typing is off; Wisprit pastes at the end.                      │ + 22/13
│                                                                            │
│ ───────────────────────────────────────────────────────────────────────────│
│ ✓  Microphone                Wisprit can hear you.                         │ 44
│ ✓  Input Monitoring          Granted.                                      │
│ ✓  Accessibility             Granted.                                      │
│ ✓  Sending the paste keystroke                                             │
│ ✓  Speech model (en-US)      Installed.                                    │
│ !  Apple Intelligence        Not available — enable it in System Settings.  │
│                                                    [ Open Apple Intelligence ]│
│ ⊖  Live Typing               Off. Wisprit pastes at the end.                │
│                                                    [ Turn On Live Typing… ] │
│ ───────────────────────────────────────────────────────────────────────────│
│  Checked 4 seconds ago.                          [ Run the setup guide → ] │
└────────────────────────────────────────────────────────────────────────────┘
```

Entirely driven by what already exists — this page adds no new probing:

| Piece | Source |
|---|---|
| Banner | `WispritWindowModel.secureInputNotice` → `SetupChecklist.secureInputNotice(facts)` |
| Hero | `WispritWindowModel.summary` → `SetupSummary{hero, headline, subhead}`; glyph `checkmark.seal` (`positive`) / `exclamationmark.triangle` (`critical`) / `ellipsis.circle` (`inkTertiary`, `.checking`) |
| Rows | `WispritWindowModel.items` → `[SetupItem]`, in the order `SetupChecklist.items(from:)` returns: `microphone`, `input_monitoring`, `accessibility`, `post_event`, `speech`, `apple_intelligence`, `live_typing`, and `learned_terms` **only when suspects exist** |
| Row glyph | Restyled `StatusDot`: `.ok`→`checkmark.circle.fill` `positive`; `.warn`→`exclamationmark.circle` (**outlined**) `attention`; `.bad`→`xmark.circle.fill` `critical`; `isOff`→`minus.circle` `inkTertiary` |
| Row buttons | `item.fix` / `item.fixTitle` primary, and — new — `item.secondaryFix` / `item.secondaryFixTitle` as a secondary button. The current `OnboardingView.permissionPage` never renders the secondary fix; the `input_monitoring` and `post_event` rows both carry `.relaunch` / "Quit & Reopen Wisprit" and it matters |
| Note | `item.note` (e.g. `SetupChecklist.relaunchNote`) as a `caption` row with an `info.circle` glyph, `inkSecondary` — **not orange** |
| Fix dispatch | `WispritWindowModel.fix(_:)` → `SetupFixRunner.run(_:)`, unchanged |
| "Run the setup guide" | `model.beginOnboarding(resuming: false)` |
| "Copy diagnostics" | `Doctor.report(from: model.facts).rendered()` → pasteboard. `report(from:)` is the only public entry point and it is enough |
| "Checked N ago" | New `@Published private(set) var lastProbeAt: Date?` on the model, set in `refreshFull()` |

**Reminders.** `Doctor.reminders` (the 🌐-key setting and the external-keyboard
caveat) render as two `caption` `inkSecondary` rows under a "Can't be
auto-checked" header — but only when `GlobeKeySettings.current().isClear` is
false, or `hotkey == .fn`. Doctor has no Fn check; `GlobeKeyUsage` is the real
signal and it belongs here as an eighth row style: glyph `keyboard`, title
"The 🌐 key", detail `globeKey.advice`, fix `.openKeyboardSettings`
"Open Keyboard Settings".

---

## 4. Onboarding

### 4.1 Shape

A **sheet**, 560 × 520, `rGroup`, presented over the Hub — replacing today's
720 × 540 two-pane wizard. One card, one decision, per step. The left step-rail
goes: it advertises seven chores before the user has done one. A 3 pt segmented
progress rail at the bottom replaces it.

```
┌──────────────────────────────────────────────────────┐
│                                                      │ 40 top
│                    ⌗  (34pt glyph)                   │
│                                                      │ 24
│              Let Wisprit hear you                    │ 22 semibold
│                                                      │ 8
│      macOS asks once. Wisprit only listens while     │ 13 inkSecondary
│      you are holding the key.                        │ centered, 380 max
│                                                      │ 32
│              ┌──────────────────────┐                │
│              │   Allow Microphone   │                │ rButton, prominent
│              └──────────────────────┘                │
│                                                      │ 20
│         System Settings ▸ Privacy ▸ Microphone       │ mono 11 inkTertiary
│                                                      │
├──────────────────────────────────────────────────────┤
│ ← Back        ▬▬ ▬▬ ▬▬ ▭▭ ▭▭ ▭▭ ▭▭ ▭▭        Skip →  │ 56 footer
└──────────────────────────────────────────────────────┘
```

Footer: `Back` (text, `inkSecondary`, disabled on step 1) · progress rail
(8 segments, 24 × 3, 4 pt gaps, `fillSubtle` → `ink` when satisfied) ·
`Skip` (text, only when `step.isOptional` or the step is unsatisfied) or the
primary action. `Do this later` moves to a `⌘W`-equivalent close button in the
sheet's top-right (12 pt `xmark`), calling `model.dismissOnboarding()` — the
step is already persisted, so reopening resumes.

### 4.2 The cascade, mapped to Wisprit's real permission set

`OnboardingStep` gains **one** case; everything else is already in place. The
gating source of truth stays `OnboardingModel.isSatisfied(_:_:)` over
`OnboardingInputs`, which reads `SetupItem`s built by `SetupChecklist` from
`DoctorFacts` — i.e. Doctor is already the gate.

| # | Step | Gate (`OnboardingModel.isSatisfied`) | Decision | Fix action |
|---|---|---|---|---|
| 1 | `.welcome` | `welcomeAcknowledged` | Continue | — |
| 2 | `.microphone` | `item("microphone")?.isSatisfied` | Allow Microphone | `.requestMicrophone`, or `.openMicrophoneSettings` when denied |
| 3 | `.micTest` **(new)** | `micTestPassed` **(new input)** | speak once | none — this is the mic test |
| 4 | `.globeKey` | `globeKey.isClear` | Open Keyboard Settings / I use an external keyboard | `.openKeyboardSettings`, or `model.setHotkey(.rightOption)` |
| 5 | `.inputMonitoring` | `item("input_monitoring")?.isSatisfied` | Open Input Monitoring → Quit & Reopen | `.requestInputMonitoring`, secondary `.relaunch` |
| 6 | `.accessibility` | `item("accessibility")?.isSatisfied` | Open Accessibility | `.openAccessibilitySettings` |
| 7 | `.tryIt` | `didDictate` | dictate once | — |
| 8 | `.liveTyping` | `liveTypingSettled \|\| item("live_typing")?.isSatisfied` | Enable / Not now | `.enableLiveTyping` / `model.settleLiveTyping()` |

Ordering changes from today: `.globeKey` moves **before** `.inputMonitoring`,
because a user whose 🌐 key opens the emoji picker cannot succeed at `.tryIt` no
matter what they grant, and because it is the only step that can be resolved
without a system prompt. `.micTest` is inserted immediately after the mic grant
while the permission is fresh in mind.

`.globeKey` is skipped outright when `model.hotkey == .rightOption` — its
`isOptional` is already `true`, and `advanceOnboardingIfNeeded` will step past
it once `setHotkey(.rightOption)` is called. Make `isSatisfied(.globeKey, …)`
return `true` when the hotkey is `right_option`; that needs `hotkey` added to
`OnboardingInputs`.

**Wireframes for the two non-obvious steps.**

**Step 3 — mic test (the practice warm-up, and the second Tally):**

```
┌──────────────────────────────────────────────────────┐
│                  Say anything                        │ 22 semibold
│      Just checking macOS gave us the right input.    │ 13 inkSecondary
│                                                      │ 32
│      ┌────────────────────────────────────────┐      │
│      │  ▎▎▍▊█▊▍▎▁▂▅█▆▃▁▂▄▇▅▃▁▂▄▆▃▂▁▃▅▇▄▂▁     │      │ 44pt Tally
│      └────────────────────────────────────────┘      │  340 × 44
│                                                      │ 20
│              ✓  Heard you.                           │ positive, appears
│                                                      │  at first voiced peak
├──────────────────────────────────────────────────────┤
│ ← Back        ▬▬ ▬▬ ▬▬ ▭▭ ▭▭ ▭▭ ▭▭ ▭▭      Continue  │
└──────────────────────────────────────────────────────┘
```

Same `TallyWaveform` view, `barCount: 33`, `barWidth: 4`, `barPitch: 9`,
`height: 44`, `peak: 22`, `floor: 4`. Fed from a dedicated short-lived
`AudioPort` capture (started on step entry, stopped on exit — never left
running). Pass condition: any pushed level ≥
`MetricsSummary.voicedPeakThreshold` (`0.02`, a public constant — reuse it, do
not restate it). Continue is disabled until then, with the caption
*"Waiting for sound…"*. A 6-second timeout swaps in
*"Nothing yet — check System Settings ▸ Sound ▸ Input."* and enables Skip.

**Step 7 — the practice moment:**

```
┌──────────────────────────────────────────────────────┐
│                 Try it right here                    │ 22 semibold
│                                                      │ 8
│         Hold ┌────┐ , say a sentence, let go.        │ 13, inline KeycapView
│              │ 🌐 │                                  │
│              └────┘                                  │
│                                                      │ 24
│  ┌────────────────────────────────────────────────┐  │
│  │                                                │  │ 110pt field
│  │  the pill redesign ships thursday_             │  │ mono 13, provisional
│  │                                                │  │ text gets a hot
│  └────────────────────────────────────────────────┘  │ underline (1.5pt,
│                                                      │ offset 4) while live
│      ▎▎▍▊█▊▍▎▁▂▅█▆▃▁                                 │ 28pt Tally, inline
│                                                      │
│      ✓  That worked.                                 │ positive, on didDictate
├──────────────────────────────────────────────────────┤
```

The live underline on provisional text is a direct lift of the site's
`.volatile` rule (`text-decoration-color: var(--hot); thickness 1.5px; offset
4px`) — the same visual grammar on the site and in the app. It is the only
place in the Hub where `hot` touches text, and it is legitimate: that text is
literally being produced by an open microphone.

Gate is `didDictate`, which `WispritWindowModel` already computes two ways (a
history-timestamp baseline plus `noteDictationObserved()` fired from
`AppController` on `.inserting`) — no new plumbing.

### 4.3 Completion

Step 8's "Not now" and "Enable" both land on a completion card *inside the same
sheet* — do not add a ninth step:

```
        ✓  You're set.
   Hold 🌐 anywhere you can type.
   [ Open Wisprit ]     ← finishOnboarding(), sheet closes onto Home
```

`finishOnboarding()` already writes `onboarding_completed = true` and pins
`onboarding_step` to the last case; keep that contract.

### 4.4 `KeycapView`

The site's keycap, translated. `Sources/WispritMacUI/KeycapView.swift`, sizes
`.small` (28) and `.large` (74):

- `RoundedRectangle(cornerRadius: 16)` at 74 pt (6 at 28 pt)
- Fill: vertical gradient `#FFFFFF → #EEF0F3` light, `#2A2F36 → #1E2226` dark
- Stroke: 1 pt `hairlineStrong`
- Depth: a 3 pt offset copy behind, `#C9CDD3` light / `#0E1114` dark
- Content: `globe` symbol (or `option`) + 11 pt label
- **Held state:** `translateY(3)`, depth collapses, inset ring
  `hot` @ 55%, 2 pt. This is the fourth and final sanctioned orange — and it is
  correct: the key is held, so the mic is open.

---

## 5. Menu bar

### 5.1 Icon

Emoji glyphs (`🎙 🔴 … ⌨`) are replaced by images. `StatusMenu.install()` sets
`item.button?.image` instead of `.title`.

| App state | Symbol | Rendering |
|---|---|---|
| Idle, everything ready | `mic` | **Template** — macOS tints it for the menu-bar appearance |
| Recording | `mic.fill` | **Non-template**, tinted `hot` `#F07818`. The one non-template status image in the app, and the second sanctioned orange |
| Finalizing / inserting | `mic.fill` | Template |
| Dictation disabled (`enabled == false`) | `mic.slash` | Template |
| Needs setup (any `SetupItem.isBlocking`) | `exclamationmark.circle` | Template |

Configuration: `NSImage(systemSymbolName:accessibilityDescription:)` with
`.withSymbolConfiguration(.init(pointSize: 16, weight: .regular))`,
`isTemplate = true` except recording. Priority when states collide:
`needsSetup` > `disabled` > `recording` > `working` > `idle`.

`StatusMenuModel.glyph(for:)` and `glyph(forStateNamed:)` are **kept** (tests
assert on them and the menu title is still a fallback) but `StatusMenu` stops
calling them; a new `StatusMenuModel.iconSpec(for:)` returns
`(symbolName: String, isTemplate: Bool)` and is what the AppKit layer reads.
That keeps the decision pure and tested in `WispritMacUITests`.

### 5.2 Dropdown

`StatusMenuModel.build(_:)` already produces the right rows in the right order.
Two changes only:

1. `"Open Wisprit…"` → `"Open Wisprit"` and gains `⌘0` as its key equivalent
   (there is no other way back into an `LSUIElement` app whose icon is behind
   the notch).
2. A new row directly under it, present **only** when
   `StatusMenuState.needsSetup == true` (new field): `"Finish setup…"` →
   `MenuAction.openWindow` routed to the `setup` page. It sits above the first
   separator, tagged with `attention` via an `NSMenuItem.image`.

Final order:

```
Open Wisprit                              ⌘0
Finish setup…                                  ← only when blocking items exist
───────────────────────────────────────────
Dictation On                              ✓
AI Cleanup (Apple Intelligence)           ✓
Polish Last                               ▸    ← Clean up / Formal / Casual / As an AI prompt
Live Typing                               ✓    ← or "Enable Live Typing…" / "Update…" / inert
───────────────────────────────────────────
Recent transcripts                             ← inert label
  Let's ship the pill redesign before the…     ← last 5, elided at 48, click copies
  …
───────────────────────────────────────────
Paste Last Transcript  (⌘⌃V)
Open Dictionary…
Open Config…
Run Doctor…
Purge History
───────────────────────────────────────────
Quit Wisprit
```

`Open Dictionary…` and `Open Config…` still open the files in the user's
editor — that is the power-user path and it stays. The Hub's Dictionary page
and Settings page are the other path; both exist on purpose.

---

## 6. SwiftUI architecture

### 6.1 Target placement

`docs/SWIFT-INTERFACES.md` is binding: `WispritMacUI` depends on **`WispritKit`
only**. It cannot see `WispritPersistence`, `WispritDictionary`, or anything in
`WispritMac`. That constraint decides everything:

> **`WispritMacUI` owns anything expressible over `WispritKit` + Foundation +
> SwiftUI. `WispritMac/Window/` owns anything that needs `DoctorFacts`,
> `SetupItem`, `Settings`, `HistoryEntry`, `MetricsSummary`, or
> `DictionaryRow`.**

| New file | Target | Kind |
|---|---|---|
| `Theme.swift` | `WispritMacUI` | tokens (§1) |
| `WaveformBuffer.swift` | `WispritMacUI` | pure, tested |
| `TallyWaveform.swift` | `WispritMacUI` | SwiftUI view, value-parameterised |
| `PillSurface.swift` | `WispritMacUI` | SwiftUI view over `PillRender` |
| `KeycapView.swift` | `WispritMacUI` | SwiftUI view |
| `StatTile.swift`, `StreakGrid.swift`, `Badge.swift`, `SearchField.swift`, `SectionGroup.swift` | `WispritMacUI` | SwiftUI components, all value-in |
| `InsightsModel.swift` | `WispritMacUI` | **pure**, tested — see below |
| `HomeModel.swift` | `WispritMacUI` | **pure**, tested — see below |
| `HubShell.swift`, `HomeView.swift`, `DictionaryPage.swift`, `InsightsPage.swift`, `SettingsPage.swift`, `SetupPage.swift`, `OnboardingSheet.swift` | `WispritMac/Window/` | model-bound views |

**The neutral seam.** `InsightsModel` cannot name `MetricsSummary`. It takes a
value struct declared in `WispritMacUI` that `WispritMac` maps into:

```swift
// WispritMacUI/InsightsModel.swift
public struct InsightsInput: Equatable, Sendable {
    public var windowLabel: String
    public var total: Int
    public var outcomes: [String: Int]
    public var empty: Int
    public var emptyRate: Double
    public var emptyReasons: [String: Int]
    public var unclassifiedEmpty: Int
    public var unexplainedEmpty: Int
    public var unexplainedEmptyRate: Double
    public var timedOut: Int
    public var timedOutRate: Double
    public var finalizeP50: Double?, finalizeP90: Double?
    public var releaseP50: Double?, releaseP90: Double?
    public var aiOutcomes: [String: Int]
    public var dailyCounts: [DayCount]        // struct DayCount { day: Date; count: Int }
    public var vocabulary: [TermUse]          // struct TermUse { term: String; hits: Int }
    public var learnedTermCount: Int
}

public enum InsightTile: Equatable, Sendable {
    case value(label: String, value: String, sub: String?, spark: [Double])
    case latency(label: String, p50: Double, p90: Double, reference: Double)
    case stacked(label: String, segments: [(String, Int)])
    case ranked(label: String, rows: [(String, Int)], footnote: String?, alarm: String?)
    case sparse(label: String, need: String)   // the < 5 rows placeholder
}

public enum InsightsModel {
    public static let minimumRows = 5
    public static func tiles(from input: InsightsInput) -> [InsightTile]
}
```

`WispritMacUITests/InsightsModelTests.swift` then pins, with no disk and no
SQLite: the sparse rule at 4 vs 5 rows; `aiOutcomes.isEmpty` → tile absent;
`unclassifiedEmpty` never folded into `emptyReasons`; ranked ordering matching
`MetricsSummary.ranked`'s tie-break (count desc, then key asc); `releaseP50 ==
nil` → `.sparse`.

`HomeModel` follows the same shape:

```swift
public struct TranscriptItem: Identifiable, Equatable, Sendable {
    public var id: Int64, ts: Double, text: String, engine: String, durationMs: Double?
    public var wordCount: Int
}
public struct DayGroup: Identifiable, Equatable, Sendable { … }

public enum HomeModel {
    public static func groups(_ items: [TranscriptItem], now: Date, calendar: Calendar) -> [DayGroup]
    public static func streak(_ items: [TranscriptItem], now: Date, calendar: Calendar) -> Int
    public static func heatmap(_ items: [TranscriptItem], weeks: Int, now: Date, calendar: Calendar) -> [[Int]]
    public static func medianWPM(_ items: [TranscriptItem], sample: Int) -> Double?
    public static func filter(_ items: [TranscriptItem], query: String) -> [TranscriptItem]
}
```

An explicit `now` and `calendar` (never `Date()` or `.current` inside) is what
makes "Today/Yesterday" and streaks testable — the same discipline
`MetricsSummary.summarize(_:window:now:)` already uses.

### 6.2 The `Color(light:dark:)` helper

```swift
// WispritMacUI/Theme.swift
extension Color {
    init(light: UInt32, dark: UInt32) {
        #if canImport(AppKit)
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(hex: dark) : NSColor(hex: light)
        })
        #else
        self.init(hex: light)
        #endif
    }
}
```

Dynamic `NSColor` — not `@Environment(\.colorScheme)` branching in view bodies.
This makes the pill's AppKit layer and the Hub's SwiftUI layer read the same
token, and it keeps appearance changes free (no view invalidation).

### 6.3 Pill wiring and threading

Unchanged: `SessionController` runs on the `session` thread; the level ticker
runs on the `pill-level` thread at 20 Hz; `AppController.MainThreadPill` hops
every `PillPort` call to main via `WispritUI.callOnMain`; `PillModel` is
main-thread-only. Keep all of it.

Added discipline, all inside `WispritMacUI`:

1. `PillModel.updateLevel` pushes into `WaveformBuffer` and **only calls
   `emit()` when `push` returns `true`.** Silence costs zero redraws.
2. `PillSurface` draws the meter in one `Canvas`. No per-bar view identity.
3. `NSHostingView` is created **once** in `Pill.build()` and its root view's
   `render` is updated through an `@Observable` box, so a frame change is one
   property write, not a hosting-view rebuild.

### 6.4 Hub state flow

`WispritWindowModel` stays `ObservableObject` with `@Published private(set)`
mirrors and `@ObservedObject` at the view. It is under concurrent edit and it
works; migrating it to `@Observable` in the same pass as a visual rebuild is
two risks at once.

**New page models are `@Observable`** and are owned by `WispritWindowModel` as
plain stored properties:

```swift
@MainActor @Observable final class InsightsPageModel {
    private(set) var input: InsightsInput?
    var window: MetricsWindowChoice = .days30
    func refreshIfNeeded(force: Bool = false) async   // mtime-gated, Task.detached read
}
```

Threading rules, inherited from the existing model and non-negotiable:

- **No page adds main-thread work while a key is held.** `noteSessionState`
  already stops the 2-second tick for the duration of an utterance; the
  Insights refresh must check the same `isDictating` flag before starting.
- Every disk read (`MetricsWriter.readAll`, `History.recent`,
  `DictionaryEditor.rows`) goes through `Task.detached(priority: .utility)` and
  publishes back on the main actor. `WispritWindowModel.refreshRecents` and
  `loadHistory` already demonstrate the exact pattern — copy it.
- `Doctor.gatherInputSources` is **main-thread-only** (`TISCreateInputSourceList`
  asserts the main queue) while `Doctor.gatherBridge` must be **off** main
  (1 s ceiling). `Doctor.gatheringLiveTyping(_:)` is the correctly-sequenced
  entry point and is what the model already calls. Do not re-sequence it.

### 6.5 Window creation for an `LSUIElement` agent

No change to the strategy, which is already correct and measured:

- `Info.plist` keeps `LSUIElement = true`; `AppController.launch()` keeps
  `setActivationPolicy(.accessory)`.
- `MainWindowController.show()` flips to `.regular` on first use, raises with
  the self-activate → deferred → 0.25 s LaunchServices bounce, and **never
  flips back** (`windowWillClose` calls `NSApp.deactivate()` only). The comment
  block explaining why is a record of three failed alternatives — preserve it
  verbatim.
- `makeFirstResponder(nil)` on raise stays: it is what stops the practice
  field from scrolling the page.

Only the `NSWindow` configuration lines in §3.1 and the `contentView` root
change.

### 6.6 Integration touchpoints — files the accuracy workstream owns

**Do not edit these.** Every dependency on them is expressed as a request with
a working fallback.

| File | What the UI needs | Fallback if it does not land |
|---|---|---|
| `WispritMac/SessionController.swift` | `pill?.showPrewarming()` on key-down accept (before audio start); `pill?.showRefining()` when the refine pass begins; `pill?.flashBlockedSecure(detail)` instead of `flashError` when `Delivery.blockedSecure` | Pill renders `prewarming` never (goes straight to `listening`), `refining` identically to `finalizing`, and `blockedSecure` as a plain `error` with the existing `"secure field — press ⌘⌃V to paste"` message. **All three degrade silently.** |
| `WispritMac/SessionPorts.swift` | Three additive `PillPort` methods with default implementations (`extension PillPort { func showPrewarming() {} … }`) so no conformer breaks | as above |
| `WispritMac/AppController.swift` | `MainThreadPill` forwards the three new methods; `openWindow(tab:)` default changes `.status` → `.setup`; `StatusMenuState` gains `needsSetup` | Menu "Finish setup…" row absent; `openWindow()` lands on Home |
| `WispritMac/Main.swift` | `WindowLaunch.parse` accepts the new `Tab` raw values, with aliases `status → .setup` and `history → .home` so existing shell habits and the usage string keep working | `Wisprit window <page>` falls through to `.home`; nothing crashes |
| `WispritMac/Doctor.swift`, `DoctorProbes.swift` | Nothing. `Doctor.report(from:)` and `DoctorFacts` are consumed as-is | — |
| `WispritMac/Window/SetupChecklist.swift` | Nothing required. Optional: correct the "seven rows" doc comment (it builds up to eight) | — |
| `WispritPersistence/MetricsSummary.swift`, `MetricsWriter.swift` | Nothing. `summarize`, `windowed`, `ranked`, `voicedPeakThreshold` are all public and sufficient | — |
| `WispritPersistence/History.swift` | `func delete(id: Int64)` for the per-row trash action | The `trash` action is **absent** from Home rows |
| `WispritDictionary/DictionaryStore.swift` | A persisted `starred` bool | Star badge and "Starred first" sort are **absent** |
| `WispritCorrections` / session learn loop | Persist a passive offer as `source: "offered"` | Pending badge is **absent**; no schema change either way |
| `packaging/make_app.sh` | Copy `InstrumentSerif-Regular.ttf` into `Contents/Resources/`; add `ATSApplicationFontsPath = Resources` to the Info.plist | `Theme.serif` falls back to `.system(design: .serif)` and every layout still holds |

**Two real bugs found while grounding this spec — report them, do not fix them
in the UI pass:**

1. `AppController` builds `SessionController.Configuration` with
   `levelTickInterval: settings.pillHidden ? nil : 0.05` **captured once at
   construction**. Toggling "Show the floating pill" in Settings therefore does
   not re-arm the level ticker until relaunch. Every other config closure in
   that struct re-reads live settings; this one does not. Settings will show
   the toggle regardless — the fix belongs to whoever owns `AppController`.
2. `OnboardingModel.firstIncomplete` does not skip optional steps despite its
   doc comment saying it does. This is *fine* for the new cascade (an optional
   step still gets shown, with Skip enabled) but the comment should be
   corrected so the next reader does not "fix" it.

### 6.7 Implementation plan

Ordered. Each step is independently buildable and testable. Build with
`swift build --target <T> --scratch-path /tmp/wisprit-build-<T>` per the
contract.

| # | Step | Creates | Modifies | Test |
|---|---|---|---|---|
| 1 | **Tokens + font.** `Theme` with both palettes, type roles, spacing, radii, the `Color(light:dark:)` helper, `Theme.serif(_:)` with fallback | `WispritMacUI/Theme.swift` | `packaging/make_app.sh` (font + `ATSApplicationFontsPath`) | Snapshot-free: assert every token resolves and `serif` never returns nil |
| 2 | **Waveform core.** Ring buffer + shaping | `WispritMacUI/WaveformBuffer.swift` | — | `WispritMacUITests/WaveformBufferTests.swift` — scroll semantics, silence-is-free, clamp, NaN |
| 3 | **Pill surface.** New geometry + palette + states + `Canvas` view; swap `PillView` for `NSHostingView`; the two positioning guards | `WispritMacUI/PillSurface.swift`, `TallyWaveform.swift` | `PillGeometry.swift` (constants), `PillModel.swift` (3 states, error message, buffer), `Pill.swift` (hosting view, clamps), rename `PillBubbleGeometry` → `PillTailGeometry` | Extend `PillModelTests`: new states, error message retained, monotone tail width preserved |
| 4 | **Hub shell.** Window config, sidebar + material, content card, new `Tab` enum with badge, sidebar status footer | `WispritMac/Window/HubShell.swift` | `MainWindow.swift` (4 lines + root view), `WindowModel.swift` (`Tab` cases, `lastProbeAt`) | `WispritMacTests/WindowModelTests.swift` — tab raw values, badge predicate |
| 5 | **Setup page.** Hero + rows + secondary fixes + banner + 🌐 row + Copy diagnostics | `Window/SetupPage.swift` | — | Reuses `SetupChecklistTests`; add a rendering-input test asserting all 8 row ids appear in order |
| 6 | **Home.** `HomeModel` + page + stat rail + streak grid + search | `WispritMacUI/HomeModel.swift`, `StatTile.swift`, `StreakGrid.swift`, `Window/HomeView.swift` | `WindowModel.swift` (`historySearch`) | `WispritMacUITests/HomeModelTests.swift` — grouping across midnight, streak with a gap, empty input, WPM median |
| 7 | **Dictionary page.** List, chips, badges, sort, add/edit sheet with the rebuild warning | `Window/DictionaryPage.swift`, `WispritMacUI/Badge.swift` | — | Reuses `DictionaryEditorTests`; add a test that `.rebuild` plans surface the warning string |
| 8 | **Insights.** `InsightsModel` + `InsightsInput` mapper + page + charts + window control + mtime-gated read | `WispritMacUI/InsightsModel.swift`, `Window/InsightsPage.swift`, `Window/MetricsSource.swift` | — | `WispritMacUITests/InsightsModelTests.swift` — the five properties in §6.1 |
| 9 | **Settings.** Regrouped, all new keys, the gated-section rule | `Window/SettingsPage.swift` | `WindowModel.swift` (new setters + mirrors), `WindowSettings.swift` (`writtenKeys`) | Extend the `writtenKeys` assertion; a test per gating branch |
| 10 | **Onboarding.** Sheet, 8 steps, mic test, practice moment, progress rail | `Window/OnboardingSheet.swift`, `WispritMacUI/KeycapView.swift` | `Window/OnboardingModel.swift` (`.micTest` case, `micTestPassed` + `hotkey` on `OnboardingInputs`), `WindowModel.swift` (mic-test plumbing) | Extend `OnboardingModelTests` — new step order, globe-key skip on `right_option`, mic-test gate |
| 11 | **Menu bar.** `iconSpec(for:)`, template images, `⌘0`, the Finish-setup row | `WispritMacUI/StatusMenuModel.swift` (add `iconSpec`, `needsSetup`) | `StatusMenu.swift` (image instead of title) | Extend `StatusMenuModelTests` — icon spec per state, row present iff `needsSetup` |
| 12 | **Requests.** File the §6.6 asks against the owning workstreams; delete the now-dead `RootView.swift`, `StatusView.swift`, `HistoryView.swift`, `DictionaryView.swift`, `SettingsView.swift`, `OnboardingView.swift` once their replacements pass | — | — | Full `swift test` |

Steps 1–3 have no dependency on the Hub and can run in parallel with 4–5.
Steps 6–9 depend only on 4. Step 10 depends on 5 (it reuses the row styling).

---

## 7. Restraint pass

### The one signature element: **the Tally**

A live capsule waveform driven by the microphone's real peak levels, scrolling
right-to-left, collapsing to a row of perfect dots at silence. One component,
`TallyWaveform`, rendered at three scales:

| Scale | Where | Bars / width / pitch / height |
|---|---|---|
| 28 pt | The pill, and inline in the practice step | 15 / 2.5 / 5.0 / 28 |
| 44 pt | The onboarding mic test | 33 / 4.0 / 9.0 / 44 |
| 6 pt dot | The Hub sidebar footer | — (degenerate case: one bar) |

It is the **only** place mic-orange appears, and orange appears **only** when
the microphone is open. That coupling is the whole design: the app has a tally
light, and the tally never lies. Everything else — every card, chart, toggle,
badge, and selection — is built from ink values on aluminum. This is what the
120% goes into: the ring buffer, the perceptual shaping curve, the per-bar
spring, the dot-collapse, the zero-redraw silence.

### Deliberately not added

| Not added | Why |
|---|---|
| **Cancel / confirm buttons on the pill** (Wispr has both, measured at 18 px each) | Wisprit is push-to-talk. Releasing the key *is* confirm; Esc *is* cancel. Two click targets on a 28 pt panel during a key-hold is a solution to a problem the interaction model does not have |
| **Draggable snap zones and a docked-vertical pill reflow** | The pill already persists a free position. Three snap zones plus a vertical layout is a second geometry to maintain for a preference nobody has asked for |
| **A right-click pill menu** | The menu bar is one movement away and already has every one of those items |
| **Per-app insights** | `metrics.log` has no bundle identifier. Designing a chart for data that does not exist is how specs lie |
| **"Time saved" / typing-speed comparison** | Fabricated. Speaking rate is measured; time saved is a marketing number wearing a stat tile |
| **Any global percentile or leaderboard** | There is no network. Structurally impossible, and the impossibility is the product |
| **Snippets, Style presets, Scratchpad** (three of Wispr's seven nav items) | Wisprit does not have these features. Three empty pages is worse than three missing ones |
| **A notifications page** | An app with no network and no account has nothing to notify about |
| **Amber for Doctor warnings** | Amber sits 20° from mic-orange. A checklist with three amber dots would destroy the tally's meaning for the sake of a convention nobody would miss |
| **Colored / gradient / multicolor SF Symbols** | Hierarchical only. Depth is value steps and hairlines |
| **Card shadows anywhere in the Hub** | The only shadows in the app are the pill's and the system's on sheets |
| **A serif in body copy, buttons, or labels** | Two uses: numerals and one cover title. A display serif in a settings row is the exact tell of a design that mistook a font for an identity |
| **Migrating `WispritWindowModel` to `@Observable` in this pass** | It is under concurrent edit. New page models get `@Observable`; the old one migrates later, alone |
| **A "starred" badge / sort, and per-row transcript delete, shipped as disabled controls** | Both need another target's change. A missing affordance is honest; a permanently greyed one is a bug report waiting to be filed |

### 5-dimension self-review

| Dimension | Score | Note |
|---|---|---|
| Philosophy alignment | 9 | One school (Instrument), one signature, one orange rule that every other decision defers to |
| Visual hierarchy | 8 | Serif numeral → page title → row title → caption on every page; one dominant action per screen; the tally is the only thing that moves |
| Craft quality | 8 | 4 pt grid throughout, every dimension derived rather than picked, radii from a 7-value set, pill geometry from measured ratios |
| Functionality | 9 | Every tile names its source field; unavailable data is refused rather than faked; gated sections disappear; the pill gains three states that close real feedback gaps |
| Distinctiveness | 9 | Would be recognisable with the wordmark removed: cool aluminum, orange tally, serif numerals, monospace-for-machine-text |

No banned pattern present: no purple-blue gradient, no emoji-as-icon (the menu
bar's are removed), no left-border accent cards, no symmetric feature grid, no
neon-on-dark, no AI illustration, no Inter/Roboto.
