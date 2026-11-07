import Foundation

/// A label and its count. The spec sketches these as `[(String, Int)]`, but a
/// tuple array is not `Equatable`, and a value that cannot be compared cannot
/// be asserted on — which is the whole point of putting this logic in the pure
/// target. Same shape, one name.
public struct LabeledCount: Identifiable, Equatable, Sendable {
    public var label: String
    public var count: Int
    public var id: String { label }

    public init(_ label: String, _ count: Int) {
        self.label = label
        self.count = count
    }
}

/// One day of the holds-per-day sparkline.
public struct DayCount: Identifiable, Equatable, Sendable {
    public var day: Date
    public var count: Int
    public var id: Date { day }

    public init(day: Date, count: Int) {
        self.day = day
        self.count = count
    }
}

/// One dictionary term and how often it fired.
public struct TermUse: Identifiable, Equatable, Sendable {
    public var term: String
    public var hits: Int
    public var id: String { term }

    public init(term: String, hits: Int) {
        self.term = term
        self.hits = hits
    }
}

/// Everything Insights needs from `metrics.log` and the dictionary, in
/// `WispritMacUI`'s own vocabulary — `docs/design/ui-redesign.md` §6.1.
///
/// The neutral seam: this target cannot name `MetricsSummary`, so
/// `WispritMac/Window/` maps one into this. Every field is a field
/// `MetricsSummary` already publishes, or a count the mapper takes over the
/// same windowed rows; nothing here is invented.
///
/// Rates are **fractions**, 0…1. Latencies are milliseconds. The optional ones
/// are optional because the rows that carry them are optional:
/// `release_to_text_ms` exists only on rows that put text in front of the user.
///
/// The keys in `outcomes`, `emptyReasons`, `aiOutcomes` and `captureBackends`
/// are the machine words from disk. They never reach the screen as-is: every
/// label goes through `InsightsLabels`.
public struct InsightsInput: Equatable, Sendable {
    public var windowLabel: String
    public var total: Int
    public var outcomes: [String: Int]
    public var empty: Int
    public var emptyRate: Double
    public var emptyReasons: [String: Int]
    /// Reported **separately and never merged** into `emptyReasons` —
    /// `MetricsSummary` is explicit about this and the UI honours it.
    public var unclassifiedEmpty: Int
    public var unexplainedEmpty: Int
    public var unexplainedEmptyRate: Double
    public var timedOut: Int
    public var timedOutRate: Double
    public var finalizeP50: Double?
    public var finalizeP90: Double?
    public var releaseP50: Double?
    public var releaseP90: Double?
    public var aiOutcomes: [String: Int]
    public var dailyCounts: [DayCount]
    /// From `DictionaryEditor.rows()`, **not** metrics.
    public var vocabulary: [TermUse]
    public var learnedTermCount: Int
    /// Every term in the dictionary, fired or not — so "none has been needed
    /// yet" and "the dictionary is empty" are different sentences.
    public var dictionaryTermCount: Int
    /// Utterances whose fate was actually re-read out of a field — the
    /// zero-edit denominator. 0 means the figure is absent, not zero.
    public var zeroEditObserved: Int
    /// Zero-edit / observed, a fraction 0…1 — over OBSERVED utterances ONLY.
    public var zeroEditRate: Double
    /// `capture_backend` → count, over the utterance rows that carry it (rows
    /// written since the 2026-11-06 capture update).
    public var captureBackends: [String: Int]
    /// `starved` empties that carry `capture_backend`, i.e. happened on the
    /// current capture path. Zero next to a non-zero `starved` count is how
    /// the page knows the no-audio holds all predate the fix.
    public var starvedSinceCaptureUpdate: Int
    /// `first_chunk_ms` — key-down to the first audio the mic delivered.
    public var firstChunkP50: Double?
    public var firstChunkP90: Double?

    public init(windowLabel: String = "",
                total: Int = 0,
                outcomes: [String: Int] = [:],
                empty: Int = 0,
                emptyRate: Double = 0,
                emptyReasons: [String: Int] = [:],
                unclassifiedEmpty: Int = 0,
                unexplainedEmpty: Int = 0,
                unexplainedEmptyRate: Double = 0,
                timedOut: Int = 0,
                timedOutRate: Double = 0,
                finalizeP50: Double? = nil,
                finalizeP90: Double? = nil,
                releaseP50: Double? = nil,
                releaseP90: Double? = nil,
                aiOutcomes: [String: Int] = [:],
                dailyCounts: [DayCount] = [],
                vocabulary: [TermUse] = [],
                learnedTermCount: Int = 0,
                dictionaryTermCount: Int = 0,
                zeroEditObserved: Int = 0,
                zeroEditRate: Double = 0,
                captureBackends: [String: Int] = [:],
                starvedSinceCaptureUpdate: Int = 0,
                firstChunkP50: Double? = nil,
                firstChunkP90: Double? = nil) {
        self.windowLabel = windowLabel
        self.total = total
        self.outcomes = outcomes
        self.empty = empty
        self.emptyRate = emptyRate
        self.emptyReasons = emptyReasons
        self.unclassifiedEmpty = unclassifiedEmpty
        self.unexplainedEmpty = unexplainedEmpty
        self.unexplainedEmptyRate = unexplainedEmptyRate
        self.timedOut = timedOut
        self.timedOutRate = timedOutRate
        self.finalizeP50 = finalizeP50
        self.finalizeP90 = finalizeP90
        self.releaseP50 = releaseP50
        self.releaseP90 = releaseP90
        self.aiOutcomes = aiOutcomes
        self.dailyCounts = dailyCounts
        self.vocabulary = vocabulary
        self.learnedTermCount = learnedTermCount
        self.dictionaryTermCount = dictionaryTermCount
        self.zeroEditObserved = zeroEditObserved
        self.zeroEditRate = zeroEditRate
        self.captureBackends = captureBackends
        self.starvedSinceCaptureUpdate = starvedSinceCaptureUpdate
        self.firstChunkP50 = firstChunkP50
        self.firstChunkP90 = firstChunkP90
    }

