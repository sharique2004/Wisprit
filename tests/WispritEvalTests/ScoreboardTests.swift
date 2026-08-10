import XCTest
@testable import WispritEval

final class ScoreboardTests: XCTestCase {

    static func provenance(source: CorpusSource) -> RunProvenance {
        RunProvenance(gitSha: "a1b2c3d", osBuild: "26.0 (25A123)",
                      promptSha256: "9f8e7d6c", dictionaryTerms: 138, corpusSource: source)
    }

    static func run(source: CorpusSource = .human, battery: Double? = nil) -> RunSummary {
        RunSummary(
            timestamp: "2026-08-09T12:00:00Z", corpusId: "human-v1", split: "held",
            engine: "apple_live", config: "refine=on,dict=on",
            provenance: provenance(source: source),
            stages: [
                StageMetrics(stage: "raw", utterances: 60, refWords: 812, errors: 21,
                             wer: 0.0259, cer: 0.011, termRecall: 0.812, zeroEdit: 0.55),
                StageMetrics(stage: "final", utterances: 60, refWords: 812, errors: 14,
                             wer: 0.0172, cer: 0.008, termRecall: 0.93, zeroEdit: 0.68),
            ],
            categories: [
                CategoryMetrics(category: "proper-nouns", utterances: 12, wer: 0.05,
                                termRecall: 0.75),
                CategoryMetrics(category: "addresses", utterances: 8, wer: 0.01),
            ],
            battery: battery)
    }

    // MARK: - rendering

    func testMarkdownSectionCarriesIdentityAndProvenance() {
        let text = Scoreboard.markdownSection(for: Self.run())
        XCTAssertTrue(text.hasPrefix("## 2026-08-09T12:00:00Z — human-v1/held — apple_live — "
                                     + "`refine=on,dict=on`"), text)
        XCTAssertTrue(text.contains("git `a1b2c3d`"), text)
        XCTAssertTrue(text.contains("os `26.0 (25A123)`"), text)
        XCTAssertTrue(text.contains("prompt `9f8e7d6c`"), text)
        XCTAssertTrue(text.contains("dictionary 138 terms"), text)
        XCTAssertTrue(text.contains("scorer v\(EvalInfo.scorerVersion)"), text)
        XCTAssertTrue(text.contains("corpus source `human`"), text)
    }

    func testMarkdownSectionRendersStagesAndCategories() {
        let text = Scoreboard.markdownSection(for: Self.run())
        XCTAssertTrue(text.contains("| raw | 60 | 812 | 21 | 2.59% | 1.10% | 0.812 | 0.550 |"),
                      text)
        XCTAssertTrue(text.contains("| final | 60 | 812 | 14 | 1.72% | 0.80% | 0.930 | 0.680 |"),
                      text)
        XCTAssertTrue(text.contains("### By category"), text)
        XCTAssertTrue(text.contains("| proper-nouns | 12 | 5.00% | 0.750 |"), text)
        // A metric that was not measured renders as an em dash, never as 0.
        XCTAssertTrue(text.contains("| addresses | 8 | 1.00% | — |"), text)
    }

    /// The banner is mandatory on TTS rows: `say -v Samantha` audio proves the
    /// plumbing works and nothing else.
    func testTTSCorpusCarriesTheBanner() {
        let tts = Scoreboard.markdownSection(for: Self.run(source: .tts))
        XCTAssertTrue(tts.contains(Scoreboard.ttsBanner), tts)
        XCTAssertEqual(Scoreboard.ttsBanner,
                       "TTS corpus — plumbing check only, not an accuracy claim")
        XCTAssertTrue(tts.contains("corpus source `tts`"), tts)

        for source in [CorpusSource.human, .librispeech] {
            let other = Scoreboard.markdownSection(for: Self.run(source: source))
            XCTAssertFalse(other.contains(Scoreboard.ttsBanner), other)
        }
    }

    func testBatteryRowIsRenderedOnlyWhenMeasured() {
        XCTAssertFalse(Scoreboard.markdownSection(for: Self.run()).contains("Refine battery"))
        let withBattery = Scoreboard.markdownSection(for: Self.run(battery: 0.84))
        XCTAssertTrue(withBattery.contains("Refine battery: **0.840** (weighted)"), withBattery)
    }

    /// The renderer is pure: the caller supplies the clock and the hashes, so
    /// the same summary always produces the same bytes.
    func testRendererIsPure() {
        XCTAssertEqual(Scoreboard.markdownSection(for: Self.run()),
                       Scoreboard.markdownSection(for: Self.run()))
    }

    // MARK: - machine-readable

    func testRunSummaryRoundTrips() throws {
        let original = Self.run(battery: 0.84)
        let decoded = try Scoreboard.decodeRun(Scoreboard.encode(original))
        XCTAssertEqual(decoded, original)
        let text = String(decoding: try Scoreboard.encode(original), as: UTF8.self)
        XCTAssertTrue(text.contains("\n  \""), "expected pretty-printed JSON")
        XCTAssertTrue(text.contains("\"scorerVersion\""), text)
        XCTAssertEqual(decoded.provenance.scorerVersion, EvalInfo.scorerVersion)
    }

