import Foundation
import WispritPersistence

// The Settings window's decisions, kept out of the views so they can be pinned
// by tests: which language a stored identifier is, what the Microphone pane
// says about the device and its volume, which changes only take effect after a
// restart, and the one-line copy for the data inventory.

// MARK: - Language

/// The Language picker's matching rule.
///
/// The bug this exists for: `config.json` stores `en-US` (BCP-47, the shipped
/// default) while `SpeechTranscriber.installedLocales` reports `en_US` (ICU),
/// so a picker that compared the two strings selected nothing and drew blank.
/// Speech itself treats them as one locale (`AsrDoctor.matches`), so this does
/// too: identifiers are compared after normalizing `_`/`-` and case.
///
/// What gets WRITTEN is the hyphen form. Every consumer of `locale` accepts
/// either (`Locale(identifier:)` for the engines, `AsrDoctor.matches` for the
/// doctor), but the shipped default and `wisprit eval`'s default are `en-US`,
/// and the eval cache key hashes the string — so the hyphen form keeps a user
/// who re-picks their own language byte-identical, and choosing the language
/// already stored writes nothing at all.
public enum SettingsLanguage {

    public struct Option: Identifiable, Equatable, Sendable {
        /// What `locale` is set to when this row is chosen.
        public var value: String
        /// "English (United States)", in the display locale.
        public var name: String
        /// False only for the stored value when no installed voice matches it:
        /// it is still listed, so the picker never draws blank.
        public var isInstalled: Bool

        public var id: String { SettingsLanguage.key(value) }
    }

    /// `en-US`, `en_US` and `EN_us` all key to `en-us`.
    public static func key(_ identifier: String) -> String {
        identifier.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
    }

    public static func matches(_ a: String, _ b: String) -> Bool {
        key(a) == key(b)
    }

    /// The on-disk form for an installed identifier: `en_US` → `en-US`,
    /// `zh_Hans_CN` → `zh-Hans-CN`. Case is preserved — BCP-47 casing is
    /// already what Speech reports.
    public static func storageValue(_ identifier: String) -> String {
        identifier.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
    }

    /// "English (United States)". Falls back to the identifier itself for a
    /// string Foundation cannot name.
    public static func displayName(_ identifier: String,
                                   in display: Locale = .autoupdatingCurrent) -> String {
        let normalized = storageValue(identifier)
        return display.localizedString(forIdentifier: normalized) ?? identifier
    }

    /// Every installed voice once, sorted by name, each carrying the value to
    /// write. The installed row that matches the stored setting carries the
    /// STORED spelling, so selecting it is a no-op. A stored value with no
    /// installed match is appended, marked not installed.
    public static func options(installed: [String], current: String,
                               display: Locale = .autoupdatingCurrent) -> [Option] {
        var seen = Set<String>()
        var options: [Option] = []
        for identifier in installed {
            let k = key(identifier)
            guard !k.isEmpty, seen.insert(k).inserted else { continue }
            options.append(Option(
                value: matches(identifier, current) ? current : storageValue(identifier),
                name: displayName(identifier, in: display),
                isInstalled: true))
        }
        options.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let currentKey = key(current)
        if !currentKey.isEmpty, !seen.contains(currentKey) {
            options.append(Option(value: current,
                                  name: displayName(current, in: display),
                                  isInstalled: false))
        }
        return options
    }

    /// The option id the stored value selects — nil only when there is no
    /// stored value at all.
    public static func selection(current: String, in options: [Option]) -> String? {
        options.first { matches($0.value, current) }?.id
    }

    /// What choosing `value` should write, or nil when it is the language
    /// already stored (in any spelling).
    public static func write(choosing value: String, current: String) -> String? {
        matches(value, current) ? nil : storageValue(value)
    }
}

// MARK: - Microphone

/// What the Microphone pane says. Every input is a fact the doctor probe
/// already gathers; nothing here opens or listens to a microphone — the mic is
/// live only while the dictation key is held, and Settings never holds it.
public enum MicrophoneCopy {

    public struct Line: Equatable, Sendable {
        public var title: String
        public var help: String
    }

    /// Which microphone the next dictation will use, and why.
    ///
    /// `prefer_builtin` pins the Mac mic only for the two headset cases
    /// (`InputDevicePolicy.shouldPinBuiltIn`); a USB desk mic is never
    /// displaced, so for everything else the answer is the system input.
    public static func dictatingDevice(name: String, transport: String,
                                       narrowband: Bool, headsetRisk: Bool,
                                       policy: WindowSettings.InputDevicePolicyOption,
                                       hasProbed: Bool) -> Line {
        guard !name.isEmpty else {
            return hasProbed
                ? Line(title: "No microphone found",
                       help: "Connect one, or pick an input in Sound settings.")
                : Line(title: "Checking…", help: "Reading the system input.")
        }
        let headset = narrowband || headsetRisk
        if headset, policy == .preferBuiltin {
            return Line(title: "Mac microphone",
                        help: "\(name) is connected; the Mac mic keeps playback clear.")
        }
        if headset {
            return Line(title: name, help: "Headphones are connected, so their mic dictates.")
        }
        let kind = transport.isEmpty ? "" : "\(capitalized(transport)) · "
        return Line(title: name, help: "\(kind)the input chosen in Sound settings.")
    }

