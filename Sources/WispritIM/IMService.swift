import Foundation
import WispritIMProtocol
import WispritKit

#if os(macOS)

/// The input method's side of the pipe: one named port, one session, one client.
///
/// Commands arrive on the main run loop (that is where `CFMessagePort`'s source
/// is attached, and where IMK delivers `activateServer:`), so the session's view
/// of the field is only ever touched by one thread and a partial can never
/// interleave with a retroactive edit.
public final class IMService {

    public static let shared = IMService()

    public let session = IMStreamSession()

    private let log = WLog.logger("im.service")
    private var server: WispritIMPortServer?
    private let events: WispritIMRemotePort
    private let startedAt = Date()

    private init() {
        events = WispritIMRemotePort(name: WispritIMNaming.eventPortName)
    }

    // MARK: Listening

    /// Registers the port name. Returns false when another copy of the input
    /// method already owns it — in which case this process must stay out of the
    /// way rather than fight over the user's text field.
    @discardableResult
    public func start(machServiceName: String = WispritIMNaming.machServiceName) -> Bool {
        guard server == nil else { return true }
        let server = WispritIMPortServer(name: machServiceName) { [weak self] payload in
            self?.handle(payload)
        }
        guard server.start() else {
            log.error("port \(machServiceName, privacy: .public) is already taken")
            return false
        }
        self.server = server
        log.info("listening on \(machServiceName, privacy: .public)")
        return true
    }

    public func stop() {
        server?.stop()
        server = nil
    }

    public var uptime: TimeInterval { Date().timeIntervalSince(startedAt) }

    // MARK: Commands in

    private func handle(_ payload: WispritIMPayload) -> WispritIMPayload? {
        switch IMDispatch.handle(payload, session: session) {
        case .reply(let response):
            return response
        case .emit(let snapshot):
            // The app posted the read and moved on, so the answer travels the
            // same way every other unsolicited message does.
            events.post(snapshot, timeout: 0.2)
            return nil
        case .undecodable(let reason):
            log.error("undecodable payload: \(reason, privacy: .public)")
            return nil
        }
    }

    // MARK: Called by the input controller

    public func clientAcquired(_ seam: IMClientSeam) {
        emit(session.clientAcquired(seam))
    }

    public func clientLost(reason: String) {
        emit(session.clientLost(reason: reason))
    }

    /// `commitComposition:` — the client is ending the composition under us.
    /// Commit the marked tail rather than dropping words the user already said.
    public func commitCompositionFromClient() {
        guard let generation = session.gate.openGeneration else { return }
        _ = session.handle(.endSession(generation: generation, commit: true))
    }

    // MARK: Events out

    /// Unsolicited events go to the app's own port. Fire and forget: the app may
    /// not be listening (it may not even be running), and the input method must
    /// never block on it.
    public func emit(_ event: IMEventMessage) {
        guard let payload = try? WispritIMPayload(event: event) else { return }
        events.post(payload, timeout: 0.2)
    }
}
#endif
