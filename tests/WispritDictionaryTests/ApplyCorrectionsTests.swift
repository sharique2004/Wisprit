import XCTest
import WispritKit
@testable import WispritDictionary

/// The apply engine, pinned against the three text-corruption defects measured
/// on the real dictionary. Everything here is about `applyCorrections` as a
/// rewriter — what it may touch and, mostly, what it must not.
///
/// The fixture is deliberately the shape that produced the live damage: a term
/// whose canonical form CONTAINS one of its own `hear` phrases ("Aman UAE" hears
/// "aman"), and two terms whose `hear` phrases are ordinary English words that
/// show up on the left of a hyphenated compound ("well x" in "x-ray", "for
/// hands" in "hands-free").
final class ApplyCorrectionsTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = try makeTempRoot()
        WispritPaths.overrideRoot = root
    }

    override func tearDownWithError() throws {
        WispritPaths.overrideRoot = nil
        try? FileManager.default.removeItem(at: root)
    }

    private func store(_ json: String) throws -> DictionaryStore {
        try json.write(to: WispritPaths.dictionaryPath, atomically: true, encoding: .utf8)
        return DictionaryStore()
    }

    private func fixture() throws -> DictionaryStore {
        try store("""
        {"terms": [
          {"term": "Aman UAE", "hear": ["aman", "amman", "aman uae"]},
          {"term": "WellX", "hear": ["well x", "wellex"]},
          {"term": "FourHands", "hear": ["for hands", "four hands"]}
        ]}
        """)
    }

    // MARK: - Cascade

    /// DEFECT 1, measured verbatim. The old engine re-ran every pattern over the
    /// OUTPUT of the previous one: "amman" wrote "Aman UAE", then the shorter
    /// "aman" rule matched the "Aman" that had just been written — `\b` sits at
    /// the space — and expanded it again, giving "Aman UAE UAE".
    func testAShorterHearPhraseCannotReEnterALongerRulesReplacement() throws {
        XCTAssertEqual(try fixture().applyCorrections(to: "We flew to Amman last night."),
                       "We flew to Aman UAE last night.")
    }

    /// The same guarantee from the other direction: a span written by one rule
    /// is invisible to every other rule in the pass, however many of them there
    /// are and whatever order they run in.
    func testEveryOccurrenceIsCorrectedExactlyOnce() throws {
        let store = try fixture()
        XCTAssertEqual(store.applyCorrections(to: "amman and amman and aman"),
                       "Aman UAE and Aman UAE and Aman UAE")
        XCTAssertEqual(store.applyCorrections(to: "wellex, for    hands. amman!"),
                       "WellX, FourHands. Aman UAE!")
    }

    // MARK: - Idempotence

    /// DEFECT 2, and the one that actually compounds: dictation text runs
    /// through here on every utterance and users re-dictate text they have
    /// already had corrected. "Aman UAE signed the contract." became "Aman UAE
    /// UAE signed the contract." — canonical input, corrupted output.
    func testTextThatIsAlreadyCanonicalIsLeftAlone() throws {
        let store = try fixture()
        XCTAssertEqual(store.applyCorrections(to: "Aman UAE signed the contract."),
                       "Aman UAE signed the contract.")
        XCTAssertEqual(store.applyCorrections(to: "WellX and FourHands and Aman UAE"),
                       "WellX and FourHands and Aman UAE")
    }

    /// Suppressing the no-op must not suppress the CASE fix — "aman uae" is a
    /// `hear` phrase that differs from the term only in casing, and correcting
    /// it is the whole point of the self-pattern.
    func testCanonicalUpToCasingIsStillRecased() throws {
        XCTAssertEqual(try fixture().applyCorrections(to: "we visited aman uae twice"),
                       "we visited Aman UAE twice")
    }

    /// The property, stated exactly: a second pass is a no-op on the first
    /// pass's output. Every input below is a shape that broke the old engine.
    func testApplyingCorrectionsTwiceEqualsApplyingThemOnce() throws {
        let store = try fixture()
        let inputs = [
            "We flew to Amman last night.",
            "Aman UAE signed the contract.",
            "The well x-ray results are in.",
            "It ships flat for hands-free use.",
            "the well x launch went fine",
            "wellex and for hands and amman",
            "aman uae, aman uae. aman uae!",
            "(amman)",
            "",
            "   ",
        ]
        for input in inputs {
            let once = store.applyCorrections(to: input)
            XCTAssertEqual(store.applyCorrections(to: once), once,
                           "not idempotent for \(input.debugDescription)")
        }
    }

    // MARK: - Hyphen safety

    /// DEFECT 3. A hyphen is a non-word character, so `\b` reports a boundary in
    /// the middle of every hyphenated compound and the phrase eats the half in
    /// front of it: "The well x-ray results are in." → "The WellX-ray results are
    /// in.", "It ships flat for hands-free use." → "It ships flat FourHands-free
    /// use.". Both are ordinary English the dictionary had no business touching.
    func testAMatchMayNotEndAgainstAHyphen() throws {
        let store = try fixture()
        XCTAssertEqual(store.applyCorrections(to: "The well x-ray results are in."),
                       "The well x-ray results are in.")
        XCTAssertEqual(store.applyCorrections(to: "It ships flat for hands-free use."),
                       "It ships flat for hands-free use.")
    }

    /// The left edge is guarded the same way, so the tail of a compound is safe
    /// too.
    func testAMatchMayNotBeginAgainstAHyphen() throws {
        XCTAssertEqual(try fixture().applyCorrections(to: "a pre-well x scan"),
                       "a pre-well x scan")
    }

    /// The other side of the hyphen rule: guarding the compound must not cost us
    /// the standalone phrase, which is the case the entry was written for.
    func testAStandaloneHearPhraseStillCorrects() throws {
        let store = try fixture()
        XCTAssertEqual(store.applyCorrections(to: "the well x launch went fine"),
                       "the WellX launch went fine")
        XCTAssertEqual(store.applyCorrections(to: "well x"), "WellX")
    }

    /// Word-internal matching is unchanged — the guard is about hyphens, not
    /// about loosening `\b` — and punctuation still bounds a match.
    func testWordInternalAndPunctuationBoundariesAreUnchanged() throws {
        let store = try fixture()
        XCTAssertEqual(store.applyCorrections(to: "amandine wellexington"),
                       "amandine wellexington")
        XCTAssertEqual(store.applyCorrections(to: "(amman), amman."),
                       "(Aman UAE), Aman UAE.")
    }

    // MARK: - Longest match wins

    /// Two `hear` phrases can start at the same position; the longer one owns it.
    /// Without that, "pull" would claim the "pull" of "pull request" and the
    /// longer rule would never get to run.
    func testOverlappingHearPhrasesResolveLongestFirst() throws {
        let store = try store("""
        {"terms": [
          {"term": "Pulley", "hear": ["pull"]},
          {"term": "PullRequest", "hear": ["pull request"]}
        ]}
        """)
        XCTAssertEqual(store.applyCorrections(to: "open a pull request please"),
                       "open a PullRequest please")
        // File order must not decide it: the short entry is listed first above,
        // and the short phrase alone still corrects.
        XCTAssertEqual(store.applyCorrections(to: "the pull is stuck"),
                       "the Pulley is stuck")
    }

    /// Whitespace flexibility survives the rewrite: a multi-word phrase matches
    /// however the recogniser spaced it, and the longest phrase still wins.
    func testLongestMatchWinsAcrossRelaxedWhitespace() throws {
        let store = try store("""
        {"terms": [
          {"term": "Pulley", "hear": ["pull"]},
          {"term": "PullRequest", "hear": ["pull request"]}
        ]}
        """)
        XCTAssertEqual(store.applyCorrections(to: "open a pull\trequest please"),
                       "open a PullRequest please")
    }

    // MARK: - Preserved behaviour

    func testMatchingStaysCaseInsensitiveAndTheTermKeepsItsCasing() throws {
        let store = try fixture()
        XCTAssertEqual(store.applyCorrections(to: "AMMAN and WellEx and For Hands"),
                       "Aman UAE and WellX and FourHands")
    }

    /// Non-ASCII replacements are spliced on UTF-16 match offsets, so a term
    /// with combining-width characters must come back intact.
    func testNonASCIIReplacementsSpliceCorrectly() throws {
        let store = try store(#"{"terms": [{"term": "Café über", "hear": ["cafe uber"]}]}"#)
        XCTAssertEqual(store.applyCorrections(to: "the cafe uber é test"),
                       "the Café über é test")
    }
}
