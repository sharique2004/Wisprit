#if os(macOS)
import Carbon
import Foundation
import WispritIMProtocol
import WispritKit

/// The only two files in the app that touch the user's Text Input Sources.
///
///  * `SystemLiveTypingPeer` — per-session `TISSelectInputSource` /
///    `TISDeselectInputSource`. Silent, prompt-free, and legal for a palette
///    source ("zero or more of these can be selected", TextInputSources.h).
///  * `InputMethodInstaller` — the onboarding path: copy the staged bundle into
///    `~/Library/Input Methods`, `TISRegisterInputSource`, then
///    `TISEnableInputSource`, which is the one call that raises the system's
///    "<App> wants to activate the third-party input method" dialog. It runs
///    only from the "Enable Live Typing…" menu item, with the user watching.
///
/// Both honour `WISPRIT_NO_IM=1` as a hard kill switch, so a machine can be told
/// to leave its input sources alone no matter what the settings say.

public enum LiveTypingEnvironment {
    /// Set `WISPRIT_NO_IM=1` to disable every input-source call in this process.
    public static var isDisabled: Bool {
        let value = ProcessInfo.processInfo.environment["WISPRIT_NO_IM"] ?? ""
        return value == "1" || value.lowercased() == "true"
    }
}

/// Where `WispritIM.app` rides inside `Wisprit.app`.
///
/// Research 2.4.5: everything ships in-bundle; onboarding *copies* it out to
/// `~/Library/Input Methods` because `TISRegisterInputSource` accepts no other
/// location. `scripts/build_app.sh` puts it here.
public enum IMStagedBundle {
    public static let relativePath = IMStagedBundleLayout.relativePath

    /// Inside the assembled app bundle. When running from a bare SPM build there
    /// is no bundle, so this also looks next to the executable — which is what
    /// makes `Wisprit doctor` useful straight out of `swift build`.
    public static var url: URL? {
        var candidates: [URL] = []
        let bundle = Bundle.main.bundleURL
        if bundle.pathExtension == "app" {
            candidates.append(bundle.appendingPathComponent(relativePath))
        }
        if let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            let dir = executable.deletingLastPathComponent()
            candidates.append(dir.appendingPathComponent("WispritIM.app"))
            candidates.append(dir.appendingPathComponent("../Library/InputMethods/WispritIM.app")
                .standardizedFileURL)
        }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    public static func version(at url: URL?) -> String? {
        guard let url,
              let data = try? Data(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = plist as? [String: Any]
        else { return nil }
        return dict["CFBundleVersion"] as? String
    }
}

// MARK: - Text Input Source calls

enum TIS {
    static func source(withID id: String) -> TISInputSource? {
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue()
            as? [TISInputSource]
        else { return nil }
        return list.first
    }

    @discardableResult
    static func select(_ id: String) -> Bool {
        guard !LiveTypingEnvironment.isDisabled, let source = source(withID: id) else { return false }
        return TISSelectInputSource(source) == noErr
    }

    @discardableResult
    static func deselect(_ id: String) -> Bool {
        guard !LiveTypingEnvironment.isDisabled, let source = source(withID: id) else { return false }
        return TISDeselectInputSource(source) == noErr
    }

    @discardableResult
    static func register(bundleAt url: URL) -> Bool {
        guard !LiveTypingEnvironment.isDisabled else { return false }
        return TISRegisterInputSource(url as CFURL) == noErr
    }

    /// PROMPTS THE USER. Onboarding only.
    @discardableResult
    static func enable(_ id: String) -> Bool {
        guard !LiveTypingEnvironment.isDisabled, let source = source(withID: id) else { return false }
        return TISEnableInputSource(source) == noErr
    }
}

// MARK: - Peer

public final class SystemLiveTypingPeer: LiveTypingPeer, @unchecked Sendable {

    private let log = WLog.logger("live-typing")
    private let client: WispritIMClient
    private let sourceID: String
    private let layout: IMInstallLayout
    private let lock = NSLock()
    private var handler: (@Sendable (IMEventMessage) -> Void)?
    private var listening = false

    public init(sourceID: String = WispritIMNaming.inputSourceID,
                layout: IMInstallLayout = .user) {
        self.sourceID = sourceID
        self.layout = layout
        // The handler is installed later; route through a box so the client can
        // be built once at wiring time.
        let box = EventBox()
        self.client = WispritIMClient(onEvent: { event in box.deliver(event) })
        box.owner = self
    }

    /// Trampoline so `WispritIMClient`'s escaping handler can reach a property
    /// that is set after construction.
    private final class EventBox: @unchecked Sendable {
        weak var owner: SystemLiveTypingPeer?
        func deliver(_ event: IMEventMessage) { owner?.dispatch(event) }
    }

    private func dispatch(_ event: IMEventMessage) {
        lock.lock(); let handler = self.handler; lock.unlock()
        handler?(event)
    }

    public var isReachable: Bool {
        guard !LiveTypingEnvironment.isDisabled else { return false }
        return client.isAvailable
    }

