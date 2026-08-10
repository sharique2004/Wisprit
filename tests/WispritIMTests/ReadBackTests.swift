import XCTest
import WispritIMProtocol
@testable import WispritIM

/// The read-back channel: the input method looking at the field and reporting
/// what it sees. Two promises are on trial in every test here — it never writes,
/// and it never sends more than it is allowed to.
final class ReadBackTests: XCTestCase {

    private let generation: UInt64 = 42

    private func makeSession(_ client: FakeClient,
                             supportedWireVersion: Int = WispritIMWire.version) -> IMStreamSession {
        let session = IMStreamSession(supportedWireVersion: supportedWireVersion)
        session.clientAcquired(client)
        session.handle(.beginSession(generation: generation))
        return session
    }

    /// `a…z` repeating, so every offset is checkable by eye and by substring.
    private func alphabet(_ length: Int) -> String {
        String((0..<length).map { Character(UnicodeScalar(UInt8(97 + $0 % 26))) })
    }

    private func context(_ session: IMStreamSession,
                         generation: UInt64? = nil,
                         file: StaticString = #filePath,
                         line: UInt = #line) throws -> IMContextSnapshot {
        let message = try XCTUnwrap(session.handle(.readContext(generation: generation ?? self.generation)),
                                    file: file, line: line)
        guard case .contextSnapshot(let snapshot) = message.snapshot else {
            XCTFail("expected a context snapshot, got \(message.snapshot)", file: file, line: line)
            return IMContextSnapshot(detail: .readFailed)
        }
        return snapshot
    }

    private func committed(_ session: IMStreamSession,
                           generation: UInt64? = nil,
                           file: StaticString = #filePath,
                           line: UInt = #line) throws -> IMCommittedSnapshot {
        let message = try XCTUnwrap(session.handle(.readCommitted(generation: generation ?? self.generation)),
                                    file: file, line: line)
        guard case .committedSnapshot(let snapshot) = message.snapshot else {
            XCTFail("expected a committed snapshot, got \(message.snapshot)", file: file, line: line)
            return IMCommittedSnapshot(detail: .readFailed)
        }
        return snapshot
    }

    // MARK: The window

    func testContextIsBoundedAtFourHundredBeforeAndTwoHundredAfterTheCursor() throws {
        let document = alphabet(1000)
        let client = FakeClient(document: document, caret: 600)
        let session = makeSession(client)

        let snapshot = try context(session)

        let whole = document as NSString
        XCTAssertEqual(snapshot.detail, .read)
        XCTAssertEqual(snapshot.before, whole.substring(with: NSRange(location: 200, length: 400)))
        XCTAssertEqual(snapshot.selected, "")
        XCTAssertEqual(snapshot.after, whole.substring(with: NSRange(location: 600, length: 200)))
        XCTAssertEqual((snapshot.text as NSString).length, 600,
                       "never the document — 1000 characters in the field, 600 on the wire")
    }

    func testContextClampsAtTheStartOfTheDocument() throws {
        let document = alphabet(1000)
        let client = FakeClient(document: document, caret: 10)
        let session = makeSession(client)

        let snapshot = try context(session)

        XCTAssertEqual(snapshot.before, (document as NSString).substring(to: 10))
        XCTAssertEqual((snapshot.after as NSString).length, 200)
    }

    func testContextClampsAtTheEndOfTheDocument() throws {
        let document = alphabet(100)
        let client = FakeClient(document: document, caret: 100)
        let session = makeSession(client)

        let snapshot = try context(session)

        XCTAssertEqual(snapshot.before, document)
        XCTAssertEqual(snapshot.after, "", "there is nothing after the end of the field")
    }

    func testContextCarriesTheSelectionSeparatelyFromWhatSurroundsIt() throws {
        let document = "please fix the speling of Sharique in this line"
        let client = FakeClient(document: document, caret: 0)
        client.selection = NSRange(location: 15, length: 8)   // "speling "
        let session = makeSession(client)

        let snapshot = try context(session)

        XCTAssertEqual(snapshot.before, "please fix the ")
        XCTAssertEqual(snapshot.selected, "speling ")
        XCTAssertEqual(snapshot.after, "of Sharique in this line")
    }

    func testContextFallsBackToTheEndOfTheFieldWhenTheClientWillNotSayWhereTheCaretIs() throws {
        let client = FakeClient(document: "hello world", caret: 0)
        client.selection = NSRange(location: NSNotFound, length: 0)
        let session = makeSession(client)

        let snapshot = try context(session)

        XCTAssertEqual(snapshot.before, "hello world")
        XCTAssertEqual(snapshot.after, "")
    }

    func testContextOfAnEmptyFieldIsEmptyRatherThanAFailure() throws {
        let session = makeSession(FakeClient())
        let snapshot = try context(session)

        XCTAssertEqual(snapshot.detail, .read)
        XCTAssertEqual(snapshot.text, "")
    }

