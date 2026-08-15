import XCTest
import WispritIMProtocol
@testable import WispritIM

/// The behaviour a user actually feels: words appear as they speak, corrections
/// rewrite them in place, and nothing ever scribbles over text the user typed.
final class StreamSessionTests: XCTestCase {

    private let generation: UInt64 = 42

    private func makeSession(_ client: FakeClient) -> IMStreamSession {
        let session = IMStreamSession()
        session.clientAcquired(client)
        session.handle(.beginSession(generation: generation))
        return session
    }

    // MARK: Live tail

    func testPartialsBecomeUnderlinedMarkedText() {
        let client = FakeClient()
        let session = makeSession(client)

        session.handle(.updateVolatile(generation: generation, tail: "the qui"))
        session.handle(.updateVolatile(generation: generation, tail: "the quick bro"))

        XCTAssertEqual(client.ops, [
            .marked("the qui", selection: NSRange(location: 7, length: 0), replacement: IMNoRange),
            .marked("the quick bro", selection: NSRange(location: 13, length: 0), replacement: IMNoRange),
        ], "each partial wholesale-replaces the marked run, caret at its end")
        XCTAssertEqual(client.visibleText, "the quick bro")
        XCTAssertEqual(session.tier, .markedStreaming)
    }

    func testOneCommitPerStableChunkMeansOneUndoStep() {
        let client = FakeClient()
        let session = makeSession(client)

        session.handle(.updateVolatile(generation: generation, tail: "The quick bro"))
        session.handle(.commitFinal(generation: generation, text: "The quick brown fox "))
        session.handle(.updateVolatile(generation: generation, tail: "jumped o"))
        session.handle(.commitFinal(generation: generation, text: "jumped over."))

        let inserts = client.ops.filter { if case .insert = $0 { return true } else { return false } }
        XCTAssertEqual(inserts.count, 2, "two stable chunks, two insertText calls, two undo steps")
        XCTAssertEqual(client.document as String, "The quick brown fox jumped over.")
        XCTAssertEqual(client.marked, "", "committing clears the provisional tail")
        XCTAssertEqual(session.committedText, "The quick brown fox jumped over.")
    }

    func testCommitStreamStartsAtTheInsertionPointNotTheEndOfTheDocument() {
        let client = FakeClient(document: "before after", caret: 7)
        let session = makeSession(client)

        session.handle(.commitFinal(generation: generation, text: "NEW "))

        XCTAssertEqual(client.document as String, "before NEW after")
        XCTAssertEqual(session.committedRange, NSRange(location: 7, length: 4))
    }

    // MARK: Degradation

    func testMarkedTextRefusalDegradesToCommitOnlyForTheRestOfTheSession() {
        let client = FakeClient()
        client.acceptsMarkedText = false
        let session = makeSession(client)

        let event = session.handle(.updateVolatile(generation: generation, tail: "hello"))

        XCTAssertEqual(event?.event, .editResult(IMEditResult.failed(
            .notSupported,
            note: "marked text refused by com.apple.TextEdit; degraded to commit_only")))
        XCTAssertEqual(session.tier, .commitOnly)
        XCTAssertFalse(session.markedTextHealthy)

        // A second partial is dropped silently — no more doomed setMarkedText calls.
        let opsAfterFirstFailure = client.ops.count
        XCTAssertNil(session.handle(.updateVolatile(generation: generation, tail: "hello there")))
        XCTAssertEqual(client.ops.count, opsAfterFirstFailure)

        // …but the words still land.
        session.handle(.commitFinal(generation: generation, text: "hello there"))
        XCTAssertEqual(client.document as String, "hello there")
    }

    func testClientWithoutUnicodeIsUnsupportedAndNothingIsWritten() {
        let client = FakeClient()
        client.supportsUnicode = false
        let session = makeSession(client)

        XCTAssertEqual(session.tier, .unsupported)
        let event = session.handle(.commitFinal(generation: generation, text: "hello"))
        XCTAssertEqual(event?.event, .editResult(IMEditResult.failed(.notSupported, note: "commit_final")))
        XCTAssertTrue(client.ops.isEmpty, "the app falls back to pasting instead")
    }

    // MARK: Retroactive correction

