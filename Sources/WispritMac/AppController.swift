#if os(macOS)
import AppKit
import Foundation
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
    private var statusMenu: StatusMenu!
    private let instanceLock: SingleInstanceLock

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
        self.history = History(settings: settings)
        self.metrics = MetricsWriter()

        self.refiner = Refiner(
            generator: AppController.makeGenerator(),
            configuration: {
                RefineConfiguration(enabled: settings.aiCleanup,
                                    maxWords: settings.aiCleanupMaxWords,
                                    timeoutMs: settings.aiCleanupTimeoutMs)
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
        let capture = MicCapture(onChunk: { pcm in asr.feed(pcm: pcm) })

        // The pill reads nothing itself; settings arrive as closures.
        let pill = Pill(configuration: Pill.Configuration(
            isSuppressed: { settings.pillHidden },
            savedPosition: {
                guard let position = settings.pillPosition else { return nil }
                return CGPoint(x: position.x, y: position.y)
            },
            persistPosition: { point in
                settings.setPillPosition(x: Double(point.x), y: Double(point.y))
            }))
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

        self.session = SessionController(
            events: events,
            asr: AsrManagerPort(asr),
            audio: MicCapturePort(capture),
            inserter: SettingsInserterPort(inserter: Inserter(), settings: settings),
            history: history,
            metrics: metrics,
            refiner: RefinerPort(refiner),
            pill: MainThreadPill(pill, isSuppressed: { settings.pillHidden }),
            vocabulary: dictionary,
            corrections: dictionary,
            corrector: SpokenSpellingCorrector(vocabulary: dictionary),
            gate: monitor,
            liveTyping: liveTyping,
            configuration: SessionController.Configuration(
                holdDebounceMs: { Double(settings.holdDebounceMs) },
                isEnabled: { settings.enabled },
                postProcessOptions: {
                    PostProcessOptions(
                        fillerRemoval: settings.fillerRemoval,
                        ensureSentencePeriod: settings.ensureSentencePeriod,
                        leadingSpace: PostProcessOptions.LeadingSpace(
                            rawValue: settings.leadingSpace) ?? .auto,
                        emojiCommands: settings.emojiCommands)
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
                vocabularyRetro: { VocabularyRetroSettings.isEnabled(settings) }))

        super.init()

        self.statusMenu = StatusMenu(actions: makeMenuActions())
        let windowModel = WispritWindowModel(
            settings: settings,
            dictionary: DictionaryEditor(store: dictionary),
            ports: AppController.makeWindowPorts(history: history,
                                                 settings: settings,
                                                 tierCache: tierCache,
                                                 paste: { [weak self] text in
                                                     self?.pasteFromWindow(text)
                                                 },
                                                 fix: { [weak self] kind in
                                                     self?.runFix(kind)
                                                 }))
        self.windowModel = windowModel
        self.windowController = MainWindowController(model: windowModel)

        let statusMenu = self.statusMenu!
        session.onStateChange = { state in
            WispritUI.callOnMain {
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
            performFix: fix)
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
            cleanLearnedTerms: { [weak self] in self?.cleanLearnedTerms() }).run(kind)
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
                    needsSetup: self.needsSetup)
            },
            openWindow: { [weak self] in self?.openWindow() },
            openSetup: { [weak self] in self?.openWindow(tab: .setup) },
            iconState: { [weak self] in
                guard let self else { return StatusIconState() }
                return StatusIconState(dictationEnabled: self.settings.enabled,
                                       needsSetup: self.needsSetup)
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
            pasteLast: { [weak self] in self?.session.requestPasteLast() },
            openDictionary: { NSWorkspace.shared.open(WispritPaths.dictionaryPath) },
            openConfig: { NSWorkspace.shared.open(WispritPaths.configPath) },
            runDoctor: { AppController.openDoctorInTerminal() },
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
            pill.transientNotice("Could not enable Live Typing — run Doctor")
        }
        refreshLiveTypingStatus()
        statusMenu?.rebuild()
    }

    /// Open a Terminal window running this same binary's `doctor` subcommand so
    /// the user can read the checklist (`app.py`'s `runDoctor_`).
    static func openDoctorInTerminal() {
        let binary = Bundle.main.executableURL?.path
            ?? ProcessInfo.processInfo.arguments.first ?? "wisprit"
        let command = "\(shellQuoted(binary)) doctor; echo; "
            + "read -n1 -r -p \\\"Press any key to close…\\\""
        let script = """
            tell application "Terminal"
                do script "\(command)"
                activate
            end tell
            """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()
    }

    private static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    func terminate() {
        availabilityTimer?.invalidate()
        // Commits anything still marked, closes the session, and gives the input
        // source back — leaving a palette source selected after we quit would
        // strand the user's field.
        liveTyping.shutdown()
        session.stop()
        monitor.uninstall()
        events.close()
        history.close()
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
    func hide() { onMain { $0.hide() } }
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
