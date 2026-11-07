import XCTest
import WispritContext
import WispritCorrections
import WispritDictionary
import WispritKit
import WispritPersistence
@testable import WispritMac

/// The Dictionary page's review queue, source labels, keep / stop-matching
/// decisions and undo — against a real `DictionaryStore` on a temp path and a
/// fixed lexicon, never the user's file or the machine's word list.
@MainActor
final class DictionaryReviewTests: XCTestCase {

    private var root: URL!
    private var path: URL!

    /// The lexicon these tests call "English". Base forms only, like
    /// `/usr/share/dict/words`, so the inflection rule is exercised.
    private static let lexicon = FixedLexicon([
        "play", "employ", "place", "ploy", "letter", "queen", "archive", "the", "you",
        "four", "hands", "remain",
    ])
    private let ordinary = OrdinaryWords(DictionaryReviewTests.lexicon)

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wisprit-dict-review-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        path = root.appendingPathComponent("dictionary.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func seed(_ json: String) throws {
        try json.write(to: path, atomically: true, encoding: .utf8)
    }

    private func raw() throws -> String {
        try String(contentsOf: path, encoding: .utf8)
    }

    private func editor(_ words: OrdinaryWords? = nil) -> DictionaryEditor {
        DictionaryEditor(store: DictionaryStore(path: path), ordinaryWords: words ?? ordinary)
    }

    private func makeModel(proposals: [WispritWindowModel.LearnProposalRow] = []) -> WispritWindowModel {
        WispritWindowModel(
            settings: Settings(path: root.appendingPathComponent("config.json")),
            dictionary: editor(),
            ports: WispritWindowModel.Ports(learnProposals: { proposals }))
    }

    private static let fixture = """
        {"terms": [
          {"term": "Ploy", "hear": ["play", "employ", "ploy", "place"], "source": "vocab_retro",
           "hit_count": 2},
          {"term": "Letta", "hear": ["letters", "leta"]},
          {"term": "Qwen", "hear": ["quinn", "q wen", "queen"], "kept_hears": ["queen"]},
          {"term": "Four Hands", "hear": ["four hands", "for hands"]},
          {"term": "InsForge", "hear": ["in forge"], "source": "manual"},
          {"term": "Krzysztof", "source": "spoken_spelling", "pending": true,
           "observations": ["play"]},
          {"term": "Spotnana", "hear": ["spot nana"]},
          {"term": "Spotnana", "hear": ["spot nona"]}
        ]}
        """

    // MARK: - what counts as an everyday word

    /// The page asks the fuzzy layer's own question, so for any token the two
    /// answers are the same — including inflections the base-form lexicon
    /// does not list ("letters" is ordinary because "letter" is).
    func testTheReviewAndTheEngineAgreeOnEverydayWords() {
        let words = ["play", "letters", "employed", "queens", "archive", "quinn",
                     "leta", "shariq", "remained", "ploys"]
        for word in words {
            XCTAssertEqual(ordinary.isEveryday(word),
                           FuzzyVocabularyCorrector.isOrdinaryToken(word) {
                               Self.lexicon.contains($0)
                           }, word)
        }
        XCTAssertTrue(ordinary.isEveryday("letters"))
        XCTAssertTrue(ordinary.isEveryday(" Play "), "trimmed, case-insensitive")
        XCTAssertFalse(ordinary.isEveryday("quinn"))
        XCTAssertFalse(ordinary.isEveryday("four hands"),
                       "a multi-word phrase is the term spaced out, not an everyday word")
        XCTAssertFalse(OrdinaryWords.none.isEveryday("play"))
    }

