import Foundation

/// System Settings ▸ Keyboard ▸ "Press 🌐 key to".
///
/// This is the single most confusing failure mode of a Fn-key hotkey: with the
/// default setting a bare press opens the emoji picker or starts Apple's own
/// dictation *over* Wisprit, so the user sees the wrong panel appear and
/// concludes Wisprit is broken. `doctor` already carries it as a reminder it
/// cannot check; here it becomes a real check.
///
/// The value lives in `com.apple.HIToolbox`'s `AppleFnUsageType`. It is read
/// through `CFPreferencesCopyAppValue`, which is a plain preferences read of
/// another domain — the same thing `defaults read com.apple.HIToolbox
/// AppleFnUsageType` does. A missing value means the user has never touched the
/// setting, which on current macOS means the system default, not "do nothing".
public enum GlobeKeyUsage: Sendable, Equatable {
    case doNothing
    case changeInputSource
    case showEmoji
    case startDictation
    /// Read succeeded but the value is not one we know.
    case other(Int)
    /// The domain could not be read at all (sandbox, or the key was never set).
    case unknown

    /// `AppleFnUsageType`'s documented integers.
    public static func from(rawValue: Int?) -> GlobeKeyUsage {
        guard let rawValue else { return .unknown }
        switch rawValue {
        case 0: return .doNothing
        case 1: return .changeInputSource
        case 2: return .showEmoji
        case 3: return .startDictation
        default: return .other(rawValue)
        }
    }

    /// Only "Do Nothing" leaves the key free for Wisprit. `unknown` is NOT
    /// treated as fine: we could not prove it, and a false green here is exactly
    /// the confusion this check exists to prevent.
    public var isClear: Bool { self == .doNothing }

    public var label: String {
        switch self {
        case .doNothing: return "Do Nothing"
        case .changeInputSource: return "Change Input Source"
        case .showEmoji: return "Show Emoji & Symbols"
        case .startDictation: return "Start Dictation"
        case .other(let value): return "an unrecognised setting (\(value))"
        case .unknown: return "unknown"
        }
    }

    /// One line for the onboarding step.
    public var advice: String {
        switch self {
        case .doNothing:
            return "\"Press 🌐 key to\" is set to Do Nothing — the key is all yours."
        case .unknown:
            return "Couldn't read this setting. Check System Settings ▸ Keyboard ▸ "
                + "\"Press 🌐 key to\" and set it to Do Nothing."
        default:
            return "\"Press 🌐 key to\" is set to \(label). A bare press of 🌐 will "
                + "do that instead of dictating — set it to Do Nothing."
        }
    }
}

#if os(macOS)
import CoreFoundation

public enum GlobeKeySettings {
    static let domain = "com.apple.HIToolbox"
    static let key = "AppleFnUsageType"

    /// Read the live value. Read-only: Wisprit never writes another app's
    /// preferences — the user changes this in System Settings, we only report.
    public static func current() -> GlobeKeyUsage {
        let value = CFPreferencesCopyAppValue(key as CFString, domain as CFString)
        guard let number = value as? NSNumber else { return GlobeKeyUsage.from(rawValue: nil) }
        return GlobeKeyUsage.from(rawValue: number.intValue)
    }
}
#endif
