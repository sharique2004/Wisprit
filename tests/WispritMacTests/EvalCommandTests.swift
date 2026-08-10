import XCTest
import WispritEval
@testable import WispritMac

/// `Wisprit eval` — the argument grammar, the configuration matrix, the cache
/// key, and the arithmetic that turns a replay into a scoreboard row.
///
/// Everything here is pure. The live ASR path is exercised by an actual baseline
/// run (`Wisprit eval all`), never by CI: it needs installed speech models, a
/// 16-core ANE and ~40 s of wall time, and a test that skips itself on every
/// other machine is not a test.
final class EvalCommandTests: XCTestCase {

    // MARK: - verbs

    /// `record` is the one verb a bare invocation cannot satisfy — it needs a
    /// script and a speaker, and neither is guessable.
    func testEveryVerbParses() {
        for verb in EvalCommand.Verb.allCases where verb != .record {
            var expected = EvalCommand.Options(verb: verb)
            if verb.isInteractive { expected.corpus = EvalCommand.humanCorpus }
            XCTAssertEqual(EvalCommand.parse([verb.rawValue]), .run(expected), verb.rawValue)
        }
    }

    /// Recording into `tts-samantha` is never what anyone means, and a human
    /// take landing there would poison the one corpus whose entire job is to be
    /// admittedly synthetic. So the interactive verbs default elsewhere.
    func testTheInteractiveVerbsDefaultToTheHumanCorpus() {
        guard case .run(let verify) = EvalCommand.parse(["verify"]) else {
            return XCTFail("verify should parse")
        }
        XCTAssertEqual(verify.corpus, "human-v1")

        guard case .run(let record) =
                EvalCommand.parse(["record", "--script", "s.txt", "--speaker", "spk01"]) else {
            return XCTFail("record should parse")
        }
        XCTAssertEqual(record.corpus, "human-v1")

        // Every replay verb keeps the synthetic default.
        for verb in EvalCommand.Verb.allCases where !verb.isInteractive {
            guard case .run(let options) = EvalCommand.parse([verb.rawValue]) else {
                return XCTFail(verb.rawValue)
            }
            XCTAssertEqual(options.corpus, "tts-samantha", verb.rawValue)
        }
    }

    /// The two failures that are only discoverable an hour into a session if
    /// they are allowed through — that is when the manifest turns out to be
    /// under the wrong name, or to be missing.
    func testRecordRefusesWithoutAScriptAndASpeaker() {
        guard case .invalid(let noScript) = EvalCommand.parse(["record", "--speaker", "spk01"])
        else { return XCTFail("should not parse") }
        XCTAssertTrue(noScript.contains("--script"), noScript)

        guard case .invalid(let noSpeaker) = EvalCommand.parse(["record", "--script", "s.txt"])
        else { return XCTFail("should not parse") }
        XCTAssertTrue(noSpeaker.contains("--speaker"), noSpeaker)

        // A label that slugs to nothing is no speaker at all.
        guard case .invalid(let blank) =
                EvalCommand.parse(["record", "--script", "s.txt", "--speaker", "!!!"])
        else { return XCTFail("should not parse") }
        XCTAssertTrue(blank.contains("--speaker"), blank)
    }

    func testTheRecordingFlags() {
        var expected = EvalCommand.Options(verb: .record)
        expected.corpus = "human-v1"
        expected.script = "tools/eval/scripts/human-v1/01-proper-nouns.txt"
        expected.speaker = "spk02"
        expected.mic = "AirPods Pro"
        expected.split = "dev"
        expected.out = "/tmp/corpus"

        XCTAssertEqual(EvalCommand.parse([
            "record", "--script", "tools/eval/scripts/human-v1/01-proper-nouns.txt",
            "--speaker", "spk02", "--mic", "AirPods Pro", "--split", "dev",
            "--out", "/tmp/corpus",
        ]), .run(expected))

        XCTAssertEqual(
            EvalCommand.parse(["record", "--script=s.txt", "--speaker=spk01", "--split=nope"]),
            .invalid("--split must be dev|held"))
    }

