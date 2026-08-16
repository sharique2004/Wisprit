#if os(macOS)
import AppKit
import Foundation
import WispritContext
import WispritCorrections
import WispritDictionary
import WispritEngine
import WispritIMProtocol
import WispritKit
import WispritMacInput
import WispritMacUI
import WispritPersistence
import WispritPolish
import WispritPostProcess
import WispritRefine

/// Wires every component and runs the AppKit loop — port of `wisprit/app.py`.
///
/// Thread layout, unchanged from the Python:
/// - **main**: `NSApplication` run loop, the status item + menu, the pill panel,
///   and the CGEventTap (its run-loop source lives on this loop).
/// - **session**: one thread running `SessionController.run()`.
/// - **pill-level / capture / analyzer**: spawned per utterance underneath.
///
/// Every UI mutation from another thread goes through `WispritUI.callOnMain`.
@MainActor
public final class AppController: NSObject, NSApplicationDelegate {

    private let log = WLog.logger("app")

    let settings: Settings
    let dictionary: DictionaryStore
    let snippets: SnippetStore
    let history: History
    let metrics: MetricsWriter
    let refiner: Refiner
    let polisher: Polisher
    let events: HotkeyEventQueue
    let monitor: HotkeyMonitor
    let session: SessionController
    let pill: Pill
    let liveTyping: LiveTypingSession
    let tierCache: BundleCapabilityCache
    /// Phase-4 context awareness — inert until the consent flow flips
    /// `context_awareness`, and hard-off under `WISPRIT_NO_CONTEXT=1`.
    let contextCapture: ContextCapture
    /// Phase-5 edit capture: the evidence ledger and the coordinator that
    /// classifies field re-reads into zero-edit lines and learn proposals.
    let pendingLearns: PendingLearnStore
    let editCapture: EditCapture
    private var statusMenu: StatusMenu!
    private let instanceLock: SingleInstanceLock
    /// Answers second launches that lost the lock — see `InstanceHandoff`.
    /// Held for the process lifetime; torn down in `terminate()` *before* the
    /// lock, so a launcher can never get an ack from an instance that has
    /// already let go.
    private var instanceServer: InstanceHandoffServer?

    /// The front end. Built eagerly (it is cheap — no probes until the window
    /// opens) so `applicationShouldHandleReopen` never has to construct it while
    /// the user is waiting on a Dock click.
    private var windowModel: WispritWindowModel!
    private var windowController: MainWindowController!
    /// One window-raise per launch for a broken hotkey tap; the ghost-tap
    /// watchdog can fire repeatedly and must not keep stealing focus.
    private var inputMonitoringSurfaced = false

    /// `Refiner.availability` is actor-isolated while the menu build is
    /// synchronous, so the last probed value is cached here and refreshed on a
    /// slow timer. nil (still probing) and true both show the toggle; only an
    /// explicit false swaps in the "unavailable — run Doctor" row.
    private var aiAvailability: Bool?
    /// Same tri-state, for the "Polish Last" submenu.
    private var polishAvailability: Bool?
    private var polishUnavailableReason: String = ""
    /// Last input-source snapshot, sampled on the same slow timer as the model
    /// probes and re-read whenever the menu opens.
    private var liveTypingStatus: LiveTypingMenuStatus = .probing
    private var liveTypingDetail: String = ""
    private var availabilityTimer: Timer?
    /// Secure Keyboard Entry, cached (R12). While some app holds it, macOS
    /// suppresses the event tap entirely, so the menu-bar icon is the only
    /// feedback channel left standing — it gets a lock. The flag is refreshed
    /// by `secureInputTimer` below and by every menu open, and NEVER read live
    /// from the icon path itself: `iconState` is sampled on session-state
    /// changes, i.e. while the key is held, and the discipline for that path
    /// is no syscalls (same rule as `needsSetup` above).
    private var secureInputActive = false
    private var secureInputTimer: Timer?
    /// The session's last reported state. The secure-input poll is suspended
    /// for the whole of any utterance — "never while a key is held".
    private var sessionIsIdle = true

