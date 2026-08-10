import FluidAudio
import Foundation
import WispritKit

/// The FluidAudio-backed `ParakeetDecoding`, composing the manual load path the
/// spike validated (docs/research/spikes-parakeet.md, "API reality"):
///
/// * TDT: `AsrModels.load(from:version:.v3, encoderPrecision:.int8)` +
///   `AsrManager`, fresh `TdtDecoderState` per utterance.
/// * CTC: `CtcModels.loadDirect(from:)` + `CtcTokenizer.load(from:)` from OUR
///   models dir — never `CustomVocabularyContext.loadWithCtcTokens`, which
///   hardcodes the Application Support cache — and each term encoded into
///   `ctcTokenIds` by hand (the ≈20 lines the spike promised).
/// * Rescorer: `spotterRescueEnabled: false` is mandatory (vendor's own
///   #702/#724 guidance; the spike measured 50 → 23 FPs), thresholds from
///   `ContextBiasingConstants.rescorerConfig(forVocabSize:)`, and ONLY
///   `ctcTokenEvaluateCandidates` is called — the evidence API. The rescored
///   text never exists in this process.
///
/// Zero-network double lock: `AsrModels.load` routes files through ModelHub,
/// which silently downloads anything missing. Before ANY FluidAudio call this
/// decoder (1) requires `ParakeetModelStore.state() == .verified` — every file
/// present and byte-identical to the manifest — and (2) sets
/// `ModelHub.offlineMode = true`, FluidAudio's own hard refusal, so even an
/// unforeseen code path inside the dependency throws instead of fetching.
public actor ParakeetLiveDecoder: ParakeetDecoding {

    public enum DecoderError: Error, Equatable {
        /// `ParakeetModelStore` did not answer `.verified`; no FluidAudio API
        /// was called. Download the models first (explicit user action).
        case modelsNotVerified
    }

    private struct Stack {
        let manager: AsrManager
        let spotter: CtcKeywordSpotter
        let tokenizer: CtcTokenizer
        let ctcDirectory: URL
    }

    /// Vocabulary artifacts are cached against the exact term list: terms
    /// change rarely (a learn event), rescorer creation is milliseconds, and
    /// rebuilding on change keeps the ctcTokenIds honest.
    private struct VocabularyStack {
        let terms: [ParakeetTerm]
        let context: CustomVocabularyContext
        let rescorer: VocabularyRescorer
        let sizeConfig: ContextBiasingConstants.VocabSizeConfig
    }

    private let store: ParakeetModelStore
    private let modelsDir: URL
    private let log = WLog.logger("parakeet.decoder")
    private var stack: Stack?
    private var vocabularyStack: VocabularyStack?

    public init(modelsDir: URL) {
        self.modelsDir = modelsDir
        self.store = ParakeetModelStore(modelsDir: modelsDir)
    }

    public func warmup() async throws {
        _ = try await loadedStack()
    }

    public func decode(pcm: Data, terms: [ParakeetTerm]) async throws -> ParakeetDecodeOutput {
        let stack = try await loadedStack()
        let samples = Self.floats(fromInt16: pcm)

        var decoderState = TdtDecoderState.make(decoderLayers: await stack.manager.decoderLayerCount)
        let result = try await stack.manager.transcribe(
            samples, decoderState: &decoderState, language: .english)

        guard !terms.isEmpty else { return ParakeetDecodeOutput(transcript: result.text) }
        let vocabulary = try await vocabularyStack(for: terms, stack: stack)
        guard !vocabulary.context.terms.isEmpty else {
            return ParakeetDecodeOutput(transcript: result.text)
        }

        let spot = try await stack.spotter.spotKeywordsWithLogProbs(
            audioSamples: samples, customVocabulary: vocabulary.context, minScore: nil)
        guard let timings = result.tokenTimings, !timings.isEmpty, !spot.logProbs.isEmpty else {
            // No timings or no frames: no evidence is obtainable; the raw
            // transcript still flows downstream unmodified.
            return ParakeetDecodeOutput(transcript: result.text)
        }

        let evaluated = vocabulary.rescorer.ctcTokenEvaluateCandidates(
            transcript: result.text,
            tokenTimings: timings,
            logProbs: spot.logProbs,
            frameDuration: spot.frameDuration,
            cbw: vocabulary.sizeConfig.cbw,
            marginSeconds: ContextBiasingConstants.defaultMarginSeconds,
            minSimilarity: vocabulary.sizeConfig.minSimilarity)

        let evidence = evaluated.candidates.map { candidate in
            ParakeetSpotEvidence(
                basePhrase: candidate.basePhrase,
                term: candidate.canonicalTerm,
                alias: candidate.matchedAlias,
                similarity: Double(candidate.similarity),
                vocabularyCtcScore: candidate.rawVocabularyCTCScore.map(Double.init),
                originalCtcScore: candidate.rawOriginalCTCScore.map(Double.init),
                utf8Range: candidate.baseTextUTF8Range,
                comparisonPassed: candidate.comparisonPassed,
                applied: candidate.legacyOutcome == .applied,
                reason: candidate.reason)
        }
        // `baseText` is the untouched transcript the byte ranges index into —
        // use it verbatim so range slicing can never drift from the text.
        return ParakeetDecodeOutput(transcript: evaluated.baseText, evidence: evidence)
    }

    // MARK: - Loading

    private func loadedStack() async throws -> Stack {
        if let stack { return stack }

        // Gate 1: byte-identity of every manifest file, BEFORE any FluidAudio
        // call — this is what makes ModelHub's silent fallback unreachable.
        guard case .verified = store.state() else {
            log.error("parakeet models not verified at \(self.modelsDir.path, privacy: .public)")
            throw DecoderError.modelsNotVerified
        }
        // Gate 2: FluidAudio's own refusal, for code paths gate 1 cannot see.
        ModelHub.offlineMode = true

        let tdtDir = modelsDir.appendingPathComponent(ParakeetManifest.tdtDirectory, isDirectory: true)
        let ctcDir = modelsDir.appendingPathComponent(ParakeetManifest.ctcDirectory, isDirectory: true)

        let models = try await AsrModels.load(from: tdtDir, version: .v3, encoderPrecision: .int8)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)

        let ctcModels = try await CtcModels.loadDirect(from: ctcDir, variant: .ctc110m)
        let tokenizer = try await CtcTokenizer.load(from: ctcDir)
        let spotter = CtcKeywordSpotter(models: ctcModels, blankId: ctcModels.vocabulary.count)

        let loaded = Stack(manager: manager, spotter: spotter,
                           tokenizer: tokenizer, ctcDirectory: ctcDir)
        stack = loaded
        return loaded
    }

    private func vocabularyStack(for terms: [ParakeetTerm], stack: Stack) async throws -> VocabularyStack {
        if let vocabularyStack, vocabularyStack.terms == terms { return vocabularyStack }

        // `CustomVocabularyTerm(text:aliases:)` maps 1:1 to {term, hear:[]};
        // ctcTokenIds encoded here because loadWithCtcTokens would drag in the
        // hardcoded cache. Terms the tokenizer cannot encode are skipped, as
        // the vendor path does.
        let vocabularyTerms = terms.compactMap { term -> CustomVocabularyTerm? in
            let tokenIds = stack.tokenizer.encode(term.text)
            guard !tokenIds.isEmpty else { return nil }
            return CustomVocabularyTerm(
                text: term.text,
                aliases: term.aliases.isEmpty ? nil : term.aliases,
                ctcTokenIds: tokenIds)
        }
        let context = CustomVocabularyContext(terms: vocabularyTerms)
        let sizeConfig = ContextBiasingConstants.rescorerConfig(forVocabSize: vocabularyTerms.count)
        let rescorer = try await VocabularyRescorer.create(
            spotter: stack.spotter,
            vocabulary: context,
            config: VocabularyRescorer.Config(spotterRescueEnabled: false),
            ctcModelDirectory: stack.ctcDirectory)

        let built = VocabularyStack(terms: terms, context: context,
                                    rescorer: rescorer, sizeConfig: sizeConfig)
        vocabularyStack = built
        return built
    }

    // MARK: - PCM

    /// Canonical retained PCM (16 kHz mono Int16, little-endian) → the [-1, 1]
    /// floats FluidAudio wants. A trailing odd byte is dropped.
    static func floats(fromInt16 pcm: Data) -> [Float] {
        let count = pcm.count / 2
        guard count > 0 else { return [] }
        var samples = [Float](repeating: 0, count: count)
        pcm.withUnsafeBytes { raw in
            for i in 0..<count {
                // loadUnaligned: Data slices carry no alignment guarantee.
                let sample = raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self)
                samples[i] = Float(Int16(littleEndian: sample)) / 32768.0
            }
        }
        return samples
    }
}
