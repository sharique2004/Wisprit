import Foundation
import WispritIMProtocol

/// The decision layer of the input method: what to do to the focused text field
/// for each message the app sends.
///
/// Three behaviours it exists to get right:
///
///  * **Live tail.** Partials go out as marked text — underlined, provisional,
///    wholesale-replaced on every update. That is exactly what a CJK input method
///    does on every keystroke (5–15 Hz), so Wisprit's 3–10 Hz partial cadence is
///    nowhere near a flicker or rate-limit problem.
///  * **One undo step per stable chunk.** Finals go out as a single
///    `insertText:`, which also clears the marked tail. The user's ⌘Z removes a
///    chunk, not fifty keystrokes.
///  * **Never guess at a range.** A retroactive correction re-reads the live
///    document and aborts unless the text this session committed is still
///    findable, unambiguously, where we can see it. The user may have typed while
///    we were thinking, and mangling their sentence is worse than not correcting.
///
/// Main thread only — IMK delivers on the main thread and `IMService` hops there
/// before touching this.
public final class IMStreamSession {

    // MARK: State

    public private(set) var gate: IMGenerationGate
    public private(set) var tier: IMDeliveryTier = .unsupported
    /// Text this session has committed, in document order.
    public private(set) var committedText: String = ""
    /// Where `committedText` starts and ends, as of the last write. Re-validated
    /// (never trusted) before any retroactive edit.
    public private(set) var committedRange: NSRange?
    /// The provisional tail currently shown as marked text.
    public private(set) var volatileTail: String = ""
    /// Flips false the first time `setMarkedText` fails; the session then
    /// degrades to commit-only for good, because a client that cannot hold
    /// marked text will not start.
    public private(set) var markedTextHealthy: Bool = true
    /// Diagnostics for the log and the tests.
    public private(set) var lastDetail: IMEditDetail?

    public var client: IMClientSeam?

    /// The newest wire version this session admits. Injectable so the stale-input-
    /// method case — an old `WispritIM.app` still installed in
    /// `~/Library/Input Methods` while the app has moved on — is a testable fact
    /// rather than a story about a build nobody has.
    public let supportedWireVersion: Int

    public init(gate: IMGenerationGate = IMGenerationGate(),
                client: IMClientSeam? = nil,
                supportedWireVersion: Int = WispritIMWire.version) {
        self.gate = gate
        self.client = client
        self.supportedWireVersion = supportedWireVersion
    }

    public var capabilities: IMClientCapabilities? { client?.capabilities }

    // MARK: Client lifecycle

    /// `activateServer:` — TSM handed us a text field.
    @discardableResult
    public func clientAcquired(_ client: IMClientSeam) -> IMEventMessage {
        self.client = client
        markedTextHealthy = true
        tier = IMDeliveryTier.decide(capabilities: client.capabilities, markedTextHealthy: true)
        return .clientAcquired(generation: gate.openGeneration ?? 0, client.capabilities)
    }

    /// `deactivateServer:`, focus loss, or the client's app going away. Anything
    /// still marked is the client's problem now; we drop our idea of the field
    /// rather than hold offsets into a document we can no longer see.
    @discardableResult
    public func clientLost(reason: String) -> IMEventMessage {
        let generation = gate.openGeneration ?? 0
        client = nil
        tier = .unsupported
        volatileTail = ""
        committedRange = nil
        gate.abandon()
        return .clientLost(generation: generation, reason: reason)
    }

    // MARK: Commands

    /// Handle one message. Returns the event to send back, if any.
    @discardableResult
    public func handle(_ message: IMCommandMessage) -> IMEventMessage? {
        guard WispritIMWire.isSupported(message.wireVersion, by: supportedWireVersion) else {
            return reject(message, detail: .notSupported,
                          note: "wire version \(message.wireVersion) unsupported")
        }

        switch gate.evaluate(message) {
        case .accept:
            break
        case .rejectStale(let current):
            // The whole point of the generation counter: a message from a session
            // that is over can never touch the field a newer session owns.
            return reject(message, detail: .staleGeneration,
                          note: "generation \(message.generation) != \(current)")
        case .rejectNoSession:
            return reject(message, detail: .noSession, note: message.command.name)
        }

        switch message.command {
        case .beginSession:
            return begin(generation: message.generation)
        case .updateVolatile(let tail):
            return updateVolatile(tail, generation: message.generation)
        case .commitFinal(let text):
            return commitFinal(text, generation: message.generation)
        case .applyEdit(let edit):
            return applyEdit(edit, generation: message.generation)
        case .endSession(let commit):
            return endSession(commit: commit, generation: message.generation)
        }
    }