    func testBadVerbs() {
        XCTAssertEqual(EvalCommand.parse([]), .invalid("eval needs a verb"))
        XCTAssertEqual(EvalCommand.parse([""]), .invalid("eval needs a verb"))
        XCTAssertEqual(EvalCommand.parse(["asrr"]), .invalid("unknown verb: asrr"))
        // A flag in the verb slot is a missing verb, not an unknown option.
        XCTAssertEqual(EvalCommand.parse(["--corpus", "x"]), .invalid("unknown verb: --corpus"))
    }

    // MARK: - flags

    func testFlagSpelling() {
        var expected = EvalCommand.Options(verb: .all)
        expected.corpus = "human-v1"
        expected.engine = .dictation
        expected.refine = .on
        expected.dict = .off
        expected.out = "/tmp/runs"
        expected.repeatCount = 5
        expected.baseline = "/tmp/BASELINE.json"
        expected.categories = ["proper-nouns", "addresses"]
        expected.realtime = true

        let spaced = EvalCommand.parse([
            "all", "--corpus", "human-v1", "--engine", "dictation", "--refine", "on",
            "--dict", "off", "--out", "/tmp/runs", "--repeat", "5",
            "--baseline", "/tmp/BASELINE.json", "--categories", "proper-nouns,addresses",
            "--realtime",
        ])
        XCTAssertEqual(spaced, .run(expected))

        // `--flag=value` is the same flag, exactly as `Wisprit stats --days=7` is.
        let equals = EvalCommand.parse([
            "all", "--corpus=human-v1", "--engine=dictation", "--refine=on", "--dict=off",
            "--out=/tmp/runs", "--repeat=5", "--baseline=/tmp/BASELINE.json",
            "--categories=proper-nouns,addresses", "--realtime",
        ])
        XCTAssertEqual(equals, .run(expected))
    }

    func testDefaults() {
        guard case .run(let options) = EvalCommand.parse(["all"]) else {
            return XCTFail("bare verb should parse")
        }
        XCTAssertEqual(options.corpus, "tts-samantha")
        XCTAssertEqual(options.engine, .speech)
        XCTAssertNil(options.refine)
        XCTAssertNil(options.dict)
        XCTAssertNil(options.out)
        XCTAssertEqual(options.repeatCount, 3)
        XCTAssertNil(options.baseline)
        XCTAssertEqual(options.categories, [])
        XCTAssertFalse(options.realtime)
    }

    func testCategoriesAreTrimmedAndCompacted() {
        guard case .run(let options) =
                EvalCommand.parse(["score", "--categories", " homophones , ,addresses "]) else {
            return XCTFail("should parse")
        }
        XCTAssertEqual(options.categories, ["homophones", "addresses"])
    }

    func testBadFlags() {
        let cases: [(argv: [String], message: String)] = [
            (["asr", "--engine", "parakeet"], "--engine must be speech|dictation"),
            (["asr", "--refine", "yes"], "--refine must be on|off"),
            (["asr", "--dict", "1"], "--dict must be on|off"),
            (["refine", "--repeat", "0"], "--repeat needs a positive whole number"),
            (["refine", "--repeat", "-2"], "--repeat needs a positive whole number"),
            (["refine", "--repeat", "three"], "--repeat needs a positive whole number"),
            (["asr", "--categories", " , "], "--categories needs at least one category name"),
            (["asr", "--corpus"], "--corpus needs a value"),
            (["asr", "--corpus="], "--corpus needs a value"),
            (["asr", "--speed", "2"], "unknown option: --speed"),
            (["asr", "tts-samantha"], "unexpected argument: tts-samantha"),
        ]
        for (argv, message) in cases {
            XCTAssertEqual(EvalCommand.parse(argv), .invalid(message), "\(argv)")
        }
    }