    /// Utterance rows that recorded how the mic was opened.
    public var capturedRows: Int { captureBackends.values.reduce(0, +) }
}

// MARK: - Recovery

/// Rescue / empty-reason / quiet-speech figures, derived by
/// `InsightsMapper.recovery` from the same windowed rows as `InsightsInput`.
public struct InsightsRecovery: Equatable, Sendable {
    public static let sectionTitle = "Recovery"
    public static let rescuedLabel = "Rescued by a second pass"
    public static let rescuedDescription =
        "Holds the backup recognizer recovered after live speech returned nothing."
    public static let quietSpeechLabel = "Quiet speech, last 7 days"
    public static let quietSpeechDescription =
        "Holds whose loudest moment stayed under 0.12 on the level meter."
    public static let quietSpeechCaption =
        "Speak a touch louder or raise input gain for best accuracy"

    /// The batch engine's on-disk name. A rescued hold writes this as `engine`.
    public static let appleBatchEngine = "apple_batch"
    public static let rescuedKey = "rescued"
    public static let peakLevelKey = "peak_level"
    /// Mid-utterance input switch — `EmptyReason.deviceChanged`.
    public static let deviceChangedReason = "device_changed"
    public static let quietPeakCeiling = 0.12
    public static let quietShareAlarm = 0.20
    public static let quietSpeechDays: Double = 7

    public var rescued: Int
    /// Classified `empty_reason` histogram, including `device_changed`. Never
    /// merged with `unclassifiedEmpty`.
    public var emptyReasons: [String: Int]
    public var unclassifiedEmpty: Int
    /// Last-7-day holds with `peak_level` present and under `quietPeakCeiling`.
    public var quietSpeech: Int
    /// Last-7-day holds that recorded `peak_level` at all. Missing is an
    /// absence, not a quiet hold.
    public var quietSpeechSample: Int

    public init(rescued: Int = 0,
                emptyReasons: [String: Int] = [:],
                unclassifiedEmpty: Int = 0,
                quietSpeech: Int = 0,
                quietSpeechSample: Int = 0) {
        self.rescued = rescued
        self.emptyReasons = emptyReasons
        self.unclassifiedEmpty = unclassifiedEmpty
        self.quietSpeech = quietSpeech
        self.quietSpeechSample = quietSpeechSample
    }

    public var quietSpeechShare: Double {
        InsightsRecovery.share(quietSpeech, of: quietSpeechSample)
    }

    /// The caption fires only when the share *exceeds* 20%, not at the line.
    public var showsQuietCaption: Bool {
        quietSpeechSample > 0 && quietSpeechShare > InsightsRecovery.quietShareAlarm
    }

    /// Nothing to draw: hide the section rather than a plate of zeros.
    public var isEmpty: Bool {
        rescued == 0 && emptyReasons.isEmpty && unclassifiedEmpty == 0
            && quietSpeechSample == 0
    }

    public var unclassifiedFootnote: String? {
        InsightsModel.unclassifiedNote(unclassifiedEmpty)
    }

    public static func share(_ part: Int, of total: Int) -> Double {
        total > 0 ? Double(part) / Double(total) : 0
    }

    public static func percent(_ fraction: Double) -> String {
        InsightsModel.percent(fraction)
    }
}

// MARK: - Activity (from history, not metrics)

/// The history-derived half of the page: the streak grid and the speaking
/// rate. Built from `HomeStats` (which the window already computes off the main
/// thread) plus the newest page of transcripts, so Insights adds no query.
public struct InsightsActivity: Equatable, Sendable {
    /// Weeks × 7 counts, oldest week first — `HomeModel.heatmap`.
    public var weeks: [[Int]]
    /// The first day of the oldest column.
    public var gridStart: Date
    public var today: StreakCell?
    public var streakDays: Int
    /// Median words per minute; nil when no transcript carries a duration.
    public var medianWPM: Double?
    /// Per-dictation words per minute, newest first, over the same sample the
    /// median is taken from.
    public var rates: [Double]
    public var calendar: Calendar

