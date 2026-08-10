import XCTest
@testable import WispritParakeet

/// The channel's contract behind a faked decoder seam: spotting evidence in,
/// termHits + a transcript with ONLY spotter-confirmed dictionary terms
/// substituted out. The spike's one non-negotiable — never take the rescorer's
/// rewritten text — is pinned here as refusals: evidence that is not applied,
/// not comparison-passed, not byte-aligned, or not about a requested term
/// changes nothing.
final class ParakeetVocabularyChannelTests: XCTestCase {

    private final class FakeDecoder: ParakeetDecoding, @unchecked Sendable {
        let lock = NSLock()
        var output: ParakeetDecodeOutput
        var throwOnDecode = false
        var throwOnWarmup = false
        private(set) var warmups = 0
        private(set) var decodedTerms: [[ParakeetTerm]] = []
        struct Failure: Error {}

        init(_ output: ParakeetDecodeOutput) { self.output = output }

        func warmup() async throws {
            lock.lock(); warmups += 1; let fail = throwOnWarmup; lock.unlock()
            if fail { throw Failure() }
        }

        func decode(pcm: Data, terms: [ParakeetTerm]) async throws -> ParakeetDecodeOutput {
            lock.lock(); decodedTerms.append(terms); let out = output
            let fail = throwOnDecode; lock.unlock()
            if fail { throw Failure() }
            return out
        }
    }

    private let pcm = Data(repeating: 0x01, count: 640)

    private func evidence(_ phrase: String, term: String, in base: String,
                          similarity: Double = 0.9, alias: String? = nil,
                          comparisonPassed: Bool = true, applied: Bool = true,
                          range: Range<Int>? = nil) -> ParakeetSpotEvidence {
        let bytes = Array(base.utf8)
        let needle = Array(phrase.utf8)
        let found = range ?? (0...(bytes.count - needle.count)).first {
            Array(bytes[$0..<$0 + needle.count]) == needle
        }.map { $0..<($0 + needle.count) }
        return ParakeetSpotEvidence(basePhrase: phrase, term: term, alias: alias,
                                    similarity: similarity, utf8Range: found,
                                    comparisonPassed: comparisonPassed, applied: applied)
    }

    // MARK: - The happy path

    func testConfirmedTermIsSubstitutedAndCounted() async {
        let base = "Please add this to whisper it before the meeting."
        let decoder = FakeDecoder(ParakeetDecodeOutput(
            transcript: base,
            evidence: [evidence("whisper it", term: "Wisprit", in: base,
                                similarity: 1.0, alias: "whisper it")]))
        let channel = ParakeetVocabularyChannel(decoder: decoder) {
            [ParakeetTerm(text: "Wisprit", aliases: ["whisper it"])]
        }

        let result = await channel.reconcile(pcm: pcm, extraTerms: [])
        XCTAssertEqual(result?.transcript,
                       "Please add this to Wisprit before the meeting.")
        XCTAssertEqual(result?.termHits, ["Wisprit": 1])
        XCTAssertEqual(result?.termCount, 1)
        XCTAssertGreaterThanOrEqual(result?.elapsedMs ?? -1, 0)
    }

    func testMultipleNonOverlappingSubstitutions() async {
        let base = "Ask Shari Kudari about ins forge."
        let decoder = FakeDecoder(ParakeetDecodeOutput(
            transcript: base,
            evidence: [
                evidence("Shari Kudari", term: "Sharique", in: base, similarity: 0.8),
                evidence("ins forge", term: "InsForge", in: base, similarity: 0.9),
            ]))
        let channel = ParakeetVocabularyChannel(decoder: decoder) {
            [ParakeetTerm(text: "Sharique"), ParakeetTerm(text: "InsForge")]
        }
        let result = await channel.reconcile(pcm: pcm, extraTerms: [])
        XCTAssertEqual(result?.transcript, "Ask Sharique about InsForge.")
        XCTAssertEqual(result?.termHits, ["Sharique": 1, "InsForge": 1])
    }

