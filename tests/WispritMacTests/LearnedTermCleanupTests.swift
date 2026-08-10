import XCTest
import WispritDictionary
import WispritKit
@testable import WispritMac

/// The migration for the junk the ungated learn loop already wrote, against a
/// real `DictionaryStore` on a temp path. Never the user's own dictionary.
///
/// The fixture is the live file's shape, entry for entry: `Sharique` with no
/// `source` (the user's, from the Python era), and the three `spoken_spelling`
/// terms the loop created on the three occasions the ASR misheard the spelled
/// letters — each `hear: ["Sharik"]`, each a canonical term, each one making
/// the next misrecognition likelier.
final class LearnedTermCleanupTests: XCTestCase {

    private var root: URL!
    private var path: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wisprit-learn-cleanup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        path = root.appendingPathComponent("dictionary.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - the audit

    func testTheThreeLiveJunkTermsAreAllSpellingsOfTheNameTheFileAlreadyHad() throws {
        try seed(liveShapedDictionary)
        let audit = LearnedTermCleanup.audit(store: DictionaryStore(path: path))

        XCTAssertEqual(audit.examined, 3, "only the loop's own writes are judged")
        XCTAssertEqual(audit.suspects.map(\.term), ["Sharhuue", "Shaikd", "Shariq"])
        for suspect in audit.suspects {
            XCTAssertEqual(suspect.action, .fold(into: "Sharique"), suspect.term)
        }
    }

    func testJunkNeverMergesIntoJunk() throws {
        // `Sharhuue` scores 0.980 against `Shariq`, which is itself junk. If the
        // audit let one merge into another, the cleanup would keep a
        // misrecognition as the canonical spelling of the user's name.
        try seed(liveShapedDictionary)
        let audit = LearnedTermCleanup.audit(store: DictionaryStore(path: path))
        for suspect in audit.suspects {
            XCTAssertEqual(suspect.action, .fold(into: "Sharique"))
        }
    }

    // MARK: - the fix

    func testTheFixFoldsEverySpellingBackIntoTheNameItGarbled() throws {
        try seed(liveShapedDictionary)
        let store = DictionaryStore(path: path)
        let outcome = try LearnedTermCleanup.run(store: store)

        XCTAssertTrue(outcome.changed)
        XCTAssertEqual(outcome.folded,
                       ["Sharhuue → Sharique", "Shaikd → Sharique", "Shariq → Sharique"])
        XCTAssertTrue(outcome.quarantined.isEmpty)

        // The junk canonical terms are gone — they are no longer biasing
        // strings, correction targets or self-casing rules.
        XCTAssertEqual(store.terms(), ["InsForge", "Sharique"])

        // Their spellings survive as evidence on the term they belonged to.
        // "Shariq"/"Sharik" were already listed (case-insensitively), so the
        // fold adds the two that were not.
        XCTAssertEqual(store.heardPhrases(for: "Sharique"),
                       ["shariq", "sharik", "shreek", "Sharhuue", "Shaikd"])

        // And the bug the whole exercise is about stays fixed, now by
        // construction rather than by file order.
        XCTAssertEqual(store.applyCorrections(to: "Hi Sharik"), "Hi Sharique")
    }

    func testTheUsersOwnFileIsBackedUpBeforeAByteOfItChanges() throws {
        try seed(liveShapedDictionary)
        try LearnedTermCleanup.run(store: DictionaryStore(path: path))

        let backup = path.appendingPathExtension("bak")
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), liveShapedDictionary)
        XCTAssertNotEqual(try raw(), liveShapedDictionary)
    }

    func testEntriesTheLoopDidNotWriteAreLeftExactlyAsTheUserWroteThem() throws {
        try seed(liveShapedDictionary)
        let store = DictionaryStore(path: path)
        try LearnedTermCleanup.run(store: store)

        // A `source: "manual"` entry comes back byte-identical.
        let text = try raw()
        XCTAssertTrue(text.contains(manualEntryText), text)
        // And the entry with no `source` at all keeps every key it had —
        // gaining `hear` evidence is the point, gaining a provenance it never
        // claimed is not.
        XCTAssertNil(store.stats(for: "Sharique")?.source)
        XCTAssertEqual(store.stats(for: "Sharique")?.hitCount, 12)
    }

    func testASecondRunIsANoOp() throws {
        try seed(liveShapedDictionary)
        let store = DictionaryStore(path: path)
        try LearnedTermCleanup.run(store: store)
        let afterFirst = try raw()

        let second = try LearnedTermCleanup.run(store: store)

        XCTAssertFalse(second.changed)
        XCTAssertEqual(second.summary, "nothing to clean up")
        XCTAssertEqual(try raw(), afterFirst)
        // The backup still holds the pre-fix file, not a copy of the fixed one.
        XCTAssertEqual(try String(contentsOf: path.appendingPathExtension("bak"), encoding: .utf8),
                       liveShapedDictionary)
    }

    func testAnUnreadableSpellingIsQuarantinedRatherThanDeleted() throws {
        // "Zzzt" is no spelling of anything — no vowel, and nothing in the file
        // to merge it into. Deleting it would throw away the only record that
        // the loop once heard it; `pending: true` keeps the record while
        // excluding it from terms, corrections and the biasing list.
        try seed("""
            {"terms": [
                {"term": "Sharique", "hear": ["shariq"], "hit_count": 12},
                {"term": "Zzzt", "hear": ["is it"], "source": "spoken_spelling", "hit_count": 1}
            ]}
            """)
        let store = DictionaryStore(path: path)
        let outcome = try LearnedTermCleanup.run(store: store)

        XCTAssertEqual(outcome.quarantined, ["Zzzt"])
        XCTAssertEqual(store.terms(), ["Sharique"], "quarantined entries are not vocabulary")
        let entry = try XCTUnwrap(store.learnedEntries().first { $0.term == "Zzzt" })
        XCTAssertTrue(entry.isPending)
        XCTAssertEqual(entry.observations, ["is it"], "the sighting is kept, as a sighting")
        XCTAssertEqual(store.applyCorrections(to: "is it"), "is it")
    }

    func testAlreadyQuarantinedEntriesAreLeftAlone() throws {
        // A pending entry is already out of every derived structure. There is
        // nothing to warn about and nothing to fold, and a second pass over one
        // would only risk resurrecting it.
        try seed("""
            {"terms": [
                {"term": "Sharique", "hear": ["shariq"], "hit_count": 12},
                {"term": "Shariq", "source": "spoken_spelling", "pending": true,
                 "observations": ["Sharik"]}
            ]}
            """)
        let store = DictionaryStore(path: path)
        let audit = LearnedTermCleanup.audit(store: store)

        XCTAssertEqual(audit.examined, 0)
        XCTAssertTrue(audit.isClean)
        XCTAssertFalse(try LearnedTermCleanup.run(store: store).changed)
    }

    func testACleanDictionaryIsNeverRewrittenAndGetsNoBackup() throws {
        try seed("""
            {"terms": [
                {"term": "InsForge", "hear": ["in forge"], "source": "manual"}
            ]}
            """)
        let store = DictionaryStore(path: path)
        let before = try raw()

        XCTAssertFalse(try LearnedTermCleanup.run(store: store).changed)
        XCTAssertEqual(try raw(), before)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: path.appendingPathExtension("bak").path))
    }

    // MARK: - the surface

    func testTheChecklistOffersTheFixOnlyWhileThereIsSomethingToClean() {
        var facts = DoctorFacts()
        XCTAssertNil(SetupChecklist.items(from: facts)
            .first { $0.id == SetupChecklist.learnedTermsID },
                     "a clean dictionary has nothing to say, so it says nothing")

        facts.learnedTerms = LearnedTermCleanup.Audit(examined: 3, suspects: [
            LearnedTermCleanup.Suspect(term: "Sharhuue", hear: ["Sharik"],
                                       action: .fold(into: "Sharique")),
        ])
        let row = SetupChecklist.items(from: facts)
            .first { $0.id == SetupChecklist.learnedTermsID }

        XCTAssertEqual(row?.mark, .warn)
        XCTAssertEqual(row?.fix, .cleanLearnedTerms)
        XCTAssertEqual(row?.fixTitle, Doctor.cleanLearnedTermsTitle)
        XCTAssertEqual(row?.isEssential, false, "dictation works with a messy dictionary")
        XCTAssertEqual(row?.isRequired, false)
    }

    @MainActor
    func testTheFixKindRunsTheInjectedCleanupAndNothingElse() {
        var cleanups = 0
        var relaunches = 0
        let runner = SetupFixRunner(relaunch: { relaunches += 1 },
                                    cleanLearnedTerms: { cleanups += 1 })
        runner.run(.cleanLearnedTerms)

        XCTAssertEqual(cleanups, 1)
        XCTAssertEqual(relaunches, 0)
        XCTAssertNil(SetupFixKind.cleanLearnedTerms.settingsURL,
                     "there is no System Settings pane for the user's own dictionary")
    }

    // MARK: - fixtures

    private func seed(_ json: String) throws {
        try json.write(to: path, atomically: true, encoding: .utf8)
    }

    private func raw() throws -> String {
        try String(contentsOf: path, encoding: .utf8)
    }

    /// One entry, exactly as it sits in the file — indentation included, so
    /// "untouched" can be asserted as bytes rather than as a parse.
    private let manualEntryText = """
            {
              "term": "InsForge",
              "hear": [
                "in forge",
                "ins forge"
              ],
              "source": "manual"
            },
        """

    /// `~/.wisprit/dictionary.json` as it actually stands — same two-space
    /// pretty printing, same key order, trimmed to the entries that matter.
    private let liveShapedDictionary = """
        {
          "terms": [
            {
              "term": "InsForge",
              "hear": [
                "in forge",
                "ins forge"
              ],
              "source": "manual"
            },
            {
              "term": "Sharique",
              "hear": [
                "shariq",
                "sharik",
                "shreek"
              ],
              "hit_count": 12,
              "last_used": "2026-08-10T03:06:31Z"
            },
            {
              "term": "Sharhuue",
              "hear": [
                "Sharik"
              ],
              "source": "spoken_spelling",
              "learned_at": "2026-08-05T23:20:58Z",
              "hit_count": 2,
              "last_used": "2026-08-05T23:20:58Z"
            },
            {
              "term": "Shaikd",
              "hear": [
                "Sharik"
              ],
              "source": "spoken_spelling",
              "learned_at": "2026-08-05T23:21:06Z",
              "hit_count": 2,
              "last_used": "2026-08-05T23:21:06Z"
            },
            {
              "term": "Shariq",
              "hear": [
                "Sharik"
              ],
              "source": "spoken_spelling",
              "learned_at": "2026-08-05T23:34:25Z",
              "hit_count": 2,
              "last_used": "2026-08-05T23:34:25Z"
            }
          ]
        }

        """
}
