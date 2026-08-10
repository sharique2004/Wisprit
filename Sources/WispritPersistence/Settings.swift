import Foundation
import WispritKit

/// Wisprit configuration: `~/.wisprit/config.json` with atomic persistence.
/// 1:1 port of `wisprit/settings.py`.
///
/// The file is loaded merged over `Settings.defaults` so a missing key always
/// resolves; `set` persists immediately (temp + fsync + rename) so a crash
/// mid-write can never truncate the config. Unknown keys found in the file are
/// preserved and re-emitted after the known ones — forward compatibility with a
/// newer build (or the Python era) editing the same file.

/// Canonical key names. Strings, not an enum case set, because the config file
/// legitimately carries keys this build has never heard of.
public enum SettingsKey {
    public static let hotkey = "hotkey"
    public static let holdDebounceMs = "hold_debounce_ms"
    public static let locale = "locale"
    public static let finalizeTimeoutMs = "finalize_timeout_ms"
    public static let fillerRemoval = "filler_removal"
    public static let ensureSentencePeriod = "ensure_sentence_period"
    public static let leadingSpace = "leading_space"
    public static let terminalBundleIDs = "terminal_bundle_ids"
    public static let pillPosition = "pill_position"
    public static let pillHidden = "pill_hidden"
    public static let historyEnabled = "history_enabled"
    public static let historyLimit = "history_limit"
    public static let engine = "engine"
    public static let aiCleanup = "ai_cleanup"
    public static let aiCleanupMaxWords = "ai_cleanup_max_words"
    public static let aiCleanupTimeoutMs = "ai_cleanup_timeout_ms"
    public static let mlxModel = "mlx_model"
    public static let pasteRestoreDelayMs = "paste_restore_delay_ms"
    public static let enabled = "enabled"
    public static let liveTyping = "live_typing"
    public static let imSelectionPolicy = "im_selection_policy"
    public static let emojiCommands = "emoji_commands"
}