    // MARK: Reads (wire v2)

    /// Answer a read-back. Never writes, never returns an `IMEvent`, and never
    /// touches the tier — a read that could not be answered must not change where
    /// the user's next words go.
    ///
    /// `nil` means "this build cannot represent the question", which is exactly
    /// what an input method older than the read channel does with these bytes: it
    /// fails to decode them and says nothing. Modelling the refusal as silence
    /// rather than as an error reply keeps the two indistinguishable to the app,
    /// which is what makes "the app degrades to no-signal" a single code path
    /// instead of two.
    public func handle(_ message: IMReadMessage) -> IMSnapshotMessage? {
        guard WispritIMWire.isSupported(message.wireVersion, by: supportedWireVersion) else {
            return nil
        }

        let generation = message.generation
        switch gate.admitRead(generation) {
        case .accept:
            break
        case .rejectStale:
            // Answered, but with nothing in it: a read for a generation we are
            // not serving must not carry one character out of the field.
            return unavailable(message.read, generation: generation, detail: .staleGeneration)
        case .rejectNoSession:
            return unavailable(message.read, generation: generation, detail: .noSession)
        }

        guard let client else {
            return unavailable(message.read, generation: generation, detail: .noClient)
        }
        // Reads go through `stringFromRange:`, which returns nothing without
        // TSMDocumentAccess. Saying so is more useful than an empty window that
        // looks like an empty field.
        guard client.supportsDocumentAccess else {
            return unavailable(message.read, generation: generation, detail: .noDocumentAccess)
        }

        switch message.read {
        case .context:
            return .contextSnapshot(generation: generation, readContext(client))
        case .committed:
            return .committedSnapshot(generation: generation, readCommitted(client))
        }
    }

    /// The bounded window around the insertion point.
    ///
    /// One read, not three: the document can change between calls, and a
    /// `before` from one moment spliced onto an `after` from another is a
    /// sentence the user never wrote.
    private func readContext(_ client: IMClientSeam) -> IMContextSnapshot {
        let length = client.documentLength()
        guard length > 0 else { return .read(before: "", selected: "", after: "") }

        let selection = client.selectedRange()
        let caret = selection.location == NSNotFound ? length : selection.location
        let selectionStart = min(max(0, caret), length)
        let selectionLength = selection.location == NSNotFound
            ? 0 : min(max(0, selection.length), length - selectionStart)
        let selectionEnd = selectionStart + selectionLength

        let windowStart = max(0, selectionStart - IMContextWindow.before)
        let windowEnd = min(length, selectionEnd + IMContextWindow.after)
        guard windowEnd > windowStart else { return .read(before: "", selected: "", after: "") }

        guard let read = client.string(in: NSRange(location: windowStart,
                                                   length: windowEnd - windowStart)) else {
            return .unavailable(.readFailed)
        }
        // `actualRange` is the coordinate base, never the request: a client is
        // allowed to hand back less than we asked for (Chromium serves a cached
        // window around the selection).
        let text = read.text as NSString
        let base = read.actual.location == NSNotFound ? windowStart : read.actual.location
        let usable = IMStreamSession.alignedToCharacters(NSRange(location: 0, length: text.length),
                                                         in: text)
        // Clip in DOCUMENT coordinates and only then rebase. `NSIntersectionRange`
        // is unsigned underneath, so a range whose location went negative on the
        // way to local coordinates comes back empty instead of clamped — which is
        // exactly the client-returned-a-narrower-window case.
        let readable = NSRange(location: base + usable.location, length: usable.length)

        func slice(_ absolute: NSRange) -> String {
            let clipped = NSIntersectionRange(absolute, readable)
            guard clipped.length > 0 else { return "" }
            return text.substring(with: NSRange(location: clipped.location - base,
                                                length: clipped.length))
        }

        return .read(
            before: slice(NSRange(location: windowStart, length: selectionStart - windowStart)),
            selected: slice(NSRange(location: selectionStart, length: selectionLength)),
            after: slice(NSRange(location: selectionEnd, length: windowEnd - selectionEnd)))
    }

