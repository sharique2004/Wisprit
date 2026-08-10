#if os(macOS)
import AppKit
import Foundation
import WispritKit
import WispritMacInput
import WispritPersistence

/// `python -m wisprit [doctor|hotkey|insert …]` — the same dispatch, natively.
/// A bare invocation runs the menu-bar app.
@main
enum WispritMacMain {

    static func main() {
        applyStateDirOverride()
        let arguments = Array(CommandLine.arguments.dropFirst())
        switch arguments.first {
        case "doctor":
            exit(runDoctor())
        case "stats":
            exit(StatsCommand.run(arguments: Array(arguments.dropFirst())))
        case "eval":
            exit(EvalCommand.run(arguments: Array(arguments.dropFirst())))
        case "window":
            // Same app, but it opens showing itself. The point of a front end is
            // that there is always a way to make it appear.
            runApp(open: WindowLaunch.parse(Array(arguments.dropFirst())))
        case "bootstrap":
            exit(runBootstrap())
        case "hotkey":
            exit(runHotkeySmoke(arguments: Array(arguments.dropFirst())))
        case "insert":
            exit(runInsertSmoke(arguments: Array(arguments.dropFirst())))
        case "--version", "version":
            print("Wisprit \(WispritVersion.string)")
            exit(0)
        case "--help", "-h", "help":
            print(usage)
            exit(0)
        case .some(let unknown) where unknown.hasPrefix("-"):
            FileHandle.standardError.write(Data("unknown option: \(unknown)\n\n\(usage)\n".utf8))
            exit(2)
        default:
            runApp()
        }
    }

    static let usage = """
        Wisprit \(WispritVersion.string) — fully-local push-to-talk dictation.

          Wisprit                 run the menu-bar app
          Wisprit window [page]   run it with the window open (home|dictionary|
                                  insights|settings|setup)
          Wisprit doctor          permission + engine checklist (exit 0 when ready)
          Wisprit stats [--days N]
                                  what metrics.log says: outcomes, empty
                                  reasons, timings (default: all time)
          Wisprit eval <verb>     accuracy harness (asr|stages|score|refine|
                                  report|all|record|verify) — see `Wisprit eval`
                                  for flags; record/verify are the human corpus
          Wisprit bootstrap       create ~/.wisprit and seed config + dictionary
          Wisprit hotkey [secs]   print hotkey events (needs WISPRIT_MANUAL_INPUT=1)
          Wisprit insert "text"   insert text after a 3 s countdown (same gate)
        """

    // MARK: - the app

    /// What `Wisprit window …` should show. Parsed here so the argument spelling
    /// is pinned by a test rather than by a string comparison in `main`.
    enum WindowLaunch: Equatable {
        case none
        case page(WispritWindowModel.Tab)
        case setupGuide

        /// The redesign renamed two pages (`status → setup`, `history → home`).
        /// Both old spellings keep working: they are in shell history, in
        /// scripts, and in a usage string people have read.
        ///
        /// `setup` stays the *guide* rather than the page, which it has always
        /// been — and the guide opens on the Setup page anyway, so nothing that
        /// worked stops working.
        static func parse(_ arguments: [String]) -> WindowLaunch {
            switch arguments.first?.lowercased() {
            case nil, "": return .page(.setup)
            case "setup", "onboarding", "guide": return .setupGuide
            case "status": return .page(.setup)
            case "history": return .page(.home)
            case let name?:
                return .page(WispritWindowModel.Tab(rawValue: name) ?? .setup)
            }
        }
    }

    static func runApp(open launch: WindowLaunch = .none) {
        try? WispritPaths.ensureStateDir()

        // Single instance: two taps would each paste on every release. The lock
        // file is shared with the Python era, so the two cannot both run.
        let lock = SingleInstanceLock()
        guard lock.acquire() else {
            WLog.logger("app").error("""
                another Wisprit instance is already running — exiting so we don't \
                double-paste. Quit the other one from its menu first.
                """)
            notify("Wisprit", "Another copy is already running.")
            exit(0)
        }

        MainActor.assumeIsolated {
            let controller = AppController(instanceLock: lock)
            controller.launch()
            switch launch {
            case .none: break
            case .page(let tab): controller.openWindow(tab: tab)
            case .setupGuide: controller.openSetupGuide()
            }
            // NSApplication.delegate is weak and every menu closure captures
            // self weakly, so THIS reference is what keeps the whole app object
            // graph (status item, pill, session) alive for the process
            // lifetime. Dropping it deallocates the controller right here and
            // the menu-bar icon vanishes while the run loop keeps spinning.
            Self.controller = controller
        }
        NSApplication.shared.run()
    }

