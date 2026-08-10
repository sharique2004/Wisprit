import Foundation

/// The robustness deck, version 1: four regression-tripwire indices computed
/// over a frozen cell list at the **raw** stage, `refine=off,dict=off`
/// semantics (raw is pre-pipeline, so the config toggles cannot touch it).
///
/// The four components are reported separately, never blended: a blended
/// scalar hides which axis regressed, and "what does a 0.3-weighted accent
/// point mean" has no answer. Tone appears in the rendered table as `—` —
/// synthetic audio cannot reach that axis, and printing the row is how the
/// deck admits it (measurement.md §5.6).
///
/// Every number the deck produces is a TTS tripwire: deterministic per OS
/// build, useful for catching regressions in ~2 minutes, and **never** an
/// accuracy claim. The banner discipline applies to the deck doubly.
public enum RobustnessDeck {

    /// Version of the frozen cell list. Bumped only when the deck's corpora or
    /// component definitions change — at which point every recorded baseline
    /// stops being comparable and must be re-measured, deliberately.
    public static let version = "v1"

    /// The corpora the deck runs over, in reporting order. Frozen per version.
    public static let corpora = ["tts-accents-v1", "tts-stress-v1", "tts-corners-v1"]

    public static let accentsCorpus = "tts-accents-v1"
    public static let stressCorpus = "tts-stress-v1"

    /// The pseudo-record identity in `BASELINE.json`, following the
    /// `refine-battery`/`cases` precedent: the deck scores axes across three
    /// corpora, so its bands must not attach to any one (corpus, config) a
    /// normal run could match.
    public static let baselineCorpus = "robustness-deck"
    public static let baselineConfig = version

    /// Component names as they appear in `BASELINE.json` `stage` fields and in
    /// the rendered table.
    public static let noiseComponent = "ri-noise"
    public static let accentComponent = "ri-accent"
    public static let levelComponent = "ri-level"
    public static let emptyComponent = "ri-empty"

    /// The stress-corpus cells each component reads. Conditions are manifest
    /// categories (`category` = condition — the pilot-proven zero-code path).
    public static let cleanCell = "g0"
    public static let noiseCell = "wn5"
    public static let levelCells = ["g-36", "clip+6"]
    /// The accents-corpus reference voice every other voice is measured against.
    public static let referenceVoice = "samantha"

    // MARK: - the components

    /// One computed deck. Optional components stay nil when a needed cell is
    /// absent — a deck run over a corpus missing its cells must say "not
    /// measured", never 0.
    public struct Components: Equatable, Sendable {
        /// WER(wn5) − WER(g0): what SNR 5 dB white noise costs over clean.
        public var riNoise: Double?
        /// max-over-voices WER − reference-voice WER: the worst accent gap.
        public var riAccent: Double?
        /// Which voice carries the accent gap — the flag worth chasing.
        public var worstVoice: String?
        /// max(WER(g−36), WER(clip+6)) − WER(g0): the level/clipping envelope.
        public var riLevel: Double?
        /// Empty-transcript rate over every clip in the whole deck.
        public var riEmpty: Double?
        /// Σ clips the empty rate was computed over.
        public var deckUtterances: Int

        public init(riNoise: Double? = nil, riAccent: Double? = nil,
                    worstVoice: String? = nil, riLevel: Double? = nil,
                    riEmpty: Double? = nil, deckUtterances: Int = 0) {
            self.riNoise = riNoise; self.riAccent = riAccent
            self.worstVoice = worstVoice; self.riLevel = riLevel
            self.riEmpty = riEmpty; self.deckUtterances = deckUtterances
        }
    }