    // MARK: - the configuration matrix

    /// The order and the label spelling are both contractual: the label is a
    /// row's identity in `BASELINE.json` and the order is the filename order in
    /// `docs/eval/runs/`. Changing either silently orphans every accepted band.
    func testAnUnspecifiedToggleMeansBoth() {
        guard case .run(let options) = EvalCommand.parse(["all"]) else {
            return XCTFail("should parse")
        }
        XCTAssertEqual(EvalCommand.configs(options).map(\.label), [
            "refine=off,dict=off",
            "refine=off,dict=on",
            "refine=on,dict=off",
            "refine=on,dict=on",
        ])
    }

    func testAnExplicitToggleNarrowsTheMatrix() {
        func configs(_ argv: [String]) -> [String] {
            guard case .run(let options) = EvalCommand.parse(argv) else { return ["<invalid>"] }
            return EvalCommand.configs(options).map(\.label)
        }
        XCTAssertEqual(configs(["stages", "--refine", "on"]),
                       ["refine=on,dict=off", "refine=on,dict=on"])
        XCTAssertEqual(configs(["stages", "--dict", "on"]),
                       ["refine=off,dict=on", "refine=on,dict=on"])
        XCTAssertEqual(configs(["stages", "--refine", "off", "--dict", "off"]),
                       ["refine=off,dict=off"])
    }

    // MARK: - artifact names and cache keys

    /// Per-utterance artifacts must end in `.detail.jsonl`: that suffix is the
    /// single `.gitignore` rule keeping transcripts out of the repo, and a file
    /// that misses it gets committed by accident.
    func testEveryPerUtteranceArtifactIsGitignorable() {
        let names = [
            EvalPaths.asrDetailName(corpus: "tts-samantha", engine: "apple_live",
                                    settingsHash: "abc123"),
            EvalPaths.asrCacheName(corpus: "tts-samantha", engine: "apple_live",
                                   settingsHash: "abc123"),
            EvalPaths.stagesDetailName(corpus: "tts-samantha", engine: "apple_live",
                                       config: "refine=on,dict=off"),
        ]
        for name in names {
            XCTAssertTrue(name.hasSuffix(".detail.jsonl"), name)
        }
        // The committed aggregate is the one file that is NOT detail.
        let summary = EvalPaths.runSummaryName(stamp: "2026-08-09T201402Z",
                                               corpus: "tts-samantha", engine: "apple_live",
                                               config: "refine=on,dict=on")
        XCTAssertEqual(summary, "2026-08-09T201402Z.tts-samantha.apple_live.refine-on.dict-on.json")
        XCTAssertFalse(summary.contains(".detail."))
    }

    func testConfigSlugIsFilesystemSafe() {
        XCTAssertEqual(EvalPaths.slug("refine=on,dict=off"), "refine-on.dict-off")
    }

    /// The cache key carries the audio's own sha, so a re-recorded take misses
    /// the cache without anyone remembering to clear it.
    func testCacheKeyFollowsTheAudio() {
        let a = EvalPaths.cacheKey(audioSha256: "aaaa", engine: "apple_live",
                                   settingsHash: "1111")
        XCTAssertEqual(a, "aaaa.apple_live.1111")
        XCTAssertNotEqual(a, EvalPaths.cacheKey(audioSha256: "bbbb", engine: "apple_live",
                                                settingsHash: "1111"))
        XCTAssertNotEqual(a, EvalPaths.cacheKey(audioSha256: "aaaa", engine: "apple_dictation",
                                                settingsHash: "1111"))
        XCTAssertNotEqual(a, EvalPaths.cacheKey(audioSha256: "aaaa", engine: "apple_live",
                                                settingsHash: "2222"))
    }

