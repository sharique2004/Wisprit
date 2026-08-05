import XCTest
import WispritKit
@testable import WispritRefine

/// The cage, exercised end-to-end against a fake generator — every guard and
/// every outcome, with no Apple Intelligence involved. Mirrors the hermetic
/// half of `tests/test_refine.py` (the live model is exercised by
/// `RehearsalTests` instead).
final class RefinerCageTests: XCTestCase {

    // MARK: - fake model

    actor FakeGenerator: RefineGenerating {
        struct UnexpectedError: Error {}

        enum Behavior {
            case reply(String)
            case fail(RefineError)
            case throwUnexpected
            case hang
        }

        var behavior: Behavior
        var availability: RefineAvailability
        var delay: Duration = .zero

        private(set) var prewarmCount = 0
        private(set) var discardCount = 0
        private(set) var generateCount = 0
        private(set) var lastTranscript: String?

        init(behavior: Behavior = .reply(""),
             availability: RefineAvailability = RefineAvailability(available: true)) {
            self.behavior = behavior
            self.availability = availability
        }

        func setBehavior(_ new: Behavior) { behavior = new }
        func setDelay(_ new: Duration) { delay = new }

        func probe() async -> RefineAvailability { availability }
        func prewarm() async { prewarmCount += 1 }
        func discard() async { discardCount += 1 }

        func generate(_ transcript: String) async throws -> String {
            generateCount += 1
            lastTranscript = transcript
            if delay != .zero { try await Task.sleep(for: delay) }
            switch behavior {
            case .reply(let text): return text
            case .fail(let error): throw error
            case .throwUnexpected: throw UnexpectedError()
            case .hang:
                try await Task.sleep(for: .seconds(60))
                return ""
            }
        }
    }

    private func makeRefiner(_ generator: FakeGenerator,
                             enabled: Bool = true,
                             maxWords: Int = 350,
                             timeoutMs: Int = 12000,
                             vocabulary: (any VocabularySource)? = nil) -> Refiner {
        // startProbe: false keeps availability at nil (unknown ⇒ try anyway),
        // which is the state the guard tests care about.
        Refiner(generator: generator,
                configuration: { RefineConfiguration(enabled: enabled, maxWords: maxWords,
                                                     timeoutMs: timeoutMs) },
                vocabulary: vocabulary,
                startProbe: false)
    }

    // MARK: - skips (verbatim in, verbatim out)

    func testEmptyReturnsVerbatim() async {
        let generator = FakeGenerator()
        let refiner = makeRefiner(generator)
        let result = await refiner.refine("")
        XCTAssertEqual(result, RefineResult(text: "", outcome: .empty))
        let whitespace = await refiner.refine("   \n ")
        XCTAssertEqual(whitespace.outcome, .empty)
        let generated = await generator.generateCount
        XCTAssertEqual(generated, 0)
    }

    func testDisabledReturnsVerbatim() async {
        let generator = FakeGenerator()
        let refiner = makeRefiner(generator, enabled: false)
        let result = await refiner.refine("um hello there")
        XCTAssertEqual(result, RefineResult(text: "um hello there", outcome: .off))
        let generated = await generator.generateCount
        XCTAssertEqual(generated, 0)
    }

    func testAddressReturnsVerbatim() async {
        let generator = FakeGenerator(behavior: .reply("Rewritten."))
        let refiner = makeRefiner(generator)
        let text = "email bob at bob dot jones at gmail dot com"
        let result = await refiner.refine(text)
        XCTAssertEqual(result, RefineResult(text: text, outcome: .hasAddress))
    }

    func testLetterRunReturnsVerbatim() async {
        let generator = FakeGenerator(behavior: .reply("Actually, it's Sharifue."))
        let refiner = makeRefiner(generator)
        let text = "actually it's S-H-A-R-I-Q-U-E"
        let result = await refiner.refine(text)
        XCTAssertEqual(result, RefineResult(text: text, outcome: .hasLetterRun))
        let generated = await generator.generateCount
        XCTAssertEqual(generated, 0)
    }

    func testTooLongReturnsVerbatim() async {
        let generator = FakeGenerator(behavior: .reply("short"))
        let refiner = makeRefiner(generator)
        let text = String(repeating: "word ", count: 400)
        let result = await refiner.refine(text)
        XCTAssertEqual(result, RefineResult(text: text, outcome: .tooLong))
    }

    /// CJK-style transcripts have no spaces; the cap must still engage via the
    /// character-based estimate rather than treating 3000 chars as one word.
    func testSpaceFreeLongInputHitsWordCap() async {
        let generator = FakeGenerator(behavior: .reply("short"))
        let refiner = makeRefiner(generator)
        let text = String(repeating: "字", count: 3000)
        let result = await refiner.refine(text)
        XCTAssertEqual(result, RefineResult(text: text, outcome: .tooLong))
    }

