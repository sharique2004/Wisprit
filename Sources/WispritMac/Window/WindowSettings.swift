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

    // MARK: - Live Typing input-source policy

    /// `im_selection_policy` — whether the input source is left selected between
    /// utterances. An Advanced row under Live Typing (§3.6).
    public enum SelectionPolicyOption: String, Sendable, Equatable, CaseIterable {
        case warm
        case perUtterance = "per_utterance"

        public var label: String {
            switch self {
            case .warm: return "Keep it warm"
            case .perUtterance: return "Per utterance"
            }
        }

        public var explanation: String {
            switch self {
            case .warm:
                return "Wisprit keeps its input source selected between utterances, so the "
                    + "first word of the next one lands without a switch."
            case .perUtterance:
                return "Wisprit selects its input source only while you are speaking, and "
                    + "hands it straight back."
            }
        }

        public static func parse(_ raw: String) -> SelectionPolicyOption {
            SelectionPolicyOption(rawValue: raw) ?? .warm
        }
    }

    // MARK: - Speech engine

    /// `engine`. Only the two values that exist: `mlx_whisper` and
    /// `faster_whisper` are vestigial config values with no implementation
    /// behind them, and offering them would be offering a broken app (§3.6).
    public enum EngineOption: String, Sendable, Equatable, CaseIterable {
        case auto
        case appleLive = "apple_live"

        public var label: String {
            switch self {
            case .auto: return "Automatic"
            case .appleLive: return "Apple live speech"
            }
        }

        /// Anything else on disk — including the unbuilt engines — reads as
        /// `auto` rather than being rewritten, so a hand-edited config survives
        /// a visit to this page untouched unless the user changes the control.
        public static func parse(_ raw: String) -> EngineOption {
            EngineOption(rawValue: raw) ?? .auto
        }
    }

    // MARK: - History

    /// `history_limit` — the four sizes the menu offers.
    public static let historyLimitChoices = [100, 500, 1000, 5000]

    public static func clampHistoryLimit(_ value: Int) -> Int {
        // Snap to the nearest offered size rather than refusing a hand-edited
        // one: the menu has to be able to show *something* selected.
        historyLimitChoices.min { abs($0 - value) < abs($1 - value) } ?? 1000
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

    public static let aiCleanupMaxWordsRange: ClosedRange<Int> = 100...1000
    public static let aiCleanupMaxWordsStep = 50
    public static let aiCleanupTimeoutRange: ClosedRange<Int> = 4000...30000
    public static let aiCleanupTimeoutStep = 1000
    public static let finalizeTimeoutRange: ClosedRange<Int> = 500...5000
    public static let finalizeTimeoutStep = 250

    public static func clampAiCleanupMaxWords(_ value: Int) -> Int {
        min(max(value, aiCleanupMaxWordsRange.lowerBound), aiCleanupMaxWordsRange.upperBound)
    }

    public static func clampAiCleanupTimeout(_ value: Int) -> Int {
        min(max(value, aiCleanupTimeoutRange.lowerBound), aiCleanupTimeoutRange.upperBound)
    }

    public static func clampFinalizeTimeout(_ value: Int) -> Int {
        min(max(value, finalizeTimeoutRange.lowerBound), finalizeTimeoutRange.upperBound)
    }

    // MARK: - Gated sections (§3.6)

    /// What a settings group whose feature might not exist should render.
    ///
    /// Three states, and the middle one is the point: a feature that is missing
    /// but fixable becomes one row with one button, never a disabled toggle.
    public enum Gate: Equatable, Sendable {
        /// The feature exists here — draw the group.
        case available
        /// Structurally impossible on this Mac — the group does not exist.
        case absent
        /// One row: an explanation and the button that fixes it.
        case fixable(message: String, fixTitle: String, fix: SetupFixKind)
    }

    /// Apple Intelligence, from `DoctorFacts`.
    ///
    /// `FoundationModels` reports its unavailability as an enum case name
    /// (`deviceNotEligible`, `appleIntelligenceNotEnabled`, `modelNotReady`),
    /// which `Doctor` stores verbatim in `aiReason`. Only ineligible hardware —
    /// and a build with no `FoundationModels` at all — is structural; everything
    /// else is a switch in System Settings.
    public static func appleIntelligenceGate(available: Bool, reason: String) -> Gate {
        if available { return .available }
        let lowered = reason.lowercased()
        if lowered.contains("devicenoteligible") || lowered.contains("unavailable in this build") {
            return .absent
        }
        return .fixable(
            message: "Turn on Apple Intelligence to let Wisprit clean up what it hears.",
            fixTitle: "Open Apple Intelligence",
            fix: .openAppleIntelligenceSettings)
    }

    /// Live Typing, from the checklist row plus whether this build ships an
    /// input method at all.
    public static func liveTypingGate(isStaged: Bool, mark: DoctorMark?) -> Gate {
        guard isStaged else { return .absent }
        guard mark == .ok else {
            return .fixable(
                message: "Wisprit can type into the field while you speak. This installs a "
                    + "small input method and macOS will ask you to approve it.",
                fixTitle: "Enable Live Typing…",
                fix: .enableLiveTyping)
        }
        return .available
    }

    /// Every `Settings.defaults` key the Settings page writes. All of them
    /// already exist there; the page adds none, which is what keeps the on-disk
    /// key order stable for configs written by any build. (The context keys —
    /// `ContextSettings` — are deliberately NOT here: they follow the
    /// `LiveTypingSettings` string-key precedent, living outside the
    /// golden-pinned defaults, and the file preserves keys it does not know.)
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
        // Added by the §3.6 rebuild. Still no new keys: every one of these was
        // already in `Settings.defaults` and only reachable by editing JSON.
        SettingsKey.locale,
        SettingsKey.ensureSentencePeriod,
        SettingsKey.terminalBundleIDs,
        SettingsKey.aiCleanupMaxWords,
        SettingsKey.aiCleanupTimeoutMs,
        SettingsKey.imSelectionPolicy,
        SettingsKey.historyLimit,
        SettingsKey.finalizeTimeoutMs,
        SettingsKey.engine,
        SettingsKey.pillPosition,
    ]
}
