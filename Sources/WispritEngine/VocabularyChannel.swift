import Foundation
import AVFoundation
import Speech
import WispritKit

/// Result of the off-path vocabulary pass. The future in-field retro-correction
/// pass consumes this: `transcript` is DictationTranscriber's biased reading of
/// the same audio, `termHits` says which learned terms it actually recovered.
public struct VocabularyReconciliation: Sendable, Equatable {
    public var transcript: String
    /// Canonical term → whole-word occurrences in `transcript`.
    public var termHits: [String: Int]
    public var termCount: Int
    public var elapsedMs: Double

    public init(transcript: String, termHits: [String: Int], termCount: Int, elapsedMs: Double) {
        self.transcript = transcript; self.termHits = termHits
        self.termCount = termCount; self.elapsedMs = elapsedMs
    }
}

/// `DictationTranscriber` + `AnalysisContext.contextualStrings`, the ONLY Apple
/// mechanism that makes a learned name actually *recognized* rather than
/// post-corrected (`SpeechTranscriber` provably ignores contextualStrings).
///
/// Runs **off the paste path**, in its own analyzer, over retained PCM, after
/// the live result has already been inserted:
/// * Putting both modules in one analyzer costs 1377–1790 ms release→final —
///   never do it on the live path.
/// * `contextualStrings` costs ~3.1 ms/term, **all of it in session setup** and
///   none in decoding (release→final was flat 388–441 ms from n=0 to n=500), so
///   the whole dictionary ships. No 50-term cap. No dilution measured at n=500.
/// * `.frequentFinalization` is **mandatory**: with default reportingOptions, or
///   with `[.volatileResults]` alone, DictationTranscriber emits volatiles and
///   **no final at all** — silent total data loss.
public final class VocabularyChannel: @unchecked Sendable {
    public static let engineName = "apple_dictation"

    private let log = WLog.logger("engine.vocabulary")
    private let settings: AsrSettings
    private let vocabulary: (any VocabularySource)?

    public init(settings: AsrSettings, vocabulary: (any VocabularySource)?) {
        self.settings = settings
        self.vocabulary = vocabulary
    }

    /// Terms actually handed to the analyzer, honouring `contextualTermLimit`
    /// (nil = all of them, which is the shipping configuration).
    ///
    /// `extra` is the Phase-4 per-utterance seam: context-awareness candidates
    /// for THIS utterance only, merged AFTER the dictionary (and after its
    /// limit — the cap protects the dictionary path, and two dozen extras cost
    /// ~75 ms of session setup in a pass that is already off-path by contract).
    /// Deduped case-insensitively with the dictionary spelling winning, so a
    /// term the user already owns is never re-cased by what was on screen.
    /// Nothing here persists: the extras exist for one `reconcile` call.
    public func contextualTerms(extra: [String] = []) -> [String] {
        let all = vocabulary?.vocabularyTerms() ?? []
        var terms = all
        if let limit = settings.contextualTermLimit, limit > 0, all.count > limit {
            terms = Array(all.prefix(limit))
        }
        guard !extra.isEmpty else { return terms }
        var seen = Set(terms.map { $0.lowercased() })
        for term in extra where !term.isEmpty && seen.insert(term.lowercased()).inserted {
            terms.append(term)
        }
        return terms
    }

    /// Re-transcribe the retained utterance with the dictionary loaded. Returns
    /// nil when there is no audio or the pass failed — callers treat that as
    /// "no reconciliation available" and keep the live text unchanged.
    ///
    /// `extraTerms` bias this one pass and are counted in `termHits` alongside
    /// the dictionary — deliberately, because that is what lets the Phase-3
    /// retro-correction planner act on a context term with zero new machinery.
    /// They still persist nothing: `recordUse` ignores terms the dictionary
    /// does not hold, and the learn fallback is `isKnownTerm`-gated.
    ///
    /// Never call this before inserting: it is seconds of work, by design.
    public func reconcile(pcm: Data, extraTerms: [String] = []) async -> VocabularyReconciliation? {
        guard !pcm.isEmpty else { return nil }
        let terms = contextualTerms(extra: extraTerms)
        let t0 = Date()

        let module = DictationTranscriber(
            locale: Locale(identifier: settings.locale),
            contentHints: [.shortForm],
            transcriptionOptions: [.punctuation],
            reportingOptions: [.volatileResults, .frequentFinalization],
            attributeOptions: [])
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            log.error("no DictationTranscriber format for \(self.settings.locale, privacy: .public)")
            return nil
        }

        let context = AnalysisContext()
        if !terms.isEmpty { context.contextualStrings = [.general: terms] }

        let analyzer = SpeechAnalyzer(modules: [module])
        let (sequence, builder) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let sink = FinalsSink()
        let collector = Task {
            do {
                for try await result in module.results where result.isFinal {
                    await sink.append(String(result.text.characters))
                }
            } catch {
                await sink.setError("\(error)")
            }
        }

        do {
            try await analyzer.setContext(context)
            // prepareToAnalyze is what scales with term count — it stays inside this
            // background task, never in a key-down prewarm.
            try await analyzer.prepareToAnalyze(in: format)
            try await analyzer.start(inputSequence: sequence)
            // Off the paste path: feed as fast as the analyzer accepts it, no pacing.
            for chunk in PcmFormat.split(pcm) {
                guard let buffer = PcmFormat.buffer(from: chunk, in: format) else { continue }
                builder.yield(AnalyzerInput(buffer: buffer))
            }
            builder.finish()
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            log.error("vocabulary pass failed: \(error.localizedDescription, privacy: .public)")
            collector.cancel()
            await analyzer.cancelAndFinishNow()
            // Same recovery lever the live path uses after a failure, for the same
            // reason: a failed DictationTranscriber session leaves a cached engine
            // behind, and this channel shares that cache with the live path.
            // Measured free (0 ms, spike S1 Q1). Failure path ONLY — the matrix
            // below showed a *successful* reconcile does not degrade the live
            // path, so this is not a routine cooldown.
            await SpeechModels.endRetention()
            return nil
        }
        _ = await collector.value

        let (text, error) = await sink.snapshot()
        if error != nil { return nil }
        let transcript = text.trimmingCharacters(in: .whitespaces)
        return VocabularyReconciliation(
            transcript: transcript,
            termHits: Self.termHits(in: transcript, terms: terms),
            termCount: terms.count,
            elapsedMs: Date().timeIntervalSince(t0) * 1000.0)
    }

    /// Whole-word, case-insensitive occurrences of each term. Multi-word terms
    /// are matched with relaxed inter-word whitespace, like the dictionary pass.
    static func termHits(in text: String, terms: [String]) -> [String: Int] {
        guard !text.isEmpty else { return [:] }
        var hits: [String: Int] = [:]
        for term in terms {
            let words = term.split(whereSeparator: { $0.isWhitespace }).map { NSRegularExpression.escapedPattern(for: String($0)) }
            guard !words.isEmpty else { continue }
            let pattern = "\\b" + words.joined(separator: "\\s+") + "\\b"
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let n = re.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
            if n > 0 { hits[term] = n }
        }
        return hits
    }

}

actor FinalsSink {
    private var parts: [String] = []
    private var error: String?
    func append(_ s: String) { parts.append(s) }
    func setError(_ s: String) { if error == nil { error = s } }
    func snapshot() -> (String, String?) { (parts.joined(), error) }
}
