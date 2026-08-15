import Foundation
import WispritIMProtocol

/// Hand-run checks for the things unit tests must never do: change the user's
/// input sources, and write into whatever window happens to be focused.
///
/// Nothing here runs during an ordinary `swift test`. Everything is gated on
/// `WISPRIT_MANUAL_IM=1`, and the one function that mutates system state needs a
/// second, separate opt-in.
///
///     # 1. Build the bundle (visible in the Input menu so you can pick it):
///     ./scripts/build_im.sh --visible
///
///     # 2. Look, change nothing:
///     WISPRIT_MANUAL_IM=1 swift test --filter WispritIMTests.ManualIMTests/testReport \
///         --scratch-path /tmp/wisprit-build-WispritIM
///
///     # 3. Install + register (this writes to ~/Library/Input Methods):
///     WISPRIT_MANUAL_IM=1 WISPRIT_MANUAL_IM_REGISTER=1 \
///         swift test --filter WispritIMTests.ManualIMTests/testInstallAndRegister \
///         --scratch-path /tmp/wisprit-build-WispritIM
///
///     # 4. Enable it BY HAND: System Settings ▸ Keyboard ▸ Input Sources ▸ Edit ▸ +
///     #    (or approve the "wants to activate the third-party input method" dialog).
///     #    Then open TextEdit, click in the document, and pick "Wisprit Dictation"
///     #    from the Input menu in the menu bar.
///
///     # 5. Stream into that field:
///     WISPRIT_MANUAL_IM=1 swift test --filter WispritIMTests.ManualIMTests/testLoopback \
///         --scratch-path /tmp/wisprit-build-WispritIM
///
/// Step 4 is deliberately manual. `TISEnableInputSource` and
/// `TISSelectInputSource` are changes to the user's system input configuration;
/// this code never calls them.
public enum ManualIMSmoke {
    public static let envVar = "WISPRIT_MANUAL_IM"
    public static let registerEnvVar = "WISPRIT_MANUAL_IM_REGISTER"

    public static var isEnabled: Bool {
        ProcessInfo.processInfo.environment[envVar] == "1"
    }

    public static var registrationAllowed: Bool {
        isEnabled && ProcessInfo.processInfo.environment[registerEnvVar] == "1"
    }

    #if os(macOS)

    /// Read-only: where the install stands and exactly which calls would fix it.
    /// Makes no calls of its own.
    public static func report(emit: (String) -> Void = { print($0) }) -> InputMethodStatus {
        let layout = IMInstallLayout.user
        let status = InputSourceProbe.status(layout: layout,
                                             stagedVersion: WispritIMEntry.defaultVersion)
        let verdict = IMPreflight.evaluate(status)

        emit("input method    : \(WispritIMNaming.inputSourceID)")
        emit("connection name : \(WispritIMNaming.connectionName)")
        emit("install path    : \(layout.installedBundle.path)")
        emit("bundle present  : \(status.bundleInstalled)")
        emit("registered      : \(status.registered)")
        emit("enabled         : \(status.enabled)")
        emit("selected        : \(status.selected)")
        emit("verdict         : \(verdict)")
        emit("remedy          : \(IMPreflight.remedy(for: verdict, layout: layout))")

        let plan = IMOnboarding.plan(status: status,
                                     stagedBundle: stagedBundle(),
                                     layout: layout)
        if plan.isNoop {
            emit("plan            : nothing to do")
        } else {
            emit("plan            : \(plan.calls.count) call(s) — NOT executed here")
            for call in plan.calls {
                emit("   \(call.promptsUser ? "[prompts you] " : "")\(call.rendered)")
            }
        }

        if let plist = InputSourceProbe.installedInfoPlist(layout: layout) {
            let problems = IMBundleTemplate.violations(in: plist)
            emit("installed plist : \(problems.isEmpty ? "ok" : problems.joined(separator: "; "))")
        }
        return status
    }

    /// Copies the built bundle into `~/Library/Input Methods/` and calls
    /// `TISRegisterInputSource` on it. Requires BOTH env vars — running the manual
    /// suite alone must never touch the input-source database.
    ///
    /// Still does not enable or select: those stay the user's, in System Settings.
    @discardableResult
    public static func installAndRegister(emit: (String) -> Void = { print($0) }) -> Bool {
        guard registrationAllowed else {
            emit("refusing: set \(envVar)=1 AND \(registerEnvVar)=1 to install the input method")
            return false
        }
        let layout = IMInstallLayout.user
        let source = stagedBundle()
        guard FileManager.default.fileExists(atPath: source.path) else {
            emit("no bundle at \(source.path) — run ./scripts/build_im.sh --visible first")
            return false
        }

        do {
            try FileManager.default.createDirectory(at: layout.inputMethodsDirectory,
                                                    withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: layout.installedBundle.path) {
                try FileManager.default.removeItem(at: layout.installedBundle)
            }
            try FileManager.default.copyItem(at: source, to: layout.installedBundle)
            emit("installed \(layout.installedBundle.path)")
        } catch {
            emit("install failed: \(error)")
            return false
        }

        let status = registerInputSource(at: layout.installedBundle)
        emit("TISRegisterInputSource → \(status)")
        emit("")
        emit("Now enable it BY HAND:")
        emit("  System Settings ▸ Keyboard ▸ Input Sources ▸ Edit… ▸ +  →  Wisprit Dictation")
        emit("Then click in a TextEdit document and choose it from the Input menu.")
        return status == 0
    }