    public init(instanceLock: SingleInstanceLock) {
        self.instanceLock = instanceLock

        // Construction order is contractual: state dir → settings → history →
        // metrics, so every component reads a directory that already exists.
        do {
            try Bootstrap.ensureStateDir()
        } catch {
            WLog.logger("app").error("could not create the state dir; continuing with defaults")
        }

        let settings = Settings.load()
        self.settings = settings
        let dictionary = DictionaryStore()
        self.dictionary = dictionary
        let snippets = SnippetStore()
        self.snippets = snippets
        // `history_detail` is honored HERE, the wiring site: the store takes it
        // as a constructor value on purpose (see `History.detailEnabled`).
        self.history = History(settings: settings,
                               detailEnabled: HistoryDetailSettings.isEnabled(settings))
        self.metrics = MetricsWriter()

        self.refiner = Refiner(
            generator: AppController.makeGenerator(),
            configuration: {
                RefineConfiguration(enabled: settings.aiCleanup,
                                    maxWords: settings.aiCleanupMaxWords,
                                    timeoutMs: settings.aiCleanupTimeoutMs,
                                    // The verbatim-app skip, resolved per call
                                    // against the app being dictated INTO —
                                    // the same live frontmost read the ladder
                                    // uses from the session thread.
                                    verbatimApp: ContextSettings.isVerbatimApp(
                                        settings,
                                        bundleID: AppController.frontmostBundleID()))
            },
            vocabulary: dictionary)

        self.polisher = Polisher(
            generator: AppController.makePolishGenerator(),
            configuration: { PolishConfiguration(maxWords: settings.aiCleanupMaxWords) })

        let events = HotkeyEventQueue()
        self.events = events
        let monitor = HotkeyMonitor(queue: events, hotkeySetting: settings.hotkey)
        self.monitor = monitor

        let asrSettings = AsrSettings(locale: settings.locale,
                                      finalizeTimeoutMs: Double(settings.finalizeTimeoutMs),
                                      engine: AsrEngineKind(settingsValue: settings.engine))
        let asr = AsrManager(settings: asrSettings, vocabulary: dictionary)
        let capture = MicCapture(onChunk: { pcm in asr.feed(pcm: pcm) },
                                 // The 2026-08-05 failure class, finally wired
                                 // to something: the fact used to stop inside
                                 // MicCapture, where only a log line read it.
                                 onConfigurationChange: { asr.noteConfigurationChange() })
        // `prefer_builtin`, and only against a narrowband classic-BT default —
        // never over a deliberate USB/external choice. Evaluated per `start()`,
        // so unplugging the headset restores the normal path with no relaunch.
        capture.preferredDevice = {
            guard InputDevicePolicySettings.policy(settings) == .preferBuiltin,
                  let device = InputDeviceProbe.defaultInput(), device.isNarrowband
            else { return nil }
            return InputDeviceProbe.builtInInput()
        }
        // One notice per device appearance, silenced by `input_device_policy=off`.
        let narrowbandWarner = NarrowbandWarner(
            isEnabled: { InputDevicePolicySettings.policy(settings) != .off })
        // Its quiet-speech twin (2026-08-15): the same once-per-device
        // discipline, the same `input_device_policy=off` kill switch, and a
        // strictly read-only Core Audio property. Consulted only when an
        // utterance actually came back marginal — see `SessionController
        // .flashEmpty` — so a user whose slider is low and whose dictation works
        // never hears about it.
        let inputVolumeAdvisor = InputVolumeAdvisor(
            isEnabled: { InputDevicePolicySettings.policy(settings) != .off })

        // R33 — the microphone opens at KEY-DOWN, off the session thread.
        //
        // The head-loss defect this closes: `dispatch` only begins a press from
        // IDLE, so a press arriving while the previous utterance is still
        // finalizing/refining/inserting waits in the queue — measured 0.7–1.5 s
        // typically, and up to the batch-rescue budget in the worst case — and
        // every word spoken in that window was simply never captured (11.6 % of
        // presses land <3 s after the previous one). These hooks take the mic
        // out of the pipeline's critical path entirely: arm the retention
        // buffer, open the input, and let `begin()`'s existing retained-head
        // replay splice the pre-roll into the analyzer when it finally runs.
        //
        // Serial and user-interactive: press and release must stay in FIFO
        // order (a release-stop overtaking the next press-start would leave the
        // mic dark for an utterance), and the tap callback must not do this work
        // itself.
        let prestartQueue = DispatchQueue(label: "wisprit.mic-prestart", qos: .userInteractive)
        monitor.onPress = { [weak asr, weak capture] in
            prestartQueue.async {
                guard settings.enabled, let asr, let capture else { return }
                // A mic that is ALREADY running belongs to someone else: either
                // an utterance still recording (which `armCapture` refuses
                // anyway), or — if this queue was briefly busy draining the
                // previous key-up's stop — the session's own `begin()` racing us
                // to this very press. Arming in that second case would reset a
                // buffer that is already collecting the utterance's head.
                guard !capture.isActive else { return }
                // Arm FIRST, and start the mic ONLY if arming succeeded: an
                // un-armed prestart would reset the live capture session's R4
                // telemetry mid-read and would then have its audio discarded by
                // `startUtterance`. A refusal means an utterance is still
                // recording — that press degrades to today's behaviour.
                if asr.armCapture() { _ = capture.start() }
            }
        }
        monitor.onRelease = { [weak asr, weak capture] in
            prestartQueue.async {
                guard let asr, let capture else { return }
                // The privacy invariant, restored for the prestart path: the mic
                // is live only while the key is down. When a live utterance owns
                // the capture (`isRecordingUtterance`), the session's own
                // `finish()` stops it — including its keyup grace, which this
                // must not cut short. Otherwise this key-up belongs to a QUEUED
                // press whose `begin()` has not run yet, and nothing else would
                // close the mic until it does.
                guard !asr.isRecordingUtterance else { return }
                capture.stop()
            }
        }

        // The pill reads nothing itself; settings arrive as closures.
        let pill = Pill(configuration: Pill.Configuration(
            isSuppressed: { settings.pillHidden },
            savedPosition: {
                guard let position = settings.pillPosition else { return nil }
                return CGPoint(x: position.x, y: position.y)
            },
            persistPosition: { point in
                settings.setPillPosition(x: Double(point.x), y: Double(point.y))
            },
            onStart: { events.put(HotkeyEvent(.press)) },
            onCancel: { events.put(HotkeyEvent(.esc)) },
            onConfirm: { events.put(HotkeyEvent(.release)) }))
        self.pill = pill

        // Rungs 1–2 of the insertion ladder. Nothing here touches an input
        // source until `live_typing` is on AND onboarding has run — the setting
        // defaults to false, so a fresh install behaves exactly like Phase 1.
        let tierCache = BundleCapabilityCache()
        self.tierCache = tierCache
        let liveTyping = LiveTypingSession(
            peer: SystemLiveTypingPeer(),
            cache: tierCache,
            configuration: LiveTypingConfiguration(
                isEnabled: { LiveTypingSettings.isEnabled(settings) },
                terminalBundleIDs: { settings.terminalBundleIDs },
                frontmostBundleID: { AppController.frontmostBundleID() },
                secureInputActive: { Permissions.secureInput().active },
                selectionPolicy: LiveTypingSettings.selectionPolicy(settings)))
        self.liveTyping = liveTyping

        // Context capture: the IM wire when the rung is live (zero
        // permissions), the 4-call AX reader on rungs 3–4. Everything it
        // reads is gated by `ContextSettings.policy` per key-down, so the
        // default-off install never posts a read or touches AX at all.
        // The lexicon is shared with edit capture below — one dictionary load,
        // one answer to "is this an ordinary word?".
        let lexicon = SystemLexicon()
        let contextCapture = ContextCapture(
            configuration: ContextCapture.Configuration(
                policy: { ContextSettings.policy(settings) },
                maxTerms: { ContextSettings.maxTerms(settings) },
                frontmostBundleID: { AppController.frontmostBundleID() },
                secureInputActive: { Permissions.secureInput().active }),
            requestIMRead: { [weak liveTyping] in liveTyping?.requestContextRead() },
            axReader: AXContextReader(),
            lexicon: lexicon)
        self.contextCapture = contextCapture
        // Installed before `liveTyping.start()` (in `launch`), per the client's
        // own rule: the handler is in place before the event port opens.
        liveTyping.onContextSnapshot { [weak contextCapture] generation, snapshot in
            contextCapture?.deliverIMSnapshot(wireGeneration: generation, snapshot)
        }
        if ContextSettings.isEnabled(settings) {
            contextCapture.prewarm()
        }

        // One pill port for every off-main producer — the session thread and
        // the edit-capture answers both speak through it.
        let pillPort = MainThreadPill(pill, isSuppressed: { settings.pillHidden })

        // Phase-5 edit capture: committed snapshots (the IM rung's own read
        // channel) and next-utterance field diffs (the paste rung, consent-
        // gated through context awareness) both land here.
        let pendingLearns = PendingLearnStore()
        self.pendingLearns = pendingLearns
        let editCapture = EditCapture(
            store: pendingLearns,
            metrics: metrics,
            vocabulary: dictionary,
            pill: pillPort,
            lexicon: lexicon,
            committedText: { [weak liveTyping] in liveTyping?.committedText(for: $0) },
            configuration: EditCapture.Configuration(
                knownTerm: { dictionary.isKnownTerm($0) },
                autoAccept: { EditLearnSettings.autoAccept(settings) }))
        self.editCapture = editCapture
        liveTyping.onCommittedSnapshot { [weak editCapture] generation, snapshot in
            editCapture?.consumeCommitted(wireGeneration: generation, snapshot)
        }

        self.session = SessionController(
            events: events,
            asr: AsrManagerPort(asr),
            audio: MicCapturePort(capture),
            inserter: SettingsInserterPort(inserter: Inserter(), settings: settings),
            history: history,
            metrics: metrics,
            refiner: RefinerPort(refiner),
            pill: pillPort,
            vocabulary: dictionary,
            corrections: dictionary,
            corrector: SpokenSpellingCorrector(vocabulary: dictionary),
            gate: monitor,
            liveTyping: liveTyping,
            context: contextCapture,
            editObserver: editCapture,
            // Default-off behind the `sounds` key until the cue-bleed check
            // passes with the real asset (tools/eval/scripts/cue-bleed).
            sound: SystemSoundCues(settings: settings),
            configuration: SessionController.Configuration(
                holdDebounceMs: { Double(settings.holdDebounceMs) },
                isEnabled: { settings.enabled },
                postProcessOptions: {
                    PostProcessOptions(
                        fillerRemoval: settings.fillerRemoval,
                        ensureSentencePeriod: settings.ensureSentencePeriod,
                        leadingSpace: PostProcessOptions.LeadingSpace(
                            rawValue: settings.leadingSpace) ?? .auto,
                        emojiCommands: settings.emojiCommands,
                        pressEnterEnabled: true,
                        smartFormatting: true)
                },
                // Armed unconditionally, and suppressed live inside
                // `MainThreadPill` instead.
                //
                // Reading `settings.pillHidden` HERE captured it once, at
                // construction: every other closure in this struct re-reads the
                // setting per utterance, but the ticker interval is a value, so
                // "Show the floating pill" needed a relaunch to take effect —
                // switch it back on and the pill appeared with a dead meter.
                // The port now drops the tick when the pill is hidden, which
                // costs one bool read on the `pill-level` thread and no main
                // thread work at all, and the toggle is live in both directions.
                levelTickInterval: 0.05,
                // Re-read per utterance like every other setting closure here:
                // switching retro-correction off has to take effect on the next
                // dictation, not the next launch.
                vocabularyRetro: { VocabularyRetroSettings.isEnabled(settings) },
                expandSnippets: { snippets.expand($0) },
                // One definition of the grace, in `KeyupGraceSettings`.
                releaseGrace: KeyupGraceSettings.seconds(settings),
                inputWarning: { narrowbandWarner.warning() },
                inputVolumeAdvisory: { inputVolumeAdvisor.lowVolumePercent() }))

        super.init()

        self.statusMenu = StatusMenu(actions: makeMenuActions())
        let windowModel = WispritWindowModel(
            settings: settings,
            dictionary: DictionaryEditor(store: dictionary),
            snippets: snippets,
            ports: AppController.makeWindowPorts(history: history,
                                                 settings: settings,
                                                 tierCache: tierCache,
                                                 dictionary: dictionary,
                                                 pendingLearns: pendingLearns,
                                                 metrics: metrics,
                                                 paste: { [weak self] text in
                                                     self?.pasteFromWindow(text)
                                                 },
                                                 fix: { [weak self] kind in
                                                     self?.runFix(kind)
                                                 }))
        self.windowModel = windowModel
        windowModel.onPillHiddenChange = { [weak self] hidden in
            WispritUI.callOnMain {
                if hidden { self?.pill.hide() } else { self?.pill.showIdle() }
            }
        }
        self.windowController = MainWindowController(model: windowModel)

        let statusMenu = self.statusMenu!
        session.onStateChange = { [weak self] state in
            WispritUI.callOnMain {
                self?.sessionIsIdle = state == .idle
                statusMenu.update(stateNamed: state.rawValue)
                // The window's 2-second timer stops for the duration of an
                // utterance. Everything it polls shares the main thread with the
                // hotkey tap, the pill and the live-typing stream, and the Try-it
                // card asks the user to dictate with the window open.
                windowModel.noteSessionState(state)
                // The "try a dictation" step needs proof that the whole chain
                // ran, and INSERTING is that proof — it survives history being
                // switched off, which a history poll would not.
                if state == .inserting { windowModel.noteDictationObserved() }
            }
        }
    }

