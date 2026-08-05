# Mac + iOS apps: feasibility research (August 2026)

Research pass for turning Wisprit into **native Mac and iOS apps, App Store ready**, keeping today's functionality and adding: (a) faster transcription, (b) live transcription streaming *into the target text field* while speaking, and (c) spoken spelling corrections — "actually it's S h a r i q u e" detected as a directive, retro-fixing the misheard word, never transcribed literally, and learned permanently in the dictionary.

Method: 7 research dimensions + adversarial verification of each dimension's load-bearing claims (13 agents, ~940 tool calls). Where claims were testable locally, agents **compiled Swift probes and measured on this machine** (M4, macOS 26.5.2, Xcode 26.6) rather than trusting docs. Probe sources are preserved in [probes/](probes/). One caveat: all speech-accuracy probes used `say`-synthesized audio — directions are trustworthy, absolute numbers need re-validation on real voice.

---

## Executive verdict

**Yes — both apps are buildable, on-device, with today's APIs.** Three findings reshape the spec:

1. **"App Store" means different things per platform.** iOS: App Store submission, full stop — feasible with the standard keyboard-extension architecture. macOS: the *full* Wisprit UX (Fn push-to-talk + live in-field streaming + retroactive correction) is **not reliably Mac App Store-shippable** — every serious competitor (Wispr Flow, superwhisper, MacWhisper, VoiceInk) distributes the real Mac product outside MAS via Developer ID + notarization, which your existing certificates cover. A reduced MAS SKU is possible as a second channel.
2. **Goal (c) — learned names actually *recognized* — is real and verified.** `DictationTranscriber` + `contextualStrings` turned "Hi **Cherie**" into "Hi **Sharique**" in an A/B probe on this machine. `SpeechTranscriber` provably ignores the same context (byte-identical output). The engines must be combined.
3. **Goal (b) — live in-field streaming — has a first-class mechanism on both platforms**, and on each one it's a mechanism **no shipping competitor uses**: a palette Input Method (the exact machinery Apple's own Dictation uses — verified: `DictationIM.app` is an IMKit palette IM) on macOS, and `setMarkedText` provisional text in a keyboard extension on iOS. Both give flicker-free underlined provisional text with clean retroactive replacement — a genuine differentiator.

Requirement-by-requirement:

