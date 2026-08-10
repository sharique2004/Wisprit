import Foundation
import WispritIMProtocol
import WispritKit
import WispritPersistence

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

    private var severity: Int {
        switch self {
        case .ok: return 0
        case .warn: return 1
        case .bad: return 2
        }
    }

    /// The more alarming of two marks — how one window row can stand for several
    /// doctor checks without hiding the worst of them. `nil` is "that check was
    /// not emitted", which is not evidence of anything.
    public static func worst(_ lhs: DoctorMark, _ rhs: DoctorMark?) -> DoctorMark {
        guard let rhs else { return lhs }
        return lhs.severity >= rhs.severity ? lhs : rhs
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

    // Live in-field streaming (the palette input method)
    /// The `live_typing` setting.
    public var liveTypingEnabled: Bool = false
    /// `Wisprit.app/Contents/Library/InputMethods/WispritIM.app` is present.
    public var imStaged: Bool = false
    public var imStagedPath: String = ""
    /// Installed / registered / enabled / selected, straight from TIS.
    public var imStatus = InputMethodStatus()
    /// A message reached `WispritIM.app` and came back.
    public var imReachable: Bool = false
    /// `IMBundleTemplate.violations` against the INSTALLED bundle's Info.plist —
    /// how a half-updated install gets caught instead of silently never
    /// receiving a client.
    public var imPlistViolations: [String] = []

    // State files
    public var configValid: Bool = false
    public var configPath: String = ""
    public var dictionaryValid: Bool = false
    public var dictionaryPath: String = ""

    // Accuracy and hygiene — how well dictation has been GOING, which is a
    // different question from whether it can run at all. Nothing here is ever
    // required; see the rows themselves.
    /// A recent slice of `metrics.log`, already summarized. nil when it has not
    /// been read — which is not the same as "no utterances".
    public var metrics: MetricsSummary?
    /// The learn loop's own entries in dictionary.json, re-judged.
    public var learnedTerms = LearnedTermCleanup.Audit()
    /// `docs/eval/BASELINE.json`, when this build can see the checkout it came
    /// from. A shipped .app never can.
    public var evalBaselinePath: String?
    /// The macOS build that baseline was recorded on, nil when it records none.
    public var evalBaselineOSBuild: String?
    /// This Mac's build, as `sw_vers -buildVersion` prints it.
    public var osBuild: String = ""

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

        // --- live in-field streaming ------------------------------------------
        //
        // Never required: live typing is the Developer-ID-only rung 1 of the
        // insertion ladder, and every machine without it still dictates by
        // pasting at the end. A red mark here would call a perfectly healthy
        // install broken.
        checks.append(contentsOf: liveTypingChecks(facts))

        // --- state files -----------------------------------------------------
        checks.append(DoctorCheck(
            facts.configValid ? .ok : .warn, "config.json",
            facts.configValid ? facts.configPath
                : "missing/invalid at \(facts.configPath) (run once to create)"))
        checks.append(DoctorCheck(
            facts.dictionaryValid ? .ok : .warn, "dictionary.json",
            facts.dictionaryValid ? facts.dictionaryPath
                : "missing/invalid at \(facts.dictionaryPath) (run once to create)"))

        // --- accuracy & hygiene ----------------------------------------------
        //
        // None of the three can fail a doctor run, and none is ever `required`.
        // They report on how well dictation has been going — a question a red
        // mark cannot answer, because a Wisprit that works perfectly and has
        // simply never been measured is not broken.
        checks.append(dictationHealth(facts))
        checks.append(learnedTerms(facts))
        checks.append(evalBaseline(facts))

        return DoctorReport(executablePath: facts.executablePath,
                            checks: checks,
                            reminders: reminders)
    }

    // MARK: - dictation health

    public static let dictationHealthLabel = "Dictation health"

    /// Share of utterances that may silently produce nothing before the row
    /// says so. The live stream's real rate is ~2% (`produced_nothing` with
    /// audible speech and a long enough hold); this is a REGRESSION alarm, not
    /// a claim that 2% is fine.
    public static let unexplainedEmptyWarn = 0.02

    static func dictationHealth(_ facts: DoctorFacts) -> DoctorCheck {
        guard let metrics = facts.metrics, metrics.total > 0 else {
            let scope = facts.metrics.map { " (\($0.window.label))" } ?? ""
            return DoctorCheck(.ok, dictationHealthLabel,
                               "no utterances recorded\(scope) — see: Wisprit stats")
        }
        let detail = "\(metrics.total) utterances (\(metrics.window.label)); "
            + "\(metrics.unexplainedEmpty) silently produced nothing "
            + "(\(percent(metrics.unexplainedEmptyRate)) — audible speech, clean finish, no text)"
        guard metrics.unexplainedEmptyRate > unexplainedEmptyWarn else {
            return DoctorCheck(.ok, dictationHealthLabel, detail)
        }
        return DoctorCheck(.warn, dictationHealthLabel,
                           detail + " — above the \(percent(unexplainedEmptyWarn)) expected; "
                           + "run: Wisprit stats for the empty_reason breakdown")
    }

    // MARK: - learned terms

    public static let learnedTermsLabel = "Learned terms"

    /// Named so the row is actionable from a terminal, where there is no button.
    public static let cleanLearnedTermsTitle = "Clean Up Learned Terms"
    public static let learnedTermsRemedy =
        "open the Wisprit window ▸ Setup and choose \"\(cleanLearnedTermsTitle)\": "
        + "it writes dictionary.json.bak first, folds each one back into the term it is "
        + "a spelling of, and quarantines the rest. Nothing you typed yourself is touched."

    /// Warn-only, and quiet when the dictionary is clean. A learned spelling
    /// that merges into a term the file already has is a duplicate of that
    /// name, and every one of them makes the next misrecognition likelier —
    /// but the user's own file is never edited without them asking.
    static func learnedTerms(_ facts: DoctorFacts) -> DoctorCheck {
        let audit = facts.learnedTerms
        guard !audit.suspects.isEmpty else {
            return DoctorCheck(.ok, learnedTermsLabel,
                               audit.examined == 0
                                   ? "nothing learned by spelling yet"
                                   : "\(audit.examined) learned by spelling, all plausible")
        }
        return DoctorCheck(
            .warn, learnedTermsLabel,
            "\(audit.suspects.count) of \(audit.examined) learned spellings look wrong: "
            + "\(audit.names) — \(learnedTermsRemedy)")
    }

    // MARK: - accuracy eval

    public static let evalBaselineLabel = "Accuracy eval baseline"
    public static let evalRerunCommand = "Wisprit eval all"

    /// Info, not judgement. The baseline lives in the repo, so a shipped copy
    /// has none and says so; a checkout whose baseline predates an OS update
    /// gets a warn, because the on-device speech and refine models ship WITH
    /// the OS and every recorded number is attributable to one build.
    static func evalBaseline(_ facts: DoctorFacts) -> DoctorCheck {
        guard facts.evalBaselinePath != nil else {
            return DoctorCheck(.ok, evalBaselineLabel,
                               "no eval baseline recorded — run: \(evalRerunCommand)")
        }
        guard let recorded = facts.evalBaselineOSBuild, !recorded.isEmpty else {
            return DoctorCheck(.ok, evalBaselineLabel,
                               "recorded, but with no os_build to compare against — "
                               + "re-run: \(evalRerunCommand)")
        }
        guard !facts.osBuild.isEmpty else {
            return DoctorCheck(.ok, evalBaselineLabel,
                               "recorded on macOS build \(recorded); this Mac's build "
                               + "could not be read, so staleness is unknown")
        }
        guard !osBuildMatches(recorded: recorded, live: facts.osBuild) else {
            return DoctorCheck(.ok, evalBaselineLabel, "recorded on macOS build \(recorded)")
        }
        return DoctorCheck(
            .warn, evalBaselineLabel,
            "recorded on macOS build \(recorded); this Mac runs \(facts.osBuild) — the "
            + "on-device speech and refine models ship with the OS, so the accepted "
            + "numbers are stale. Re-run: \(evalRerunCommand)")
    }

    /// Lenient on shape, strict on identity: the scoreboard may record the
    /// build alone ("25A123") or with the marketing version ("26.0 (25A123)"),
    /// and a doctor row must not call two spellings of the same build a
    /// regression.
    public static func osBuildMatches(recorded: String, live: String) -> Bool {
        let a = recorded.trimmingCharacters(in: .whitespaces).lowercased()
        let b = live.trimmingCharacters(in: .whitespaces).lowercased()
        guard !a.isEmpty, !b.isEmpty else { return false }
        return a == b || a.contains(b) || b.contains(a)
    }

    static func percent(_ rate: Double) -> String { String(format: "%.1f%%", rate * 100) }

    // MARK: - live typing

    public static let liveTypingLabel = "Live Typing (input method)"
    public static let liveTypingBridgeLabel = "Live Typing bridge (XPC)"
    public static let liveTypingBundleLabel = "Live Typing bundle"

    /// Three questions, in the order that fixing them unblocks the next:
    /// is the input method REGISTERED, is it ENABLED, and is the bridge
    /// REACHABLE. Each carries the exact remedy.
    static func liveTypingChecks(_ facts: DoctorFacts) -> [DoctorCheck] {
        var checks: [DoctorCheck] = []
        let verdict = IMPreflight.evaluate(facts.imStatus)

        // 1. registered + enabled.
        let registrationDetail: String
        let registrationMark: DoctorMark
        if !facts.imStaged {
            registrationMark = .warn
            registrationDetail = "no WispritIM.app inside this build "
                + "(expected at \(facts.imStagedPath.isEmpty ? IMStagedBundleLayout.relativePath : facts.imStagedPath)) "
                + "— rebuild with scripts/build_app.sh; dictation still pastes at the end"
        } else if verdict.isUsable {
            registrationMark = .ok
            registrationDetail = "registered and enabled"
                + (facts.imStatus.selected ? ", selected now" : ", selected when you dictate")
        } else {
            registrationMark = .warn
            registrationDetail = "registered: \(facts.imStatus.registered), "
                + "enabled: \(facts.imStatus.enabled) — "
                + remedy(for: verdict)
        }
        checks.append(DoctorCheck(registrationMark, liveTypingLabel, registrationDetail))

        // 2. the bridge.
        let bridgeMark: DoctorMark
        let bridgeDetail: String
        if !verdict.isUsable {
            bridgeMark = .warn
            bridgeDetail = "not checked — install and enable the input method first"
        } else if facts.imReachable {
            bridgeMark = .ok
            bridgeDetail = "WispritIM.app answered on \(WispritIMNaming.machServiceName)"
        } else if !facts.imStatus.selected {
            bridgeMark = .warn
            bridgeDetail = "input method is not running right now — Wisprit selects it "
                + "when you start dictating, which is what launches it. Hold the "
                + "dictation key once, then re-run doctor."
        } else {
            bridgeMark = .warn
            bridgeDetail = "selected but not answering on \(WispritIMNaming.machServiceName) — "
                + "choose Live Typing ▸ Enable Live Typing… from the Wisprit menu to "
                + "reinstall, or log out and back in. Dictation keeps working by pasting."
        }
        checks.append(DoctorCheck(bridgeMark, liveTypingBridgeLabel, bridgeDetail))

        // 3. the installed bundle's identity keys, which a half-finished update
        //    silently breaks.
        if facts.imStatus.bundleInstalled {
            let violations = facts.imPlistViolations
            checks.append(DoctorCheck(
                violations.isEmpty ? .ok : .bad, liveTypingBundleLabel,
                violations.isEmpty
                    ? "Info.plist keys are correct"
                    : violations.joined(separator: "; ")
                      + " — choose Live Typing ▸ Enable Live Typing… to reinstall"))
        }

        return checks
    }

    // The verdicts and substance are `IMPreflight`'s; this override owns only
    // the click-path wording so doctor copy can track the shipping menu
    // without touching the protocol target.
    static func remedy(for verdict: IMPreflightVerdict,
                       layout: IMInstallLayout = .user) -> String {
        let menuItem = "choose \"Enable Live Typing…\" from the Wisprit menu"
        switch verdict {
        case .ready:
            return "Live in-field streaming is ready."
        case .notSelected:
            return "Installed and enabled. Wisprit selects it when you start dictating."
        case .needsInstall:
            return "\(menuItem) — it copies WispritIM.app into "
                + "\(layout.inputMethodsDirectory.path) and registers it."
        case .needsRegistration:
            return "WispritIM.app is in place but macOS has not registered it. "
                + "\(menuItem) to re-register, or log out and back in."
        case .needsEnable:
            return "macOS needs your permission to activate the Wisprit input method. "
                + "\(menuItem); approve the dialog that says Wisprit wants to activate "
                + "a third-party input method. (You can also do it by hand in "
                + "System Settings ▸ Keyboard ▸ Input Sources.)"
        case .needsUpdate(let installed, let staged):
            return "A newer input method ships with this Wisprit "
                + "(installed \(installed ?? "unknown"), bundled \(staged ?? "unknown")) — "
                + "\(menuItem) to update."
        }
    }
}

/// Kept next to the report so the pure builder can name the staged location
/// without importing the macOS-only bundle helpers.
public enum IMStagedBundleLayout {
    public static let relativePath = "Contents/Library/InputMethods/WispritIM.app"
}

/// Version reported by `doctor` and stamped into the app bundle.
public enum WispritVersion {
    public static let string = "2.0.0-dev"
}