    // MARK: - Refusals (the rescorer-text pin)

    func testUnappliedOrFailedComparisonEvidenceChangesNothing() async {
        let base = "What is the population of Denmark?"
        let decoder = FakeDecoder(ParakeetDecodeOutput(
            transcript: base,
            evidence: [
                // The classic over-fire the spike measured: rescue-pass junk.
                evidence("the population", term: "Wisprit", in: base, applied: false),
                evidence("Denmark", term: "Letta", in: base, comparisonPassed: false),
            ]))
        let channel = ParakeetVocabularyChannel(decoder: decoder) {
            [ParakeetTerm(text: "Wisprit"), ParakeetTerm(text: "Letta")]
        }
        let result = await channel.reconcile(pcm: pcm, extraTerms: [])
        XCTAssertEqual(result?.transcript, base, "unconfirmed evidence must not edit")
        XCTAssertEqual(result?.termHits, [:])
    }

    func testEvidenceAboutATermNobodyAskedForIsDiscarded() async {
        // A decoder gone rogue (or a stale cached vocabulary) proposing a term
        // outside the dictionary must be ignored even when marked applied —
        // this is the structural "Wisprit keeps the pen" guarantee.
        let base = "Meet me at the cafe."
        let decoder = FakeDecoder(ParakeetDecodeOutput(
            transcript: base,
            evidence: [evidence("the cafe", term: "Kubernetes", in: base, similarity: 1.0)]))
        let channel = ParakeetVocabularyChannel(decoder: decoder) {
            [ParakeetTerm(text: "Wisprit")]
        }
        let result = await channel.reconcile(pcm: pcm, extraTerms: [])
        XCTAssertEqual(result?.transcript, base)
    }

    func testMisalignedByteRangeIsRefusedNotRepaired() async {
        let base = "Deploy it to production now."
        var bad = evidence("production", term: "Wisprit", in: base)
        bad.utf8Range = 0..<10  // points at "Deploy it ", not at basePhrase
        let decoder = FakeDecoder(ParakeetDecodeOutput(transcript: base, evidence: [bad]))
        let channel = ParakeetVocabularyChannel(decoder: decoder) {
            [ParakeetTerm(text: "Wisprit")]
        }
        let result = await channel.reconcile(pcm: pcm, extraTerms: [])
        XCTAssertEqual(result?.transcript, base)
    }

    func testEvidenceWithoutARangeCountsForNothing() async {
        let base = "Ship whisper it today."
        var rangeless = evidence("whisper it", term: "Wisprit", in: base)
        rangeless.utf8Range = nil
        let decoder = FakeDecoder(ParakeetDecodeOutput(transcript: base, evidence: [rangeless]))
        let channel = ParakeetVocabularyChannel(decoder: decoder) {
            [ParakeetTerm(text: "Wisprit")]
        }
        let result = await channel.reconcile(pcm: pcm, extraTerms: [])
        XCTAssertEqual(result?.transcript, base)
        XCTAssertEqual(result?.termHits, [:])
    }

    func testOverlappingCandidatesResolveToHigherSimilarity() async {
        let base = "We use whisper it daily."
        let decoder = FakeDecoder(ParakeetDecodeOutput(
            transcript: base,
            evidence: [
                evidence("whisper", term: "Wisp", in: base, similarity: 0.6),
                evidence("whisper it", term: "Wisprit", in: base, similarity: 0.95),
            ]))
        let channel = ParakeetVocabularyChannel(decoder: decoder) {
            [ParakeetTerm(text: "Wisp"), ParakeetTerm(text: "Wisprit")]
        }
        let result = await channel.reconcile(pcm: pcm, extraTerms: [])
        XCTAssertEqual(result?.transcript, "We use Wisprit daily.")
    }

