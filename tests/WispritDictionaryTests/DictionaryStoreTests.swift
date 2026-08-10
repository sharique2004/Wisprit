import XCTest
import WispritKit
@testable import WispritDictionary

/// Behaviour that has no Python counterpart (the learn loop, ranking) plus the
/// Python behaviours that are about files rather than text (hot reload,
/// degradation, atomic writes).
final class DictionaryStoreTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = try makeTempRoot()
        WispritPaths.overrideRoot = root
    }

    override func tearDownWithError() throws {
        WispritPaths.overrideRoot = nil
        try? FileManager.default.removeItem(at: root)
    }

    private func writeDictionary(_ text: String, modified: Date? = nil) throws {
        try text.write(to: WispritPaths.dictionaryPath, atomically: true, encoding: .utf8)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified],
                                                  ofItemAtPath: WispritPaths.dictionaryPath.path)
        }
    }

    private func fileText() throws -> String {
        try String(contentsOf: WispritPaths.dictionaryPath, encoding: .utf8)
    }

    // MARK: - Loading and degradation

    func testMissingFileLoadsEmptyAndDoesNotThrow() {
        let store = DictionaryStore()
        XCTAssertEqual(store.terms(), [])
        XCTAssertEqual(store.corrections().count, 0)
        XCTAssertEqual(store.applyCorrections(to: "unchanged text"), "unchanged text")
        XCTAssertFalse(store.maybeReload())
    }

    func testInvalidJSONIsTreatedAsEmpty() throws {
        try writeDictionary("{ this is not json")
        let store = DictionaryStore()
        XCTAssertEqual(store.terms(), [])
    }

    func testNonObjectRootIsTreatedAsEmpty() throws {
        try writeDictionary("[1, 2, 3]")
        XCTAssertEqual(DictionaryStore().terms(), [])
    }

    func testMalformedEntriesAreSkipped() throws {
        try writeDictionary("""
        {"terms": [
          "a bare string",
          {"nope": 1},
          {"term": "   "},
          {"term": "Good", "hear": ["", "  ", "gud", 7]}
        ]}
        """)
        let store = DictionaryStore()
        XCTAssertEqual(store.terms(), ["Good"])
        XCTAssertEqual(store.heardPhrases(for: "Good"), ["gud"])
        XCTAssertEqual(store.applyCorrections(to: "that is gud"), "that is Good")
    }

    // MARK: - Hot reload

    func testMaybeReloadPicksUpEdits() throws {
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        try writeDictionary(#"{"terms": [{"term": "Wisprit", "hear": ["whisper it"]}]}"#,
                            modified: old)
        let store = DictionaryStore()
        XCTAssertFalse(store.maybeReload())
        XCTAssertEqual(store.applyCorrections(to: "whisper it works"), "Wisprit works")

        try writeDictionary(#"{"terms": [{"term": "InsForge", "hear": ["in forge"]}]}"#,
                            modified: old.addingTimeInterval(60))
        XCTAssertTrue(store.maybeReload())
        XCTAssertFalse(store.maybeReload())
        XCTAssertEqual(store.terms(), ["InsForge"])
        XCTAssertEqual(store.applyCorrections(to: "whisper it works"), "whisper it works")
    }

    /// A vanished file keeps the last good compilation rather than going empty —
    /// losing the dictionary mid-session would silently degrade every utterance.
    func testMaybeReloadKeepsLastGoodStateWhenFileVanishes() throws {
        try writeDictionary(#"{"terms": [{"term": "Wisprit", "hear": ["whisper it"]}]}"#)
        let store = DictionaryStore()
        try FileManager.default.removeItem(at: WispritPaths.dictionaryPath)
        XCTAssertFalse(store.maybeReload())
        XCTAssertEqual(store.terms(), ["Wisprit"])
    }

    // MARK: - VocabularySource

    func testIsKnownTermIsCaseInsensitiveAndIgnoresHearPhrases() throws {
        try writeDictionary(#"{"terms": [{"term": "InsForge", "hear": ["in forge"]}]}"#)
        let store = DictionaryStore()
        XCTAssertTrue(store.isKnownTerm("InsForge"))
        XCTAssertTrue(store.isKnownTerm("insforge"))
        XCTAssertTrue(store.isKnownTerm("  INSFORGE  "))
        XCTAssertFalse(store.isKnownTerm("in forge"))   // a hear phrase is a WRONG spelling
        XCTAssertFalse(store.isKnownTerm("insforg"))
        XCTAssertFalse(store.isKnownTerm(""))
    }

    func testVocabularyTermsRankByHitCountAndRecency() throws {
        let now = Date()
        let recent = ISO8601DateFormatter().string(from: now.addingTimeInterval(-3600))
        let ancient = ISO8601DateFormatter().string(from: now.addingTimeInterval(-400 * 86_400))
        try writeDictionary("""
        {"terms": [
          {"term": "Alpha"},
          {"term": "Bravo", "hit_count": 2, "last_used": "\(recent)"},
          {"term": "Charlie", "hit_count": 40, "last_used": "\(ancient)"},
          {"term": "Delta", "hit_count": 9, "last_used": "\(recent)"}
        ]}
        """)
        let store = DictionaryStore()
        // Delta (9, fresh) > Bravo (2, fresh) > Charlie (40 but ~13 half-lives
        // stale) > Alpha (never used, keeps file position among the zeroes).
        XCTAssertEqual(store.vocabularyTerms(), ["Delta", "Bravo", "Charlie", "Alpha"])
    }

    func testVocabularyTermsDedupeCaseInsensitively() throws {
        try writeDictionary("""
        {"terms": [{"term": "Spotnana"}, {"term": "Zulu"}, {"term": "spotnana"}]}
        """)
        XCTAssertEqual(DictionaryStore().vocabularyTerms(), ["Spotnana", "Zulu"])
    }

    // MARK: - Learn loop

    /// The load-bearing guarantee: an entry we did not touch comes back
    /// byte-identical, unknown keys and number formatting included.
    func testAddPreservesHandEditedEntriesByteForByte() throws {
        let handEdited = """
        {
          "_comment": "hand written, must survive",
          "terms": [
            {
              "term": "InsForge",
              "hear": [
                "in forge"
              ],
              "notes": "do not touch",
              "weight": 1.50
            }
          ]
        }

        """
        try writeDictionary(handEdited)
        let store = DictionaryStore()
        store.add(LearnedTerm(term: "Sharique", heard: ["Cherie", "Shariq"],
                              source: "spoken_spelling"))

        let text = try fileText()
        let untouched = """
            {
              "term": "InsForge",
              "hear": [
                "in forge"
              ],
              "notes": "do not touch",
              "weight": 1.50
            }
        """
        XCTAssertTrue(text.contains(untouched), "untouched entry was rewritten:\n\(text)")
        XCTAssertTrue(text.contains(#""_comment": "hand written, must survive""#))
        // Top-level key order preserved: _comment still precedes terms.
        XCTAssertLessThan(text.range(of: "_comment")!.lowerBound,
                          text.range(of: "\"terms\"")!.lowerBound)
        XCTAssertEqual(store.terms(), ["InsForge", "Sharique"])
        XCTAssertEqual(store.heardPhrases(for: "Sharique"), ["Cherie", "Shariq"])
    }

    func testAddWritesTheExtensionFields() throws {
        try writeDictionary(#"{"terms": []}"#)
        let store = DictionaryStore()
        store.add(LearnedTerm(term: "Sharique", heard: ["Cherie"], source: "spoken_spelling"))

        let stats = try XCTUnwrap(store.stats(for: "Sharique"))
        XCTAssertEqual(stats.source, "spoken_spelling")
        XCTAssertEqual(stats.hitCount, 1)  // a learn is also a use — rank it high immediately
        XCTAssertNotNil(stats.learnedAt)
        XCTAssertNotNil(stats.lastUsed)
        XCTAssertEqual(try fileText().contains("\"hit_count\": 1"), true)
        // ISO8601 with a Z suffix, so Python's datetime.fromisoformat can read it.
        XCTAssertTrue(try fileText().contains("\"learned_at\": \""))
        XCTAssertTrue(ISO8601DateFormatter().string(from: try XCTUnwrap(stats.learnedAt))
            .hasSuffix("Z"))
    }

    /// A second learn of the same term merges: hear grows append-only, existing
    /// provenance is not rewritten, hit_count climbs.
    func testAddMergesAdditivelyIntoAnExistingEntry() throws {
        try writeDictionary("""
        {"terms": [{"term": "Sharique", "hear": ["Shariq"],
                    "source": "manual", "learned_at": "2020-01-01T00:00:00Z",
                    "custom": {"kept": true}}]}
        """)
        let store = DictionaryStore()
        store.add(LearnedTerm(term: "Sharique", heard: ["shariq", "Cherie"],
                              source: "spoken_spelling"))

        XCTAssertEqual(store.terms(), ["Sharique"])
        // "shariq" is a case-insensitive duplicate of the existing phrase.
        XCTAssertEqual(store.heardPhrases(for: "Sharique"), ["Shariq", "Cherie"])
        let stats = try XCTUnwrap(store.stats(for: "Sharique"))
        XCTAssertEqual(stats.source, "manual")
        XCTAssertEqual(stats.hitCount, 1)
        XCTAssertEqual(ISO8601DateFormatter().string(from: try XCTUnwrap(stats.learnedAt)),
                       "2020-01-01T00:00:00Z")
        XCTAssertTrue(try fileText().contains(#""kept": true"#))
    }

    func testAddMatchesExistingTermCaseInsensitivelyAndAdoptsCanonicalSpelling() throws {
        try writeDictionary(#"{"terms": [{"term": "insforge", "hear": ["in forge"]}]}"#)
        let store = DictionaryStore()
        store.add(LearnedTerm(term: "InsForge", heard: ["ins forge"], source: "manual"))
        XCTAssertEqual(store.terms(), ["InsForge"])
        XCTAssertEqual(store.heardPhrases(for: "InsForge"), ["in forge", "ins forge"])
    }

    func testAddIgnoresBlankTerms() throws {
        try writeDictionary(#"{"terms": []}"#)
        let store = DictionaryStore()
        store.add(LearnedTerm(term: "   ", heard: ["x"], source: "manual"))
        XCTAssertEqual(store.terms(), [])
    }

    func testLearnedTermTakesEffectImmediately() throws {
        try writeDictionary(#"{"terms": []}"#)
        let store = DictionaryStore()
        XCTAssertEqual(store.applyCorrections(to: "hi cherie"), "hi cherie")
        store.add(LearnedTerm(term: "Sharique", heard: ["cherie"], source: "spoken_spelling"))
        XCTAssertEqual(store.applyCorrections(to: "hi cherie"), "hi Sharique")
        XCTAssertEqual(store.vocabularyTerms().first, "Sharique")
        XCTAssertTrue(store.isKnownTerm("sharique"))
    }

    func testAddSeedsTermsArrayWhenTheFileHasNone() throws {
        try writeDictionary(#"{"other": 1}"#)
        let store = DictionaryStore()
        store.add(LearnedTerm(term: "Sharique", heard: [], source: "manual"))
        XCTAssertEqual(store.terms(), ["Sharique"])
        XCTAssertTrue(try fileText().contains(#""other": 1"#))
    }

    func testRecordUseBumpsHitCountAndLastUsed() throws {
        try writeDictionary("""
        {"terms": [{"term": "InsForge", "hear": ["in forge"], "hit_count": 4,
                    "last_used": "2020-01-01T00:00:00Z"}]}
        """)
        let store = DictionaryStore()
        store.recordUse(term: "insforge")
        let stats = try XCTUnwrap(store.stats(for: "InsForge"))
        XCTAssertEqual(stats.hitCount, 5)
        XCTAssertGreaterThan(try XCTUnwrap(stats.lastUsed),
                             Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(store.heardPhrases(for: "InsForge"), ["in forge"])
    }

    func testRecordUseStartsFromZeroAndNeverInventsTerms() throws {
        try writeDictionary(#"{"terms": [{"term": "InsForge"}]}"#)
        let store = DictionaryStore()
        store.recordUse(term: "InsForge")
        XCTAssertEqual(store.stats(for: "InsForge")?.hitCount, 1)
        store.recordUse(term: "NeverHeardOfIt")
        XCTAssertEqual(store.terms(), ["InsForge"])
    }

    func testRemoveTerm() throws {
        try writeDictionary("""
        {"terms": [{"term": "InsForge", "hear": ["in forge"]}, {"term": "Wisprit"}]}
        """)
        let store = DictionaryStore()
        store.removeTerm("insforge")
        XCTAssertEqual(store.terms(), ["Wisprit"])
        XCTAssertEqual(store.applyCorrections(to: "in forge"), "in forge")
        store.removeTerm("   ")
        XCTAssertEqual(store.terms(), ["Wisprit"])
    }

    func testAddTermMirrorsPythonAddTerm() throws {
        try writeDictionary(#"{"terms": []}"#)
        let store = DictionaryStore()
        store.addTerm("Wispr Flow", misrecognitions: ["whisper flow"])
        XCTAssertEqual(store.applyCorrections(to: "whisper   flow"), "Wispr Flow")
        XCTAssertEqual(store.stats(for: "Wispr Flow")?.source, "manual")
    }

    // MARK: - Quarantined (pending) entries

    /// All four derived structures at once. A quarantined entry is a note that
    /// the loop once heard this spelling — it must not correct text, must not
    /// self-case, must not answer `isKnownTerm`, and above all must not reach
    /// the recogniser as a biasing string, where it would make the very
    /// misrecognition that produced it likelier.
    func testPendingEntriesAreExcludedFromEverythingDerived() throws {
        try writeDictionary("""
        {"terms": [
          {"term": "Sharique", "hear": ["shariq"]},
          {"term": "Sharhuue", "hear": ["Sharik"], "source": "spoken_spelling",
           "pending": true, "observations": ["Sharik"]}
        ]}
        """)
        let store = DictionaryStore()
        XCTAssertEqual(store.terms(), ["Sharique"])
        XCTAssertFalse(store.isKnownTerm("Sharhuue"))
        XCTAssertEqual(store.vocabularyTerms(), ["Sharique"])
        XCTAssertEqual(store.corrections().map(\.source).sorted(), ["Sharique", "shariq"])
        XCTAssertEqual(store.applyCorrections(to: "hi sharhuue and shariq"),
                       "hi sharhuue and Sharique")
        // The record itself is still readable — an audit needs to see it.
        XCTAssertEqual(store.heardPhrases(for: "Sharhuue"), ["Sharik"])
    }

    /// The live bug, in the shape that would have hurt. Three junk terms were
    /// written from spelled runs the ASR misread; they were survivable only
    /// because "Sharique" happens to sit earlier in the file and wins the
    /// equal-length tie in the compiled correction order. Quarantining takes
    /// the entry out of the running entirely, so file order stops mattering.
    func testAQuarantinedJunkTermCannotShadowARealOneEvenWhenItComesFirst() throws {
        let junkFirst = """
        {"terms": [
          {"term": "Sharhuue", "hear": ["Sharik"], "source": "spoken_spelling",
           "pending": true, "observations": ["Sharik"]},
          {"term": "Sharique", "hear": ["shariq", "sharik", "shreek"]}
        ]}
        """
        try writeDictionary(junkFirst)
        XCTAssertEqual(DictionaryStore().applyCorrections(to: "Hi Sharik how are you"),
                       "Hi Sharique how are you")

        // Without the flag the same file really does shadow: both `hear`
        // phrases are six characters, so the tie goes to whichever entry the
        // file lists first. That is the outcome the learn gate exists to
        // prevent at write time.
        try writeDictionary(junkFirst.replacingOccurrences(
            of: #""pending": true, "observations": ["Sharik"]"#, with: #""x": 1"#))
        XCTAssertEqual(DictionaryStore().applyCorrections(to: "Hi Sharik how are you"),
                       "Hi Sharhuue how are you")
    }

    func testAddPendingWritesTheQuarantineFieldsAndLearnsNothingYet() throws {
        try writeDictionary(#"{"terms": []}"#)
        let store = DictionaryStore()
        XCTAssertFalse(store.addPending(term: "Sharifue", observation: "Shariq"))

        XCTAssertEqual(store.terms(), [])
        XCTAssertFalse(store.isKnownTerm("Sharifue"))
        XCTAssertEqual(store.applyCorrections(to: "hi shariq"), "hi shariq")
        let text = try fileText()
        XCTAssertTrue(text.contains(#""pending": true"#), text)
        XCTAssertTrue(text.contains(#""observations": ["#), text)
        XCTAssertEqual(store.stats(for: "Sharifue")?.source, "spoken_spelling")
        XCTAssertNotNil(store.stats(for: "Sharifue")?.learnedAt)
    }

    /// The evidence rule: a second sighting of the same run promotes it, and
    /// only then does it become vocabulary. One utterance is exactly what the
    /// three live junk terms each had.
    func testASecondObservationPromotesTheEntry() throws {
        try writeDictionary(#"{"terms": []}"#)
        let store = DictionaryStore()
        store.addPending(term: "Sharifue", observation: "Shariq")
        XCTAssertTrue(store.addPending(term: "sharifue", observation: "Cherie"),
                      "the match is case-insensitive, like every other entry lookup")

        XCTAssertEqual(store.terms(), ["Sharifue"], "the first spelling's casing is kept")
        XCTAssertTrue(store.isKnownTerm("SHARIFUE"))
        XCTAssertEqual(store.heardPhrases(for: "Sharifue"), ["Shariq", "Cherie"],
                       "observations fold into hear, in the order they were seen")
        XCTAssertEqual(store.applyCorrections(to: "hi shariq"), "hi Sharifue")
        XCTAssertEqual(store.stats(for: "Sharifue")?.hitCount, 1)
        let text = try fileText()
        XCTAssertFalse(text.contains("pending"), text)
        XCTAssertFalse(text.contains("observations"), text)
    }

    func testAddPendingOnAnAlreadyRealTermJustTeachesTheMisrecognition() throws {
        try writeDictionary(#"{"terms": [{"term": "Sharique", "hear": ["shariq"]}]}"#)
        let store = DictionaryStore()
        XCTAssertTrue(store.addPending(term: "Sharique", observation: "Sharik"))
        XCTAssertEqual(store.terms(), ["Sharique"])
        XCTAssertEqual(store.heardPhrases(for: "Sharique"), ["shariq", "Sharik"])
        XCTAssertFalse(try fileText().contains("pending"))
    }

    func testAddPendingIgnoresBlankTerms() throws {
        try writeDictionary(#"{"terms": []}"#)
        let store = DictionaryStore()
        XCTAssertFalse(store.addPending(term: "  ", observation: "Shariq"))
        XCTAssertEqual(store.learnedEntries(), [])
    }

    /// Only a JSON `true` is the flag — a hand-written "true" or a 1 must not
    /// silently disable an entry the user meant to keep.
    func testOnlyABooleanTrueQuarantinesAnEntry() throws {
        try writeDictionary("""
        {"terms": [
          {"term": "Alpha", "pending": "true"},
          {"term": "Bravo", "pending": 1},
          {"term": "Charlie", "pending": false},
          {"term": "Delta", "pending": true}
        ]}
        """)
        XCTAssertEqual(DictionaryStore().terms(), ["Alpha", "Bravo", "Charlie"])
    }

    // MARK: - Audit seam

    /// What a later plausibility check runs over: everything the learn loop
    /// wrote, pending ones included, in file order. The store reports what is
    /// on disk; deciding what counts as suspect is the classifier's job.
    func testLearnedEntriesReportProvenanceIncludingPendingOnes() throws {
        try writeDictionary("""
        {"terms": [
          {"term": "InsForge", "hear": ["in forge"]},
          {"term": "Sharhuue", "hear": ["Sharik"], "source": "spoken_spelling",
           "hit_count": 2},
          {"term": "Sharifue", "source": "spoken_spelling", "pending": true,
           "observations": ["Shariq"]},
          {"term": "Manual", "source": "manual"}
        ]}
        """)
        let store = DictionaryStore()
        let learned = store.learnedEntries(source: "spoken_spelling")
        XCTAssertEqual(learned.map(\.term), ["Sharhuue", "Sharifue"])
        XCTAssertEqual(learned.first?.hear, ["Sharik"])
        XCTAssertEqual(learned.first?.isPending, false)
        XCTAssertEqual(learned.first?.stats.hitCount, 2)
        XCTAssertEqual(learned.last?.isPending, true)
        XCTAssertEqual(learned.last?.observations, ["Shariq"])
        XCTAssertEqual(store.learnedEntries().map(\.term),
                       ["InsForge", "Sharhuue", "Sharifue", "Manual"])
        XCTAssertEqual(store.learnedEntries(source: "manual").map(\.term), ["Manual"])
    }

    // MARK: - Atomic writes

    func testWritesLeaveNoTemporaryFilesBehind() throws {
        try writeDictionary(#"{"terms": []}"#)
        let store = DictionaryStore()
        store.add(LearnedTerm(term: "Sharique", heard: ["Cherie"], source: "spoken_spelling"))
        store.recordUse(term: "Sharique")
        let leftovers = try FileManager.default
            .contentsOfDirectory(atPath: root.path)
            .filter { $0.hasSuffix(".tmp") }
        XCTAssertEqual(leftovers, [])
    }

    func testWrittenFileIsValidJSONWithATrailingNewline() throws {
        try writeDictionary(#"{"terms": []}"#)
        let store = DictionaryStore()
        store.add(LearnedTerm(term: "Café über", heard: ["cafe uber"], source: "manual"))
        let text = try fileText()
        XCTAssertTrue(text.hasSuffix("\n"))
        XCTAssertTrue(text.contains("Café über"))  // ensure_ascii=False parity
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(text.utf8)))
        // A fresh store reads back exactly what we wrote.
        let reopened = DictionaryStore()
        XCTAssertEqual(reopened.applyCorrections(to: "cafe uber"), "Café über")
    }
}