    /// The window's system seams. Kept static and closure-shaped so the model
    /// never sees the controller (and so tests can build it with fakes).
    private static func makeWindowPorts(history: History,
                                        settings: Settings,
                                        tierCache: BundleCapabilityCache,
                                        dictionary: DictionaryStore,
                                        pendingLearns: PendingLearnStore,
                                        metrics: MetricsWriter,
                                        paste: @escaping (String) -> Void,
                                        fix: @escaping (SetupFixKind) -> Void)
        -> WispritWindowModel.Ports {
        WispritWindowModel.Ports(
            fullProbe: {
                // Two hops on purpose: the speech/model probes are slow and must
                // not run on the main thread, and the Live Typing probe has to
                // straddle it (main for the input-source read, off it for the
                // bridge ping). `gatheringLiveTyping` owns that split so the
                // order and the threads are not this call site's to remember.
                let base = await Doctor.gather(locale: settings.locale, liveTyping: false)
                return await Doctor.gatheringLiveTyping(base)
            },
            fastProbe: { Doctor.refreshingPermissions($0) },
            globeKey: { GlobeKeySettings.current() },
            recents: { history.recent(limit: $0) },
            purgeHistory: { history.purge() },
            copy: { StatusMenu.copyToPasteboard($0) },
            pasteAtCursor: paste,
            liveTypingFallbacks: { tierCache.downgraded() },
            performFix: fix,
            learnProposals: {
                pendingLearns.pending().map { entry in
                    WispritWindowModel.LearnProposalRow(
                        term: entry.term,
                        heard: entry.observations.map(\.heard).filter { !$0.isEmpty },
                        count: entry.count)
                }
            },
            acceptLearnProposal: { row in
                // The same transition the auto-accept path makes, from the
                // user's own click instead of the threshold flag.
                dictionary.add(LearnedTerm(term: row.term,
                                           heard: row.heard,
                                           source: EditCapture.learnSource))
                pendingLearns.promoteConsumed(term: row.term)
            },
            dismissLearnProposal: { term in pendingLearns.dismiss(term: term) },
            dataStores: { DataInventory.status() },
            purgeDataStore: { id in
                // File-level classes only — the window model routes
                // `.transcripts` through `purgeHistory` (the store's own
                // DELETE + VACUUM) and never sends `.settings`.
                DataInventory.purge(id)
                // `maybeReload` deliberately keeps its in-memory copy when the
                // file vanishes; a purge is the one caller that MEANS empty.
                if id == .dictionary { dictionary.reload() }
            },
            writeOnboardingRow: { deltaMs, skipped, relaunches in
                metrics.writeOnboarding(firstLaunchToDictateMs: deltaMs,
                                        stepsSkipped: skipped,
                                        relaunchCount: relaunches)
            })
    }