    func testMultiByteTextAroundTheRangeSurvivesSplicing() async {
        let base = "The café’s docs — read “whisper it” fully."
        let decoder = FakeDecoder(ParakeetDecodeOutput(
            transcript: base,
            evidence: [evidence("whisper it", term: "Wisprit", in: base)]))
        let channel = ParakeetVocabularyChannel(decoder: decoder) {
            [ParakeetTerm(text: "Wisprit")]
        }
        let result = await channel.reconcile(pcm: pcm, extraTerms: [])
        XCTAssertEqual(result?.transcript, "The café’s docs — read “Wisprit” fully.")
        XCTAssertEqual(result?.termHits, ["Wisprit": 1])
    }

    // MARK: - Lifecycle and failure

    func testEmptyPcmAndDecoderFailureReturnNil() async {
        let decoder = FakeDecoder(ParakeetDecodeOutput(transcript: "hi"))
        let channel = ParakeetVocabularyChannel(decoder: decoder) {
            [ParakeetTerm(text: "Wisprit")]
        }
        let empty = await channel.reconcile(pcm: Data(), extraTerms: [])
        XCTAssertNil(empty)

        decoder.throwOnDecode = true
        let failed = await channel.reconcile(pcm: pcm, extraTerms: [])
        XCTAssertNil(failed)
    }

    func testWarmupIsLoadOnceButRetriesAfterFailure() async {
        let decoder = FakeDecoder(ParakeetDecodeOutput(transcript: ""))
        decoder.throwOnWarmup = true
        let channel = ParakeetVocabularyChannel(decoder: decoder) { [] }
        await channel.warmup()
        XCTAssertEqual(decoder.warmups, 1)
        // Models arrive (the user downloaded them); the next warmup may retry.
        decoder.throwOnWarmup = false
        await channel.warmup()
        XCTAssertEqual(decoder.warmups, 2)
        // Warm is warm: the 15.8 s compile must never be paid twice.
        await channel.warmup()
        XCTAssertEqual(decoder.warmups, 2)
    }

    // MARK: - Term assembly

    func testExtraTermsMergeAfterDictionaryAndDictionarySpellingWins() async {
        let base = "The insforge rollout is on wisprit."
        let decoder = FakeDecoder(ParakeetDecodeOutput(transcript: base))
        let channel = ParakeetVocabularyChannel(decoder: decoder) {
            [ParakeetTerm(text: "Wisprit", aliases: ["whisper it"])]
        }
        let result = await channel.reconcile(
            pcm: pcm, extraTerms: ["WISPRIT", "InsForge", ""])
        // The decoder saw dictionary first, extras deduped case-insensitively.
        XCTAssertEqual(decoder.decodedTerms.last?.map(\.text), ["Wisprit", "InsForge"])
        XCTAssertEqual(result?.termCount, 2)
        // Hits are counted for extras too — that is what lets the Phase-3
        // planner act on a context term with zero new machinery.
        XCTAssertEqual(result?.termHits, ["Wisprit": 1, "InsForge": 1])
    }

    func testNoTermsMeansNoPass() async {
        let decoder = FakeDecoder(ParakeetDecodeOutput(transcript: "hello"))
        let channel = ParakeetVocabularyChannel(decoder: decoder) { [] }
        let result = await channel.reconcile(pcm: pcm, extraTerms: [])
        XCTAssertNil(result)
        XCTAssertTrue(decoder.decodedTerms.isEmpty)
    }

    // MARK: - termHits parity with the DictationTranscriber channel

    func testTermHitsWholeWordCaseInsensitiveWhitespaceRelaxed() {
        let hits = ParakeetVocabularyChannel.termHits(
            in: "wisprit ships Wisprit; mail  ex swift is not mailexswift",
            terms: ["Wisprit", "mail ex swift", "Absent"])
        XCTAssertEqual(hits, ["Wisprit": 2, "mail ex swift": 1])
    }
}