    func testContextHonoursTheClientsNarrowerReadWindow() throws {
        // Chromium serves a cached window around the selection: we asked for
        // 200..<800 and got 500..<600. Everything must be based on what came
        // back, not on what was requested.
        let document = alphabet(1000)
        let client = FakeClient(document: document, caret: 600)
        client.readWindow = NSRange(location: 500, length: 100)
        let session = makeSession(client)

        let snapshot = try context(session)

        XCTAssertEqual(snapshot.before,
                       (document as NSString).substring(with: NSRange(location: 500, length: 100)))
        XCTAssertEqual(snapshot.after, "")
    }

    func testContextNeverSplitsAnEmojiAtTheWindowEdge() throws {
        // The 400-character cap lands between the two UTF-16 units of "👋".
        let document = "👋" + String(repeating: "a", count: 500)
        let client = FakeClient(document: document, caret: 401)
        let session = makeSession(client)

        let snapshot = try context(session)

        XCTAssertEqual(snapshot.before, String(repeating: "a", count: 399),
                       "the stranded half of the surrogate pair is dropped, not shipped")
        XCTAssertFalse(snapshot.before.unicodeScalars.contains("\u{FFFD}"))
    }

    // MARK: Refusals

    func testContextIsRefusedWhenTheClientCannotBeRead() throws {
        let client = FakeClient()
        client.supportsDocumentAccess = false
        let session = makeSession(client)

        let snapshot = try context(session)

        XCTAssertEqual(snapshot.detail, .noDocumentAccess)
        XCTAssertEqual(snapshot.text, "")
    }

    func testContextIsRefusedWithNoFocusedField() throws {
        // What Secure Event Input looks like from in here: no client at all.
        let session = IMStreamSession()
        session.handle(.beginSession(generation: generation))

        let snapshot = try context(session)

        XCTAssertEqual(snapshot.detail, .noClient)
    }

    func testContextReportsAFailedReadRatherThanAnEmptyWindow() throws {
        let client = FakeClient(document: "some text", caret: 9)
        let session = makeSession(client)
        client.readsFail = true

        let snapshot = try context(session)

        XCTAssertEqual(snapshot.detail, .readFailed)
        XCTAssertEqual(snapshot.text, "")
    }

    // MARK: The committed run

    func testCommittedRunIsReportedUnchangedWhenTheUserLeftItAlone() throws {
        let client = FakeClient()
        let session = makeSession(client)
        session.handle(.commitFinal(generation: generation, text: "Hi Sharique."))

        let snapshot = try committed(session)

        XCTAssertEqual(snapshot, .unchanged("Hi Sharique."))
    }

    func testCommittedRunIsUnchangedEvenAfterTheUserTypesAroundIt() throws {
        let client = FakeClient()
        let session = makeSession(client)
        session.handle(.commitFinal(generation: generation, text: "Hi Sharique."))
        client.userTypes("PREFIX ", at: 0)

        XCTAssertEqual(try committed(session).detail, .unchanged,
                       "our run moved but is still there, exactly once — nothing was edited")
    }

    func testCommittedRunIsReportedChangedWhenTheUserEditedIt() throws {
        let client = FakeClient()
        let session = makeSession(client)
        session.handle(.commitFinal(generation: generation, text: "Hi Sharik."))
        client.fieldRewritten(to: "Hi Sharique.")

        let snapshot = try committed(session)

        XCTAssertEqual(snapshot.detail, .changed)
        XCTAssertEqual(snapshot.current, "",
                       "that an edit happened is a fact; which edit is not, so nothing is guessed")
    }

    func testCommittedRunIsUnknownWhenItAppearsTwice() throws {
        let client = FakeClient()
        let session = makeSession(client)
        session.handle(.commitFinal(generation: generation, text: "Hi Sharik."))
        client.userTypes("Hi Sharik.", at: 0)   // which run is ours?

        XCTAssertEqual(try committed(session), IMCommittedSnapshot(detail: .unknown))
    }

    func testCommittedRunIsUnknownWhenNothingWasCommitted() throws {
        let session = makeSession(FakeClient(document: "the user's own words", caret: 20))

        XCTAssertEqual(try committed(session).detail, .unknown,
                       "no run of ours to look for is evidence of nothing, not of a clean utterance")
    }

    func testCommittedReadIsRefusedWithoutDocumentAccess() throws {
        let client = FakeClient()
        client.supportsDocumentAccess = false
        let session = makeSession(client)
        session.handle(.commitFinal(generation: generation, text: "Hi Sharique."))

        XCTAssertEqual(try committed(session).detail, .noDocumentAccess)
    }

