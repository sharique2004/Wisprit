import XCTest
@testable import WispritEval

final class RefineBatteryTests: XCTestCase {

    static func fixture(must: [String] = [], mustNot: [String] = [], ideal: String? = nil,
                        expectOutcome: String? = nil, weight: Double = 1.0) -> RefineCase {
        RefineCase(id: "fixture", category: "test", input: "input",
                   must: must, mustNot: mustNot, ideal: ideal,
                   expectOutcome: expectOutcome, weight: weight)
    }

    // MARK: - the arithmetic

    func testScoreIsSatisfiedMustMinusViolatedMustNot() {
        let testCase = Self.fixture(must: ["alpha", "beta"], mustNot: ["gamma", "delta"])
        let cases: [(output: String, score: Double, violations: Int)] = [
            ("alpha beta", 1.0, 0),                 // 2/2 - 0/2
            ("alpha beta gamma", 0.5, 1),           // 2/2 - 1/2
            ("alpha gamma", 0.0, 2),                // 1/2 - 1/2
            ("alpha", 0.5, 1),                      // 1/2 - 0/2
            ("gamma delta", 0.0, 4),                // 0/2 - 2/2, clamped at 0
            ("nothing here", 0.0, 2),               // 0/2 - 0/2
        ]
        for c in cases {
            let verdict = RefineBattery.evaluate(testCase, output: c.output)
            XCTAssertEqual(verdict.score, c.score, accuracy: 1e-12, c.output)
            XCTAssertEqual(verdict.violations.count, c.violations, c.output)
            XCTAssertEqual(verdict.passed, c.violations == 0, c.output)
            XCTAssertEqual(verdict.output, c.output)
        }
    }

    /// A case with no `mustNot` divides by 1, not by 0.
    func testEmptyListsAreSafe() {
        XCTAssertEqual(RefineBattery.evaluate(Self.fixture(must: ["a"]), output: "a").score, 1)
        XCTAssertEqual(RefineBattery.evaluate(Self.fixture(mustNot: ["a"]), output: "b").score, 1)
        XCTAssertEqual(RefineBattery.evaluate(Self.fixture(mustNot: ["a"]), output: "a").score, 0)
        XCTAssertEqual(RefineBattery.evaluate(Self.fixture(), output: "").score, 1)
    }

    func testIdealBlendsFiftyFiftyWithOneMinusCER() {
        let testCase = Self.fixture(must: ["hello"], ideal: "hello world")
        XCTAssertEqual(RefineBattery.evaluate(testCase, output: "hello world").score, 1,
                       accuracy: 1e-12)
        // "world" → "there" is 5 substitutions over an 11-character reference.
        XCTAssertEqual(Score.cer(ref: "hello world", hyp: "hello there").errors, 5)
        XCTAssertEqual(RefineBattery.evaluate(testCase, output: "hello there").score,
                       0.5 * 1.0 + 0.5 * (1.0 - 5.0 / 11.0), accuracy: 1e-12)
        // A wildly longer output cannot push CER past 1 and drive the score negative.
        let runaway = RefineBattery.evaluate(testCase,
                                             output: "hello " + String(repeating: "x ", count: 80))
        XCTAssertGreaterThanOrEqual(runaway.score, 0)
        XCTAssertLessThanOrEqual(runaway.score, 0.5)
    }

    /// A spelled run that went through the model is a failure even when this
    /// particular sample survived — the bypass is the invariant, not the output.
    func testOutcomeMismatchZerosTheScore() {
        let testCase = Self.fixture(must: ["alpha"],
                                    expectOutcome: RefineBattery.ExpectedOutcome.hasLetterRun)
        let matched = RefineBattery.evaluate(testCase, output: "alpha",
                                             outcome: RefineBattery.ExpectedOutcome.hasLetterRun)
        XCTAssertEqual(matched.score, 1)
        XCTAssertTrue(matched.passed)

        let mismatched = RefineBattery.evaluate(testCase, output: "alpha",
                                                outcome: RefineBattery.ExpectedOutcome.applied)
        XCTAssertEqual(mismatched.score, 0)
        XCTAssertFalse(mismatched.passed)
        XCTAssertTrue(mismatched.violations.contains { $0.contains("has_letter_run") },
                      "\(mismatched.violations)")

        // Not recorded → not checked, so the battery still runs against a bare
        // generator.
        XCTAssertEqual(RefineBattery.evaluate(testCase, output: "alpha").score, 1)
    }

    /// All-lowercase needles keep the original battery's case-insensitive
    /// semantics; a needle carrying uppercase is how a casing expectation is
    /// written.
    func testNeedleCaseSensitivityRule() {
        XCTAssertTrue(RefineBattery.contains("iphone", in: "the iPhone"))
        XCTAssertTrue(RefineBattery.contains("iPhone", in: "the iPhone"))
        XCTAssertFalse(RefineBattery.contains("iPhone", in: "the iphone"))
        XCTAssertFalse(RefineBattery.contains("iPhone", in: "the Iphone"))
    }

