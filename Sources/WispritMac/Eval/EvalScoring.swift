#if os(macOS)
import Foundation
import WispritEval

/// Turning a replay into a scoreboard row.
///
/// Pure, and separate from the runner for the reason every other pure half in
/// this codebase is separate: the numbers a RESULTS.md section carries are
/// asserted by a test over literal records, not by reading a table someone
/// produced once on one machine.
///
/// The reference for every stage is the corpus entry's `ref` — the text the
/// user wanted in their document. Scoring the raw ASR against it therefore
/// counts the formatting the pipeline is *supposed* to add ("sharique at
/// wisprit dot com" is not the reference; `sharique@wisprit.com` is), which is
/// exactly what makes the stage ladder legible: the drop from `raw` to `final`
/// is what the deterministic stages are worth.
enum EvalScoring {

    /// One utterance at one stage, joined to what the corpus expects of it.
    struct ScoredClip: Equatable {
        var id: String
        var category: String
        var ref: String
        var hyp: String
        /// `expect.terms` — the dictionary terms that must survive.
        var terms: [String]
    }

    /// Stage names, in `SessionController.finalizeUtterance` order. The order is
    /// the point: a regression is attributable to a stage only if the rows are
    /// in the order the pipeline runs them.
    static let stageOrder = ["raw", "corrected", "refined", "final"]

    static func hypothesis(_ record: StageRecord, stage: String) -> String {
        switch stage {
        case "raw": return record.raw
        case "corrected": return record.corrected
        case "refined": return record.refined
        default: return record.final
        }
    }

    // MARK: - aggregation

    /// Micro-averaged metrics for one stage.
    ///
    /// WER and CER are Σerrors/Σref (never a mean of rates — a three-word
    /// utterance must not outvote a ninety-word one). Term recall is micro too:
    /// Σfound/Σexpected over the clips that expect anything, and nil when no
    /// clip does, because "1.000 of nothing" is a lie a scoreboard should not
    /// tell. Zero-edit is per utterance and counts every clip.
    static func metrics(stage: String, clips: [ScoredClip]) -> StageMetrics {
        let wers = clips.map { Score.wer(ref: $0.ref, hyp: $0.hyp, profile: .asr) }
        let word = Score.aggregate(wers)

        var charErrors = 0, refChars = 0
        for clip in clips {
            let cer = Score.cer(ref: clip.ref, hyp: clip.hyp)
            charErrors += cer.errors
            refChars += cer.refChars
        }

        var found = 0, expected = 0
        for clip in clips where !clip.terms.isEmpty {
            let recall = Score.termRecall(refTerms: clip.terms, hyp: clip.hyp)
            found += recall.found.count
            expected += recall.total
        }

        return StageMetrics(
            stage: stage,
            utterances: clips.count,
            refWords: word.refWords,
            errors: word.errors,
            wer: clips.isEmpty ? nil : word.rate,
            cer: refChars > 0 ? Double(charErrors) / Double(refChars) : nil,
            termRecall: expected > 0 ? Double(found) / Double(expected) : nil,
            zeroEdit: clips.isEmpty
                ? nil
                : Score.zeroEditRate(clips.map { (ref: $0.ref, hyp: $0.hyp) }),
            emptyRate: clips.isEmpty
                ? nil
                : Double(clips.count { isEmptyHypothesis($0.hyp) }) / Double(clips.count))
    }

