import XCTest
import WispritPersistence
@testable import WispritMac

/// `Wisprit stats` — the argument spelling, and the report a fixture stream
/// produces. Both pure: the subcommand's only impure parts are reading the file
/// and reading the clock, and neither is asserted on here.
final class StatsCommandTests: XCTestCase {

    // MARK: - arguments

    func testArgumentSpelling() {
        let cases: [(argv: [String], expected: StatsCommand.Parsed)] = [
            // No argument is the whole file: metrics.log spans three eras and a
            // first look should see all of it.
            ([], .window(MetricsWindow.all)),
            (["--days", "7"], .window(MetricsWindow(days: 7))),
            (["--days=7"], .window(MetricsWindow(days: 7))),
            (["--days", "0.5"], .window(MetricsWindow(days: 0.5))),
            (["--days"], .invalid("--days needs a positive number of days")),
            (["--days", "0"], .invalid("--days needs a positive number of days")),
            (["--days", "-3"], .invalid("--days needs a positive number of days")),
            (["--days", "week"], .invalid("--days needs a positive number of days")),
            (["--weeks", "2"], .invalid("unknown option: --weeks")),
        ]
        for (argv, expected) in cases {
            XCTAssertEqual(StatsCommand.parse(argv), expected, "\(argv)")
        }
    }

    // MARK: - the report

    func testTheReportAnswersEveryQuestionTheEmptyRateRaises() {
        // The live stream's shape, in miniature: one empty the classifier
        // explains, one it cannot, one from before `empty_reason` existed, one
        // timeout, and two ordinary pastes.
        let text = MetricsSummary.render(for: MetricsSummary.summarize(
            fixtureRows(), window: MetricsWindow(days: 14), now: now))

        XCTAssertTrue(text.contains("last 14 days"), text)
        XCTAssertTrue(text.contains("utterances      6"), text)
        XCTAssertTrue(text.contains("paste 3"), text)
        XCTAssertTrue(text.contains("empty 3"), text)
        // Empty rate WITH the breakdown — the number alone is what made the
        // 18% unactionable in the first place.
        XCTAssertTrue(text.contains("3 (50.0%)"), text)
        XCTAssertTrue(text.contains("produced_nothing 1"), text)
        XCTAssertTrue(text.contains("short_hold 1"), text)
        // Legacy rows are reported next to the classified ones, never folded in.
        XCTAssertTrue(text.contains("unclassified 1"), text)
        XCTAssertTrue(text.contains("logged before empty_reason existed"), text)
        // The one number worth alarming on, over ALL utterances.
        XCTAssertTrue(text.contains("unexplained     1 (16.7%)"), text)
        XCTAssertTrue(text.contains("timed out       1 (16.7%)"), text)
        XCTAssertTrue(text.contains("finalize_ms"), text)
        XCTAssertTrue(text.contains("release_to_text"), text)
        XCTAssertTrue(text.contains("kept 2"), text)
    }

    func testAnEmptyWindowSaysSoRatherThanReportingZeroes() {
        let text = MetricsSummary.render(for: MetricsSummary.summarize(
            fixtureRows(), window: MetricsWindow(days: 1), now: now + 30 * 86_400))
        XCTAssertTrue(text.contains("no utterances recorded"), text)
    }

    // MARK: - fixtures

    private let now: Double = 1_775_000_000

    private func fixtureRows() -> [JSONObject] {
        [
            row(outcome: "paste", finalizeMs: 80, releaseMs: 70, ai: "kept"),
            row(outcome: "paste", finalizeMs: 120, releaseMs: 95, ai: "kept"),
            row(outcome: "paste", finalizeMs: 300, releaseMs: 240, timedOut: true),
            // Audible speech, clean finish, no text: the real defect.
            row(outcome: "empty", finalizeMs: 90, emptyReason: "produced_nothing",
                peakLevel: 0.2, heldMs: 2500),
            // Benign: the key was tapped, not held.
            row(outcome: "empty", finalizeMs: 20, emptyReason: "short_hold",
                peakLevel: 0.3, heldMs: 300),
            // Written before the classifier existed.
            row(outcome: "empty", finalizeMs: 60),
        ]
    }

    private func row(outcome: String, finalizeMs: Double, releaseMs: Double? = nil,
                     ai: String? = nil, timedOut: Bool = false,
                     emptyReason: String? = nil, peakLevel: Double? = nil,
                     heldMs: Double? = nil) -> JSONObject {
        var row = JSONObject()
        row["ts"] = .double(now - 3600)
        row["outcome"] = .string(outcome)
        row["finalize_ms"] = .double(finalizeMs)
        if let releaseMs { row["release_to_text_ms"] = .double(releaseMs) }
        if let ai { row["ai"] = .string(ai) }
        if timedOut { row["timed_out"] = .bool(true) }
        if let emptyReason { row["empty_reason"] = .string(emptyReason) }
        if let peakLevel { row["peak_level"] = .double(peakLevel) }
        if let heldMs { row["held_ms"] = .double(heldMs) }
        return row
    }
}
