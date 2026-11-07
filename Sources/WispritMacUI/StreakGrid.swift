import Foundation
#if canImport(SwiftUI)
import SwiftUI
#endif

/// The streak grid's original fixed ramp — `docs/design/ui-redesign.md` §3.3.
///
/// Kept for its callers; the grid itself now draws with `StreakScale`, because
/// a fixed "4 or more is the top step" ramp painted every working day the same
/// grey once a user dictated more than three times a day — 126 near-identical
/// squares. Four steps of `ink`, never orange: a heatmap is history, not live
/// audio (§1.6).
public enum StreakIntensity {
    /// α for steps 0…3. Step 0 is an empty cell, still visible — an invisible
    /// zero would make a sparse month look like a missing month.
    public static let alphas: [Double] = [0.08, 0.22, 0.45, 0.75]

    /// Four buckets: none, one, a couple, a working day.
    public static func step(for count: Int) -> Int {
        switch count {
        case ..<1: return 0
        case 1: return 1
        case 2...3: return 2
        default: return 3
        }
    }

    public static func alpha(for count: Int) -> Double {
        alphas[step(for: count)]
    }
}

// MARK: - the scale

/// An intensity scale fitted to the days actually on the grid.
///
/// The cut points are the quartiles of the *active* days (nearest rank), so
/// each shade covers roughly a quarter of the days the user dictated — a light
/// user and a heavy one both get a grid with four visibly different steps.
/// Duplicate cut points collapse, and a cut point at the busiest day is
/// dropped, so a grid where every active day had the same count is one shade,
/// not four shades of the same number. Pure, so the legend is testable.
public struct StreakScale: Equatable, Sendable {
    /// Inclusive upper bound of each level but the last, ascending and unique.
    /// Level 0 is "no dictation"; level `bounds.count + 1` is open-ended.
    public let bounds: [Int]
    /// The busiest day on the grid — the top level's upper end.
    public let peak: Int

    public static let maxLevels = 4

    public init(bounds: [Int], peak: Int) {
        self.bounds = bounds
        self.peak = peak
    }

    public static func fit(_ counts: [Int]) -> StreakScale {
        let active = counts.filter { $0 > 0 }.sorted()
        guard let peak = active.last else { return StreakScale(bounds: [], peak: 0) }
        var bounds: [Int] = []
        for quantile in [0.25, 0.5, 0.75] {
            let rank = max(1, Int((quantile * Double(active.count)).rounded(.up)))
            let value = active[min(active.count, rank) - 1]
            if value < peak, bounds.last.map({ value > $0 }) ?? true {
                bounds.append(value)
            }
        }
        return StreakScale(bounds: bounds, peak: peak)
    }

    /// How many shaded levels this grid uses (0 when nothing was dictated).
    public var levelCount: Int { peak > 0 ? bounds.count + 1 : 0 }

    /// 0 for a day with no dictation, else 1…`levelCount`.
    public func level(for count: Int) -> Int {
        guard count > 0, peak > 0 else { return 0 }
        for (index, bound) in bounds.enumerated() where count <= bound {
            return index + 1
        }
        return bounds.count + 1
    }

    /// The range each shaded level covers, lightest first: "1–4", "5–10",
    /// "11–25", "26–53". A level that is one number is that number.
    public var legend: [String] {
        guard peak > 0 else { return [] }
        var out: [String] = []
        var lower = 1
        for upper in bounds + [peak] {
            out.append(lower == upper ? "\(upper)" : "\(lower)–\(upper)")
            lower = upper + 1
        }
        return out
    }

    /// Opacity of `ink` for a level. Level 0 is a visible empty cell; the
    /// shaded levels spread evenly up to near-solid, however many there are.
    public func alpha(forLevel level: Int) -> Double {
        guard level > 0, levelCount > 0 else { return StreakScale.emptyAlpha }
        guard levelCount > 1 else { return StreakScale.topAlpha }
        let step = (StreakScale.topAlpha - StreakScale.firstAlpha) / Double(levelCount - 1)
        return StreakScale.firstAlpha + Double(min(level, levelCount) - 1) * step
    }

    public func alpha(for count: Int) -> Double { alpha(forLevel: level(for: count)) }

    public static let emptyAlpha = 0.07
    public static let firstAlpha = 0.24
    public static let topAlpha = 0.92
}

// MARK: - the calendar under the grid

/// A cell of the grid, as (week column, day row).
public struct StreakCell: Equatable, Hashable, Sendable {
    public var week: Int
    public var day: Int