    public init(weeks: [[Int]], gridStart: Date, today: StreakCell?, streakDays: Int,
                medianWPM: Double?, rates: [Double], calendar: Calendar) {
        self.weeks = weeks
        self.gridStart = gridStart
        self.today = today
        self.streakDays = streakDays
        self.medianWPM = medianWPM
        self.rates = rates
        self.calendar = calendar
    }

    /// `HomeStats` + the newest transcripts → the page's activity figures.
    ///
    /// The rate sample is `HomeModel.medianWPM`'s exactly (newest `sample`
    /// rows, then the ones with a usable duration), so the dots and the median
    /// over them are one measurement; with no transcripts loaded the median
    /// falls back to the one `HomeStats` already carries.
    public static func make(stats: HomeStats,
                            items: [TranscriptItem],
                            now: Date,
                            calendar: Calendar,
                            rateSample: Int = HomeModel.defaultRateSample) -> InsightsActivity? {
        guard let start = StreakCalendar.gridStart(weeks: stats.heatmapWeeks, now: now,
                                                   calendar: calendar) else { return nil }
        let rates = items
            .sorted { $0.ts > $1.ts }
            .prefix(max(0, rateSample))
            .compactMap { item -> Double? in
                guard let ms = item.durationMs, ms > 0, item.wordCount > 0 else { return nil }
                return Double(item.wordCount) / (ms / 60_000.0)
            }
        let median = rates.isEmpty ? stats.medianWPM : InsightsModel.median(rates)
        return InsightsActivity(weeks: stats.heatmap,
                                gridStart: start,
                                today: StreakCalendar.today(weeks: stats.heatmapWeeks,
                                                            now: now, calendar: calendar),
                                streakDays: stats.streakDays,
                                medianWPM: median,
                                rates: rates,
                                calendar: calendar)
    }

    /// Cells up to and including today — the days the grid can speak for.
    public var elapsedDays: Int {
        guard let today else { return weeks.count * 7 }
        return today.week * 7 + today.day + 1
    }

    public var activeDays: Int {
        weeks.joined().filter { $0 > 0 }.count
    }

    /// The busiest day on the grid, oldest wins a tie.
    public var busiest: (count: Int, date: Date)? {
        var best: (count: Int, cell: StreakCell)?
        for (week, days) in weeks.enumerated() {
            for (day, count) in days.enumerated() where count > (best?.count ?? 0) {
                best = (count, StreakCell(week: week, day: day))
            }
        }
        guard let best,
              let date = StreakCalendar.date(of: best.cell, gridStart: gridStart, calendar: calendar)
        else { return nil }
        return (best.count, date)
    }

    public var monthLabels: [StreakMonthLabel] {
        StreakCalendar.monthLabels(weeks: weeks.count, gridStart: gridStart, calendar: calendar)
    }

    /// "Thu, Sep 4 · 12 dictations" for every drawn cell.
    public var tooltips: [StreakCell: String] {
        var out: [StreakCell: String] = [:]
        for (week, days) in weeks.enumerated() {
            for (day, count) in days.enumerated() {
                let cell = StreakCell(week: week, day: day)
                if let today, cell.week > today.week || (cell.week == today.week && cell.day > today.day) {
                    continue
                }
                guard let date = StreakCalendar.date(of: cell, gridStart: gridStart, calendar: calendar)
                else { continue }
                out[cell] = "\(InsightsModel.shortDate(date, calendar: calendar)) · "
                    + (count == 0 ? "no dictations" : InsightsModel.plural(count, "dictation"))
            }
        }
        return out
    }
}

// MARK: - Headlines

/// One run of a headline sentence. Figures are the numbers the sentence is
/// about, drawn a step louder than the words around them.
public struct HeadlineRun: Equatable, Sendable {
    public var text: String
    public var isFigure: Bool

    public init(_ text: String, figure: Bool = false) {
        self.text = text
        self.isFigure = figure
    }
}

/// `critical` is for genuine faults only — a quick tap or a silent hold is
/// normal behaviour and is never drawn red.
public enum HeadlineTone: Equatable, Sendable {
    case neutral
    case fault
}

/// Where a hold ended up, grouped the way a person would tell it.
public enum HoldGroup: String, CaseIterable, Equatable, Sendable {
    case delivered
    case correction
    case quiet
    case mic
    case noWords
    case unknown
    case blocked
    case fault

    public var label: String {
        switch self {
        case .delivered: return "Became text"
        case .correction: return "Spelling correction"
        case .quiet: return "Quick tap or silence"
        case .mic: return "Mic sent no audio"
        case .noWords: return "Heard sound, no words"
        case .unknown: return "Reason not recorded"
        case .blocked: return "Blocked by a password field"
        case .fault: return "Wisprit missed it"
        }
    }

    /// Only these are faults on Wisprit's side worth `critical`.
    public var isFault: Bool { self == .fault }
}

public struct HoldSegment: Identifiable, Equatable, Sendable {
    public var group: HoldGroup
    public var count: Int
    public var id: String { group.rawValue }

    public init(_ group: HoldGroup, _ count: Int) {
        self.group = group
        self.count = count
    }
}

