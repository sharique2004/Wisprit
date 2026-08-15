import Foundation

/// State-directory layout, mirroring wisprit/runtime.py. Everything lives under
/// `~/.wisprit` on macOS; on iOS the root is the App Group container (set at app
/// startup via `WispritPaths.overrideRoot`). Tests point this at a temp dir.
public enum WispritPaths {
    /// Overridable root; nil means the platform default.
    public nonisolated(unsafe) static var overrideRoot: URL?

    public static var stateDir: URL {
        if let overrideRoot { return overrideRoot }
        #if os(iOS)
        // iOS: the app sets overrideRoot to the App Group container at startup;
        // sandbox home keeps tests/tools working if it hasn't.
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".wisprit", isDirectory: true)
        #else
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".wisprit", isDirectory: true)
        #endif
    }

    public static var configPath: URL { stateDir.appendingPathComponent("config.json") }
    public static var dictionaryPath: URL { stateDir.appendingPathComponent("dictionary.json") }
    public static var snippetsPath: URL { stateDir.appendingPathComponent("snippets.json") }
    public static var historyPath: URL { stateDir.appendingPathComponent("history.sqlite") }
    public static var metricsPath: URL { stateDir.appendingPathComponent("metrics.log") }
    public static var logPath: URL { stateDir.appendingPathComponent("wisprit.log") }

    /// Create the state dir if missing (0700, like the Python bootstrap).
    public static func ensureStateDir() throws {
        try FileManager.default.createDirectory(
            at: stateDir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
    }
}
