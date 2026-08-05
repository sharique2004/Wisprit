#if os(macOS)
import Foundation
import WispritEngine
import WispritKit
import WispritRefine

/// The system side of `wisprit doctor`: run every real probe, fill a
/// `DoctorFacts`, hand it to the pure report builder.
///
/// Deliberately thin — every judgement (mark, remedy text, required-ness, exit
/// code) lives in `Doctor.report(from:)`, which is what the tests cover.
public extension Doctor {

    static func gather(locale: String = "en-US") async -> DoctorFacts {
        var facts = DoctorFacts()
        facts.executablePath = Bundle.main.executableURL?.path
            ?? ProcessInfo.processInfo.arguments.first
            ?? "(unknown)"

        facts.accessibility = Permissions.accessibility()
        facts.inputMonitoring = Permissions.inputMonitoring().rawValue
        facts.postEventAccess = Permissions.postEventAccess()
        facts.microphone = Permissions.microphone().rawValue
        facts.secureInputActive = Permissions.secureInput().active

        let preflight = await AsrDoctor.check(locale: locale)
        facts.requestedLocale = locale
        facts.speechOK = preflight.ok
        facts.speechDetail = preflight.detail
        facts.speechFix = preflight.fix
        facts.transcriberAvailable = preflight.transcriberAvailable
        facts.installedLocales = preflight.installedLocales
        facts.assetStatus = preflight.assetStatus

        let availability = await refineAvailability()
        facts.aiAvailable = availability.available
        facts.aiReason = availability.reason

        facts.configPath = WispritPaths.configPath.path
        facts.configValid = isValidJSON(WispritPaths.configPath)
        facts.dictionaryPath = WispritPaths.dictionaryPath.path
        facts.dictionaryValid = isValidJSON(WispritPaths.dictionaryPath)

        return facts
    }

    /// Probe FoundationModels directly. `Refiner` would work too, but it starts
    /// a retry loop the CLI has no use for.
    static func refineAvailability() async -> RefineAvailability {
        #if canImport(FoundationModels)
        return await SystemModelGenerator().probe()
        #else
        return RefineAvailability(available: false,
                                  reason: "FoundationModels not available in this build")
        #endif
    }

    static func isValidJSON(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        return (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil
    }

    /// `doctor.run()` — print the checklist, return the process exit code.
    static func run(locale: String = "en-US") async -> Int32 {
        let report = Doctor.report(from: await gather(locale: locale))
        FileHandle.standardOutput.write(Data(report.rendered().utf8))
        return report.isReady ? 0 : 1
    }
}
#endif