/// The one simple chart each headline carries.
public enum HeadlineChart: Equatable, Sendable {
    /// Median and 90th percentile against the "feels instant" reference.
    case latency(p50: Double, p90: Double, reference: Double)
    /// One bar, every hold in it.
    case holds([HoldSegment])
    /// The busiest dictionary terms.
    case terms([LabeledCount])
    /// Every dictation in the sample as a dot on a words-per-minute axis.
    case rates(samples: [Double], median: Double)
    /// The streak grid, drawn from `InsightsActivity`.
    case activity
    /// Not enough data yet: a dashed plate and the line that says what it needs.
    case placeholder(String)
    case none
}

public struct InsightHeadline: Identifiable, Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case speed, holds, dictionary, pace, activity
    }

    public var kind: Kind
    /// "Speed", "Holds" — the small label over the sentence.
    public var kicker: String
    /// What the figures cover: "Last 30 days", "All time".
    public var scope: String
    public var sentence: [HeadlineRun]
    /// One plain line of context under the chart.
    public var detail: String?
    /// What to try. Empty when there is nothing to do.
    public var advice: [String]
    public var tone: HeadlineTone
    public var chart: HeadlineChart

    public var id: String { kind.rawValue }
    /// The sentence as one string — what VoiceOver reads and tests assert.
    public var text: String { sentence.map(\.text).joined() }

    public init(kind: Kind, kicker: String, scope: String, sentence: [HeadlineRun],
                detail: String? = nil, advice: [String] = [], tone: HeadlineTone = .neutral,
                chart: HeadlineChart) {
        self.kind = kind
        self.kicker = kicker
        self.scope = scope
        self.sentence = sentence
        self.detail = detail
        self.advice = advice
        self.tone = tone
        self.chart = chart
    }
}

// MARK: - Technical details

public struct InsightDetailRow: Identifiable, Equatable, Sendable {
    public var label: String
    public var value: String
    /// A second column (the "9 in 10" figure in a timing row); nil spans.
    public var secondary: String?
    /// Bar length 0…1 for ranked rows; nil draws no bar.
    public var fraction: Double?
    public var isFault: Bool
    public var id: String { label }

    public init(_ label: String, _ value: String, secondary: String? = nil,
                fraction: Double? = nil, isFault: Bool = false) {
        self.label = label
        self.value = value
        self.secondary = secondary
        self.fraction = fraction
        self.isFault = isFault
    }
}

public struct InsightDetailSection: Identifiable, Equatable, Sendable {
    public var title: String
    /// Headers for a two-column section ("Median", "9 in 10"); empty otherwise.
    public var columns: [String]
    public var rows: [InsightDetailRow]
    /// Daily volume, normalised 0…1, drawn over the rows when present.
    public var spark: [Double]
    /// Quiet footnotes.
    public var notes: [String]
    /// The one line in a section that gets `critical`.
    public var alarm: String?
    public var id: String { title }

    public init(title: String, columns: [String] = [], rows: [InsightDetailRow],
                spark: [Double] = [], notes: [String] = [], alarm: String? = nil) {
        self.title = title
        self.columns = columns
        self.rows = rows
        self.spark = spark
        self.notes = notes
        self.alarm = alarm
    }
}

// MARK: - The model

/// Insights' pure logic.
///
/// Three rules run through all of it:
///
/// 1. **Headlines first.** Each headline is one sentence with numbers in it,
///    one simple chart, and — when something went wrong — what to try.
/// 2. **Plain words.** Every machine value goes through `InsightsLabels`; the
///    technical details are still details, not a log dump.
/// 3. **The sparse contract.** Fewer than `minimumRows` contributing rows and
///    a figure degrades to a line that says what it needs — never a zero,
///    never a chart of one bar.
public enum InsightsModel {
    public static let minimumRows = 5
    /// Release-to-text under 400 ms reads as immediate.
    public static let latencyReferenceMs: Double = 400
    /// How many terms the dictionary chart lists.
    public static let vocabularyLimit = 5
    /// How many advice lines one headline may carry.
    public static let adviceLimit = 2

    /// Outcomes that put text in front of the user.
    public static let deliveredOutcomes: Set<String> = ["im_streaming", "im_commit", "paste", "type"]

    // MARK: headlines

    /// The headlines, in page order: speed, holds, dictionary, pace, activity.
    /// Pace and activity come from history and are absent until it is read.
    public static func headlines(from input: InsightsInput,
                                 activity: InsightsActivity?,
                                 locale: Locale = .autoupdatingCurrent) -> [InsightHeadline] {
        var out = [speed(input), holds(input, locale: locale), dictionary(input, locale: locale)]
        if let activity {
            if let pace = pace(activity) { out.append(pace) }
            out.append(self.activity(activity, locale: locale))
        }
        return out
    }