    public func exchange(_ message: IMCommandMessage, timeout: TimeInterval) -> LiveTypingReply {
        guard !LiveTypingEnvironment.isDisabled else { return .unreachable }
        if let event = client.sendAndWait(message, timeout: timeout) { return .event(event) }
        // `sendAndWait` returns nil both for "no event to report" and for "the
        // port is gone". A failed send invalidates the cached port, so asking
        // once more tells the two apart — and getting that wrong is exactly how
        // an utterance would vanish.
        return client.isAvailable ? .acknowledged : .unreachable
    }

    @discardableResult
    public func post(_ message: IMCommandMessage) -> Bool {
        guard !LiveTypingEnvironment.isDisabled else { return false }
        return client.post(message)
    }

    @discardableResult
    public func postRead(_ message: IMReadMessage) -> Bool {
        guard !LiveTypingEnvironment.isDisabled else { return false }
        return client.post(message)
    }

    public func setSnapshotHandler(_ handler: (@Sendable (IMSnapshotMessage) -> Void)?) {
        client.onSnapshot = handler
    }

    @discardableResult
    public func selectInputSource() -> Bool {
        let ok = TIS.select(sourceID)
        if !ok { log.info("could not select \(self.sourceID, privacy: .public)") }
        return ok
    }

    public func deselectInputSource() {
        TIS.deselect(sourceID)
    }

    public func inputMethodStatus() -> InputMethodStatus {
        guard !LiveTypingEnvironment.isDisabled else { return InputMethodStatus() }
        return InputSourceProbe.status(sourceID: sourceID,
                                       layout: layout,
                                       stagedVersion: IMStagedBundle.version(at: IMStagedBundle.url))
    }

    public func startEvents(_ handler: @escaping @Sendable (IMEventMessage) -> Void) {
        lock.lock()
        self.handler = handler
        let alreadyListening = listening
        listening = true
        lock.unlock()
        guard !alreadyListening, !LiveTypingEnvironment.isDisabled else { return }
        client.startListeningForEvents()
    }

    public func stopEvents() {
        lock.lock()
        handler = nil
        let wasListening = listening
        listening = false
        lock.unlock()
        guard wasListening else { return }
        client.invalidate()
    }
}

// MARK: - Onboarding

/// Executes an `IMPlan`. Every call it can make is enumerated in
/// `WispritIMProtocol.TISCall`, and every one is rendered into the log, so a user
/// can read exactly what Wisprit did to their input sources.
public enum InputMethodInstaller {

    public struct Outcome: Sendable, Equatable {
        public var performed: [String]
        public var failed: [String]
        public var message: String
        public var ok: Bool { failed.isEmpty }

        public init(performed: [String] = [], failed: [String] = [], message: String = "") {
            self.performed = performed
            self.failed = failed
            self.message = message
        }
    }

    /// Build the plan for the current machine.
    public static func plan(layout: IMInstallLayout = .user,
                            sourceID: String = WispritIMNaming.inputSourceID) -> IMPlan? {
        guard let staged = IMStagedBundle.url else { return nil }
        let status = InputSourceProbe.status(sourceID: sourceID, layout: layout,
                                             stagedVersion: IMStagedBundle.version(at: staged))
        return IMOnboarding.plan(status: status, stagedBundle: staged,
                                 layout: layout, sourceID: sourceID)
    }

    /// Run a plan. This is the ONLY place `TISRegisterInputSource` and
    /// `TISEnableInputSource` are ever called, and it is reachable only from the
    /// "Enable Live Typing…" menu item.
    @discardableResult
    public static func run(_ plan: IMPlan) -> Outcome {
        let log = WLog.logger("live-typing")
        guard !LiveTypingEnvironment.isDisabled else {
            return Outcome(failed: ["WISPRIT_NO_IM=1"],
                           message: "Live typing is disabled for this process (WISPRIT_NO_IM=1).")
        }
        var outcome = Outcome(message: plan.userMessage ?? "")
        for call in plan.calls {
            log.info("input source: \(call.rendered, privacy: .public)")
            let ok: Bool
            switch call {
            case .installBundle(let from, let to):
                ok = copyBundle(from: from, to: to)
            case .removeInstalledBundle(let at):
                ok = (try? FileManager.default.removeItem(at: at)) != nil
                    || !FileManager.default.fileExists(atPath: at.path)
            case .registerInputSource(let url):
                ok = TIS.register(bundleAt: url)
            case .enableInputSource(let id):
                ok = TIS.enable(id)
            case .selectInputSource(let id):
                ok = TIS.select(id)
            case .deselectInputSource(let id):
                ok = TIS.deselect(id)
            }
            if ok {
                outcome.performed.append(call.rendered)
            } else {
                outcome.failed.append(call.rendered)
                log.error("input source call failed: \(call.rendered, privacy: .public)")
                break   // the remaining steps depend on this one
            }
        }
        return outcome
    }

    static func copyBundle(from: URL, to: URL) -> Bool {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: to.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            if fm.fileExists(atPath: to.path) { try fm.removeItem(at: to) }
            try fm.copyItem(at: from, to: to)
            return true
        } catch {
            WLog.logger("live-typing").error("""
                could not install the input method into \(to.path, privacy: .public)
                """)
            return false
        }
    }
}
#endif