    func testBaselineRoundTrips() throws {
        let baseline = Baseline(records: [
            BaselineRecord(corpus: "human-v1", config: "refine=on,dict=on", bands: [
                BaselineBand(stage: "final", metric: .wer, accepted: 0.02, tolerance: 0.005),
                BaselineBand(stage: "final", metric: .termRecall, accepted: 0.90,
                             tolerance: 0.03),
            ]),
        ])
        XCTAssertEqual(try Scoreboard.decodeBaseline(Scoreboard.encode(baseline)), baseline)
    }

    // MARK: - comparison

    func testCompareAcceptsInsideTheBand() {
        let baseline = Baseline(records: [
            BaselineRecord(corpus: "human-v1", config: "refine=on,dict=on", bands: [
                // observed 0.0172 ≤ 0.015 + 0.005
                BaselineBand(stage: "final", metric: .wer, accepted: 0.015, tolerance: 0.005),
                // observed 0.930 ≥ 0.950 - 0.030
                BaselineBand(stage: "final", metric: .termRecall, accepted: 0.95,
                             tolerance: 0.03),
            ]),
        ])
        XCTAssertEqual(Scoreboard.compare(run: Self.run(), baseline: baseline), [])
    }

    func testCompareReportsBothDirections() {
        let baseline = Baseline(records: [
            BaselineRecord(corpus: "human-v1", config: "refine=on,dict=on", bands: [
                // WER is lower-is-better: 0.0172 > 0.010 + 0.005 → regression.
                BaselineBand(stage: "final", metric: .wer, accepted: 0.010, tolerance: 0.005),
                // Recall is higher-is-better: 0.930 < 0.990 - 0.030 → regression.
                BaselineBand(stage: "final", metric: .termRecall, accepted: 0.99,
                             tolerance: 0.03),
            ]),
        ])
        let violations = Scoreboard.compare(run: Self.run(), baseline: baseline)
        XCTAssertEqual(violations.map(\.metric), [.wer, .termRecall])
        XCTAssertEqual(violations.first?.observed, 0.0172)
        XCTAssertTrue("\(violations[0])".contains("final.wer"), "\(violations[0])")
    }

    /// Dropping a metric is how a regression hides, so an unmeasured band is a
    /// violation in its own right.
    func testUnmeasuredMetricIsAViolation() {
        let baseline = Baseline(records: [
            BaselineRecord(corpus: "human-v1", config: "refine=on,dict=on", bands: [
                BaselineBand(stage: "corrected", metric: .wer, accepted: 0.02, tolerance: 0.01),
            ]),
        ])
        let violations = Scoreboard.compare(run: Self.run(), baseline: baseline)
        XCTAssertEqual(violations.count, 1)
        XCTAssertNil(violations.first?.observed)
        XCTAssertTrue("\(violations[0])".contains("not measured"), "\(violations[0])")
    }

    func testBatteryBandReadsTheRunLevelScore() {
        let baseline = Baseline(records: [
            BaselineRecord(corpus: "human-v1", config: "refine=on,dict=on", bands: [
                BaselineBand(stage: "-", metric: .battery, accepted: 0.85, tolerance: 0.05),
            ]),
        ])
        XCTAssertEqual(Scoreboard.compare(run: Self.run(battery: 0.84), baseline: baseline), [])
        XCTAssertEqual(Scoreboard.compare(run: Self.run(battery: 0.60),
                                          baseline: baseline).count, 1)
        // Never measured at all → violation, same as any other missing metric.
        XCTAssertEqual(Scoreboard.compare(run: Self.run(), baseline: baseline).count, 1)
    }

    /// A configuration nobody has accepted numbers for yet is new, not broken.
    func testUnknownConfigurationYieldsNoViolations() {
        let baseline = Baseline(records: [
            BaselineRecord(corpus: "tts-samantha", config: "refine=off,dict=on", bands: [
                BaselineBand(stage: "final", metric: .wer, accepted: 0.0, tolerance: 0.0),
            ]),
        ])
        XCTAssertEqual(Scoreboard.compare(run: Self.run(), baseline: baseline), [])
    }

    // MARK: - the thin appender

    func testAppendSectionCreatesThenAppends() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wisprit-eval-\(UUID().uuidString)")
        let url = directory.appendingPathComponent("eval/RESULTS.md")
        defer { try? FileManager.default.removeItem(at: directory) }

        try Scoreboard.appendSection("## first\n", to: url, creatingWith: "# Scoreboard")
        var text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("# Scoreboard\n\n"), text)
        XCTAssertTrue(text.contains("## first"), text)

        try Scoreboard.appendSection("## second\n", to: url, creatingWith: "# Scoreboard")
        text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(text.components(separatedBy: "# Scoreboard").count, 2,
                       "the header must be written exactly once")
        XCTAssertTrue(text.contains("## first"), text)
        XCTAssertTrue(text.hasSuffix("## second\n"), text)
    }

    func testWriteSummaryCreatesIntermediateDirectories() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wisprit-eval-\(UUID().uuidString)")
        let url = directory.appendingPathComponent("eval/runs/2026-08-09.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        try Scoreboard.writeSummary(Self.run(), to: url)
        let decoded = try Scoreboard.decodeRun(try Data(contentsOf: url))
        XCTAssertEqual(decoded, Self.run())
    }
}
