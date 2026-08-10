import Foundation
import WispritKit
import os

/// The auto-learn evidence ledger: `~/.wisprit/learn_pending.json`.
///
/// This is the rule that alone would have blocked every junk term the live learn
/// loop produced — each of them was seen in exactly ONE utterance. A candidate
/// that passes the plausibility gate is not learned; it is *recorded* here, and
/// only a second sighting **in a different utterance** makes it a proposal the
/// user is asked about. One utterance is a coincidence; two are evidence.
///
/// Not the same thing as `DictionaryStore`'s `pending: true` quarantine. That
/// one lives in `dictionary.json` and records a spelling the correction loop
/// half-believes. This file records *edit-derived* candidates — what the user
/// actually typed over what we inserted — plus the dismissals, which is why it
/// is a separate file: dictionary.json is hand-editable vocabulary, this is
/// machine bookkeeping the user never has to read.
///
/// File format (order-preserving, additive — unknown keys survive a write):
/// ```json
/// {"entries": [
///     {"term": "Sharique",
///      "observations": [{"heard": "Shariq", "at": "2026-08-09T12:00:00.000Z"}],
///      "first_seen": "2026-08-09T12:00:00.000Z",
///      "status": "proposed"}
/// ]}
/// ```
///
/// Threading: the record path runs on the session thread, `pending()` on the UI
/// thread when the Dictionary page draws its badge, so every public method takes
/// the instance lock. Every method degrades to a no-op rather than throwing — a
/// broken ledger must never take down dictation.
public final class PendingLearnStore: @unchecked Sendable {

    /// What a candidate is, right now.
    public enum Status: String, Sendable, Equatable {
        /// Recorded, and proposed to the user once it reaches the threshold.
        case proposed
        /// The user said no. A permanent negative — see `dismiss(term:)`.
        case dismissed
    }

    /// One sighting: what the ASR produced, and which utterance produced it.
    public struct Observation: Sendable, Equatable {
        /// The misrecognition this candidate was corrected from.
        public var heard: String
        /// The utterance's timestamp — also its identity. See `record`.
        public var at: Date

        public init(heard: String, at: Date) {
            self.heard = heard
            self.at = at
        }
    }

    public struct Entry: Sendable, Equatable {
        public var term: String
        public var observations: [Observation]
        public var firstSeen: Date
        public var status: Status
        /// Distinct utterances this term has been seen in.
        public var count: Int { observations.count }

        public init(term: String, observations: [Observation], firstSeen: Date, status: Status) {
            self.term = term
            self.observations = observations
            self.firstSeen = firstSeen
            self.status = status
        }
    }

    /// What `record` did, for the caller that has to decide whether to propose.
    public enum RecordResult: Sendable, Equatable {
        /// Evidence noted, not enough of it yet.
        case recorded
        /// This term now has `count` distinct-utterance observations, at or above
        /// the threshold — propose it.
        case reachedThreshold(count: Int)
        /// The user already said no. Nothing was written, and nothing ever will
        /// be for this term.
        case alreadyDismissed
    }

    /// `~/.wisprit/learn_pending.json`. Computed rather than stored so a test
    /// that moves `WispritPaths.overrideRoot` moves the file with it.
    public static var defaultPath: URL {
        WispritPaths.stateDir.appendingPathComponent("learn_pending.json")
    }

    /// Distinct-utterance sightings needed before a term is proposed.
    public let threshold: Int
    private let cap: Int
    private let maxAge: TimeInterval

    private let log = WLog.logger("learn-pending")
    private let lock = NSLock()
    private let url: URL

    /// - Parameters:
    ///   - threshold: distinct utterances required to propose. 2 is the gate the
    ///     live-junk audit picked: all three polluting terms had exactly one.
    ///   - cap: most entries kept; the oldest — first recorded, which is file
    ///     order — go first. Bounded because this file is written on a hot path
    ///     and read to draw a badge.
    ///   - maxAge: evidence older than this is stale and drops on load — a term
    ///     heard once in March is not corroborated by hearing it again in August.
    ///     Dismissals are exempt; a "no" does not expire.
    public init(path: URL = PendingLearnStore.defaultPath,
                threshold: Int = 2,
                cap: Int = 200,
                maxAge: TimeInterval = 30 * 86_400) {
        self.url = path
        self.threshold = max(1, threshold)
        self.cap = max(1, cap)
        self.maxAge = maxAge
    }

    public var path: URL { url }

    // MARK: - Reading