    /// Is the run this session committed still exactly what we committed?
    ///
    /// Located by content and only accepted when it occurs exactly once — the
    /// same rule `applyEdit` uses, deliberately shared (`RetroEditPlanner.locate`)
    /// so a correction and an observation can never disagree about which text is
    /// ours. Only that run travels back to the app; the rest of the document is
    /// read here and stays here.
    private func readCommitted(_ client: IMClientSeam) -> IMCommittedSnapshot {
        guard !committedText.isEmpty, committedRange != nil else {
            return .unavailable(.unknown)
        }
        guard let window = readWindow(client) else { return .unavailable(.readFailed) }

        switch RetroEditPlanner.locate(committed: committedText, in: window) {
        case .found(let range):
            // Read the run back out of the document rather than replaying what we
            // remember writing: the app is then comparing against the field.
            return .unchanged((window.text as NSString).substring(with: range))
        case .gone:
            // Our exact text is not there any more, so an edit is a fact. Which
            // edit is not, and inventing one is how a flywheel learns nonsense.
            return .changed
        case .ambiguous:
            return .unavailable(.unknown)
        }
    }

    private func unavailable(_ read: IMRead,
                             generation: UInt64,
                             detail: IMReadDetail) -> IMSnapshotMessage {
        switch read {
        case .context:
            return .contextSnapshot(generation: generation, .unavailable(detail))
        case .committed:
            return .committedSnapshot(generation: generation, .unavailable(detail))
        }
    }

    /// Drop a stranded half of a surrogate pair from either end of a window we
    /// cut ourselves.
    ///
    /// The 400/200 caps are ours, so they can land in the middle of an emoji;
    /// slicing there yields a lone surrogate, which becomes U+FFFD the moment it
    /// is a `String`. Shrinks only — the cap is a promise, not a target.
    private static func alignedToCharacters(_ range: NSRange, in text: NSString) -> NSRange {
        var start = range.location
        var end = NSMaxRange(range)
        guard start >= 0, end <= text.length, end > start else {
            return NSRange(location: max(0, min(start, text.length)), length: 0)
        }
        if UTF16.isTrailSurrogate(text.character(at: start)) { start += 1 }
        if end > start, UTF16.isLeadSurrogate(text.character(at: end - 1)) { end -= 1 }
        return NSRange(location: start, length: max(0, end - start))
    }

    // MARK: Individual commands

    private func begin(generation: UInt64) -> IMEventMessage {
        committedText = ""
        volatileTail = ""
        lastDetail = nil
        markedTextHealthy = true

        guard let client else {
            tier = .unsupported
            committedRange = nil
            return .clientLost(generation: generation, reason: "no text field is focused")
        }

        tier = IMDeliveryTier.decide(capabilities: client.capabilities, markedTextHealthy: true)
        // Anchor at the insertion point. This is the only offset we take on
        // faith, and it is re-validated against the document before it is ever
        // used to replace anything.
        let selection = client.selectedRange()
        let anchor: Int
        if selection.location != NSNotFound {
            anchor = selection.location + selection.length
        } else {
            anchor = client.documentLength()
        }
        committedRange = NSRange(location: max(0, anchor), length: 0)
        return .clientAcquired(generation: generation, client.capabilities)
    }

    private func updateVolatile(_ tail: String, generation: UInt64) -> IMEventMessage? {
        guard let client else { return failure(generation, .noClient, note: "update_volatile") }
        guard tier.streamsLiveTail else {
            // Dropping a partial is lossless: the app always sends the full
            // stable text in `commitFinal`.
            lastDetail = .notSupported
            return nil
        }
        let marked = tail as NSString
        let ok = client.setMarkedText(tail,
                                      selection: NSRange(location: marked.length, length: 0),
                                      replacement: IMNoRange)
        guard ok else {
            markedTextHealthy = false
            tier = IMDeliveryTier.decide(capabilities: client.capabilities, markedTextHealthy: false)
            volatileTail = ""
            return failure(generation, .notSupported,
                           note: "marked text refused by \(client.bundleID); degraded to \(tier.rawValue)")
        }
        volatileTail = tail
        return nil
    }

    private func commitFinal(_ text: String, generation: UInt64) -> IMEventMessage? {
        guard let client else { return failure(generation, .noClient, note: "commit_final") }
        guard tier.acceptsCommits else { return failure(generation, .notSupported, note: "commit_final") }

        guard !text.isEmpty else {
            clearMarkedTail(client)
            return nil
        }

        // One call: `insertText:` with no replacement range commits at the
        // insertion point AND clears whatever was marked. One undo step.
        guard client.insertText(text, replacement: IMNoRange) else {
            return failure(generation, .noClient, note: "insertText refused")
        }
        volatileTail = ""
        append(text)
        return nil
    }

