import Foundation
import WispritKit

/// One JSON line per utterance appended to `~/.wisprit/metrics.log`.
///
/// The field names, their ORDER, and the rounding are copied from
/// `session.py::_log_metrics` on purpose: metrics.log is a single append-only
/// stream that spans the Python era and this one, and the analysis scripts read
/// it as one file. Optional fields are omitted (not null) when absent, exactly
/// as the Python does.

public struct MetricsRecord: Sendable {
    public var ts: Double            // wall-clock seconds, Python's time.time()
    public var heldMs: Double
    public var engine: String
    public var finalizeMs: Double
    public var timedOut: Bool
    public var postMs: Double
    public var insertMs: Double
    public var outcome: String       // insert method | "empty"
    public var chars: Int
    public var releaseToTextMs: Double?
    public var aiMs: Double?
    public var ai: String?           // refine outcome vocabulary
    // Telemetry added after the Python era. Everything below is appended AFTER
    // `ai` and omitted when nil, so a row written by this build is still a
    // superset of a row written by any earlier one and the stream stays one file.
    public var emptyReason: String?  // EmptyReason.rawValue; only on outcome == "empty"
    public var peakLevel: Double?    // loudest metered level, 0…1
    public var audioMs: Double?      // audio actually handed to the engine
    public var rawChars: Int?        // chars before refine, so `chars` can be read as a delta
    public var refineDelta: Int?     // edit distance raw → refined: the over-rewrite alarm

    public init(ts: Double = Date().timeIntervalSince1970,
                heldMs: Double, engine: String, finalizeMs: Double, timedOut: Bool,
                postMs: Double, insertMs: Double, outcome: String, chars: Int,
                releaseToTextMs: Double? = nil, aiMs: Double? = nil, ai: String? = nil,
                emptyReason: String? = nil, peakLevel: Double? = nil,
                audioMs: Double? = nil, rawChars: Int? = nil, refineDelta: Int? = nil) {
        self.ts = ts
        self.heldMs = heldMs
        self.engine = engine
        self.finalizeMs = finalizeMs
        self.timedOut = timedOut
        self.postMs = postMs
        self.insertMs = insertMs
        self.outcome = outcome
        self.chars = chars
        self.releaseToTextMs = releaseToTextMs
        self.aiMs = aiMs
        self.ai = ai
        self.emptyReason = emptyReason
        self.peakLevel = peakLevel
        self.audioMs = audioMs
        self.rawChars = rawChars
        self.refineDelta = refineDelta
    }

    /// The exact line `session.py` writes, newline included.
    public func jsonLine() -> String {
        var entry = JSONObject()
        entry["ts"] = .double(ts)                                  // never rounded
        entry["held_ms"] = .double(MetricsWriter.round1(heldMs))
        entry["engine"] = .string(engine)
        entry["finalize_ms"] = .double(MetricsWriter.round1(finalizeMs))
        entry["timed_out"] = .bool(timedOut)
        entry["post_ms"] = .double(MetricsWriter.round1(postMs))
        entry["insert_ms"] = .double(MetricsWriter.round1(insertMs))
        entry["outcome"] = .string(outcome)
        entry["chars"] = .int(chars)
        if let releaseToTextMs { entry["release_to_text_ms"] = .double(MetricsWriter.round1(releaseToTextMs)) }
        if let aiMs { entry["ai_ms"] = .double(MetricsWriter.round1(aiMs)) }
        if let ai { entry["ai"] = .string(ai) }
        // Post-Python fields, strictly after `ai`: the prefix above must stay
        // byte-identical or the merged stream stops being one stream.
        if let emptyReason { entry["empty_reason"] = .string(emptyReason) }
        if let peakLevel { entry["peak_level"] = .double(MetricsWriter.round4(peakLevel)) }
        if let audioMs { entry["audio_ms"] = .double(MetricsWriter.round1(audioMs)) }
        if let rawChars { entry["raw_chars"] = .int(rawChars) }
        if let refineDelta { entry["refine_delta"] = .int(refineDelta) }
        return WispritJSON.serializeCompact(.object(entry)) + "\n"
    }
}

