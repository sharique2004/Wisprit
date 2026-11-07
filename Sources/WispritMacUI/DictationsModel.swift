import Foundation

// The Dictations page's pure half — everything the page decides, as functions
// over neutral values with an explicit `now` and `calendar`, the `HomeModel`
// discipline. `WispritMac/Window/HomeSource` is the only place history rows and
// metrics lines are turned into these.

/// How long each stage of one dictation took, in milliseconds.
public struct DictationTiming: Equatable, Sendable {
    /// Key-up → text in the field: the number the user feels.
    public var releaseToTextMs: Double?
    /// Recognition's finalize.
    public var recognizeMs: Double?
    /// The cleanup stage, however it ended.
    public var cleanupMs: Double?

    public init(releaseToTextMs: Double? = nil, recognizeMs: Double? = nil, cleanupMs: Double? = nil) {
        self.releaseToTextMs = releaseToTextMs
        self.recognizeMs = recognizeMs
        self.cleanupMs = cleanupMs
    }

    public var isEmpty: Bool { releaseToTextMs == nil && recognizeMs == nil && cleanupMs == nil }
}

/// One utterance line of `metrics.log`, as the page needs it.
public struct MetricsUtterance: Equatable, Sendable {
    /// Wall-clock seconds, written once the utterance finished.
    public var ts: Double
    public var heldMs: Double
    /// `paste` / `type` / `im_streaming` / … / `empty` / `correction`.
    public var outcome: String
    /// Only on `empty` rows; nil on rows from before the reasons existed.
    public var emptyReason: String?
    public var audioMs: Double?
    public var releaseToTextMs: Double?
    public var finalizeMs: Double?
    public var aiMs: Double?
    public var ai: String?
    public var refineDelta: Int?
    public var inputDevice: String?
    /// Speech the room nearly swallowed (`marginal_audio`).
    public var marginalAudio: Bool
    /// The audio hardware changed under the hold (`config_changed`).
    public var configChanged: Bool

    public init(ts: Double, heldMs: Double, outcome: String, emptyReason: String? = nil,
                audioMs: Double? = nil, releaseToTextMs: Double? = nil,
                finalizeMs: Double? = nil, aiMs: Double? = nil, ai: String? = nil,
                refineDelta: Int? = nil, inputDevice: String? = nil,
                marginalAudio: Bool = false, configChanged: Bool = false) {
        self.ts = ts; self.heldMs = heldMs; self.outcome = outcome
        self.emptyReason = emptyReason; self.audioMs = audioMs
        self.releaseToTextMs = releaseToTextMs; self.finalizeMs = finalizeMs
        self.aiMs = aiMs; self.ai = ai; self.refineDelta = refineDelta
        self.inputDevice = inputDevice; self.marginalAudio = marginalAudio
        self.configChanged = configChanged
    }

    /// A capture that produced nothing — the rows the page shows as misses.
    public var isMiss: Bool { outcome == DictationsModel.missOutcome }

    /// A row that delivered text, so it has a transcript to belong to.
    /// `correction` (a spoken spelling with nothing to insert) has none.
    public var isDelivery: Bool { outcome != DictationsModel.missOutcome && outcome != "correction" }
}

/// One saved dictation with everything the page and its inspector show.
public struct DictationRecord: Identifiable, Equatable, Sendable {
    public var id: Int64
    public var ts: Double
    /// What history kept — what was written.
    public var text: String
    public var engine: String
    public var durationMs: Double?
    public var wordCount: Int
    /// The recognizer's own words, when `history_detail` captured them.
    public var heard: String?
    /// After dictionary corrections, before cleanup.
    public var corrected: String?
    /// After cleanup.
    public var refined: String?
    /// False when the text was saved but never reached the app; nil unknown.
    public var delivered: Bool?
    /// Cleanup's outcome (`applied`, `off`, `skipped_verbatim_app`, …).
    public var ai: String?
    /// The app the text went to; nil for rows from before it was recorded.
    public var appBundleID: String?
    /// The insertion rung.
    public var outcome: String?
    public var timing: DictationTiming?
    public var inputDevice: String?
    /// How far cleanup moved the text, from the matching metrics line —
    /// the "Polished" evidence for rows without the detail triple.
    public var refineDelta: Int?