    private func applyEdit(_ edit: IMEdit, generation: UInt64) -> IMEventMessage {
        guard let client else { return failure(generation, .noClient, note: "apply_edit") }
        guard client.supportsUnicode else {
            return failure(generation, .notSupported, note: client.bundleID)
        }
        guard client.supportsDocumentAccess else {
            // Without TSMDocumentAccess the replacement range is silently
            // discarded, so the "correction" would be appended to the end of the
            // field. Refusing is the safe answer; the app corrects before commit
            // instead (or just learns the term).
            return failure(generation, .noDocumentAccess, note: client.bundleID)
        }

        // A live marked tail moves under an absolute-range edit. Take it down,
        // edit, put it back — so the ranges we compute describe committed text
        // only.
        let liveTail = volatileTail
        if !liveTail.isEmpty { clearMarkedTail(client) }
        // Put the tail back at the END OF OUR RUN, not wherever the client left
        // the caret: after an absolute-range `insertText:` the insertion point
        // sits just after the corrected word, in the middle of the sentence.
        // `setMarkedText:`'s replacementRange is exactly the documented way to
        // "insert marked text somewhere other than at the current insertion point".
        defer {
            if !liveTail.isEmpty {
                restoreMarkedTail(liveTail, client: client, at: committedRange.map {
                    NSRange(location: $0.location + $0.length, length: 0)
                } ?? IMNoRange)
            }
        }

        let plan = RetroEditPlanner.plan(edit: edit,
                                         committed: committedText,
                                         committedRange: committedRange,
                                         window: readWindow(client))
        switch plan {
        case .abort(let detail):
            return failure(generation, detail, note: "\(edit.replace) → \(edit.with)")
        case .replace(let range, let text, let newCommitted, let newRange):
            guard client.insertText(text, replacement: range) else {
                return failure(generation, .noClient, note: "insertText refused")
            }
            committedText = newCommitted
            committedRange = newRange
            lastDetail = .applied
            return .editResult(generation: generation, .applied(note: "\(edit.replace) → \(edit.with)"))
        }
    }

    private func endSession(commit: Bool, generation: UInt64) -> IMEventMessage? {
        defer {
            volatileTail = ""
            lastDetail = nil
        }
        guard let client else { return nil }
        if !volatileTail.isEmpty {
            if commit {
                let tail = volatileTail
                if client.insertText(tail, replacement: IMNoRange) { append(tail) }
            } else {
                clearMarkedTail(client)
            }
        }
        return nil
    }

    // MARK: Helpers

    private func append(_ text: String) {
        committedText += text
        let location = committedRange?.location ?? 0
        committedRange = NSRange(location: location, length: (committedText as NSString).length)
    }

    private func clearMarkedTail(_ client: IMClientSeam) {
        guard !volatileTail.isEmpty else { return }
        _ = client.setMarkedText("", selection: NSRange(location: 0, length: 0), replacement: IMNoRange)
        volatileTail = ""
    }

    private func restoreMarkedTail(_ tail: String, client: IMClientSeam, at replacement: NSRange) {
        guard tier.streamsLiveTail else { return }
        let marked = tail as NSString
        if client.setMarkedText(tail,
                                selection: NSRange(location: marked.length, length: 0),
                                replacement: replacement) {
            volatileTail = tail
        }
    }

    /// Fresh read of the client's document. Deliberately re-read on every edit —
    /// caching this is exactly how a retro-edit corrupts a field the user has
    /// been typing into.
    private func readWindow(_ client: IMClientSeam) -> IMDocumentWindow? {
        let length = client.documentLength()
        guard length > 0 else { return nil }
        guard let read = client.string(in: NSRange(location: 0, length: length)) else { return nil }
        let base = read.actual.location == NSNotFound ? 0 : read.actual.location
        return IMDocumentWindow(text: read.text, base: base)
    }

    private func failure(_ generation: UInt64, _ detail: IMEditDetail, note: String) -> IMEventMessage {
        lastDetail = detail
        return .editResult(generation: generation, .failed(detail, note: note))
    }

    private func reject(_ message: IMCommandMessage, detail: IMEditDetail, note: String) -> IMEventMessage {
        lastDetail = detail
        return .editResult(generation: message.generation,
                           .failed(detail, note: "\(message.command.name): \(note)"))
    }
}
