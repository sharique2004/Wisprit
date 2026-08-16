import XCTest
import WispritCorrections
import WispritDictionary
import WispritEngine
import WispritKit
import WispritPostProcess
@testable import WispritMac

/// The identity gate on the REAL session path — the whole chain from an ASR
/// result to what the inserter typed, with the real `PostProcess`, the real
/// `IdentityExpansion`, and a real `IdentityStore` on a temp directory.
///
/// The unit tables in `IdentityExpansionTests` prove the gate's grammar. This
/// file proves the four NON-INTERACTIONS the placement decision rests on, each
/// measured rather than assumed:
///   1. `ensureSentencePeriod` cannot glue a period onto an emitted address.
///   2. `SmartFormat.applyContextFit`'s `lowercaseOpening` cannot re-case one.
///   3. the spoken-email/URL joiner and the gate cannot fight.
///   4. a user-authored snippet wins a trigger collision.
final class SessionIdentityTests: XCTestCase {
    private var root: URL!
    private var store: IdentityStore!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wisprit-session-identity-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        WispritPaths.overrideRoot = root
        store = IdentityStore(path: root.appendingPathComponent("identity.json"))
    }

    override func tearDownWithError() throws {
        WispritPaths.overrideRoot = nil
        try? FileManager.default.removeItem(at: root)
    }

    /// The wiring AppController uses, built over the real store.
    private func identityStage(enabled: Bool = true) -> @Sendable (String) -> String {
        let store = self.store!
        return { text in
            guard enabled else { return text }
            return IdentityExpansion.expand(text, store.values())
        }
    }

    private func dictate(_ text: String,
                         options: @escaping @Sendable () -> PostProcessOptions
                             = { PostProcessOptions() },
                         snippets: @escaping @Sendable (String) -> String = { $0 },
                         enabled: Bool = true) -> [String] {
        let h = SessionControllerTests.Harness(useRefiner: false,
                                               postProcessOptions: options,
                                               expandSnippets: snippets,
                                               expandIdentity: identityStage(enabled: enabled))
        h.asr.result = UtteranceResult(text: text, engine: "apple_live", finalizeMs: 40)
        h.utterance()
        return h.inserter.inserted
    }

    // MARK: - the three the user asked for

    func testSoloTriggerTypesTheAddress() {
        store.set(.email, to: "me@example.com")
        XCTAssertEqual(dictate("my email"), ["me@example.com"])
    }

    func testMidSentenceHandoverTypesTheAddress() {
        store.set(.email, to: "me@example.com")
        XCTAssertEqual(dictate("send it to my email"), ["send it to me@example.com"])
    }

    func testReferringSentenceIsByteIdentical() {
        store.set(.email, to: "me@example.com")
        let input = "I need to check my email"
        XCTAssertEqual(dictate(input), [input])
    }

    func testUnsetSlotSurvivesAsTheWordsTheUserSaid() {
        store.set(.email, to: "me@example.com")   // linkedin and website ship UNSET
        XCTAssertEqual(dictate("my LinkedIn"), ["my LinkedIn"])
        XCTAssertEqual(dictate("here's my website"), ["here's my website"])
    }

    func testKillSwitchOffLeavesTheUtteranceAlone() {
        store.set(.email, to: "me@example.com")
        XCTAssertEqual(dictate("my email", enabled: false), ["my email"])
    }

    /// `SmartFormat.consumePressEnter` strips the command INSIDE
    /// `processResult`, so by the time the gate runs the residue is a bare
    /// trigger and R1 owns it. Running the gate at a single point after the
    /// whole pipeline is what makes this work with no special case: a
    /// design that decided rule 1 BEFORE PostProcess would see
    /// "my email press enter", decline, and type the literal words.
    func testPressEnterLeavesABareTriggerTheGateStillOwns() {
        store.set(.email, to: "me@example.com")
        let h = SessionControllerTests.Harness(
            useRefiner: false,
            postProcessOptions: {
                PostProcessOptions(pressEnterEnabled: true, smartFormatting: true)
            },
            expandIdentity: identityStage())
        h.asr.result = UtteranceResult(text: "my email press enter",
                                       engine: "apple_live", finalizeMs: 40)
        h.utterance()
        XCTAssertEqual(h.inserter.inserted, ["me@example.com"])
        XCTAssertEqual(h.inserter.returnCount, 1)
    }

    // MARK: - the four non-interactions

    /// `ensureSentencePeriod` appends "." to "my email" BEFORE the gate sees
    /// it. R1 tolerates and drops that period, so the address is never emitted
    /// with a dot glued to it — the paste bug this ordering exists to prevent.
    func testSentencePeriodCannotStickToASoloValue() {
        store.set(.email, to: "me@example.com")
        let inserted = dictate("my email",
                               options: { PostProcessOptions(ensureSentencePeriod: true) })
        XCTAssertEqual(inserted, ["me@example.com"])
    }

    /// Mid-sentence the period is OUTSIDE the replaced span and stays: rule 2
    /// is prose, and a sentence that ends in a value is still a sentence. The
    /// asymmetry with the solo case is a decision, not an accident.
    func testSentencePeriodSurvivesOutsideAMidSentenceValue() {
        store.set(.email, to: "me@example.com")
        let inserted = dictate("reach me at my email",
                               options: { PostProcessOptions(ensureSentencePeriod: true) })
        XCTAssertEqual(inserted, ["reach me at me@example.com."])
    }

    /// `applyContextFit` runs inside `processResult` and lowercases the opening
    /// word when the cursor is mid-sentence. The value is spliced in AFTER it,
    /// so a capitalized local part survives — RFC 5321 says it must.
    func testSmartFormatCasingNeverReachesTheValue() {
        store.set(.email, to: "Me@Example.com")
        let context = FakeContext()
        context.outcome = ContextOutcome(status: .read, precedingText: "Reach me at")
        let h = SessionControllerTests.Harness(
            useRefiner: false,
            context: context,
            postProcessOptions: { PostProcessOptions(smartFormatting: true) },
            expandIdentity: identityStage())
        h.asr.result = UtteranceResult(text: "my email", engine: "apple_live", finalizeMs: 40)
        h.utterance()
        // The leading space is applyContextFit's, taken on the trigger words
        // and preserved by R1's leading-whitespace capture.
        XCTAssertEqual(h.inserter.inserted, [" Me@Example.com"])
    }

    /// The spoken-address joiner and the gate have disjoint inputs: `joinEmail`
    /// needs the literal spoken " dot " / " at " tokens, and the gate needs the
    /// possessive shorthand. Running both leaves exactly one address, and it is
    /// the one the user spelled out — the identity value is not substituted in.
    func testSpokenAddressJoinerAndTheGateDoNotFight() {
        store.set(.email, to: "me@example.com")
        let inserted = dictate("my email is sharique dot khatri at gmail dot com")
        XCTAssertEqual(inserted, ["my email is sharique.khatri@gmail.com"])
        XCTAssertEqual(inserted.first?.filter { $0 == "@" }.count, 1, "exactly one address")
        XCTAssertFalse(inserted.first?.contains("me@example.com") ?? true)
    }

    /// A user-authored snippet is an EXPLICIT unconditional rule and outranks
    /// the conditional identity gate. It wins with zero precedence code: it
    /// runs first and consumes the phrase, so the gate finds nothing.
    func testSnippetWinsATriggerCollision() {
        store.set(.email, to: "me@example.com")
        let inserted = dictate("my email",
                               snippets: { $0 == "my email" ? "work@corp.com" : $0 })
        XCTAssertEqual(inserted, ["work@corp.com"])
    }

    // MARK: - what the gate hands downstream

    /// The off-path vocabulary planner is the only thing in this system that
    /// edits the user's document AFTER delivery. Handed an expanded insertion
    /// it must refuse — asserted, not inferred.
    func testVocabularyRetroPlannerRefusesAnExpandedInsertion() {
        let solo = VocabularyReconciler.plan(inserted: "me@example.com",
                                             reconciled: "my email",
                                             termHits: [:],
                                             knownTerm: { _ in false })
        XCTAssertTrue(solo.edits.isEmpty)
        XCTAssertNotNil(solo.refusal)

        let inline = VocabularyReconciler.plan(inserted: "here's me@example.com",
                                               reconciled: "here's my email",
                                               termHits: [:],
                                               knownTerm: { _ in false })
        XCTAssertTrue(inline.edits.isEmpty)
        XCTAssertNotNil(inline.refusal)
    }

    /// History stores what was INSERTED, which after this feature means the
    /// address rather than the words "my email". Consistent with snippets, and
    /// a written decision rather than a side effect — the settings copy says so.
    func testHistoryRecordsTheExpandedValue() {
        store.set(.email, to: "me@example.com")
        let h = SessionControllerTests.Harness(useRefiner: false,
                                               expandIdentity: identityStage())
        h.asr.result = UtteranceResult(text: "my email", engine: "apple_live", finalizeMs: 40)
        h.utterance()
        XCTAssertEqual(h.history.added.map(\.text), ["me@example.com"])
    }
}
