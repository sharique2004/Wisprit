import XCTest
import WispritEval
@testable import WispritRefine

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Live scored gate over the shared refine battery.
///
/// The cases live in `WispritEval.RefineBattery` — the original eight carried
/// over verbatim plus the categories the 3B model measurably fails (homophones,
/// spelled runs, addresses, obedience, injection, plausibility-band edges,
/// length, disfluency). Keeping them there means this test and the
/// `Wisprit eval refine` CLI score the *same* battery; the CLI is what repeats
/// each case and writes the scored artifact to the scoreboard, and this file is
/// only the XCTest door onto it. One pass per case here, deliberately: the gate
/// has to stay inside a `swift test` wall clock.
///
/// Run after EVERY edit to `RefineInstructions` and after every macOS point
/// release: Apple replaces the on-device model in updates (26.4 rebuilt it) and
/// explicitly tells developers to re-test prompts.
///
///     WISPRIT_REHEARSAL=1 swift test --filter RehearsalTests \
///       --scratch-path /tmp/wisprit-build-WispritRefine
///
/// Gated because it needs Apple Intelligence, costs ~0.4–2 s per case, and
/// serializes on the system daemon (parallel helpers measurably do not help).
///
/// The verdict is a *score*, not a per-case pass/fail. The model is stochastic
/// and gets replaced underneath us, so one sampled miss is noise while a dropped
/// aggregate is a regression — the assertion is the aggregate against
/// `docs/eval/BASELINE.json`. Until a battery band is accepted there, the run is
/// report-only and just prints the number.
final class RehearsalTests: XCTestCase {

    func testRefineBatteryHoldsTheBaseline() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["WISPRIT_REHEARSAL"] == "1",
                          "set WISPRIT_REHEARSAL=1 to run the live model battery")
        #if canImport(FoundationModels)
        // The real cage, not the bare generator: the letter-run and address
        // cases assert a *bypass outcome*, which only exists on this side of
        // `Refiner`, and the plausibility guard is what the user actually gets
        // when the model answers instead of cleaning. Default configuration =
        // the app's own word cap and timeout budget.
        let refiner = Refiner(generator: SystemModelGenerator(),
                              configuration: { RefineConfiguration() },
                              startProbe: false)
        let available = await refiner.probeNow()
        let reason = await refiner.unavailableReason
        try XCTSkipUnless(available, "Apple Intelligence unavailable: \(reason)")

        var verdicts: [CaseVerdict] = []
        print(Self.header)
        for testCase in RefineBattery.cases {
            // Prewarm per case exactly like a record press, and never reuse a
            // session: `LanguageModelSession` accumulates a transcript, so the
            // previous case would still be in context.
            await refiner.begin()
            let result = await refiner.refine(testCase.input)
            let verdict = RefineBattery.evaluate(testCase, output: result.text,
                                                 outcome: result.outcome.rawValue)
            verdicts.append(verdict)
            print(Self.row(for: testCase, verdict: verdict, outcome: result.outcome))
        }
        await refiner.cancel()

        let score = RefineBattery.aggregate(verdicts)
        let violated = verdicts.filter { !$0.passed }
        print("")
        print(String(format: "REHEARSAL ===== refine battery score %.4f =====", score))
        print("REHEARSAL       \(verdicts.count) cases, one pass each, "
              + "\(violated.count) with violations "
              + "(weighted; repeats live in `Wisprit eval refine`)")

        guard let band = try Self.baselineBand() else {
            print("REHEARSAL       no battery band in docs/eval/BASELINE.json — REPORT ONLY, "
                  + "nothing gated. Record one with `Wisprit eval refine`.")
            return
        }
        let floor = band.accepted - band.tolerance
        print(String(format: "REHEARSAL       baseline %.4f ± %.4f → floor %.4f",
                     band.accepted, band.tolerance, floor))
        XCTAssertGreaterThanOrEqual(
            score, floor,
            "refine battery regressed: \(String(format: "%.4f", score)) < "
                + "\(String(format: "%.4f", floor)). Do not tune the cases to make this pass — "
                + "find which case class dropped:\n"
                + violated.map { "  \($0.id): \($0.violations.joined(separator: "; ")) → "
                    + Self.oneLine($0.output) }.joined(separator: "\n"))
        #else
        throw XCTSkip("FoundationModels unavailable on this platform")
        #endif
    }

    // MARK: - the baseline

    /// The accepted battery band from `docs/eval/BASELINE.json`, or nil when the
    /// file or the band is not there yet — nothing accepted means nothing to
    /// regress from, which is a new configuration, not a failure.
    ///
    /// The battery is a property of a run, not of a corpus, so any record may
    /// carry it. When several do, the LOWEST floor wins: this gate samples each
    /// case exactly once, and the tight gate is the CLI runner's repeated
    /// average, so a single pass should only fail when the prompt actually
    /// broke.
    static func baselineBand() throws -> BaselineBand? {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // WispritRefineTests
            .deletingLastPathComponent()   // tests
            .deletingLastPathComponent()   // repo root
        let url = repoRoot.appendingPathComponent("docs/eval/BASELINE.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let baseline = try Scoreboard.decodeBaseline(try Data(contentsOf: url))
        return baseline.records
            .flatMap(\.bands)
            .filter { $0.metric == .battery }
            .min { $0.accepted - $0.tolerance < $1.accepted - $1.tolerance }
    }

    // MARK: - the printed table

    static let header = "REHEARSAL "
        + pad("case", 26) + " " + pad("category", 13) + " score "
        + pad("outcome", 15) + " violations"

    /// One row per case. The model output is printed only when the case scored
    /// violations — on a clean run it is noise, and on a dirty one it is the
    /// only thing that says WHICH way the prompt slipped.
    static func row(for testCase: RefineCase, verdict: CaseVerdict,
                    outcome: RefineOutcome) -> String {
        var line = "REHEARSAL " + pad(testCase.id, 26) + " " + pad(testCase.category, 13)
            + String(format: " %.2f  ", verdict.score) + pad(outcome.rawValue, 15)
        line += verdict.violations.isEmpty
            ? "ok"
            : verdict.violations.joined(separator: "; ") + " → " + oneLine(verdict.output)
        return line
    }

    static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }

    static func oneLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ⏎ ")
    }
}
