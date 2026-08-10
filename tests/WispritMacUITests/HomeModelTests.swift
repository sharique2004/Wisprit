import XCTest
@testable import WispritMacUI

/// Home's pure logic — `ui-redesign.md` §3.3 / §6.1.
///
/// Every entry point takes an explicit `now` and `calendar`, which is the only
/// reason "Today/Yesterday" and streaks can be asserted at all. No disk, no
/// SQLite, no `Date()`.
final class HomeModelTests: XCTestCase {

    /// UTC + POSIX, so the day boundaries and the `EEEE, d MMM` string are the
    /// same on every machine that runs this.
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

    private func item(_ id: Int64, _ when: Date, _ text: String = "one two three",
                      durationMs: Double? = nil) -> TranscriptItem {
        TranscriptItem(id: id, ts: when.timeIntervalSince1970, text: text,
                       engine: "apple_live", durationMs: durationMs)
    }

    // MARK: - word count

    func testWordCountSplitsOnAnyWhitespace() {
        XCTAssertEqual(HomeModel.wordCount("Let's ship the pill redesign"), 5)
        XCTAssertEqual(HomeModel.wordCount("  spaced \n out  "), 2)
        XCTAssertEqual(HomeModel.wordCount(""), 0)
        XCTAssertEqual(TranscriptItem(id: 1, ts: 0, text: "two words", engine: "auto").wordCount, 2)
    }

    // MARK: - grouping

    func testGroupsAreNewestFirstAndLabelled() {
        let now = date(2026, 8, 9, 14)
        let items = [
            item(1, date(2026, 8, 9, 14, 32)),
            item(2, date(2026, 8, 9, 14, 28)),
            item(3, date(2026, 8, 8, 9)),
            item(4, date(2026, 8, 3, 9)),
        ]
        let groups = HomeModel.groups(items, now: now, calendar: calendar)
        XCTAssertEqual(groups.map(\.title), ["Today", "Yesterday", "Monday, 3 Aug"])
        XCTAssertEqual(groups[0].items.map(\.id), [1, 2], "newest row first inside a day")
        XCTAssertEqual(groups[0].wordCount, 6)
    }