    func testTheReviewFlagsExactlyTheEverydayHears() throws {
        try seed(Self.fixture)
        let editor = editor()
        let review = editor.review(editor.rows())

        XCTAssertEqual(review.everydayWords.map(\.term), ["Ploy", "Letta"])
        XCTAssertEqual(review.everydayWords[0].words, ["play", "employ", "place"],
                       "the term's own spelling is not flagged: removing it changes nothing")
        XCTAssertEqual(review.everydayWords[0].kind, .learnedAutomatically)
        XCTAssertEqual(review.everydayWords[1].words, ["letters"])
        XCTAssertFalse(review.everydayWords.contains { $0.term == "Qwen" },
                       "a kept word is not asked about again")
        XCTAssertFalse(review.everydayWords.contains { $0.term == "Krzysztof" },
                       "a quarantined entry corrects nothing yet")
        XCTAssertEqual(review.pending.map(\.term), ["Krzysztof"])
        XCTAssertEqual(review.duplicates, [DuplicateReview(term: "Spotnana", copies: 2)])
        XCTAssertEqual(review.count, 4)
    }

    /// Before the system word list loads, the review only knows the compiled-in
    /// floor; `isReady` is what tells the model to ask again.
    func testAnUnloadedLexiconIsReportedSoTheReviewIsAskedAgain() {
        let loading = OrdinaryWords(lookup: { _ in false }, isLoaded: { false })
        XCTAssertFalse(loading.isReady)
        XCTAssertTrue(ordinary.isReady, "a fixed lexicon is always loaded")
    }

    // MARK: - source labels

    func testEverySourceValueHasPlainWords() {
        XCTAssertEqual(DictionarySource(nil).label, "added by you")
        XCTAssertEqual(DictionarySource("manual").label, "added by you")
        XCTAssertEqual(DictionarySource("vocab_retro").label, "learned automatically")
        XCTAssertEqual(DictionarySource(SpokenSpellingCorrector.source).label,
                       "learned from a spelling")
        XCTAssertEqual(DictionarySource(EditCapture.learnSource).label, "learned from your edits")
        XCTAssertEqual(DictionarySource("something_new").label, "imported")

        for kind in DictionarySource.allCases {
            XCTAssertFalse(kind.label.contains("_"), "no internal names on screen: \(kind)")
        }
        XCTAssertEqual(DictionarySource.allCases.filter(\.isLearned),
                       [.learnedAutomatically, .learnedFromSpelling, .learnedFromEdits])
    }

    func testTheLearnedAndAddedFiltersSplitOnSource() throws {
        try seed(Self.fixture)
        let rows = editor().rows()
        let learned = DictionaryList.items(rows, search: "", sort: .alphabetical, filter: .learned)
        let added = DictionaryList.items(rows, search: "", sort: .alphabetical, filter: .added)

        XCTAssertEqual(learned.map(\.row.term), ["Krzysztof", "Ploy"])
        XCTAssertEqual(added.count + learned.count, rows.count)
        XCTAssertEqual(DictionaryList.tag(for: rows[0]).title, "learned automatically")
        XCTAssertEqual(DictionaryList.tag(for: rows[4]).title, "added by you")
        XCTAssertNil(DictionaryList.tag(for: rows[4]).symbol, "the user's own entries say so quietly")
        XCTAssertEqual(DictionaryList.tag(for: rows[5]).symbol, "clock", "pending says pending")
    }

    // MARK: - decisions through the model

    func testStopMatchingRemovesOnlyTheFlaggedWords() throws {
        try seed(Self.fixture)
        let model = makeModel()
        let ploy = try XCTUnwrap(model.dictionaryReview.everydayWords.first)

        XCTAssertTrue(model.stopMatching(ploy))

        let row = try XCTUnwrap(model.dictionaryRows.first { $0.term == "Ploy" })
        XCTAssertEqual(row.hear, ["ploy"])
        XCTAssertEqual(row.hitCount, 2, "stats survive")
        XCTAssertEqual(row.source, "vocab_retro")
        XCTAssertEqual(model.dictionaryReview.everydayWords.map(\.term), ["Letta"])
        XCTAssertEqual(model.dictionaryLastChange?.summary,
                       "Ploy no longer changes “play”, “employ” and “place”.")
        XCTAssertEqual(DictionaryStore(path: path).applyCorrections(to: "we play"), "we play")
    }

