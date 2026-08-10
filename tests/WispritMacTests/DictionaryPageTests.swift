import XCTest
import WispritDictionary
import WispritKit
import WispritPersistence
@testable import WispritMac

/// The Dictionary page's decisions — `docs/design/ui-redesign.md` §3.4.
///
/// Which rows are shown and in what order, which badges a row wears, what the
/// sheet warns about, and what Accept does to the file. All of it is a function
/// of values or of a real `DictionaryStore` on a temp path, so none of it needs
/// a window server.
final class DictionaryPageTests: XCTestCase {

    private var root: URL!
    private var path: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wisprit-dict-page-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        path = root.appendingPathComponent("dictionary.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func seed(_ json: String) throws {
        try json.write(to: path, atomically: true, encoding: .utf8)
    }

    private func editor() -> DictionaryEditor {
        DictionaryEditor(store: DictionaryStore(path: path))
    }

    private func raw() throws -> String {
        try String(contentsOf: path, encoding: .utf8)
    }

    private func date(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)!
    }

    /// Four rows that differ in every field the sort menu offers.
    private func fixture() -> [DictionaryRow] {
        [
            DictionaryRow(term: "InsForge", hear: ["in forge"], hitCount: 3,
                          learnedAt: date("2026-08-01T09:00:00Z"),
                          lastUsed: date("2026-08-02T09:00:00Z")),
            DictionaryRow(term: "Sharique", hear: ["Shariq", "Cherie"],
                          source: "spoken_spelling", hitCount: 14,
                          learnedAt: date("2026-08-05T09:00:00Z"),
                          lastUsed: date("2026-08-07T09:00:00Z")),
            DictionaryRow(term: "Aardvark"),
            DictionaryRow(term: "Krzysztof", source: "spoken_spelling",
                          learnedAt: date("2026-08-06T09:00:00Z"),
                          isPending: true, observations: ["Christoph"]),
        ]
    }

    private func terms(_ sort: DictionarySort, search: String = "") -> [String] {
        DictionaryList.items(fixture(), search: search, sort: sort).map(\.row.term)
    }

    // MARK: - sorting

    func testEverySortOptionOrdersByTheFieldItNames() {
        XCTAssertEqual(terms(.alphabetical),
                       ["Aardvark", "InsForge", "Krzysztof", "Sharique"])
        XCTAssertEqual(terms(.mostUsed),
                       ["Sharique", "InsForge", "Aardvark", "Krzysztof"],
                       "equal (zero) hit counts fall back to file order")
        XCTAssertEqual(terms(.recentlyUsed).prefix(2).map { $0 }, ["Sharique", "InsForge"])
        XCTAssertEqual(terms(.recentlyAdded).prefix(3).map { $0 },
                       ["Krzysztof", "Sharique", "InsForge"])
    }

    /// A term that has never been used is not a term used in 1970: it sorts
    /// last, not first, whichever date column is being read.
    func testTermsWithNoDateSortLastRatherThanOldest() {
        XCTAssertEqual(terms(.recentlyUsed).suffix(2).map { $0 }, ["Aardvark", "Krzysztof"],
                       "no last_used at all, in file order")
        XCTAssertEqual(terms(.recentlyAdded).last, "Aardvark")
    }

    /// Ties break on file position, so re-sorting never shuffles equal rows and
    /// the same input always renders the same list.
    func testSortingIsStableOnFileOrder() {
        let rows = [
            DictionaryRow(term: "one"), DictionaryRow(term: "two"),
            DictionaryRow(term: "three"),
        ]
        for sort in [DictionarySort.recentlyUsed, .recentlyAdded, .mostUsed] {
            XCTAssertEqual(DictionaryList.items(rows, search: "", sort: sort).map(\.row.term),
                           ["one", "two", "three"], "\(sort)")
        }
    }

    /// `DictionaryRow.id` is the case-folded term and `dictionary.json` can hold
    /// the same term twice, so the list's identity is the file position.
    func testDuplicateTermsStillGetDistinctRowIdentities() {
        let rows = [DictionaryRow(term: "Sharique"), DictionaryRow(term: "sharique")]
        let items = DictionaryList.items(rows, search: "", sort: .alphabetical)

        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(Set(items.map(\.id)).count, 2)
    }

    // MARK: - search

    func testSearchMatchesTheTermAndTheHeardPhrases() {
        XCTAssertEqual(terms(.alphabetical, search: "shar"), ["Sharique"])
        XCTAssertEqual(terms(.alphabetical, search: "cherie"), ["Sharique"],
                       "the phrase the user remembers is the wrong one")
        XCTAssertEqual(terms(.alphabetical, search: "in forge"), ["InsForge"])
        XCTAssertEqual(terms(.alphabetical, search: "  "), terms(.alphabetical),
                       "a blank query is not a filter")
    }

    /// A pending entry has no `hear` array at all — its misrecognitions are
    /// `observations` — and searching only `hear` would make exactly the rows
    /// that need a decision unfindable.
    func testSearchReachesAPendingEntrysObservations() {
        XCTAssertEqual(terms(.alphabetical, search: "christoph"), ["Krzysztof"])
    }

    // MARK: - badges

    func testBadgesComeFromTheFieldsTheStorePersists() {
        let rows = fixture()
        XCTAssertEqual(DictionaryList.badges(for: rows[0]), [.used(3)])
        XCTAssertEqual(DictionaryList.badges(for: rows[1]), [.learned, .used(14)])
        XCTAssertEqual(DictionaryList.badges(for: rows[2]), [], "nothing true, nothing shown")
    }

    /// A quarantined entry corrects nothing and has never been used, so
    /// "Learned" and "Used" would both be lies even though `source` says
    /// `spoken_spelling`.
    func testAPendingEntryWearsOnlyThePendingBadge() {
        XCTAssertEqual(DictionaryList.badges(for: fixture()[3]), [.pending])
        XCTAssertEqual(DictionaryBadgeKind.pending.symbol, "clock")
        XCTAssertEqual(DictionaryBadgeKind.learned.symbol, "sparkles")
        XCTAssertNil(DictionaryBadgeKind.used(2).symbol)
    }

    func testHeardPhrasesCollapseAfterThree() {
        XCTAssertEqual(DictionaryList.chips(["a", "b"]).visible, ["a", "b"])
        XCTAssertEqual(DictionaryList.chips(["a", "b"]).overflow, 0)

        let many = DictionaryList.chips(["a", "b", "c", "d", "e"])
        XCTAssertEqual(many.visible, ["a", "b", "c"])
        XCTAssertEqual(many.overflow, 2)
    }

    // MARK: - the sheet

    /// The one edit consequence that cannot be undone by editing again, said
    /// before Save rather than after.
    func testOnlyARebuildPlanSurfacesTheWarning() {
        let original = DictionaryRow(term: "Sharique", hear: ["Shariq", "Cherie"],
                                     source: "spoken_spelling", hitCount: 4)

        let removal = DictionaryEdit.plan(original: original, term: "Sharique",
                                          hear: ["Shariq"])
        let rename = DictionaryEdit.plan(original: original, term: "Sharique K",
                                         hear: ["Shariq", "Cherie"])
        let append = DictionaryEdit.plan(original: original, term: "Sharique",
                                         hear: ["Shariq", "Cherie", "Sharik"])
        let unchanged = DictionaryEdit.plan(original: original, term: "Sharique",
                                            hear: ["Shariq", "Cherie"])

        XCTAssertEqual(DictionaryList.warning(for: removal), DictionaryList.rebuildWarning)
        XCTAssertEqual(DictionaryList.warning(for: rename), DictionaryList.rebuildWarning)
        XCTAssertNil(DictionaryList.warning(for: append), "a merge loses nothing")
        XCTAssertNil(DictionaryList.warning(for: unchanged))
        XCTAssertTrue(DictionaryList.rebuildWarning.contains("learn date"))
    }

    func testThePreviewShowsTheFirstPhraseRewrittenToTheTerm() {
        XCTAssertEqual(DictionaryList.preview(term: "InsForge", hear: [" in forge ", "ins forge"]),
                       "in forge  →  InsForge")
        XCTAssertNil(DictionaryList.preview(term: "InsForge", hear: []))
        XCTAssertNil(DictionaryList.preview(term: "InsForge", hear: ["   "]))
        XCTAssertNil(DictionaryList.preview(term: "  ", hear: ["in forge"]),
                     "there is nothing to rewrite to yet")
    }

    // MARK: - the cleanup banner

    func testTheBannerCountsWhatTheAuditFound() {
        let one = LearnedTermCleanup.Audit(examined: 3, suspects: [
            .init(term: "Sharhuue", hear: ["Sharik"], action: .fold(into: "Sharique")),
        ])
        let two = LearnedTermCleanup.Audit(examined: 3, suspects: one.suspects + [
            .init(term: "Shaikd", hear: ["Sharik"], action: .fold(into: "Sharique")),
        ])

        XCTAssertEqual(DictionaryList.suspectHeadline(one), "1 learned spelling looks wrong")
        XCTAssertEqual(DictionaryList.suspectHeadline(two), "2 learned spellings look wrong")
        XCTAssertTrue(LearnedTermCleanup.Audit().isClean, "a clean audit shows no banner at all")
    }

    // MARK: - empty states

    func testTheEmptyStateSaysWhichNothingThisIs() {
        XCTAssertEqual(DictionaryList.emptyTitle(hasRows: false, search: ""), "No terms yet.")
        XCTAssertEqual(DictionaryList.emptyTitle(hasRows: true, search: " zzz "),
                       "Nothing matches “zzz”.")
        XCTAssertEqual(DictionaryList.emptyTitle(hasRows: true, search: "  "), "No terms yet.",
                       "a blank query filtered nothing out")
        XCTAssertNotEqual(DictionaryList.emptyDetail(hasRows: true),
                          DictionaryList.emptyDetail(hasRows: false))
    }

    // MARK: - pending rows, end to end

    /// The page is the only surface a quarantined entry is visible from:
    /// `terms()`, the compiled corrections and the biasing list all exclude it.
    func testPendingEntriesReachTheListWithTheirObservations() throws {
        try seed("""
            {"terms": [
              {"term": "InsForge", "hear": ["in forge"]},
              {"term": "Krzysztof", "source": "spoken_spelling",
               "pending": true, "observations": ["Christoph"]}
            ]}
            """)
        let rows = editor().rows()

        XCTAssertEqual(rows.map(\.term), ["InsForge", "Krzysztof"], "file order is preserved")
        XCTAssertFalse(rows[0].isPending)
        XCTAssertTrue(rows[1].isPending)
        XCTAssertEqual(rows[1].observations, ["Christoph"])
        XCTAssertEqual(rows[1].phrases, ["Christoph"],
                       "observations are what a reader means by 'hears'")
        XCTAssertEqual(rows[1].badges, ["pending"])
    }

    /// Accept is the store's own promotion — the same transition a second
    /// sighting makes — so the entry becomes live vocabulary rather than a
    /// still-quarantined row with `hear` phrases.
    func testAcceptPromotesThroughTheStore() throws {
        try seed("""
            {"terms": [
              {"term": "Krzysztof", "source": "spoken_spelling",
               "pending": true, "observations": ["Christoph", "Christophe"]}
            ]}
            """)
        let store = DictionaryStore(path: path)
        let editor = DictionaryEditor(store: store)
        XCTAssertTrue(store.terms().isEmpty, "quarantined: not vocabulary yet")

        let pending = editor.rows()[0]
        XCTAssertTrue(editor.promote(pending))

        let after = editor.rows()
        XCTAssertEqual(after.count, 1)
        XCTAssertFalse(after[0].isPending)
        XCTAssertEqual(after[0].hear, ["Christoph", "Christophe"],
                       "observations fold into hear, in order")
        XCTAssertTrue(after[0].observations.isEmpty)
        XCTAssertEqual(store.terms(), ["Krzysztof"], "and the engine can see it now")
        XCTAssertEqual(store.applyCorrections(to: "call Christoph back"),
                       "call Krzysztof back")
        XCTAssertFalse(try raw().contains("\"pending\""))
    }

    func testPromotingALiveTermIsRefused() throws {
        try seed("""
            {"terms": [{"term": "InsForge", "hear": ["in forge"], "hit_count": 2}]}
            """)
        let editor = editor()
        let before = try raw()

        XCTAssertFalse(editor.promote(editor.rows()[0]), "there is nothing to promote")
        XCTAssertEqual(try raw(), before, "and nothing was written")
    }

    /// Dismiss is the store's own removal, not a second kind of delete.
    func testDismissRemovesOnlyTheQuarantinedEntry() throws {
        try seed("""
            {"terms": [
              {"term": "InsForge", "hear": ["in forge"]},
              {"term": "Krzysztof", "source": "spoken_spelling",
               "pending": true, "observations": ["Christoph"]}
            ]}
            """)
        let editor = editor()
        editor.delete("krzysztof")

        XCTAssertEqual(editor.rows().map(\.term), ["InsForge"])
    }

    // MARK: - through the window model

    @MainActor
    func testTheModelRepublishesAfterAcceptAndDismiss() throws {
        try seed("""
            {"terms": [
              {"term": "Krzysztof", "source": "spoken_spelling",
               "pending": true, "observations": ["Christoph"]},
              {"term": "Sharifue", "source": "spoken_spelling",
               "pending": true, "observations": ["Sharik"]}
            ]}
            """)
        let model = WispritWindowModel(
            settings: Settings(path: root.appendingPathComponent("config.json")),
            dictionary: editor())

        XCTAssertEqual(model.dictionaryRows.filter(\.isPending).map(\.term),
                       ["Krzysztof", "Sharifue"])

        XCTAssertTrue(model.promoteTerm(model.dictionaryRows[0]))
        XCTAssertEqual(model.dictionaryRows.filter(\.isPending).map(\.term), ["Sharifue"],
                       "the accepted one is live now")

        model.deleteTerm("Sharifue")
        XCTAssertEqual(model.dictionaryRows.map(\.term), ["Krzysztof"])
    }

    // MARK: - the learn-proposals banner (Phase 5)

    /// The banner's copy, as functions of values: singular vs plural, and the
    /// evidence line that shows what the recognizer actually wrote.
    func testTheProposalsBannerCopy() {
        XCTAssertEqual(DictionaryList.proposalsHeadline(1), "1 new word heard in your edits")
        XCTAssertEqual(DictionaryList.proposalsHeadline(3), "3 new words heard in your edits")

        let full = WispritWindowModel.LearnProposalRow(term: "Sharique",
                                                       heard: ["Shariq"], count: 2)
        XCTAssertEqual(DictionaryList.proposalEvidence(full), "heard “Shariq” · 2×")

        let bare = WispritWindowModel.LearnProposalRow(term: "InsForge", count: 3)
        XCTAssertEqual(DictionaryList.proposalEvidence(bare), "3×",
                       "no recorded misrecognition still renders the count")
    }

    /// The banner's button runs the checklist's fix, and nothing else: the page
    /// never edits `dictionary.json` itself.
    @MainActor
    func testTheCleanupAffordanceGoesThroughTheChecklistFixSeam() throws {
        try seed("{\"terms\": []}")
        let box = FixRecorder()
        let model = WispritWindowModel(
            settings: Settings(path: root.appendingPathComponent("config.json")),
            dictionary: editor(),
            ports: WispritWindowModel.Ports(performFix: { box.record($0) }))

        model.fix(.cleanLearnedTerms)

        XCTAssertEqual(box.kinds, [.cleanLearnedTerms])
        XCTAssertNil(SetupFixKind.cleanLearnedTerms.settingsURL,
                     "there is no System Settings pane for the user's own dictionary")
    }
}

/// `Ports.performFix` is not `Sendable`, so the recorder is main-actor bound.
@MainActor
private final class FixRecorder {
    private(set) var kinds: [SetupFixKind] = []
    func record(_ kind: SetupFixKind) { kinds.append(kind) }
}
