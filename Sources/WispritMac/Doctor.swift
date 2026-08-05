import Foundation
import WispritKit

/// `wisprit doctor` — diagnose the environment and permissions.
///
/// Port of `wisprit/doctor.py`, with the Python-era checks that no longer have
/// a subject (the `apple_live` subprocess probe, `mlx-whisper` importability,
/// the `wisprit_refine` binary + `swiftc`) replaced by the native equivalents:
/// `SpeechTranscriber` availability + installed locale assets, and
/// FoundationModels availability. Everything else — every remedy string, the
/// "Accessibility implies Input Monitoring" leniency, the two non-checkable
/// reminders — carries over unchanged.
///
/// The report is built from a plain `DoctorFacts` value, so the checklist, the
/// remedies and the exit-code rule are all testable without a single TCC grant.

// MARK: - Report model

public enum DoctorMark: String, Sendable, Equatable {
    case ok, warn, bad

    /// The Python's colored glyphs.
    var glyph: String {
        switch self {
        case .ok: return "\u{001B}[32m✓\u{001B}[0m"
        case .bad: return "\u{001B}[31m✗\u{001B}[0m"
        case .warn: return "\u{001B}[33m!\u{001B}[0m"
        }
    }
}

public struct DoctorCheck: Sendable, Equatable {
    public var mark: DoctorMark
    public var label: String
    public var detail: String
    /// Whether a non-ok result makes `wisprit doctor` exit non-zero.
    public var isRequired: Bool

    public init(_ mark: DoctorMark, _ label: String, _ detail: String = "",
                required: Bool = false) {
        self.mark = mark
        self.label = label
        self.detail = detail
        self.isRequired = required
    }
}

public struct DoctorReport: Sendable, Equatable {
    public var executablePath: String
    public var checks: [DoctorCheck]
    public var reminders: [String]

    /// Exit 0 only when every required check is green.
    public var isReady: Bool {
        !checks.contains { $0.isRequired && $0.mark != .ok }
    }

    public func check(_ label: String) -> DoctorCheck? {
        checks.first { $0.label == label }
    }

    public func rendered() -> String {
        var out = "\nWisprit doctor  (v\(WispritVersion.string))\n" + String(repeating: "─", count: 44) + "\n"
        out += "  executable: \(executablePath)\n"
        out += "  (TCC permissions are granted to THIS binary; a rebuilt or moved\n"
        out += "   app must be re-granted Accessibility and Input Monitoring.)\n\n"
        for check in checks {
            out += "  \(check.mark.glyph)  \(check.label)"
            if !check.detail.isEmpty { out += "  — \(check.detail)" }
            out += "\n"
        }
        out += "\n  Reminders (can't be auto-checked):\n"
        for reminder in reminders {
            out += "  \(DoctorMark.warn.glyph)  \(reminder)\n"
        }
        out += String(repeating: "─", count: 44) + "\n"
        out += "  \(isReady ? "READY" : "NOT READY — resolve the ✗ items above")\n\n"
        return out
    }
}

/// Everything the report is derived from. Filled by real probes in
/// `Doctor.gather()`; constructed directly in tests.
public struct DoctorFacts: Sendable {
    public var executablePath: String = "(unknown)"

    // Permissions
    public var accessibility: Bool = false
    public var inputMonitoring: String = "undetermined"   // granted|denied|undetermined
    public var postEventAccess: Bool = false
    public var microphone: String = "undetermined"        // granted|denied|undetermined|restricted
    public var secureInputActive: Bool = false

    // Speech
    public var transcriberAvailable: Bool = false
    public var speechDetail: String = ""
    public var speechFix: String?
    public var speechOK: Bool = false
    public var installedLocales: [String] = []
    /// `AssetInventory.status` — ADVISORY ONLY, printed but never gating.
    public var assetStatus: String = ""
    public var requestedLocale: String = "en-US"

    // Apple Intelligence
    public var aiAvailable: Bool = false
    public var aiReason: String = ""

    // State files
    public var configValid: Bool = false
    public var configPath: String = ""
    public var dictionaryValid: Bool = false
    public var dictionaryPath: String = ""

    public init() {}
}

// MARK: - Pure report construction

public enum Doctor {

    public static let reminders = [
        "System Settings ▸ Keyboard ▸ \"Press 🌐 key to\" → \"Do Nothing\"\n"
        + "       (otherwise a bare Fn press opens emoji/dictation over Wisprit)",
        "On external keyboards Fn often isn't sent to macOS — switch\n"
        + "       hotkey to \"right_option\" in config.json if Fn never fires.",
    ]

