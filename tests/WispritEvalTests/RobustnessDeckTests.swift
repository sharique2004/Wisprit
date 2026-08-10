import XCTest
@testable import WispritEval

/// The robustness deck: four tripwire indices over a frozen cell list, raw
/// stage, reported as components and never blended. Everything here is pure
/// arithmetic over literal metrics — the deck's honesty properties (nil for
/// missing cells, the tone row, the pseudo-record identity) are the contract.
final class RobustnessDeckTests: XCTestCase {

    static func accents() -> [CategoryMetrics] {
        [
            CategoryMetrics(category: "samantha", utterances: 50, wer: 0.1176),
            CategoryMetrics(category: "daniel", utterances: 50, wer: 0.1416),
            CategoryMetrics(category: "aman", utterances: 50, wer: 0.2004),
            CategoryMetrics(category: "tara", utterances: 50, wer: 0.1830),
        ]
    }

    static func stress() -> [CategoryMetrics] {
        [
            CategoryMetrics(category: "g0", utterances: 50, wer: 0.1176),
            CategoryMetrics(category: "g-36", utterances: 50, wer: 0.1416),
            CategoryMetrics(category: "clip+6", utterances: 50, wer: 0.1133),
            CategoryMetrics(category: "wn5", utterances: 50, wer: 0.2854),
        ]
    }

    static func deckStages(emptyRates: [Double?] = [0, 0, 0]) -> [StageMetrics] {
        emptyRates.enumerated().map { index, rate in
            StageMetrics(stage: "raw", utterances: 100 * (index + 1), refWords: 1000,
                         errors: 100, wer: 0.1, emptyRate: rate)
        }
    }

    // MARK: - components

    func testComponentsMatchTheirDefinitions() {
        let components = RobustnessDeck.components(
            accents: Self.accents(), stress: Self.stress(), deckStages: Self.deckStages())
        // RI-noise = WER(wn5) − WER(g0); the pilot's +16.8 points.
        XCTAssertEqual(components.riNoise ?? 0, 0.2854 - 0.1176, accuracy: 1e-9)
        // RI-accent = worst voice − samantha; the worst voice is named because
        // "which accent" is the flag worth chasing.
        XCTAssertEqual(components.riAccent ?? 0, 0.2004 - 0.1176, accuracy: 1e-9)
        XCTAssertEqual(components.worstVoice, "aman")
        // RI-level = max(g-36, clip+6) − g0.
        XCTAssertEqual(components.riLevel ?? 0, 0.1416 - 0.1176, accuracy: 1e-9)
        // RI-empty spans the whole deck: Σempties / Σclips.
        XCTAssertEqual(components.riEmpty, 0)
        XCTAssertEqual(components.deckUtterances, 600)
    }

    func testEmptyRateIsClipWeightedAcrossCorpora() {
        let components = RobustnessDeck.components(
            accents: Self.accents(), stress: Self.stress(),
            deckStages: Self.deckStages(emptyRates: [0.01, 0, 0]))
        // 1 empty in the 100-clip corpus over 600 deck clips.
        XCTAssertEqual(components.riEmpty ?? 0, 1.0 / 600.0, accuracy: 1e-9)
    }

    /// A deck run over corpora missing their cells must say "not measured",
    /// never 0 — a zero here would read as "no regression".
    func testMissingCellsYieldNilComponentsNeverZero() {
        let components = RobustnessDeck.components(
            accents: [], stress: [CategoryMetrics(category: "g0", utterances: 50, wer: 0.1)],
            deckStages: [StageMetrics(stage: "raw", utterances: 0, refWords: 0, errors: 0)])
        XCTAssertNil(components.riNoise)
        XCTAssertNil(components.riAccent)
        XCTAssertNil(components.riLevel)
        XCTAssertNil(components.riEmpty)
    }

    // MARK: - baseline plumbing

    /// The deck compares through the existing band mechanism under a
    /// pseudo-record no corpus run can match — the `refine-battery`/`cases`
    /// precedent.
    func testSummaryRunCarriesThePseudoRecordIdentity() {
        let run = RobustnessDeck.summaryRun(
            timestamp: "2026-08-10T12:00:00Z", engine: "apple_live",
            provenance: ScoreboardTests.provenance(source: .tts),
            components: RobustnessDeck.components(
                accents: Self.accents(), stress: Self.stress(),
                deckStages: Self.deckStages()))
        XCTAssertEqual(run.corpusId, "robustness-deck")
        XCTAssertEqual(run.config, "v1")
        XCTAssertEqual(run.stages.map(\.stage),
                       ["ri-noise", "ri-accent", "ri-level", "ri-empty"])

        let baseline = Baseline(records: [
            BaselineRecord(corpus: "robustness-deck", config: "v1", bands: [
                BaselineBand(stage: "ri-noise", metric: .wer, accepted: 0.168,
                             tolerance: 0.03),
                BaselineBand(stage: "ri-accent", metric: .wer, accepted: 0.083,
                             tolerance: 0.02),
                BaselineBand(stage: "ri-empty", metric: .emptyRate, accepted: 0,
                             tolerance: 0),
            ]),
        ])
        XCTAssertEqual(Scoreboard.compare(run: run, baseline: baseline), [])

        // Any nonzero deck empty rate is news: the band is exact.
        var silent = run
        silent.stages = run.stages.map { stage in
            var out = stage
            if out.stage == "ri-empty" { out.emptyRate = 0.002 }
            return out
        }
        let violations = Scoreboard.compare(run: silent, baseline: baseline)
        XCTAssertEqual(violations.map(\.metric), [.emptyRate])
    }

    /// `emptyRate` joined `BaselineMetric` as an error rate: lower is better,
    /// and old baseline files (which never mention it) still decode.
    func testEmptyRateIsLowerIsBetter() {
        XCTAssertTrue(BaselineMetric.emptyRate.lowerIsBetter)
    }

    // MARK: - rendering

    func testRenderTableNamesEveryComponentAndAdmitsTone() {
        let table = RobustnessDeck.renderTable(RobustnessDeck.components(
            accents: Self.accents(), stress: Self.stress(), deckStages: Self.deckStages()))
        XCTAssertTrue(table.contains("ri-noise   +16.8 pts"), table)
        XCTAssertTrue(table.contains("ri-accent  +8.3 pts"), table)
        XCTAssertTrue(table.contains("(aman)"), table)
        XCTAssertTrue(table.contains("ri-level   +2.4 pts"), table)
        XCTAssertTrue(table.contains("ri-empty   0.00%"), table)
        // The tone row prints and admits it cannot be measured synthetically —
        // pretending coverage would be the lie the deck exists to prevent.
        XCTAssertTrue(table.contains("ri-tone    —"), table)
        XCTAssertTrue(table.contains("unmeasured until human-v1"), table)
        XCTAssertTrue(table.contains("never accuracy"), table)
    }

    func testRenderTableShowsDashesForMissingComponents() {
        let table = RobustnessDeck.renderTable(RobustnessDeck.Components())
        XCTAssertTrue(table.contains("ri-noise   —"), table)
        XCTAssertTrue(table.contains("ri-empty   —"), table)
    }

    /// The corpus list is the frozen deck; a change here is a version bump and
    /// a deliberate re-baseline, never a drive-by.
    func testDeckV1IsFrozen() {
        XCTAssertEqual(RobustnessDeck.version, "v1")
        XCTAssertEqual(RobustnessDeck.corpora,
                       ["tts-accents-v1", "tts-stress-v1", "tts-corners-v1"])
        XCTAssertEqual(RobustnessDeck.baselineConfig, "v1")
    }
}
