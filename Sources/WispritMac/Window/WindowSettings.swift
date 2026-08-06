import Foundation
import WispritPersistence

/// The Settings tab's vocabulary: the choices a picker offers, the words that
/// explain them, and the clamps a stepper must respect.
///
/// Pure — it never reads or writes `Settings` itself. The window model does the
/// I/O through the existing `Settings` accessors, which keeps this whole file
/// testable and keeps the append-only key discipline in one place (every key
/// here already exists on disk; nothing new is introduced).
public enum WindowSettings {

    // MARK: - Hotkey

    public enum HotkeyOption: String, Sendable, Equatable, CaseIterable {
        case fn = "fn"
        case rightOption = "right_option"

        public var label: String {
            switch self {
            case .fn: return "🌐 (Fn)"
            case .rightOption: return "Right ⌥ (Option)"
            }
        }

        public var explanation: String {
            switch self {
            case .fn:
                return "The globe/Fn key on the built-in keyboard. Set System Settings ▸ "
                    + "Keyboard ▸ \"Press 🌐 key to\" → Do Nothing so a press doesn't open "
                    + "the emoji picker instead."
            case .rightOption:
                return "Use this on an external keyboard: many of them never send Fn to "
                    + "macOS at all, so the 🌐 hotkey simply never fires."
            }
        }

        /// Unknown values in a hand-edited config fall back to the shipped default.
        public static func parse(_ raw: String) -> HotkeyOption {
            HotkeyOption(rawValue: raw) ?? .fn
        }
    }

    // MARK: - Leading space

    public enum LeadingSpaceOption: String, Sendable, Equatable, CaseIterable {
        case auto, always, never

        public var label: String {
            switch self {
            case .auto: return "Automatic"
            case .always: return "Always"
            case .never: return "Never"
            }
        }

        public var explanation: String {
            switch self {
            case .auto:
                return "Add a space before the text only when the character before the "
                    + "cursor needs one."
            case .always: return "Always start the inserted text with a space."
            case .never: return "Never add a leading space."
            }
        }

        public static func parse(_ raw: String) -> LeadingSpaceOption {
            LeadingSpaceOption(rawValue: raw) ?? .auto
        }
    }

    // MARK: - Numeric clamps
    //
    // The window is the first surface that can set these without editing JSON,
    // so it is also the first that can set them to something absurd. Both
    // ranges bracket the shipped default generously and refuse the values that
    // break the pipeline outright (a 0 ms restore delay pastes stale clipboard
    // content; a 2 s debounce swallows real utterances).

    public static let holdDebounceRange: ClosedRange<Int> = 0...600
    public static let holdDebounceStep = 25
    public static let pasteRestoreRange: ClosedRange<Int> = 100...2000
    public static let pasteRestoreStep = 50

    public static func clampHoldDebounce(_ value: Int) -> Int {
        min(max(value, holdDebounceRange.lowerBound), holdDebounceRange.upperBound)
    }

    public static func clampPasteRestore(_ value: Int) -> Int {
        min(max(value, pasteRestoreRange.lowerBound), pasteRestoreRange.upperBound)
    }

    /// Every key the Settings tab writes. All of them already exist in
    /// `Settings.defaults`; the tab adds none, which is what keeps the on-disk
    /// key order stable for configs written by any build.
    public static let writtenKeys = [
        SettingsKey.hotkey,
        SettingsKey.holdDebounceMs,
        SettingsKey.pasteRestoreDelayMs,
        SettingsKey.leadingSpace,
        SettingsKey.fillerRemoval,
        SettingsKey.aiCleanup,
        SettingsKey.pillHidden,
        SettingsKey.historyEnabled,
        SettingsKey.enabled,
        SettingsKey.liveTyping,
    ]
}