    /// Every skip drops the prewarmed session, exactly like the Python killed
    /// the prewarmed helper — otherwise the next utterance would inherit it.
    func testSkipsDiscardThePrewarmedSession() async {
        let generator = FakeGenerator()
        let refiner = makeRefiner(generator)
        await refiner.begin()
        _ = await refiner.refine("see https://foo.bar/baz")
        let discards = await generator.discardCount
        XCTAssertEqual(discards, 1)
    }

    // MARK: - the happy path

    func testAppliedStripsWrappers() async {
        let generator = FakeGenerator(
            behavior: .reply("Here's the cleaned transcript:\n```\n"
                             + "So basically we should probably migrate the database.\n```"))
        let refiner = makeRefiner(generator)
        let result = await refiner.refine(
            "um so basically we should uh probably migrate the the data base")
        XCTAssertEqual(result, RefineResult(
            text: "So basically we should probably migrate the database.", outcome: .applied))
    }

    func testGeneratorSeesTheRawTranscript() async {
        let generator = FakeGenerator(behavior: .reply("Hello there."))
        let refiner = makeRefiner(generator)
        _ = await refiner.refine("um hello there")
        let seen = await generator.lastTranscript
        XCTAssertEqual(seen, "um hello there")
    }

    // MARK: - implausible output

    func testAnsweredInsteadOfCleanedIsRejected() async {
        let generator = FakeGenerator(behavior: .reply(
            "Why did the cat sit on the computer? Because it wanted to keep an eye on "
            + "the mouse! Here is another one for you my friend."))
        let refiner = makeRefiner(generator)
        let raw = "tell me a joke about uh cats"
        let result = await refiner.refine(raw)
        XCTAssertEqual(result, RefineResult(text: raw, outcome: .implausible))
    }

    func testAssistantOpenerIsRejected() async {
        let generator = FakeGenerator(
            behavior: .reply("Sure, the population of Sweden is about ten million."))
        let refiner = makeRefiner(generator)
        let raw = "whats the population of um sweden"
        let result = await refiner.refine(raw)
        XCTAssertEqual(result.outcome, .implausible)
    }

    func testSummaryIsRejected() async {
        let generator = FakeGenerator(
            behavior: .reply(Array(repeating: "word", count: 30).joined(separator: " ")))
        let refiner = makeRefiner(generator)
        let raw = Array(repeating: "word", count: 100).joined(separator: " ")
        let result = await refiner.refine(raw)
        XCTAssertEqual(result, RefineResult(text: raw, outcome: .implausible))
    }

    func testEmptyModelOutputIsRejected() async {
        let generator = FakeGenerator(behavior: .reply("   "))
        let refiner = makeRefiner(generator)
        let result = await refiner.refine("um hello there")
        XCTAssertEqual(result.outcome, .implausible)
    }

    // MARK: - interrupts and timeout

    func testTimeoutAbandonsTheModel() async {
        let generator = FakeGenerator(behavior: .hang)
        let refiner = makeRefiner(generator, timeoutMs: 120)
        let raw = "um hello there"
        let started = ContinuousClock.now
        let result = await refiner.refine(raw)
        XCTAssertEqual(result, RefineResult(text: raw, outcome: .timeout))
        XCTAssertLessThan(started.duration(to: .now), .seconds(5))
        let discards = await generator.discardCount
        XCTAssertGreaterThanOrEqual(discards, 1)
    }

    /// A queued next press: finish NOW with verbatim text so the next dictation
    /// isn't stuck behind the model.
    func testHurryPreempts() async {
        let generator = FakeGenerator(behavior: .hang)
        let refiner = makeRefiner(generator)
        let raw = "um hello there"
        let started = ContinuousClock.now
        let result = await refiner.refine(raw, interrupt: { .hurry })
        XCTAssertEqual(result, RefineResult(text: raw, outcome: .preempted))
        XCTAssertLessThan(started.duration(to: .now), .seconds(2))
    }

    func testEscCancels() async {
        let generator = FakeGenerator(behavior: .hang)
        let refiner = makeRefiner(generator)
        let raw = "um hello there"
        let result = await refiner.refine(raw, interrupt: { .cancel })
        XCTAssertEqual(result, RefineResult(text: raw, outcome: .cancelled))
    }

    /// `.none` must not disturb a healthy run.
    func testNoneKeepsWaiting() async {
        let generator = FakeGenerator(behavior: .reply("Hello there."))
        await generator.setDelay(.milliseconds(200))
        let refiner = makeRefiner(generator)
        let result = await refiner.refine("um hello there", interrupt: { .none })
        XCTAssertEqual(result, RefineResult(text: "Hello there.", outcome: .applied))
    }