    /// Home's per-row "paste at cursor" (§3.3).
    ///
    /// Two things this cannot skip. The Hub window is key when the button is
    /// clicked, so the app has to hand the front back before anything is
    /// posted — `deactivate()` (never `hide`, which would take the pill down
    /// with it, see `MainWindowController.windowWillClose`) — and the settle is
    /// the same measured 0.25 s the window uses in the other direction. And the
    /// insert itself sleeps for the clipboard-restore delay (500 ms by
    /// default), so it runs off the main thread, which is carrying the hotkey
    /// tap and the live-typing stream.
    ///
    /// `WispritWindowModel.pasteAtCursor` refuses mid-utterance, so this never
    /// races the session's own clipboard swap.
    private func pasteFromWindow(_ text: String) {
        guard !text.isEmpty else { return }
        let inserter = SettingsInserterPort(inserter: Inserter(), settings: settings)
        NSApp.deactivate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            DispatchQueue.global(qos: .userInitiated).async {
                _ = inserter.insert(text)
            }
        }
    }

    /// Perform one checklist fix. `enableLiveTyping` and the relaunch are the
    /// app's own, so they are injected here rather than reimplemented.
    private func runFix(_ kind: SetupFixKind) {
        SetupFixRunner(
            enableLiveTyping: { [weak self] in self?.enableLiveTyping() },
            relaunch: { [weak self] in self?.relaunch() },
            cleanLearnedTerms: { [weak self] in self?.cleanLearnedTerms() },
            enableContextAwareness: { [weak self] in self?.enableContextAwareness() }).run(kind)
    }

    /// Fold the learn loop's junk entries back into the terms they are garbled
    /// spellings of.
    ///
    /// Only ever from the checklist button: the dictionary is the user's file,
    /// and `LearnedTermCleanup` writes `dictionary.json.bak` before touching a
    /// byte of it. A failure leaves the file exactly as it was.
    func cleanLearnedTerms() {
        do {
            let outcome = try LearnedTermCleanup.run(store: dictionary)
            log.info("learned-term cleanup: \(outcome.summary, privacy: .public)")
            pill.transientNotice(outcome.changed
                ? "Cleaned up learned spellings"
                : "Nothing to clean up")
        } catch {
            log.error("""
                learned-term cleanup failed, dictionary untouched: \
                \(String(describing: error), privacy: .public)
                """)
            pill.transientNotice("Could not clean up learned spellings")
        }
    }

    /// Quit and come back. The replacement is spawned first and only waits for
    /// this process to release the single-instance lock; if it cannot be
    /// spawned we stay running rather than leave the user with nothing.
    func relaunch() {
        guard AppRelaunch.spawnHelper() else {
            log.error("relaunch aborted — could not spawn the helper; staying up")
            return
        }
        terminate()
    }

    // MARK: - the window

    /// Show the main window. This is what a Dock click, a Finder open and the
    /// menu's first row all end up calling.
    public func openWindow(tab: WispritWindowModel.Tab = .setup) {
        windowController.show(tab: tab)
    }

    /// Open the window straight into the first-run wizard.
    public func openSetupGuide() {
        windowController.showOnboarding()
    }

    private static func makeGenerator() -> any RefineGenerating {
        #if canImport(FoundationModels)
        return SystemModelGenerator()
        #else
        return UnavailableGenerator()
        #endif
    }

    private static func makePolishGenerator() -> any PolishGenerating {
        #if canImport(FoundationModels)
        return SystemPolishGenerator()
        #else
        return UnavailablePolishGenerator()
        #endif
    }

    /// Frontmost application's bundle id — the key the ladder caches tier
    /// verdicts under before the input method has told us anything.
    nonisolated static func frontmostBundleID() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    // MARK: - startup

    /// The hotkey tap can't see the key. Used to be a modal alert with a deep
    /// link — now it raises the window, which says the same thing but with a
    /// live status dot, the relaunch button, and everywhere else the user has to
    /// go next. Once per launch: the ghost-tap watchdog fires repeatedly and
    /// must not keep stealing focus.
    private func surfaceInputMonitoringProblem() {
        guard !inputMonitoringSurfaced else { return }
        inputMonitoringSurfaced = true
        openWindow(tab: .setup)
    }

    /// Everything `app.py: main()` does between the lock and `NSApp.run()`.
    public func launch() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.delegate = self

        // As early as possible: everything below is a beat during which a
        // simultaneous second launch would find the lock taken and nobody
        // listening. (`arbitrate`'s retry loop covers that beat; this shortens
        // it to almost nothing.)
        //
        // `assumeIsolated`, not `Task { @MainActor }`: the port source lives on
        // this run loop, so the handler already IS on the main actor, and the
        // hop must stay synchronous — the ack has to mean "the window is
        // opening", not "the request was filed". A launcher that gets an ack
        // exits immediately and hands focus over.
        let server = InstanceHandoffServer(name: InstanceHandoff.portName()) { [weak self] request in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch request {
                // `.window(nil)` lands on Setup, because that is where
                // `openWindow()`'s default lands — deliberately the SAME call a
                // Dock click makes, so the two entry points cannot drift.
                case .window(nil): self.openWindow()
                case .window(let tab?): self.openWindow(tab: tab)
                case .setupGuide: self.openSetupGuide()
                }
            }
        }
        if !server.start() {
            log.warning("""
                instance-handoff port name is already taken — a second launch will \
                fall back to the "another copy is running" notice
                """)
        }
        instanceServer = server

        statusMenu.install()

        // The Input Monitoring grant binds at TAP-CREATION time: a tap created
        // before the toggle stays deaf forever while reporting enabled (found
        // the hard way on first install). Preflight up front so the app lands
        // in the System Settings list, prompts, and tells the user to relaunch.
        if !CGPreflightListenEventAccess() {
            CGRequestListenEventAccess()
            surfaceInputMonitoringProblem()
        }

        // Tap creation must happen on the main thread — its run-loop source is
        // added to the CURRENT CFRunLoop, which has to be the one NSApp pumps.
        if !monitor.install() {
            log.error("""
                hotkey tap failed to install — grant Input Monitoring to this app in \
                System Settings > Privacy & Security > Input Monitoring, then relaunch. \
                Run `Wisprit doctor` for the full checklist.
                """)
            // macOS never prompts for Input Monitoring on a listen-only tap — it
            // silently fails, and with the menu icon possibly notch-hidden a log
            // line is invisible. This alert is the user's only signal.
            surfaceInputMonitoringProblem()
        }
        // The grant can also be missing with a SUCCESSFULLY created tap that
        // never fires ("ghost tap") — only the watchdog can see that case.
        monitor.onGhostTap = { [weak self] in
            WispritUI.callOnMain { self?.surfaceInputMonitoringProblem() }
        }

        // Grants are per-identity: a new launcher must be granted even when the
        // old one already was. Raise the mic prompt and audit the rest.
        Permissions.requestMicrophone()
        auditPermissions()
        startAvailabilityRefresh()
        startSecureInputWatch()

        // A menu-bar-only app with a notch-hidden icon starts INVISIBLY — users
        // read that as "not starting" (it happened). The pill flash is the
        // proof-of-life: no window, no permission, just 1.6 s at the pill spot.
        WispritUI.callOnMain { [pill] in
            pill.transientNotice("Wisprit ready — hold 🌐 to dictate")
        }

        // Listen for `clientLost` from the input method. This registers a local
        // message port and nothing else — no input source is touched until the
        // user has enabled live typing and holds the dictation key.
        liveTyping.start()

        session.start()
        log.info("Wisprit ready — hold \(self.settings.hotkey, privacy: .public) to dictate.")
    }

    private func auditPermissions() {
        var missing: [String] = []
        if !Permissions.accessibility() { missing.append("Accessibility") }
        if Permissions.inputMonitoring() != .granted { missing.append("Input Monitoring") }
        if Permissions.microphone() == .denied { missing.append("Microphone") }
        guard !missing.isEmpty else { return }
        log.warning("""
            permissions incomplete (\(missing.joined(separator: ", "), privacy: .public)) — \
            dictation won't work until these are granted in System Settings > Privacy & \
            Security. Run `Wisprit doctor` for the checklist.
            """)
        Permissions.requestAccessibilityPrompt()
    }

    /// Keep the cached Apple Intelligence availability fresh (the Refiner
    /// re-probes every 5 minutes while unavailable, so the menu recovers
    /// without a relaunch).
    private func startAvailabilityRefresh() {
        refreshAvailability()
        availabilityTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            MainActor.assumeIsolated { self.refreshAvailability() }
        }
    }

    private func refreshAvailability() {
        let refiner = self.refiner
        let polisher = self.polisher
        Task { @MainActor in
            self.aiAvailability = await refiner.availability
            self.polishAvailability = await polisher.availability
            self.polishUnavailableReason = await polisher.unavailableReason
        }
        refreshLiveTypingStatus()
        // A permission granted in System Settings has to clear the menu-bar
        // warning icon without waiting for the user to open the menu.
        statusMenu?.refreshIcon()
    }

    /// The low-rate idle poll behind the secure-input lock icon (R12).
    ///
    /// Two seconds is the same cadence the window's fast probe uses, and the
    /// manual bar it exists to meet: password field focused → lock within ~2 s;
    /// released → clears as fast. `IsSecureEventInputEnabled()` is one syscall,
    /// but the poll still yields for the whole of any utterance — the main
    /// thread is carrying the event tap and the pill while the key is held,
    /// and no icon is worth competing with that (`noteSessionState` rule).
    private func startSecureInputWatch() {
        refreshSecureInput()
        secureInputTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated { self.refreshSecureInput() }
        }
    }

    /// Re-sample Secure Keyboard Entry and redraw the icon only on a change.
    /// Skipped mid-utterance; a session that is running proves the key was
    /// seen, so the cached value cannot be misleading anyone right now.
    private func refreshSecureInput() {
        guard sessionIsIdle else { return }
        let active = Permissions.secureInput().active
        guard active != secureInputActive else { return }
        secureInputActive = active
        statusMenu?.refreshIcon()
    }

    /// Cheap enough to re-read on every menu open: one `TISCreateInputSourceList`
    /// plus a file-existence check. Strictly read-only.
    private func refreshLiveTypingStatus() {
        let staged = IMStagedBundle.url
        guard staged != nil, !LiveTypingEnvironment.isDisabled else {
            liveTypingStatus = .unsupported
            liveTypingDetail = LiveTypingEnvironment.isDisabled
                ? "Live typing is disabled for this process (WISPRIT_NO_IM=1)."
                : "This build ships no input method — rebuild with scripts/build_app.sh."
            return
        }
        let status = InputSourceProbe.status(stagedVersion: IMStagedBundle.version(at: staged))
        let verdict = IMPreflight.evaluate(status)
        liveTypingDetail = IMPreflight.remedy(for: verdict)
        switch verdict {
        case .needsInstall:
            liveTypingStatus = .notInstalled
        case .needsRegistration, .needsEnable:
            liveTypingStatus = .needsEnable
        case .needsUpdate:
            liveTypingStatus = .needsUpdate
        case .ready, .notSelected:
            liveTypingStatus = LiveTypingSettings.isEnabled(settings) ? .readyOn : .readyOff
        }
    }

    // MARK: - menu wiring

    /// Something on the checklist is stopping dictation outright.
    ///
    /// Read from the window model's last probe rather than probed here: the menu
    /// samples this on every state change and every open, and a TCC read per
    /// sample would put syscalls on the main thread while the key is held. The
    /// model already re-probes on its own 2-second cadence.
    private var needsSetup: Bool {
        windowModel?.items.contains(where: \.isBlocking) ?? false
    }

    private func makeMenuActions() -> StatusMenu.Actions {
        StatusMenu.Actions(
            state: { [weak self] in
                guard let self else { return StatusMenuState() }
                self.refreshLiveTypingStatus()
                // A menu open is a user gesture, not a key-hold — refresh the
                // secure-input cache here too so the icon is honest the moment
                // the user comes looking for an answer.
                self.refreshSecureInput()
                return StatusMenuState(
                    dictationEnabled: self.settings.enabled,
                    aiCleanupEnabled: self.settings.aiCleanup,
                    aiAvailability: self.aiAvailability,
                    recents: self.history.recent(limit: StatusMenuModel.recentsLimit)
                        .map(\.text),
                    polishAvailability: self.polishAvailability,
                    polishUnavailableReason: self.polishUnavailableReason,
                    polishModes: PolishMenu.modeItems,
                    liveTyping: self.liveTypingStatus,
                    liveTypingDetail: self.liveTypingDetail,
                    contextAwareness: self.contextMenuStatus,
                    needsSetup: self.needsSetup)
            },
            openWindow: { [weak self] in self?.openWindow() },
            openSetup: { [weak self] in self?.openWindow(tab: .setup) },
            iconState: { [weak self] in
                guard let self else { return StatusIconState() }
                // `secureInputActive` is the cache, never a live read: this
                // closure runs on every session-state change, i.e. while the
                // key is held (see the field's comment).
                return StatusIconState(dictationEnabled: self.settings.enabled,
                                       needsSetup: self.needsSetup,
                                       secureInput: self.secureInputActive)
            },
            toggleDictation: { [weak self] in
                guard let self else { return }
                self.settings.set(SettingsKey.enabled, !self.settings.enabled)
            },
            toggleAiCleanup: { [weak self] in
                guard let self else { return }
                self.settings.set(SettingsKey.aiCleanup, !self.settings.aiCleanup)
            },
            polishLast: { [weak self] key in self?.polishLast(modeKey: key) },
            enableLiveTyping: { [weak self] in self?.enableLiveTyping() },
            toggleLiveTyping: { [weak self] in
                guard let self else { return }
                LiveTypingSettings.setEnabled(self.settings,
                                              !LiveTypingSettings.isEnabled(self.settings))
                self.refreshLiveTypingStatus()
            },
            enableContextAwareness: { [weak self] in self?.enableContextAwareness() },
            toggleContextAwareness: { [weak self] in
                guard let self else { return }
                // Off is consent-free; on ALWAYS re-runs the consent flow.
                if ContextSettings.isEnabled(self.settings) {
                    ContextSettings.setEnabled(self.settings, false)
                } else {
                    self.enableContextAwareness()
                }
            },
            pasteLast: { [weak self] in self?.session.requestPasteLast() },
            openDictionary: { NSWorkspace.shared.open(WispritPaths.dictionaryPath) },
            openConfig: { NSWorkspace.shared.open(WispritPaths.configPath) },
            purgeHistory: { [weak self] in self?.history.purge() },
            quit: { [weak self] in self?.terminate() })
    }

    // MARK: - Polish Last

    /// `app.py::_do_polish`, unchanged in shape: read the last transcript, run it
    /// through one mode, put the result on the clipboard, say so. On failure the
    /// clipboard is left ALONE — the user still has whatever they copied.
    ///
    /// The Python spawned a `threading.Thread(name="polish")`; `Polisher` is an
    /// actor that serializes requests itself, so two quick menu clicks chain
    /// instead of racing and there is no thread to manage.
    func polishLast(modeKey: String) {
        let mode = PolishMode.named(modeKey)
        guard let text = history.lastText(), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            pill.transientNotice(PolishFailureKind.empty.notice)
            return
        }
        let polisher = self.polisher
        Task { @MainActor [weak self] in
            let result = await polisher.polish(text, mode: mode)
            guard let self else { return }
            switch result {
            case .success(let polished):
                StatusMenu.copyToPasteboard(polished)
                self.pill.transientNotice(PolishMenu.successNotice(for: mode))
            case .failure(let reason, let kind):
                self.log.warning("polish failed: \(kind.notice, privacy: .public)")
                self.pill.transientNotice(reason)
            }
        }
    }

    // MARK: - Live typing onboarding

    /// The one place the user's input sources are changed, and only ever from a
    /// menu click. `TISEnableInputSource` raises the system's "wants to activate
    /// the third-party input method" dialog — that prompt is the point of the
    /// item, not an accident of it.
    func enableLiveTyping() {
        guard let plan = InputMethodInstaller.plan() else {
            pill.transientNotice("No input method in this build")
            log.error("""
                cannot enable live typing: no WispritIM.app at \
                \(IMStagedBundle.relativePath, privacy: .public) — rebuild with scripts/build_app.sh
                """)
            return
        }
        guard !plan.isNoop else {
            LiveTypingSettings.setEnabled(settings, true)
            refreshLiveTypingStatus()
            pill.transientNotice("Live Typing is ready")
            return
        }
        let outcome = InputMethodInstaller.run(plan)
        if outcome.ok {
            LiveTypingSettings.setEnabled(settings, true)
            pill.transientNotice("Live Typing enabled")
        } else {
            // "run Doctor" pointed at a terminal ritual; the Setup page is the
            // same doctor rendered natively, so say that AND open it — the
            // remedy should not be a scavenger hunt (native-feel P6 / R9).
            pill.transientNotice("Could not enable Live Typing — see Setup")
            openWindow(tab: .setup)
        }
        refreshLiveTypingStatus()
        statusMenu?.rebuild()
    }

    // MARK: - Context awareness onboarding

    /// The kill switch + consent flag, in the menu's vocabulary.
    private var contextMenuStatus: ContextAwarenessMenuStatus {
        if ContextEnvironment.isDisabled { return .disabledByEnvironment }
        return ContextSettings.isEnabled(settings) ? .on : .off
    }

    /// The one place `context_awareness` is ever flipped ON, copying the
    /// `enableLiveTyping` deliberate-act pattern: a menu click, then the
    /// explanatory sheet, and only an explicit "Enable" changes anything.
    /// `Permissions.requestAccessibilityPrompt()` is raised only when the AX
    /// path would actually need it — the IM rung reads with no permission at
    /// all, and the sheet says so.
    func enableContextAwareness() {
        guard !ContextEnvironment.isDisabled else {
            pill.transientNotice("Context Awareness is disabled (WISPRIT_NO_CONTEXT=1)")
            return
        }
        guard !ContextSettings.isEnabled(settings) else { return }

        let alert = NSAlert()
        alert.messageText = ContextConsent.title
        alert.informativeText = ContextConsent.informativeText
        alert.addButton(withTitle: ContextConsent.enableTitle)
        alert.addButton(withTitle: ContextConsent.cancelTitle)
        let response = alert.runModal()

        let plan = ContextConsent.plan(accepted: response == .alertFirstButtonReturn,
                                       axTrusted: Permissions.accessibility())
        guard plan.enable else { return }
        if plan.requestAccessibility {
            Permissions.requestAccessibilityPrompt()
        }
        ContextSettings.setEnabled(settings, true)
        contextCapture.prewarm()
        pill.transientNotice("Context Awareness enabled")
        statusMenu?.rebuild()
    }

    func terminate() {
        availabilityTimer?.invalidate()
        secureInputTimer?.invalidate()
        // Commits anything still marked, closes the session, and gives the input
        // source back — leaving a palette source selected after we quit would
        // strand the user's field.
        liveTyping.shutdown()
        session.stop()
        monitor.uninstall()
        events.close()
        history.close()
        // The clipboard restore is asynchronous now (R33): quitting inside the
        // custody window would otherwise leave our dictation on the user's
        // pasteboard permanently, which the old on-thread sleep made impossible.
        // Bounded by the restore delay (500 ms default).
        Inserter.drainClipboardCustody()
        // Order matters: stop answering handoffs BEFORE letting go of the lock,
        // or a launcher could be acked by an instance that is already gone and
        // then exit having shown the user nothing.
        instanceServer?.stop()
        instanceServer = nil
        instanceLock.release()
        NSApplication.shared.terminate(self)
    }

    // MARK: - NSApplicationDelegate

    /// First probe, then decide whether to show ourselves.
    ///
    /// A healthy install stays quiet in the menu bar — that is the whole point
    /// of a push-to-talk agent. A first run, or one with a required permission
    /// missing, opens the window instead of leaving the user staring at a Mac
    /// that appears to have done nothing.
    public func applicationDidFinishLaunching(_ notification: Notification) {
        let model = windowModel!
        Task { @MainActor in
            await model.refreshFull()
            // A window that is already up was asked for deliberately (`Wisprit
            // window …`, or the Input Monitoring surface during `launch`).
            // Yanking it to the Status page would undo the user's own request.
            guard !self.windowController.isVisible, model.shouldAutoOpenWindow else { return }
            self.openWindow(tab: .setup)
            model.beginOnboarding()
        }
    }

    /// Clicking the app in Finder, the Dock, or Spotlight when it is already
    /// running. Without this, "opening" Wisprit does nothing at all — the single
    /// behaviour that made a working install look broken.
    ///
    /// `hasVisibleWindows` is ignored on purpose: the pill is a visible window
    /// (a borderless non-activating panel) and would otherwise talk us out of
    /// opening the real one.
    ///
    /// The twin of this is `InstanceHandoff`'s `.window(nil)`, for the case
    /// LaunchServices does NOT route here — a second *copy* at a different path.
    /// Both end at this same `openWindow()` so a Dock click and a second launch
    /// land in exactly the same place.
    public func applicationShouldHandleReopen(_ sender: NSApplication,
                                              hasVisibleWindows flag: Bool) -> Bool {
        openWindow()
        return true
    }

    /// Closing the window is not quitting: the hotkey has to keep working.
    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    public func applicationWillTerminate(_ notification: Notification) {
        liveTyping.shutdown()
        session.stop()
        monitor.uninstall()
    }
}