    /// "Text lands 0.20 s after you let go."
    public static func speed(_ input: InsightsInput) -> InsightHeadline {
        let scope = capitalized(input.windowLabel)
        guard input.total >= minimumRows, let p50 = input.releaseP50, let p90 = input.releaseP90 else {
            return InsightHeadline(kind: .speed, kicker: "Speed", scope: scope,
                                   sentence: [HeadlineRun("How fast text lands shows up here.")],
                                   chart: .placeholder(need(input.total, noun: "dictations")))
        }
        var advice: [String] = []
        if p50 > latencyReferenceMs, (input.aiOutcomes["applied"] ?? 0) > 0 {
            advice.append("AI cleanup adds time to longer dictations. "
                          + "Turn it off in Settings if speed matters more.")
        }
        return InsightHeadline(
            kind: .speed, kicker: "Speed", scope: scope,
            sentence: [HeadlineRun("Text lands "), HeadlineRun(secondsFigure(p50), figure: true),
                       HeadlineRun(" seconds after you let go.")],
            detail: "9 in 10 land within \(seconds(p90)). The dashed line, "
                + "\(seconds(latencyReferenceMs)), is where a wait starts to show.",
            advice: advice,
            chart: .latency(p50: p50, p90: p90, reference: latencyReferenceMs))
    }

    /// "9 of your last 34 holds became text."
    public static func holds(_ input: InsightsInput, locale: Locale) -> InsightHeadline {
        let scope = capitalized(input.windowLabel)
        guard input.total >= minimumRows else {
            return InsightHeadline(kind: .holds, kicker: "Holds", scope: scope,
                                   sentence: [HeadlineRun("How many holds became text shows up here.")],
                                   chart: .placeholder(need(input.total, noun: "dictations")))
        }
        let segments = holdSegments(input)
        let count = { (group: HoldGroup) in segments.first { $0.group == group }?.count ?? 0 }
        let delivered = count(.delivered)
        let total = number(input.total, locale: locale)

        let sentence: [HeadlineRun] = delivered == input.total
            ? [HeadlineRun("Every one of your last "), HeadlineRun(total, figure: true),
               HeadlineRun(" holds became text.")]
            : [HeadlineRun(number(delivered, locale: locale), figure: true),
               HeadlineRun(" of your last "), HeadlineRun(total, figure: true),
               HeadlineRun(" holds became text.")]

        return InsightHeadline(kind: .holds, kicker: "Holds", scope: scope,
                               sentence: sentence,
                               detail: emptiesSentence(input, segments: segments, locale: locale),
                               advice: holdAdvice(input, segments: segments),
                               tone: count(.fault) > 0 ? .fault : .neutral,
                               chart: .holds(segments))
    }

    /// Every hold in the window, by where it ended up. Sums to `total`.
    public static func holdSegments(_ input: InsightsInput) -> [HoldSegment] {
        var counts: [HoldGroup: Int] = [:]
        for (outcome, n) in input.outcomes {
            switch outcome {
            case _ where deliveredOutcomes.contains(outcome): counts[.delivered, default: 0] += n
            case "correction": counts[.correction, default: 0] += n
            case "blocked_secure": counts[.blocked, default: 0] += n
            case "error": counts[.fault, default: 0] += n
            case "empty": continue   // split by reason below
            default: counts[.unknown, default: 0] += n
            }
        }
        for (reason, n) in input.emptyReasons {
            switch reason {
            case "short_hold", "silent": counts[.quiet, default: 0] += n
            case "starved", "device_changed": counts[.mic, default: 0] += n
            case "produced_nothing": counts[.noWords, default: 0] += n
            case "timed_out", "crashed": counts[.fault, default: 0] += n
            default: counts[.unknown, default: 0] += n
            }
        }
        counts[.unknown, default: 0] += input.unclassifiedEmpty
        // The unexplained ones: audible speech, a long hold, a clean finish,
        // nothing back. That is Wisprit's fault, and the only empty that is.
        let unexplained = min(input.unexplainedEmpty, counts[.noWords] ?? 0)
        counts[.noWords, default: 0] -= unexplained
        counts[.fault, default: 0] += unexplained
        return HoldGroup.allCases.compactMap { group in
            let n = counts[group] ?? 0
            return n > 0 ? HoldSegment(group, n) : nil
        }
    }

    /// "25 caught nothing: 17 were quick taps or silence, 7 got no audio from
    /// the mic and 1 heard sound but no words." Nil when nothing was empty.
    static func emptiesSentence(_ input: InsightsInput, segments: [HoldSegment],
                                locale: Locale) -> String? {
        guard input.empty > 0 else { return nil }
        let order: [HoldGroup] = [.quiet, .mic, .noWords, .fault, .unknown]
        // Only the empty share of `.fault` / `.unknown` belongs in this
        // sentence; an insertion error is not a hold that caught nothing.
        let errorCount = input.outcomes["error"] ?? 0
        let otherUnknown = input.outcomes.filter {
            !deliveredOutcomes.contains($0.key)
                && !["correction", "blocked_secure", "error", "empty"].contains($0.key)
        }.values.reduce(0, +)
        let parts: [(HoldGroup, Int)] = order.compactMap { group in
            var n = segments.first { $0.group == group }?.count ?? 0
            if group == .fault { n -= errorCount }
            if group == .unknown { n -= otherUnknown }
            return n > 0 ? (group, n) : nil
        }
        // A genuine fault is always named, first; the rest biggest first.
        .sorted { lhs, rhs in
            if (lhs.0 == .fault) != (rhs.0 == .fault) { return lhs.0 == .fault }
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            return order.firstIndex(of: lhs.0)! < order.firstIndex(of: rhs.0)!
        }

        let shown = parts.prefix(3).map { phrase($0.0, $0.1, locale: locale) }
        let rest = parts.dropFirst(3).reduce(0) { $0 + $1.1 }
        var clauses = Array(shown)
        if rest > 0 { clauses.append("\(number(rest, locale: locale)) other\(rest == 1 ? "" : "s")") }
        let head = "\(number(input.empty, locale: locale)) caught nothing"
        guard !clauses.isEmpty else { return head + "." }
        return head + ": " + list(clauses) + "."
    }