    func testRetroEditRewritesTheCommittedWordInPlace() {
        let client = FakeClient()
        let session = makeSession(client)
        session.handle(.commitFinal(generation: generation, text: "Hi Sharik, welcome."))

        let event = session.handle(.applyEdit(generation: generation, replace: "Sharik", with: "Sharique"))

        XCTAssertEqual(event?.event, .editResult(IMEditResult.applied(
            note: "Sharik → Sharique", appliedUtf16LocationInCommitted: 3)))
        XCTAssertEqual(client.document as String, "Hi Sharique, welcome.")
        XCTAssertEqual(session.committedText, "Hi Sharique, welcome.")
        XCTAssertEqual(client.ops.last, .insert("Sharique", replacement: NSRange(location: 3, length: 6)),
                       "one absolute-range replacement, not backspaces")
    }

    /// The wrong-instance defect, through the real planner and a real document
    /// model. One session spans consecutive utterances, so two commits put the
    /// same word in the field twice — and until the anchor existed, a
    /// correction aimed at the FIRST could only ever rewrite the second.
    func testAnAnchoredEditFixesTheFirstOccurrenceAcrossTwoCommits() {
        let client = FakeClient()
        let session = makeSession(client)
        session.handle(.commitFinal(generation: generation, text: "Sharik one. "))
        session.handle(.commitFinal(generation: generation, text: "Sharik two."))

        let event = session.handle(.applyEdit(generation: generation, replace: "Sharik",
                                              with: "Sharique", utf16LocationInCommitted: 0))

        XCTAssertEqual(client.document as String, "Sharique one. Sharik two.",
                       "the first is corrected and the second is left exactly as it was")
        XCTAssertEqual(session.committedText, "Sharique one. Sharik two.")
        XCTAssertEqual(event?.event, .editResult(IMEditResult.applied(
            note: "Sharik → Sharique", appliedUtf16LocationInCommitted: 0)))
    }

    /// …and the second occurrence is still reachable, by its own anchor. The
    /// anchor is a choice between real instances, not a bias toward the front.
    func testTheSecondCommitsOccurrenceIsReachableByItsOwnAnchor() {
        let client = FakeClient()
        let session = makeSession(client)
        session.handle(.commitFinal(generation: generation, text: "Sharik one. "))
        session.handle(.commitFinal(generation: generation, text: "Sharik two."))

        session.handle(.applyEdit(generation: generation, replace: "Sharik",
                                  with: "Sharique", utf16LocationInCommitted: 12))

        XCTAssertEqual(client.document as String, "Sharik one. Sharique two.")
        XCTAssertEqual(session.committedText, "Sharik one. Sharique two.")
    }

    /// No anchor, no change of behaviour: the last occurrence, and an echo
    /// saying so — which is what keeps the app's mirror in step even here.
    func testAnUnanchoredEditStillTakesTheLastOccurrenceAndEchoesWhereItLanded() {
        let client = FakeClient()
        let session = makeSession(client)
        session.handle(.commitFinal(generation: generation, text: "Sharik one. Sharik two."))

        let event = session.handle(.applyEdit(generation: generation,
                                              replace: "Sharik", with: "Sharique"))

        XCTAssertEqual(client.document as String, "Sharik one. Sharique two.")
        XCTAssertEqual(event?.event, .editResult(IMEditResult.applied(
            note: "Sharik → Sharique", appliedUtf16LocationInCommitted: 12)))
    }

    /// An offset the record does not bear out — an app-side mirror that drifted
    /// — costs the user the old behaviour, not a rewrite of the wrong word, and
    /// the echo tells the app where the fallback actually put it.
    func testAnOffsetTheRecordDoesNotBearOutDegradesToTheLastOccurrence() {
        let client = FakeClient()
        let session = makeSession(client)
        session.handle(.commitFinal(generation: generation, text: "Sharik one. Sharik two."))

        let event = session.handle(.applyEdit(generation: generation, replace: "Sharik",
                                              with: "Sharique", utf16LocationInCommitted: 4))

        XCTAssertEqual(client.document as String, "Sharik one. Sharique two.")
        XCTAssertEqual(event?.event, .editResult(IMEditResult.applied(
            note: "Sharik → Sharique", appliedUtf16LocationInCommitted: 12)))
    }

    func testRetroEditNeverTouchesTextTheUserTypedThemselves() {
        // The user's own "Sharik" sits before our insertion point. Ours is the
        // one that gets fixed.
        let client = FakeClient(document: "Sharik ", caret: 7)
        let session = makeSession(client)
        session.handle(.commitFinal(generation: generation, text: "Hi Sharik."))

        session.handle(.applyEdit(generation: generation, replace: "Sharik", with: "Sharique"))

        XCTAssertEqual(client.document as String, "Sharik Hi Sharique.")
    }

