#if os(macOS)
import AVFoundation
import Foundation
import WispritCorrections
import WispritDictionary
import WispritEngine
import WispritEval
import WispritKit
import WispritPostProcess
import WispritRefine

/// The eval harness proper: audio in, scoreboard rows out.
///
/// Two phases, because they cost three orders of magnitude apart. `asr` runs the
/// recognizer once per (clip, engine, settings) and caches the transcript keyed
/// by the audio's own sha256 — a re-recorded take invalidates its line without
/// anyone remembering to clear anything. `stages` replays those transcripts
/// through the pipeline in `SessionController.finalizeUtterance` order, which is
/// what makes measuring four pipeline configurations a matter of seconds
/// (or of model latency, when refine is on) rather than of re-transcribing.
///
/// Nothing here reads `~/.wisprit`. The dictionary is the repo fixture at
/// `tools/eval/fixtures/eval-dictionary.json` and the pipeline settings are the
/// shipped defaults, so a row recorded on this machine means the same thing on
/// another one.
struct EvalRunner {

    let options: EvalCommand.Options

    // MARK: - failures

    enum EvalError: Error, CustomStringConvertible {
        case noCheckout
        case missingFile(URL, hint: String)
        case audioChanged(id: String)
        case refineUnavailable(String)
        case corpus(String)

        var description: String {
            switch self {
            case .noCheckout:
                return "could not locate the Wisprit checkout "
                    + "(set WISPRIT_EVAL_ROOT to it)"
            case let .missingFile(url, hint):
                return "\(url.path) not found — \(hint)"
            case let .audioChanged(id):
                return "audio for '\(id)' does not match the sha256 in the manifest "
                    + "— regenerate the corpus so the cache key follows the audio"
            case let .refineUnavailable(reason):
                return "Apple Intelligence unavailable: \(reason)"
            case let .corpus(detail):
                return "corpus: \(detail)"
            }
        }
    }

    /// The exit code a violated baseline band produces. Distinct from 1 (the run
    /// failed) and 2 (the arguments were wrong): a regression is a result, not
    /// an error, and a caller should be able to tell the three apart.
    static let regressionExit: Int32 = 3

    // MARK: - entry point

    /// Blocking bridge, exactly as `Wisprit doctor` does it: `main` is a plain
    /// thread with no run loop yet, so one `runBlocking` at the top is cheaper
    /// than making the whole harness sync-friendly.
    func run() -> Int32 {
        runBlocking { await self.execute() }
    }

    private func execute() async -> Int32 {
        do {
            return try await dispatch()
        } catch let error as EvalError {
            FileHandle.standardError.write(Data("eval: \(error.description)\n".utf8))
            return 1
        } catch {
            FileHandle.standardError.write(Data("eval: \(error)\n".utf8))
            return 1
        }
    }

    private func dispatch() async throws -> Int32 {
        guard let root = EvalPaths.repoRoot() else { throw EvalError.noCheckout }
        let outDir = try outputDirectory(root: root)

        // The battery scores the model, not a corpus, so it is the one verb that
        // needs no manifest — and requiring one would make it unrunnable on a
        // machine where the audio has not been generated.
        if options.verb == .refine {
            let battery = try await runBattery()
            print(String(format: "refine battery: %.4f (weighted, %d repeats)",
                         battery.score, options.repeatCount))
            return 0
        }

        let corpus = try loadCorpus(root: root)
        switch options.verb {
        case .asr:
            let records = try await runAsr(root: root, corpus: corpus, outDir: outDir)
            print("asr: \(records.count) clips")
            return 0

        case .stages:
            let asr = try loadAsr(outDir: outDir)
            for config in EvalCommand.configs(options) {
                let records = try await runStages(config: config, asr: asr,
                                                  root: root, outDir: outDir)
                print("stages \(config.label): \(records.count) clips")
            }
            return 0

        case .score:
            for config in EvalCommand.configs(options) {
                let records = try loadStages(config: config, outDir: outDir)
                let summary = try makeSummary(root: root, corpus: corpus,
                                              records: records, config: config)
                print(EvalScoring.renderTable(summary))
                print("")
            }
            return 0

        case .report:
            var worst: Int32 = 0
            for config in EvalCommand.configs(options) {
                let records = try loadStages(config: config, outDir: outDir)
                let summary = try makeSummary(root: root, corpus: corpus,
                                              records: records, config: config)
                worst = max(worst, try publish(summary, root: root, outDir: outDir))
            }
            return worst

        case .all:
            return try await runAll(root: root, corpus: corpus, outDir: outDir)

        case .refine:
            return 0   // handled above
        }
    }

