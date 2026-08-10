import Foundation

/// Everything about the machine and the build that produced a row. Recorded
/// because an accuracy number without it is a rumour: the on-device model is
/// replaced in macOS point releases, the prompt is eval-locked, and the
/// dictionary changes under the user's hands.
///
/// The caller supplies every value — this library reads no clocks, runs no
/// `git`, and hashes nothing, so a rendered section is a pure function of its
/// inputs and a golden test is possible.
public struct RunProvenance: Codable, Equatable, Sendable {
    public var gitSha: String
    public var osBuild: String
    /// sha256 of `RefineInstructions.text`.
    public var promptSha256: String
    public var dictionaryTerms: Int
    /// `EvalInfo.scorerVersion` at the time the row was produced.
    public var scorerVersion: Int
    public var corpusSource: CorpusSource

    public init(gitSha: String, osBuild: String, promptSha256: String, dictionaryTerms: Int,
                scorerVersion: Int = EvalInfo.scorerVersion, corpusSource: CorpusSource) {
        self.gitSha = gitSha; self.osBuild = osBuild; self.promptSha256 = promptSha256
        self.dictionaryTerms = dictionaryTerms; self.scorerVersion = scorerVersion
        self.corpusSource = corpusSource
    }
}

/// One row of the per-stage table. Stage names mirror
/// `SessionController.finalizeUtterance` order (raw, corrected, refined, final)
/// so a regression can be attributed to a stage, not just to "the pipeline".
public struct StageMetrics: Codable, Equatable, Sendable {
    public var stage: String
    public var utterances: Int
    public var refWords: Int
    public var errors: Int
    public var wer: Double?
    public var cer: Double?
    public var termRecall: Double?
    public var zeroEdit: Double?
    /// Share of utterances whose hypothesis at this stage is empty. WER cannot
    /// see this failure mode (an empty hypothesis scores as deletions,
    /// indistinguishable from garbled text), and it is the failure the live
    /// path actually hits (`outcome: empty`). Optional so records written
    /// before the field existed still decode; nil renders as `—`, never as 0.
    public var emptyRate: Double?

    public init(stage: String, utterances: Int, refWords: Int, errors: Int,
                wer: Double? = nil, cer: Double? = nil,
                termRecall: Double? = nil, zeroEdit: Double? = nil,
                emptyRate: Double? = nil) {
        self.stage = stage; self.utterances = utterances
        self.refWords = refWords; self.errors = errors
        self.wer = wer; self.cer = cer; self.termRecall = termRecall; self.zeroEdit = zeroEdit
        self.emptyRate = emptyRate
    }
}

public struct CategoryMetrics: Codable, Equatable, Sendable {
    public var category: String
    public var utterances: Int
    public var wer: Double?
    public var termRecall: Double?
    /// See `StageMetrics.emptyRate`. Per category because the robustness deck
    /// encodes its conditions as categories, and "which cell went silent" is
    /// the question the deck exists to answer.
    public var emptyRate: Double?

    public init(category: String, utterances: Int, wer: Double? = nil,
                termRecall: Double? = nil, emptyRate: Double? = nil) {
        self.category = category; self.utterances = utterances
        self.wer = wer; self.termRecall = termRecall
        self.emptyRate = emptyRate
    }
}

/// The machine-readable half of a scoreboard entry — written to
/// `docs/eval/runs/*.json` and diffed by `compare`.
public struct RunSummary: Codable, Equatable, Sendable {
    /// ISO-8601, supplied by the caller.
    public var timestamp: String
    public var corpusId: String
    public var split: String
    public var engine: String
    /// The pipeline configuration this run measured, e.g. "refine=on,dict=on".
    public var config: String
    public var provenance: RunProvenance
    public var stages: [StageMetrics]
    public var categories: [CategoryMetrics]
    /// Which stage the category table was computed at. Nil means `final` (the
    /// historical behaviour); the robustness deck records `raw`, because its
    /// axes attack the engine and the final-stage table conflates engine damage
    /// with pipeline repair. Optional so summaries written before the field
    /// existed still decode.
    public var categoryStage: String?
    /// Weighted aggregate from `RefineBattery`, when the run included it.
    public var battery: Double?
    public var notes: String?

