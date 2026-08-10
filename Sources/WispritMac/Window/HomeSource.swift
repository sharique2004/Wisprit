#if os(macOS)
import Foundation
import WispritMacUI
import WispritPersistence

/// Home's mapper — `docs/design/ui-redesign.md` §3.3 / §6.1.
///
/// `WispritMacUI` depends on `WispritKit` only, so `HomeModel` cannot name
/// `HistoryEntry`. This is the seam that lets it stay that way: everything the
/// page needs from persistence is turned into `TranscriptItem` here, on the
/// `WispritMac` side of the wall, and every rule about grouping, streaks and
/// rates stays in the pure model where it is testable with no disk and no
/// SQLite.
///
/// The formatters live here for the same reason `HomeModel` takes an explicit
/// `now` and `calendar`: a caption line that reads "14:32" on one machine and
/// "2:32 PM" on another is not a thing a test can pin, and the caption line is
/// the row's only metadata.
enum HomeSource {

    // MARK: - persistence → the neutral seam

    /// `[HistoryEntry]` → `[TranscriptItem]`, newest first (the order
    /// `History.recent` already returns). Word counts are derived once, here,
    /// rather than once per row per render.
    static func items(_ entries: [HistoryEntry]) -> [TranscriptItem] {
        entries.map {
            TranscriptItem(id: $0.id, ts: $0.ts, text: $0.text,
                           engine: $0.engine, durationMs: $0.durationMs)
        }
    }

    /// The right-hand rail. Reads the whole retained table rather than the
    /// page on screen: a lifetime word count and an 18-week streak are not
    /// derivable from the newest fifty rows.
    static func stats(_ entries: [HistoryEntry],
                      now: Date,
                      calendar: Calendar) -> HomeStats {
        HomeModel.stats(items(entries), now: now, calendar: calendar)
    }

    // MARK: - the streak grid

    /// Where today sits in `HomeModel.heatmap`'s grid, for the 1 pt ring.
    ///
    /// `heatmap` builds its columns backwards from the week containing `now`,
    /// so today is always in the last column; the row is the day's distance
    /// from the calendar's `firstWeekday`, which is what makes this correct on
    /// a Monday-first locale as well as a Sunday-first one.
    struct GridCell: Equatable {
        var week: Int
        var day: Int
    }

    static func todayCell(weeks: Int, now: Date, calendar: Calendar) -> GridCell? {
        guard weeks > 0 else { return nil }
        let weekday = calendar.component(.weekday, from: now)
        return GridCell(week: weeks - 1,
                        day: (weekday - calendar.firstWeekday + 7) % 7)
    }

    // MARK: - row caption

    /// `HH:mm · N words · engine · D.Ds` (§3.3).
    ///
    /// Parts that are not known are dropped rather than rendered empty: the
    /// Python era did not always write a duration, and a row that says
    /// "· 0.0s" is a lie about a measurement that was never taken.
    static func caption(for item: TranscriptItem, calendar: Calendar) -> String {
        var parts = [time(item.date, calendar: calendar), words(item.wordCount)]
        if !item.engine.isEmpty { parts.append(item.engine) }
        if let ms = item.durationMs, ms > 0 { parts.append(duration(ms)) }
        return parts.joined(separator: " · ")
    }

    /// 24-hour clock, from the calendar's components — no `DateFormatter`, so
    /// this costs nothing per row and reads the same on every machine.
    static func time(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    static func words(_ count: Int) -> String {
        "\(count) word\(count == 1 ? "" : "s")"
    }

    /// One decimal, so a 400 ms hold is "0.4s" and not "0s".
    static func duration(_ milliseconds: Double) -> String {
        String(format: "%.1fs", milliseconds / 1000.0)
    }

    // MARK: - the headline and the rail

    /// Grouped thousands. Localised in the app, pinned in tests.
    static func decimal(_ value: Int, locale: Locale = .autoupdatingCurrent) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = locale
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    /// The `body` line under the big number: what it counts, and the streak
    /// when there is one. A zero-day streak is not mentioned — an empty boast
    /// is worse than no boast.
    static func headlineSubline(_ stats: HomeStats) -> String {
        var line = "words dictated"
        if stats.streakDays > 0 {
            line += " · \(stats.streakDays)-day streak"
        }
        return line
    }

    /// "words · 38 dictations" — the sub-line of the TODAY tile, whose value is
    /// the word count itself.
    static func todaySubline(_ stats: HomeStats) -> String {
        let count = stats.dictationsToday
        return "words · \(count) dictation\(count == 1 ? "" : "s")"
    }

    /// Whole words per minute. A median of 147.6 is not a measurement anyone
    /// can act on to a decimal place.
    static func rate(_ wpm: Double) -> String {
        "\(Int(wpm.rounded()))"
    }

    static func streakSubline(_ days: Int) -> String {
        "day\(days == 1 ? "" : "s")"
    }

    // MARK: - add to dictionary

    /// What the add-a-term popover starts with.
    ///
    /// A transcript short enough to *be* a term (a name, a product, a command)
    /// is offered whole; a sentence is not, because a dictionary entry made of
    /// a whole sentence is a term the recognizer will never match. SwiftUI's
    /// `Text` exposes no selection to read, so the popover's field is where the
    /// user does the selecting.
    static let suggestableWordCount = 3

    static func suggestedTerm(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard HomeModel.wordCount(trimmed) <= suggestableWordCount else { return "" }
        return trimmed
    }
}
#endif