    private static func phrase(_ group: HoldGroup, _ n: Int, locale: Locale) -> String {
        let count = number(n, locale: locale)
        switch group {
        case .quiet: return n == 1 ? "\(count) was a quick tap or silence" : "\(count) were quick taps or silence"
        case .mic: return "\(count) got no audio from the mic"
        case .noWords: return "\(count) heard sound but no words"
        case .fault: return "\(count) \(n == 1 ? "was" : "were") missed by Wisprit"
        case .unknown: return "\(count) \(n == 1 ? "has" : "have") no recorded reason"
        case .delivered, .correction, .blocked: return count
        }
    }

    /// What to try, biggest cause first. A fault always leads.
    static func holdAdvice(_ input: InsightsInput, segments: [HoldSegment]) -> [String] {
        var advice: [String] = []
        let count = { (group: HoldGroup) in segments.first { $0.group == group }?.count ?? 0 }
        if count(.fault) > 0 {
            advice.append("If speech keeps going missing, open Setup and use Copy diagnostics to report it.")
        }
        let ranked: [HoldGroup] = [.quiet, .mic, .noWords]
            .filter { count($0) > 0 }
            .sorted { count($0) > count($1) }
        for group in ranked {
            switch group {
            case .quiet:
                let silent = input.emptyReasons["silent"] ?? 0
                let taps = input.emptyReasons["short_hold"] ?? 0
                advice.append(silent > taps
                    ? "If you were speaking, check that the mic named in the toolbar is the one you talk into."
                    : "Hold the key for the whole sentence — very short taps are ignored on purpose.")
            case .mic:
                let starved = input.emptyReasons["starved"] ?? 0
                let switched = input.emptyReasons["device_changed"] ?? 0
                if switched > starved {
                    advice.append("Avoid switching microphones or headsets while you hold the key.")
                } else if input.capturedRows > 0, input.starvedSinceCaptureUpdate == 0, switched == 0 {
                    advice.append("The no-audio holds all came before Wisprit's new mic capture — none since.")
                } else {
                    advice.append("With AirPods or another Bluetooth headset, wait a moment after "
                                  + "pressing the key before you speak.")
                }
            case .noWords:
                advice.append("Speak a little closer to the mic, or raise its input level in System Settings.")
            default:
                break
            }
        }
        return Array(advice.prefix(adviceLimit))
    }

    /// "Your dictionary has fixed 69 words so far."
    public static func dictionary(_ input: InsightsInput, locale: Locale) -> InsightHeadline {
        let used = input.vocabulary
            .filter { $0.hits > 0 }
            .sorted { $0.hits == $1.hits ? $0.term < $1.term : $0.hits > $1.hits }
        guard input.dictionaryTermCount > 0 || !used.isEmpty else {
            return InsightHeadline(
                kind: .dictionary, kicker: "Dictionary", scope: "All time",
                sentence: [HeadlineRun("Your dictionary is empty.")],
                advice: ["Add names and jargon Wisprit gets wrong — it fixes them in every dictation."],
                chart: .none)
        }
        guard let top = used.first else {
            let count = input.dictionaryTermCount
            return InsightHeadline(
                kind: .dictionary, kicker: "Dictionary", scope: "All time",
                sentence: count == 1
                    ? [HeadlineRun("Your one dictionary term hasn't been needed yet.")]
                    : [HeadlineRun("None of your "),
                       HeadlineRun(number(count, locale: locale), figure: true),
                       HeadlineRun(" dictionary terms have been needed yet.")],
                chart: .none)
        }
        let total = used.reduce(0) { $0 + $1.hits }
        var detail = "\(top.term) leads with \(number(top.hits, locale: locale))."
        if input.dictionaryTermCount > used.count {
            detail = "The fixes came from \(used.count) of your "
                + "\(plural(input.dictionaryTermCount, "term"))."
        }
        if input.learnedTermCount > 0 {
            detail += " Wisprit learned \(plural(input.learnedTermCount, "term"))"
                + " from your spelled-out corrections."
        }
        return InsightHeadline(
            kind: .dictionary, kicker: "Dictionary", scope: "All time",
            sentence: [HeadlineRun("Your dictionary has fixed "),
                       HeadlineRun(number(total, locale: locale), figure: true),
                       HeadlineRun(total == 1 ? " word so far." : " words so far.")],
            detail: detail,
            chart: .terms(used.prefix(vocabularyLimit).map { LabeledCount($0.term, $0.hits) }))
    }

