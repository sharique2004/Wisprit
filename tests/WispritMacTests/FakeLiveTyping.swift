import Foundation
import WispritIMProtocol
@testable import WispritMac

/// A fake `WispritIM.app` that lives in this process.
///
/// It is not a stub that returns canned answers: it holds a real
/// `IMGenerationGate` and a real document string, so the tests exercise the same
/// accept/reject/commit/edit semantics the shipping input method implements —
/// including the one that matters most, that a message stamped with a generation
/// the input method is not serving can never touch the field.
///
/// Nothing here talks to a Mach port, an input source, or a text field.
final class FakeIMPeer: LiveTypingPeer, @unchecked Sendable {

    private let lock = NSLock()

    // MARK: knobs

    /// The port answers at all.
    var reachable = true
    /// What `activateServer:` would report about the focused field.
    var capabilities: IMClientCapabilities? = IMClientCapabilities(
        supportsUnicode: true, bundleID: "com.apple.TextEdit",
        supportsDocumentAccess: true, clientID: "fake")
    /// `setMarkedText:` succeeds. false = a Java/Qt-style client.
    var markedTextWorks = true
    /// `insertText:` succeeds.
    var insertWorks = true
    /// Installed / registered / enabled / selected, as TIS would report it.
    var status = InputMethodStatus(bundleInstalled: true, registered: true,
                                   enabled: true, selected: false,
                                   installedVersion: "2.0.0-dev", stagedVersion: "2.0.0-dev")
    /// `beginSession` answers `clientLost` instead of `clientAcquired`.
    var refuseClient = false

    // MARK: observations

    private(set) var commands: [IMCommandMessage] = []
    private(set) var document = ""
    private(set) var markedTail = ""
    private(set) var committed = ""
    private(set) var selectCount = 0
    private(set) var deselectCount = 0
    private(set) var openGeneration: UInt64?

    private var gate = IMGenerationGate()
    private var handler: (@Sendable (IMEventMessage) -> Void)?

    // MARK: helpers for the tests

    var commandNames: [String] {
        lock.lock(); defer { lock.unlock() }
        return commands.map(\.command.name)
    }

    func lastCommand(_ name: String) -> IMCommandMessage? {
        lock.lock(); defer { lock.unlock() }
        return commands.last { $0.command.name == name }
    }

    /// Every provisional tail the input method was handed, in order.
    var volatileTails: [String] {
        lock.lock(); defer { lock.unlock() }
        return commands.compactMap {
            guard case .updateVolatile(let tail) = $0.command else { return nil }
            return tail
        }
    }

    func count(of name: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return commands.filter { $0.command.name == name }.count
    }

    var snapshot: (document: String, marked: String, committed: String) {
        lock.lock(); defer { lock.unlock() }
        return (document, markedTail, committed)
    }

    /// Simulate the field going away mid-utterance (focus change, app quit).
    func loseClient(reason: String = "focus left") {
        lock.lock()
        let generation = gate.openGeneration ?? 0
        gate.abandon()
        openGeneration = nil
        markedTail = ""
        capabilities = nil
        let handler = self.handler
        lock.unlock()
        handler?(.clientLost(generation: generation, reason: reason))
    }

    /// Pre-type text the user already had in the field.
    func preload(_ text: String) {
        lock.lock(); document = text; lock.unlock()
    }

    // MARK: LiveTypingPeer

    var isReachable: Bool {
        lock.lock(); defer { lock.unlock() }
        return reachable
    }

    func exchange(_ message: IMCommandMessage, timeout: TimeInterval) -> LiveTypingReply {
        lock.lock()
        guard reachable else { lock.unlock(); return .unreachable }
        commands.append(message)
        let reply = handleLocked(message)
        lock.unlock()
        return reply
    }

    @discardableResult
    func post(_ message: IMCommandMessage) -> Bool {
        lock.lock()
        guard reachable else { lock.unlock(); return false }
        commands.append(message)
        _ = handleLocked(message)
        lock.unlock()
        return true
    }

    @discardableResult
    func selectInputSource() -> Bool {
        lock.lock(); selectCount += 1; status.selected = true; lock.unlock()
        return true
    }

    func deselectInputSource() {
        lock.lock(); deselectCount += 1; status.selected = false; lock.unlock()
    }

    func inputMethodStatus() -> InputMethodStatus {
        lock.lock(); defer { lock.unlock() }
        return status
    }

    func startEvents(_ handler: @escaping @Sendable (IMEventMessage) -> Void) {
        lock.lock(); self.handler = handler; lock.unlock()
    }

    func stopEvents() {
        lock.lock(); handler = nil; lock.unlock()
    }

    // MARK: the fake input method itself (caller holds `lock`)

    private func handleLocked(_ message: IMCommandMessage) -> LiveTypingReply {
        switch gate.evaluate(message) {
        case .rejectStale:
            return .event(.editResult(generation: message.generation,
                                      .failed(.staleGeneration)))
        case .rejectNoSession:
            return .event(.editResult(generation: message.generation, .failed(.noSession)))
        case .accept:
            break
        }

        switch message.command {
        case .beginSession:
            committed = ""
            markedTail = ""
            guard let capabilities, !refuseClient else {
                gate.abandon()
                openGeneration = nil
                return .event(.clientLost(generation: message.generation,
                                          reason: "no text field is focused"))
            }
            openGeneration = message.generation
            return .event(.clientAcquired(generation: message.generation, capabilities))

        case .updateVolatile(let tail):
            guard capabilities?.supportsUnicode == true else {
                return .event(.editResult(generation: message.generation, .failed(.notSupported)))
            }
            guard markedTextWorks else {
                markedTail = ""
                return .event(.editResult(generation: message.generation,
                                          .failed(.notSupported, note: "marked text refused")))
            }
            markedTail = tail
            return .acknowledged

        case .commitFinal(let text):
            guard insertWorks else {
                return .event(.editResult(generation: message.generation,
                                          .failed(.noClient, note: "insertText refused")))
            }
            markedTail = ""
            guard !text.isEmpty else { return .acknowledged }
            document += text
            committed += text
            return .acknowledged

        case .applyEdit(let edit):
            guard capabilities?.supportsDocumentAccess == true else {
                return .event(.editResult(generation: message.generation,
                                          .failed(.noDocumentAccess)))
            }
            guard !edit.replace.isEmpty else {
                return .event(.editResult(generation: message.generation, .failed(.emptyEdit)))
            }
            guard let range = committed.range(of: edit.replace, options: .backwards) else {
                return .event(.editResult(generation: message.generation,
                                          .failed(.targetNotFound)))
            }
            guard let live = document.range(of: edit.replace, options: .backwards) else {
                return .event(.editResult(generation: message.generation, .failed(.fieldChanged)))
            }
            committed.replaceSubrange(range, with: edit.with)
            document.replaceSubrange(live, with: edit.with)
            return .event(.editResult(generation: message.generation,
                                      .applied(note: "\(edit.replace) → \(edit.with)")))

        case .endSession(let commit):
            if commit, !markedTail.isEmpty {
                document += markedTail
                committed += markedTail
            }
            markedTail = ""
            openGeneration = nil
            return .acknowledged
        }
    }
}
