import Foundation
import WispritKit

/// Published by the session when a vocabulary-channel transcript arrives, and
/// read by the edit-script backend without awaiting it. The insert path does
/// not wait on this slot. Nil `current()` means the peer was not ready, and
/// the agreement mask stays off for that utterance.
public final class EditPeerSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var transcript: String?
    private var termHits: [String: Int] = [:]
    private var published = false

    public init() {}

    public func publish(transcript: String, termHits: [String: Int]) {
        lock.lock()
        self.transcript = transcript
        self.termHits = termHits
        published = true
        lock.unlock()
    }

    public func current() -> (transcript: String, termHits: [String: Int])? {
        lock.lock()
        defer { lock.unlock() }
        guard published, let transcript else { return nil }
        return (transcript, termHits)
    }
}

/// Constraints for `refine_backend=apple_edits` only. The default backend is
/// handed nil and must not consult `TranscriptionConfidence.uncalibratedEditGate`.
public struct EditConstraints: Sendable {
    public var runs: [TranscriptionConfidenceRun]
    /// Already-computed agreement. The generator fills this from `peer` when
    /// the slot has a transcript; tests pass it directly.
    public var agreement: TranscriptAgreement?
    /// Non-blocking peer. Not awaited. Read once, at apply time.
    public var peer: EditPeerSlot?

    public init(runs: [TranscriptionConfidenceRun] = [],
                agreement: TranscriptAgreement? = nil,
                peer: EditPeerSlot? = nil) {
        self.runs = runs
        self.agreement = agreement
        self.peer = peer
    }
}