    /// "You speak at 123 words per minute." Absent with no rate to report.
    public static func pace(_ activity: InsightsActivity) -> InsightHeadline? {
        guard let wpm = activity.medianWPM, wpm.isFinite, wpm > 0 else { return nil }
        let rates = activity.rates
        let scope = rates.isEmpty ? "Recent dictations" : "Last \(plural(rates.count, "dictation"))"
        var detail: String?
        var chart: HeadlineChart = .none
        if rates.count >= minimumRows {
            let sorted = rates.sorted()
            let low = Int(nearestRank(sorted, 25).rounded())
            let high = Int(nearestRank(sorted, 75).rounded())
            detail = "Half of them fall between \(low) and \(high) words per minute."
            chart = .rates(samples: rates, median: wpm)
        }
        return InsightHeadline(
            kind: .pace, kicker: "Pace", scope: scope,
            sentence: [HeadlineRun("You speak at "),
                       HeadlineRun("\(Int(wpm.rounded()))", figure: true),
                       HeadlineRun(" words per minute.")],
            detail: detail, chart: chart)
    }

    /// "You dictated on 42 of the last 126 days."
    public static func activity(_ activity: InsightsActivity, locale: Locale) -> InsightHeadline {
        let weeks = activity.weeks.count
        var parts: [String] = []
        if activity.streakDays > 0 {
            parts.append("\(activity.streakDays)-day streak.")
        }
        if let busiest = activity.busiest {
            parts.append("Busiest day: \(plural(busiest.count, "dictation")) on "
                         + "\(shortDate(busiest.date, calendar: activity.calendar)).")
        }
        return InsightHeadline(
            kind: .activity, kicker: "Activity", scope: "Last \(weeks) weeks",
            sentence: [HeadlineRun("You dictated on "),
                       HeadlineRun(number(activity.activeDays, locale: locale), figure: true),
                       HeadlineRun(" of the last "),
                       HeadlineRun(number(activity.elapsedDays, locale: locale), figure: true),
                       HeadlineRun(" days.")],
            detail: parts.isEmpty ? nil : parts.joined(separator: " "),
            chart: .activity)
    }

    // MARK: technical details

    /// Everything a curious or troubleshooting reader wants, in plain labels.
    public static func details(from input: InsightsInput,
                               recovery: InsightsRecovery?,
                               locale: Locale = .autoupdatingCurrent) -> [InsightDetailSection] {
        var sections: [InsightDetailSection] = []

        if let timing = timing(input, locale: locale) { sections.append(timing) }

        if input.total > 0 {
            sections.append(InsightDetailSection(
                title: "What happened to each hold",
                rows: rankedRows(input.outcomes, label: InsightsLabels.outcome,
                                 faults: ["error"], locale: locale),
                spark: input.dailyCounts.count > 1 ? sparkline(input.dailyCounts) : []))
        }

        if input.empty > 0 {
            var notes: [String] = []
            if let note = unclassifiedNote(input.unclassifiedEmpty) { notes.append(note) }
            var alarm: String?
            if input.unexplainedEmpty > 0 {
                alarm = "\(plural(input.unexplainedEmpty, "hold")) (\(percent(input.unexplainedEmptyRate)))"
                    + " had clear speech and a clean finish but still produced no text."
            }
            sections.append(InsightDetailSection(
                title: "Why holds caught nothing",
                rows: rankedRows(input.emptyReasons, label: InsightsLabels.emptyReason,
                                 faults: ["crashed", "timed_out"], locale: locale),
                notes: notes, alarm: alarm))
        }

        if !input.aiOutcomes.isEmpty {
            sections.append(InsightDetailSection(
                title: "AI cleanup",
                rows: rankedRows(input.aiOutcomes, label: InsightsLabels.cleanup,
                                 faults: [], locale: locale)))
        }

        if let recovery, recovery.rescued > 0 || recovery.quietSpeechSample > 0 {
            var rows: [InsightDetailRow] = []
            if recovery.rescued > 0 {
                rows.append(InsightDetailRow(InsightsRecovery.rescuedLabel,
                                             number(recovery.rescued, locale: locale)))
            }
            if recovery.quietSpeechSample > 0 {
                rows.append(InsightDetailRow(
                    InsightsRecovery.quietSpeechLabel,
                    "\(percent(recovery.quietSpeechShare)) of \(plural(recovery.quietSpeechSample, "hold"))"))
            }
            sections.append(InsightDetailSection(
                title: InsightsRecovery.sectionTitle, rows: rows,
                notes: recovery.showsQuietCaption ? [InsightsRecovery.quietSpeechCaption + "."] : []))
        }

        if input.capturedRows > 0 {
            sections.append(InsightDetailSection(
                title: "Mic capture",
                rows: rankedRows(input.captureBackends, label: InsightsLabels.captureBackend,
                                 faults: [], locale: locale),
                notes: ["Recorded on holds since Wisprit's new mic capture."]))
        }

        if input.zeroEditObserved > 0 {
            let value = input.zeroEditObserved >= minimumRows
                ? "\(percent(input.zeroEditRate)) of \(plural(input.zeroEditObserved, "checked dictation"))"
                : need(input.zeroEditObserved, noun: "checked dictations")
            sections.append(InsightDetailSection(
                title: "Edits",
                rows: [InsightDetailRow("Needed no edits afterwards", value)]))
        }
        return sections
    }