    public init(id: Int64, ts: Double, text: String, engine: String, durationMs: Double? = nil,
                heard: String? = nil, corrected: String? = nil, refined: String? = nil,
                delivered: Bool? = nil, ai: String? = nil, appBundleID: String? = nil,
                outcome: String? = nil, timing: DictationTiming? = nil,
                inputDevice: String? = nil, refineDelta: Int? = nil) {
        self.id = id; self.ts = ts; self.text = text; self.engine = engine
        self.durationMs = durationMs
        self.wordCount = HomeModel.wordCount(text)
        self.heard = heard; self.corrected = corrected; self.refined = refined
        self.delivered = delivered; self.ai = ai; self.appBundleID = appBundleID
        self.outcome = outcome; self.timing = timing; self.inputDevice = inputDevice
        self.refineDelta = refineDelta
    }

    public var date: Date { Date(timeIntervalSince1970: ts) }
}

/// A hold that produced no text. There is no audio behind it — Wisprit keeps
/// none — so the row explains and advises; it never offers to retry.
public struct MissedCapture: Identifiable, Equatable, Sendable {
    /// The FIRST try's milliseconds since 1970: unique enough for one
    /// person's key presses, stable across reloads, and unmoved when a newer
    /// try joins the run — so a selected miss stays selected.
    public var id: Int64 { Int64((firstTs * 1000).rounded()) }
    /// The newest try in the run.
    public var ts: Double
    public var heldMs: Double
    public var audioMs: Double?
    public var reason: String?
    public var marginalAudio: Bool
    public var inputDevice: String?
    /// How many back-to-back tries this row stands for (see
    /// `DictationsModel.foldMisses`), and when the first of them was.
    public var count: Int
    public var firstTs: Double

    public init(ts: Double, heldMs: Double, audioMs: Double? = nil, reason: String? = nil,
                marginalAudio: Bool = false, inputDevice: String? = nil,
                count: Int = 1, firstTs: Double? = nil) {
        self.ts = ts; self.heldMs = heldMs; self.audioMs = audioMs; self.reason = reason
        self.marginalAudio = marginalAudio; self.inputDevice = inputDevice
        self.count = count; self.firstTs = firstTs ?? ts
    }

    public init(_ line: MetricsUtterance) {
        self.init(ts: line.ts, heldMs: line.heldMs, audioMs: line.audioMs,
                  reason: line.emptyReason, marginalAudio: line.marginalAudio,
                  inputDevice: line.inputDevice)
    }

    public var date: Date { Date(timeIntervalSince1970: ts) }
    public var copy: MissCopy { MissCopy.for(reason: reason, marginal: marginalAudio) }
}

/// One row of the page.
public enum DictationEntry: Identifiable, Equatable, Sendable {
    case dictation(DictationRecord)
    case missed(MissedCapture)

    public enum ID: Hashable, Sendable {
        case dictation(Int64)
        case missed(Int64)
    }

    public var id: ID {
        switch self {
        case .dictation(let record): return .dictation(record.id)
        case .missed(let miss): return .missed(miss.id)
        }
    }

    public var ts: Double {
        switch self {
        case .dictation(let record): return record.ts
        case .missed(let miss): return miss.ts
        }
    }

    public var date: Date { Date(timeIntervalSince1970: ts) }

    public var record: DictationRecord? {
        if case .dictation(let record) = self { return record }
        return nil
    }

    public var miss: MissedCapture? {
        if case .missed(let miss) = self { return miss }
        return nil
    }
}

/// A day's rows, newest day first.
public struct DictationDay: Identifiable, Equatable, Sendable {
    public var id: Date
    public var title: String
    public var entries: [DictationEntry]
}

// MARK: - what a miss says

/// The plain-language copy for one `empty_reason`. Every reason the engine can
/// write has its own; nil (rows from before reasons were recorded) and any
/// value a newer build invents get honest generic copy.
public struct MissCopy: Equatable, Sendable {
    /// The row's caption tail: "the mic was still connecting".
    public var short: String
    /// The inspector's headline.
    public var title: String
    /// What happened, in a sentence or two.
    public var explanation: String
    /// What to do about it.
    public var advice: String

    public static let rowTitle = "Didn't catch that"

