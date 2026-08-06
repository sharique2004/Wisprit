#if os(macOS)
import Foundation
import WispritEngine
import WispritIMProtocol
import WispritKit
import WispritPersistence
import WispritRefine

/// The system side of `wisprit doctor`: run every real probe, fill a
/// `DoctorFacts`, hand it to the pure report builder.
///
/// Deliberately thin — every judgement (mark, remedy text, required-ness, exit
/// code) lives in `Doctor.report(from:)`, which is what the tests cover.
public extension Doctor {

    /// `liveTyping: false` skips the Live Typing half. The window needs that:
    /// once an app has an event loop, `TISCreateInputSourceList` asserts the
    /// main queue and traps anywhere else, so the window runs this probe off the
    /// main actor and calls `gatheringLiveTyping` afterwards, which puts each
    /// half on the thread it needs. The CLI keeps the default and is unaffected —
    /// HIToolbox has no such queue to assert against in a process with no
    /// NSApplication.
    static func gather(locale: String = "en-US", liveTyping: Bool = true) async -> DoctorFacts {
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

        if liveTyping { gatherLiveTyping(into: &facts) }

        facts.configPath = WispritPaths.configPath.path
        facts.configValid = isValidJSON(WispritPaths.configPath)
        facts.dictionaryPath = WispritPaths.dictionaryPath.path
        facts.dictionaryValid = isValidJSON(WispritPaths.dictionaryPath)

        return facts
    }

    /// Read-only inspection of the input-source database plus one liveness ping.
    ///
    /// Nothing here registers, enables, selects or deselects anything: doctor is
    /// a diagnostic, and changing the user's input configuration from a
    /// diagnostic would be indefensible. The ping is inert by construction —
    /// `WispritIMClient.ping` uses generation 0, which the gate can never open a
    /// session for.
    static func gatherLiveTyping(into facts: inout DoctorFacts) {
        let sources = gatherInputSources(into: &facts)
        gatherBridge(into: &facts, after: sources)
    }

    /// The whole Live Typing probe from a GUI process, each half on the thread
    /// it needs, in the only order that works.
    ///
    /// One entry point rather than two calls the caller has to sequence itself:
    /// the input-source read must be on the main thread (see
    /// `gatherInputSources`) while the bridge ping must *not* be, because its
    /// one-second ceiling would freeze the pill mid-utterance. Getting either
    /// half wrong is silent — a checklist that reports Live Typing unreachable,
    /// or a stalled main thread — so neither is left to a comment.
    static func gatheringLiveTyping(_ base: DoctorFacts) async -> DoctorFacts {
        var probed = await MainActor.run { () -> (DoctorFacts, LiveTypingSources) in
            var onMain = base
            let sources = gatherInputSources(into: &onMain)
            return (onMain, sources)
        }
        gatherBridge(into: &probed.0, after: probed.1)
        return probed.0
    }

    /// What the input-source half found, and the only way to ask for the bridge
    /// half.
    ///
    /// The ping is meaningless before the input-source read (an unregistered
    /// input method is never pinged), and that used to be a doc comment a caller
    /// could ignore — silently producing a checklist that reported Live Typing
    /// unreachable. Now the ordering is in the types: nothing but
    /// `gatherInputSources` can make one of these.
    struct LiveTypingSources: Sendable {
        let registered: Bool
        fileprivate init(registered: Bool) { self.registered = registered }
    }

    /// The input-source database half. **Main thread only in a GUI process** —
    /// `TISCreateInputSourceList` runs `dispatch_assert_queue(main)` under
    /// HIToolbox once an event loop exists, and traps on any other thread.
    /// Cheap (one list copy plus a file read), so blocking the main thread on it
    /// costs nothing.
    @discardableResult
    static func gatherInputSources(into facts: inout DoctorFacts) -> LiveTypingSources {
        facts.liveTypingEnabled = LiveTypingSettings.isEnabled(Settings.load())

        let staged = IMStagedBundle.url
        facts.imStaged = staged != nil
        facts.imStagedPath = staged?.path
            ?? Bundle.main.bundleURL.appendingPathComponent(IMStagedBundle.relativePath).path

        facts.imStatus = InputSourceProbe.status(
            stagedVersion: IMStagedBundle.version(at: staged))

        if let plist = InputSourceProbe.installedInfoPlist() {
            facts.imPlistViolations = IMBundleTemplate.violations(in: plist)
        }

        return LiveTypingSources(registered: facts.imStatus.registered)
    }

    /// The liveness half: one round trip with a 1 s ceiling. Thread-agnostic,
    /// and deliberately kept OFF the main thread by the window — a second of
    /// main-thread stall would freeze the pill mid-utterance.
    ///
    /// Takes the input-source result rather than re-reading `facts`, so the
    /// order dependency is a compiler error instead of a quiet wrong answer.
    static func gatherBridge(into facts: inout DoctorFacts, after sources: LiveTypingSources) {
        guard !LiveTypingEnvironment.isDisabled, sources.registered else { return }
        let client = WispritIMClient(onEvent: { _ in })
        facts.imReachable = client.ping(timeout: 1.0) != nil
        client.invalidate()
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
