import Foundation
import WispritKit

/// One JSON line per utterance appended to `~/.wisprit/metrics.log`.
///
/// The field names, their ORDER, and the rounding are copied from
/// `session.py::_log_metrics` on purpose: metrics.log is a single append-only
/// stream that spans the Python era and this one, and the analysis scripts read
/// it as one file. Optional fields are omitted (not null) when absent, exactly
/// as the Python does.
///
/// Two `outcome` values are NOT insertion methods and do not describe an
/// utterance's delivery — both are deliberate deviations, recorded in
/// `docs/notes/deviations.md`:
///
///  * `correction` — a spoken-spelling directive that legitimately left nothing
///    to insert. Logging it as `empty` would inflate the empty-rate metric with
///    successes.
///  * `vocab_retro` — the off-path vocabulary reconciliation, which finishes
///    1–2.5 s AFTER its utterance's row is already on disk and so cannot ride
///    it. A reference-less second line carrying `vocab_ms` / `vocab_hits` /
///    `vocab_delta` / `applied` is the honest shape; attributing the numbers to
///    the next utterance's row would not be. One such row is written per
///    completed reconciliation, at the moment `applied` is finally known. For
///    a plan whose deferred application a new utterance discards, that moment
///    is the discard itself, and the row says so (`apply_detail: "dropped"`,
///    2026-08-12) — a proposal must never vanish from the stream silently.

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
    // The `vocab_retro` row only (see the note above). Four fields, never on an
    // utterance row, and still appended after everything that precedes them.
    public var vocabMs: Double?      // how long the biased re-transcription took
    public var vocabHits: Int?       // dictionary terms it recovered, counting repeats
    public var vocabDelta: Int?      // 0/1: the planner proposed at least one edit
    public var applied: Bool?        // an edit actually landed in the user's field
    // Phase-4 context awareness, utterance rows only, appended after the whole
    // tail above. Omitted entirely while the consent flag is off — the
    // default-off install never grows a byte. `ctx` names the capture cycle's
    // outcome (read|late|busy|off); the STATUS vocabulary only, never text.
    public var ctx: String?          // ContextReadStatus.rawValue
    public var ctxMs: Double?        // key-down → snapshot arrival
    public var ctxTerms: Int?        // candidates fed to the vocabulary channel
    // The Phase-5 `edit_observed` row only — the `vocab_retro` precedent again:
    // a reference-less line written when the pipeline finally saw what became
    // of text it inserted, which is one-to-many utterances later. Never on an
    // utterance row.
    public var editDist: Int?        // 0 = zero-edit; absent on an observed edit whose size is unknowable
    public var editScope: String?    // "im" | "ax" — which reader observed it
    // R6 (2026-08-10): the paste rung's post-delivery custody window, split
    // out of `release_to_text_ms`/`insert_ms`, which now stop at delivery —
    // the metric-correction discontinuity recorded in docs/notes/deviations.md.
    public var restoreMs: Double?    // delivery → insert() return (sleep + clipboard restore)
    public var repressQueued: Bool?  // a press was waiting when the restore window closed (R34's counter)
    // R4 (2026-08-10): the capture session's acoustic pair, utterance rows.
    public var noiseFloor: Double?   // quietest ~300 ms window, meter scale (RMS×4, clamped) like peak_level
    public var firstVoicedMs: Double? // mic-live → first ≥-voiced-threshold chunk
    // R14: the one-time `onboarding` row only (reference-less, like vocab_retro).
    public var onboardMs: Double?    // first launch → first successful dictation
    public var stepsSkipped: Int?    // onboarding steps the user skipped
    public var relaunches: Int?      // relaunch count before the first dictation
    // 2026-08-12: the `vocab_retro` row's diagnosis trio — why `applied` is
    // false. Before these, applied:false could mean a correct planner refusal,
    // a real apply failure, or a dropped plan, indistinguishably.
    public var vocabRefusal: String? // VocabularyRetroRefusal.rawValue: the gate that proposed nothing
    public var rung: String?         // the utterance's insertion `outcome`, carried onto its retro row
    public var applyDetail: String?  // why a proposed edit did not land:
                                     // IMEditDetail.rawValue | not_engaged | no_reply | dropped
    // 2026-08-15: the audio hardware was reconfigured under this utterance's
    // capture (default input changed, or its format did). Utterance rows only,
    // and only when true — the 2026-08-05 incident's five empty rows carried no
    // field that separated them from an ordinary silent hold, which is what
    // made the log unreadable. `true` also appears on rows WITH text: a
    // mid-utterance switch truncates silently, and that is the shape worth
    // counting.
    public var configChanged: Bool?
    // 2026-08-15, the quiet-speech trio. Utterance rows only, each omitted
    // unless it has something to say, so an ordinary loud dictation's row does
    // not grow a byte.
    //
    /// Voiced audio the room nearly swallowed: `peak_level` under 0.12 with
    /// `peak_level / noise_floor` under 5 (≈14 dB). The rate of THIS is the
    /// series to watch — it is the class the 3.2× WER penalty lives in, and the
    /// one no gain stage can fix.
    public var marginalAudio: Bool?
    /// The batch rescue read a peak-normalized copy of the retained audio.
    public var rescueNormalized: Bool?
    /// …by this much, in dB. Two fields rather than one on purpose: the flag
    /// counts the rows, the number says how far the audio had to be dragged.
    public var appliedGainDb: Double?

    public init(ts: Double = Date().timeIntervalSince1970,
                heldMs: Double, engine: String, finalizeMs: Double, timedOut: Bool,
                postMs: Double, insertMs: Double, outcome: String, chars: Int,
                releaseToTextMs: Double? = nil, aiMs: Double? = nil, ai: String? = nil,
                emptyReason: String? = nil, peakLevel: Double? = nil,
                audioMs: Double? = nil, rawChars: Int? = nil, refineDelta: Int? = nil,
                vocabMs: Double? = nil, vocabHits: Int? = nil, vocabDelta: Int? = nil,
                applied: Bool? = nil,
                ctx: String? = nil, ctxMs: Double? = nil, ctxTerms: Int? = nil,
                editDist: Int? = nil, editScope: String? = nil,
                restoreMs: Double? = nil, repressQueued: Bool? = nil,
                noiseFloor: Double? = nil, firstVoicedMs: Double? = nil,
                onboardMs: Double? = nil, stepsSkipped: Int? = nil,
                relaunches: Int? = nil,
                vocabRefusal: String? = nil, rung: String? = nil,
                applyDetail: String? = nil,
                configChanged: Bool? = nil,
                marginalAudio: Bool? = nil,
                rescueNormalized: Bool? = nil,
                appliedGainDb: Double? = nil) {
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
        self.vocabMs = vocabMs
        self.vocabHits = vocabHits
        self.vocabDelta = vocabDelta
        self.applied = applied
        self.ctx = ctx
        self.ctxMs = ctxMs
        self.ctxTerms = ctxTerms
        self.editDist = editDist
        self.editScope = editScope
        self.restoreMs = restoreMs
        self.repressQueued = repressQueued
        self.noiseFloor = noiseFloor
        self.firstVoicedMs = firstVoicedMs
        self.onboardMs = onboardMs
        self.stepsSkipped = stepsSkipped
        self.relaunches = relaunches
        self.vocabRefusal = vocabRefusal
        self.rung = rung
        self.applyDetail = applyDetail
        self.configChanged = configChanged
        self.marginalAudio = marginalAudio
        self.rescueNormalized = rescueNormalized
        self.appliedGainDb = appliedGainDb
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
        // The `vocab_retro` row's own four, last of all.
        if let vocabMs { entry["vocab_ms"] = .double(MetricsWriter.round1(vocabMs)) }
        if let vocabHits { entry["vocab_hits"] = .int(vocabHits) }
        if let vocabDelta { entry["vocab_delta"] = .int(vocabDelta) }
        if let applied { entry["applied"] = .bool(applied) }
        // Context awareness, after everything: an utterance row and a
        // `vocab_retro` row never carry both families, so every row written by
        // any earlier build remains a byte-for-byte prefix of this schema.
        if let ctx { entry["ctx"] = .string(ctx) }
        if let ctxMs { entry["ctx_ms"] = .double(MetricsWriter.round1(ctxMs)) }
        if let ctxTerms { entry["ctx_terms"] = .int(ctxTerms) }
        // The `edit_observed` row's own two, after everything: no row carries
        // both these and the vocab/ctx families, so every earlier build's row
        // stays a byte-for-byte prefix of this schema.
        if let editDist { entry["edit_dist"] = .int(editDist) }
        if let editScope { entry["edit_scope"] = .string(editScope) }
        // 2026-08-10 additions, strictly after every key above — the same
        // append-only rule, one more round. R6's split pair first, then R4's
        // acoustic pair, then the `onboarding` row's own three (never on an
        // utterance row).
        if let restoreMs { entry["restore_ms"] = .double(MetricsWriter.round1(restoreMs)) }
        if let repressQueued { entry["repress_queued"] = .bool(repressQueued) }
        if let noiseFloor { entry["noise_floor"] = .double(MetricsWriter.round4(noiseFloor)) }
        if let firstVoicedMs { entry["first_voiced_ms"] = .double(MetricsWriter.round1(firstVoicedMs)) }
        if let onboardMs { entry["onboard_ms"] = .double(MetricsWriter.round1(onboardMs)) }
        if let stepsSkipped { entry["steps_skipped"] = .int(stepsSkipped) }
        if let relaunches { entry["relaunches"] = .int(relaunches) }
        // The `vocab_retro` diagnosis trio (2026-08-12), strictly after every
        // key above — the append-only rule once more. Absent on every row an
        // earlier build could have written, so those stay byte-for-byte prefixes.
        if let vocabRefusal { entry["vocab_refusal"] = .string(vocabRefusal) }
        if let rung { entry["rung"] = .string(rung) }
        if let applyDetail { entry["apply_detail"] = .string(applyDetail) }
        // 2026-08-15, last of all — the append-only rule once more. Absent on
        // every row any earlier build could have written, so those stay
        // byte-for-byte prefixes of this schema.
        if let configChanged { entry["config_changed"] = .bool(configChanged) }
        // The quiet-speech trio (2026-08-15), after every key above — the
        // append-only rule once more, and the last three keys any reader of this
        // stream has to know about. Absent from every row an earlier build could
        // have written, so those stay byte-for-byte prefixes of this schema.
        if let marginalAudio { entry["marginal_audio"] = .bool(marginalAudio) }
        if let rescueNormalized { entry["rescue_normalized"] = .bool(rescueNormalized) }
        if let appliedGainDb { entry["applied_gain_db"] = .double(MetricsWriter.round1(appliedGainDb)) }
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
    public static let vocabMs = "vocab_ms"
    public static let vocabHits = "vocab_hits"
    public static let vocabDelta = "vocab_delta"
    // `empty_reason` is a string and `applied` a bool, so neither has a slot in
    // `UtteranceMetrics.fields` ([String: Double]). `empty_reason` rides beside
    // `ai` on the bridge; `applied` only ever appears on the `vocab_retro` row,
    // which the session writes as a `MetricsRecord` directly.
    public static let emptyReason = "empty_reason"
    public static let applied = "applied"
    // Context awareness (Phase 4). The session writes these as a
    // `MetricsRecord` directly too; `ctx` is a string like `empty_reason`.
    public static let ctx = "ctx"
    public static let ctxMs = "ctx_ms"
    public static let ctxTerms = "ctx_terms"
    // R6/R4 (2026-08-10). Session-written `MetricsRecord` fields; named here so
    // readers share one vocabulary with the writer.
    public static let restoreMs = "restore_ms"
    public static let repressQueued = "repress_queued"
    public static let noiseFloor = "noise_floor"
    public static let firstVoicedMs = "first_voiced_ms"
    // The `onboarding` row (R14).
    public static let onboardMs = "onboard_ms"
    public static let stepsSkipped = "steps_skipped"
    public static let relaunches = "relaunches"
    // The `vocab_retro` diagnosis trio (2026-08-12) — strings, session-written
    // as a `MetricsRecord` directly, like `applied`.
    public static let vocabRefusal = "vocab_refusal"
    public static let rung = "rung"
    public static let applyDetail = "apply_detail"
    /// The audio hardware reconfigured mid-utterance (2026-08-15).
    public static let configChanged = "config_changed"
    // The quiet-speech trio (2026-08-15). Session-written `MetricsRecord`
    // fields; named here so readers share one vocabulary with the writer.
    public static let marginalAudio = "marginal_audio"
    public static let rescueNormalized = "rescue_normalized"
    public static let appliedGainDb = "applied_gain_db"
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

    /// The one-time time-to-wow row (R14): first launch → first successful
    /// dictation, written by the onboarding model through this entry point so
    /// the schema stays owned in one place. Reference-less like `vocab_retro`
    /// (no engine produced it — `engine` is the empty string) and dropped from
    /// every utterance stat by `MetricsSummary.nonUtteranceOutcomes`.
    public func writeOnboarding(firstLaunchToDictateMs: Double,
                                stepsSkipped: Int,
                                relaunchCount: Int) {
        write(MetricsRecord(
            heldMs: 0, engine: "", finalizeMs: 0, timedOut: false,
            postMs: 0, insertMs: 0, outcome: "onboarding", chars: 0,
            onboardMs: firstLaunchToDictateMs,
            stepsSkipped: stepsSkipped,
            relaunches: relaunchCount))
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
    /// is finer than the 0.01 voiced threshold needs (it was written against an
    /// earlier 0.02 and the comment outlived it) and keeps the line short. The
    /// resolution matters now that `noise_floor` shares the rounder: the
    /// marginal-audio ratio divides two of these.
    static func round4(_ x: Double) -> Double {
        guard x.isFinite, x.magnitude < 1e11 else { return x }
        return Double(String(format: "%.4f", x)) ?? x
    }
}