    public static func `for`(reason: String?, marginal: Bool = false) -> MissCopy {
        switch reason {
        case "starved":
            return MissCopy(
                short: "the mic was still connecting",
                title: "The mic was still connecting",
                explanation: "The microphone sent no sound while the key was down. "
                    + "Bluetooth headsets often take a moment to wake up.",
                advice: "Press the key, wait a beat, then speak. If it keeps happening, "
                    + "choose another mic in Settings.")
        case "device_changed":
            return MissCopy(
                short: "the mic changed mid-sentence",
                title: "The mic changed while you spoke",
                explanation: "Your Mac switched microphones in the middle of the hold, "
                    + "so the recording stopped.",
                advice: "Hold the key and say it again on the new mic.")
        case "silent":
            return MissCopy(
                short: "it was quiet the whole time",
                title: "No speech came through",
                explanation: "The mic was on, but it heard only silence.",
                advice: "Speak while the key is down. If you did, check that the right "
                    + "mic is selected — it's named in the toolbar.")
        case "short_hold":
            return MissCopy(
                short: "the key came up too soon",
                title: "The key came up too soon",
                explanation: "The key was released before any words came through.",
                advice: "Keep holding the key until you finish speaking.")
        case "produced_nothing" where marginal:
            return MissCopy(
                short: "it was too faint to make out",
                title: "Too faint to make out",
                explanation: "Wisprit heard you, but your voice was barely above the "
                    + "room, and no words could be read from it.",
                advice: "Speak up, or move closer to the mic.")
        case "produced_nothing":
            return MissCopy(
                short: "heard speech but found no words",
                title: "Heard you, but found no words",
                explanation: "There was speech in the recording, but recognition "
                    + "returned nothing.",
                advice: "Say it again, a little closer to the mic.")
        case "timed_out":
            return MissCopy(
                short: "recognition ran out of time",
                title: "Recognition ran out of time",
                explanation: "Turning speech into text took too long, so the words "
                    + "were dropped.",
                advice: "Say it again.")
        case "crashed":
            return MissCopy(
                short: "speech recognition stopped",
                title: "Speech recognition stopped",
                explanation: "Recognition stopped unexpectedly before it returned any words.",
                advice: "Say it again. If it keeps happening, open Setup from the toolbar.")
        case nil:
            return MissCopy(
                short: "no reason was recorded",
                title: "No words came through",
                explanation: "This happened before Wisprit recorded why a capture "
                    + "came up empty.",
                advice: "Hold the key and say it again.")
        default:
            return MissCopy(
                short: "no words came through",
                title: "No words came through",
                explanation: "Wisprit didn't get any words from this hold.",
                advice: "Hold the key and say it again.")
        }
    }

    /// Said once, under every miss: why there is no Retry.
    public static let noAudioNote = "There's nothing to replay. Wisprit never keeps audio."
}

// MARK: - row chips

/// The quiet tags on a row.
public enum DictationChip: String, Equatable, Sendable, CaseIterable {
    /// Cleanup changed the wording.
    case polished = "Polished"
    /// Saved, but it never reached the app.
    case notPasted = "Not pasted"
}

// MARK: - the model

public enum DictationsModel {
    /// `metrics.log`'s `outcome` for a capture that produced nothing.
    public static let missOutcome = "empty"

    /// How far after its transcript a metrics line may land and still belong
    /// to it. The session writes history BEFORE delivery and the metrics line
    /// after it, so the gap is delivery plus the clipboard restore: measured
    /// 0.001–0.9 s across 647 real rows. Thirty seconds is slack for a stalled
    /// insert, not a guess at the norm.
    public static let matchWindowAfter: Double = 30
    /// The other side: a metrics line never precedes its transcript, but a
    /// clock step must not make a perfect `held_ms` match unmatchable.
    public static let matchWindowBefore: Double = 1
    /// `held_ms` is logged at one decimal; history keeps the full double.
    public static let heldTolerance: Double = 0.051
    /// Without a hold to compare (Python-era rows), only a near-simultaneous
    /// line is believable.
    public static let timeOnlyWindow: Double = 2

    // MARK: matching