    func testRetroEditRelocatesWhenTheUserTypesAboveOurText() {
        let client = FakeClient()
        let session = makeSession(client)
        session.handle(.commitFinal(generation: generation, text: "Hi Sharik."))
        client.userTypes("PREFIX ", at: 0)   // every offset we remember is now wrong

        session.handle(.applyEdit(generation: generation, replace: "Sharik", with: "Sharique"))

        XCTAssertEqual(client.document as String, "PREFIX Hi Sharique.",
                       "our run is still findable exactly once, so relocating is a fact, not a guess")
    }

    func testRetroEditAbortsWhenTheFieldWasRewrittenUnderUs() {
        let client = FakeClient()
        let session = makeSession(client)
        session.handle(.commitFinal(generation: generation, text: "Hi Sharik."))
        client.fieldRewritten(to: "something else entirely")
        let opsBefore = client.ops.count

        let event = session.handle(.applyEdit(generation: generation, replace: "Sharik", with: "Sharique"))

        XCTAssertEqual(event?.event, .editResult(IMEditResult.failed(.fieldChanged, note: "Sharik → Sharique")))
        XCTAssertEqual(client.ops.count, opsBefore, "abort writes nothing at all")
        XCTAssertEqual(client.document as String, "something else entirely")
    }

    func testRetroEditAbortsWhenOurTextAppearsTwice() {
        let client = FakeClient()
        let session = makeSession(client)
        session.handle(.commitFinal(generation: generation, text: "Hi Sharik."))
        client.userTypes("Hi Sharik.", at: 0)   // now which run is ours?
        let opsBefore = client.ops.count

        let event = session.handle(.applyEdit(generation: generation, replace: "Sharik", with: "Sharique"))

        XCTAssertEqual(event?.event, .editResult(IMEditResult.failed(.ambiguousRelocation,
                                                                    note: "Sharik → Sharique")))
        XCTAssertEqual(client.ops.count, opsBefore)
    }

    func testRetroEditRefusedWithoutDocumentAccess() {
        let client = FakeClient()
        client.supportsDocumentAccess = false
        let session = makeSession(client)
        session.handle(.commitFinal(generation: generation, text: "Hi Sharik."))
        let opsBefore = client.ops.count

        let event = session.handle(.applyEdit(generation: generation, replace: "Sharik", with: "Sharique"))

        XCTAssertEqual(event?.event, .editResult(IMEditResult.failed(.noDocumentAccess,
                                                                    note: "com.apple.TextEdit")))
        XCTAssertEqual(client.ops.count, opsBefore,
                       "the range would be silently dropped and the fix appended at the end")
    }

    func testRetroEditAbortsWhenTheClientCannotBeRead() {
        let client = FakeClient()
        let session = makeSession(client)
        session.handle(.commitFinal(generation: generation, text: "Hi Sharik."))
        client.readsFail = true

        let event = session.handle(.applyEdit(generation: generation, replace: "Sharik", with: "Sharique"))

        XCTAssertEqual(event?.event, .editResult(IMEditResult.failed(.readFailed, note: "Sharik → Sharique")))
    }

    func testRetroEditWithALiveTailTakesItDownAndPutsItBack() {
        let client = FakeClient()
        let session = makeSession(client)
        session.handle(.commitFinal(generation: generation, text: "Hi Sharik. "))
        session.handle(.updateVolatile(generation: generation, tail: "and th"))
        let opsBefore = client.ops.count

        session.handle(.applyEdit(generation: generation, replace: "Sharik", with: "Sharique"))

        XCTAssertEqual(Array(client.ops.dropFirst(opsBefore)), [
            .marked("", selection: NSRange(location: 0, length: 0), replacement: IMNoRange),
            .insert("Sharique", replacement: NSRange(location: 3, length: 6)),
            // Back at the end of our run — NOT at the caret, which the client
            // left sitting right after the corrected word.
            .marked("and th", selection: NSRange(location: 6, length: 0),
                    replacement: NSRange(location: 13, length: 0)),
        ])
        XCTAssertEqual(client.visibleText, "Hi Sharique. and th")
        XCTAssertEqual(session.volatileTail, "and th")
    }

    // MARK: Generations

