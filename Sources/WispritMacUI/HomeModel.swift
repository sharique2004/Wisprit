import Foundation

/// One committed transcript, as Home needs it — `docs/design/ui-redesign.md`
/// §3.3 and §6.1.
///
/// This is the neutral seam. `WispritMacUI` depends on `WispritKit` only, so it
/// cannot name `HistoryEntry`; `WispritMac/Window/` maps history rows into this
/// on the way in. The mapping is trivial and the payoff is that every grouping,
/// streak and rate rule below is testable with no disk and no SQLite.
public struct TranscriptItem: Identifiable, Equatable, Sendable {
    public var id: Int64
    /// Unix seconds.
    public var ts: Double
    public var text: String
    /// `apple_live`, `auto`, … — shown verbatim in the caption line.
    public var engine: String
    /// Hold duration. Optional because the Python era did not always write it.
    public var durationMs: Double?
    /// Derived from `text`; stored so grouping and the rate median do not
    /// re-split the same string once per row per render.
    public var wordCount: Int

    public init(id: Int64, ts: Double, text: String, engine: String, durationMs: Double? = nil) {
        self.id = id
        self.ts = ts
        self.text = text
        self.engine = engine
        self.durationMs = durationMs
        self.wordCount = HomeModel.wordCount(text)
    }

    public var date: Date { Date(timeIntervalSince1970: ts) }
}

/// A day's worth of transcripts, newest day first.
public struct DayGroup: Identifiable, Equatable, Sendable {
    /// Start of the day, in the supplied calendar — also the identity.
    public var id: Date
    /// `Today`, `Yesterday`, then `EEEE, d MMM`.
    public var title: String
    public var items: [TranscriptItem]
    public var wordCount: Int

    public init(id: Date, title: String, items: [TranscriptItem]) {
        self.id = id
        self.title = title
        self.items = items
        self.wordCount = items.reduce(0) { $0 + $1.wordCount }
    }
}

/// The right-hand stat rail (§3.3): three tiles and a streak grid.
public struct HomeStats: Equatable, Sendable {
    public var lifetimeWords: Int
    public var wordsToday: Int
    public var dictationsToday: Int
    /// Median words per minute over the recent sample. Nil when no row carries
    /// a usable duration — a rate tile with no rate shows nothing, never a 0.
    public var medianWPM: Double?
    public var streakDays: Int
    /// Weeks × 7 days, oldest week first.
    public var heatmap: [[Int]]
    public var heatmapWeeks: Int
}

/// Home's pure logic. Every entry point takes an explicit `now` and `calendar`
/// and never reaches for `Date()` or `.current` — the same discipline
/// `MetricsSummary.summarize(_:window:now:)` uses, and the only reason
/// "Today/Yesterday" and streaks are testable at all.
public enum HomeModel {
    /// 18 weeks × 7 days = the §3.3 grid.
    public static let defaultHeatmapWeeks = 18
    /// "148 wpm (median, last 30)".
    public static let defaultRateSample = 30

    /// `text.split(whereSeparator: \.isWhitespace).count`, per §3.3.
    public static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    // MARK: - grouping

    /// Day groups, newest day first, newest row first inside each day.
    public static func groups(_ items: [TranscriptItem],
                              now: Date,
                              calendar: Calendar) -> [DayGroup] {
        guard !items.isEmpty else { return [] }
        var buckets: [Date: [TranscriptItem]] = [:]
        for item in items {
            let day = calendar.startOfDay(for: item.date)
            buckets[day, default: []].append(item)
        }
        return buckets.keys.sorted(by: >).map { day in
            DayGroup(id: day,
                     title: title(for: day, now: now, calendar: calendar),
                     items: buckets[day, default: []].sorted { $0.ts > $1.ts })
        }
    }