    func testAggregateIsWeightWeighted() {
        let cases = [
            RefineCase(id: "heavy", category: "c", input: "i", must: ["x"], weight: 1.0),
            RefineCase(id: "light", category: "c", input: "i", must: ["x"], weight: 0.5),
        ]
        let verdicts = [
            CaseVerdict(id: "heavy", passed: true, score: 1.0, violations: [], output: "x"),
            CaseVerdict(id: "light", passed: false, score: 0.0, violations: ["missing"],
                        output: ""),
        ]
        XCTAssertEqual(RefineBattery.aggregate(verdicts, cases: cases), 1.0 / 1.5,
                       accuracy: 1e-12)
        // Reversing the weights reverses the aggregate, which is the whole point.
        let flipped = [
            RefineCase(id: "heavy", category: "c", input: "i", must: ["x"], weight: 0.5),
            RefineCase(id: "light", category: "c", input: "i", must: ["x"], weight: 1.0),
        ]
        XCTAssertEqual(RefineBattery.aggregate(verdicts, cases: flipped), 0.5 / 1.5,
                       accuracy: 1e-12)
        XCTAssertEqual(RefineBattery.aggregate([], cases: cases), 0)
    }

    // MARK: - the shipped cases

    func testCasesAreWellFormed() {
        XCTAssertGreaterThanOrEqual(RefineBattery.cases.count, 30)
        var ids = Set<String>()
        for testCase in RefineBattery.cases {
            XCTAssertTrue(ids.insert(testCase.id).inserted, "duplicate id \(testCase.id)")
            XCTAssertFalse(testCase.input.isEmpty, testCase.id)
            XCTAssertFalse(testCase.category.isEmpty, testCase.id)
            XCTAssertTrue(!testCase.must.isEmpty || testCase.expectOutcome != nil,
                          "\(testCase.id) asserts nothing")
            XCTAssertGreaterThan(testCase.weight, 0, testCase.id)
            XCTAssertLessThanOrEqual(testCase.weight, 1, testCase.id)
            XCTAssertNotEqual(testCase.ideal, "", testCase.id)
            for needle in testCase.must {
                XCTAssertFalse(testCase.mustNot.contains(needle),
                               "\(testCase.id): '\(needle)' is both required and forbidden")
                XCTAssertFalse(needle.isEmpty, testCase.id)
            }
            if let outcome = testCase.expectOutcome {
                XCTAssertTrue([RefineBattery.ExpectedOutcome.hasLetterRun,
                               RefineBattery.ExpectedOutcome.hasAddress,
                               RefineBattery.ExpectedOutcome.applied].contains(outcome),
                              "\(testCase.id): unknown outcome '\(outcome)'")
            }
        }
    }

    /// Every class the plan asks for is actually represented.
    func testEveryFailureClassIsCovered() {
        let categories = Set(RefineBattery.cases.map(\.category))
        for expected in ["regression", "jargon", "letter-run", "address", "obedience",
                         "injection", "plausibility", "length", "disfluency"] {
            XCTAssertTrue(categories.contains(expected), "no \(expected) cases")
        }
        XCTAssertEqual(RefineBattery.cases.filter {
            $0.expectOutcome == RefineBattery.ExpectedOutcome.hasLetterRun
        }.count, 4)
        XCTAssertEqual(RefineBattery.cases.filter {
            $0.expectOutcome == RefineBattery.ExpectedOutcome.hasAddress
        }.count, 4)
    }

    /// A bypass case's `ideal` IS its input: the utterance must come back
    /// byte-identical. Scoring the ideal against itself must therefore be a
    /// perfect 1 — if it is not, the case's own needles contradict it.
    func testBypassCasesDemandVerbatimAndAreSelfConsistent() {
        for testCase in RefineBattery.cases where testCase.ideal != nil {
            let verdict = RefineBattery.evaluate(testCase, output: testCase.ideal!,
                                                 outcome: testCase.expectOutcome)
            XCTAssertEqual(verdict.score, 1, accuracy: 1e-12,
                           "\(testCase.id): \(verdict.violations)")
            XCTAssertTrue(verdict.passed, "\(testCase.id): \(verdict.violations)")
        }
        for testCase in RefineBattery.cases where testCase.expectOutcome != nil {
            XCTAssertEqual(testCase.ideal, testCase.input,
                           "\(testCase.id): a bypass case must demand its input back verbatim")
        }
    }

    /// The regression core is the eight cases the eval-locked prompt was tuned
    /// against. They are carried over VERBATIM from
    /// `tests/WispritRefineTests/RehearsalTests.swift`; this reads that file and
    /// checks the strings still match, so "tidying" one side is caught.
    ///
    /// Skips when the anchor is gone — the plan turns RehearsalTests into a thin
    /// baseline gate, and a restructured file must not fail this target.
    func testRegressionCoreMatchesTheOriginalBattery() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // WispritEvalTests
            .deletingLastPathComponent()   // tests
            .deletingLastPathComponent()   // repo root
        let original = repoRoot.appendingPathComponent("tests/WispritRefineTests/"
                                                       + "RehearsalTests.swift")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: original.path),
                          "RehearsalTests.swift not in this checkout")
        let source = try String(contentsOf: original, encoding: .utf8)
        try XCTSkipUnless(source.contains("static let cases: [Case]"),
                          "RehearsalTests no longer carries the inline cases")

        XCTAssertEqual(RefineBattery.regression.count, 8)
        for testCase in RefineBattery.regression {
            XCTAssertTrue(source.contains("\"\(testCase.id)\""),
                          "label '\(testCase.id)' is not in RehearsalTests.swift")
            XCTAssertTrue(source.contains("\"\(testCase.input)\""),
                          "\(testCase.id): input drifted from RehearsalTests.swift")
            for needle in testCase.must + testCase.mustNot {
                XCTAssertTrue(source.contains("\"\(needle)\""),
                              "\(testCase.id): needle '\(needle)' drifted")
            }
        }
    }
}