/// Field keys used when bridging a `WispritKit.UtteranceMetrics` — the session
/// layer fills `fields` with these names, which are the on-disk names.
public enum MetricsField {
    public static let ts = "ts"
    public static let heldMs = "held_ms"
    public static let finalizeMs = "finalize_ms"
    public static let timedOut = "timed_out"        // 0 / 1
    public static let postMs = "post_ms"
    public static let insertMs = "insert_ms"
    public static let chars = "chars"
    public static let releaseToTextMs = "release_to_text_ms"
    public static let aiMs = "ai_ms"
    public static let peakLevel = "peak_level"
    public static let audioMs = "audio_ms"
    public static let rawChars = "raw_chars"
    public static let refineDelta = "refine_delta"
    // `empty_reason` is a string, so it has no slot in `UtteranceMetrics.fields`
    // ([String: Double]) and rides beside `ai` on the bridge instead.
    public static let emptyReason = "empty_reason"
}

public final class MetricsWriter: @unchecked Sendable {
    private let path: URL
    private let lock = NSLock()
    private let log = WLog.logger("metrics")

    public init(path: URL = WispritPaths.metricsPath) {
        self.path = path
    }

    public var metricsPath: URL { path }

    /// Append one record. Never throws: a failed metrics write must not take
    /// down an utterance.
    public func write(_ record: MetricsRecord) {
        lock.lock(); defer { lock.unlock() }
        do {
            try AtomicWrite.appendLine(record.jsonLine(), to: path)
        } catch {
            log.error("metrics log write failed")
        }
    }

    /// Bridge from the cross-module `UtteranceMetrics`. `timed_out` rides in
    /// `fields` as 0/1 and `chars` as a whole number, because that struct's
    /// payload is `[String: Double]`; `ai` has no slot there at all, so the
    /// refine outcome is passed alongside.
    public func write(_ metrics: UtteranceMetrics, ai: String? = nil,
                      emptyReason: String? = nil) {
        let f = metrics.fields
        write(MetricsRecord(
            ts: f[MetricsField.ts] ?? Date().timeIntervalSince1970,
            heldMs: f[MetricsField.heldMs] ?? 0,
            engine: metrics.engine,
            finalizeMs: f[MetricsField.finalizeMs] ?? 0,
            timedOut: (f[MetricsField.timedOut] ?? 0) != 0,
            postMs: f[MetricsField.postMs] ?? 0,
            insertMs: f[MetricsField.insertMs] ?? 0,
            outcome: metrics.outcome,
            chars: Int((f[MetricsField.chars] ?? 0).rounded()),
            releaseToTextMs: f[MetricsField.releaseToTextMs],
            aiMs: f[MetricsField.aiMs],
            ai: ai,
            emptyReason: emptyReason,
            peakLevel: f[MetricsField.peakLevel],
            audioMs: f[MetricsField.audioMs],
            rawChars: f[MetricsField.rawChars].map { Int($0.rounded()) },
            refineDelta: f[MetricsField.refineDelta].map { Int($0.rounded()) }))
    }

    /// Read the stream back, newest last, skipping unparsable lines (the file
    /// spans app versions and a torn tail is possible after a hard kill).
    public func readAll() -> [JSONObject] {
        guard let text = try? String(contentsOf: path, encoding: .utf8) else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: true).compactMap {
            guard case .object(let object)? = try? WispritJSON.parse(String($0)) else { return nil }
            return object
        }
    }

    /// CPython's `round(x, 1)`: correct decimal rounding of the exact binary
    /// value, ties to even. `%.1f` implements the same rule, and the resulting
    /// one-decimal value is its own shortest round-trip repr, so the printed
    /// digits match Python's. Guard the exponent range where `%f` and repr
    /// would disagree — no real duration goes there.
    static func round1(_ x: Double) -> Double {
        guard x.isFinite, x.magnitude < 1e15 else { return x }
        return Double(String(format: "%.1f", x)) ?? x
    }

    /// Same rule at four decimals, for `peak_level`. The level is a `Float`
    /// widened to `Double`, so it arrives as 0.03700000047683716; four decimals
    /// is finer than the 0.02 voiced threshold needs and keeps the line short.
    static func round4(_ x: Double) -> Double {
        guard x.isFinite, x.magnitude < 1e11 else { return x }
        return Double(String(format: "%.4f", x)) ?? x
    }
}