    /// Fill each record's missing timing, cleanup outcome, mic and rung from
    /// the metrics line that belongs to it. Persisted values always win: the
    /// match is for rows written before the session persisted its own.
    ///
    /// A line belongs to a record when it is a delivery row, landed within
    /// [-1 s, +30 s] of the transcript, and — when the record has a hold
    /// duration — carries the same `held_ms` to the logged decimal. The
    /// nearest such line wins and is then spent: two records never share one.
    public static func match(_ records: [DictationRecord],
                             metrics: [MetricsUtterance]) -> [DictationRecord] {
        let deliveries = metrics.filter(\.isDelivery).sorted { $0.ts < $1.ts }
        guard !deliveries.isEmpty else { return records }
        let times = deliveries.map(\.ts)
        var used = Set<Int>()
        var out = records
        // Oldest first, so a burst of dictations claims lines in order.
        for index in out.indices.sorted(by: { out[$0].ts < out[$1].ts }) {
            let record = out[index]
            let lower = record.ts - matchWindowBefore
            let upper = record.ts + (record.durationMs == nil ? timeOnlyWindow : matchWindowAfter)
            var best: Int?
            var cursor = lowerBound(times, lower)
            while cursor < deliveries.count, times[cursor] <= upper {
                defer { cursor += 1 }
                guard !used.contains(cursor) else { continue }
                let line = deliveries[cursor]
                if let held = record.durationMs, abs(line.heldMs - held) > heldTolerance { continue }
                if let current = best,
                   abs(deliveries[current].ts - record.ts) <= abs(line.ts - record.ts) { continue }
                best = cursor
            }
            guard let best else { continue }
            used.insert(best)
            out[index] = merged(record, with: deliveries[best])
        }
        return out
    }

    private static func merged(_ record: DictationRecord, with line: MetricsUtterance) -> DictationRecord {
        var out = record
        let fromLine = DictationTiming(releaseToTextMs: line.releaseToTextMs,
                                       recognizeMs: line.finalizeMs,
                                       cleanupMs: line.aiMs)
        if let timing = out.timing, !timing.isEmpty {
            out.timing = DictationTiming(
                releaseToTextMs: timing.releaseToTextMs ?? fromLine.releaseToTextMs,
                recognizeMs: timing.recognizeMs ?? fromLine.recognizeMs,
                cleanupMs: timing.cleanupMs ?? fromLine.cleanupMs)
        } else if !fromLine.isEmpty {
            out.timing = fromLine
        }
        out.ai = out.ai ?? line.ai
        out.inputDevice = out.inputDevice ?? line.inputDevice
        out.outcome = out.outcome ?? line.outcome
        out.refineDelta = out.refineDelta ?? line.refineDelta
        if out.delivered == nil, ["blocked_secure", "error"].contains(line.outcome) {
            out.delivered = false
        }
        return out
    }

    private static func lowerBound(_ sorted: [Double], _ value: Double) -> Int {
        var low = 0, high = sorted.count
        while low < high {
            let mid = (low + high) / 2
            if sorted[mid] < value { low = mid + 1 } else { high = mid }
        }
        return low
    }

    // MARK: the timeline

    /// Dictations and misses, newest first.
    ///
    /// Misses are interleaved only as far back as the dictations reach: the
    /// page shows one page of history at a time, and a miss older than the
    /// oldest row on screen would sit under a "Load older" button that does
    /// not load it. When the page already holds everything (`isComplete`), or
    /// there is no saved dictation to anchor to, misses from the last
    /// `orphanMissWindow` are shown on their own.
    public static let orphanMissWindow: Double = 7 * 24 * 3600

    public static func timeline(records: [DictationRecord],
                                metrics: [MetricsUtterance],
                                isComplete: Bool,
                                now: Date) -> [DictationEntry] {
        let matched = match(records, metrics: metrics)
        let floor: Double
        if let oldest = records.map(\.ts).min(), !isComplete {
            floor = oldest
        } else if let oldest = records.map(\.ts).min() {
            floor = min(oldest, now.timeIntervalSince1970 - orphanMissWindow)
        } else {
            floor = now.timeIntervalSince1970 - orphanMissWindow
        }
        let misses = metrics.filter { $0.isMiss && $0.ts >= floor }.map(MissedCapture.init)
        let entries = matched.map(DictationEntry.dictation) + misses.map(DictationEntry.missed)
        return foldMisses(entries.sorted { $0.ts > $1.ts })
    }

    /// Back-to-back tries further apart than this stay separate rows.
    public static let missRunGap: Double = 10 * 60