    /// Compute the deck from raw-stage per-category (= per-condition) metrics.
    ///
    /// `deckStages` carries one raw-stage `StageMetrics` per deck corpus (any
    /// order); the empty component is Σempties/Σclips across all of them —
    /// corner cells count toward empties even though no WER component reads
    /// them, because "any cell went silent" is news wherever it happens.
    public static func components(accents: [CategoryMetrics], stress: [CategoryMetrics],
                                  deckStages: [StageMetrics]) -> Components {
        var out = Components()

        func wer(_ rows: [CategoryMetrics], _ category: String) -> Double? {
            rows.first { $0.category == category }?.wer
        }

        if let clean = wer(stress, cleanCell) {
            if let noisy = wer(stress, noiseCell) { out.riNoise = noisy - clean }
            let levels = levelCells.compactMap { wer(stress, $0) }
            if levels.count == levelCells.count, let worst = levels.max() {
                out.riLevel = worst - clean
            }
        }

        if let reference = wer(accents, referenceVoice) {
            let others = accents.filter { $0.category != referenceVoice && $0.wer != nil }
            if let worst = others.max(by: { ($0.wer ?? 0) < ($1.wer ?? 0) }),
               let worstWer = worst.wer {
                out.riAccent = worstWer - reference
                out.worstVoice = worst.category
            }
        }

        var clips = 0
        var empties = 0.0
        for stage in deckStages {
            guard let emptyRate = stage.emptyRate else { continue }
            clips += stage.utterances
            empties += emptyRate * Double(stage.utterances)
        }
        if clips > 0 {
            out.riEmpty = empties / Double(clips)
            out.deckUtterances = clips
        }

        return out
    }

    // MARK: - baseline comparison

    /// The deck spelled as a `RunSummary` so `Scoreboard.compare` and the
    /// existing band mechanism apply unchanged: each component is a pseudo-stage
    /// row, WER-difference components under `.wer`, the empty rate under
    /// `.emptyRate`. `refWords`/`errors` are 0 — a difference of two
    /// micro-averages has no single error count, and nothing reads them here.
    public static func summaryRun(timestamp: String, engine: String,
                                  provenance: RunProvenance,
                                  components: Components,
                                  notes: String? = nil) -> RunSummary {
        var stages: [StageMetrics] = []
        func append(_ name: String, wer: Double?) {
            stages.append(StageMetrics(stage: name, utterances: components.deckUtterances,
                                       refWords: 0, errors: 0, wer: wer))
        }
        append(noiseComponent, wer: components.riNoise)
        append(accentComponent, wer: components.riAccent)
        append(levelComponent, wer: components.riLevel)
        stages.append(StageMetrics(stage: emptyComponent,
                                   utterances: components.deckUtterances,
                                   refWords: 0, errors: 0,
                                   emptyRate: components.riEmpty))
        return RunSummary(timestamp: timestamp, corpusId: baselineCorpus, split: "all",
                          engine: engine, config: baselineConfig, provenance: provenance,
                          stages: stages, notes: notes)
    }

    // MARK: - the terminal table

    /// The four components plus the honest tone row. Differences are printed in
    /// WER points (the unit the research reports quote) — the underlying
    /// summary keeps them as rates.
    public static func renderTable(_ components: Components) -> String {
        func points(_ value: Double?) -> String {
            guard let value else { return "—" }
            return String(format: "%+.1f pts", value * 100)
        }
        func percent(_ value: Double?) -> String {
            guard let value else { return "—" }
            return String(format: "%.2f%%", value * 100)
        }
        let accentDetail = components.worstVoice.map { " (\($0))" } ?? ""
        var lines: [String] = []
        lines.append("robustness-deck \(version) · raw stage · TTS tripwire, never accuracy")
        lines.append("  \(noiseComponent)   \(points(components.riNoise))  (wn5 − g0)")
        lines.append("  \(accentComponent)  \(points(components.riAccent))  "
                     + "(worst voice − \(referenceVoice))\(accentDetail)")
        lines.append("  \(levelComponent)   \(points(components.riLevel))  "
                     + "(max(g-36, clip+6) − g0)")
        lines.append("  \(emptyComponent)   \(percent(components.riEmpty))  "
                     + "(over \(components.deckUtterances) clips, whole deck)")
        lines.append("  ri-tone    —  (unmeasured until human-v1 — synthetic audio "
                     + "cannot reach this axis)")
        return lines.joined(separator: "\n")
    }
}
