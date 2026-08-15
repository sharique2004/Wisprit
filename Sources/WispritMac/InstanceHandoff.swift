#if os(macOS)
import CoreFoundation
import CryptoKit
import Foundation
import WispritKit

/// Second-launch handoff — "open Wisprit while Wisprit is running" must show the
/// window, not an error.
///
/// WHY THIS EXISTS. `SingleInstanceLock` is a `flock`: the second process loses
/// it and used to log "another Wisprit instance is already running", toast
/// "Another copy is already running.", and exit. That is the right refusal for
/// the bug it was written against (two event taps, every release pasted twice)
/// and the wrong *answer* to the user, who asked to see the app.
///
/// The reopen path (`applicationShouldHandleReopen`) already covers the common
/// case: opening the SAME registered bundle delivers a reopen and no second
/// process is spawned. A second process appears only when LaunchServices thinks
/// this is a different app — two copies at different paths (`./dist/Wisprit.app`
/// and `/Applications/Wisprit.app` both exist on any dev machine, see
/// `scripts/build_app.sh --install`), a CLI-exec'd instance, or `open -n`. That
/// is exactly the case reopen cannot cover, and the one this file covers.
///
/// WHY CFMessagePort. No URL scheme exists (neither Info.plist generator
/// declares `CFBundleURLTypes`), and adding one means touching two generators
/// plus Apple-event plumbing. `DistributedNotificationCenter` posts without an
/// acknowledgement — and the acknowledgement is the whole point: it is what
/// distinguishes "a live Wisprit took the request" from "something foreign holds
/// the lock" (the Python-era `wisprit/app.py` shares this lock file by design,
/// and must NEVER be handed a window request). CFMessagePort is also the
/// codebase's established IPC (`WispritIMPortServer`, measured 1.2–2.6 ms round
/// trip). The vocabularies stay separate: the IM wire carries `WispritIMPayload`
/// and must not grow app verbs.
public enum InstanceHandoff {

    /// Wire version. Both halves ship in one binary, but an OLD running instance
    /// meeting a NEW launcher is routine (that is the entire failure mode being
    /// fixed), so the format announces itself and every decoder is total.
    private static let prefix = "v1 show:"
    /// The reply that means "a live Wisprit has the request". Anything else —
    /// including no reply — is not a handoff.
    static let ackData = Data("v1 ok".utf8)

    // MARK: - the wire

    /// What a second launch is asking the live instance to put on screen.
    public enum Request: Equatable, Sendable {
        /// `nil` = "just show me the app", which lands wherever a Dock click
        /// lands (see the mapping note on `AppController.openWindow`).
        case window(WispritWindowModel.Tab?)
        case setupGuide

        var encoded: Data {
            switch self {
            case .window(nil): return Data((InstanceHandoff.prefix + "default").utf8)
            case .window(let tab?): return Data((InstanceHandoff.prefix + tab.rawValue).utf8)
            case .setupGuide: return Data((InstanceHandoff.prefix + "guide").utf8)
            }
        }

        /// Total by construction: any byte string that is not exactly a v1
        /// request — wrong version, unknown tab, garbage, empty — is `nil`, and
        /// the server answers `nil` (no ack) rather than guessing. A launcher
        /// that gets no ack falls back to the "foreign holder" toast, which is
        /// the honest outcome when we cannot tell what is on the other end.
        init?(decoding data: Data) {
            guard let text = String(data: data, encoding: .utf8),
                  text.hasPrefix(InstanceHandoff.prefix)
            else { return nil }
            switch String(text.dropFirst(InstanceHandoff.prefix.count)) {
            case "default": self = .window(nil)
            case "guide": self = .setupGuide
            case let name:
                guard let tab = WispritWindowModel.Tab(rawValue: name) else { return nil }
                self = .window(tab)
            }
        }
    }