    /// Every recognizer setting that can move a transcript has to move the hash;
    /// one that does not would serve a stale transcript under a key claiming to
    /// describe it.
    func testSettingsHashCoversEverySettingThatMovesATranscript() {
        let base = EvalPaths.settingsHash(locale: "en-US", engine: "apple_live",
                                          finalizeTimeoutMs: 1500, contextualTermLimit: nil)
        XCTAssertEqual(base, EvalPaths.settingsHash(locale: "en-US", engine: "apple_live",
                                                    finalizeTimeoutMs: 1500,
                                                    contextualTermLimit: nil))
        XCTAssertEqual(base.count, 8)
        let variants = [
            EvalPaths.settingsHash(locale: "en-GB", engine: "apple_live",
                                   finalizeTimeoutMs: 1500, contextualTermLimit: nil),
            EvalPaths.settingsHash(locale: "en-US", engine: "apple_dictation",
                                   finalizeTimeoutMs: 1500, contextualTermLimit: nil),
            EvalPaths.settingsHash(locale: "en-US", engine: "apple_live",
                                   finalizeTimeoutMs: 3000, contextualTermLimit: nil),
            EvalPaths.settingsHash(locale: "en-US", engine: "apple_live",
                                   finalizeTimeoutMs: 1500, contextualTermLimit: 200),
        ]
        for variant in variants { XCTAssertNotEqual(base, variant) }
    }

    /// The ASR phase has produced nothing after the engine, so every later stage
    /// carries the raw text. Leaving them empty would score as whole-utterance
    /// deletions and make an ASR-only run look catastrophic.
    func testAnAsrOnlyRecordCarriesRawIntoEveryStage() {
        let line = EvalRunner.AsrCacheLine(
            key: "k", id: "pn-01", raw: "hi sharique", finalizeMs: 88, timedOut: false,
            starvedInput: false, peakLevel: 0.4, audioMs: 3280)
        let record = line.stageRecord(engine: "apple_live")
        XCTAssertEqual(record.id, "pn-01")
        XCTAssertEqual(record.engine, "apple_live")
        XCTAssertEqual([record.raw, record.corrected, record.refined, record.final],
                       Array(repeating: "hi sharique", count: 4))
        XCTAssertEqual(record.finalizeMs, 88)
    }

    // MARK: - report assembly

    func testStageRowsAreInPipelineOrderAndMicroAveraged() {
        let run = Self.fixtureSummary()

        XCTAssertEqual(run.stages.map(\.stage), ["raw", "corrected", "refined", "final"])
        XCTAssertEqual(run.corpusId, "fixture")
        XCTAssertEqual(run.config, "refine=off,dict=on")

        let raw = try? XCTUnwrap(run.stages.first)
        // "hi sharik" vs "hi sharique" is one substitution; the spelled run
        // collapses to `json` on both sides and costs nothing. Σerrors/Σwords,
        // never the mean of 0.5 and 0.
        XCTAssertEqual(raw?.refWords, 6)
        XCTAssertEqual(raw?.errors, 1)
        XCTAssertEqual(raw?.wer ?? 0, 1.0 / 6.0, accuracy: 1e-9)

        let final = run.stages.last
        XCTAssertEqual(final?.errors, 0)
        XCTAssertEqual(final?.wer, 0)
        XCTAssertEqual(final?.utterances, 2)
    }

    func testTermRecallAndZeroEditMoveWithTheStage() {
        let run = Self.fixtureSummary()
        // Only one clip expects a term, so recall is 0/1 raw and 1/1 final —
        // the clip that expects nothing contributes to neither side.
        XCTAssertEqual(run.stages.first?.termRecall, 0)
        XCTAssertEqual(run.stages.last?.termRecall, 1)
        XCTAssertEqual(run.stages.first?.zeroEdit, 0)
        XCTAssertEqual(run.stages.last?.zeroEdit, 1)
        // CER is the formatter's metric: casing and punctuation are missing from
        // the raw text and restored by the end.
        XCTAssertGreaterThan(run.stages.first?.cer ?? 0, run.stages.last?.cer ?? 1)
    }