    // MARK: - all

    /// asr once, then every configuration through stages → score → report.
    ///
    /// A configuration whose refine stage cannot run (Apple Intelligence off,
    /// assets still downloading) is skipped with a warning rather than failing
    /// the run: the refine-off rows are still a baseline, and half a scoreboard
    /// is worth more than none.
    private func runAll(root: URL, corpus: Corpus, outDir: URL) async throws -> Int32 {
        let asr = try await runAsr(root: root, corpus: corpus, outDir: outDir)
        var worst: Int32 = 0
        var skipped: [String] = []
        // The battery scores the prompt, so it belongs to the refine=on rows and
        // to no others. Run once and carry it: it is the same model, the same
        // cases and the same repeats for every configuration that uses it.
        var battery: Double?
        for config in EvalCommand.configs(options) {
            do {
                let records = try await runStages(config: config, asr: asr,
                                                  root: root, outDir: outDir)
                if config.refine, battery == nil {
                    battery = try await runBattery().score
                }
                let summary = try makeSummary(root: root, corpus: corpus,
                                              records: records, config: config,
                                              battery: config.refine ? battery : nil)
                print(EvalScoring.renderTable(summary))
                print("")
                worst = max(worst, try publish(summary, root: root, outDir: outDir))
            } catch EvalError.refineUnavailable(let reason) {
                skipped.append("\(config.label) (\(reason))")
                FileHandle.standardError.write(
                    Data("eval: skipped \(config.label) — \(reason)\n".utf8))
            }
        }
        if !skipped.isEmpty {
            print("skipped \(skipped.count) configuration(s): \(skipped.joined(separator: ", "))")
        }
        return worst
    }

    // MARK: - phase 1: audio → text

    private func runAsr(root: URL, corpus: Corpus, outDir: URL) async throws -> [StageRecord] {
        let settings = asrSettings()
        let engineName = self.engineName
        let hash = EvalPaths.settingsHash(locale: settings.locale, engine: engineName,
                                          finalizeTimeoutMs: settings.finalizeTimeoutMs,
                                          contextualTermLimit: settings.contextualTermLimit)
        let cacheURL = outDir.appendingPathComponent(
            EvalPaths.asrCacheName(corpus: options.corpus, engine: engineName,
                                   settingsHash: hash))
        let detailURL = outDir.appendingPathComponent(
            EvalPaths.asrDetailName(corpus: options.corpus, engine: engineName,
                                    settingsHash: hash))
        var cache = try Self.loadCache(cacheURL)
        let audioDir = EvalPaths.corpusDir(root: root, corpus: options.corpus)

        // Only the biased channel takes a vocabulary; the live SpeechTranscriber
        // provably ignores `contextualStrings` (spike S1), so handing it one
        // would record a biasing effect that does not exist.
        let vocabulary: (any VocabularySource)? =
            options.engine == .dictation ? dictionary(root: root) : nil

        var records: [StageRecord] = []
        var fresh: [AsrCacheLine] = []
        for entry in selected(corpus) {
            let audio = audioDir.appendingPathComponent(entry.audio)
            guard FileManager.default.fileExists(atPath: audio.path) else {
                throw EvalError.missingFile(
                    audio, hint: "run tools/eval/corpus/\(options.corpus)/generate.sh")
            }
            // The cache key is the manifest's sha, so a file that changed
            // without the manifest being regenerated would serve a stale
            // transcript under a key that claims to describe it. Cheap to
            // verify, and the failure it prevents is silent.
            guard try EvalPaths.sha256Hex(Data(contentsOf: audio)) == entry.sha256 else {
                throw EvalError.audioChanged(id: entry.id)
            }

            let key = EvalPaths.cacheKey(audioSha256: entry.sha256, engine: engineName,
                                         settingsHash: hash)
            if let hit = cache[key] {
                records.append(hit.stageRecord(engine: engineName))
                continue
            }

            let pcm = try Self.pcm(of: audio)
            let result = await transcribe(pcm: pcm, settings: settings, vocabulary: vocabulary)
            let line = AsrCacheLine(
                key: key, id: entry.id, raw: result.text, finalizeMs: result.finalizeMs,
                timedOut: result.timedOut, starvedInput: result.starvedInput,
                peakLevel: Double(result.peakLevel), audioMs: Self.durationMs(of: pcm))
            cache[key] = line
            fresh.append(line)
            records.append(line.stageRecord(engine: engineName))
            print("  \(entry.id): \(result.text)")
        }

        try Self.appendCache(fresh, to: cacheURL)
        try StageRecord.jsonl(records).write(to: detailURL, atomically: true, encoding: .utf8)
        print("asr: \(records.count) clips, \(fresh.count) transcribed, "
              + "\(records.count - fresh.count) cached → \(detailURL.lastPathComponent)")
        return records
    }