    /// Keep is persisted in the entry, so a new process does not ask again —
    /// and a new everyday word learned later IS asked about.
    func testKeepIsRememberedAcrossLaunches() throws {
        try seed(Self.fixture)
        let model = makeModel()
        let ploy = try XCTUnwrap(model.dictionaryReview.everydayWords.first)

        XCTAssertTrue(model.keepEverydayWords(ploy))
        XCTAssertEqual(model.dictionaryReview.everydayWords.map(\.term), ["Letta"])
        XCTAssertEqual(DictionaryStore(path: path).applyCorrections(to: "we play"), "we Ploy",
                       "kept words keep correcting")

        let relaunched = editor()
        XCTAssertEqual(relaunched.review(relaunched.rows()).everydayWords.map(\.term), ["Letta"])

        DictionaryStore(path: path).add(LearnedTerm(term: "Ploy", heard: ["queen"],
                                                    source: "vocab_retro"))
        let later = editor()
        XCTAssertEqual(later.review(later.rows()).everydayWords.first?.words, ["queen"])
    }

    func testMergeFoldsTheDuplicateAndLeavesTheQueue() throws {
        try seed(Self.fixture)
        let model = makeModel()
        let duplicate = try XCTUnwrap(model.dictionaryReview.duplicates.first)

        XCTAssertTrue(model.mergeDuplicates(duplicate))
        XCTAssertEqual(model.dictionaryRows.filter { $0.term == "Spotnana" }.map(\.hear),
                       [["spot nana", "spot nona"]])
        XCTAssertTrue(model.dictionaryReview.duplicates.isEmpty)
    }

    /// The sidebar badge counts every kind of decision.
    func testTheReviewCountIncludesProposals() throws {
        try seed(Self.fixture)
        let model = makeModel(proposals: [.init(term: "Sharique", heard: ["Shariq"], count: 2)])

        XCTAssertEqual(model.dictionaryReview.count, 4)
        XCTAssertEqual(model.dictionaryReviewCount, 5)
        XCTAssertEqual(model.dictionaryBadge, .attention)
    }

    func testAnEmptyDictionaryNeedsNoReview() throws {
        try seed("{\"terms\": [{\"term\": \"InsForge\", \"hear\": [\"in forge\"]}]}")
        let model = makeModel()
        XCTAssertEqual(model.dictionaryReviewCount, 0)
        XCTAssertNil(model.dictionaryBadge)
    }

    // MARK: - undo

    /// Edit ▸ Undo puts the file back byte for byte; Redo does the change again.
    func testUndoAndRedoThroughTheWindowsUndoManager() throws {
        try seed(Self.fixture)
        let model = makeModel()
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.dictionaryUndoManager = undo
        model.deleteTerm("InsForge")   // one write, so `before` is in serializer form
        undo.undo()
        let original = try raw()

        let ploy = try XCTUnwrap(model.dictionaryReview.everydayWords.first)
        model.stopMatching(ploy)
        XCTAssertNotEqual(try raw(), original)
        XCTAssertTrue(undo.canUndo)
        XCTAssertEqual(undo.undoActionName, "Stop Matching")

        undo.undo()
        XCTAssertEqual(try raw(), original)
        XCTAssertEqual(model.dictionaryReview.everydayWords.first?.words, ["play", "employ", "place"])
        XCTAssertNil(model.dictionaryLastChange, "the confirmation goes with the change")
        XCTAssertTrue(undo.canRedo)

        undo.redo()
        XCTAssertEqual(model.dictionaryRows.first { $0.term == "Ploy" }?.hear, ["ploy"])
    }

    func testDeleteIsUndoneExactlyIncludingStatsAndPosition() throws {
        try seed(Self.fixture)
        let model = makeModel()
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.dictionaryUndoManager = undo
        model.keepEverydayWords(try XCTUnwrap(model.dictionaryReview.everydayWords.last))
        let before = try raw()

        model.deleteTerm("Ploy")
        XCTAssertFalse(model.dictionaryRows.contains { $0.term == "Ploy" })
        XCTAssertEqual(model.dictionaryLastChange?.summary, "Deleted “Ploy”.")

        undo.undo()
        XCTAssertEqual(try raw(), before)
        XCTAssertEqual(model.dictionaryRows.first?.term, "Ploy", "back in its old place")
    }