    /// The live path's `outcome: empty`, applied to a replay: nothing survived
    /// but whitespace. Deliberately not a normalization profile — an utterance
    /// that produced only punctuation still produced *something*.
    static func isEmptyHypothesis(_ hyp: String) -> Bool {
        hyp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Per-category WER and term recall, in first-appearance order so the table
    /// matches the script that produced the corpus.
    static func categories(_ clips: [ScoredClip]) -> [CategoryMetrics] {
        var order: [String] = []
        var grouped: [String: [ScoredClip]] = [:]
        for clip in clips {
            if grouped[clip.category] == nil { order.append(clip.category) }
            grouped[clip.category, default: []].append(clip)
        }
        return order.map { category in
            let row = metrics(stage: category, clips: grouped[category] ?? [])
            return CategoryMetrics(category: category, utterances: row.utterances,
                                   wer: row.wer, termRecall: row.termRecall,
                                   emptyRate: row.emptyRate)
        }
    }

    // MARK: - report assembly

    /// Join a replay to its corpus and produce the row the scoreboard renders.
    ///
    /// Records with no matching manifest entry are dropped: a stale detail file
    /// from a corpus that has since lost a clip must not contribute a number
    /// with no reference behind it.
    static func summary(timestamp: String, corpus: Corpus, records: [StageRecord],
                        engine: String, config: String, provenance: RunProvenance,
                        categoryStage: String = "final",
                        battery: Double? = nil, notes: String? = nil) -> RunSummary {
        var byID: [String: CorpusEntry] = [:]
        for entry in corpus.entries { byID[entry.id] = entry }

        func clips(stage: String) -> [ScoredClip] {
            records.compactMap { record in
                guard let entry = byID[record.id] else { return nil }
                return ScoredClip(id: record.id, category: entry.category, ref: entry.ref,
                                  hyp: hypothesis(record, stage: stage),
                                  terms: entry.expect?.terms ?? [])
            }
        }

        return RunSummary(
            timestamp: timestamp,
            corpusId: corpus.id,
            split: corpus.split,
            engine: engine,
            config: config,
            provenance: provenance,
            stages: stageOrder.map { metrics(stage: $0, clips: clips(stage: $0)) },
            categories: categories(clips(stage: categoryStage)),
            // Nil is the historical spelling of "final", so summaries produced
            // before `--stage` existed compare equal to new default-stage ones.
            categoryStage: categoryStage == "final" ? nil : categoryStage,
            battery: battery,
            notes: notes)
    }

    /// The provenance `corpusSource`, which is one value while a corpus may hold
    /// several. A mixed corpus containing any TTS reports as TTS: the banner is
    /// a warning, and a warning that a mixed corpus suppresses is worse than a
    /// warning that is occasionally over-broad.
    static func reportedSource(_ corpus: Corpus) -> CorpusSource {
        if let single = corpus.source { return single }
        return corpus.sources.contains(.tts) ? .tts : .human
    }

    // MARK: - the terminal table

    /// What `eval score` prints. Same numbers as the RESULTS.md section, laid
    /// out for a terminal — the scoreboard file is the record, this is the
    /// feedback loop while you are running the thing.
    static func renderTable(_ run: RunSummary) -> String {
        var lines: [String] = []
        lines.append("\(run.corpusId)/\(run.split) · \(run.engine) · \(run.config)")
        lines.append(pad("stage", 11) + right("n", 5) + right("WER", 9) + right("CER", 9)
                     + right("terms", 8) + right("zero-edit", 11) + right("empty", 8))
        for stage in run.stages {
            lines.append(pad(stage.stage, 11) + right("\(stage.utterances)", 5)
                         + right(percent(stage.wer), 9) + right(percent(stage.cer), 9)
                         + right(rate(stage.termRecall), 8)
                         + right(rate(stage.zeroEdit), 11)
                         + right(percent(stage.emptyRate), 8))
        }
        if !run.categories.isEmpty {
            lines.append("")
            if let stage = run.categoryStage {
                lines.append("  by category (\(stage) stage)")
            }
            for category in run.categories {
                lines.append("  " + pad(category.category, 20)
                             + right("\(category.utterances)", 4)
                             + right(percent(category.wer), 9)
                             + right(rate(category.termRecall), 8)
                             + right(percent(category.emptyRate), 8))
            }
        }
        return lines.joined(separator: "\n")
    }

    static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }

    static func right(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : String(repeating: " ", count: width - text.count) + text
    }

    static func percent(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.2f%%", value * 100)
    }

    static func rate(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.3f", value)
    }
}
#endif