    public init(week: Int, day: Int) {
        self.week = week
        self.day = day
    }
}

/// A month name over the column where that month starts.
public struct StreakMonthLabel: Equatable, Sendable {
    public var column: Int
    public var title: String

    public init(column: Int, title: String) {
        self.column = column
        self.title = title
    }
}

/// Dates for `HomeModel.heatmap`'s grid: the same arithmetic, so a label can
/// never name a different day than the count under it. The grid's last column
/// is the week containing `now`, each column starts on the calendar's
/// `firstWeekday`, and rows run from that weekday on.
public enum StreakCalendar {
    /// The first day of the oldest column.
    public static func gridStart(weeks: Int, now: Date, calendar: Calendar) -> Date? {
        guard weeks > 0 else { return nil }
        let day = calendar.startOfDay(for: now)
        let weekday = calendar.component(.weekday, from: day)
        let delta = (weekday - calendar.firstWeekday + 7) % 7
        guard let thisWeek = calendar.date(byAdding: .day, value: -delta, to: day) else { return nil }
        return calendar.date(byAdding: .day, value: -7 * (weeks - 1), to: thisWeek)
    }

    public static func date(of cell: StreakCell, gridStart: Date, calendar: Calendar) -> Date? {
        calendar.date(byAdding: .day, value: cell.week * 7 + cell.day, to: gridStart)
    }

    /// Where today sits: always the last column, on its weekday's row.
    public static func today(weeks: Int, now: Date, calendar: Calendar) -> StreakCell? {
        guard weeks > 0 else { return nil }
        let weekday = calendar.component(.weekday, from: now)
        return StreakCell(week: weeks - 1, day: (weekday - calendar.firstWeekday + 7) % 7)
    }

    /// A month name over every column whose first day starts a new month. The
    /// first column is labelled only when the next label is at least three
    /// columns away, so two names never collide over the left edge.
    public static func monthLabels(weeks: Int, now: Date, calendar: Calendar) -> [StreakMonthLabel] {
        guard let start = gridStart(weeks: weeks, now: now, calendar: calendar) else { return [] }
        return monthLabels(weeks: weeks, gridStart: start, calendar: calendar)
    }

    public static func monthLabels(weeks: Int, gridStart start: Date,
                                   calendar: Calendar) -> [StreakMonthLabel] {
        let symbols = calendar.shortMonthSymbols
        var labels: [StreakMonthLabel] = []
        var previousMonth: Int?
        for week in 0..<weeks {
            guard let first = calendar.date(byAdding: .day, value: week * 7, to: start) else { continue }
            let month = calendar.component(.month, from: first)
            if month != previousMonth {
                labels.append(StreakMonthLabel(column: week, title: symbols[(month - 1) % symbols.count]))
            }
            previousMonth = month
        }
        if labels.count > 1, labels[0].column == 0, labels[1].column < 3 {
            labels.removeFirst()
        }
        return labels
    }

    /// Short weekday names, one per row, starting at `firstWeekday`.
    public static func weekdaySymbols(calendar: Calendar) -> [String] {
        let symbols = calendar.shortWeekdaySymbols
        return (0..<7).map { symbols[(calendar.firstWeekday - 1 + $0) % 7] }
    }
}

#if canImport(SwiftUI)
/// The activity grid: weeks × 7 days, oldest week on the left.
///
/// Legible by construction rather than by squinting: shades come from a
/// `StreakScale` fitted to these days (with its ranges printed in the legend),
/// month names sit over the columns where months start, alternate weekday names
/// run down the left, days after today are not drawn at all, and today wears a
/// ring. Every cell carries a tooltip with its date and count.
public struct StreakGrid: View {
    public struct Labels: Sendable {
        public var months: [StreakMonthLabel]
        public var weekdays: [String]
        /// Tooltip text per cell, keyed by cell. Missing → no tooltip.
        public var tooltips: [StreakCell: String]

        public init(months: [StreakMonthLabel], weekdays: [String],
                    tooltips: [StreakCell: String] = [:]) {
            self.months = months
            self.weekdays = weekdays
            self.tooltips = tooltips
        }
    }

    /// Weeks × 7 counts, oldest week first — `HomeModel.heatmap`.
    private let weeks: [[Int]]
    private let today: StreakCell?
    private let labels: Labels?
    private let cell: Double
    private let gap: Double
    private let scale: StreakScale

    public static let cell: Double = 8
    public static let gap: Double = 2

