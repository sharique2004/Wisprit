#if os(macOS)
import Foundation
import WispritEngine
import WispritEval

/// `Wisprit eval verify` — ref against hyp, one clip at a time, decided by a
/// person.
///
/// Thin for the same reason `EvalRecorder` is: the decisions are in
/// `EvalVerifyPlan`, tested, and what is left here is a transcription pass, a
/// `readLine()` and a manifest rewrite.
///
/// The transcription runs through `EvalRunner.transcribe` — the same seam
/// `eval asr` uses — and **writes into the same cache file**, keyed by the same
/// `(audio sha, engine, settings)` triple. So a verify pass is not a detour: the
/// clips it transcribes are already transcribed when `eval asr` runs next, and
/// the reviewer and the scoreboard are looking at literally the same text.
struct EvalVerifier {

    let options: EvalCommand.Options

    enum VerifyError: Error, CustomStringConvertible {
        case noCheckout
        case missingFile(URL, hint: String)
        case corpus(String)
        case audioChanged(id: String)

        var description: String {
            switch self {
            case .noCheckout:
                return "could not locate the Wisprit checkout (set WISPRIT_EVAL_ROOT to it)"
            case let .missingFile(url, hint):
                return "\(url.path) not found — \(hint)"
            case let .corpus(detail):
                return "corpus: \(detail)"
            case let .audioChanged(id):
                return "audio for '\(id)' does not match the sha256 in the manifest "
                    + "— re-record it or fix the manifest before reviewing it"
            }
        }
    }

    // MARK: - entry point

    func run() -> Int32 {
        runBlocking { await self.execute() }
    }

    private func execute() async -> Int32 {
        do {
            return try await verify()
        } catch let error as VerifyError {
            FileHandle.standardError.write(Data("eval verify: \(error.description)\n".utf8))
            return 1
        } catch {
            FileHandle.standardError.write(Data("eval verify: \(error)\n".utf8))
            return 1
        }
    }

    private func verify() async throws -> Int32 {
        guard let root = EvalPaths.repoRoot() else { throw VerifyError.noCheckout }
        let corpusDir = EvalPaths.corpusDir(root: root, corpus: options.corpus)
        let manifestURL = corpusDir.appendingPathComponent("manifest.jsonl")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw VerifyError.missingFile(manifestURL, hint: "run `Wisprit eval record` first")
        }

        var entries = try loadManifest(manifestURL)
        // Slugged, because that is what `eval record` wrote into the manifest —
        // `--speaker SPK01` filtering to nothing would read as "already
        // reviewed" and is the kind of silence a review must not produce.
        let speaker = options.speaker.map(EvalRecordPlan.slug).flatMap { $0.isEmpty ? nil : $0 }
        let pending = EvalVerifyPlan.pending(entries, speaker: speaker)
        print("corpus   \(options.corpus) → \(manifestURL.path)")
        print("clips    \(entries.count) total, \(pending.count) unverified"
              + (speaker.map { " (speaker \($0))" } ?? ""))
        guard !pending.isEmpty else {
            print("nothing to review.")
            return 0
        }
        print("keys     Return/a accept · f fix the reference · d discard the take · q stop")

        var transcriber = try asrPass(root: root)
        var accepted = 0, corrected = 0, discarded = 0

        loop: for (position, entry) in pending.enumerated() {
            let audio = corpusDir.appendingPathComponent(entry.audio)
            guard FileManager.default.fileExists(atPath: audio.path) else {
                throw VerifyError.missingFile(audio, hint: "the manifest references it")
            }
            let hyp = try await transcriber.text(for: entry, audio: audio)

            print("")
            print("[\(position + 1)/\(pending.count)] \(entry.id) · \(entry.category)")
            print("  ref  \(entry.ref)")
            print("  hyp  \(hyp)")
            print("  diff \(EvalVerifyPlan.diff(ref: entry.ref, hyp: hyp))")
            print("       \(EvalVerifyPlan.summary(ref: entry.ref, hyp: hyp))")

            var decision = EvalVerifyPlan.decision(for: prompt("  [A]ccept / f / d / q > "))
            while case .unknown(let text) = decision {
                print("  '\(text)' is not one of a / f / d / q")
                decision = EvalVerifyPlan.decision(for: prompt("  [A]ccept / f / d / q > "))
            }

            var edited: String?
            if decision == .fix {
                print("  the reference is what the reader SAID, not what the script asked for.")
                edited = prompt("  ref> ")
            }
            guard let outcome = EvalVerifyPlan.apply(decision, to: entry, fixed: edited) else {
                break loop
            }

            entries = EvalVerifyPlan.applying(outcome, to: entries)
            try write(entries, to: manifestURL)
            switch outcome {
            case .verified:
                accepted += 1
                print("  accepted")
            case let .corrected(entry, was):
                corrected += 1
                print("  ref was: \(was)")
                print("  ref now: \(entry.ref)")
            case let .removed(_, audioPath):
                discarded += 1
                try discard(corpusDir.appendingPathComponent(audioPath))
                print("  discarded → \(EvalVerifyPlan.discardedPath(audioPath))")
            }
        }

