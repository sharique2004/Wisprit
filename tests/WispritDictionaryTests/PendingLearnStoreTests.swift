import XCTest
import WispritKit
@testable import WispritDictionary

/// The evidence ledger behind auto-learn. The rule under test everywhere below
/// is the one that would have blocked every junk term the live loop produced:
/// one utterance is not evidence.
final class PendingLearnStoreTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = try makeTempRoot()
        WispritPaths.overrideRoot = root
    }

    override func tearDownWithError() throws {
        WispritPaths.overrideRoot = nil
        try? FileManager.default.removeItem(at: root)
    }

    private var path: URL { PendingLearnStore.defaultPath }

    private func writeLedger(_ text: String) throws {
        try text.write(to: path, atomically: true, encoding: .utf8)
    }

    private func fileText() throws -> String {
        try String(contentsOf: path, encoding: .utf8)
    }

    /// Distinct utterances, spaced far enough apart to be unmistakably distinct.
    private func utterance(_ index: Int) -> Date {
        Date().addingTimeInterval(Double(index) * -60)
    }

    // MARK: - The threshold

    func testFirstSightingIsEvidenceNotAProposal() {
        let store = PendingLearnStore()
        XCTAssertEqual(store.record(term: "Sharique", heard: "Shariq", at: utterance(0)),
                       .recorded)
        // Recorded, but not proposable — this is exactly the state all three
        // live junk terms died in.
        XCTAssertEqual(store.pending(), [])
        XCTAssertEqual(store.all().map(\.term), ["Sharique"])
        XCTAssertEqual(store.all().first?.count, 1)
        XCTAssertEqual(store.all().first?.status, .proposed)
    }

    func testSecondDistinctUtteranceReachesTheThreshold() {
        let store = PendingLearnStore()
        XCTAssertEqual(store.record(term: "Sharique", heard: "Shariq", at: utterance(0)),
                       .recorded)
        XCTAssertEqual(store.record(term: "Sharique", heard: "Cherie", at: utterance(1)),
                       .reachedThreshold(count: 2))
        XCTAssertEqual(store.pending().map(\.term), ["Sharique"])
        XCTAssertEqual(store.pending().first?.observations.map(\.heard), ["Shariq", "Cherie"])
    }

    /// The distinct-utterance rule: a name said twice in ONE sentence is one
    /// piece of evidence. Without this, a single utterance self-corroborates.
    func testSameUtteranceDoesNotCountTwice() throws {
        let store = PendingLearnStore()
        let at = utterance(0)
        XCTAssertEqual(store.record(term: "Sharique", heard: "Shariq", at: at), .recorded)
        XCTAssertEqual(store.record(term: "Sharique", heard: "Cherie", at: at), .recorded)
        XCTAssertEqual(store.all().first?.count, 1)
        XCTAssertEqual(store.pending(), [])
        // The second heard phrase is not silently swallowed into the same
        // observation either — nothing at all was written.
        XCTAssertFalse(try fileText().contains("Cherie"))
    }

    func testThresholdIsConfigurable() {
        let eager = PendingLearnStore(path: path, threshold: 1)
        XCTAssertEqual(eager.record(term: "Wisprit", heard: "whisper it", at: utterance(0)),
                       .reachedThreshold(count: 1))

        let strict = PendingLearnStore(path: root.appendingPathComponent("strict.json"),
                                       threshold: 3)
        XCTAssertEqual(strict.record(term: "InsForge", heard: "in forge", at: utterance(0)),
                       .recorded)
        XCTAssertEqual(strict.record(term: "InsForge", heard: "ins forge", at: utterance(1)),
                       .recorded)
        XCTAssertEqual(strict.record(term: "InsForge", heard: "in forge", at: utterance(2)),
                       .reachedThreshold(count: 3))
        XCTAssertEqual(strict.pending().map(\.term), ["InsForge"])
    }

    func testFurtherSightingsKeepReportingTheThreshold() {
        let store = PendingLearnStore()
        store.record(term: "Sharique", heard: "Shariq", at: utterance(0))
        store.record(term: "Sharique", heard: "Cherie", at: utterance(1))
        XCTAssertEqual(store.record(term: "Sharique", heard: "Shreek", at: utterance(2)),
                       .reachedThreshold(count: 3))
    }

    func testTermsMatchCaseInsensitivelyAndKeepTheFirstSpelling() {
        let store = PendingLearnStore()
        store.record(term: "Sharique", heard: "Shariq", at: utterance(0))
        XCTAssertEqual(store.record(term: "SHARIQUE", heard: "Cherie", at: utterance(1)),
                       .reachedThreshold(count: 2))
        XCTAssertEqual(store.all().map(\.term), ["Sharique"])
    }

    func testBlankTermsAreIgnored() {
        let store = PendingLearnStore()
        XCTAssertEqual(store.record(term: "   ", heard: "x", at: utterance(0)), .recorded)
        XCTAssertEqual(store.all(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
    }

    // MARK: - Dismissal is forever

    func testDismissBlocksTheTermForever() {
        let store = PendingLearnStore()
        store.record(term: "Blurgh", heard: "blurg", at: utterance(0))
        store.dismiss(term: "Blurgh")

        for i in 1...5 {
            XCTAssertEqual(store.record(term: "Blurgh", heard: "blurg", at: utterance(i)),
                           .alreadyDismissed)
        }
        XCTAssertEqual(store.pending(), [])
        XCTAssertEqual(store.all().first?.status, .dismissed)
        XCTAssertEqual(store.all().first?.count, 1)   // no evidence accrued after the no
    }

    /// Dismissing something never recorded still has to stick: the negative is
    /// the point, not the entry it happens to hang off.
    func testDismissingAnUnknownTermWritesTheNegative() {
        let store = PendingLearnStore()
        store.dismiss(term: "NeverSeen")
        XCTAssertEqual(store.entry(for: "neverseen")?.status, .dismissed)
        XCTAssertEqual(store.record(term: "NeverSeen", heard: "never seen", at: utterance(0)),
                       .alreadyDismissed)
    }

    func testDismissIgnoresBlankTerms() {
        let store = PendingLearnStore()
        store.dismiss(term: "  ")
        XCTAssertEqual(store.all(), [])
    }

    // MARK: - Promotion

    func testPromoteConsumedRemovesTheEntry() {
        let store = PendingLearnStore()
        store.record(term: "Sharique", heard: "Shariq", at: utterance(0))
        store.record(term: "Sharique", heard: "Cherie", at: utterance(1))
        XCTAssertEqual(store.pending().map(\.term), ["Sharique"])

        XCTAssertTrue(store.promoteConsumed(term: "sharique"))   // case-insensitive
        XCTAssertEqual(store.all(), [])
        XCTAssertFalse(store.promoteConsumed(term: "Sharique"))  // nothing left to remove

        // Promotion is not a dismissal: a term that gets removed from the real
        // dictionary later can be proposed again on fresh evidence.
        store.record(term: "Sharique", heard: "Shariq", at: utterance(2))
        XCTAssertEqual(store.all().map(\.term), ["Sharique"])
    }

    // MARK: - The cap

    func testCapEvictsTheOldestEntries() {
        let store = PendingLearnStore(path: path, cap: 3)
        for i in 0..<5 {
            store.record(term: "term\(i)", heard: "heard\(i)", at: utterance(i))
        }
        XCTAssertEqual(store.all().map(\.term), ["term2", "term3", "term4"])
    }

    /// A dismissal is a decision the user actually made; an unreviewed proposal
    /// is not. Losing the negative would re-propose something already refused.
    func testCapEvictsProposalsBeforeDismissals() {
        let store = PendingLearnStore(path: path, cap: 3)
        for i in 0..<3 { store.record(term: "term\(i)", heard: "h", at: utterance(i)) }
        store.dismiss(term: "term0")            // the oldest entry, now a negative
        store.record(term: "term3", heard: "h", at: utterance(3))

        XCTAssertEqual(store.all().map(\.term), ["term0", "term2", "term3"])
        XCTAssertEqual(store.entry(for: "term0")?.status, .dismissed)
    }

    func testCapFallsBackToDroppingDismissalsWhenThatIsAllThereIs() {
        let store = PendingLearnStore(path: path, cap: 2)
        for i in 0..<3 { store.dismiss(term: "term\(i)") }
        XCTAssertEqual(store.all().map(\.term), ["term1", "term2"])
    }

    // MARK: - Expiry

    func testEvidenceOlderThanTheWindowExpiresOnLoad() throws {
        try writeLedger(ledger(term: "Stale", ageDays: 45, status: "proposed"))
        let store = PendingLearnStore()
        XCTAssertEqual(store.all(), [])
        XCTAssertEqual(store.pending(), [])
    }

    func testFreshEvidenceInsideTheWindowSurvives() throws {
        try writeLedger(ledger(term: "Fresh", ageDays: 29, status: "proposed"))
        XCTAssertEqual(PendingLearnStore().all().map(\.term), ["Fresh"])
    }

    /// A "no" is a decision, not evidence, so it does not age out — otherwise a
    /// dismissed term comes back a month later.
    func testDismissalsDoNotExpire() throws {
        try writeLedger(ledger(term: "Refused", ageDays: 400, status: "dismissed"))
        let store = PendingLearnStore()
        XCTAssertEqual(store.all().map(\.term), ["Refused"])
        XCTAssertEqual(store.record(term: "Refused", heard: "refuse", at: Date()),
                       .alreadyDismissed)
    }

    /// A read never writes, but the next write cleans up: the expired row is
    /// gone from the file, not just from the view.
    func testExpiredEntriesDisappearAtTheNextWrite() throws {
        try writeLedger(ledger(term: "Stale", ageDays: 45, status: "proposed"))
        let store = PendingLearnStore()
        XCTAssertTrue(try fileText().contains("Stale"))   // still on disk after a read

        store.record(term: "Live", heard: "live", at: Date())
        XCTAssertFalse(try fileText().contains("Stale"))
        XCTAssertEqual(store.all().map(\.term), ["Live"])
    }

    // MARK: - Corrupted files

    func testMissingFileIsAnEmptyLedger() {
        let store = PendingLearnStore()
        XCTAssertEqual(store.all(), [])
        XCTAssertEqual(store.pending(), [])
        XCTAssertNil(store.entry(for: "anything"))
        XCTAssertFalse(store.promoteConsumed(term: "anything"))
    }

    func testInvalidJSONIsTreatedAsEmptyAndRecoveredOnTheNextWrite() throws {
        try writeLedger("{ this is not json")
        let store = PendingLearnStore()
        XCTAssertEqual(store.all(), [])

        store.record(term: "Sharique", heard: "Shariq", at: utterance(0))
        XCTAssertEqual(store.all().map(\.term), ["Sharique"])
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(try fileText().utf8)))
    }

    func testNonObjectRootIsTreatedAsEmpty() throws {
        try writeLedger("[1, 2, 3]")
        XCTAssertEqual(PendingLearnStore().all(), [])
    }

    func testMalformedEntriesAreSkipped() throws {
        try writeLedger("""
        {"entries": [
          "a bare string",
          {"nope": 1},
          {"term": "   "},
          {"term": "Good", "observations": [
             {"heard": "good", "at": "2026-08-10T22:05:12.250Z"},
             {"heard": "no timestamp"},
             "not an object"
          ], "first_seen": "2026-08-10T22:05:12.250Z", "status": "proposed"}
        ]}

        """)
        // maxAge infinite: this test is about tolerance, not the clock.
        let store = PendingLearnStore(path: path, maxAge: .infinity)
        XCTAssertEqual(store.all().map(\.term), ["Good"])
        XCTAssertEqual(store.all().first?.observations.map(\.heard), ["good"])
    }

    func testEntriesThatAreNotAnArrayAreTreatedAsEmpty() throws {
        try writeLedger(#"{"entries": {"term": "nope"}}"#)
        XCTAssertEqual(PendingLearnStore().all(), [])
    }

    /// An unrecognised status must fail toward asking the user, never toward
    /// silently learning — and never toward a silent block either.
    func testUnknownStatusIsTreatedAsProposed() throws {
        try writeLedger(ledger(term: "Odd", ageDays: 1, status: "who knows"))
        XCTAssertEqual(PendingLearnStore().all().first?.status, .proposed)
    }

    // MARK: - File discipline (the DictionaryStore idiom)

    /// Byte-for-byte, against a ledger written from two known utterances.
    func testWrittenFileIsByteStable() throws {
        // maxAge infinite so the fixed timestamps below never age out of the
        // test; expiry has its own tests.
        let store = PendingLearnStore(path: path, maxAge: .infinity)
        store.record(term: "Sharique", heard: "Shariq",
                     at: Date(timeIntervalSince1970: 1786399512.25))
        store.record(term: "Sharique", heard: "Cherie",
                     at: Date(timeIntervalSince1970: 1786399600.5))

        XCTAssertEqual(try fileText(), """
        {
          "entries": [
            {
              "term": "Sharique",
              "observations": [
                {
                  "heard": "Shariq",
                  "at": "2026-08-10T22:05:12.250Z"
                },
                {
                  "heard": "Cherie",
                  "at": "2026-08-10T22:06:40.500Z"
                }
              ],
              "first_seen": "2026-08-10T22:05:12.250Z",
              "status": "proposed"
            }
          ]
        }

        """)

        // And it reads back as what was written.
        let reopened = PendingLearnStore(path: path, maxAge: .infinity)
        XCTAssertEqual(reopened.pending().map(\.term), ["Sharique"])
        XCTAssertEqual(reopened.entry(for: "Sharique")?.firstSeen,
                       Date(timeIntervalSince1970: 1786399512.25))
    }

    /// Same order-preserving contract as dictionary.json: keys this code has
    /// never heard of survive a write untouched.
    func testUnknownKeysAndKeyOrderSurviveAWrite() throws {
        try writeLedger("""
        {
          "_comment": "hand written, must survive",
          "entries": [
            {
              "term": "Kept",
              "observations": [],
              "first_seen": "2026-08-10T22:05:12.250Z",
              "status": "proposed",
              "why": "a key this code has never heard of"
            }
          ]
        }

        """)
        let store = PendingLearnStore(path: path, maxAge: .infinity)
        store.record(term: "Other", heard: "other", at: Date())

        let text = try fileText()
        XCTAssertTrue(text.contains(#""why": "a key this code has never heard of""#), text)
        XCTAssertTrue(text.contains(#""_comment": "hand written, must survive""#))
        XCTAssertLessThan(text.range(of: "_comment")!.lowerBound,
                          text.range(of: "\"entries\"")!.lowerBound)
        XCTAssertEqual(store.all().map(\.term), ["Kept", "Other"])
    }

    func testWritesLeaveNoTemporaryFilesBehind() throws {
        let store = PendingLearnStore()
        store.record(term: "Sharique", heard: "Shariq", at: utterance(0))
        store.dismiss(term: "Other")
        store.promoteConsumed(term: "Sharique")
        let leftovers = try FileManager.default
            .contentsOfDirectory(atPath: root.path)
            .filter { $0.hasSuffix(".tmp") }
        XCTAssertEqual(leftovers, [])
    }

    func testWrittenFileIsValidJSONWithATrailingNewlineAndRawUnicode() throws {
        let store = PendingLearnStore()
        store.record(term: "Café über", heard: "cafe uber", at: utterance(0))
        let text = try fileText()
        XCTAssertTrue(text.hasSuffix("\n"))
        XCTAssertTrue(text.contains("Café über"))     // ensure_ascii=False parity
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(text.utf8)))
    }

    func testConcurrentRecordsAndReadsDoNotCorruptTheLedger() throws {
        let store = PendingLearnStore()
        DispatchQueue.concurrentPerform(iterations: 40) { i in
            if i.isMultiple(of: 2) {
                store.record(term: "term\(i)", heard: "h\(i)", at: self.utterance(i))
            } else {
                _ = store.pending()
            }
        }
        XCTAssertEqual(store.all().count, 20)
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(try fileText().utf8)))
    }

    // MARK: - Fixtures

    /// One-entry ledger whose single observation is `ageDays` old.
    private func ledger(term: String, ageDays: Double, status: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = formatter.string(from: Date().addingTimeInterval(-ageDays * 86_400))
        return """
        {"entries": [
          {"term": "\(term)",
           "observations": [{"heard": "heard", "at": "\(stamp)"}],
           "first_seen": "\(stamp)",
           "status": "\(status)"}
        ]}

        """
    }
}