    /// Every live entry, in file order, dismissals included. The diagnostic view;
    /// `pending()` is what the UI wants.
    public func all() -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        return load()
    }

    /// Candidates the user should be asked about: `proposed`, and corroborated by
    /// at least `threshold` distinct utterances. This is the Dictionary-page
    /// badge count — a sub-threshold entry is evidence, not a proposal, and
    /// showing it would put the user back in the loop the threshold exists to
    /// keep them out of.
    public func pending() -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        return load().filter { $0.status == .proposed && $0.count >= threshold }
    }

    /// One entry by canonical spelling, matched case-insensitively like every
    /// other term lookup in this module. Includes dismissed entries.
    public func entry(for term: String) -> Entry? {
        let needle = Self.normalize(term)
        guard !needle.isEmpty else { return nil }
        lock.lock(); defer { lock.unlock() }
        return load().first { Self.normalize($0.term) == needle }
    }

    // MARK: - Writing

    /// Record one sighting of `term`, corrected from `heard`, in the utterance
    /// stamped `at`.
    ///
    /// `at` is the utterance's identity, not decoration: a term corrected twice
    /// inside the SAME utterance is one piece of evidence, not two, so a repeat
    /// of an `at` this term already carries is dropped rather than counted. That
    /// is the whole "distinct utterances" rule — without it, a single sentence
    /// that says a name twice would self-corroborate.
    @discardableResult
    public func record(term: String, heard: String, at: Date = Date()) -> RecordResult {
        let canonical = term.trimmingCharacters(in: .whitespacesAndNewlines)
        let phrase = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        // A blank term is not a candidate: nothing is written, and `.recorded`
        // says what the caller needs to hear — there is nothing to propose.
        guard !canonical.isEmpty else { return .recorded }

        lock.lock(); defer { lock.unlock() }
        var result = RecordResult.recorded
        mutate { list in
            let needle = Self.normalize(canonical)
            guard let index = list.firstIndex(where: {
                Self.normalize($0.objectValue?["term"]?.stringValue ?? "") == needle
            }) else {
                var entry = JSONObject()
                entry["term"] = .string(canonical)
                entry["observations"] = .array([Self.observation(heard: phrase, at: at)])
                entry["first_seen"] = .string(Self.stamp(at))
                entry["status"] = .string(Status.proposed.rawValue)
                list.append(.object(entry))
                result = 1 >= self.threshold ? .reachedThreshold(count: 1) : .recorded
                return true
            }

            guard var entry = list[index].objectValue else { return false }
            guard Self.status(entry) != .dismissed else {
                result = .alreadyDismissed
                return false
            }

            var observations = entry["observations"]?.arrayValue ?? []
            let stamp = Self.stamp(at)
            let isNewUtterance = !observations.contains {
                $0.objectValue?["at"]?.stringValue == stamp
            }
            if isNewUtterance { observations.append(Self.observation(heard: phrase, at: at)) }
            entry["observations"] = .array(observations)
            entry.setIfAbsent("first_seen", .string(stamp))
            entry.setIfAbsent("status", .string(Status.proposed.rawValue))
            list[index] = .object(entry)

            let count = observations.count
            result = count >= self.threshold ? .reachedThreshold(count: count) : .recorded
            // A same-utterance repeat changes nothing on disk; do not rewrite the
            // file just to prove it.
            return isNewUtterance
        }
        return result
    }

    /// Record the user's "no". The entry stays — as a negative — so the term is
    /// never proposed again, however much later evidence arrives. Unknown terms
    /// get an entry created for exactly that reason: dismissing something we have
    /// not recorded yet still has to stick.
    public func dismiss(term: String) {
        let canonical = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !canonical.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        mutate { list in
            let needle = Self.normalize(canonical)
            guard let index = list.firstIndex(where: {
                Self.normalize($0.objectValue?["term"]?.stringValue ?? "") == needle
            }) else {
                var entry = JSONObject()
                entry["term"] = .string(canonical)
                entry["observations"] = .array([])
                entry["first_seen"] = .string(Self.stamp(Date()))
                entry["status"] = .string(Status.dismissed.rawValue)
                list.append(.object(entry))
                return true
            }
            guard var entry = list[index].objectValue else { return false }
            entry["status"] = .string(Status.dismissed.rawValue)
            list[index] = .object(entry)
            return true
        }
    }

    /// Drop an entry once the integration layer has written the term into the
    /// real dictionary. Removal, not a status: the ledger's job was to gather
    /// evidence, and `dictionary.json` is now the record.
    ///
    /// - Returns: whether there was anything to remove.
    @discardableResult
    public func promoteConsumed(term: String) -> Bool {
        let needle = Self.normalize(term)
        guard !needle.isEmpty else { return false }
        lock.lock(); defer { lock.unlock() }
        var removed = false
        mutate { list in
            let before = list.count
            list.removeAll { Self.normalize($0.objectValue?["term"]?.stringValue ?? "") == needle }
            removed = list.count != before
            return removed
        }
        return removed
    }

    // MARK: - Load

    /// Parse the file into entries, dropping what has expired. Callers hold the
    /// lock. Expiry is applied to the in-memory view only — a read never writes;
    /// the stale rows physically disappear at the next `mutate`.
    private func load() -> [Entry] {
        Self.entries(from: Self.readRaw(url, log: log)).compactMap { item in
            guard let entry = Self.decode(item) else { return nil }
            return isExpired(entry) ? nil : entry
        }
    }

    private func isExpired(_ entry: Entry) -> Bool {
        // A dismissal is a decision, not evidence, so it does not age out.
        guard entry.status != .dismissed else { return false }
        let latest = entry.observations.map(\.at).max() ?? entry.firstSeen
        return Date().timeIntervalSince(latest) > maxAge
    }

    private static func decode(_ item: JSONValue) -> Entry? {
        guard let object = item.objectValue else { return nil }
        let term = (object["term"]?.stringValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return nil }

        let observations = (object["observations"]?.arrayValue ?? []).compactMap {
            item -> Observation? in
            guard let object = item.objectValue,
                  let at = parseDate(object["at"]?.stringValue) else { return nil }
            return Observation(heard: object["heard"]?.stringValue ?? "", at: at)
        }
        // A malformed first_seen falls back to the earliest observation rather
        // than to "now": treating a corrupt row as brand new would hand it
        // another 30 days of life.
        let firstSeen = parseDate(object["first_seen"]?.stringValue)
            ?? observations.map(\.at).min()
            ?? Date(timeIntervalSince1970: 0)
        return Entry(term: term, observations: observations,
                     firstSeen: firstSeen, status: status(object))
    }

    /// Anything that is not literally `"dismissed"` is a proposal — a corrupted
    /// status must fail toward asking the user, never toward silently learning.
    private static func status(_ object: JSONObject) -> Status {
        Status(rawValue: object["status"]?.stringValue ?? "") ?? .proposed
    }

    // MARK: - File IO

    private static func entries(from root: JSONValue) -> [JSONValue] {
        root.objectValue?["entries"]?.arrayValue ?? []
    }

    private static func readRaw(_ url: URL, log: Logger) -> JSONValue {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return .object(JSONObject())  // missing file: an empty ledger
        }
        do {
            let value = try JSONValue.parse(text)
            guard value.objectValue != nil else {
                log.error("learn_pending is not a JSON object; treating as empty")
                return .object(JSONObject())
            }
            return value
        } catch {
            // Same tolerance as the dictionary: a truncated or hand-mangled
            // ledger costs us evidence, never an utterance.
            log.error("cannot parse learn_pending; treating as empty: \(String(describing: error), privacy: .public)")
            return .object(JSONObject())
        }
    }

    /// Read-modify-write under the caller's lock, exactly as `DictionaryStore`
    /// does it: re-read from disk first so a concurrent writer is not clobbered,
    /// let `body` edit the raw entry list (so unknown keys on untouched entries
    /// survive byte-for-byte), then prune, cap, and write atomically.
    ///
    /// `body` returns whether anything changed; false skips the write entirely.
    private func mutate(_ body: (inout [JSONValue]) -> Bool) {
        var root = Self.readRaw(url, log: log)
        var list = Self.entries(from: root)
        let changed = body(&list)
        let pruned = prune(list)
        guard changed || pruned.count != list.count else { return }

        var object = root.objectValue ?? JSONObject()
        object["entries"] = .array(pruned)
        root = .object(object)
        write(root)
    }

    /// Expiry + the cap, applied to the raw list so the file self-heals.
    private func prune(_ list: [JSONValue]) -> [JSONValue] {
        var out = list.filter { item in
            guard let entry = Self.decode(item) else { return false }
            return !isExpired(entry)
        }
        // Oldest-first eviction, but a dismissal outranks an unreviewed proposal:
        // the user actually expressed the negative, and losing it would re-propose
        // something they already refused. Dismissals only go once they are all
        // that is left to drop.
        while out.count > cap {
            let index = out.firstIndex {
                Self.decode($0).map { $0.status != .dismissed } ?? true
            }
            out.remove(at: index ?? 0)
        }
        return out
    }

    private func write(_ root: JSONValue) {
        let text = root.serialized() + "\n"
        let directory = url.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: temporary)
            // fsync before rename: a crash must leave either the old ledger or
            // the new one, never a truncated one.
            if let handle = try? FileHandle(forWritingTo: temporary) {
                try? handle.synchronize()
                try? handle.close()
            }
            guard rename(temporary.path, url.path) == 0 else {
                throw CocoaError(.fileWriteUnknown)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            log.error("failed to write learn_pending: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Helpers

    private static func observation(heard: String, at: Date) -> JSONValue {
        var object = JSONObject()
        object["heard"] = .string(heard)
        object["at"] = .string(stamp(at))
        return .object(object)
    }

    private static func normalize(_ term: String) -> String {
        term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    // MARK: - Timestamps

    /// Fractional seconds, unlike `dictionary.json`'s learned_at: this stamp is
    /// an utterance IDENTITY, and two utterances inside one second are ordinary.
    private static let iso8601Fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func stamp(_ date: Date) -> String { iso8601Fractional.string(from: date) }

    /// Reads back both shapes, so a hand-written stamp without milliseconds is
    /// still a valid observation.
    private static func parseDate(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        return iso8601Fractional.date(from: text) ?? iso8601.date(from: text)
    }
}