| Requirement | macOS | iOS |
|---|---|---|
| Same functionality as today | ✅ native Swift rewrite (mandatory anyway — Python/venv violates MAS 2.4.5 and can't ship) | ⚠️ partial by construction: no global hotkey / no cross-app paste exists on iOS; keyboard extension is the only insertion path |
| Much faster transcription | ✅ engine already fast (42–268 ms release→final measured); the real win is restructuring the refine stage (~1 s for 40 words) and streaming during the hold | ✅ same SpeechAnalyzer stack on iOS 26; iPhone 12+ (older devices need the DictationTranscriber fallback) |
| Live text in the target field | ✅ via palette Input Method (Developer ID SKU); MAS SKU degrades to paste-at-end | ✅ via `setMarkedText` in the keyboard — architecturally available since iOS 13, unexploited by competitors |
| Spoken spelling correction + permanent learning | ✅ deterministic detection measured <0.1 ms, retro-edit via `insertText:replacementRange:` | ✅ even cleaner: the just-dictated words stay *marked*, so correction is a marked-text replacement, not backspace surgery |
| App Store ready | ⚠️ Developer ID primary + optional reduced MAS SKU (market-proven pattern) | ✅ App Store, keyboard extension + container app + App Intents |

---

## Verified empirical findings (this machine, re-runnable)

**ASR engines (probes: `probe.swift`, `bias.swift`, `dual.swift`, `lat.swift`, `resident.swift`, `dict_probe*.swift`)**

- `bestAvailableAudioFormat` for both transcribers = 1 ch / 16 kHz / Int16 — Wisprit's existing pipeline format is already optimal.
- Release→final: **42–268 ms** (SpeechTranscriber), 71–190 ms (DictationTranscriber). Sub-400 ms target holds.
- **The biasing asymmetry, A/B verified:** with `contextualStrings = ["Sharique","Wisprit","InsForge",…]`, SpeechTranscriber output was byte-identical with/without context ("Hi, Shariq… Whisper Dendon's Forge"); DictationTranscriber flipped "Hi Cherie" → "Hi Sharique". Confirmed unchanged in the iOS/macOS 27 betas — do not wait for Apple.
- Biasing is a probability nudge, not a guarantee: it failed on a bare two-word utterance ("Sharique Khatri" → "Cheri Cuttery"). The dictionary regex post-pass stays as the net.
- **`SFCustomLanguageModelData` / `CustomPronunciation` is a trap:** builds, exports (0.01 s), prepares (0.87 s, 6.55 MB) — and had **zero measurable effect** in two probes. Also there is no system grapheme→phoneme API left (`NSSpeechSynthesizer.phonemes` returns error −50 on 26.5, never existed on iOS). Don't budget time here.
- Both modules in one `SpeechAnalyzer` works but blows release→final to 1377–1790 ms — dual-engine must be off the paste path (async reconciliation over retained PCM).
- Conflicting probe results to re-settle in a spike (different agents measured opposite outcomes, likely config-sensitive): (i) whether a **resident analyzer + `finalize(through: nil)`** works (one probe: 12/12 at 74–305 ms) or hangs (another: >70 s with a `CMTime` target); (ii) whether `.fastResults` yields genuinely early partials or partials that track end-of-audio; (iii) `contextualStrings` cost per term (+4 ms/term to n=500 on a long-lived analyzer vs +7 ms/term session-per-utterance — the verifier's stronger result says **ship the whole dictionary on a long-lived DictationTranscriber, no 50-term cap**).
- DictationTranscriber gotcha: with default `reportingOptions` you may get **no final at all** — set `.frequentFinalization` (or take the last volatile). Silent total data loss otherwise.
- Rapid back-to-back sessions (<4 s apart) with alternating module configs corrupted the results stream; keep engine config stable, use `SpeechModels.endRetention()` when switching.
- Device floor: SpeechTranscriber needs a 16-core ANE — **iPhone 12+**; iPhone 11/SE2 and the **entire iOS Simulator** return `isAvailable == false`. DictationTranscriber fallback is mandatory, and dev/CI needs a simulator stub.

**Spelling corrections (probes: `spell_probe.py`, 18 utterances through the repo's own `apple_live`)**

- SpeechTranscriber's inverse-text-normalization emits spelled letter runs as **uppercase tokens** ("S. H. A. R. I. Q. U. E." → `S-H-A-R-I-Q-U-E`; sometimes glued/space-broken — uppercase is the invariant, not the hyphen). Detection is a **regex, not an ML problem**, <0.1 ms.
- Trigger phrases are the *unreliable* part ("that's spelled" transcribed as "Let's spell") — key on the letter run; use the trigger only as a confidence booster. NATO alphabet and "S as in Sam" are non-functional — don't build on them.
- **The existing refine stage destroys spelled runs** (`S-H-A-R-I-Q-U-E` → "Sharifue", non-deterministically). A `_has_letter_run()` bypass in refine, mirroring `_has_address()`, is a blocking prerequisite.
- FoundationModels as the detector: measured 759–2325 ms, wrong 3–4/10, never joined letters correctly. Strictly worse than the regex — LLM only as an off-path arbiter for the low-confidence branch.
- Antecedent matching ("which word did they mean?"): hybrid scorer `max(0.6·DoubleMetaphone-code-similarity + 0.4·JaroWinkler, 0.9·JaroWinkler)`, threshold ≈ 0.62 — separated 12/14 true misrecognition pairs from 8/8 false pairs, <0.1 ms. Hard tail: when ASR mangles beyond phonetic recovery (Krzysztof→"Cherie", 0.38), **never retro-delete** — insert literally and offer the fix passively. That branch is what protects user text.
- The learn loop needs no G2P: the ASR's own wrong output ("Cherie", "Shariq") **is** the pronunciation evidence — it goes straight into the existing `hear:[]` array, feeding both the regex pass and `contextualStrings`.

**macOS live in-field streaming (verified on this machine + source-level evidence)**

- macOS Dictation **is a palette input method** (`/System/Library/Input Methods/DictationIM.app`, IMKit, enabled-but-unselected in `AppleEnabledInputSources`). Third-party palette IMs demonstrably get a live `IMKTextInput` client and call `insertText:replacementRange:` into arbitrary apps (IPAPalette, open source). Apple's own `IMKInputController.h` documents `replacementRange` for exactly the synonym-replacement (= retroactive correction) case.
- Marked text is *designed* for wholesale replacement at 5–15 Hz (CJK IMEs do it on every keystroke) — no flicker problem at Wisprit's 3–10 Hz partial cadence, one undo step per committed chunk, and it works in terminals (retires the typed-injection special case in the IM tier).
- The AX write path (`kAXSelectedTextAttribute`) is a false friend: silently no-ops in Chrome, Mail, VS Code, Google Docs, Electron. Even Talon only *reads* via AX and writes with keystrokes. AX = read-only context source, Developer ID SKU only.
- Unverified-but-plausible (needs the 3-day spike below): selecting the palette IM on Fn-down acquires the client for the *already-focused* field without a focus change, and cold-start cost of the IM process on first use.

**Distribution (macOS) — the three-TCC-services decomposition (Apple DTS, verified sources)**

- `ListenEvent` (Input Monitoring — the Fn tap) and `PostEvent` (CGEvent.post — the ⌘V paste) **are** App Sandbox/MAS-compatible. `Accessibility` (AXUIElement) is **categorically impossible** in a sandboxed app — no prompt, can't be granted manually.
- App Review is inconsistent on 2.4.5 regardless: WhisperPad had an *update* rejected for CGEvent.post after prior approvals ("Accessibility features should not be used for non-accessibility purposes"); Voice Type and Whisper Notes ship the same pattern approved. A MAS SKU must budget for rejection roulette and keep a clipboard-only fallback build ready.
- Input methods cannot ship via MAS (2.4.5(ii): nothing may install into `~/Library/Input Methods`). `RegisterEventHotKey` (the zero-TCC MAS-safe hotkey) **cannot bind Fn** — Fn requires the event tap. So the MAS SKU keeps ⌘/⌃-chord push-to-talk + paste-at-end; the Developer ID SKU keeps Fn + IM streaming + AX read-back.
- The market vote: MacWhisper's own docs say dictation is direct-only "due to restrictions that Apple puts on apps sold on the Mac App Store"; superwhisper's App Store listing is iOS/visionOS only; Wispr Flow is .dmg-only.

**iOS insertion — the mic wall and the session model (SDK-header + DTS-verified)**

- Keyboard extensions **cannot access the microphone** — documented, enforced at the CoreAudio sandbox level, unchanged through iOS 26/27, and Full Access does not grant it. Every shipping competitor uses: keyboard = trigger + inserter; **container app = recorder/transcriber**, foregrounded once per session, then `UIBackgroundModes: audio` keeps the mic across app switches (Wispr Flow's 5-minute-idle "session"); App Group + Darwin notifications for IPC.
- DTS blessed the keyboard→own-container-app launch under 4.4.1 (Jan 2026, thread 812091). Two iOS-26-era regressions: `open(_:)` from the keyboard now needs Full Access, and **iOS 26.4 killed host-app identification**, so auto-return to the host app is dead — first dictation per session costs one visible app switch + a manual swipe back (Wispr Flow ships an explainer for exactly this). No API for the return leg, none planned.
- Keyboard memory ceiling ~30–70 MB: ASR and FoundationModels must live in the container. Every live partial crosses a process boundary (App Group file + Darwin notification — notifications carry no payload).
- 4.4.1: the keyboard must work without Full Access → a real minimal QWERTY (with globe key) is mandatory shipping scope. Consider licensing **KeyboardKit Pro**, which already implements the dictation round-trip, audio bridge, and iOS 26.4 workarounds.
- Free fallback tier worth shipping: on Face-ID iPhones the *system* dictation mic button still appears above third-party keyboards, and the keyboard receives `textDidChange` with committed text — Wisprit can apply dictionary + refine on top of Apple's dictation with no mic, no Full Access, no app switch.

**Engine alternatives (research complete; this dimension's verification pass failed on an API error — treat numbers as vendor-reported, decision direction is safe because v1 doesn't depend on it)**

- The only OSS engine that earns a slot is **Parakeet via FluidAudio** (Apache-2.0, CoreML/ANE) — not for speed (ASR is not the bottleneck; the refine stage is) but for its CTC **vocabulary boosting**: `CustomVocabularyTerm(text:aliases:)` is a 1:1 match for the `{term, hear:[]}` schema, with byte-range candidate scoring (`ctcTokenEvaluateCandidates`) that gives acoustic evidence for corrections. TDT-CTC-110M is the right size (~66 MB, 3.01 % WER, built-in CTC head). Optional post-v1, macOS first.
- **WhisperKit large-v3-turbo (MIT) replaces mlx-whisper** as the long-tail-language fallback, killing the Python/MLX dependency. Ship as an optional Background Assets pack (on-demand resources are deprecated as of iOS 27; the 200 MB cellular cap forces asset packs for big models).
- Rejected: Moonshine (no ANE path on iOS, non-commercial non-English weights), Kyutai (1B params, no win), Argmax Pro SDK ($1,000+/mo license floor).

---

## Recommended architecture

**One shared Swift core, three thin shells.** The core (postprocess rules, dictionary + learn loop, refine cage, history, settings, metrics, correction detector) is pure logic — port it 1:1 from Python with the existing tests as the conformance suite. Shells: macOS menu-bar app (hotkey/pill/insertion), macOS palette IM bundle (Developer ID SKU only), iOS container app + keyboard extension.

**Engine layer (both platforms):** `SpeechTranscriber` session-per-utterance for the live path (punctuation, casing, best general accuracy) + `DictationTranscriber` with the full learned dictionary as `contextualStrings` as the vocabulary channel, reconciled off the paste path; dictionary regex remains the final net. Exact split (long-lived vs per-utterance, single vs dual analyzer) is Spike S1.

**Insertion ladder, macOS (probe per bundle ID, cache verdict):** IM marked-text streaming → IM commit-only → paste-at-end (today's clipboard dance, kept byte-for-byte) → typed unicode → `blocked_secure`. MAS SKU enters the ladder at tier 3.

**iOS:** container-app session model (mic held via background audio, visible indicator per 2.5.14), keyboard streams partials from the App Group into `setMarkedText`, commits after refine + dictionary, correction directives replace marked text. App Intents `DictateIntent` (Action Button / Control Center / Siri) ships first as the zero-review-risk trigger path.

**Corrections (both platforms), five layers:** (0) letter-run bypass in refine — blocking prereq; (1) regex detection on raw ASR finals; (2) phonetic antecedent scorer, threshold 0.62; (3) three-way action branch — high-confidence retro-edit / insert-literally + passive offer / same-utterance-tail replace — never retro-delete without a confident antecedent; (4) learn loop: `hear:[]` gets the ASR's own misrecognition, feeds regex + `contextualStrings`, syncs Mac↔iPhone via iCloud/App Group.

## Build plan

- **Spikes first (~1 week, on-device):** S1 engine split (resident-vs-per-utterance, `.fastResults` partial timing, DT `contextualStrings` at n=full-dictionary — settles the conflicting probe results); S2 minimal palette IM (select-on-Fn-down → client for already-focused field? latency? `insertText:replacementRange:` support matrix across TextEdit/Safari/Chrome/Slack/VS Code/Terminal/Notes/Mail); S3 iOS keyboard `setMarkedText` streaming cadence against Messages/Mail/Safari/Slack on a real iPhone; S4 spelling probes re-run on recorded human speech (3+ speakers).
- **Phase 1 — Swift core + Mac app (Developer ID), feature parity.** Port checklist = the repo-inventory contract (hotkey semantics incl. dirty-chord + watchdog, insert cascade incl. 500 ms conditional clipboard restore, refine cage + rehearsal battery, doctor, history-before-insert, metrics schema). Explicit re-decisions: polish→FoundationModels modes or claude-CLI detection kept as a non-MAS extra; fallback chain→WhisperKit; flock→`NSRunningApplication`; self-compile bootstrap→gone (helpers in-bundle, one signed identity — also fixes the TCC-identity gotcha); launchd→`SMAppService`.
- **Phase 2 — live streaming + corrections on Mac** (IM tier + detector + learn loop).
- **Phase 3 — iOS app** (container + App Intents first, then keyboard with marked-text streaming; TestFlight early — the keyboard install flow needs real-device validation).
- **Phase 4 — store hardening:** privacy manifests, usage strings (`NSSpeechRecognitionUsageDescription` is required for SpeechAnalyzer even on-device), review notes citing the DTS TCC decomposition, age questionnaire, optional reduced MAS SKU behind a compile-time channel flag. Cheap de-risk before building the MAS SKU: a Meet-with-Apple App Review appointment + the two free DTS TSIs on the CGEvent.post question.

## Standing risks

- App Review inconsistency on macOS 2.4.5 (mitigation: Developer ID primary channel; clipboard-fallback build ready).
- Apple is tightening the iOS keyboard round-trip (26.0 and 26.4 both regressed it) while giving away better system dictation (iOS 27 "Advanced Dictation"). Wisprit's durable moats are the local-only guarantee, the dictionary, and spoken-spelling learning — not raw streaming or generic cleanup.
- Every Apple point release can silently change the refine model and the ITN spelling behavior: both the refine prompt **and** the correction detector need eval batteries re-run per OS update (extend `tests/rehearsal_refine.sh` pattern).
- All accuracy probes were TTS-based; S4 re-validation on human audio gates the correction feature's thresholds.
