# Wispr Flow (wisprflow.ai) — Deep Research Report (as of mid-2026)

## 0. Company snapshot

- Founded 2021 by Tanay Kothari and Sahaj Garg (CTO); originally a neural-interface wearable company ("Wispr"), pivoted to the Flow dictation app (Show HN launch Oct 2024, demo featuring Steve Wozniak).
- Funding: $30M Series A led by Menlo Ventures (June 2025, ~$56M total at that point); $700M valuation set in Nov 2025; as of May 2026 in talks (Bloomberg) to raise ~$260M at a ~$2B valuation, again led by Menlo.
- Scale: processes ~1 billion words/month (per Wispr's own engineering blog), ~2.5M downloads late-2025→early-2026, used at 270 Fortune 500 companies (Nvidia, Amazon cited), ~$10M revenue in 2025, ~94 employees.
- Marquee praise: Rahul Vohra (Superhuman): "Best AI product I've used since ChatGPT." Customers cited: Clay, Vercel, Notion, Replit.

## 1. Exact UX mechanics

### Hotkeys (from Wispr's own help docs)
- **Push-to-talk (default):** *hold* a key while speaking, release to finish.
  - Mac default: **Fn** (Apple keyboards; the Fn key is a hardware-level signal unique to Apple-built keyboards) or **Ctrl+Opt** on external keyboards.
  - Windows default: **Ctrl+Win**.
- **Hands-free / toggle mode:** **double-tap** the dictation shortcut, or press a dedicated hands-free shortcut (Mac: Fn+Space, Windows: Ctrl+Win+Space) to start/stop without holding.
- **Command Mode** (Pro-only, experimental): Mac Fn+Ctrl / Windows Ctrl+Win+Alt — voice-driven *editing* of existing text ("make this more formal", etc.), can also drive ChatGPT/Perplexity by voice.
- Other bindings: Cancel = Esc; Paste last transcript (Cmd+Ctrl+V / Shift+Alt+Z); Copy last transcript; Transforms (Opt+1 "Polish", Opt+2 "Prompt Engineer"); View Diff (Opt+O); optional Scratchpad. Up to 4 shortcuts per action.
- Constraints: max 3 keys per combo, must include a modifier; mouse buttons Middle/Mouse4–10 supported (not left/right click, not Magic Mouse/trackpad); Caps Lock not usable; long lists of OS-reserved combos blocked. Many Windows users remap to Right Alt or a side mouse button.
- Gotcha: apps with macOS "Secure Keyboard Entry" (e.g., Slack setting) block Flow's shortcuts system-wide.

### On-screen indicator
- A small (~70px) **pill locked to bottom-center** of the screen shows recording/processing state. It is *not repositionable natively* — a third-party utility ("PillFloat", on GitHub/Product Hunt) exists solely to move it, which tells you users find the fixed position annoying.

### Text insertion mechanics
- Flow does **not** type character-by-character. It places the formatted transcript on the clipboard and fires a **simulated paste keystroke** (Cmd+V on Mac / Ctrl+V on Windows; **Shift+Insert** in Windows terminals where Ctrl+V is unreliable), then **restores your original clipboard contents**.
- It detects which physical key produces "v" once at helper start (for non-QWERTY layouts) and reuses it all session — a known source of bugs on layout switches ("Flow fails to detect text fields or inserts incorrectly on non-QWERTY layouts" help article).
- Failure mode: if the paste fails on macOS the text can be lost from the clipboard; the "Paste last transcript" hotkey is the recovery path. There are real bug reports of the simulated Ctrl+V breaking in specific apps (e.g., a Claude Code GitHub issue about Wispr paste breaking on Windows).
- On Android, Flow uses the **Accessibility Service** to insert text into any app (Android has no standard cross-app insertion API); iOS uses a custom keyboard/app.
- Text lands "wherever my cursor currently has focus" — works across ~any text field (Gmail, Slack, Notion, VS Code/Cursor agent panes, web forms).

### Latency (release-to-text)
- Wispr's engineering target: **end-to-end < 700 ms at p99** after you stop speaking — budgeted as **<200 ms ASR + <200 ms LLM (100+ tokens in <250 ms per Baseten) + <200 ms network** from anywhere in the world. They explicitly optimize p90/p99, not median ("We measure latency on a p90 or p99 basis for each user" — Sahaj Garg).
- User-perceived reality: reviewers report ~**1–2 seconds** in practice; fine for sentence/paragraph dictation, noticeable if you want word-by-word feedback. There is no streaming partial text — output appears as one block after you release.

## 2. Architecture

### Cloud, not on-device
- **All ASR and post-processing is cloud-based. There is no offline mode at any tier.** Audio streams via gRPC to Baseten-hosted model endpoints (observed endpoint: `model-*.grpc.api.baseten.co`), on AWS (us-east-1 noted; multi-region autoscaling, GPU capacity "scales to zero").
- Documented subprocessor chain (11+ subprocessors): audio → **Baseten** (transcription) → **OpenAI / Anthropic / Cerebras** (formatting/LLM calls) → AWS S3 storage. Telemetry to PostHog, Sentry, Segment, Datadog.

### ASR layer
- Wispr says it builds **"context-aware, personalized, code-switched" ASR models** (own engineering blog, "Technical challenges behind Flow"). Whether the base is a fine-tuned Whisper variant is **not publicly disclosed**; Baseten separately markets "the world's fastest ASR runtime" (Whisper speed factor >1,000; 30 s audio chunks in <200 ms), and Wispr is their flagship dictation customer. Best characterization: proprietary/fine-tuned cloud ASR served on Baseten's optimized Whisper-class runtime.
- ASR is **conditioned on context**: speaker qualities, on-screen/surrounding text, personal history, plus a separate LLM call to extract likely proper nouns (`/llm/extract_asr_words` endpoint observed in forensic logs) so names on screen get spelled right.
- Handles **whispered speech** (explicit feature, higher error rates acknowledged since whisper training data is scarce) and **code-switching** (mixing languages mid-utterance) across 100+ languages with auto-detection.

### LLM post-processing layer (the real differentiator)
- **Fine-tuned open-source Llama models** (per Baseten case study), built with TensorRT-LLM engine builder and orchestrated with Baseten Chains; chosen because "Llama is controllable and customizable, which lets us focus on the output."
- What it does:
  - **Auto-punctuation** inferred from pauses and tone.
  - **Filler-word removal** ("um," "uh," pauses).
  - **Self-correction handling**: "Say 'Let's meet at 2… actually 3,' and Flow writes the corrected version instantly" (their marketing example); also handles full restarts where you scrap a thought and start over.
  - **Tone matching per app**: detects the active app's category (Email / Work messaging / Personal messaging / Other) and applies a configured style (Formal / Casual / Very Casual / Excited). Email+work default Formal; personal messaging defaults Casual.
  - **Custom dictionary**: user-added words/phrases (product names, jargon) bias recognition; changes apply instantly; optional **auto-add** learns proper nouns from your manual corrections ("only names and uncommon proper nouns"); team-shared dictionaries on Teams plans; syncs across devices. Snippets = voice-triggered text expansion.
  - **Learning from edits**: device-level capture of your post-dictation edits trains preference policies — stated goal "never make the same mistake twice." They note LLMs have "very low precision" on token-level style prefs (dash vs comma, capitalization), which is why they fine-tune.
  - **Context awareness (opt-in-ish)**: reads "limited text near your cursor" via accessibility APIs — and historically **screenshots of the active window** — to ground spelling and tone. Toggle lives in Settings → Data & Privacy. Personalization context is stored on-device partly because the 200 ms latency budget and privacy constraints preclude cloud lookup.
  - Developer mode: syntax awareness for code, file-tagging in Cursor/Windsurf, dev-terminology recognition.

## 3. Accuracy

- **No published WER numbers from Wispr.** Marketing claims it beats OpenAI Whisper and Apple Dictation on internal benchmarks, unpublished.
- Independent testing (competitor Spokenly, so salt required) measured ~**97.2% word accuracy (~2.8% WER)** on standard English audio — i.e., in the same class as other top cloud STT (Whisper large-v3 ≈ 2.7% WER on LibriSpeech clean, 8–12% on messy real-world audio; Deepgram Nova-3 ≈ 5.3–6.8% median WER in production). Reviewer consensus: Flow's edge comes from **LLM cleanup/formatting, not a fundamentally better acoustic model**.
- Enthusiast users report near-perfect output: one developer (182k words dictated across 36 apps) calls accuracy "so close to 100% that it's essentially perfect," including technical terms — *after* dictionary/passive learning kick in.
- **Names/jargon**: strong via three mechanisms — custom dictionary, passive learning of your repeated corrections, and screen-context proper-noun extraction ("Flow uses surrounding context to spell uncommon names right"). Cold-start on unusual names is still the weak point; noisy environments (open offices) measurably degrade output.
- **Theoretical ceiling context**: human transcription WER is ~4–5% on conversational audio (Microsoft's landmark parity result was 5.1% on Switchboard); best ASR models now beat humans on clean read speech (2–3% WER) but remain ~8–12% on noisy/accented/far-field real-world audio. So "essentially perfect" dictation is achievable specifically in the close-mic, single-speaker, cooperative-speaker regime dictation lives in — plus an LLM layer that masks residual ASR errors by rewriting to intent. That rewriting is also a failure mode (see complaints).

## 4. Speed

- Official claim: **"Talk 4x faster than you type" — 220 WPM via Flow vs 45 WPM typing** (homepage).
- Independent user data: a developer measured **179–184 WPM** sustained dictating code/docs (vs his 90 WPM typing); reviewers commonly cite a realistic 150–220 WPM range once you stop self-editing mid-speech.
- End-to-end latency: <700 ms p99 engineering claim; ~1–2 s user-perceived (see §1). Recording cap: ~6 minutes per dictation (user-reported).
- Practical caveat: for very short replies (≤2 words) the hotkey+cloud round trip erases the speed advantage.

## 5. Weaknesses and top user complaints

1. **Privacy / surveillance concerns (the big one).**
   - 2025: a Reddit user monitoring network traffic found Flow uploading **screenshots of the active window** to cloud servers (Context Awareness). Wispr's first response was to **ban the user**; CTO Sahaj Garg then publicly apologized; the company made context capture opt-in-ish, made training-data use opt-in/default-off, and expanded Privacy Mode.
   - April 2026, HN front page: "Wispr Flow Is Tracking Every App/URL You Visit and Taking Screenshots," from Wensen Wu's forensic investigation, which found: a system-wide **CGEventTap** intercepting every keystroke (can suppress keys); accessibility-tree traversal of the active app (up to 214 elements, 9 levels; ~336 ms "AX context collection") sent to cloud alongside audio; **1,688 app/URL tracking events in 30 hours**; a 694 MB local SQLite DB with raw audio BLOBs plus `screenshot`, `axText`, `axHTML` columns; hourly uploads to `/history/upload` continuing "metadata-only" even with data-sharing toggled off; Hardened Runtime disabled via entitlements. The same report documented the **"spacebar bug"**: a stuck Right-Option key in Flow's key-tracking set made the app suppress **145 spacebar presses in 10 minutes** system-wide (its event tap swallowed Space as a hotkey) until the process was killed.
   - March 2026 **Delve audit scandal**: Wispr's SOC 2 certs (issued Feb–Sep 2025) came via Delve, whose reports were alleged to be boilerplate; YC removed Delve from its community (Apr 4, 2026). Wispr migrated to Drata + engaged A-LIGN for a fresh SOC 2 Type II (expected Jun–Jul 2026) and moved its trust center to trust.wispr.ai. Until then enterprise buyers treat its SOC 2 as provisional.
   - Privacy Mode (zero data retention) is **off by default** for individuals; HIPAA BAA (self-serve) irreversibly locks it on.
2. **Cloud-only / no offline.** Unusable on planes, dead zones, strict networks; audio always leaves the machine. This is the #1 structural objection on HN, where local alternatives (Superwhisper, MacWhisper, Handy, FreeFlow, Monologue, VoiceInk) are repeatedly recommended.
3. **Reliability / "day-two drop."** Trustpilot ~**2.7/5**. Most consistent negative theme: works great during the 14-day trial, then degrades after payment — "working 60% of the time," accuracy drops, and the most-cited quality complaint: "Instead of transcribing what I say, it's trying to rewrite what I say" (over-aggressive LLM cleanup vs verbatim transcription; no true verbatim mode).
4. **Cost.** $15/mo (or $144/yr) is the priciest mainstream dictation app; subscription-only, no lifetime license; refunds post-trial only where legally required. Free tier (2,000 words/week) exhausts fast.
5. **Resource usage / platform bugs.** ~800 MB idle RAM reported on Windows; Windows app freezes; paste breakage in specific apps/terminal versions; fixed bottom-center pill annoys users (hence PillFloat); Fn hotkey doesn't work on most third-party keyboards; Secure Keyboard Entry conflicts.
6. **Latency perception.** 1–2 s block-paste output; no streaming feedback while speaking.

## 6. Pricing and platform support

| Tier | Price | Limits / notes |
|---|---|---|
| Flow Basic (free) | $0 | 2,000 words/week Mac+Windows; 1,000/week iPhone; Android unlimited "for a limited time"; custom dictionary, 100+ languages, Privacy Mode, HIPAA-ready |
| Flow Pro | **$15/mo** or **$12/mo billed annually ($144/yr)** | Unlimited words, Command Mode, early access, priority support; 14-day free trial, no card |
| Teams | from **$12/user/mo** (3-seat min) | shared dictionaries/snippets, usage dashboards |
| Enterprise | custom | SOC 2 Type II & ISO 27001 claims, enforced Privacy Mode/HIPAA, SSO/SAML, admin seats |
| Students | 3 months free + 50% off Pro | new subscribers |

- **Platforms:** macOS 12+, Windows 10/11 (x64), iOS 18.3+ (keyboard app), Android 13–16 (accessibility-service keyboard, beta). No Linux. Settings/dictionary/snippets sync across devices.

## 7. Implications if building a competitor

- The moat is *not* the ASR — it's (a) sub-second p99 end-to-end pipeline engineering, (b) the fine-tuned LLM cleanup layer (self-corrections, tone-per-app, personal style), (c) dictionary + passive proper-noun learning, (d) frictionless push-to-talk UX everywhere.
- The clearest attack surfaces, straight from user complaints: **local/on-device processing** (privacy + offline + no subscription anxiety), a **verbatim mode** toggle, streaming partial text, lower RAM footprint, movable indicator, and transparent data handling. Whisper-class local models (large-v3-turbo, Parakeet) already match Flow's raw accuracy on close-mic dictation; a small local LLM can replicate most of the cleanup.

## Sources
See structured sources list.