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
        let arguments = Array(CommandLine.arguments.dropFirst())
        switch arguments.first {
        case "doctor":
            exit(runDoctor())
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
          Wisprit doctor          permission + engine checklist (exit 0 when ready)
          Wisprit bootstrap       create ~/.wisprit and seed config + dictionary
          Wisprit hotkey [secs]   print hotkey events (needs WISPRIT_MANUAL_INPUT=1)
          Wisprit insert "text"   insert text after a 3 s countdown (same gate)
        """

    // MARK: - the app

    static func runApp() {
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
        }
        NSApplication.shared.run()
    }

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