/// Routes every pill call through `WispritUI.callOnMain`, so the session thread
/// never touches AppKit directly. The Pill reference rides inside this
/// `@unchecked Sendable` box; only the main-thread block ever dereferences it.
final class MainThreadPill: PillPort, @unchecked Sendable {
    private let pill: Pill
    /// `pill_hidden`, read live. The 20 Hz level tick is the one pill call
    /// frequent enough that hopping it to main only to be dropped there is
    /// worth avoiding — and reading the setting here rather than at
    /// construction is what makes the Settings toggle take effect without a
    /// relaunch.
    private let isSuppressed: @Sendable () -> Bool

    init(_ pill: Pill, isSuppressed: @escaping @Sendable () -> Bool = { false }) {
        self.pill = pill
        self.isSuppressed = isSuppressed
    }

    private func onMain(_ work: @escaping @Sendable @MainActor (Pill) -> Void) {
        WispritUI.callOnMain { [self] in work(self.pill) }
    }

    func showRecording() { onMain { $0.showRecording() } }
    func updateLevel(_ level: Double) {
        guard !isSuppressed() else { return }
        onMain { $0.updateLevel(level) }
    }
    func livePartial(_ text: String) { onMain { $0.livePartial(text) } }
    func showFinalizing() { onMain { $0.showFinalizing() } }
    func flashSuccess() { onMain { $0.flashSuccess() } }
    func flashError(_ message: String) { onMain { $0.flashError(message) } }
    func transientNotice(_ text: String) { onMain { $0.transientNotice(text) } }
    func flashMissed(_ message: String) { onMain { $0.flashMissed(message) } }
    func flashTooQuiet(_ message: String) { onMain { $0.flashTooQuiet(message) } }
    func hide() { onMain { $0.hide() } }
    func showIdle() { onMain { $0.showIdle() } }
    func showPrewarming() { onMain { $0.showPrewarming() } }
    func showRefining() { onMain { $0.showRefining() } }
    func flashBlockedSecure() { onMain { $0.flashBlockedSecure() } }
}

/// Stand-in when FoundationModels is not linkable; the cage treats it as an
/// always-unavailable model and every utterance stays verbatim.
struct UnavailableGenerator: RefineGenerating {
    func probe() async -> RefineAvailability {
        RefineAvailability(available: false, reason: "FoundationModels unavailable in this build")
    }
    func prewarm() async {}
    func generate(_ transcript: String) async throws -> String {
        throw RefineError.unavailable("FoundationModels unavailable in this build")
    }
    func discard() async {}
}

/// The same stand-in for the polish cage.
struct UnavailablePolishGenerator: PolishGenerating {
    func probe() async -> PolishAvailability {
        PolishAvailability(available: false, reason: "FoundationModels unavailable in this build")
    }
    func generate(_ transcript: String, mode: PolishMode) async throws -> String {
        throw PolishError.unavailable("FoundationModels unavailable in this build")
    }
    func discard() async {}
}
#endif