    /// `Wisprit window …`'s verb, as a handoff request. A bare double-click
    /// (`.none`) becomes `.window(nil)` — "show me the app" — which the handler
    /// routes through the same `openWindow()` a Dock click uses, so the two
    /// entry points cannot drift apart.
    static func request(for launch: WispritMacMain.WindowLaunch) -> Request {
        switch launch {
        case .none: return .window(nil)
        case .page(let tab): return .window(tab)
        case .setupGuide: return .setupGuide
        }
    }

    // MARK: - the name

    /// Port name, derived from the state directory.
    ///
    /// WHY THE STATE DIR AND NOT A CONSTANT: `WISPRIT_STATE_DIR` exists so a
    /// throwaway build can run beside the installed app without fighting it —
    /// the single-instance lock already moves with it (see
    /// `WispritMacMain.applyStateDirOverride`). If the port name did not move
    /// too, an overridden instance would answer handoffs meant for the installed
    /// one and open the wrong app's window.
    ///
    /// The hash keeps the name short and free of path characters; 64 bits is far
    /// more than enough to separate a handful of directories on one machine, and
    /// the result is 40 chars — well inside the bootstrap namespace's limit.
    public static func portName(stateDir: URL = WispritPaths.stateDir) -> String {
        let digest = SHA256.hash(data: Data(stateDir.standardizedFileURL.path.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "com.wisprit.app.instance." + hex.prefix(16)
    }

    // MARK: - the decision

    public enum Arbitration: Equatable, Sendable {
        /// We got the lock. Run the app.
        case weArePrimary
        /// A live Wisprit acked the request and is showing itself. Exit 0,
        /// silently — the user asked to see the app and is seeing it.
        case handedOff
        /// Something holds the lock and will not answer: the Python-era Wisprit,
        /// or a pre-handoff build. Only this case still earns the toast.
        case lockedByForeignProcess
    }

    /// The whole second-launch decision, in one place so it can be tested
    /// without spawning an app.
    ///
    /// The retry loop is not belt-and-braces; it covers two real races:
    ///   * a simultaneous launch, where the winner holds the flock but has not
    ///     registered its port yet (the port comes up in `AppController.launch`,
    ///     a beat after the lock);
    ///   * the relaunch helper's window, where the outgoing instance still holds
    ///     the lock and is already tearing its port down.
    /// Each tick re-attempts BOTH, because either can become true first.
    static func arbitrate(lock: SingleInstanceLock,
                          request: Request,
                          client: InstanceHandoffSending,
                          attempts: Int = 10,
                          interval: TimeInterval = 0.2,
                          sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) })
        -> Arbitration
    {
        if lock.acquire() { return .weArePrimary }
        if client.requestShow(request) { return .handedOff }
        for _ in 0..<attempts {
            sleep(interval)
            if lock.acquire() { return .weArePrimary }
            if client.requestShow(request) { return .handedOff }
        }
        return .lockedByForeignProcess
    }
}

// MARK: - client

/// The sending half, as a seam: `arbitrate` is pure decision logic and the tests
/// drive it with a fake rather than a second process.
public protocol InstanceHandoffSending {
    /// True only when a live Wisprit acknowledged the request.
    func requestShow(_ request: InstanceHandoff.Request) -> Bool
}

/// Sends a handoff to the named port. Shaped after `WispritIMRemotePort.send`
/// (cached remote port, 1 s timeouts, invalidate on failure) but with raw `Data`
/// payloads — the IM wire's vocabulary stays the IM's.
public final class InstanceHandoffClient: InstanceHandoffSending, @unchecked Sendable {

    public let name: String
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var port: CFMessagePort?

    public init(name: String, timeout: TimeInterval = 1.0) {
        self.name = name
        self.timeout = timeout
    }