    private func loadAsr(outDir: URL) throws -> [StageRecord] {
        let settings = asrSettings()
        let hash = EvalPaths.settingsHash(locale: settings.locale, engine: engineName,
                                          finalizeTimeoutMs: settings.finalizeTimeoutMs,
                                          contextualTermLimit: settings.contextualTermLimit)
        let url = outDir.appendingPathComponent(
            EvalPaths.asrDetailName(corpus: options.corpus, engine: engineName,
                                    settingsHash: hash))
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw EvalError.missingFile(url, hint: "run `Wisprit eval asr` first")
        }
        return try StageRecord.decode(jsonl: String(contentsOf: url, encoding: .utf8))
    }

    /// One clip through the recognizer. `speech` is the live path;
    /// `dictation` is the off-path channel, whose whole reason to exist is that
    /// `contextualStrings` biasing works there and nowhere else.
    private func transcribe(pcm: Data, settings: AsrSettings,
                            vocabulary: (any VocabularySource)?) async -> UtteranceResult {
        switch options.engine {
        case .speech:
            let engine = SpeechAnalyzerEngine(settings: settings)
            guard await engine.begin(onPartial: { _ in }) else {
                return UtteranceResult(text: "", engine: SpeechAnalyzerEngine.engineName,
                                       finalizeMs: 0, crashed: true)
            }
            await Self.feed(pcm, realtime: options.realtime) { engine.feed(pcm: $0) }
            return await engine.finalize()

        case .dictation:
            let channel = VocabularyChannel(settings: settings, vocabulary: vocabulary)
            guard let reconciliation = await channel.reconcile(pcm: pcm) else {
                return UtteranceResult(text: "", engine: VocabularyChannel.engineName,
                                       finalizeMs: 0, crashed: true)
            }
            return UtteranceResult(text: reconciliation.transcript,
                                   engine: VocabularyChannel.engineName,
                                   finalizeMs: reconciliation.elapsedMs,
                                   peakLevel: PcmFormat.level(of: pcm))
        }
    }

    /// The `LiveAsrTests` reading idiom: whatever the file is, `PcmFormat`
    /// hands back canonical 16 kHz mono Int16 bytes.
    static func pcm(of url: URL) throws -> Data {
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(file.length)) else {
            throw EvalError.missingFile(url, hint: "could not allocate a buffer for it")
        }
        try file.read(into: buffer)
        return PcmFormat.canonicalData(from: buffer)
    }

    /// 100 ms chunks — the push-to-talk shape. Real-time pacing is off by
    /// default: the analyzer sees the same samples either way, so paying one
    /// wall-second per audio-second only buys a latency measurement.
    static func feed(_ pcm: Data, realtime: Bool, to sink: (Data) -> Void) async {
        let step = Int(PcmFormat.chunkFrames) * PcmFormat.bytesPerFrame
        let start = Date()
        var offset = 0, chunks = 0
        while offset < pcm.count {
            sink(pcm.subdata(in: offset..<min(offset + step, pcm.count)))
            offset += step
            chunks += 1
            if realtime {
                let due = start.addingTimeInterval(Double(chunks) * 0.1).timeIntervalSinceNow
                if due > 0 { try? await Task.sleep(nanoseconds: UInt64(due * 1e9)) }
            }
        }
    }

    static func durationMs(of pcm: Data) -> Double {
        Double(pcm.count) / Double(PcmFormat.bytesPerFrame) / PcmFormat.sampleRate * 1000.0
    }

    // MARK: - phase 2: text → pipeline

    /// Replay in the shipped order, mirroring `SessionController.finalizeUtterance`:
    /// spoken-spelling corrections on the RAW final, then the Apple Intelligence
    /// cage, then the deterministic post-process with the dictionary.
    ///
    /// One deliberate difference: `previousUtterance` is always empty. The
    /// session carries the last utterance so a cross-utterance spelling
    /// directive can find its antecedent; corpus clips are independent
    /// recordings in manifest order, so carrying it would invent antecedents
    /// out of adjacency.
    private func runStages(config: EvalCommand.Config, asr: [StageRecord],
                           root: URL, outDir: URL) async throws -> [StageRecord] {
        let store = dictionary(root: root)
        let corrector = SpokenSpellingCorrector(vocabulary: store)
        let refiner = config.refine ? try await makeRefiner(vocabulary: store) : nil

        var out: [StageRecord] = []
        for record in asr {
            let raw = record.raw
            let action = corrector.decide(utterance: raw, previousUtterance: "")
            let correction = CorrectionApplier.apply(action, to: raw)

            var refined = correction.text
            var outcome = RefineOutcome.off
            var aiMs: Double?
            if let refiner {
                // Prewarm per clip exactly like a record press, and never reuse
                // a session: `LanguageModelSession` accumulates a transcript.
                await refiner.begin()
                let started = Date()
                let result = await refiner.refine(correction.text)
                aiMs = Date().timeIntervalSince(started) * 1000.0
                refined = result.text
                outcome = result.outcome
            }

            // `--dict off` removes the dictionary from the post-process stage
            // only. The corrector and the refine cage keep it as a *vocabulary*
            // (is this spelled run already a known term?), which is a different
            // job from rewriting the text and is not what the flag measures.
            let final = PostProcess.process(refined,
                                            options: PostProcessOptions(),
                                            corrections: config.dict ? store : nil)

            out.append(StageRecord(id: record.id, engine: record.engine, raw: raw,
                                   corrected: correction.text, refined: refined, final: final,
                                   ai: outcome.rawValue, aiMs: aiMs,
                                   finalizeMs: record.finalizeMs, timedOut: record.timedOut,
                                   starvedInput: record.starvedInput))
        }
        if let refiner { await refiner.cancel() }

        let url = outDir.appendingPathComponent(
            EvalPaths.stagesDetailName(corpus: options.corpus, engine: engineName,
                                       config: config.label))
        try StageRecord.jsonl(out).write(to: url, atomically: true, encoding: .utf8)
        return out
    }

    private func loadStages(config: EvalCommand.Config, outDir: URL) throws -> [StageRecord] {
        let url = outDir.appendingPathComponent(
            EvalPaths.stagesDetailName(corpus: options.corpus, engine: engineName,
                                       config: config.label))
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw EvalError.missingFile(url, hint: "run `Wisprit eval stages` first")
        }
        return try StageRecord.decode(jsonl: String(contentsOf: url, encoding: .utf8))
    }

    private func makeRefiner(vocabulary: any VocabularySource) async throws -> Refiner {
        #if canImport(FoundationModels)
        let refiner = Refiner(generator: SystemModelGenerator(),
                              configuration: { RefineConfiguration() },
                              vocabulary: vocabulary,
                              startProbe: false)
        guard await refiner.probeNow() else {
            throw EvalError.refineUnavailable(await refiner.unavailableReason)
        }
        return refiner
        #else
        throw EvalError.refineUnavailable("FoundationModels unavailable in this build")
        #endif
    }

    // MARK: - the refine battery

    /// Every `RefineBattery` case, `--repeat N` times, against the real cage.
    ///
    /// The aggregate is the mean of the per-repeat aggregates rather than one
    /// aggregate over all verdicts: they are numerically the same here, and the
    /// per-repeat numbers are what say whether a low score is a consistent
    /// failure or a stochastic one.
    private func runBattery() async throws -> (score: Double, verdicts: [CaseVerdict]) {
        let refiner = try await makeRefiner(vocabulary: EmptyVocabulary())
        var passes: [Double] = []
        var all: [CaseVerdict] = []
        var passCount: [String: Int] = [:]

        for pass in 1...options.repeatCount {
            var verdicts: [CaseVerdict] = []
            for testCase in RefineBattery.cases {
                await refiner.begin()
                let result = await refiner.refine(testCase.input)
                let verdict = RefineBattery.evaluate(testCase, output: result.text,
                                                     outcome: result.outcome.rawValue)
                verdicts.append(verdict)
                if verdict.passed { passCount[testCase.id, default: 0] += 1 }
            }
            let score = RefineBattery.aggregate(verdicts)
            passes.append(score)
            all.append(contentsOf: verdicts)
            print(String(format: "  pass %d/%d: %.4f", pass, options.repeatCount, score))
        }
        await refiner.cancel()

        // Per-case pass rates: the aggregate says the battery moved, this says
        // which class of failure moved it.
        for testCase in RefineBattery.cases {
            let hits = passCount[testCase.id] ?? 0
            guard hits < options.repeatCount else { continue }
            print("  \(testCase.id): \(hits)/\(options.repeatCount) passes")
        }

        let mean = passes.isEmpty ? 0 : passes.reduce(0, +) / Double(passes.count)
        return (mean, all)
    }

    /// The battery is about the prompt, not about anyone's dictionary — an empty
    /// vocabulary keeps the letter-run guard's "already a known term" branch out
    /// of the measurement.
    private struct EmptyVocabulary: VocabularySource {
        func vocabularyTerms() -> [String] { [] }
        func isKnownTerm(_ word: String) -> Bool { false }
    }

    // MARK: - scoring and reporting

    private func makeSummary(root: URL, corpus: Corpus, records: [StageRecord],
                             config: EvalCommand.Config,
                             battery: Double? = nil) throws -> RunSummary {
        EvalScoring.summary(timestamp: EvalPaths.timestamp(Date()),
                            corpus: corpus,
                            records: records,
                            engine: engineName,
                            config: config.label,
                            provenance: provenance(root: root, corpus: corpus),
                            battery: battery,
                            notes: notes())
    }

    /// Everything that makes a row attributable six months later. Read here,
    /// never inside `WispritEval` — the library is pure so its renderers can be
    /// golden-tested.
    private func provenance(root: URL, corpus: Corpus) -> RunProvenance {
        RunProvenance(
            gitSha: Self.shell("/usr/bin/git", ["-C", root.path, "rev-parse", "--short", "HEAD"])
                ?? "unknown",
            osBuild: Self.shell("/usr/bin/sw_vers", ["-buildVersion"]) ?? "unknown",
            promptSha256: EvalPaths.sha256Hex(RefineInstructions.text),
            dictionaryTerms: dictionary(root: root).terms().count,
            corpusSource: EvalScoring.reportedSource(corpus))
    }

    private func notes() -> String? {
        guard !options.categories.isEmpty else { return nil }
        return "Categories: \(options.categories.joined(separator: ", ")) "
            + "— a filtered run is not comparable with a full one."
    }

    /// Append the section, write the run JSON, and compare against the accepted
    /// numbers. RESULTS.md is append-only: a section is a dated record of what
    /// this build measured, and editing history is how a scoreboard stops being
    /// evidence.
    private func publish(_ summary: RunSummary, root: URL, outDir: URL) throws -> Int32 {
        try Scoreboard.appendSection(Scoreboard.markdownSection(for: summary),
                                     to: EvalPaths.results(root: root),
                                     creatingWith: Self.resultsHeader)
        let name = EvalPaths.runSummaryName(stamp: EvalPaths.stamp(Date()),
                                            corpus: summary.corpusId,
                                            engine: summary.engine,
                                            config: summary.config)
        let url = outDir.appendingPathComponent(name)
        try Scoreboard.writeSummary(summary, to: url)
        print("recorded \(summary.config) → docs/eval/RESULTS.md + \(name)")

        let baselineURL = options.baseline.map { URL(fileURLWithPath: $0) }
            ?? EvalPaths.baseline(root: root)
        guard FileManager.default.fileExists(atPath: baselineURL.path),
              let baseline = try? Scoreboard.decodeBaseline(Data(contentsOf: baselineURL))
        else { return 0 }
        let violations = Scoreboard.compare(run: summary, baseline: baseline)
        guard !violations.isEmpty else { return 0 }
        FileHandle.standardError.write(Data(
            ("baseline violated:\n" + violations.map { "  \($0)" }.joined(separator: "\n") + "\n")
                .utf8))
        return Self.regressionExit
    }

    /// Written only when RESULTS.md is absent — the committed file carries the
    /// full discipline note. Kept short here on purpose: this is a fallback for
    /// a checkout that lost the file, not a second copy of the documentation.
    static let resultsHeader = """
        # Wisprit accuracy results

        Append-only. Every section is one `Wisprit eval` run, stamped with the git
        sha, OS build, prompt hash and dictionary size that produced it. Never edit
        or delete a section: a superseded number is evidence of what changed.

        Definitions live in `DEFINITIONS.md`; accepted numbers in `BASELINE.json`.
        """

    // MARK: - inputs

    private func loadCorpus(root: URL) throws -> Corpus {
        let url = EvalPaths.manifest(root: root, corpus: options.corpus)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw EvalError.missingFile(
                url, hint: "run tools/eval/corpus/\(options.corpus)/generate.sh")
        }
        do {
            return try Corpus.load(contentsOf: url, id: options.corpus, split: "all")
        } catch let error as CorpusError {
            throw EvalError.corpus(error.description)
        }
    }

    /// `--categories` narrows the corpus. The filter is applied here rather than
    /// at scoring time so a partial run's artifacts contain exactly what was
    /// measured.
    private func selected(_ corpus: Corpus) -> [CorpusEntry] {
        guard !options.categories.isEmpty else { return corpus.entries }
        let wanted = Set(options.categories)
        return corpus.entries.filter { wanted.contains($0.category) }
    }

    private func dictionary(root: URL) -> DictionaryStore {
        DictionaryStore(path: EvalPaths.dictionaryFixture(root: root))
    }

    private var engineName: String {
        options.engine == .speech
            ? SpeechAnalyzerEngine.engineName
            : VocabularyChannel.engineName
    }

    /// The shipped defaults, not the user's config: a scoreboard row has to mean
    /// the same thing on another machine.
    private func asrSettings() -> AsrSettings {
        AsrSettings(locale: "en-US", finalizeTimeoutMs: 1500, engine: .appleLive)
    }

    private func outputDirectory(root: URL) throws -> URL {
        let url = options.out.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath,
                                        isDirectory: true) }
            ?? EvalPaths.runs(root: root)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - the ASR cache

    /// One cached transcript. Separate from `StageRecord` because the cache key
    /// needs the audio sha, which the interchange record has no field for — and
    /// `WispritEval` owns that schema.
    struct AsrCacheLine: Codable, Equatable {
        var key: String
        var id: String
        var raw: String
        var finalizeMs: Double
        var timedOut: Bool
        var starvedInput: Bool
        var peakLevel: Double
        var audioMs: Double

        /// The ASR phase fills every stage with the raw text: nothing after the
        /// engine has run yet, and leaving them empty would score as deletions.
        func stageRecord(engine: String) -> StageRecord {
            StageRecord(id: id, engine: engine, raw: raw, corrected: raw, refined: raw,
                        final: raw, finalizeMs: finalizeMs, timedOut: timedOut,
                        starvedInput: starvedInput)
        }
    }

    /// Last line wins, so the file can be appended to forever and a re-recorded
    /// clip's new transcript shadows the old one under its new key.
    static func loadCache(_ url: URL) throws -> [String: AsrCacheLine] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let decoder = JSONDecoder()
        var out: [String: AsrCacheLine] = [:]
        for raw in try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, let data = line.data(using: .utf8),
                  let entry = try? decoder.decode(AsrCacheLine.self, from: data) else { continue }
            out[entry.key] = entry
        }
        return out
    }

    static func appendCache(_ lines: [AsrCacheLine], to url: URL) throws {
        guard !lines.isEmpty else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let text = try lines.map { String(decoding: try encoder.encode($0), as: UTF8.self) }
            .joined(separator: "\n") + "\n"
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
        guard manager.fileExists(atPath: url.path) else {
            return try text.write(to: url, atomically: true, encoding: .utf8)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    // MARK: - the machine

    /// One command, stdout trimmed, nil on any failure. Provenance must never
    /// be the reason a run dies — an "unknown" git sha is a worse row, not a
    /// missing one.
    static func shell(_ path: String, _ arguments: [String]) -> String? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
#endif
