import XCTest
import WispritDictionary
import WispritMacUI
import WispritPersistence
@testable import WispritMac

/// Home's mapper and the model surface the page binds to —
/// `docs/design/ui-redesign.md` §3.3 / §6.1.
///
/// `HomeModel`'s own rules (grouping, streaks, the WPM median, search) are
/// pinned in `WispritMacUITests/HomeModelTests`, where they belong: they are
/// expressible over `WispritKit` alone. What is asserted here is the half that
/// cannot live there — turning `HistoryEntry` into the neutral shape, the
/// caption line, and the ports the page reaches the system through.
final class HomeSourceTests: XCTestCase {

    /// UTC + POSIX, so the caption line and the grid columns read the same on
    /// every machine that runs this.
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.firstWeekday = 1
        return calendar
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int,
                      _ hour: Int = 12, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day,
                                           hour: hour, minute: minute))!
    }

    private func entry(_ id: Int64, _ when: Date, _ text: String = "one two three",
                       engine: String = "apple_live",
                       durationMs: Double? = nil) -> HistoryEntry {
        HistoryEntry(id: id, ts: when.timeIntervalSince1970, text: text,
                     engine: engine, durationMs: durationMs)
    }

    // MARK: - the neutral seam

    func testEveryFieldSurvivesTheMappingAndTheWordCountIsDerived() {
        let rows = [entry(7, date(2026, 8, 9, 14, 32), "Let's ship the pill redesign",
                          durationMs: 2400)]
        let items = HomeSource.items(rows)

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].id, 7)
        XCTAssertEqual(items[0].ts, rows[0].ts)
        XCTAssertEqual(items[0].text, "Let's ship the pill redesign")
        XCTAssertEqual(items[0].engine, "apple_live")
        XCTAssertEqual(items[0].durationMs, 2400)
        XCTAssertEqual(items[0].wordCount, 5, "derived here, not per render")
    }

    func testAMissingDurationStaysMissingRatherThanBecomingZero() {
        let items = HomeSource.items([entry(1, date(2026, 8, 9))])
        XCTAssertNil(items[0].durationMs, "the Python era did not always write one")
    }

    /// The rail is the whole retained table, not the page on screen — the same
    /// numbers `HomeModel.stats` produces, reached through the mapper.
    func testTheRailIsDerivedFromEveryRowItIsGiven() {
        let now = date(2026, 8, 9, 18)
        let rows = [
            entry(1, date(2026, 8, 9, 14), "one two three four", durationMs: 2000),
            entry(2, date(2026, 8, 9, 9), "five six"),
            entry(3, date(2026, 8, 8, 9), "seven"),
        ]
        let stats = HomeSource.stats(rows, now: now, calendar: calendar)

        XCTAssertEqual(stats.lifetimeWords, 7)
        XCTAssertEqual(stats.wordsToday, 6)
        XCTAssertEqual(stats.dictationsToday, 2)
        XCTAssertEqual(stats.streakDays, 2)
        guard let wpm = stats.medianWPM else { return XCTFail("one row carries a duration") }
        XCTAssertEqual(wpm, 120, accuracy: 0.001, "4 words in 2 s")
    }

    // MARK: - the streak grid's ring

    /// Today has to be the cell `HomeModel.heatmap` actually counted today into,
    /// or the 1 pt ring lands on the wrong square. Asserted against the grid
    /// itself rather than against the arithmetic that produced it.
    func testTodaysRingSitsOnTheCellTheHeatmapCountedTodayInto() {
        let now = date(2026, 8, 9, 14)          // a Sunday
        let items = HomeSource.items([entry(1, now)])
        let grid = HomeModel.heatmap(items, weeks: 18, now: now, calendar: calendar)
        guard let cell = HomeSource.todayCell(weeks: 18, now: now, calendar: calendar) else {
            return XCTFail("an 18-week grid has a cell for today")
        }
        XCTAssertEqual(cell.week, 17, "today is always in the last column")
        XCTAssertEqual(grid[cell.week][cell.day], 1)
    }

    /// A Monday-first locale puts the same day in a different row.
    func testTheRingFollowsTheCalendarsFirstWeekday() {
        var monday = calendar
        monday.firstWeekday = 2
        let now = date(2026, 8, 9, 14)          // Sunday

        XCTAssertEqual(HomeSource.todayCell(weeks: 18, now: now, calendar: calendar)?.day, 0,
                       "Sunday is row 0 when the week starts on Sunday")
        XCTAssertEqual(HomeSource.todayCell(weeks: 18, now: now, calendar: monday)?.day, 6,
                       "and row 6 when it starts on Monday")

        let items = HomeSource.items([entry(1, now)])
        let grid = HomeModel.heatmap(items, weeks: 18, now: now, calendar: monday)
        XCTAssertEqual(grid[17][6], 1)
    }

    func testAGridWithNoWeeksHasNoRing() {
        XCTAssertNil(HomeSource.todayCell(weeks: 0, now: date(2026, 8, 9), calendar: calendar))
    }

    // MARK: - the caption line

    func testTheCaptionIsTimeWordsEngineAndDuration() {
        let item = HomeSource.items([entry(1, date(2026, 8, 9, 14, 32),
                                           "Let's ship the pill redesign before the demo "
                                           + "on Thursday",
                                           durationMs: 400)])[0]
        XCTAssertEqual(HomeSource.caption(for: item, calendar: calendar),
                       "14:32 · 10 words · apple_live · 0.4s")
    }

    func testOneWordIsSingularAndMidnightIsZeroPadded() {
        let item = HomeSource.items([entry(1, date(2026, 8, 9, 0, 5), "yes", engine: "")])[0]
        XCTAssertEqual(HomeSource.caption(for: item, calendar: calendar), "00:05 · 1 word")
    }

    /// A part that was never measured is dropped, not rendered as a zero: a row
    /// claiming "· 0.0s" is a lie about a measurement nobody took.
    func testUnknownPartsAreDroppedRatherThanRenderedEmpty() {
        let noEngine = HomeSource.items([entry(1, date(2026, 8, 9, 9), "two words",
                                               engine: "", durationMs: 0)])[0]
        XCTAssertEqual(HomeSource.caption(for: noEngine, calendar: calendar), "09:00 · 2 words")
    }

    // MARK: - the headline and the rail's copy

    func testThousandsAreGrouped() {
        XCTAssertEqual(HomeSource.decimal(14208, locale: Locale(identifier: "en_US")), "14,208")
        XCTAssertEqual(HomeSource.decimal(0, locale: Locale(identifier: "en_US")), "0")
    }

    func testTheSublineOnlyBoastsAboutAStreakThatExists() {
        let now = date(2026, 8, 9, 14)
        let none = HomeSource.stats([], now: now, calendar: calendar)
        XCTAssertEqual(HomeSource.headlineSubline(none), "words dictated")

        let streak = HomeSource.stats([entry(1, now), entry(2, date(2026, 8, 8))],
                                      now: now, calendar: calendar)
        XCTAssertEqual(HomeSource.headlineSubline(streak), "words dictated · 2-day streak")
    }

    func testTheTileSublinesAgreeWithTheirCounts() {
        let now = date(2026, 8, 9, 14)
        let one = HomeSource.stats([entry(1, now)], now: now, calendar: calendar)
        XCTAssertEqual(HomeSource.todaySubline(one), "words · 1 dictation")

        let two = HomeSource.stats([entry(1, now), entry(2, date(2026, 8, 9, 9))],
                                   now: now, calendar: calendar)
        XCTAssertEqual(HomeSource.todaySubline(two), "words · 2 dictations")

        XCTAssertEqual(HomeSource.streakSubline(1), "day")
        XCTAssertEqual(HomeSource.streakSubline(62), "days")
    }

    /// A median of 147.6 wpm is not a measurement anyone can act on to a
    /// decimal place.
    func testTheRateIsWholeWordsPerMinute() {
        XCTAssertEqual(HomeSource.rate(147.6), "148")
    }

    // MARK: - add to dictionary

    /// A transcript short enough to *be* a term is offered whole; a sentence is
    /// not, because a dictionary entry made of a sentence never matches.
    func testOnlyAShortTranscriptPrefillsTheTermField() {
        XCTAssertEqual(HomeSource.suggestedTerm("  Sharique Khatri "), "Sharique Khatri")
        XCTAssertEqual(HomeSource.suggestedTerm("one two three"), "one two three")
        XCTAssertEqual(HomeSource.suggestedTerm("Let's ship the pill redesign"), "")
        XCTAssertEqual(HomeSource.suggestedTerm("   "), "")
    }
}

