import XCTest
import WispritKit
@testable import WispritPersistence

final class MetricsWriterTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wisprit-metrics-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var path: URL { root.appendingPathComponent("metrics.log") }

    // MARK: golden parity with session.py::_log_metrics

    func testFullLineMatchesPythonByteForByte() {
        let record = MetricsRecord(
            ts: 1785871825.3455071, heldMs: 47416.04, engine: "apple_live",
            finalizeMs: 604.44, timedOut: false, postMs: 3.29, insertMs: 517.31,
            outcome: "paste", chars: 525,
            releaseToTextMs: 3171.23, aiMs: 1923.91, ai: "applied")
        XCTAssertEqual(record.jsonLine(), Golden.metricsFull)
    }

    func testEmptyOutcomeLineOmitsReleaseToText() {
        let record = MetricsRecord(
            ts: 1785872035.681684, heldMs: 1468.75, engine: "apple_live",
            finalizeMs: 153.0, timedOut: true, postMs: 0.0, insertMs: 0.0,
            outcome: "empty", chars: 0, releaseToTextMs: nil, aiMs: 220.44, ai: "off")
        XCTAssertEqual(record.jsonLine(), Golden.metricsEmptyOutcome)
    }

    func testMinimalLineOmitsAllOptionals() {
        let record = MetricsRecord(
            ts: 1.0, heldMs: 10.0, engine: "", finalizeMs: 0.0, timedOut: false,
            postMs: 0.0, insertMs: 0.0, outcome: "error", chars: 0)
        XCTAssertEqual(record.jsonLine(), Golden.metricsMinimal)
    }

    /// A real Python-era line must re-serialize to itself: same field order,
    /// same rounding, same float repr. This is the "one mergeable stream" check.
    func testRealPythonLineRoundTripsThroughTheSwiftWriter() throws {
        guard case .object(let parsed) = try WispritJSON.parse(Golden.metricsRealPythonLine) else {
            return XCTFail("golden line is not an object")
        }
        func double(_ key: String) throws -> Double {
            switch parsed[key] {
            case .double(let d)?: return d
            case .int(let i)?: return Double(i)
            default: throw XCTSkip("missing \(key)")
            }
        }
        let record = MetricsRecord(
            ts: try double("ts"), heldMs: try double("held_ms"),
            engine: "apple_live", finalizeMs: try double("finalize_ms"),
            timedOut: false, postMs: try double("post_ms"),
            insertMs: try double("insert_ms"), outcome: "paste", chars: 613,
            releaseToTextMs: try double("release_to_text_ms"),
            aiMs: try double("ai_ms"), ai: "applied")
        XCTAssertEqual(record.jsonLine(), Golden.metricsRealPythonLine + "\n")
    }

    func testFieldOrderIsTheOnDiskOrder() throws {
        let record = MetricsRecord(
            ts: 1.0, heldMs: 2.0, engine: "e", finalizeMs: 3.0, timedOut: false,
            postMs: 4.0, insertMs: 5.0, outcome: "paste", chars: 6,
            releaseToTextMs: 7.0, aiMs: 8.0, ai: "applied")
        guard case .object(let object) = try WispritJSON.parse(record.jsonLine()) else {
            return XCTFail("not an object")
        }
        XCTAssertEqual(object.keys, [
            "ts", "held_ms", "engine", "finalize_ms", "timed_out", "post_ms",
            "insert_ms", "outcome", "chars", "release_to_text_ms", "ai_ms", "ai",
        ])
    }

    // MARK: post-Python telemetry (additive, strictly after `ai`)

    func testTelemetryFieldsSerializeAfterAiInOrder() {
        let record = MetricsRecord(
            ts: 1785871825.3455071, heldMs: 47416.04, engine: "apple_live",
            finalizeMs: 604.44, timedOut: false, postMs: 3.29, insertMs: 517.31,
            outcome: "paste", chars: 525,
            releaseToTextMs: 3171.23, aiMs: 1923.91, ai: "applied",
            emptyReason: "produced_nothing", peakLevel: 0.03712345,
            audioMs: 47250.0, rawChars: 540, refineDelta: 31)
        XCTAssertEqual(record.jsonLine(), Golden.metricsTelemetryFull)
    }

    func testClassifiedEmptyRowCarriesTheReasonRightAfterChars() {
        let record = MetricsRecord(
            ts: 1786327400.10842, heldMs: 2153.61, engine: "apple_live",
            finalizeMs: 118.42, timedOut: false, postMs: 0.0, insertMs: 0.0,
            outcome: "empty", chars: 0,
            emptyReason: "produced_nothing", peakLevel: 0.18423456, audioMs: 2100.0)
        XCTAssertEqual(record.jsonLine(), Golden.metricsTelemetryEmptyRow)
    }

    /// The whole point of "additive": the new build writing an old-shaped event
    /// must produce the old bytes, or the merged stream forks.
    func testOmittedTelemetryReproducesTheLegacyShapeByteForByte() {
        let record = MetricsRecord(
            ts: 1785872035.681684, heldMs: 1468.75, engine: "apple_live",
            finalizeMs: 1500.9, timedOut: false, postMs: 0.0, insertMs: 0.0,
            outcome: "empty", chars: 0)
        XCTAssertEqual(record.jsonLine(), Golden.metricsLegacyEmptyRow)
        for key in ["empty_reason", "peak_level", "audio_ms", "raw_chars", "refine_delta"] {
            XCTAssertFalse(record.jsonLine().contains(key), "\(key) must be omitted, not null")
        }
    }

    func testTelemetryFieldOrderIsTheOnDiskOrder() throws {
        let record = MetricsRecord(
            ts: 1.0, heldMs: 2.0, engine: "e", finalizeMs: 3.0, timedOut: false,
            postMs: 4.0, insertMs: 5.0, outcome: "paste", chars: 6,
            releaseToTextMs: 7.0, aiMs: 8.0, ai: "applied",
            emptyReason: "silent", peakLevel: 0.5, audioMs: 9.0,
            rawChars: 10, refineDelta: 11,
            vocabMs: 12.0, vocabHits: 13, vocabDelta: 1, applied: false)
        guard case .object(let object) = try WispritJSON.parse(record.jsonLine()) else {
            return XCTFail("not an object")
        }
        XCTAssertEqual(object.keys, [
            "ts", "held_ms", "engine", "finalize_ms", "timed_out", "post_ms",
            "insert_ms", "outcome", "chars", "release_to_text_ms", "ai_ms", "ai",
            "empty_reason", "peak_level", "audio_ms", "raw_chars", "refine_delta",
            "vocab_ms", "vocab_hits", "vocab_delta", "applied",
        ])
    }

    // MARK: the `vocab_retro` deviation row

    func testVocabRetroRowMatchesItsGoldenLine() {
        let record = MetricsRecord(
            ts: 1786399512.204418, heldMs: 0, engine: "apple_dictation", finalizeMs: 0,
            timedOut: false, postMs: 0, insertMs: 0, outcome: "vocab_retro", chars: 0,
            vocabMs: 1243.62, vocabHits: 2, vocabDelta: 1, applied: true)
        XCTAssertEqual(record.jsonLine(), Golden.metricsVocabRetroRow)
    }

    func testVocabRetroDiagnosedRowMatchesItsGoldenLine() {
        let record = MetricsRecord(
            ts: 1786399512.204418, heldMs: 0, engine: "apple_dictation", finalizeMs: 0,
            timedOut: false, postMs: 0, insertMs: 0, outcome: "vocab_retro", chars: 0,
            vocabMs: 1243.62, vocabHits: 2, vocabDelta: 1, applied: false,
            rung: "im_streaming", applyDetail: "noDocumentAccess")
        XCTAssertEqual(record.jsonLine(), Golden.metricsVocabRetroDiagnosedRow)
    }

    /// The 2026-08-12 diagnosis trio appends after every existing key, in
    /// on-disk order, and only when set — a row with none of it is byte-for-byte
    /// what the previous build wrote (`testVocabRetroRowMatchesItsGoldenLine`).
    func testVocabRetroDiagnosisFieldsAppendAfterEverythingAndOmitWhenAbsent() throws {
        let with = MetricsRecord(
            ts: 1786399512.204418, heldMs: 0, engine: "apple_dictation", finalizeMs: 0,
            timedOut: false, postMs: 0, insertMs: 0, outcome: "vocab_retro", chars: 0,
            vocabMs: 1243.62, vocabHits: 2, vocabDelta: 0, applied: false,
            vocabRefusal: "aligned", rung: "paste", applyDetail: "dropped")
        guard case .object(let object) = try WispritJSON.parse(with.jsonLine()) else {
            return XCTFail("not an object")
        }
        XCTAssertEqual(object.keys, [
            "ts", "held_ms", "engine", "finalize_ms", "timed_out", "post_ms",
            "insert_ms", "outcome", "chars",
            "vocab_ms", "vocab_hits", "vocab_delta", "applied",
            "vocab_refusal", "rung", "apply_detail",
        ])
        XCTAssertEqual(object["vocab_refusal"], .string("aligned"))
        XCTAssertEqual(object["rung"], .string("paste"))
        XCTAssertEqual(object["apply_detail"], .string("dropped"))
        let without = MetricsRecord(
            ts: 1786399512.204418, heldMs: 0, engine: "apple_dictation", finalizeMs: 0,
            timedOut: false, postMs: 0, insertMs: 0, outcome: "vocab_retro", chars: 0,
            vocabMs: 1243.62, vocabHits: 2, vocabDelta: 1, applied: true).jsonLine()
        for key in ["vocab_refusal", "rung", "apply_detail"] {
            XCTAssertFalse(without.contains(key), "\(key) must be omitted, not null")
        }
    }

    /// The additive promise again, for the four newest keys: an utterance row is
    /// byte-identical to what the previous build wrote.
    func testAnUtteranceRowNeverCarriesTheVocabFields() {
        let line = MetricsRecord(
            ts: 1785872035.681684, heldMs: 1468.75, engine: "apple_live",
            finalizeMs: 1500.9, timedOut: false, postMs: 0.0, insertMs: 0.0,
            outcome: "empty", chars: 0).jsonLine()
        XCTAssertEqual(line, Golden.metricsLegacyEmptyRow)
        for key in ["vocab_ms", "vocab_hits", "vocab_delta", "applied"] {
            XCTAssertFalse(line.contains(key), "\(key) must be omitted, not null")
        }
    }

    // MARK: the context-awareness tail (Phase 4)

    /// The three `ctx` fields append after the whole existing tail, in on-disk
    /// order, and only when set — the default-off install writes the exact
    /// bytes the previous build wrote.
    func testContextFieldsAppendAfterEverythingAndOmitWhenAbsent() throws {
        let with = MetricsRecord(
            ts: 1.0, heldMs: 2.0, engine: "e", finalizeMs: 3.0, timedOut: false,
            postMs: 4.0, insertMs: 5.0, outcome: "paste", chars: 6,
            releaseToTextMs: 7.0, aiMs: 8.0, ai: "applied",
            peakLevel: 0.5, audioMs: 9.0, rawChars: 10, refineDelta: 11,
            ctx: "read", ctxMs: 42.16, ctxTerms: 3)
        guard case .object(let object) = try WispritJSON.parse(with.jsonLine()) else {
            return XCTFail("not an object")
        }
        XCTAssertEqual(object.keys, [
            "ts", "held_ms", "engine", "finalize_ms", "timed_out", "post_ms",
            "insert_ms", "outcome", "chars", "release_to_text_ms", "ai_ms", "ai",
            "peak_level", "audio_ms", "raw_chars", "refine_delta",
            "ctx", "ctx_ms", "ctx_terms",
        ])
        XCTAssertEqual(object["ctx"], .string("read"))
        XCTAssertEqual(object["ctx_ms"], .double(42.2), "round1, like every duration")
        XCTAssertEqual(object["ctx_terms"], .int(3))

        let without = MetricsRecord(
            ts: 1785872035.681684, heldMs: 1468.75, engine: "apple_live",
            finalizeMs: 1500.9, timedOut: false, postMs: 0.0, insertMs: 0.0,
            outcome: "empty", chars: 0).jsonLine()
        XCTAssertEqual(without, Golden.metricsLegacyEmptyRow)
        for key in ["ctx", "ctx_ms", "ctx_terms"] {
            XCTAssertFalse(without.contains("\"\(key)\""), "\(key) must be omitted, not null")
        }
    }

    // MARK: the R6/R4 tail (2026-08-10) — restore split, acoustic pair

    /// The four new utterance-row fields append after every existing key, in
    /// on-disk order, with the family rounding rules (`round1` durations,
    /// `round4` for the meter-scale floor) — and omit cleanly, so every row an
    /// earlier build wrote remains a byte-prefix of this schema.
    func testRestoreSplitAndAcousticPairAppendAfterEverythingInOrder() throws {
        let with = MetricsRecord(
            ts: 1.0, heldMs: 2.0, engine: "e", finalizeMs: 3.0, timedOut: false,
            postMs: 4.0, insertMs: 5.0, outcome: "paste", chars: 6,
            releaseToTextMs: 7.0, aiMs: 8.0, ai: "applied",
            peakLevel: 0.5, audioMs: 9.0, rawChars: 10, refineDelta: 11,
            ctx: "read", ctxMs: 42.16, ctxTerms: 3,
            restoreMs: 500.44, repressQueued: true,
            noiseFloor: 0.01234567, firstVoicedMs: 181.27)
        guard case .object(let object) = try WispritJSON.parse(with.jsonLine()) else {
            return XCTFail("not an object")
        }
        XCTAssertEqual(object.keys, [
            "ts", "held_ms", "engine", "finalize_ms", "timed_out", "post_ms",
            "insert_ms", "outcome", "chars", "release_to_text_ms", "ai_ms", "ai",
            "peak_level", "audio_ms", "raw_chars", "refine_delta",
            "ctx", "ctx_ms", "ctx_terms",
            "restore_ms", "repress_queued", "noise_floor", "first_voiced_ms",
        ])
        XCTAssertEqual(object["restore_ms"], .double(500.4), "round1, like every duration")
        XCTAssertEqual(object["repress_queued"], .bool(true))
        XCTAssertEqual(object["noise_floor"], .double(0.0123),
                       "round4 — the same rule as peak_level, same meter scale")
        XCTAssertEqual(object["first_voiced_ms"], .double(181.3))

        let without = MetricsRecord(
            ts: 1785872035.681684, heldMs: 1468.75, engine: "apple_live",
            finalizeMs: 1500.9, timedOut: false, postMs: 0.0, insertMs: 0.0,
            outcome: "empty", chars: 0).jsonLine()
        XCTAssertEqual(without, Golden.metricsLegacyEmptyRow)
        for key in ["restore_ms", "repress_queued", "noise_floor", "first_voiced_ms",
                    "onboard_ms", "steps_skipped", "relaunches"] {
            XCTAssertFalse(without.contains("\"\(key)\""), "\(key) must be omitted, not null")
        }
    }

    // MARK: the `onboarding` deviation row (R14)

    /// One time-to-wow row per fresh install, written through the dedicated
    /// entry point: reference-less like `vocab_retro`, engine-less like
    /// `edit_observed`, and carrying exactly its own three fields.
    func testWriteOnboardingWritesTheOneRowShape() throws {
        let writer = MetricsWriter(path: path)
        writer.writeOnboarding(firstLaunchToDictateMs: 184222.67,
                               stepsSkipped: 1, relaunchCount: 2)

        let rows = writer.readAll()
        XCTAssertEqual(rows.count, 1)
        guard let row = rows.first else { return }
        XCTAssertEqual(row["outcome"], .string("onboarding"))
        XCTAssertEqual(row["engine"], .string(""), "no engine produced this line")
        XCTAssertEqual(row["onboard_ms"], .double(184222.7))
        XCTAssertEqual(row["steps_skipped"], .int(1))
        XCTAssertEqual(row["relaunches"], .int(2))
        XCTAssertEqual(row["chars"], .int(0))
        for key in ["release_to_text_ms", "vocab_ms", "edit_dist", "restore_ms"] {
            XCTAssertNil(row[key], "an onboarding row never carries \(key)")
        }
    }

    // MARK: the `edit_observed` deviation row (Phase 5)

    func testEditObservedRowMatchesItsGoldenLine() {
        let record = MetricsRecord(
            ts: 1786399600.128455, heldMs: 0, engine: "", finalizeMs: 0,
            timedOut: false, postMs: 0, insertMs: 0, outcome: "edit_observed", chars: 0,
            editDist: 0, editScope: "im")
        XCTAssertEqual(record.jsonLine(), Golden.metricsEditObservedRow)
    }

    /// `edit_dist` is honestly optional: a `.changed` answer with no text is an
    /// observed edit of unknowable size, and the line says so by omission.
    func testEditObservedRowOmitsAnUnknowableDistance() throws {
        let line = MetricsRecord(
            ts: 1786399601.0, heldMs: 0, engine: "", finalizeMs: 0,
            timedOut: false, postMs: 0, insertMs: 0, outcome: "edit_observed", chars: 0,
            editScope: "ax").jsonLine()
        XCTAssertFalse(line.contains("\"edit_dist\""))
        XCTAssertTrue(line.contains("\"edit_scope\": \"ax\""))
    }

    /// The additive promise, one more time: the two newest keys append after
    /// everything and never appear on a row that did not set them.
    func testAnUtteranceRowNeverCarriesTheEditFields() {
        let line = MetricsRecord(
            ts: 1785872035.681684, heldMs: 1468.75, engine: "apple_live",
            finalizeMs: 1500.9, timedOut: false, postMs: 0.0, insertMs: 0.0,
            outcome: "empty", chars: 0).jsonLine()
        XCTAssertEqual(line, Golden.metricsLegacyEmptyRow)
        for key in ["edit_dist", "edit_scope"] {
            XCTAssertFalse(line.contains(key), "\(key) must be omitted, not null")
        }
    }

    func testVocabRetroRowsRideTheSameStreamAsUtteranceRows() throws {
        let writer = MetricsWriter(path: path)
        writer.write(MetricsRecord(
            ts: 1786399511.0, heldMs: 2153.61, engine: "apple_live", finalizeMs: 118.42,
            timedOut: false, postMs: 0.5, insertMs: 12.0, outcome: "im_streaming", chars: 43))
        writer.write(MetricsRecord(
            ts: 1786399512.204418, heldMs: 0, engine: "apple_dictation", finalizeMs: 0,
            timedOut: false, postMs: 0, insertMs: 0, outcome: "vocab_retro", chars: 0,
            vocabMs: 1243.62, vocabHits: 2, vocabDelta: 1, applied: true))
        let rows = writer.readAll()
        XCTAssertEqual(rows.count, 2)
        XCTAssertNil(rows[0]["vocab_ms"], "an utterance row never carries them")
        XCTAssertEqual(rows[1]["applied"], .bool(true))
        XCTAssertEqual(rows[1]["vocab_delta"], .int(1))
    }

    /// `peak_level` arrives as a `Float` widened to `Double`
    /// (0.02 → 0.019999999552965164), which would otherwise print in full.
    func testPeakLevelRoundsToFourDecimalsThroughTheFloatWidening() {
        // The engine's peak is a Float: `Double(Float(0.02))` is
        // 0.019999999552965164, which would otherwise print in full.
        let cases: [(Float, String)] = [
            (0.02, "0.02"), (0.0371, "0.0371"), (0.4123456, "0.4123"),
            (0, "0.0"), (1, "1.0"),
        ]
        for (level, expected) in cases {
            let line = MetricsRecord(
                ts: 0.0, heldMs: 0.0, engine: "", finalizeMs: 0.0, timedOut: false,
                postMs: 0.0, insertMs: 0.0, outcome: "empty", chars: 0,
                peakLevel: Double(level)).jsonLine()
            XCTAssertTrue(line.contains(#""peak_level": \#(expected)}"#), "\(level) → \(line)")
        }
    }

    func testCountersStayIntegers() {
        let line = MetricsRecord(
            ts: 0.0, heldMs: 0.0, engine: "", finalizeMs: 0.0, timedOut: false,
            postMs: 0.0, insertMs: 0.0, outcome: "paste", chars: 6,
            rawChars: 540, refineDelta: 0).jsonLine()
        XCTAssertTrue(line.contains(#""raw_chars": 540, "refine_delta": 0}"#), line)
    }

    func testLegacyAndTelemetryLinesCoexistInOneStream() throws {
        try (Golden.metricsRealPythonLine + "\n" + Golden.metricsLegacyEmptyRow)
            .write(to: path, atomically: true, encoding: .utf8)
        let writer = MetricsWriter(path: path)
        writer.write(MetricsRecord(
            ts: 1786327400.10842, heldMs: 2153.61, engine: "apple_live",
            finalizeMs: 118.42, timedOut: false, postMs: 0.0, insertMs: 0.0,
            outcome: "empty", chars: 0,
            emptyReason: "produced_nothing", peakLevel: 0.18423456, audioMs: 2100.0))
        let rows = writer.readAll()
        XCTAssertEqual(rows.count, 3)
        XCTAssertNil(rows[1]["empty_reason"], "a legacy row has no reason to report")
        XCTAssertEqual(rows[2]["empty_reason"], .string("produced_nothing"))
        XCTAssertEqual(rows[2]["peak_level"], .double(0.1842))
    }

    func testBridgeCarriesTheTelemetryFields() throws {
        let metrics = UtteranceMetrics(
            fields: [
                MetricsField.ts: 1786327400.10842,
                MetricsField.heldMs: 2153.61,
                MetricsField.finalizeMs: 118.42,
                MetricsField.peakLevel: 0.18423456,
                MetricsField.audioMs: 2100.0,
            ],
            outcome: "empty", engine: "apple_live")
        let writer = MetricsWriter(path: path)
        writer.write(metrics, emptyReason: "produced_nothing")
        XCTAssertEqual(try String(contentsOf: path, encoding: .utf8),
                       Golden.metricsTelemetryEmptyRow)
    }

    func testBridgeRoundsTheCountersToIntegers() {
        let metrics = UtteranceMetrics(
            fields: [MetricsField.ts: 1.0, MetricsField.rawChars: 540,
                     MetricsField.refineDelta: 31],
            outcome: "paste", engine: "e")
        XCTAssertTrue(MetricsWriter(path: path).lineFor(metrics)
            .contains(#""raw_chars": 540, "refine_delta": 31}"#))
    }

    /// `chars` is an int and `timed_out` a bool in the Python dict; emitting
    /// `525.0` or `"false"` would break every consumer of the stream.
    func testCharsIsAnIntegerAndTimedOutIsABool() {
        let line = MetricsRecord(
            ts: 0.0, heldMs: 0.0, engine: "", finalizeMs: 0.0, timedOut: true,
            postMs: 0.0, insertMs: 0.0, outcome: "paste", chars: 525).jsonLine()
        XCTAssertTrue(line.contains(#""chars": 525}"#), line)
        XCTAssertTrue(line.contains(#""timed_out": true"#), line)
    }

    // MARK: Python round(x, 1) parity

    func testRoundingMatchesPythonRoundToOneDecimal() {
        // Generated by: [(x, round(x, 1)) for x in ...] under the repo venv python.
        let cases: [(Double, Double)] = [
            (47416.04, 47416.0), (604.44, 604.4), (3.29, 3.3), (517.31, 517.3),
            (3171.23, 3171.2), (1923.91, 1923.9), (0.05, 0.1), (0.15, 0.1),
            (0.25, 0.2), (2.675, 2.7), (-1.25, -1.2), (0.0, 0.0), (153.0, 153.0),
            (438343.0, 438343.0),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(MetricsWriter.round1(input), expected, accuracy: 0, "round1(\(input))")
        }
    }

    // MARK: appending

    func testWriteAppendsOneLinePerCallAndCreatesTheFile() throws {
        let writer = MetricsWriter(path: path)
        for i in 0..<3 {
            writer.write(MetricsRecord(
                ts: Double(i), heldMs: 0, engine: "e", finalizeMs: 0, timedOut: false,
                postMs: 0, insertMs: 0, outcome: "paste", chars: i))
        }
        let text = try String(contentsOf: path, encoding: .utf8)
        XCTAssertEqual(text.split(separator: "\n").count, 3)
        XCTAssertTrue(text.hasSuffix("\n"))
        XCTAssertEqual(writer.readAll().count, 3)
    }

    func testWritePreservesAPreExistingPythonEraFile() throws {
        try (Golden.metricsRealPythonLine + "\n").write(to: path, atomically: true, encoding: .utf8)
        let writer = MetricsWriter(path: path)
        writer.write(MetricsRecord(
            ts: 1.0, heldMs: 10.0, engine: "", finalizeMs: 0.0, timedOut: false,
            postMs: 0.0, insertMs: 0.0, outcome: "error", chars: 0))
        let text = try String(contentsOf: path, encoding: .utf8)
        XCTAssertEqual(text, Golden.metricsRealPythonLine + "\n" + Golden.metricsMinimal)
        XCTAssertEqual(writer.readAll().count, 2)
    }

    func testConcurrentWritesNeverInterleaveWithinALine() throws {
        let writer = MetricsWriter(path: path)
        DispatchQueue.concurrentPerform(iterations: 200) { i in
            writer.write(MetricsRecord(
                ts: Double(i), heldMs: Double(i), engine: "apple_live", finalizeMs: 1.0,
                timedOut: false, postMs: 1.0, insertMs: 1.0, outcome: "paste", chars: i))
        }
        XCTAssertEqual(writer.readAll().count, 200)
    }

    func testReadAllSkipsATornTrailingLine() throws {
        try (Golden.metricsRealPythonLine + "\n" + #"{"ts": 1.0, "held"#)
            .write(to: path, atomically: true, encoding: .utf8)
        XCTAssertEqual(MetricsWriter(path: path).readAll().count, 1)
    }

    // MARK: UtteranceMetrics bridge

    func testUtteranceMetricsBridgeProducesThePythonLine() throws {
        let metrics = UtteranceMetrics(
            fields: [
                MetricsField.ts: 1785871825.3455071,
                MetricsField.heldMs: 47416.04,
                MetricsField.finalizeMs: 604.44,
                MetricsField.timedOut: 0,
                MetricsField.postMs: 3.29,
                MetricsField.insertMs: 517.31,
                MetricsField.chars: 525,
                MetricsField.releaseToTextMs: 3171.23,
                MetricsField.aiMs: 1923.91,
            ],
            outcome: "paste", engine: "apple_live")
        let writer = MetricsWriter(path: path)
        writer.write(metrics, ai: "applied")
        XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), Golden.metricsFull)
    }

    func testUtteranceMetricsBridgeOmitsAbsentOptionals() throws {
        let metrics = UtteranceMetrics(
            fields: [MetricsField.ts: 1.0, MetricsField.heldMs: 10.0],
            outcome: "error", engine: "")
        let writer = MetricsWriter(path: path)
        writer.write(metrics)
        XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), Golden.metricsMinimal)
    }

    func testUtteranceMetricsTimedOutFlagIsNonZero() throws {
        let metrics = UtteranceMetrics(
            fields: [MetricsField.ts: 1.0, MetricsField.timedOut: 1],
            outcome: "paste", engine: "apple_live")
        XCTAssertTrue(MetricsWriter(path: path).lineFor(metrics).contains(#""timed_out": true"#))
    }

    func testOverrideRootDrivesTheDefaultPath() throws {
        let saved = WispritPaths.overrideRoot
        defer { WispritPaths.overrideRoot = saved }
        WispritPaths.overrideRoot = root
        let writer = MetricsWriter()
        XCTAssertEqual(writer.metricsPath, path)
        writer.write(MetricsRecord(
            ts: 1.0, heldMs: 10.0, engine: "", finalizeMs: 0.0, timedOut: false,
            postMs: 0.0, insertMs: 0.0, outcome: "error", chars: 0))
        XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), Golden.metricsMinimal)
    }
}

private extension MetricsWriter {
    /// Test helper: the line the bridge would write, without touching disk.
    func lineFor(_ metrics: UtteranceMetrics, ai: String? = nil) -> String {
        write(metrics, ai: ai)
        return (try? String(contentsOf: metricsPath, encoding: .utf8)) ?? ""
    }
}
