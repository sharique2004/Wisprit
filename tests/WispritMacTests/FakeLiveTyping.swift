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

    /// The user edits the field behind our back: rewrites the DOCUMENT, never
    /// the input method's committed record — exactly what typing over a word
    /// looks like from inside the IM.
    func userEdits(_ replace: String, with replacement: String) {
        lock.lock()
        if let range = document.range(of: replace, options: .backwards) {
            document.replaceSubrange(range, with: replacement)
        }
        lock.unlock()
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

    // MARK: wire v2 reads (Phase 4)

    /// Every read request the peer accepted, in order.
    private(set) var reads: [IMReadMessage] = []
    /// false = the post itself fails, the way a pre-v2 install stays silent.
    var readsSucceed = true
    private var snapshotHandler: (@Sendable (IMSnapshotMessage) -> Void)?

    @discardableResult
    func postRead(_ message: IMReadMessage) -> Bool {
        lock.lock()
        guard reachable, readsSucceed else { lock.unlock(); return false }
        reads.append(message)
        // Committed reads are answered here, synchronously, out of the same
        // document + gate the write channel maintains — so the session-level
        // tests exercise the real accept/locate semantics. Context reads stay
        // manual (`deliverContextSnapshot`): their answers race an utterance
        // and the tests script that race explicitly.
        var answer: IMSnapshotMessage?
        if case .committed = message.read {
            answer = .committedSnapshot(generation: message.generation,
                                        committedAnswerLocked(generation: message.generation))
        }
        let handler = snapshotHandler
        lock.unlock()
        if let answer { handler?(answer) }
        return true
    }

    /// The shipping input method's `readCommitted`, in miniature: gate first,
    /// then locate the committed run by content with the single-occurrence
    /// rule. One deliberate extension — where `IMStreamSession` reports
    /// `.changed` with no text (never guess), this fake also tries an anchored
    /// relocation (head and tail of the run each found exactly once) and, when
    /// that succeeds, ships the run as it reads now. That exercises the wire's
    /// `.changed`+current shape, which the app must consume per the protocol
    /// even though today's IM build never populates it.
    private func committedAnswerLocked(generation: UInt64) -> IMCommittedSnapshot {
        switch gate.admitRead(generation) {
        case .rejectStale: return .unavailable(.staleGeneration)
        case .rejectNoSession: return .unavailable(.noSession)
        case .accept: break
        }
        guard let capabilities else { return .unavailable(.noClient) }
        guard capabilities.supportsDocumentAccess else { return .unavailable(.noDocumentAccess) }
        guard !committed.isEmpty else { return .unavailable(.unknown) }
        switch Self.occurrences(of: committed, in: document) {
        case 1: return .unchanged(committed)
        case 0:
            if let current = relocatedRunLocked() {
                return IMCommittedSnapshot(current: current, detail: .changed)
            }
            return .changed
        default: return .unavailable(.unknown)
        }
    }

    /// Head/tail anchors, each required exactly once — the single-occurrence
    /// discipline applied to the pieces when the whole is gone.
    private func relocatedRunLocked() -> String? {
        let anchor = min(12, committed.count)
        guard anchor > 0 else { return nil }
        let head = String(committed.prefix(anchor))
        let tail = String(committed.suffix(anchor))
        guard Self.occurrences(of: head, in: document) == 1,
              Self.occurrences(of: tail, in: document) == 1,
              let headRange = document.range(of: head),
              let tailRange = document.range(of: tail, options: .backwards),
              headRange.lowerBound <= tailRange.lowerBound
        else { return nil }
        return String(document[headRange.lowerBound..<tailRange.upperBound])
    }

    private static func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var from = haystack.startIndex
        while let hit = haystack.range(of: needle, range: from..<haystack.endIndex) {
            count += 1
            if count > 1 { return count }
            from = hit.upperBound
        }
        return count
    }

    func setSnapshotHandler(_ handler: (@Sendable (IMSnapshotMessage) -> Void)?) {
        lock.lock(); snapshotHandler = handler; lock.unlock()
    }

    var readNames: [String] {
        lock.lock(); defer { lock.unlock() }
        return reads.map(\.read.name)
    }

    /// Answer a context read the way the shipping input method would —
    /// unsolicited, stamped with the generation the read named.
    func deliverContextSnapshot(generation: UInt64, before: String,
                                selected: String = "", after: String = "") {
        lock.lock(); let handler = snapshotHandler; lock.unlock()
        handler?(.contextSnapshot(generation: generation, before: before,
                                  selected: selected, after: after))
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
