import XCTest
import WispritIMProtocol
@testable import WispritMac

/// Rung selection and the per-bundle downgrade memory.
///
/// The whole ladder is a pure function of a snapshot, which is the point: the
/// policy that decides where a user's words go is asserted here with no TCC
/// grant, no input source, and no text field.
final class InsertionLadderTests: XCTestCase {

    private let unicodeClient = IMClientCapabilities(
        supportsUnicode: true, bundleID: "com.apple.TextEdit", supportsDocumentAccess: true)

    private func context(_ mutate: (inout InsertionContext) -> Void = { _ in }) -> InsertionContext {
        var ctx = InsertionContext(liveTypingEnabled: true,
                                   inputMethodUsable: true,
                                   inputMethodReachable: true,
                                   capabilities: unicodeClient,
                                   terminalBundleIDs: ["com.apple.Terminal"])
        mutate(&ctx)
        return ctx
    }

    // MARK: - rung order

    func testRungNumbersMatchTheResearchLadder() {
        XCTAssertEqual(InsertionTier.imStreaming.rung, 1)
        XCTAssertEqual(InsertionTier.imCommit.rung, 2)
        XCTAssertEqual(InsertionTier.paste.rung, 3)
        XCTAssertEqual(InsertionTier.typed.rung, 4)
        XCTAssertEqual(InsertionTier.blockedSecure.rung, 5)
    }

    func testRawValuesStayCompatibleWithTheMetricsVocabulary() {
        // `outcome` in metrics.log has always been paste|type|blocked_secure.
        XCTAssertEqual(InsertionTier.paste.rawValue, "paste")
        XCTAssertEqual(InsertionTier.typed.rawValue, "type")
        XCTAssertEqual(InsertionTier.blockedSecure.rawValue, "blocked_secure")
        XCTAssertEqual(InsertionTier.imStreaming.rawValue, "im_streaming")
        XCTAssertEqual(InsertionTier.imCommit.rawValue, "im_commit")
    }

    func testLoweringWalksOneRungAtATimeAndStopsAtTheBottom() {
        XCTAssertEqual(InsertionTier.imStreaming.lowered, .imCommit)
        XCTAssertEqual(InsertionTier.imCommit.lowered, .paste)
        XCTAssertEqual(InsertionTier.paste.lowered, .typed)
        XCTAssertEqual(InsertionTier.typed.lowered, .blockedSecure)
        XCTAssertEqual(InsertionTier.blockedSecure.lowered, .blockedSecure)
    }

    // MARK: - selection

    func testHealthyUnicodeClientGetsRungOne() {
        XCTAssertEqual(InsertionLadder.tier(context()), .imStreaming)
    }

    func testSecureInputBeatsEveryOtherRung() {
        // TN2150: Secure Event Input defeats input methods as well as event taps.
        let tier = InsertionLadder.tier(context {
            $0.secureInputActive = true
            $0.frontmostBundleID = "com.apple.Terminal"
        })
        XCTAssertEqual(tier, .blockedSecure)
    }

    func testLiveTypingOffKeepsThePhaseOneBehaviour() {
        XCTAssertEqual(InsertionLadder.tier(context { $0.liveTypingEnabled = false }), .paste)
    }

    func testUnusableInputMethodFallsToPaste() {
        XCTAssertEqual(InsertionLadder.tier(context { $0.inputMethodUsable = false }), .paste)
    }

    func testUnreachableInputMethodFallsToPaste() {
        XCTAssertEqual(InsertionLadder.tier(context { $0.inputMethodReachable = false }), .paste)
    }

    func testNoClientMeansNoInputMethodRung() {
        XCTAssertEqual(InsertionLadder.tier(context { $0.capabilities = nil }), .paste)
    }

    func testClientWithoutUnicodeIsAHardSkip() {
        // IPAPalette treats supportsUnicode == NO as a hard error; so do we.
        let tier = InsertionLadder.tier(context {
            $0.capabilities = IMClientCapabilities(supportsUnicode: false,
                                                   bundleID: "com.legacy.app",
                                                   supportsDocumentAccess: false)
        })
        XCTAssertEqual(tier, .paste)
    }

    func testCachedCommitOnlyVerdictPinsTheBundleToRungTwo() {
        XCTAssertEqual(InsertionLadder.tier(context { $0.cachedVerdict = .commitOnly }), .imCommit)
    }

    func testCachedUnsupportedVerdictTakesTheBundleOffTheInputMethodEntirely() {
        XCTAssertEqual(InsertionLadder.tier(context { $0.cachedVerdict = .unsupported }), .paste)
    }

