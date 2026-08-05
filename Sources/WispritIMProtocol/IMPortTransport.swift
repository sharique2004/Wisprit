import Foundation

#if os(macOS)

/// The pipe between `Wisprit.app` and `WispritIM.app`.
///
/// CONTRACT-DEVIATION: the plan said `NSXPCConnection`. It cannot work here, and
/// this was settled by measurement on this machine rather than by argument:
///
///   * `NSXPCListener(machServiceName:)` refuses to activate in an ordinary app
///     bundle — `listener failed to activate: xpc_error=[1: Operation not
///     permitted]` — and it refuses with the App Sandbox *disabled* too. A Mach
///     service name has to be declared to launchd (a LaunchAgent's `MachServices`
///     key or an XPCService bundle); an input method installed into
///     `~/Library/Input Methods` is neither.
///   * Naming the listener `<bundle id>_Connection` fails differently and more
///     confusingly: `xpc_error=[37: Operation already in progress]`, because
///     `IMKServer` has already claimed that exact name for itself.
///   * `NSXPCListener.anonymous()` is no way out: an `NSXPCListenerEndpoint`
///     carries a Mach send right and must travel over an existing XPC connection.
///     There is no first connection to send it over.
///
/// `CFMessagePort` registers an arbitrary global name from a plain process (the
/// same legacy bootstrap path `IMKServer` itself uses) and measured 1.2–2.6 ms
/// round trip locally — comfortably inside a 3–10 Hz partial cadence. The wire
/// types, the versioning and the generation counter are unchanged: they were
/// always defined on the payload rather than on method signatures, precisely so
/// the transport could be swapped without touching the contract.

// MARK: - Server

/// A named local port other processes can send payloads to.
public final class WispritIMPortServer {

    /// Return a payload to reply with, or nil for "no reply".
    public typealias Handler = (WispritIMPayload) -> WispritIMPayload?

    public let name: String
    private let handler: Handler
    private var port: CFMessagePort?
    private var source: CFRunLoopSource?

    public init(name: String, handler: @escaping Handler) {
        self.name = name
        self.handler = handler
    }

    /// Registers the name and starts listening on `runLoop`.
    ///
    /// Returns false when the name is already taken — which, for the input
    /// method, means another copy is already serving and this one should get out
    /// of the way rather than fight over the field.
    @discardableResult
    public func start(on runLoop: CFRunLoop = CFRunLoopGetMain()) -> Bool {
        guard port == nil else { return true }
        var context = CFMessagePortContext(version: 0,
                                           info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        // `shouldFreeInfo == true` means this process already owns a port with
        // that name and CFMessagePort handed back the existing one rather than
        // creating ours. Across processes the name being taken returns nil
        // instead. Either way: someone else is serving, so stand down.
        var shouldFreeInfo: DarwinBoolean = false
        guard let created = CFMessagePortCreateLocal(nil, name as CFString,
                                                     wispritIMPortCallback, &context,
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
        return true
    }

    public func stop() {
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            self.source = nil
        }
        if let port {
            CFMessagePortInvalidate(port)
            self.port = nil
        }
    }

    deinit { stop() }

    fileprivate func handle(_ data: Data?) -> Data? {
        guard let data,
              let payload = WispritIMPayload(archived: data),
              let response = handler(payload)
        else { return nil }
        return response.archived()
    }
}

/// C-compatible trampoline: `CFMessagePortCreateLocal` takes a function pointer,
/// which a Swift closure that captures anything cannot be.
private func wispritIMPortCallback(_ port: CFMessagePort?,
                                   _ messageID: Int32,
                                   _ data: CFData?,
                                   _ info: UnsafeMutableRawPointer?) -> Unmanaged<CFData>? {
    guard let info else { return nil }
    let server = Unmanaged<WispritIMPortServer>.fromOpaque(info).takeUnretainedValue()
    guard let reply = server.handle(data as Data?) else { return nil }
    return Unmanaged.passRetained(reply as CFData)
}

// MARK: - Client

/// The sending half. Every failure mode — service absent, port gone stale,
/// timeout — comes back as `nil` so the caller can drop to the next tier of the
/// insertion ladder without ever throwing or blocking the dictation path.
public final class WispritIMRemotePort: @unchecked Sendable {

    public let name: String
    private let lock = NSLock()
    private var port: CFMessagePort?

    public init(name: String) {
        self.name = name
    }

    /// True when something is listening right now. Cheap; safe to poll.
    public var isAvailable: Bool {
        lock.lock(); defer { lock.unlock() }
        return resolvePort() != nil
    }

    /// Send and wait for a reply. `nil` means "the input method did not answer" —
    /// treat it exactly like "not installed".
    public func send(_ payload: WispritIMPayload, timeout: TimeInterval = 1.0) -> WispritIMPayload? {
        lock.lock(); defer { lock.unlock() }
        guard let port = resolvePort(), let data = payload.archived() else { return nil }
        var reply: Unmanaged<CFData>?
        let status = CFMessagePortSendRequest(port, 0, data as CFData, timeout, timeout,
                                              CFRunLoopMode.defaultMode.rawValue, &reply)
        guard status == kCFMessagePortSuccess else {
            invalidate()
            return nil
        }
        guard let replyData = reply?.takeRetainedValue() as Data?, !replyData.isEmpty else { return nil }
        return WispritIMPayload(archived: replyData)
    }

    /// Fire and forget. This is what a live partial uses: the reply is never
    /// interesting and the utterance must not wait on one.
    @discardableResult
    public func post(_ payload: WispritIMPayload, timeout: TimeInterval = 0.25) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let port = resolvePort(), let data = payload.archived() else { return false }
        let status = CFMessagePortSendRequest(port, 0, data as CFData, timeout, 0, nil, nil)
        guard status == kCFMessagePortSuccess else {
            invalidate()
            return false
        }
        return true
    }

    public func invalidate() {
        port = nil
    }

    /// Caller holds `lock`.
    private func resolvePort() -> CFMessagePort? {
        if let port, CFMessagePortIsValid(port) { return port }
        port = CFMessagePortCreateRemote(nil, name as CFString)
        return port
    }
}
#endif