    func testCommittedReadReportsAFailedRead() throws {
        let client = FakeClient()
        let session = makeSession(client)
        session.handle(.commitFinal(generation: generation, text: "Hi Sharique."))
        client.readsFail = true

        XCTAssertEqual(try committed(session).detail, .readFailed)
    }

    // MARK: Generations

    func testTheCommittedRunStaysReadableAfterTheSessionEnds() throws {
        // The user fixes a word *after* they stop speaking. Refusing here would
        // mean never observing an edit at all.
        let client = FakeClient()
        let session = makeSession(client)
        session.handle(.commitFinal(generation: generation, text: "Hi Sharique."))
        session.handle(.endSession(generation: generation, commit: true))

        XCTAssertEqual(try committed(session), .unchanged("Hi Sharique."))
    }

    func testTheNextUtteranceRetiresThePreviousRun() throws {
        let client = FakeClient()
        let session = makeSession(client)
        session.handle(.commitFinal(generation: generation, text: "Hi Sharique."))
        session.handle(.endSession(generation: generation, commit: true))
        session.handle(.beginSession(generation: generation + 1))

        XCTAssertEqual(try committed(session, generation: generation).detail, .staleGeneration,
                       "a read for the old utterance must not answer out of the new one's session")
        XCTAssertEqual(try committed(session, generation: generation + 1).detail, .unknown)
    }

    func testAStaleReadCarriesTheReasonAndNotOneCharacterOfTheField() throws {
        let client = FakeClient(document: "private notes the app never asked for", caret: 37)
        let session = makeSession(client)

        let snapshot = try context(session, generation: generation + 99)

        XCTAssertEqual(snapshot, IMContextSnapshot(detail: .staleGeneration))
    }

    func testAReadBeforeAnySessionIsRefused() throws {
        let session = IMStreamSession()
        session.clientAcquired(FakeClient(document: "hello", caret: 5))

        XCTAssertEqual(try context(session).detail, .noSession)
    }

    // MARK: Invariants

    func testNoReadEverWritesToTheField() throws {
        let client = FakeClient(document: alphabet(600), caret: 300)
        let session = makeSession(client)
        session.handle(.commitFinal(generation: generation, text: "Hi Sharique."))
        session.handle(.updateVolatile(generation: generation, tail: "and th"))
        let opsBefore = client.ops
        let documentBefore = client.document as String

        _ = session.handle(.readContext(generation: generation))
        _ = session.handle(.readCommitted(generation: generation))
        _ = session.handle(.readContext(generation: generation + 5))
        _ = session.handle(.readCommitted(generation: generation + 5))

        XCTAssertEqual(client.ops, opsBefore, "a read is a read")
        XCTAssertEqual(client.document as String, documentBefore)
        XCTAssertEqual(session.volatileTail, "and th", "and it leaves the live tail alone")
    }

    func testAReadNeverChangesTheTier() throws {
        let client = FakeClient()
        client.supportsDocumentAccess = false
        let session = makeSession(client)

        XCTAssertEqual(try context(session).detail, .noDocumentAccess)
        XCTAssertEqual(session.tier, .markedStreaming,
                       "a refused read must not lower the rung the user's words go out on")
        XCTAssertNil(session.lastDetail)
    }

    // MARK: Degradation to a stale input method

    func testAnInputMethodTooOldForTheReadChannelSaysNothingAtAllButStillTypes() {
        let client = FakeClient()
        // Exactly what an installed WispritIM.app from before wire v2 does.
        let session = IMStreamSession(supportedWireVersion: 1)
        session.clientAcquired(client)
        session.handle(.beginSession(generation: generation))

        XCTAssertNil(session.handle(.readContext(generation: generation)),
                     "no signal — never an error reply the app would have to special-case")
        XCTAssertNil(session.handle(.readCommitted(generation: generation)))

        session.handle(.commitFinal(generation: generation, text: "the words still land"))
        XCTAssertEqual(client.document as String, "the words still land")
    }

    func testTheWriteChannelIsStampedV1SoAStaleInputMethodKeepsWorking() {
        XCTAssertEqual(IMCommandMessage.commitFinal(generation: 1, text: "x").wireVersion, 1)
        XCTAssertEqual(IMEventMessage.clientLost(generation: 1, reason: "x").wireVersion, 1)
        XCTAssertEqual(IMReadMessage.readContext(generation: 1).wireVersion, 2)
        XCTAssertEqual(IMSnapshotMessage.committedSnapshot(generation: 1,
                                                           current: "",
                                                           detail: .unknown).wireVersion, 2)

        // The same arithmetic the stale input method does.
        XCTAssertTrue(WispritIMWire.isSupported(WispritIMWire.writeChannelVersion, by: 1))
        XCTAssertFalse(WispritIMWire.isSupported(WispritIMWire.readChannelVersion, by: 1))
        XCTAssertTrue(WispritIMWire.isSupported(WispritIMWire.readChannelVersion, by: 2))
    }
}