    /// The compact form Home used: no labels, 8 pt cells.
    public init(weeks: [[Int]], today: (week: Int, day: Int)? = nil) {
        self.init(weeks: weeks,
                  today: today.map { StreakCell(week: $0.week, day: $0.day) },
                  labels: nil, cell: StreakGrid.cell, gap: StreakGrid.gap)
    }

    public init(weeks: [[Int]], today: StreakCell?, labels: Labels?,
                cell: Double, gap: Double) {
        self.weeks = weeks
        self.today = today
        self.labels = labels
        self.cell = cell
        self.gap = gap
        self.scale = StreakScale.fit(weeks.flatMap { $0 })
    }

    public static func size(weeks: Int) -> CGSize {
        CGSize(width: Double(weeks) * cell + Double(max(0, weeks - 1)) * gap,
               height: 7 * cell + 6 * gap)
    }

    private var pitch: Double { cell + gap }
    private var gutter: Double { labels == nil ? 0 : 30 }
    private var header: Double { labels == nil ? 0 : 18 }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let labels {
                ZStack(alignment: .topLeading) {
                    ForEach(labels.months, id: \.column) { month in
                        Text(month.title)
                            .font(Theme.font(Theme.Role.caption))
                            .foregroundStyle(Theme.inkTertiary)
                            .fixedSize()
                            .offset(x: gutter + Double(month.column) * pitch)
                    }
                }
                .frame(height: header, alignment: .topLeading)
            }
            HStack(alignment: .top, spacing: 0) {
                if let labels {
                    VStack(alignment: .leading, spacing: gap) {
                        ForEach(Array(labels.weekdays.enumerated()), id: \.offset) { row, name in
                            Text(row % 2 == 1 ? name : "")
                                .font(Theme.font(Theme.Role.caption))
                                .foregroundStyle(Theme.inkTertiary)
                                .frame(height: cell, alignment: .leading)
                                .fixedSize()
                        }
                    }
                    .frame(width: gutter, alignment: .leading)
                }
                HStack(alignment: .top, spacing: gap) {
                    ForEach(Array(weeks.enumerated()), id: \.offset) { weekIndex, days in
                        VStack(spacing: gap) {
                            ForEach(Array(days.enumerated()), id: \.offset) { dayIndex, count in
                                square(StreakCell(week: weekIndex, day: dayIndex), count: count)
                            }
                        }
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func square(_ position: StreakCell, count: Int) -> some View {
        let radius = max(2, cell / 5)
        if isFuture(position) {
            Color.clear.frame(width: cell, height: cell)
        } else {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Theme.ink.opacity(scale.alpha(for: count)))
                .frame(width: cell, height: cell)
                .overlay {
                    if position == today {
                        RoundedRectangle(cornerRadius: radius + 1, style: .continuous)
                            .strokeBorder(Theme.ink, lineWidth: labels == nil ? 1 : 1.5)
                            .padding(labels == nil ? 0 : -2.5)
                    }
                }
                .help(labels?.tooltips[position] ?? "")
        }
    }

    /// Days after today in the current week: not a quiet day, not a day yet.
    private func isFuture(_ position: StreakCell) -> Bool {
        guard let today else { return false }
        return position.week > today.week
            || (position.week == today.week && position.day > today.day)
    }
}

/// The scale, printed: "Less ▢ ▢ ▢ ▢ ▢ More" with the range each shade covers.
public struct StreakLegend: View {
    private let scale: StreakScale
    private let cell: Double

    public init(scale: StreakScale, cell: Double = 12) {
        self.scale = scale
        self.cell = cell
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Dictations a day")
                .font(Theme.font(Theme.Role.captionEmph))
                .tracking(Theme.Role.captionEmph.tracking)
                .foregroundStyle(Theme.inkTertiary)
            ForEach(Array(scale.legend.enumerated().reversed()), id: \.offset) { index, range in
                row(alpha: scale.alpha(forLevel: index + 1), text: range)
            }
            row(alpha: StreakScale.emptyAlpha, text: "None")
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(Theme.ink, lineWidth: 1.5)
                    .frame(width: cell, height: cell)
                Text("Today")
                    .font(Theme.font(Theme.Role.caption))
                    .foregroundStyle(Theme.inkSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func row(alpha: Double, text: String) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Theme.ink.opacity(alpha))
                .frame(width: cell, height: cell)
            Text(text)
                .font(Theme.font(Theme.Role.caption))
                .foregroundStyle(Theme.inkSecondary)
                .monospacedDigit()
        }
    }
}
#endif