    /// Drives one full session over the port into whatever field is focused: a live
    /// marked tail, two committed chunks, a retroactive correction, and a clean
    /// end. This is the loop the user watches happen in TextEdit.
    @discardableResult
    public static func loopback(emit: (String) -> Void = { print($0) }) -> Bool {
        guard isEnabled else {
            emit("refusing: set \(envVar)=1")
            return false
        }

        let events = EventLog()
        let client = WispritIMClient { event in events.append(event) }
        client.startListeningForEvents()
        defer { client.invalidate() }

        guard let pong = client.ping(timeout: 3.0) else {
            emit("no answer on \(WispritIMNaming.machServiceName).")
            emit("The input method is not running. Enable it in System Settings, then")
            emit("click in a text field and select \"Wisprit Dictation\" from the Input menu.")
            return false
        }
        emit("connected: wire v\(pong.wireVersion), round trip "
             + "\(String(format: "%.2f", pong.roundTrip * 1000)) ms")

        emit("\nFocus a TextEdit window and click in the document. Streaming in:")
        for i in [3, 2, 1] {
            emit("  \(i)...")
            Thread.sleep(forTimeInterval: 1.0)
        }

        let generation = IMGenerationCounter().next()
        let script: [(String, IMCommandMessage)] = [
            ("begin", .beginSession(generation: generation)),
            ("partial 'the qui'", .updateVolatile(generation: generation, tail: "the qui")),
            ("partial 'the quick bro'", .updateVolatile(generation: generation, tail: "the quick bro")),
            ("commit 'The quick brown fox '", .commitFinal(generation: generation, text: "The quick brown fox ")),
            ("partial 'jumps ov'", .updateVolatile(generation: generation, tail: "jumps ov")),
            ("commit 'jumped over Sharik. '", .commitFinal(generation: generation, text: "jumped over Sharik. ")),
            ("retro-edit Sharik → Sharique",
             .applyEdit(generation: generation, replace: "Sharik", with: "Sharique")),
            // The anchored case, which is the one you have to WATCH to believe:
            // "Sharik" now appears twice in the run, and the offset says which.
            // "The quick brown fox jumped over Sharique. " is 42 UTF-16 units,
            // so the first of the two below sits at 42 and the second at 54.
            ("commit 'Sharik one, Sharik two. '",
             .commitFinal(generation: generation, text: "Sharik one, Sharik two. ")),
            ("retro-edit the FIRST Sharik (anchor 42)",
             .applyEdit(generation: generation, replace: "Sharik", with: "Sharique",
                        utf16LocationInCommitted: 42)),
            ("end (commit)", .endSession(generation: generation, commit: true)),
        ]

        for (label, message) in script {
            let started = Date()
            let event = client.sendAndWait(message, timeout: 3.0)
            let ms = Date().timeIntervalSince(started) * 1000
            let reply = event.map { "\($0.event)" } ?? "—"
            emit(String(format: "  %-32@ %6.1f ms  %@", label as NSString, ms, reply as NSString))
            Thread.sleep(forTimeInterval: 0.15)   // ~7 Hz, a realistic partial cadence
        }

        emit("\nEvents received:")
        for event in events.all { emit("  \(event.event)") }
        emit("\nCheck the TextEdit window: it should read")
        emit("  \"The quick brown fox jumped over Sharique. Sharique one, Sharik two. \"")
        emit("Note WHICH of the last two changed: the anchored edit fixed the FIRST")
        emit("\"Sharik\" and left the second alone. Before the anchor existed the wire")
        emit("could only say \"the last one\", and this line read \"Sharik one, Sharique two.\"")
        emit("⌘Z should still remove it a chunk at a time, not a letter at a time.")
        return true
    }

    /// `Wisprit.app/Contents/Library/InputMethods/WispritIM.app` in a real
    /// install; `dist/WispritIM.app` in the repo during development.
    public static func stagedBundle() -> URL {
        if let override = ProcessInfo.processInfo.environment["WISPRIT_IM_BUNDLE"] {
            return URL(fileURLWithPath: override)
        }
        let repo = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        return repo.appendingPathComponent("dist/WispritIM.app")
    }

    private static func registerInputSource(at url: URL) -> OSStatus {
        // The one TIS call this file makes, and only with both env vars set.
        // Registration alone is inert: it makes the source visible to the system
        // without enabling or selecting it.
        registerInputSourceImpl(url)
    }

    private final class EventLog: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [IMEventMessage] = []
        func append(_ event: IMEventMessage) {
            lock.lock(); defer { lock.unlock() }
            events.append(event)
        }
        var all: [IMEventMessage] {
            lock.lock(); defer { lock.unlock() }
            return events
        }
    }

    #endif
}

#if os(macOS)
import Carbon

private func registerInputSourceImpl(_ url: URL) -> OSStatus {
    TISRegisterInputSource(url as CFURL)
}
#endif