/// The model surface Home binds to, driven through fake ports and a temp config
/// file — no SQLite, no pasteboard, no `~/.wisprit`.
@MainActor
final class HomePageModelTests: XCTestCase {

    private var root: URL!
    private var settings: Settings!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wisprit-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        settings = Settings(path: root.appendingPathComponent("config.json"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeModel(recents: [HistoryEntry] = [],
                           paste: ((String) -> Void)? = nil) -> WispritWindowModel {
        WispritWindowModel(
            settings: settings,
            dictionary: DictionaryEditor(store: DictionaryStore(
                path: root.appendingPathComponent("dictionary.json"))),
            ports: WispritWindowModel.Ports(recents: { Array(recents.prefix($0)) },
                                            pasteAtCursor: paste))
    }

    private func settle(_ condition: @MainActor () -> Bool) async {
        var attempts = 0
        while !condition(), attempts < 300 {
            attempts += 1
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    private func entry(_ id: Int64, _ ago: TimeInterval, _ text: String) -> HistoryEntry {
        HistoryEntry(id: id, ts: Date().timeIntervalSince1970 - ago, text: text,
                     engine: "apple_live", durationMs: 1000)
    }

    // MARK: - the page's data

    /// The page reads `homeItems`, never `history`: mapping a thousand rows per
    /// render would re-split every transcript for a word count that cannot
    /// change.
    func testTheHistoryPageIsPublishedInTheShapeHomeGroups() async {
        let model = makeModel(recents: [entry(2, 60, "two words"), entry(1, 120, "one")])
        model.loadHistory(reset: true)
        await settle { !model.homeItems.isEmpty }

        XCTAssertEqual(model.homeItems.map(\.id), [2, 1])
        XCTAssertEqual(model.homeItems.map(\.wordCount), [2, 1])
        XCTAssertEqual(model.homeItems.count, model.history.count)
    }

    /// The rail is nil until its own read lands. That is what tells "still
    /// loading" apart from "you have never dictated anything", which is the
    /// difference between a blank column and the wrong empty state.
    func testTheStatRailIsAbsentUntilItsOwnReadLands() async {
        let model = makeModel(recents: [entry(1, 60, "one two three")])
        XCTAssertNil(model.homeStats)

        model.refreshHomeStats()
        await settle { model.homeStats != nil }

        XCTAssertEqual(model.homeStats?.lifetimeWords, 3)
        XCTAssertEqual(model.homeStats?.dictationsToday, 1)
    }

    /// The rail reads the whole retained table, not the fifty rows on screen: a
    /// lifetime word count is not in the newest page.
    func testTheRailCountsBeyondOnePageOfHistory() async {
        let rows = (0..<(WispritWindowModel.historyPageSize + 10)).map {
            entry(Int64($0 + 1), Double($0) * 60, "one two")
        }
        let model = makeModel(recents: rows)
        model.loadHistory(reset: true)
        model.refreshHomeStats()
        await settle { model.homeStats != nil && !model.homeItems.isEmpty }

        XCTAssertEqual(model.homeItems.count, WispritWindowModel.historyPageSize,
                       "the list is paged")
        XCTAssertEqual(model.homeStats?.lifetimeWords, rows.count * 2,
                       "the rail is not")
    }

    func testSearchStartsEmptyAndIsNotAFilterTheModelApplies() async {
        let model = makeModel(recents: [entry(1, 60, "ship the pill"), entry(2, 120, "unrelated")])
        XCTAssertEqual(model.historySearch, "")
        model.loadHistory(reset: true)
        await settle { !model.homeItems.isEmpty }

        model.historySearch = "PILL"
        XCTAssertEqual(model.homeItems.count, 2, "the model publishes rows, the page filters")
        XCTAssertEqual(HomeModel.filter(model.homeItems, query: model.historySearch).map(\.id), [1])
    }

    // MARK: - the row actions

    /// Absent, not disabled (§3.3's rule for `trash`, and the same reasoning): a
    /// paste button that cannot paste is worse than no button.
    func testThePasteActionIsAbsentWhenNothingCanPerformIt() {
        XCTAssertFalse(makeModel().canPasteAtCursor)
    }

    func testThePasteActionForwardsTheRowsOwnText() {
        let box = TextBox()
        let model = makeModel(paste: { box.record($0) })
        XCTAssertTrue(model.canPasteAtCursor)

        model.pasteAtCursor("Add Sharique to the invite.")
        XCTAssertEqual(box.values, ["Add Sharique to the invite."])
    }

    /// The insertion path swaps the clipboard and posts ⌘V, and mid-utterance
    /// the session is doing exactly that with the words the user just spoke.
    func testPastingIsRefusedWhileADictationIsInFlight() {
        let box = TextBox()
        let model = makeModel(paste: { box.record($0) })

        model.noteSessionState(.recording)
        model.pasteAtCursor("nope")
        XCTAssertTrue(box.values.isEmpty)

        model.noteSessionState(.idle)
        model.pasteAtCursor("now")
        XCTAssertEqual(box.values, ["now"])
    }

    func testAnEmptyRowIsNeverPasted() {
        let box = TextBox()
        let model = makeModel(paste: { box.record($0) })
        model.pasteAtCursor("")
        XCTAssertTrue(box.values.isEmpty)
    }

    /// The `text.badge.plus` action goes through the same editor the Dictionary
    /// page uses, so a term added from a transcript is indistinguishable from
    /// one added there.
    func testAddingATermFromARowWritesItToTheDictionary() {
        let model = makeModel()
        XCTAssertTrue(model.saveTerm(original: nil, term: "Sharique", hear: []))
        XCTAssertEqual(model.dictionaryRows.map(\.term), ["Sharique"])
    }
}

/// A main-actor recorder for the paste port — the port is main-actor, like
/// `performFix`, so no locking is needed.
@MainActor
private final class TextBox {
    private(set) var values: [String] = []
    func record(_ value: String) { values.append(value) }
}
