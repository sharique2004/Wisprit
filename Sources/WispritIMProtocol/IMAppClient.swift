import Foundation

#if os(macOS)

/// The app's half of the contract: send commands to the input method, receive
/// events back.
///
/// It lives here rather than in the app target so both sides of the wire are
/// defined together — port names, payloads and versioning all come from one
/// module, and the app never has to know a transport detail beyond `send(_:)`.
///
/// Failure is normal and cheap: if the input method is not installed, not
/// enabled, or simply not running, every send fails fast (`nil`) and the caller
/// drops to the next tier of the insertion ladder — paste-at-end. Nothing here
/// blocks the dictation path: commands go out on a private serial queue, and
/// live partials are posted without waiting for a reply at all.
public final class WispritIMClient: @unchecked Sendable {

    public typealias EventHandler = @Sendable (IMEventMessage) -> Void
    /// Wire v2 read-backs (`contextSnapshot`, `committedSnapshot`). Nil means
    /// "drop them", which is what a build that consumes no context should do —
    /// and what every build did before v2.
    public typealias SnapshotHandler = @Sendable (IMSnapshotMessage) -> Void

    private let remote: WispritIMRemotePort
    private let events: WispritIMPortServer
    private let queue = DispatchQueue(label: "com.wisprit.im.client")
    private let onEvent: EventHandler
    private let snapshots = SnapshotSink()

    /// Where read-back answers land. Set it before `startListeningForEvents()`.
    ///
    /// Deliberately a property rather than an init parameter: the write path is
    /// wired at startup and must not gain a second required argument, and a
    /// consumer that is switched off (`context_awareness == false`) simply never
    /// sets this, so the snapshots are dropped at the door.
    public var onSnapshot: SnapshotHandler? {
        get { snapshots.handler }
        set { snapshots.handler = newValue }
    }

    public init(portName: String = WispritIMNaming.machServiceName,
                eventPortName: String = WispritIMNaming.eventPortName,
                onEvent: @escaping EventHandler) {
        self.remote = WispritIMRemotePort(name: portName)
        self.onEvent = onEvent
        let handler = onEvent
        let sink = snapshots
        self.events = WispritIMPortServer(name: eventPortName) { payload in
            switch payload.kind {
            case .snapshot:
                if let snapshot = try? payload.snapshot() { sink.deliver(snapshot) }
            default:
                if let event = try? payload.event() { handler(event) }
            }
            return nil
        }
    }

    /// Lock-guarded box, so `onSnapshot` can be set from anywhere while the port
    /// callback reads it on the run loop.
    private final class SnapshotSink: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: SnapshotHandler?

        var handler: SnapshotHandler? {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }

        func deliver(_ snapshot: IMSnapshotMessage) { handler?(snapshot) }
    }

    /// Start listening for unsolicited events (`clientAcquired`, `clientLost`).
    /// Optional: command replies work without it.
    @discardableResult
    public func startListeningForEvents(on runLoop: CFRunLoop = CFRunLoopGetMain()) -> Bool {
        events.start(on: runLoop)
    }

    public func invalidate() {
        events.stop()
        remote.invalidate()
    }

    /// Is the input method process there right now? Cheap enough to check before
    /// each utterance, which is exactly when the answer matters.
    public var isAvailable: Bool { remote.isAvailable }

    // MARK: Sending

    /// Send and wait for the resulting event, off the caller's thread.
    /// `reply(nil)` means "no event" or "could not reach the input method" — the
    /// caller treats both the same way.
    public func send(_ message: IMCommandMessage,
                     timeout: TimeInterval = 1.0,
                     reply: (@Sendable (IMEventMessage?) -> Void)? = nil) {
        guard let payload = try? WispritIMPayload(command: message) else {
            reply?(nil)
            return
        }
        queue.async { [remote] in
            let response = remote.send(payload, timeout: timeout)
            reply?(response.flatMap { try? $0.event() })
        }
    }

    /// Blocking send, for the places that genuinely need the answer before the
    /// next step (an edit result deciding whether to fall back). Never call this
    /// from the main thread while a partial is in flight.
    @discardableResult
    public func sendAndWait(_ message: IMCommandMessage,
                            timeout: TimeInterval = 1.0) -> IMEventMessage? {
        guard let payload = try? WispritIMPayload(command: message) else { return nil }
        return remote.send(payload, timeout: timeout).flatMap { try? $0.event() }
    }

    /// Fire and forget — for live partials, where waiting for an ack would put
    /// the transport on the latency path for no benefit. A dropped partial is
    /// lossless: the next `commitFinal` carries the whole stable text.
    @discardableResult
    public func post(_ message: IMCommandMessage, timeout: TimeInterval = 0.25) -> Bool {
        guard let payload = try? WispritIMPayload(command: message) else { return false }
        return remote.post(payload, timeout: timeout)
    }

    // MARK: Reading (wire v2)

    /// Ask for the bounded window around the cursor. Posted, never awaited: this
    /// is called at key-down, concurrently with starting capture, and the
    /// utterance must not spend a microsecond waiting for it.
    ///
    /// The answer arrives later on `onSnapshot` as `contextSnapshot`, stamped
    /// with `generation` — compare it against the utterance in flight and drop it
    /// if it lost the race. `false` here, or no answer at all, both mean "no
    /// context signal for this utterance": an input method older than wire v2
    /// cannot decode the request and stays silent by construction.
    ///
    /// Ask at key-down. Later in the utterance the window also contains this
    /// session's own provisional tail, which is not context — it is our own guess
    /// coming back to bias the next one.
    @discardableResult
    public func readContext(generation: UInt64, timeout: TimeInterval = 0.25) -> Bool {
        post(.readContext(generation: generation), timeout: timeout)
    }

    /// Ask what the field says now about the run this session committed — the
    /// edit-observation read. Posted after the words have landed (and legal after
    /// `endSession`, which is when the user actually fixes a word).
    ///
    /// The answer arrives on `onSnapshot` as `committedSnapshot`. `.unchanged`
    /// is a zero-edit observation; `.changed` means our text is no longer there;
    /// anything else is not evidence and must not enter a zero-edit rate.
    @discardableResult
    public func readCommitted(generation: UInt64, timeout: TimeInterval = 0.25) -> Bool {
        post(.readCommitted(generation: generation), timeout: timeout)
    }

    /// Fire and forget, read channel. There is no blocking counterpart on
    /// purpose: nothing about a read is worth making the user wait for.
    @discardableResult
    public func post(_ message: IMReadMessage, timeout: TimeInterval = 0.25) -> Bool {
        guard let payload = try? WispritIMPayload(read: message) else { return false }
        return remote.post(payload, timeout: timeout)
    }

    /// Round-trip liveness check, and how the app measures the cold-start tax of
    /// an enabled-but-unselected palette input method: time this call on the
    /// first utterance after the source is selected.
    public func ping(timeout: TimeInterval = 2.0) -> (wireVersion: Int, roundTrip: TimeInterval)? {
        // Generation 0 can never open a session — the gate needs a strictly
        // greater generation than its high-water mark, which starts at 0 — so the
        // ping is inert by construction: it proves the process answers without
        // being able to touch anyone's text.
        guard let payload = try? WispritIMPayload(command: .beginSession(generation: 0)) else {
            return nil
        }
        let started = Date()
        guard let response = remote.send(payload, timeout: timeout) else { return nil }
        return (response.wireVersion, Date().timeIntervalSince(started))
    }
}
#endif