    /// The system input-volume row. `nil` is a device with no software slider
    /// (several USB interfaces and aggregates have none). "Low" uses the same
    /// ceiling as the session's one-time advisory (`InputVolumeAdvisor`), so
    /// the window and the notch never disagree about what low means.
    public static func volume(_ scalar: Float?, lowCeiling: Float) -> (value: String, help: String, isLow: Bool) {
        guard let scalar else {
            return ("—", "This input has no volume slider.", false)
        }
        let percent = "\(Int((max(0, min(1, scalar)) * 100).rounded()))%"
        if scalar < lowCeiling {
            return (percent, "Low. Raise it in Sound settings so quiet speech isn't missed.", true)
        }
        return (percent, "Set in Sound settings.", false)
    }

    /// The test row. Settings never opens the mic, so the test is the real
    /// thing: hold the key.
    public static func testHint(hotkey: WindowSettings.HotkeyOption, notchShown: Bool) -> String {
        let key = hotkey == .fn ? "🌐" : "right ⌥"
        return notchShown
            ? "Hold \(key) and speak. The notch shows your level."
            : "Hold \(key) and speak, then check Dictations."
    }

    private static func capitalized(_ s: String) -> String {
        guard let first = s.first else { return s }
        return first.uppercased() + s.dropFirst()
    }
}

// MARK: - Restart

/// The settings the running app reads once, at launch — the dictation key
/// (`HotkeyMonitor`'s trigger), the language, engine and finalize timeout
/// (`AsrSettings`), the key-up grace pair, `history_detail` (a `History`
/// constructor value) and the input-source policy (`LiveTypingConfiguration`).
/// A change to any of them is saved at once but only felt after a restart, and
/// the window says so instead of letting the new key silently do nothing.
public enum LaunchTimeSettings {

    /// Title shown in the restart notice, and how to read the effective value.
    /// Effective, not raw: an absent string-keyed setting and an explicit
    /// default are the same thing to the app.
    static let entries: [(title: String, read: (Settings) -> String)] = [
        ("Dictation key", { WindowSettings.HotkeyOption.parse($0.hotkey).rawValue }),
        ("Language", { SettingsLanguage.key($0.locale) }),
        ("Speech engine", { WindowSettings.EngineOption.parse($0.engine).rawValue }),
        ("Finish waiting after", {
            String(WindowSettings.clampFinalizeTimeout($0.finalizeTimeoutMs)) }),
        ("Keep listening after release", {
            String(WindowSettings.clampKeyupGrace(KeyupGraceSettings.milliseconds($0))) }),
        ("Keep listening while you talk", {
            String(KeyupGraceAdaptiveSettings.isEnabled($0)) }),
        ("Save what was heard", { String(HistoryDetailSettings.isEnabled($0)) }),
        ("Input source", {
            WindowSettings.SelectionPolicyOption.parse(
                $0.string(SettingsKey.imSelectionPolicy) ?? "").rawValue }),
    ]

    /// One effective value per entry, in entry order.
    public static func snapshot(_ settings: Settings) -> [String] {
        entries.map { $0.read(settings) }
    }

    /// Titles of the entries whose effective value moved since `baseline`.
    public static func changed(since baseline: [String], now: [String]) -> [String] {
        zip(entries.indices, zip(baseline, now))
            .filter { $0.1.0 != $0.1.1 }
            .map { entries[$0.0].title }
    }

    /// "Dictation key and Language".
    public static func sentence(_ titles: [String]) -> String {
        switch titles.count {
        case 0: return ""
        case 1: return titles[0]
        default: return titles.dropLast().joined(separator: ", ") + " and " + titles.last!
        }
    }
}

// MARK: - Data inventory, one line each

/// The Privacy pane's row help: one line per store. `DataInventory.summary`
/// keeps the long form for the doctor's report.
public enum DataStoreCopy {
    public static func help(_ id: DataStoreID) -> String {
        switch id {
        case .transcripts: return "What you dictated. Search and Paste Last use it."
        case .metrics: return "Timings and counts per dictation, never your words."
        case .dictionary: return "Your terms and the spellings Wisprit learned."
        case .learnLedger: return "Words Wisprit may suggest, and ones you declined."
        case .models: return "Optional speech-model downloads."
        case .settings: return "Your preferences. Deleting data leaves them."
        }
    }

    public static let footer =
        "All of it stays on this Mac. Deleting transcripts keeps learned words — "
        + "delete the dictionary to forget those."
}
