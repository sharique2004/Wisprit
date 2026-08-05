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
            pill: MainThreadPill(pill),
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
                            rawValue: settings.leadingSpace) ?? .auto)
                },
                levelTickInterval: settings.pillHidden ? nil : 0.05))

        super.init()

        self.statusMenu = StatusMenu(actions: makeMenuActions())
        let statusMenu = self.statusMenu!
        session.onStateChange = { state in
            WispritUI.callOnMain { statusMenu.update(stateNamed: state.rawValue) }
        }
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

    private var inputMonitoringAlertShown = false

    /// One-per-launch alert with a working deep link; without it a fresh
    /// install looks completely dead (no prompt, no icon if notch-hidden).
    private func showInputMonitoringAlert() {
        guard !inputMonitoringAlertShown else { return }
        inputMonitoringAlertShown = true
        let alert = NSAlert()
        alert.messageText = "Wisprit needs Input Monitoring"
        alert.informativeText = """
        The push-to-talk key can't be seen yet. In System Settings ▸ Privacy & \
        Security ▸ Input Monitoring, enable Wisprit — then QUIT AND REOPEN \
        Wisprit; macOS applies this permission only at launch.
        """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
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
            showInputMonitoringAlert()
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
            showInputMonitoringAlert()
        }
        // The grant can also be missing with a SUCCESSFULLY created tap that
        // never fires ("ghost tap") — only the watchdog can see that case.
        monitor.onGhostTap = { [weak self] in
            WispritUI.callOnMain { self?.showInputMonitoringAlert() }
        }

        // Grants are per-identity: a new launcher must be granted even when the
        // old one already was. Raise the mic prompt and audit the rest.
        Permissions.requestMicrophone()
        auditPermissions()
        startAvailabilityRefresh()

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
                    liveTypingDetail: self.liveTypingDetail)
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

    init(_ pill: Pill) { self.pill = pill }

    private func onMain(_ work: @escaping @Sendable @MainActor (Pill) -> Void) {
        WispritUI.callOnMain { [self] in work(self.pill) }
    }

    func showRecording() { onMain { $0.showRecording() } }
    func updateLevel(_ level: Double) { onMain { $0.updateLevel(level) } }
    func livePartial(_ text: String) { onMain { $0.livePartial(text) } }
    func showFinalizing() { onMain { $0.showFinalizing() } }
    func flashSuccess() { onMain { $0.flashSuccess() } }
    func flashError(_ message: String) { onMain { $0.flashError(message) } }
    func transientNotice(_ text: String) { onMain { $0.transientNotice(text) } }
    func hide() { onMain { $0.hide() } }
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