    public init(timestamp: String, corpusId: String, split: String, engine: String,
                config: String, provenance: RunProvenance, stages: [StageMetrics],
                categories: [CategoryMetrics] = [], categoryStage: String? = nil,
                battery: Double? = nil, notes: String? = nil) {
        self.timestamp = timestamp; self.corpusId = corpusId; self.split = split
        self.engine = engine; self.config = config; self.provenance = provenance
        self.stages = stages; self.categories = categories
        self.categoryStage = categoryStage
        self.battery = battery; self.notes = notes
    }
}

// MARK: - baseline

public enum BaselineMetric: String, Codable, Equatable, Sendable, CaseIterable {
    case wer
    case cer
    case termRecall
    case zeroEdit
    case emptyRate
    case battery

    /// WER, CER and the empty rate are error rates; everything else is a hit
    /// rate.
    public var lowerIsBetter: Bool { self == .wer || self == .cer || self == .emptyRate }
}

/// One accepted number and how far it is allowed to drift before the run is a
/// regression. The band exists because the refine stage is stochastic — a hard
/// equality here would make the scoreboard flap.
public struct BaselineBand: Codable, Equatable, Sendable {
    public var stage: String
    public var metric: BaselineMetric
    public var accepted: Double
    public var tolerance: Double

    public init(stage: String, metric: BaselineMetric, accepted: Double, tolerance: Double) {
        self.stage = stage; self.metric = metric
        self.accepted = accepted; self.tolerance = tolerance
    }
}

public struct BaselineRecord: Codable, Equatable, Sendable {
    public var corpus: String
    public var config: String
    public var bands: [BaselineBand]

    public init(corpus: String, config: String, bands: [BaselineBand]) {
        self.corpus = corpus; self.config = config; self.bands = bands
    }
}

/// `docs/eval/BASELINE.json`: the accepted numbers per (corpus, config).
public struct Baseline: Codable, Equatable, Sendable {
    public var records: [BaselineRecord]

    public init(records: [BaselineRecord] = []) { self.records = records }

    public func record(corpus: String, config: String) -> BaselineRecord? {
        records.first { $0.corpus == corpus && $0.config == config }
    }
}

public struct BaselineViolation: Equatable, Sendable, CustomStringConvertible {
    public var corpus: String
    public var config: String
    public var stage: String
    public var metric: BaselineMetric
    public var accepted: Double
    public var tolerance: Double
    /// Nil when the run did not produce the metric at all.
    public var observed: Double?

    public init(corpus: String, config: String, stage: String, metric: BaselineMetric,
                accepted: Double, tolerance: Double, observed: Double?) {
        self.corpus = corpus; self.config = config; self.stage = stage; self.metric = metric
        self.accepted = accepted; self.tolerance = tolerance; self.observed = observed
    }

    public var description: String {
        let where_ = "\(corpus)/\(config) \(stage).\(metric.rawValue)"
        guard let observed else { return "\(where_): not measured (baseline \(accepted))" }
        let direction = metric.lowerIsBetter ? "<=" : ">="
        let limit = metric.lowerIsBetter ? accepted + tolerance : accepted - tolerance
        return String(format: "%@: %.4f, expected %@ %.4f", where_, observed, direction, limit)
    }
}

// MARK: - renderer

/// Pure renderers plus a thin appender. Nothing here decides *what* the numbers
/// are; it decides how they are written down so that a row is self-describing
/// six months later.
public enum Scoreboard {

    /// The banner a TTS row must carry. `say -v Samantha` audio proves the
    /// plumbing works and nothing else — it is not human speech and must never
    /// be quoted as accuracy.
    public static let ttsBanner = "TTS corpus — plumbing check only, not an accuracy claim"

    /// One appendable RESULTS.md section.
    public static func markdownSection(for run: RunSummary) -> String {
        var out: [String] = []
        out.append("## \(run.timestamp) — \(run.corpusId)/\(run.split) — \(run.engine) — "
                   + "`\(run.config)`")
        out.append("")
        if run.provenance.corpusSource == .tts {
            out.append("> **\(ttsBanner)**")
            out.append("")
        }
        out.append(provenanceLine(run.provenance))
        out.append("")
        out.append("| stage | n | ref words | errors | WER | CER | term recall | zero-edit "
                   + "| empty |")
        out.append("|---|---:|---:|---:|---:|---:|---:|---:|---:|")
        for stage in run.stages {
            out.append("| \(stage.stage) | \(stage.utterances) | \(stage.refWords) "
                       + "| \(stage.errors) | \(percent(stage.wer)) | \(percent(stage.cer)) "
                       + "| \(rate(stage.termRecall)) | \(rate(stage.zeroEdit)) "
                       + "| \(percent(stage.emptyRate)) |")
        }
        if let battery = run.battery {
            out.append("")
            out.append("Refine battery: **\(rate(battery))** (weighted)")
        }
        if !run.categories.isEmpty {
            out.append("")
            // The historical table was final-stage; only a deliberate non-final
            // choice renames the header, so old sections read unchanged.
            out.append(run.categoryStage.map { "### By category (\($0) stage)" }
                       ?? "### By category")
            out.append("")
            out.append("| category | n | WER | term recall | empty |")
            out.append("|---|---:|---:|---:|---:|")
            for category in run.categories {
                out.append("| \(category.category) | \(category.utterances) "
                           + "| \(percent(category.wer)) | \(rate(category.termRecall)) "
                           + "| \(percent(category.emptyRate)) |")
            }
        }
        if let notes = run.notes, !notes.isEmpty {
            out.append("")
            out.append(notes)
        }
        out.append("")
        return out.joined(separator: "\n")
    }

