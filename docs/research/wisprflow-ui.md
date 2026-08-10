# Wispr Flow UI — measured design reference (Aug 2026)

Research pass for the Wisprit UI redesign. Confidence key: **[MEASURED]** =
extracted programmatically from Wispr's own press-kit assets
(https://wisprflow.ai/media-kit — 9 product PNGs + `Flowbar.svg`) and site CSS;
**[DOC]** = stated in their help center; **[INFERRED]** = reasoned from those.

## The four things that make it look like Wispr Flow

1. Warm bone `#F5F4F0` chrome against `#FCFCFB` content — never gray-and-white.
   All neutrals shifted warm; no pure white anywhere in the chrome.
2. Deep teal `#034F46` as the only accent.
3. A very generous ~23pt content-card radius with flat, shadowless depth —
   value steps + 1pt `#EEEBE3` hairlines only. No vibrancy, no blur.
4. The cream-on-black pill: capsule waveform bars that collapse to dots.

## Condensed reproduction spec

```
SURFACES        window/sidebar/toolbar  #F5F4F0
                outer margin ring       #F4F3EC
                content card            #FCFCFB
                hairline & selection    #EEEBE3
TEXT            primary #1A1A1A · secondary #71716E · tertiary #A3A2A0
ACCENT          #034F46 (deep teal)
CHART RAMP      #1A5C5C #247872 #369489 #4DAA9D #68BDB0 #84CDC1 #9FD9CF
TYPE            body/UI Figtree (app is web-rendered; Electron-class) ·
                display EB Garamond (marketing only) · mono IBM Plex Mono
METRICS         toolbar 48pt · sidebar 216pt · nav row 36pt on 40pt pitch ·
                card radius ~23pt · card inset 8pt right/bottom · 4pt grid
DEPTH           no shadows, no materials — two-tone bone + hairlines
ICONS           stroke-only 1.5px @ 18px box, round caps (Lucide-family)
```

## Flow Bar (recording state) — exact geometry [MEASURED from Flowbar.svg]

Pill 96×27, radius H/2 (full pill), aspect 3.46:1. Fill `#1A1A1A`, 1px warm
stroke `#4D4A42`. Left: cancel — 18px circle `#71716E`, X stroke `#FCFCFB`
1.5px. Right: confirm — 18px circle `#FCFCFB`, check stroke `#1A1A1A`
(asymmetric weight: cancel recedes, confirm is primary). Waveform: 10 bars,
cream `#FFFFEB`, width 0.080H, pitch 0.152H, fully-rounded capsules, peak
0.509H, floor 0.080H = a perfect dot at silence, all centered on the midline.

States [DOC]: hidden by default on new installs; idle = collapsed bubble,
expands on hover; listening = live waveform that flattens after silence;
draggable with three snap zones (bottom/left/right edges, Esc cancels);
docked-vertical reflow; position persists. Right-click menu: hide 1h ·
settings · mic picker · history · paste last.

## The Hub (main window) [MEASURED + DOC]

Real traffic lights in a 48pt custom toolbar (hidden titlebar); 216pt sidebar
flush-left; content card `#FCFCFB` r≈23pt inset 8pt right/bottom. Sidebar rows
36pt on 40pt pitch, active row = filled `#EEEBE3` pill. Nav: Home ·
Notifications · Dictionary · Snippets · Style · Scratchpad · Insights;
Settings + Help pinned at bottom.

- **Home**: welcome header (total words + your shortcut), search, transcript
  history grouped Today/Yesterday/dates, hover-actions per row; right rail
  stats card (streak, avg WPM, total words, `1.22M`-style abbreviation).
- **Insights**: WPM as an animated semicircular gauge + global percentile;
  corrections count; total words with %-change badge; per-app horizontal bars
  (rank-colored from the teal ramp, % inside the bar); streak heatmap with a
  glow on the current streak; share-card carousel.
- **Dictionary**: tabs All/Personal/Team, sort incl. Starred-first, badges —
  sparkle = auto-learned, person = contacts, star = prioritized; cmd+F filter
  matching word AND replacement; multi-select; edit sheet.
- **Style**: category tabs (Personal/Work/Email/Other), style cards with LIVE
  example-text previews; four cleanup intensity levels with visual undo.

## Onboarding [DOC]

Card-per-step, one decision per screen. The pattern to steal: the **gated
permission cascade** (permission cards each with an Allow button; granting one
reveals the next) and the **in-context practice moment** (mic test with live
audio bars → shortcut config → "Try It Yourself" demo window that receives the
text). Ends by opening the Hub with a welcome message.

## Settings [DOC]

Two-level list (sections → subcategories), rows overwhelmingly binary toggles;
capability-gated sections disappear entirely rather than render disabled.
Context Awareness is split into two independently-toggled sub-settings
(AX text default ON, screen OCR default OFF) — granularity as a trust device.

## Platform reality [MEASURED]

The Hub is a cross-platform web UI (Electron-class): the Mac and Windows
screenshots are pixel-identical outside one sidebar rectangle. No SF Symbols,
no system materials, no dark mode observed anywhere.

## What Wisprit takes from this (redesign direction)

Adopt the **structure and quality bar, not the skin**: hub window with sidebar
+ inset rounded content card; a capsule-waveform pill with asymmetric
cancel/confirm and dot-collapse at silence; insights tiles; gated permission
cascade + practice moment in onboarding; toggle-first settings with
disappearing gated sections. Keep Wisprit's own identity (site palette:
aluminum `#F5F6F8` / ink `#191C20` / mic-orange `#F07818`) — and where Wispr
is Electron-flat by necessity, Wisprit is native SwiftUI and can use real
macOS materials, SF Symbols, and dark mode as differentiators.
