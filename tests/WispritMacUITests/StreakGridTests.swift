import XCTest
@testable import WispritMacUI

/// The activity grid's scale and calendar. The old fixed ramp ("4 or more is
/// the top step") painted every working day the same grey; the fitted scale has
/// to keep four visibly different steps for a heavy user and a light one.
final class StreakGridTests: XCTestCase {

    // MARK: - the scale

    func testNothingDictatedHasNoShadedLevels() {
        let scale = StreakScale.fit([0, 0, 0])
        XCTAssertEqual(scale.levelCount, 0)
        XCTAssertEqual(scale.legend, [])
        XCTAssertEqual(scale.level(for: 0), 0)
        XCTAssertEqual(scale.alpha(for: 0), StreakScale.emptyAlpha)
    }

    func testQuartilesOfTheActiveDaysBecomeTheCutPoints() {
        let scale = StreakScale.fit([0, 0, 1, 2, 3, 4, 5, 6, 7, 8])
        XCTAssertEqual(scale.bounds, [2, 4, 6])
        XCTAssertEqual(scale.peak, 8)
        XCTAssertEqual(scale.legend, ["1–2", "3–4", "5–6", "7–8"])
        XCTAssertEqual((0...8).map(scale.level(for:)), [0, 1, 1, 2, 2, 3, 3, 4, 4])
    }

    /// The owner's real distribution: most active days are well above the
    /// old ramp's "4+" ceiling, and they must not all share one shade.
    func testAHeavyUsersWorkingDaysAreToldApart() {
        let active = [1, 2, 2, 2, 3, 3, 4, 4, 4, 4, 4, 4, 4, 4, 5, 6, 6, 7, 8, 8, 9,
                      10, 12, 14, 15, 18, 18, 20, 21, 23, 24, 25, 25, 28, 29, 31, 33,
                      33, 40, 40, 41, 53]
        let scale = StreakScale.fit(active + Array(repeating: 0, count: 84))
        XCTAssertEqual(scale.levelCount, 4)
        XCTAssertEqual(Set(active.map(scale.level(for:))).count, 4)
        XCTAssertEqual(Set(active.map(StreakIntensity.step(for:))).count, 3,
                       "the old ramp collapses most of these into its top step")
    }

    func testEqualDaysAreOneShadeNotFourShadesOfTheSameNumber() {
        let scale = StreakScale.fit([3, 3, 3, 0])
        XCTAssertEqual(scale.bounds, [])
        XCTAssertEqual(scale.legend, ["1–3"], "the one shade covers every count up to the peak")
        XCTAssertEqual(scale.level(for: 3), 1)
        XCTAssertEqual(scale.alpha(for: 3), StreakScale.topAlpha)
    }

    func testShadesDarkenWithEveryLevel() {
        let scale = StreakScale.fit(Array(1...20))
        let alphas = (0...scale.levelCount).map(scale.alpha(forLevel:))
        XCTAssertEqual(alphas, alphas.sorted())
        XCTAssertEqual(Set(alphas).count, alphas.count)
        XCTAssertEqual(alphas.last, StreakScale.topAlpha)
    }

    // MARK: - the calendar

    private func calendar(firstWeekday: Int) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.firstWeekday = firstWeekday
        return calendar
    }

    /// Saturday 2026-11-07, midday UTC.
    private func now(_ calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: 7, hour: 12))!
    }

    func testTheGridStartsOnTheFirstWeekdayEighteenWeeksBack() {
        let sunday = calendar(firstWeekday: 1)
        let start = StreakCalendar.gridStart(weeks: 18, now: now(sunday), calendar: sunday)!
        XCTAssertEqual(sunday.dateComponents([.year, .month, .day], from: start),
                       DateComponents(year: 2026, month: 7, day: 5))
        XCTAssertEqual(StreakCalendar.today(weeks: 18, now: now(sunday), calendar: sunday),
                       StreakCell(week: 17, day: 6))

        let monday = calendar(firstWeekday: 2)
        let mondayStart = StreakCalendar.gridStart(weeks: 18, now: now(monday), calendar: monday)!
        XCTAssertEqual(monday.dateComponents([.month, .day], from: mondayStart),
                       DateComponents(month: 7, day: 6))
        XCTAssertEqual(StreakCalendar.today(weeks: 18, now: now(monday), calendar: monday),
                       StreakCell(week: 17, day: 5))
    }

    /// The same arithmetic `HomeModel.heatmap` uses, so a label can never name
    /// a different day than the count under it.
    func testCellDatesAgreeWithTheHeatmapItLabels() {
        let sunday = calendar(firstWeekday: 1)
        let today = now(sunday)
        let item = TranscriptItem(id: 1, ts: today.timeIntervalSince1970 - 30 * 86_400,
                                  text: "one", engine: "apple_live")
        let grid = HomeModel.heatmap([item], weeks: 18, now: today, calendar: sunday)
        let start = StreakCalendar.gridStart(weeks: 18, now: today, calendar: sunday)!

        let cell = grid.enumerated().flatMap { week, days in
            days.enumerated().compactMap { day, count in count > 0 ? StreakCell(week: week, day: day) : nil }
        }.first!
        let date = StreakCalendar.date(of: cell, gridStart: start, calendar: sunday)!
        XCTAssertEqual(date, sunday.startOfDay(for: item.date))
    }

    func testMonthNamesSitOverTheColumnsWhereMonthsStart() {
        let sunday = calendar(firstWeekday: 1)
        let labels = StreakCalendar.monthLabels(weeks: 18, now: now(sunday), calendar: sunday)
        XCTAssertEqual(labels.map(\.title), ["Jul", "Aug", "Sep", "Oct", "Nov"])
        // Week 4 starts Sun 2 Aug; week 9 starts Sun 6 Sep; week 13 Sun 4 Oct;
        // week 17 Sun 1 Nov.
        XCTAssertEqual(labels.map(\.column), [0, 4, 9, 13, 17])
    }

    func testAFirstColumnLabelThatWouldCollideIsDropped() {
        let sunday = calendar(firstWeekday: 1)
        // 2026-09-15: the grid starts Sun 23 Aug, and September starts two
        // columns later — two names that close together would overlap.
        let mid = sunday.date(from: DateComponents(year: 2026, month: 9, day: 15, hour: 12))!
        let labels = StreakCalendar.monthLabels(weeks: 4, now: mid, calendar: sunday)
        XCTAssertEqual(labels.map(\.title), ["Sep"])
    }

    func testWeekdayNamesFollowTheFirstWeekday() {
        XCTAssertEqual(StreakCalendar.weekdaySymbols(calendar: calendar(firstWeekday: 1)).first, "Sun")
        XCTAssertEqual(StreakCalendar.weekdaySymbols(calendar: calendar(firstWeekday: 2)),
                       ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"])
    }
}