    func testAStaleGenerationCanNeverWriteIntoTheNewSessionsField() {
        let client = FakeClient()
        let session = makeSession(client)                       // generation 42
        session.handle(.endSession(generation: generation, commit: true))
        session.handle(.beginSession(generation: generation + 1))
        session.handle(.commitFinal(generation: generation + 1, text: "new utterance"))
        let opsBefore = client.ops.count

        // A partial and an edit from the OLD utterance arrive late.
        let late = session.handle(.updateVolatile(generation: generation, tail: "old tail"))
        let lateEdit = session.handle(.applyEdit(generation: generation, replace: "new", with: "OLD"))

        XCTAssertEqual(late?.event, .editResult(IMEditResult.failed(
            .staleGeneration, note: "update_volatile: generation 42 != 43")))
        XCTAssertEqual(lateEdit?.event, .editResult(IMEditResult.failed(
            .staleGeneration, note: "apply_edit: generation 42 != 43")))
        XCTAssertEqual(client.ops.count, opsBefore, "not one write from the dead session")
        XCTAssertEqual(client.document as String, "new utterance")
    }

    func testGenerationsNeverGoBackwards() {
        let client = FakeClient()
        let session = IMStreamSession()
        session.clientAcquired(client)

        session.handle(.beginSession(generation: 10))
        session.handle(.endSession(generation: 10, commit: true))

        let replay = session.handle(.beginSession(generation: 10))
        XCTAssertEqual(replay?.event, .editResult(IMEditResult.failed(
            .staleGeneration, note: "begin_session: generation 10 != 10")),
            "a replayed beginSession must not reopen a finished utterance")
    }

    func testCommandsOutsideASessionAreRejected() {
        let client = FakeClient()
        let session = IMStreamSession()
        session.clientAcquired(client)

        let event = session.handle(.commitFinal(generation: 7, text: "hello"))

        XCTAssertEqual(event?.event, .editResult(IMEditResult.failed(
            .noSession, note: "commit_final: commit_final")))
        XCTAssertTrue(client.ops.isEmpty)
    }

    func testUnsupportedWireVersionIsRejectedRatherThanGuessed() {
        let client = FakeClient()
        let session = makeSession(client)
        var message = IMCommandMessage.commitFinal(generation: generation, text: "hello")
        message.wireVersion = WispritIMWire.version + 1

        let event = session.handle(message)

        XCTAssertEqual(event?.event, .editResult(IMEditResult.failed(
            .notSupported,
            note: "commit_final: wire version \(WispritIMWire.version + 1) unsupported")))
        XCTAssertTrue(client.ops.isEmpty)
    }

    // MARK: Ending

    func testEndSessionCommitsTheProvisionalTail() {
        let client = FakeClient()
        let session = makeSession(client)
        session.handle(.updateVolatile(generation: generation, tail: "trailing words"))

        session.handle(.endSession(generation: generation, commit: true))

        XCTAssertEqual(client.document as String, "trailing words")
        XCTAssertEqual(client.marked, "")
        XCTAssertEqual(session.volatileTail, "")
    }

    func testEndSessionWithoutCommitDropsTheProvisionalTail() {
        let client = FakeClient()
        let session = makeSession(client)
        session.handle(.updateVolatile(generation: generation, tail: "never mind"))

        session.handle(.endSession(generation: generation, commit: false))

        XCTAssertEqual(client.document as String, "")
        XCTAssertEqual(client.visibleText, "")
    }

    func testLosingTheClientClosesTheSessionInsteadOfHoldingStaleOffsets() {
        let client = FakeClient()
        let session = makeSession(client)
        session.handle(.commitFinal(generation: generation, text: "hello "))

        let event = session.clientLost(reason: "deactivateServer")

        XCTAssertEqual(event.event, .clientLost(reason: "deactivateServer"))
        XCTAssertNil(session.committedRange)
        XCTAssertEqual(session.tier, .unsupported)
        XCTAssertFalse(session.gate.isOpen)
    }

    func testBeginningWithNoFocusedFieldReportsClientLost() {
        let session = IMStreamSession()
        let event = session.handle(.beginSession(generation: 1))
        XCTAssertEqual(event?.event, .clientLost(reason: "no text field is focused"))
        XCTAssertEqual(session.tier, .unsupported)
    }

    func testCapabilitiesAreReportedWhenTheSessionOpens() {
        let client = FakeClient()
        client.bundleID = "com.google.Chrome"
        client.supportsDocumentAccess = false
        let session = IMStreamSession()
        session.clientAcquired(client)

        let event = session.handle(.beginSession(generation: 3))

        XCTAssertEqual(event?.event, .clientAcquired(IMClientCapabilities(
            supportsUnicode: true,
            bundleID: "com.google.Chrome",
            supportsDocumentAccess: false,
            clientID: "fake-client")))
        XCTAssertFalse(IMDeliveryTier.supportsRetroEdit(session.capabilities),
                       "streaming yes, retro-correction no — the app must know before it speaks")
    }
}