public final class Settings: @unchecked Sendable {
    /// Terminal bundle IDs that get typed injection instead of a clipboard
    /// paste. Mirrors `runtime.DEFAULT_TERMINAL_BUNDLE_IDS`.
    public static let defaultTerminalBundleIDs = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.github.wez.wezterm",
        "net.kovidgoyal.kitty",
        "io.alacritty",
        "com.mitchellh.ghostty",
    ]

    /// Declaration order is contractual: it is the on-disk key order.
    public static var defaults: JSONObject {
        JSONObject([
            (SettingsKey.hotkey, .string("fn")),                    // "fn" | "right_option"
            (SettingsKey.holdDebounceMs, .int(150)),
            (SettingsKey.locale, .string("en-US")),
            (SettingsKey.finalizeTimeoutMs, .int(1500)),
            (SettingsKey.fillerRemoval, .bool(true)),
            (SettingsKey.ensureSentencePeriod, .bool(false)),
            (SettingsKey.leadingSpace, .string("auto")),            // "auto" | "always" | "never"
            (SettingsKey.terminalBundleIDs, .array(defaultTerminalBundleIDs.map { .string($0) })),
            (SettingsKey.pillPosition, .null),                      // [x, y] once the user drags it
            (SettingsKey.pillHidden, .bool(false)),
            (SettingsKey.historyEnabled, .bool(true)),
            (SettingsKey.historyLimit, .int(1000)),
            (SettingsKey.engine, .string("auto")),                  // "auto"|"apple_live"|"mlx_whisper"|"faster_whisper"
            (SettingsKey.aiCleanup, .bool(true)),                   // on-path Apple Intelligence refinement
            (SettingsKey.aiCleanupMaxWords, .int(350)),             // longer transcripts skip AI (latency/context)
            (SettingsKey.aiCleanupTimeoutMs, .int(12000)),          // hard cap; verbatim text wins on timeout
            (SettingsKey.mlxModel, .string("mlx-community/whisper-large-v3-turbo")),
            (SettingsKey.pasteRestoreDelayMs, .int(500)),           // restore too early = paste of stale clipboard
            (SettingsKey.enabled, .bool(true)),                     // master toggle from the menu
            // Appended post-Python (append-only: mid-list inserts reorder every user's file).
            (SettingsKey.liveTyping, .bool(false)),                 // IM rungs stay off until onboarding
            (SettingsKey.imSelectionPolicy, .string("warm")),       // "warm" | "per_utterance"
            (SettingsKey.emojiCommands, .bool(true)),               // spoken "<name> emoji" -> glyph
        ])
    }

    private let path: URL
    private let lock = NSRecursiveLock()
    private var data = Settings.defaults
    private let log = WLog.logger("settings")

    public init(path: URL = WispritPaths.configPath) {
        self.path = path
        reload()
    }

    public var configPath: URL { path }

    // MARK: - Reading

    public func get(_ key: String) -> SettingValue? {
        lock.lock(); defer { lock.unlock() }
        return data[key]
    }

    /// Effective configuration, in on-disk key order.
    public func asOrderedPairs() -> [(String, SettingValue)] {
        lock.lock(); defer { lock.unlock() }
        return data.pairs
    }

    public func asObject() -> JSONObject {
        lock.lock(); defer { lock.unlock() }
        return data
    }

    // MARK: - Typed accessors
    //
    // Every accessor falls back to the DEFAULTS value (not to a zero) so a
    // hand-edited config with the wrong type degrades to shipped behavior
    // instead of, say, a 0 ms debounce.

    public func string(_ key: String) -> String? {
        if case .string(let s)? = get(key) { return s }
        return nil
    }

    public func bool(_ key: String) -> Bool? {
        if case .bool(let b)? = get(key) { return b }
        return nil
    }

    public func int(_ key: String) -> Int? {
        switch get(key) {
        case .int(let i)?: return i
        case .double(let d)? where d.rounded() == d && d.magnitude < 9e15: return Int(d)
        default: return nil
        }
    }

    public func double(_ key: String) -> Double? {
        switch get(key) {
        case .double(let d)?: return d
        case .int(let i)?: return Double(i)
        default: return nil
        }
    }

    public func stringArray(_ key: String) -> [String]? {
        guard case .array(let items)? = get(key) else { return nil }
        var out: [String] = []
        for item in items {
            guard case .string(let s) = item else { return nil }
            out.append(s)
        }
        return out
    }

    public func doubleArray(_ key: String) -> [Double]? {
        guard case .array(let items)? = get(key) else { return nil }
        var out: [Double] = []
        for item in items {
            switch item {
            case .double(let d): out.append(d)
            case .int(let i): out.append(Double(i))
            default: return nil
            }
        }
        return out
    }

    private func defaultString(_ key: String) -> String {
        if case .string(let s)? = Settings.defaults[key] { return s }
        return ""
    }

    private func defaultInt(_ key: String) -> Int {
        if case .int(let i)? = Settings.defaults[key] { return i }
        return 0
    }

    private func defaultBool(_ key: String) -> Bool {
        if case .bool(let b)? = Settings.defaults[key] { return b }
        return false
    }

    public func string(_ key: String, or fallback: String) -> String { string(key) ?? fallback }
    public func int(_ key: String, or fallback: Int) -> Int { int(key) ?? fallback }
    public func bool(_ key: String, or fallback: Bool) -> Bool { bool(key) ?? fallback }

    // Named views, mirroring the Python attribute-style access.
    public var hotkey: String { string(SettingsKey.hotkey) ?? defaultString(SettingsKey.hotkey) }
    public var holdDebounceMs: Int { int(SettingsKey.holdDebounceMs) ?? defaultInt(SettingsKey.holdDebounceMs) }
    public var locale: String { string(SettingsKey.locale) ?? defaultString(SettingsKey.locale) }
    public var finalizeTimeoutMs: Int { int(SettingsKey.finalizeTimeoutMs) ?? defaultInt(SettingsKey.finalizeTimeoutMs) }
    public var fillerRemoval: Bool { bool(SettingsKey.fillerRemoval) ?? defaultBool(SettingsKey.fillerRemoval) }
    public var ensureSentencePeriod: Bool { bool(SettingsKey.ensureSentencePeriod) ?? defaultBool(SettingsKey.ensureSentencePeriod) }
    public var leadingSpace: String { string(SettingsKey.leadingSpace) ?? defaultString(SettingsKey.leadingSpace) }
    public var terminalBundleIDs: [String] { stringArray(SettingsKey.terminalBundleIDs) ?? Settings.defaultTerminalBundleIDs }
    /// nil until the user drags the pill.
    public var pillPosition: (x: Double, y: Double)? {
        guard let pair = doubleArray(SettingsKey.pillPosition), pair.count == 2 else { return nil }
        return (pair[0], pair[1])
    }
    public var pillHidden: Bool { bool(SettingsKey.pillHidden) ?? defaultBool(SettingsKey.pillHidden) }
    public var historyEnabled: Bool { bool(SettingsKey.historyEnabled) ?? defaultBool(SettingsKey.historyEnabled) }
    public var historyLimit: Int { int(SettingsKey.historyLimit) ?? defaultInt(SettingsKey.historyLimit) }
    public var engine: String { string(SettingsKey.engine) ?? defaultString(SettingsKey.engine) }
    public var aiCleanup: Bool { bool(SettingsKey.aiCleanup) ?? defaultBool(SettingsKey.aiCleanup) }
    public var aiCleanupMaxWords: Int { int(SettingsKey.aiCleanupMaxWords) ?? defaultInt(SettingsKey.aiCleanupMaxWords) }
    public var aiCleanupTimeoutMs: Int { int(SettingsKey.aiCleanupTimeoutMs) ?? defaultInt(SettingsKey.aiCleanupTimeoutMs) }
    public var mlxModel: String { string(SettingsKey.mlxModel) ?? defaultString(SettingsKey.mlxModel) }
    public var pasteRestoreDelayMs: Int { int(SettingsKey.pasteRestoreDelayMs) ?? defaultInt(SettingsKey.pasteRestoreDelayMs) }
    public var enabled: Bool { bool(SettingsKey.enabled) ?? defaultBool(SettingsKey.enabled) }
    public var emojiCommands: Bool { bool(SettingsKey.emojiCommands) ?? defaultBool(SettingsKey.emojiCommands) }

    // MARK: - Writing

    /// Update `key` and persist the whole config atomically.
    public func set(_ key: String, _ value: SettingValue) {
        lock.lock(); defer { lock.unlock() }
        data[key] = value
        save()
    }

    public func set(_ key: String, _ value: String) { set(key, .string(value)) }
    public func set(_ key: String, _ value: Int) { set(key, .int(value)) }
    public func set(_ key: String, _ value: Double) { set(key, .double(value)) }
    public func set(_ key: String, _ value: Bool) { set(key, .bool(value)) }
    public func set(_ key: String, _ value: [String]) { set(key, .array(value.map { .string($0) })) }

    public func setPillPosition(x: Double, y: Double) {
        set(SettingsKey.pillPosition, .array([.double(x), .double(y)]))
    }

    /// Re-read config.json, merging over the defaults. A missing file yields
    /// pure defaults; a corrupt file logs and keeps defaults *without*
    /// overwriting the user's file (they may be mid-edit).
    public func reload() {
        lock.lock(); defer { lock.unlock() }
        var merged = Settings.defaults
        let raw: String
        do {
            raw = try String(contentsOf: path, encoding: .utf8)
        } catch let error as NSError where error.code == NSFileReadNoSuchFileError {
            data = merged
            return
        } catch {
            log.error("cannot read \(self.path.path, privacy: .public); using defaults")
            data = merged
            return
        }
        do {
            guard case .object(let loaded) = try WispritJSON.parse(raw) else {
                log.error("\(self.path.path, privacy: .public) is not a JSON object; using defaults")
                data = merged
                return
            }
            merged.merge(loaded)
        } catch {
            log.error("corrupt JSON in \(self.path.path, privacy: .public); using defaults")
        }
        data = merged
    }

    /// Serialize first, so an unencodable value would fail before touching disk;
    /// disk/permission trouble keeps the in-memory value and stays alive.
    private func save() {
        let payload = WispritJSON.serializePretty(.object(data)) + "\n"
        do {
            try AtomicWrite.write(payload, to: path)
        } catch {
            log.error("failed to persist settings to \(self.path.path, privacy: .public)")
        }
    }

    // MARK: - Singleton

    private static let sharedLock = NSLock()
    private nonisolated(unsafe) static var sharedInstance: Settings?

    /// Module-level singleton accessor over the default config path
    /// (`settings.load()` in the Python).
    public static func load() -> Settings {
        sharedLock.lock(); defer { sharedLock.unlock() }
        if let sharedInstance { return sharedInstance }
        let instance = Settings()
        sharedInstance = instance
        return instance
    }

    /// Test seam: drop the singleton so the next `load()` re-reads (used after
    /// `WispritPaths.overrideRoot` changes).
    public static func resetSharedForTesting() {
        sharedLock.lock(); defer { sharedLock.unlock() }
        sharedInstance = nil
    }
}
