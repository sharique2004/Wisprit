#if os(macOS)
import AppKit
import Foundation
import WispritCorrections
import WispritDictionary
import WispritEngine
import WispritKit
import WispritMacInput
import WispritMacUI
import WispritPersistence
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
    let events: HotkeyEventQueue
    let monitor: HotkeyMonitor
    let session: SessionController
    let pill: Pill
    private var statusMenu: StatusMenu!
    private let instanceLock: SingleInstanceLock

    /// `Refiner.availability` is actor-isolated while the menu build is
    /// synchronous, so the last probed value is cached here and refreshed on a
    /// slow timer. nil (still probing) and true both show the toggle; only an
    /// explicit false swaps in the "unavailable — run Doctor" row.
    private var aiAvailability: Bool?
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

    // MARK: - startup

    /// Everything `app.py: main()` does between the lock and `NSApp.run()`.
    public func launch() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.delegate = self

        statusMenu.install()

        // Tap creation must happen on the main thread — its run-loop source is
        // added to the CURRENT CFRunLoop, which has to be the one NSApp pumps.
        if !monitor.install() {
            log.error("""
                hotkey tap failed to install — grant Input Monitoring to this app in \
                System Settings > Privacy & Security > Input Monitoring, then relaunch. \
                Run `Wisprit doctor` for the full checklist.
                """)
            // Keep running: the menu bar still works, so the user can reach Doctor.
        }

        // Grants are per-identity: a new launcher must be granted even when the
        // old one already was. Raise the mic prompt and audit the rest.
        Permissions.requestMicrophone()
        auditPermissions()
        startAvailabilityRefresh()

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
        Task { @MainActor in
            self.aiAvailability = await refiner.availability
        }
    }

    // MARK: - menu wiring

    private func makeMenuActions() -> StatusMenu.Actions {
        StatusMenu.Actions(
            state: { [weak self] in
                guard let self else { return StatusMenuState() }
                return StatusMenuState(
                    dictationEnabled: self.settings.enabled,
                    aiCleanupEnabled: self.settings.aiCleanup,
                    aiAvailability: self.aiAvailability,
                    recents: self.history.recent(limit: StatusMenuModel.recentsLimit)
                        .map(\.text))
            },
            toggleDictation: { [weak self] in
                guard let self else { return }
                self.settings.set(SettingsKey.enabled, !self.settings.enabled)
            },
            toggleAiCleanup: { [weak self] in
                guard let self else { return }
                self.settings.set(SettingsKey.aiCleanup, !self.settings.aiCleanup)
            },
            pasteLast: { [weak self] in self?.session.requestPasteLast() },
            openDictionary: { NSWorkspace.shared.open(WispritPaths.dictionaryPath) },
            openConfig: { NSWorkspace.shared.open(WispritPaths.configPath) },
            runDoctor: { AppController.openDoctorInTerminal() },
            purgeHistory: { [weak self] in self?.history.purge() },
            quit: { [weak self] in self?.terminate() })
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
        session.stop()
        monitor.uninstall()
        events.close()
        history.close()
        instanceLock.release()
        NSApplication.shared.terminate(self)
    }

    // MARK: - NSApplicationDelegate

    public func applicationWillTerminate(_ notification: Notification) {
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
#endif