    /// Median and 90th percentile side by side, one row per stage, in the
    /// order a hold goes through them.
    static func timing(_ input: InsightsInput, locale: Locale) -> InsightDetailSection? {
        guard input.total > 0 else { return nil }
        var rows: [InsightDetailRow] = []
        func timed(_ label: String, _ p50: Double?, _ p90: Double?) {
            guard let p50 else { return }
            rows.append(InsightDetailRow(label, ms(p50), secondary: p90.map(ms) ?? "—"))
        }
        timed("Key press to first audio", input.firstChunkP50, input.firstChunkP90)
        timed("Speech engine finishing", input.finalizeP50, input.finalizeP90)
        if input.releaseP50 != nil {
            timed("Key release to text", input.releaseP50, input.releaseP90)
        } else {
            rows.append(InsightDetailRow("Key release to text", "Not measured yet"))
        }
        if input.finalizeP50 != nil {
            rows.append(InsightDetailRow("Finishing took too long",
                                         "\(number(input.timedOut, locale: locale)) of "
                                         + "\(number(input.total, locale: locale)) "
                                         + "(\(percent(input.timedOutRate)))",
                                         isFault: input.timedOut > 0))
        }
        return InsightDetailSection(title: "Timing", columns: ["Median", "9 in 10 within"],
                                    rows: rows)
    }

    static func rankedRows(_ counts: [String: Int], label: (String) -> String,
                           faults: Set<String>, locale: Locale) -> [InsightDetailRow] {
        let rows = ranked(counts)
        let peak = rows.map(\.count).max() ?? 0
        return rows.map { row in
            InsightDetailRow(label(row.label), number(row.count, locale: locale),
                             fraction: peak > 0 ? Double(row.count) / Double(peak) : 0,
                             isFault: faults.contains(row.label))
        }
    }

    static func unclassifiedNote(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        return "\(plural(count, "older hold")) \(count == 1 ? "was" : "were") logged "
            + "before Wisprit recorded a reason."
    }

    // MARK: - shared shaping

    /// Count descending, then key ascending — the same tie-break
    /// `MetricsSummary.ranked` uses, so the page and a Doctor report never
    /// disagree about which of two equal outcomes comes first.
    public static func ranked(_ counts: [String: Int]) -> [LabeledCount] {
        counts
            .map { LabeledCount($0.key, $0.value) }
            .sorted { $0.count == $1.count ? $0.label < $1.label : $0.count > $1.count }
    }

    /// Daily counts, normalised against the busiest day. An all-zero window
    /// produces a flat line rather than a division by zero.
    public static func sparkline(_ days: [DayCount]) -> [Double] {
        let peak = days.map(\.count).max() ?? 0
        guard peak > 0 else { return days.map { _ in 0 } }
        return days.map { Double($0.count) / Double(peak) }
    }

    /// "Needs 5 dictations. You have 2." — never a zero, always the gap.
    public static func need(_ have: Int, noun: String) -> String {
        "Needs \(minimumRows) \(noun). You have \(have)."
    }

    /// Seconds, for a person: two decimals under a second ("0.20 s"), one
    /// above ("1.4 s").
    public static func seconds(_ milliseconds: Double) -> String {
        guard milliseconds.isFinite else { return "—" }
        return secondsFigure(milliseconds) + " s"
    }

    /// The number alone ("0.20"), for a sentence that spells the unit out.
    public static func secondsFigure(_ milliseconds: Double) -> String {
        guard milliseconds.isFinite else { return "—" }
        let value = milliseconds / 1000
        return value < 1 ? String(format: "%.2f", value) : String(format: "%.1f", value)
    }

    static func number(_ value: Int, locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = locale
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// One decimal, because 5.2% and 0.3% are both meaningful.
    static func percent(_ fraction: Double) -> String {
        guard fraction.isFinite else { return "0.0%" }
        return String(format: "%.1f%%", fraction * 100)
    }

    static func ms(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        return "\(Int(value.rounded())) ms"
    }

    static func plural(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")"
    }

    static func capitalized(_ label: String) -> String {
        guard let first = label.first else { return "" }
        return first.uppercased() + label.dropFirst()
    }

    /// "a, b and c".
    static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        default: return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
        }
    }

    static func median(_ values: [Double]) -> Double? {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return nil }
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
    }

    /// Nearest-rank percentile over ascending values.
    static func nearestRank(_ sorted: [Double], _ percentile: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let rank = max(1, Int((percentile / 100 * Double(sorted.count)).rounded(.up)))
        return sorted[min(sorted.count, rank) - 1]
    }

    /// "Thu, Sep 4" in the calendar's own locale.
    static func shortDate(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = calendar.locale ?? .autoupdatingCurrent
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("EEEMMMd")
        return formatter.string(from: date)
    }
}