    /// The one that midnight breaks: 23:59 and 00:01 are different days even
    /// though they are two minutes apart.
    func testGroupingSplitsAcrossMidnight() {
        let now = date(2026, 8, 9, 12)
        let items = [
            item(1, date(2026, 8, 9, 0, 1)),
            item(2, date(2026, 8, 8, 23, 59)),
        ]
        let groups = HomeModel.groups(items, now: now, calendar: calendar)
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups.map(\.title), ["Today", "Yesterday"])
    }

    func testEmptyHistoryHasNoGroups() {
        XCTAssertTrue(HomeModel.groups([], now: date(2026, 8, 9), calendar: calendar).isEmpty)
    }

    // MARK: - streak

    func testStreakCountsBackFromToday() {
        let now = date(2026, 8, 9, 14)
        let items = (0..<5).map { item(Int64($0), date(2026, 8, 9 - $0)) }
        XCTAssertEqual(HomeModel.streak(items, now: now, calendar: calendar), 5)
    }

    /// A gap ends the streak; older runs do not count toward it.
    func testStreakStopsAtTheFirstGap() {
        let now = date(2026, 8, 9, 14)
        let items = [
            item(1, date(2026, 8, 9)),
            item(2, date(2026, 8, 8)),
            // 7 Aug missing
            item(3, date(2026, 8, 6)),
            item(4, date(2026, 8, 5)),
        ]
        XCTAssertEqual(HomeModel.streak(items, now: now, calendar: calendar), 2)
    }

    /// A streak must not read as broken at 00:01 on a day the user has simply
    /// not started yet.
    func testStreakSurvivesADayNotStarted() {
        let now = date(2026, 8, 9, 0, 1)
        let items = [item(1, date(2026, 8, 8)), item(2, date(2026, 8, 7))]
        XCTAssertEqual(HomeModel.streak(items, now: now, calendar: calendar), 2)
    }

    func testStreakIsZeroAfterAMissedDay() {
        let now = date(2026, 8, 9, 14)
        let items = [item(1, date(2026, 8, 7)), item(2, date(2026, 8, 6))]
        XCTAssertEqual(HomeModel.streak(items, now: now, calendar: calendar), 0)
        XCTAssertEqual(HomeModel.streak([], now: now, calendar: calendar), 0)
    }

    // MARK: - heatmap

    func testHeatmapIsWeeksBySevenWithTodayInTheLastColumn() {
        let now = date(2026, 8, 9, 14)   // a Sunday: first weekday, so day index 0
        let grid = HomeModel.heatmap([item(1, now), item(2, now)],
                                     weeks: 18, now: now, calendar: calendar)
        XCTAssertEqual(grid.count, 18)
        XCTAssertTrue(grid.allSatisfy { $0.count == 7 })
        XCTAssertEqual(grid[17][0], 2, "both of today's dictations land in one cell")
        XCTAssertEqual(grid.dropLast().flatMap { $0 }.reduce(0, +), 0)
    }

    func testHeatmapIgnoresRowsOlderThanTheGrid() {
        let now = date(2026, 8, 9, 14)
        let ancient = item(1, date(2025, 1, 1))
        let grid = HomeModel.heatmap([ancient], weeks: 18, now: now, calendar: calendar)
        XCTAssertEqual(grid.flatMap { $0 }.reduce(0, +), 0, "out of window, not clamped into it")
    }

    // MARK: - speaking rate

    func testMedianWPMUsesDurationAndIgnoresRowsWithout() {
        let now = date(2026, 8, 9, 14)
        let items = [
            // 6 words in 60 s = 6 wpm, 3 words in 60 s = 3, 9 words in 60 s = 9
            item(1, now, "a b c d e f", durationMs: 60_000),
            item(2, now, "a b c", durationMs: 60_000),
            item(3, now, "a b c d e f g h i", durationMs: 60_000),
            item(4, now, "no duration on this one"),
            item(5, now, "zero duration", durationMs: 0),
        ]
        XCTAssertEqual(HomeModel.medianWPM(items) ?? 0, 6, accuracy: 0.0001)
    }

    func testMedianWPMAveragesTheMiddlePairAndRefusesToInventOne() {
        let now = date(2026, 8, 9, 14)
        let items = [
            item(1, now, "a b c d", durationMs: 60_000),   // 4
            item(2, now, "a b c d e f", durationMs: 60_000), // 6
        ]
        XCTAssertEqual(HomeModel.medianWPM(items) ?? 0, 5, accuracy: 0.0001)
        XCTAssertNil(HomeModel.medianWPM([]), "no rate is nil, never a zero")
        XCTAssertNil(HomeModel.medianWPM([item(9, now, "no timing")]))
    }

    func testMedianWPMHonoursTheSampleWindow() {
        let now = date(2026, 8, 9, 14)
        let recent = item(1, now, "a b c d e f g h i j", durationMs: 60_000)   // 10
        let old = item(2, date(2026, 1, 1), "a", durationMs: 60_000)           // 1
        XCTAssertEqual(HomeModel.medianWPM([recent, old], sample: 1) ?? 0, 10, accuracy: 0.0001)
    }

    // MARK: - search

    func testFilterIsCaseAndDiacriticInsensitiveAndAnEmptyQueryIsNoFilter() {
        let now = date(2026, 8, 9, 14)
        let items = [
            item(1, now, "Let's ship the Pill redesign"),
            item(2, now, "Add Sharique to the invite"),
            item(3, now, "café notes"),
        ]
        XCTAssertEqual(HomeModel.filter(items, query: "pill").map(\.id), [1])
        XCTAssertEqual(HomeModel.filter(items, query: "cafe").map(\.id), [3])
        XCTAssertEqual(HomeModel.filter(items, query: "   ").map(\.id), [1, 2, 3])
        XCTAssertTrue(HomeModel.filter(items, query: "nothing here").isEmpty)
    }

    // MARK: - the stat rail

    func testStatsRail() {
        let now = date(2026, 8, 9, 14)
        let items = [
            item(1, date(2026, 8, 9, 10), "one two three four", durationMs: 60_000),
            item(2, date(2026, 8, 9, 11), "five six", durationMs: 60_000),
            item(3, date(2026, 8, 8, 11), "yesterday words here"),
        ]
        let stats = HomeModel.stats(items, now: now, calendar: calendar)
        XCTAssertEqual(stats.lifetimeWords, 9)
        XCTAssertEqual(stats.wordsToday, 6)
        XCTAssertEqual(stats.dictationsToday, 2)
        XCTAssertEqual(stats.streakDays, 2)
        XCTAssertEqual(stats.medianWPM ?? 0, 3, accuracy: 0.0001)
        XCTAssertEqual(stats.heatmap.count, HomeModel.defaultHeatmapWeeks)
    }
}