    /// `Today` / `Yesterday` / `EEEE, d MMM`. The formatter takes its locale and
    /// time zone from the calendar, so a test can pin the string.
    public static func title(for day: Date, now: Date, calendar: Calendar) -> String {
        let today = calendar.startOfDay(for: now)
        if let days = calendar.dateComponents([.day], from: day, to: today).day {
            if days == 0 { return "Today" }
            if days == 1 { return "Yesterday" }
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = calendar.locale ?? Locale.autoupdatingCurrent
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "EEEE, d MMM"
        return formatter.string(from: day)
    }

    // MARK: - streak

    /// Consecutive days with at least one dictation, counting back from today —
    /// or from yesterday when today has none yet, so a streak does not read as
    /// broken at 00:01 on a day the user has simply not started.
    public static func streak(_ items: [TranscriptItem],
                              now: Date,
                              calendar: Calendar) -> Int {
        guard !items.isEmpty else { return 0 }
        let days = Set(items.map { calendar.startOfDay(for: $0.date) })
        let today = calendar.startOfDay(for: now)
        var cursor = today
        if !days.contains(cursor) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today),
                  days.contains(yesterday) else { return 0 }
            cursor = yesterday
        }
        var count = 0
        while days.contains(cursor) {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return count
    }

    // MARK: - heatmap

    /// `weeks` × 7 counts, oldest week first, each week starting on the
    /// calendar's `firstWeekday`. The last column is the week containing `now`,
    /// so today always sits in the rightmost column (§3.3's 1 pt ring).
    public static func heatmap(_ items: [TranscriptItem],
                               weeks: Int = defaultHeatmapWeeks,
                               now: Date,
                               calendar: Calendar) -> [[Int]] {
        let weekCount = max(0, weeks)
        guard weekCount > 0 else { return [] }
        var grid = Array(repeating: Array(repeating: 0, count: 7), count: weekCount)
        guard let start = startOfWeek(containing: now, calendar: calendar),
              let gridStart = calendar.date(byAdding: .day, value: -7 * (weekCount - 1), to: start)
        else { return grid }

        for item in items {
            let day = calendar.startOfDay(for: item.date)
            guard let offset = calendar.dateComponents([.day], from: gridStart, to: day).day,
                  offset >= 0, offset < weekCount * 7 else { continue }
            grid[offset / 7][offset % 7] += 1
        }
        return grid
    }

    private static func startOfWeek(containing date: Date, calendar: Calendar) -> Date? {
        let day = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: day)
        let delta = (weekday - calendar.firstWeekday + 7) % 7
        return calendar.date(byAdding: .day, value: -delta, to: day)
    }

    // MARK: - speaking rate

    /// Median words per minute over the most recent `sample` rows that carry a
    /// usable duration. Self-relative by construction: there is no population to
    /// compare against and there never will be (§3.5).
    public static func medianWPM(_ items: [TranscriptItem],
                                 sample: Int = defaultRateSample) -> Double? {
        let rates = items
            .sorted { $0.ts > $1.ts }
            .prefix(max(0, sample))
            .compactMap { item -> Double? in
                guard let ms = item.durationMs, ms > 0, item.wordCount > 0 else { return nil }
                return Double(item.wordCount) / (ms / 60_000.0)
            }
            .sorted()
        guard !rates.isEmpty else { return nil }
        let mid = rates.count / 2
        return rates.count % 2 == 1 ? rates[mid] : (rates[mid - 1] + rates[mid]) / 2
    }

    // MARK: - search

    /// Case- and diacritic-insensitive substring match over the transcript. An
    /// empty or whitespace-only query is not a filter.
    public static func filter(_ items: [TranscriptItem], query: String) -> [TranscriptItem] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return items }
        return items.filter {
            $0.text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    // MARK: - the stat rail

    public static func stats(_ items: [TranscriptItem],
                             now: Date,
                             calendar: Calendar,
                             weeks: Int = defaultHeatmapWeeks,
                             rateSample: Int = defaultRateSample) -> HomeStats {
        let today = calendar.startOfDay(for: now)
        let todays = items.filter { calendar.startOfDay(for: $0.date) == today }
        return HomeStats(
            lifetimeWords: items.reduce(0) { $0 + $1.wordCount },
            wordsToday: todays.reduce(0) { $0 + $1.wordCount },
            dictationsToday: todays.count,
            medianWPM: medianWPM(items, sample: rateSample),
            streakDays: streak(items, now: now, calendar: calendar),
            heatmap: heatmap(items, weeks: weeks, now: now, calendar: calendar),
            heatmapWeeks: max(0, weeks))
    }
}