    /// Fold a run of misses into one row: adjacent on the page (no dictation
    /// between them), the same reason, each within `missRunGap` of the next.
    /// A stalled mic produces exactly that — a handful of "it was quiet" rows
    /// in a minute — and identical rows push the words the user did say off
    /// the screen without telling them anything the first row does not.
    /// Different reasons stay apart: each one is different advice.
    public static func foldMisses(_ newestFirst: [DictationEntry]) -> [DictationEntry] {
        var out: [DictationEntry] = []
        for entry in newestFirst {
            guard case .missed(let older) = entry,
                  case .missed(var run)? = out.last,
                  run.reason == older.reason,
                  run.marginalAudio == older.marginalAudio,
                  run.firstTs - older.ts <= missRunGap else {
                out.append(entry)
                continue
            }
            run.count += older.count
            run.firstTs = older.firstTs
            run.inputDevice = run.inputDevice ?? older.inputDevice
            out[out.count - 1] = .missed(run)
        }
        return out
    }

    /// Search: case- and diacritic-insensitive over what was written AND what
    /// was heard — the misheard spelling is often the one a user remembers.
    /// Misses have no words and drop out of any search.
    public static func filter(_ entries: [DictationEntry], query: String) -> [DictationEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return entries }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return entries.filter { entry in
            guard let record = entry.record else { return false }
            if record.text.range(of: needle, options: options) != nil { return true }
            if let heard = record.heard, heard.range(of: needle, options: options) != nil { return true }
            return false
        }
    }

    public static func days(_ entries: [DictationEntry], now: Date, calendar: Calendar) -> [DictationDay] {
        var order: [Date] = []
        var buckets: [Date: [DictationEntry]] = [:]
        for entry in entries.sorted(by: { $0.ts > $1.ts }) {
            let day = calendar.startOfDay(for: entry.date)
            if buckets[day] == nil { order.append(day) }
            buckets[day, default: []].append(entry)
        }
        return order.map { day in
            DictationDay(id: day,
                         title: HomeModel.title(for: day, now: now, calendar: calendar),
                         entries: buckets[day] ?? [])
        }
    }

    /// ↑ / ↓ over the visible rows. With nothing selected (or a selection the
    /// filter hid), ↓ starts at the top and ↑ at the bottom.
    public static func move(_ selection: DictationEntry.ID?, by step: Int,
                            in entries: [DictationEntry]) -> DictationEntry.ID? {
        guard !entries.isEmpty else { return nil }
        guard let selection, let index = entries.firstIndex(where: { $0.id == selection }) else {
            return step >= 0 ? entries.first?.id : entries.last?.id
        }
        let next = min(max(index + step, 0), entries.count - 1)
        return entries[next].id
    }

    // MARK: chips

    public static func chips(for record: DictationRecord) -> [DictationChip] {
        var chips: [DictationChip] = []
        if isPolished(record) { chips.append(.polished) }
        if record.delivered == false { chips.append(.notPasted) }
        return chips
    }

    /// Cleanup ran AND changed the words. With the detail triple, that is
    /// `refined != corrected`; without it, the metrics line's edit distance
    /// stands in, and only alongside an `applied` outcome.
    public static func isPolished(_ record: DictationRecord) -> Bool {
        guard record.ai == "applied" else { return false }
        if let corrected = record.corrected, let refined = record.refined {
            return corrected != refined
        }
        return (record.refineDelta ?? 0) > 0
    }

    // MARK: the stat line

    /// Median key-up → text over the most recent `sample` deliveries that
    /// carry one, in seconds.
    public static func medianSecondsToText(_ metrics: [MetricsUtterance],
                                           sample: Int = HomeModel.defaultRateSample) -> Double? {
        let values = metrics
            .filter { $0.isDelivery && ($0.releaseToTextMs ?? 0) > 0 }
            .sorted { $0.ts > $1.ts }
            .prefix(max(0, sample))
            .compactMap(\.releaseToTextMs)
            .sorted()
        guard !values.isEmpty else { return nil }
        let mid = values.count / 2
        let ms = values.count % 2 == 1 ? values[mid] : (values[mid - 1] + values[mid]) / 2
        return ms / 1000.0
    }

    /// One part of the header: a value (drawn emphasized) and its label.
    public struct StatPart: Equatable, Sendable {
        public var lead: String
        public var value: String
        public var label: String

        public init(lead: String = "", value: String, label: String) {
            self.lead = lead; self.value = value; self.label = label
        }
    }

    /// "Today 27 words · 123 wpm · 0.20 s to text · 25,934 all time". A part
    /// with nothing behind it is left out rather than drawn as a zero.
    public static func statParts(stats: HomeStats?, secondsToText: Double?,
                                 decimal: (Int) -> String) -> [StatPart] {
        var parts: [StatPart] = []
        if let stats {
            parts.append(StatPart(lead: "Today ", value: decimal(stats.wordsToday),
                                  label: stats.wordsToday == 1 ? " word" : " words"))
            if let wpm = stats.medianWPM {
                parts.append(StatPart(value: "\(Int(wpm.rounded()))", label: " wpm"))
            }
        }
        if let seconds = secondsToText {
            parts.append(StatPart(value: String(format: "%.2f s", seconds), label: " to text"))
        }
        if let stats, stats.lifetimeWords > 0 {
            parts.append(StatPart(value: decimal(stats.lifetimeWords), label: " all time"))
        }
        return parts
    }

    // MARK: formatting

    /// "412 ms" under a second, "1.4 s" from there.
    public static func duration(ms: Double) -> String {
        if ms < 1000 { return "\(Int(ms.rounded())) ms" }
        return String(format: "%.1f s", ms / 1000.0)
    }

    /// "1.3 s of audio" — the length of the hold, one decimal.
    public static func heldLength(ms: Double) -> String {
        String(format: "%.1f s", ms / 1000.0)
    }

    /// A microphone's name as the user would recognise it, or nil when Core
    /// Audio handed over one of its own plumbing names — the aggregate device
    /// voice processing builds is called "CADefaultDeviceAggregate-1470-0".
    public static func micName(_ raw: String?) -> String? {
        guard let name = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
              !name.hasPrefix("CADefaultDevice"),
              !name.contains("Aggregate-") else { return nil }
        return name
    }

    /// The speech engine, in words. Every engine Wisprit has shipped runs on
    /// the Mac; an id this map does not know says only that.
    public static func speechEngineName(_ id: String) -> String {
        switch id {
        case "apple_live", "auto": return "Apple speech"
        case "apple_batch": return "Apple speech, second pass"
        case "mlx_whisper", "whisper": return "Whisper"
        case "parakeet": return "Parakeet"
        default: return "Speech recognition"
        }
    }

    /// What cleanup did, in words. nil when the outcome was never recorded.
    public static func cleanupDescription(_ ai: String?) -> String? {
        guard let ai else { return nil }
        switch ai {
        case "applied": return "Apple Intelligence"
        case "off": return "Off"
        case "skipped_verbatim_app": return "Skipped in this app"
        case "too_long": return "Skipped, too long"
        case "has_letter_run": return "Skipped, spelled-out letters"
        case "has_address": return "Skipped, contains an address"
        case "timeout": return "Ran out of time, kept as heard"
        case "cancelled", "preempted": return "Skipped"
        case "empty": return nil
        case "spawn_failed", "helper_error", "error", "bad_reply":
            return "Unavailable, kept as heard"
        default:
            // implausible / obeyed / dropped_content / paraphrased and any
            // later guard: cleanup ran and its rewrite was refused.
            return "Checked, kept as heard"
        }
    }

    /// Whether cleanup actually ran on this Mac (as opposed to being skipped).
    public static func cleanupRan(_ ai: String?) -> Bool {
        guard let ai else { return false }
        return !["off", "skipped_verbatim_app", "too_long", "has_letter_run",
                 "has_address", "cancelled", "preempted", "empty",
                 "spawn_failed", "helper_error", "error"].contains(ai)
    }

    // MARK: teach

    /// The spelling to prefill when the user teaches from a selection: the
    /// written word the diff paired with it, when the selection is exactly one
    /// changed heard run. Otherwise the user types it.
    public static func suggestedSpelling(for heardSelection: String,
                                         diff: WordDiff.Result) -> String? {
        let needle = heardSelection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return nil }
        let heardChanged = diff.heard.filter(\.changed)
        let writtenChanged = diff.written.filter(\.changed)
        guard heardChanged.count == writtenChanged.count,
              let index = heardChanged.firstIndex(where: {
                  $0.text.trimmingCharacters(in: .whitespaces) == needle
              }) else { return nil }
        return writtenChanged[index].text.trimmingCharacters(in: .whitespaces)
    }

    /// Trim a phrase the user selected for teaching: surrounding whitespace and
    /// the punctuation a drag-select picks up at a word's edges.
    public static func teachablePhrase(_ selection: String) -> String {
        let edges = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
            .subtracting(CharacterSet(charactersIn: "'’-"))
        return selection.trimmingCharacters(in: edges)
    }
}