    func testTerminalBundleGetsTypedInjectionWhenTheInputMethodIsOut() {
        let tier = InsertionLadder.tier(context {
            $0.liveTypingEnabled = false
            $0.frontmostBundleID = "com.apple.Terminal"
        })
        XCTAssertEqual(tier, .typed)
    }

    func testTerminalStillGetsRungOneWhenTheInputMethodIsAvailable() {
        // Research: marked text works in Terminal.app / iTerm2, which is exactly
        // what retires the typed-injection special case on the IM tier.
        let tier = InsertionLadder.tier(context { $0.frontmostBundleID = "com.apple.Terminal" })
        XCTAssertEqual(tier, .imStreaming)
    }

    func testOnlyRungOneStreamsALiveTail() {
        XCTAssertTrue(InsertionTier.imStreaming.streamsLiveTail)
        for tier in InsertionTier.allCases where tier != .imStreaming {
            XCTAssertFalse(tier.streamsLiveTail, "\(tier)")
        }
        XCTAssertTrue(InsertionTier.imCommit.usesInputMethod)
        XCTAssertFalse(InsertionTier.paste.usesInputMethod)
    }

    // MARK: - capability cache

    func testCacheStartsEmptyAndRemembersWhatItIsTold() {
        let cache = BundleCapabilityCache()
        XCTAssertNil(cache.verdict(for: "com.apple.TextEdit"))
        cache.observe(.markedStreaming, for: "com.apple.TextEdit", reason: "probe")
        XCTAssertEqual(cache.verdict(for: "com.apple.TextEdit"), .markedStreaming)
        XCTAssertEqual(cache.count, 1)
    }

    func testCacheIsMonotoneAndNeverPromotesABundleBack() {
        let cache = BundleCapabilityCache()
        cache.observe(.markedStreaming, for: "org.qt.app")
        cache.downgradeMarkedText(for: "org.qt.app", reason: "setMarkedText refused")
        XCTAssertEqual(cache.verdict(for: "org.qt.app"), .commitOnly)

        // A later optimistic probe must not undo the downgrade: re-probing costs
        // the user a visible flicker every single time.
        cache.observe(.markedStreaming, for: "org.qt.app", reason: "probe")
        XCTAssertEqual(cache.verdict(for: "org.qt.app"), .commitOnly)

        cache.downgradeToPaste(for: "org.qt.app", reason: "insertText refused")
        XCTAssertEqual(cache.verdict(for: "org.qt.app"), .unsupported)
        cache.observe(.commitOnly, for: "org.qt.app")
        XCTAssertEqual(cache.verdict(for: "org.qt.app"), .unsupported)
    }

    func testDowngradeMapsEditDetailsToTheRightSeverity() {
        let cache = BundleCapabilityCache()
        cache.observe(.markedStreaming, for: "a.app")
        XCTAssertEqual(cache.downgrade(for: "a.app", detail: .notSupported), .commitOnly)

        cache.observe(.markedStreaming, for: "b.app")
        XCTAssertEqual(cache.downgrade(for: "b.app", detail: .noClient), .unsupported)
    }

    func testTransientFailuresNeverPoisonTheCache() {
        // A stale generation, a field the user typed into, a word we could not
        // find — none of these say anything about what the app can DO.
        let transient: [IMEditDetail] = [.staleGeneration, .fieldChanged, .targetNotFound,
                                         .ambiguousRelocation, .readFailed, .emptyEdit,
                                         .noSession, .noDocumentAccess, .applied]
        for detail in transient {
            let cache = BundleCapabilityCache()
            cache.observe(.markedStreaming, for: "c.app")
            XCTAssertEqual(cache.downgrade(for: "c.app", detail: detail), .markedStreaming,
                           "\(detail) must not downgrade the bundle")
        }
    }

    func testForgetAllowsADeliberateReprobe() {
        let cache = BundleCapabilityCache()
        cache.downgradeToPaste(for: "d.app", reason: "test")
        cache.forget("d.app")
        XCTAssertNil(cache.verdict(for: "d.app"))
    }

    func testEmptyBundleIDIsNeverCached() {
        let cache = BundleCapabilityCache()
        cache.observe(.markedStreaming, for: "")
        cache.observe(.markedStreaming, for: nil)
        XCTAssertEqual(cache.count, 0)
        XCTAssertNil(cache.verdict(for: nil))
    }
}