    /// Process-lifetime owner of the app object graph — see comment above.
    @MainActor private static var controller: AppController?

    // MARK: - subcommands

    static func runDoctor() -> Int32 {
        // Doctor reads config.json; seed it first so a first run reports the
        // real paths rather than "missing".
        _ = try? Bootstrap.ensureStateDir()
        let locale = currentSettings().locale
        return runBlocking { await Doctor.run(locale: locale) }
    }

    static func runBootstrap() -> Int32 {
        do {
            let report = try Bootstrap.ensureStateDir()
            print("\(report.stateDir.path): ok")
            print("  config.json: \(report.wroteConfig ? "created" : "already present")")
            print("  dictionary.json: \(report.wroteDictionary ? "created" : "already present")")
            return 0
        } catch {
            FileHandle.standardError.write(Data("bootstrap failed: \(error)\n".utf8))
            return 1
        }
    }

    static func runHotkeySmoke(arguments: [String]) -> Int32 {
        let seconds = arguments.first.flatMap(Double.init) ?? 20
        let trigger = TriggerKey.parse(currentSettings().hotkey)
        ManualInputSmoke.listenHotkey(trigger: trigger, seconds: seconds) { print($0) }
        return 0
    }

    static func runInsertSmoke(arguments: [String]) -> Int32 {
        guard let text = arguments.first, !text.isEmpty else {
            FileHandle.standardError.write(Data("usage: Wisprit insert \"text\"\n".utf8))
            return 2
        }
        let settings = currentSettings()
        let result = ManualInputSmoke.insert(
            text: text,
            config: InserterConfig(terminalBundleIDs: settings.terminalBundleIDs,
                                   pasteRestoreDelayMs: Double(settings.pasteRestoreDelayMs)),
            emit: { print($0) })
        return result.ok ? 0 : 1
    }

    // MARK: - helpers

    /// `WISPRIT_STATE_DIR` points the whole state directory somewhere else —
    /// config, dictionary, history, metrics, log and the single-instance lock.
    ///
    /// It exists so a freshly built copy can be launched and driven (screenshots,
    /// smoke runs, a second identity) without writing a byte into the `~/.wisprit`
    /// the user's installed Wisprit is living in. Because the lock moves with it,
    /// an overridden instance also does not fight the installed one for the
    /// single-instance flock — which is exactly what you want for a throwaway run
    /// and exactly what you do NOT want by default, hence the opt-in env var.
    ///
    /// Must run before anything reads `WispritPaths`, which is why it is the
    /// first statement in `main()`.
    static func applyStateDirOverride() {
        guard let raw = ProcessInfo.processInfo.environment["WISPRIT_STATE_DIR"],
              !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let expanded = (raw as NSString).expandingTildeInPath
        WispritPaths.overrideRoot = URL(fileURLWithPath: expanded, isDirectory: true)
        // The Settings singleton may not have been touched yet, but resetting is
        // free and guarantees the next `load()` reads the overridden path.
        Settings.resetSharedForTesting()
    }

    static func currentSettings() -> Settings {
        _ = try? Bootstrap.ensureStateDir()
        return Settings.load()
    }

    /// Best-effort user notification; never lets a failure break the caller.
    static func notify(_ title: String, _ message: String) {
        let safeTitle = title.replacingOccurrences(of: "\"", with: "'")
        let safeMessage = message.replacingOccurrences(of: "\"", with: "'")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e", "display notification \"\(safeMessage)\" with title \"\(safeTitle)\"",
        ]
        try? process.run()
    }
}
#endif