    // MARK: - failures

    func testSetupFailureIsSpawnFailed() async {
        let generator = FakeGenerator(behavior: .fail(.setupFailed("no session")))
        let refiner = makeRefiner(generator)
        let result = await refiner.refine("um hello there")
        XCTAssertEqual(result, RefineResult(text: "um hello there", outcome: .spawnFailed))
    }

    func testMalformedReplyIsBadReply() async {
        let generator = FakeGenerator(behavior: .fail(.malformedReply))
        let refiner = makeRefiner(generator)
        let result = await refiner.refine("um hello there")
        XCTAssertEqual(result.outcome, .badReply)
    }

    func testGenerationFailureIsHelperError() async {
        let generator = FakeGenerator(behavior: .fail(.generationFailed("guardrailViolation")))
        let refiner = makeRefiner(generator)
        let result = await refiner.refine("um hello there")
        XCTAssertEqual(result, RefineResult(text: "um hello there", outcome: .helperError))
    }

    func testEmptyResponseIsHelperError() async {
        let generator = FakeGenerator(behavior: .fail(.emptyResponse))
        let refiner = makeRefiner(generator)
        let result = await refiner.refine("um hello there")
        XCTAssertEqual(result.outcome, .helperError)
    }

    /// Python wrapped `_refine_inner` in a blanket `except` that logged and
    /// returned "error" with the verbatim text. Refinement can only ever win.
    func testUnexpectedThrowIsError() async {
        let generator = FakeGenerator(behavior: .throwUnexpected)
        let refiner = makeRefiner(generator)
        let result = await refiner.refine("um hello there")
        XCTAssertEqual(result, RefineResult(text: "um hello there", outcome: .error))
    }

    /// Apple Intelligence disabled / assets evicted mid-session: stop trying
    /// until a probe or relaunch recovers.
    func testUnavailableMidSessionFlipsAvailabilityOff() async {
        let generator = FakeGenerator(behavior: .fail(.unavailable("unavailable: modelNotReady")))
        let refiner = makeRefiner(generator)
        let first = await refiner.refine("um hello there")
        XCTAssertEqual(first.outcome, .helperError)
        let availability = await refiner.availability
        XCTAssertEqual(availability, false)
        let enabled = await refiner.enabled()
        XCTAssertFalse(enabled)
        // …and the next utterance skips the model entirely.
        let second = await refiner.refine("um hello there")
        XCTAssertEqual(second.outcome, .off)
    }

    // MARK: - lifecycle and availability

    func testBeginPrewarmsOnlyWhenEnabled() async {
        let generator = FakeGenerator()
        let on = makeRefiner(generator)
        await on.begin()
        var prewarms = await generator.prewarmCount
        XCTAssertEqual(prewarms, 1)

        let off = makeRefiner(generator, enabled: false)
        await off.begin()
        prewarms = await generator.prewarmCount
        XCTAssertEqual(prewarms, 1)
    }

    func testAvailabilityIsTriState() async {
        let generator = FakeGenerator(
            availability: RefineAvailability(available: false, reason: "appleIntelligenceNotEnabled"))
        let refiner = makeRefiner(generator)
        // nil = still probing; refinement is attempted anyway.
        var availability = await refiner.availability
        XCTAssertNil(availability)
        var enabled = await refiner.enabled()
        XCTAssertTrue(enabled)

        await refiner.probeNow()
        availability = await refiner.availability
        XCTAssertEqual(availability, false)
        let reason = await refiner.unavailableReason
        XCTAssertEqual(reason, "appleIntelligenceNotEnabled")
        enabled = await refiner.enabled()
        XCTAssertFalse(enabled)

        await generator.setAvailability(RefineAvailability(available: true))
        await refiner.probeNow()
        availability = await refiner.availability
        XCTAssertEqual(availability, true)
    }

    // MARK: - the metrics vocabulary

    /// `metrics.log`'s `ai` field must stay one comparable stream across the
    /// Python→Swift cutover: these thirteen strings are `wisprit/refine.py`'s.
    func testOutcomeVocabularyMatchesPython() {
        let python = ["applied", "off", "empty", "too_long", "has_address", "timeout",
                      "cancelled", "preempted", "spawn_failed", "bad_reply", "helper_error",
                      "implausible", "error"]
        let ported = RefineOutcome.allCases.filter(\.isPythonVocabulary).map(\.rawValue)
        XCTAssertEqual(Set(ported), Set(python))
        XCTAssertEqual(ported.count, 13)
        XCTAssertEqual(RefineOutcome.hasLetterRun.rawValue, "has_letter_run")
    }
}

extension RefinerCageTests.FakeGenerator {
    func setAvailability(_ new: RefineAvailability) { availability = new }
}