    public func requestShow(_ request: InstanceHandoff.Request) -> Bool {
        lock.lock(); defer { lock.unlock() }
        // No port registered → nil immediately, so a foreign holder costs us
        // nothing but the retry interval (the 1 s timeouts never engage).
        guard let port = resolvePort() else { return false }
        var reply: Unmanaged<CFData>?
        let status = CFMessagePortSendRequest(port, 0, request.encoded as CFData,
                                              timeout, timeout,
                                              CFRunLoopMode.defaultMode.rawValue, &reply)
        guard status == kCFMessagePortSuccess else {
            port_invalidate()
            return false
        }
        guard let data = reply?.takeRetainedValue() as Data? else { return false }
        return data == InstanceHandoff.ackData
    }

    /// Caller holds `lock`.
    private func port_invalidate() { port = nil }

    /// Caller holds `lock`.
    private func resolvePort() -> CFMessagePort? {
        if let port, CFMessagePortIsValid(port) { return port }
        port = CFMessagePortCreateRemote(nil, name as CFString)
        return port
    }
}

// MARK: - server

/// The listening half, owned by the live instance for its whole run.
///
/// Shaped after `WispritIMPortServer`: `shouldFreeInfo` catches the
/// same-process name collision, the source lives on `.commonModes` so a modal
/// panel cannot make the app stop answering, and a C trampoline stands in for
/// the capturing Swift closure `CFMessagePortCreateLocal` will not take.
public final class InstanceHandoffServer {

    /// Runs on whichever run loop `start(on:)` was given — the main one in the
    /// app. Returning means the request has been carried out, which is what
    /// makes the ack mean "handled" rather than "received".
    public typealias Handler = (InstanceHandoff.Request) -> Void

    public let name: String
    private let handler: Handler
    private var port: CFMessagePort?
    private var source: CFRunLoopSource?
    /// Remembered so `stop()` unregisters from the loop it actually joined.
    private var runLoop: CFRunLoop?

    public init(name: String, handler: @escaping Handler) {
        self.name = name
        self.handler = handler
    }

    /// False when the name is already taken — meaning handoffs will not be
    /// answered and second launches fall back to the toast. Worth logging, not
    /// worth refusing to start the app over.
    @discardableResult
    public func start(on runLoop: CFRunLoop = CFRunLoopGetMain()) -> Bool {
        guard port == nil else { return true }
        var context = CFMessagePortContext(version: 0,
                                           info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        var shouldFreeInfo: DarwinBoolean = false
        guard let created = CFMessagePortCreateLocal(nil, name as CFString,
                                                     wispritInstanceHandoffCallback, &context,
                                                     &shouldFreeInfo),
              !shouldFreeInfo.boolValue
        else {
            return false
        }
        guard let source = CFMessagePortCreateRunLoopSource(nil, created, 0) else {
            CFMessagePortInvalidate(created)
            return false
        }
        CFRunLoopAddSource(runLoop, source, .commonModes)
        self.port = created
        self.source = source
        self.runLoop = runLoop
        return true
    }

    public func stop() {
        if let source, let runLoop {
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
        }
        source = nil
        runLoop = nil
        if let port {
            CFMessagePortInvalidate(port)
            self.port = nil
        }
    }

    deinit { stop() }

    fileprivate func handle(_ data: Data?) -> Data? {
        guard let data, let request = InstanceHandoff.Request(decoding: data) else { return nil }
        handler(request)
        return InstanceHandoff.ackData
    }
}

/// C-compatible trampoline — `CFMessagePortCreateLocal` takes a function
/// pointer, which a capturing Swift closure cannot be.
private func wispritInstanceHandoffCallback(_ port: CFMessagePort?,
                                            _ messageID: Int32,
                                            _ data: CFData?,
                                            _ info: UnsafeMutableRawPointer?) -> Unmanaged<CFData>? {
    guard let info else { return nil }
    let server = Unmanaged<InstanceHandoffServer>.fromOpaque(info).takeUnretainedValue()
    guard let reply = server.handle(data as Data?) else { return nil }
    return Unmanaged.passRetained(reply as CFData)
}
#endif