        print("")
        print("accepted \(accepted), reference fixed \(corrected), discarded \(discarded)"
              + " — \(EvalVerifyPlan.pending(entries, speaker: speaker).count) left")
        return 0
    }

    // MARK: - the asr seam

    /// The cached transcription pass, sharing `eval asr`'s cache file so nothing
    /// is transcribed twice.
    private struct AsrPass {
        let runner: EvalRunner
        let cacheURL: URL
        let engine: String
        let settingsHash: String
        let settings: AsrSettings
        var cache: [String: EvalRunner.AsrCacheLine]

        mutating func text(for entry: CorpusEntry, audio: URL) async throws -> String {
            let data = try Data(contentsOf: audio)
            guard EvalPaths.sha256Hex(data) == entry.sha256 else {
                throw VerifyError.audioChanged(id: entry.id)
            }
            let key = EvalPaths.cacheKey(audioSha256: entry.sha256, engine: engine,
                                         settingsHash: settingsHash)
            if let hit = cache[key] { return hit.raw }

            let pcm = try EvalRunner.pcm(of: audio)
            let result = await runner.transcribe(pcm: pcm, settings: settings, vocabulary: nil)
            let line = EvalRunner.AsrCacheLine(
                key: key, id: entry.id, raw: result.text, finalizeMs: result.finalizeMs,
                timedOut: result.timedOut, starvedInput: result.starvedInput,
                peakLevel: Double(result.peakLevel), audioMs: EvalRunner.durationMs(of: pcm))
            cache[key] = line
            try EvalRunner.appendCache([line], to: cacheURL)
            return result.text
        }
    }

    private func asrPass(root: URL) throws -> AsrPass {
        var asrOptions = options
        asrOptions.verb = .asr
        let runner = EvalRunner(options: asrOptions)
        let settings = runner.asrSettings()
        let engine = runner.engineName
        let hash = EvalPaths.settingsHash(locale: settings.locale, engine: engine,
                                          finalizeTimeoutMs: settings.finalizeTimeoutMs,
                                          contextualTermLimit: settings.contextualTermLimit)
        let runs = options.out.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath,
                                         isDirectory: true) }
            ?? EvalPaths.runs(root: root)
        try FileManager.default.createDirectory(at: runs, withIntermediateDirectories: true)
        let cacheURL = runs.appendingPathComponent(
            EvalPaths.asrCacheName(corpus: options.corpus, engine: engine, settingsHash: hash))
        return AsrPass(runner: runner, cacheURL: cacheURL, engine: engine, settingsHash: hash,
                       settings: settings, cache: try EvalRunner.loadCache(cacheURL))
    }

    // MARK: - files

    private func loadManifest(_ url: URL) throws -> [CorpusEntry] {
        do {
            return try Corpus.parse(jsonl: String(contentsOf: url, encoding: .utf8))
        } catch let error as CorpusError {
            throw VerifyError.corpus(error.description)
        }
    }

    /// Rewritten after every decision rather than once at the end: a review is
    /// an hour of judgement calls and none of them should depend on the process
    /// surviving to the last clip.
    private func write(_ entries: [CorpusEntry], to url: URL) throws {
        try Corpus.jsonl(entries).write(to: url, atomically: true, encoding: .utf8)
    }

    /// Renamed, never deleted — see `EvalVerifyPlan.discardedPath`. An existing
    /// `.discarded` from an earlier pass is replaced, so a clip can be discarded
    /// twice without the second attempt failing.
    private func discard(_ audio: URL) throws {
        let manager = FileManager.default
        let target = URL(fileURLWithPath: EvalVerifyPlan.discardedPath(audio.path))
        if manager.fileExists(atPath: target.path) { try manager.removeItem(at: target) }
        try manager.moveItem(at: audio, to: target)
    }

    private func prompt(_ text: String) -> String? {
        FileHandle.standardOutput.write(Data(text.utf8))
        return readLine()
    }
}
#endif