    public static func report(from facts: DoctorFacts) -> DoctorReport {
        var checks: [DoctorCheck] = []

        // --- permissions -----------------------------------------------------
        checks.append(DoctorCheck(
            facts.accessibility ? .ok : .bad, "Accessibility",
            facts.accessibility
                ? "can post the paste keystroke"
                : "MISSING → System Settings ▸ Privacy & Security ▸ Accessibility",
            required: true))

        // Input Monitoring can read stale (IOHIDCheckAccess caches); Accessibility
        // implies it in practice, so don't fail hard when Accessibility is granted.
        let imMark: DoctorMark
        switch facts.inputMonitoring {
        case "granted": imMark = .ok
        case "denied": imMark = .bad
        default: imMark = .warn
        }
        let imDetail = [
            "granted": "hotkey tap can see the Fn key",
            "denied": "MISSING → System Settings ▸ Privacy & Security ▸ Input Monitoring",
            "undetermined": "not yet determined (grant on first run, or in Input Monitoring)",
        ][facts.inputMonitoring] ?? "unknown state"
        checks.append(DoctorCheck(
            imMark, "Input Monitoring", imDetail,
            required: !facts.accessibility))

        checks.append(DoctorCheck(
            facts.postEventAccess ? .ok : .warn, "Post-event access",
            facts.postEventAccess
                ? "CGPreflightPostEventAccess: this process may post ⌘V"
                : "CGPreflightPostEventAccess is false — posted events will be dropped. "
                  + "Same pane as Accessibility; grant it there and relaunch."))

        let micMark: DoctorMark
        switch facts.microphone {
        case "granted": micMark = .ok
        case "denied", "restricted": micMark = .bad
        default: micMark = .warn
        }
        let micDetail = [
            "granted": "capture allowed",
            "undetermined": "will prompt on first recording",
            "denied": "MISSING → System Settings ▸ Privacy & Security ▸ Microphone",
            "restricted": "restricted by policy",
        ][facts.microphone] ?? "unknown state"
        checks.append(DoctorCheck(
            micMark, "Microphone", micDetail,
            required: facts.microphone == "denied" || facts.microphone == "restricted"))

        checks.append(DoctorCheck(
            facts.secureInputActive ? .warn : .ok, "Secure Keyboard Entry",
            facts.secureInputActive
                ? "ACTIVE right now — the hotkey won't fire until it clears "
                  + "(a password field or an app like Slack holds it)"
                : "not active"))

        // --- speech ----------------------------------------------------------
        //
        // Keyed on `SpeechTranscriber.isAvailable` + membership of the requested
        // locale in `installedLocales`. AssetInventory.status is reported for
        // diagnostics ONLY: on a machine where transcription demonstrably works
        // it returns `.supported`, not `.installed`, so a check keyed on
        // `.installed` reports a false failure (spike S1, probe q5).
        var speechDetail = facts.speechDetail
        if !facts.assetStatus.isEmpty {
            speechDetail += " [AssetInventory.status: \(facts.assetStatus) — advisory only]"
        }
        if let fix = facts.speechFix, !facts.speechOK {
            speechDetail += " — \(fix)"
        }
        checks.append(DoctorCheck(
            facts.speechOK ? .ok : .bad, "SpeechTranscriber (on-device ASR)",
            speechDetail, required: true))

        // --- Apple Intelligence ----------------------------------------------
        // Not fatal: dictation degrades to the deterministic pipeline.
        checks.append(DoctorCheck(
            facts.aiAvailable ? .ok : .warn, "AI cleanup (Apple Intelligence)",
            facts.aiAvailable
                ? "FoundationModels available; on-path cleanup can run"
                : "unavailable: \(facts.aiReason.isEmpty ? "unknown" : facts.aiReason) — "
                  + "enable it in System Settings ▸ Apple Intelligence & Siri"))

        // --- state files -----------------------------------------------------
        checks.append(DoctorCheck(
            facts.configValid ? .ok : .warn, "config.json",
            facts.configValid ? facts.configPath
                : "missing/invalid at \(facts.configPath) (run once to create)"))
        checks.append(DoctorCheck(
            facts.dictionaryValid ? .ok : .warn, "dictionary.json",
            facts.dictionaryValid ? facts.dictionaryPath
                : "missing/invalid at \(facts.dictionaryPath) (run once to create)"))

        return DoctorReport(executablePath: facts.executablePath,
                            checks: checks,
                            reminders: reminders)
    }
}

/// Version reported by `doctor` and stamped into the app bundle.
public enum WispritVersion {
    public static let string = "2.0.0-dev"
}
