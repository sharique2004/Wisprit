import Foundation
import WispritKit

/// The Parakeet vocabulary channel — fork (b) of the B-0 spike verdict
/// (docs/research/spikes-parakeet.md): batch-decode the retained utterance with
/// Parakeet TDT v3, run CTC keyword spotting over the dictionary (term + hear
/// phrases as aliases), and consume the EVIDENCE ONLY. The rescorer's rewritten
/// text is never taken — measured 23–50 false replacements across 44 clips —
/// and that refusal is structural here: the decode seam does not even carry it.
///
/// Same reconcile surface as `WispritEngine.VocabularyChannel`, same downstream:
/// `VocabularyReconciler.plan` judges the substituted transcript with its
/// term-anchored/phonetic/no-delete gates, which are precisely the FP filter the
/// vendor rescorer lacks (every spike FP fails a gate; every true hit passes).
///
/// ## Adoption recipe (when the human-corpus gate says go)
/// WispritMac deliberately does not link this target yet — the transitive
/// binary xcframework must not ride every install for an opt-in feature. To
/// adopt:
/// 1. Package.swift (orchestrator-owned): add `"WispritParakeet"` to the
///    `WispritMac` target dependencies — one manifest line.
/// 2. Factory registration: in the session wiring, build
///    `ParakeetVocabularyChannel(decoder: ParakeetLiveDecoder(modelsDir:
///    ParakeetModelStore.productionModelsDir), terms: { dictionary terms +
///    heardPhrases as ParakeetTerm })`, call `warmup()` off-path at app start
///    (first-ever load compiles CoreML for ~16 s, once per machine), and have
///    `AsrPort.reconcileVocabulary` map `ParakeetReconciliation` →
///    `VocabularyReconciliation` field-for-field (deliberately the same shape).
/// Also recorded in docs/notes/deviations.md §7.

/// One dictionary entry as the spotter wants it: canonical spelling plus the
/// recorded hear phrases. Maps 1:1 onto FluidAudio's
/// `CustomVocabularyTerm(text:aliases:)` — the alias match is what fires
/// ("whisper it" → Wisprit at similarity 1.0, spike Q2).
public struct ParakeetTerm: Sendable, Equatable {
    public var text: String
    public var aliases: [String]

    public init(text: String, aliases: [String] = []) {
        self.text = text
        self.aliases = aliases
    }
}

/// Spotting evidence for one candidate, distilled from FluidAudio's
/// `CandidateEvidence` to exactly what the substitution rules and the
/// downstream reconciler care about. Scores ride along for metrics and future
/// threshold tuning; the structural fields do the gating.
public struct ParakeetSpotEvidence: Sendable, Equatable {
    /// The untouched phrase in the base transcript this candidate would replace.
    public var basePhrase: String
    /// The canonical dictionary spelling proposed.
    public var term: String
    /// The hear phrase that matched, nil when the canonical text did.
    public var alias: String?
    public var similarity: Double
    public var vocabularyCtcScore: Double?
    public var originalCtcScore: Double?
    /// Half-open UTF-8 byte range of `basePhrase` in the base transcript, when
    /// exact alignment was available. No range → no substitution, ever.
    public var utf8Range: Range<Int>?
    /// The acoustic comparison (constrained CTC, vocab vs original) passed.
    public var comparisonPassed: Bool
    /// The candidate won the rescorer's overlap arbitration ("applied").
    public var applied: Bool
    public var reason: String

    public init(basePhrase: String, term: String, alias: String? = nil,
                similarity: Double, vocabularyCtcScore: Double? = nil,
                originalCtcScore: Double? = nil, utf8Range: Range<Int>? = nil,
                comparisonPassed: Bool, applied: Bool, reason: String = "") {
        self.basePhrase = basePhrase
        self.term = term
        self.alias = alias
        self.similarity = similarity
        self.vocabularyCtcScore = vocabularyCtcScore
        self.originalCtcScore = originalCtcScore
        self.utf8Range = utf8Range
        self.comparisonPassed = comparisonPassed
        self.applied = applied
        self.reason = reason
    }
}