    /// The inline Undo reverts the change and withdraws it from the undo
    /// manager, so ⌘Z cannot undo the same change twice.
    func testTheInlineUndoRevertsAndWithdrawsTheChange() throws {
        try seed(Self.fixture)
        let model = makeModel()
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.dictionaryUndoManager = undo
        model.deleteTerm("InsForge")
        undo.undo()
        undo.removeAllActions()
        let original = try raw()

        model.deleteTerm("Letta")
        XCTAssertTrue(undo.canUndo)
        model.undoDictionaryChange()

        XCTAssertEqual(try raw(), original)
        XCTAssertNil(model.dictionaryLastChange)
        XCTAssertFalse(undo.canUndo)
    }

    /// A save is undoable too, including a rename (two terms touched) and an
    /// add (undo removes it).
    func testAddAndRenameAreUndoable() throws {
        try seed(Self.fixture)
        let model = makeModel()
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.dictionaryUndoManager = undo

        XCTAssertTrue(model.saveTerm(original: nil, term: "Wisprit", hear: ["whisper it"]))
        XCTAssertTrue(model.dictionaryRows.contains { $0.term == "Wisprit" })
        undo.undo()
        XCTAssertFalse(model.dictionaryRows.contains { $0.term == "Wisprit" })

        let letta = try XCTUnwrap(model.dictionaryRows.first { $0.term == "Letta" })
        XCTAssertTrue(model.saveTerm(original: letta, term: "Letta AI", hear: ["leta"]))
        XCTAssertEqual(model.dictionaryRows.filter { $0.term.hasPrefix("Letta") }.map(\.term),
                       ["Letta AI"])
        undo.undo()
        XCTAssertEqual(model.dictionaryRows.filter { $0.term.hasPrefix("Letta") }.map(\.term),
                       ["Letta"])
        XCTAssertEqual(model.dictionaryRows.first { $0.term == "Letta" }?.hear, ["letters", "leta"])
    }

    func testAWriteThatChangesNothingIsNotRecorded() throws {
        try seed(Self.fixture)
        let model = makeModel()
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.dictionaryUndoManager = undo

        let original = try XCTUnwrap(model.dictionaryRows.first { $0.term == "InsForge" })
        XCTAssertFalse(model.saveTerm(original: original, term: "InsForge", hear: ["in forge"]))
        XCTAssertNil(model.dictionaryLastChange)
        XCTAssertFalse(undo.canUndo)
    }

    // MARK: - copy

    func testConfirmationAndWarningCopy() {
        XCTAssertEqual(DictionaryCopy.quotedList(["a"]), "“a”")
        XCTAssertEqual(DictionaryCopy.quotedList(["a", "b"]), "“a” and “b”")
        XCTAssertEqual(DictionaryCopy.quotedList(["a", "b", "c"]), "“a”, “b” and “c”")

        let isEveryday = { (phrase: String) in DictionaryReviewTests.lexicon.contains(phrase) }
        XCTAssertEqual(DictionaryList.everydayWarning(term: "Ploy", hear: ["play", "ploy", "pl oy"],
                                                      isEveryday: isEveryday),
                       "“play” is an everyday word — Wisprit will change it to Ploy every "
                       + "time you say it.")
        XCTAssertNil(DictionaryList.everydayWarning(term: "Ploy", hear: ["ploy"],
                                                    isEveryday: isEveryday),
                     "the term's own spelling never warns")
        XCTAssertEqual(DictionaryList.filterTitle(.review, reviewCount: 28), "Review 28")
        XCTAssertEqual(DictionaryList.filterTitle(.review, reviewCount: 0), "Review")
        XCTAssertEqual(DictionaryList.filterTitle(.all, reviewCount: 28), "All")
        XCTAssertEqual(DictionaryList.reviewHeadline(1), "1 thing needs a decision")
        XCTAssertEqual(DictionaryList.reviewHeadline(28), "28 things need a decision")
    }
}
