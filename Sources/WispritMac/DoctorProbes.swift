#if os(macOS)
import Foundation
import WispritContext
import WispritDictionary
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

        // Read here rather than in the Live Typing half: the window's base
        // probe skips that half, and the context row must not vanish with it.
        facts.contextAwarenessEnabled = !ContextEnvironment.isDisabled
            && ContextSettings.isEnabled(Settings.load())

        facts.configPath = WispritPaths.configPath.path
        facts.configValid = isValidJSON(WispritPaths.configPath)
        facts.dictionaryPath = WispritPaths.dictionaryPath.path
        facts.dictionaryValid = isValidJSON(WispritPaths.dictionaryPath)
        // The same catalog the Settings ▸ Data page renders (R17): stat every
        // class the stores own, so the terminal can see the inventory too.
        facts.dataStores = DataInventory.status()
        facts.parakeetModelsPath = parakeetModelsDir.path
        facts.parakeetModels = parakeetModelsState(at: parakeetModelsDir)

        // Its own store rather than the app's: `gather` is also the CLI's, and
        // this is the only probe in here that reads a file the user edits. The
        // window re-runs it every few seconds, which costs one dictionary load
        // and one metrics.log read off the main thread — measured in
        // milliseconds on the live 139-term file, and never on the paste path.
        facts.metrics = recentMetrics()
        facts.learnedTerms = LearnedTermCleanup.audit(
            entries: DictionaryStore(path: WispritPaths.dictionaryPath).learnedEntries())
        facts.osBuild = liveOSBuild()
        if let baseline = repoFile(evalBaselineRelativePath) {
            facts.evalBaselinePath = baseline.path
            facts.evalBaselineOSBuild = (try? String(contentsOf: baseline, encoding: .utf8))
                .flatMap(osBuild(inBaselineJSON:))
        }

        return facts
    }

    // MARK: - accuracy & hygiene

    /// The window the "Dictation health" row reads. Two weeks is what makes the
    /// row about NOW: metrics.log spans three eras, and an all-time rate mixes
    /// in failures that were fixed months ago.
    static var dictationHealthWindow: MetricsWindow { MetricsWindow(days: 14) }

    static func recentMetrics() -> MetricsSummary {
        MetricsSummary.summarize(MetricsWriter().readAll(),
                                 window: dictationHealthWindow,
                                 now: Date().timeIntervalSince1970)
    }

    static var evalBaselineRelativePath: String { "docs/eval/BASELINE.json" }

    // MARK: - Parakeet models (path convention, NO WispritParakeet import)

    /// `ParakeetModelStore.productionModelsDir`, restated by path because this
    /// executable deliberately does not link WispritParakeet (the transitive
    /// binary xcframework must not ride every install while the feature is
    /// human-corpus-gated). The convention lives on `ParakeetManifest` in that
    /// target; a drift here shows up as a permanently-"partial" doctor row on
    /// a machine with a verified download, which the model-store tests pin
    /// against by asserting both spellings.
    static var parakeetModelsDir: URL {
        WispritPaths.stateDir
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("parakeet", isDirectory: true)
    }

    /// Marker written by `ParakeetModelStore.download` after a full SHA pass.
    static let parakeetMarkerFileName = "verified.json"

    /// Path check only — the store re-hashes 586 MB when IT verifies; a doctor
    /// row the window refreshes every few seconds trusts the marker instead:
    /// empty/absent dir → not_downloaded; content without a valid marker →
    /// partial (a torn download, or files changed since verification); valid
    /// marker → verified.
    static func parakeetModelsState(at dir: URL) -> String {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        guard !contents.isEmpty else { return "not_downloaded" }
        let marker = dir.appendingPathComponent(parakeetMarkerFileName)
        guard let data = try? Data(contentsOf: marker),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["manifest_version"] is Int else { return "partial" }
        return "verified"
    }

    /// A repo-relative file, when this build can see the checkout it came from.
    ///
    /// There is no repo-file idiom in doctor because until now no check needed
    /// one, and the reason is worth keeping in mind: a shipped Wisprit.app has
    /// no repo, so every caller must treat nil as ordinary. Walk up from the
    /// executable (`.build/debug/Wisprit` in a checkout) and then from the
    /// working directory, which is what `swift run` from the repo root gives.
    static func repoFile(_ relativePath: String, levels: Int = 8) -> URL? {
        var roots: [URL] = []
        if let executable = Bundle.main.executableURL {
            roots.append(executable.deletingLastPathComponent())
        }
        roots.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath))

        for root in roots {
            var directory = root.standardizedFileURL
            for _ in 0...levels {
                let candidate = directory.appendingPathComponent(relativePath)
                if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
                let parent = directory.deletingLastPathComponent().standardizedFileURL
                if parent.path == directory.path { break }
                directory = parent
            }
        }
        return nil
    }

    /// The `os_build` a baseline records, found by key rather than decoded.
    ///
    /// `Baseline` is the scoreboard's type and its shape is the scoreboard's to
    /// change; a doctor row that stopped compiling — or worse, stopped
    /// reporting — because a field moved would be a bad trade for a warn-only
    /// check. So the file is searched for the key wherever it sits, and a
    /// baseline that records none simply cannot be judged stale.
    static func osBuild(inBaselineJSON text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data,
                                                           options: [.fragmentsAllowed])
        else { return nil }
        return firstOSBuild(in: root)
    }

    static var osBuildKeys: [String] { ["os_build", "osBuild"] }

    static func firstOSBuild(in value: Any) -> String? {
        if let object = value as? [String: Any] {
            for key in osBuildKeys {
                if let found = object[key] as? String, !found.isEmpty { return found }
            }
            // Sorted so a nested hit is the same one on every run — an
            // unordered walk would make the row flap between two builds.
            for key in object.keys.sorted() {
                if let value = object[key], let found = firstOSBuild(in: value) { return found }
            }
        }
        if let array = value as? [Any] {
            for item in array {
                if let found = firstOSBuild(in: item) { return found }
            }
        }
        return nil
    }

    /// The token `sw_vers -buildVersion` prints. Read from `ProcessInfo` rather
    /// than by spawning `sw_vers`: the window re-runs this probe every few
    /// seconds, and a subprocess per refresh for one string is not a trade
    /// worth making.
    static func liveOSBuild() -> String {
        buildToken(inOSVersionString: ProcessInfo.processInfo.operatingSystemVersionString) ?? ""
    }

    /// "Version 26.0 (Build 25A123)" → "25A123".
    static func buildToken(inOSVersionString text: String) -> String? {
        guard let marker = text.range(of: "Build ") else { return nil }
        let token = text[marker.upperBound...].prefix { $0 != ")" }
            .trimmingCharacters(in: .whitespaces)
        return token.isEmpty ? nil : token
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