/// What one batch decode + spot pass yields. There is deliberately NO
/// rescored-text field: the only transcript in the system is the raw TDT one,
/// so "never take the rescorer's rewrite" cannot regress by accident.
public struct ParakeetDecodeOutput: Sendable, Equatable {
    public var transcript: String
    public var evidence: [ParakeetSpotEvidence]

    public init(transcript: String, evidence: [ParakeetSpotEvidence] = []) {
        self.transcript = transcript
        self.evidence = evidence
    }
}

/// The decoder seam. `ParakeetLiveDecoder` is the FluidAudio-backed
/// implementation; tests fake it to pin the substitution rules without models.
public protocol ParakeetDecoding: Sendable {
    /// Load models and absorb the ANE cold start (first decode in-process costs
    /// 112–534 ms; first-ever load ~16 s of CoreML compile). Throws when models
    /// are absent or unverified.
    func warmup() async throws
    /// Batch-decode 16 kHz mono Int16 PCM and spot `terms`. Evidence only.
    func decode(pcm: Data, terms: [ParakeetTerm]) async throws -> ParakeetDecodeOutput
}

/// Mirror of `WispritEngine.VocabularyReconciliation`, field for field, so the
/// eventual `AsrPort` adapter is a struct-copy — the shape is the contract.
public struct ParakeetReconciliation: Sendable, Equatable {
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

/// The conformance seam WispritMac adopts with the one-line link: the same
/// reconcile surface `SessionController` already speaks, minus the engine types.
public protocol ParakeetReconciling: Sendable {
    /// Off-path prewarm; safe to call more than once.
    func warmup() async
    /// nil = "no reconciliation available", callers keep the live text.
    func reconcile(pcm: Data, extraTerms: [String]) async -> ParakeetReconciliation?
}

public actor ParakeetVocabularyChannel: ParakeetReconciling {
    public static let engineName = "parakeet_tdt_v3"

    private let log = WLog.logger("parakeet.channel")
    private let decoder: any ParakeetDecoding
    private let termsProvider: @Sendable () -> [ParakeetTerm]
    private var warmed = false

    public init(decoder: any ParakeetDecoding,
                terms: @escaping @Sendable () -> [ParakeetTerm]) {
        self.decoder = decoder
        self.termsProvider = terms
    }

    /// Load-once lifecycle: the first successful warmup sticks; a failed one
    /// (models not downloaded yet) may be retried after the user downloads.
    public func warmup() async {
        guard !warmed else { return }
        do {
            try await decoder.warmup()
            warmed = true
        } catch {
            log.error("parakeet warmup failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Re-read the utterance with the dictionary spotted. Same contract as the
    /// DictationTranscriber channel: off the paste path, after insertion, nil
    /// on any failure. `extraTerms` are this utterance's context candidates —
    /// they bias this one pass, are counted in `termHits`, and persist nothing.
    public func reconcile(pcm: Data, extraTerms: [String] = []) async -> ParakeetReconciliation? {
        guard !pcm.isEmpty else { return nil }
        let terms = Self.merged(dictionary: termsProvider(), extras: extraTerms)
        guard !terms.isEmpty else { return nil }
        let t0 = Date()

        let output: ParakeetDecodeOutput
        do {
            output = try await decoder.decode(pcm: pcm, terms: terms)
        } catch {
            log.error("parakeet reconcile failed: \(String(describing: error), privacy: .public)")
            return nil
        }

        let names = terms.map(\.text)
        let transcript = Self.substituted(base: output.transcript,
                                          evidence: output.evidence,
                                          allowedTerms: Set(names))
        return ParakeetReconciliation(
            transcript: transcript,
            termHits: Self.termHits(in: transcript, terms: names),
            termCount: terms.count,
            elapsedMs: Date().timeIntervalSince(t0) * 1000.0)
    }

    // MARK: - Term assembly

    /// Dictionary first, extras after, deduped case-insensitively with the
    /// dictionary spelling winning — the same merge contract as
    /// `VocabularyChannel.contextualTerms`, so a term the user owns is never
    /// re-cased by what was on screen. Extras carry no aliases: they existed as
    /// literal text moments ago, so the canonical spelling is the spot target.
    static func merged(dictionary: [ParakeetTerm], extras: [String]) -> [ParakeetTerm] {
        var terms = dictionary
        var seen = Set(dictionary.map { $0.text.lowercased() })
        for extra in extras where !extra.isEmpty && seen.insert(extra.lowercased()).inserted {
            terms.append(ParakeetTerm(text: extra))
        }
        return terms
    }

    // MARK: - Evidence → transcript (pure, pinned by tests)

    /// Splice ONLY spotter-confirmed dictionary terms into the base transcript.
    ///
    /// A candidate substitutes exactly when ALL of:
    /// * the rescorer applied it (`applied`) after the acoustic comparison
    ///   passed (`comparisonPassed`) — the evidence, not the rewrite;
    /// * its canonical term is one we asked to spot (`allowedTerms`) — evidence
    ///   about a term nobody asked for is discarded unread;
    /// * it carries an exact byte range whose slice of the base transcript is
    ///   byte-identical to its `basePhrase` — misaligned evidence is refused,
    ///   not repaired.
    /// Overlaps keep the higher similarity. Everything outside accepted ranges
    /// is the raw TDT transcript, byte for byte — which is what makes "never
    /// take the rescorer's text" a property of the code shape, not a policy.
    static func substituted(base: String,
                            evidence: [ParakeetSpotEvidence],
                            allowedTerms: Set<String>) -> String {
        let baseBytes = Array(base.utf8)
        var eligible: [(range: Range<Int>, term: String, similarity: Double)] = []
        for candidate in evidence {
            guard candidate.applied, candidate.comparisonPassed,
                  allowedTerms.contains(candidate.term),
                  let range = candidate.utf8Range,
                  range.lowerBound >= 0, range.upperBound <= baseBytes.count,
                  !range.isEmpty else { continue }
            // The range must point at exactly the phrase the evidence claims.
            guard Array(candidate.basePhrase.utf8) == Array(baseBytes[range]) else { continue }
            // Splicing identical bytes is a no-op; skip so overlap arbitration
            // never prefers a no-op over a real recovery.
            guard Array(candidate.term.utf8) != Array(baseBytes[range]) else { continue }
            eligible.append((range, candidate.term, candidate.similarity))
        }
        guard !eligible.isEmpty else { return base }

        // Higher similarity claims its range first; ties resolve to the
        // earlier range so the outcome is deterministic.
        eligible.sort {
            if $0.similarity != $1.similarity { return $0.similarity > $1.similarity }
            return $0.range.lowerBound < $1.range.lowerBound
        }
        var kept: [(range: Range<Int>, term: String)] = []
        for candidate in eligible
        where !kept.contains(where: { $0.range.overlaps(candidate.range) }) {
            kept.append((candidate.range, candidate.term))
        }
        kept.sort { $0.range.lowerBound < $1.range.lowerBound }

        var out: [UInt8] = []
        out.reserveCapacity(baseBytes.count)
        var cursor = 0
        for (range, term) in kept {
            out.append(contentsOf: baseBytes[cursor..<range.lowerBound])
            out.append(contentsOf: Array(term.utf8))
            cursor = range.upperBound
        }
        out.append(contentsOf: baseBytes[cursor...])
        // The ranges came from evidence that aligned to whole words, but a
        // malformed one could still split a multi-byte character; refuse the
        // whole substitution rather than emit mojibake.
        guard let text = String(bytes: out, encoding: .utf8) else { return base }
        return text
    }

    /// Whole-word, case-insensitive occurrences of each term, multi-word terms
    /// whitespace-relaxed — the SAME rule as `VocabularyChannel.termHits`, kept
    /// in lockstep so `VocabularyReconciler` sees identical semantics from
    /// either channel.
    static func termHits(in text: String, terms: [String]) -> [String: Int] {
        guard !text.isEmpty else { return [:] }
        var hits: [String: Int] = [:]
        for term in terms {
            let words = term.split(whereSeparator: { $0.isWhitespace })
                .map { NSRegularExpression.escapedPattern(for: String($0)) }
            guard !words.isEmpty else { continue }
            let pattern = "\\b" + words.joined(separator: "\\s+") + "\\b"
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            else { continue }
            let n = re.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
            if n > 0 { hits[term] = n }
        }
        return hits
    }
}
