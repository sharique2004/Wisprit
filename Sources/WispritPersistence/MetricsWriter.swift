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

    public init(ts: Double = Date().timeIntervalSince1970,
                heldMs: Double, engine: String, finalizeMs: Double, timedOut: Bool,
                postMs: Double, insertMs: Double, outcome: String, chars: Int,
                releaseToTextMs: Double? = nil, aiMs: Double? = nil, ai: String? = nil) {
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
    public func write(_ metrics: UtteranceMetrics, ai: String? = nil) {
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
            ai: ai))
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
}
