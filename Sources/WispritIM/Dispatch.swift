import Foundation
import WispritIMProtocol

/// Payload in, payload out — the whole of what the transport layer does.
///
/// Keeping it here rather than inside `IMService` means the decode → decide →
/// encode path is testable without a Mach port, and `IMService` is left with
/// nothing but port bookkeeping.
public enum IMDispatch {

    public enum Outcome: Equatable {
        /// Handled. The payload is the event to send back, if the command
        /// produced one.
        case reply(WispritIMPayload?)
        /// The bytes were not a command this build understands. Nothing was done
        /// to the user's text — which is the only acceptable response to a
        /// message we cannot read.
        case undecodable(String)
    }

    public static func handle(_ payload: WispritIMPayload, session: IMStreamSession) -> Outcome {
        let message: IMCommandMessage
        do {
            message = try payload.command()
        } catch {
            return .undecodable("\(error)")
        }
        guard let event = session.handle(message) else { return .reply(nil) }
        return .reply(try? WispritIMPayload(event: event))
    }
}