    /// Everything needed to reproduce or distrust the row above it.
    public static func provenanceLine(_ p: RunProvenance) -> String {
        "git `\(p.gitSha)` · os `\(p.osBuild)` · prompt `\(p.promptSha256)` · "
            + "dictionary \(p.dictionaryTerms) terms · scorer v\(p.scorerVersion) · "
            + "corpus source `\(p.corpusSource.rawValue)`"
    }

    static func percent(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.2f%%", value * 100)
    }

    static func rate(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.3f", value)
    }

    // MARK: - machine-readable

    public static func encode(_ run: RunSummary) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(run)
    }

    public static func decodeRun(_ data: Data) throws -> RunSummary {
        try JSONDecoder().decode(RunSummary.self, from: data)
    }

    public static func encode(_ baseline: Baseline) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(baseline)
    }

    public static func decodeBaseline(_ data: Data) throws -> Baseline {
        try JSONDecoder().decode(Baseline.self, from: data)
    }

    // MARK: - comparison

    /// Every band the run failed to hold. A band whose metric the run did not
    /// measure is a violation too: silently dropping a metric is how a
    /// regression hides.
    ///
    /// No matching (corpus, config) record means nothing has been accepted yet
    /// — that is a new configuration, not a regression, so it yields no
    /// violations.
    public static func compare(run: RunSummary, baseline: Baseline) -> [BaselineViolation] {
        guard let record = baseline.record(corpus: run.corpusId, config: run.config) else {
            return []
        }
        var out: [BaselineViolation] = []
        for band in record.bands {
            let observed = value(of: band.metric, stage: band.stage, in: run)
            let failed: Bool
            if let observed {
                failed = band.metric.lowerIsBetter
                    ? observed > band.accepted + band.tolerance
                    : observed < band.accepted - band.tolerance
            } else {
                failed = true
            }
            if failed {
                out.append(BaselineViolation(corpus: record.corpus, config: record.config,
                                             stage: band.stage, metric: band.metric,
                                             accepted: band.accepted, tolerance: band.tolerance,
                                             observed: observed))
            }
        }
        return out
    }

    static func value(of metric: BaselineMetric, stage: String, in run: RunSummary) -> Double? {
        // The battery is a property of the run, not of a pipeline stage.
        if metric == .battery { return run.battery }
        guard let row = run.stages.first(where: { $0.stage == stage }) else { return nil }
        switch metric {
        case .wer: return row.wer
        case .cer: return row.cer
        case .termRecall: return row.termRecall
        case .zeroEdit: return row.zeroEdit
        case .emptyRate: return row.emptyRate
        case .battery: return run.battery
        }
    }

    // MARK: - the thin appender

    /// Append a rendered section to RESULTS.md, creating the file (and its
    /// directory) with `header` when it does not exist yet. The only IO in this
    /// target, deliberately dumb — everything above it is testable without a
    /// filesystem.
    public static func appendSection(_ section: String, to url: URL,
                                     creatingWith header: String? = nil) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
        guard manager.fileExists(atPath: url.path) else {
            let head = header.map { $0.hasSuffix("\n") ? $0 : $0 + "\n\n" } ?? ""
            try (head + section).write(to: url, atomically: true, encoding: .utf8)
            return
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        guard let data = ("\n" + section).data(using: .utf8) else { return }
        try handle.write(contentsOf: data)
    }

    public static func writeSummary(_ run: RunSummary, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try encode(run).write(to: url, options: .atomic)
    }
}