    func testCategoriesFollowFirstAppearanceAndReportNilRecallWhenNothingIsExpected() {
        let run = Self.fixtureSummary()
        XCTAssertEqual(run.categories.map(\.category), ["proper-nouns", "spelled-runs"])
        XCTAssertEqual(run.categories.first?.termRecall, 1)
        XCTAssertNil(run.categories.last?.termRecall,
                     "a category that expects no terms must report — , not 1.000")
        XCTAssertEqual(run.categories.map(\.utterances), [1, 1])
    }

    /// A detail file left over from a corpus that has since lost a clip must not
    /// contribute a number with no reference behind it.
    func testRecordsWithNoManifestEntryAreDropped() {
        let orphan = StageRecord(id: "gone", engine: "apple_live", raw: "x", corrected: "x",
                                 refined: "x", final: "x")
        let run = EvalScoring.summary(
            timestamp: "2026-08-09T20:14:02Z", corpus: Self.fixtureCorpus(),
            records: Self.fixtureRecords() + [orphan], engine: "apple_live",
            config: "refine=off,dict=on", provenance: Self.fixtureProvenance())
        XCTAssertEqual(run.stages.first?.utterances, 2)
    }

    func testAMixedCorpusStillCarriesTheTtsBanner() {
        let entries = Self.fixtureCorpus().entries
        var human = entries[0]
        human.source = .human
        let mixed = Corpus(id: "mixed", split: "all", entries: [human, entries[1]])
        XCTAssertNil(mixed.source, "the fixture must actually be mixed")
        XCTAssertEqual(EvalScoring.reportedSource(mixed), .tts)
        XCTAssertEqual(EvalScoring.reportedSource(Self.fixtureCorpus()), .tts)
    }

    func testTheRenderedTableNamesEveryStage() {
        let text = EvalScoring.renderTable(Self.fixtureSummary())
        for stage in ["raw", "corrected", "refined", "final"] {
            XCTAssertTrue(text.contains(stage), text)
        }
        XCTAssertTrue(text.contains("refine=off,dict=on"), text)
        XCTAssertTrue(text.contains("proper-nouns"), text)
    }

    // MARK: - fixtures

    private static func fixtureCorpus() -> Corpus {
        Corpus(id: "fixture", split: "all", entries: [
            CorpusEntry(id: "pn-01", audio: "audio/pn-01.wav", sha256: "aaaa",
                        ref: "Hi Sharique.", category: "proper-nouns", speaker: "tts-samantha",
                        source: .tts, expect: CorpusExpectation(terms: ["Sharique"])),
            CorpusEntry(id: "sr-01", audio: "audio/sr-01.wav", sha256: "bbbb",
                        ref: "The payload is JSON.", category: "spelled-runs",
                        speaker: "tts-samantha", source: .tts,
                        expect: CorpusExpectation(refineBypass: "has_letter_run")),
        ])
    }

    private static func fixtureRecords() -> [StageRecord] {
        [
            StageRecord(id: "pn-01", engine: "apple_live", raw: "hi sharik",
                        corrected: "hi sharik", refined: "hi sharik", final: "Hi Sharique."),
            StageRecord(id: "sr-01", engine: "apple_live", raw: "the payload is J S O N",
                        corrected: "the payload is JSON", refined: "the payload is JSON",
                        final: "The payload is JSON."),
        ]
    }

    private static func fixtureProvenance() -> RunProvenance {
        RunProvenance(gitSha: "d6a3387", osBuild: "25F84", promptSha256: "deadbeef",
                      dictionaryTerms: 9, corpusSource: .tts)
    }

    private static func fixtureSummary() -> RunSummary {
        EvalScoring.summary(timestamp: "2026-08-09T20:14:02Z", corpus: fixtureCorpus(),
                            records: fixtureRecords(), engine: "apple_live",
                            config: "refine=off,dict=on", provenance: fixtureProvenance())
    }
}
