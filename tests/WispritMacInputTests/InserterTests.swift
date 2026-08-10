import XCTest
@testable import WispritMacInput

/// The insertion cascade, driven entirely through `FakeInsertPorts`. Asserts
/// the ORDER of operations, not just the outcome — the clipboard dance is
/// ordering-sensitive (snapshot before clear, changeCount after the write,
/// restore only if changeCount is unchanged).
final class InserterTests: XCTestCase {

    private let terminals = Inserter.defaultTerminalBundleIDs

    private func config(delayMs: Double? = 500, terminals: [String]? = nil) -> InserterConfig {
        InserterConfig(terminalBundleIDs: terminals ?? self.terminals, pasteRestoreDelayMs: delayMs)
    }

    // --- routing (pure) --------------------------------------------------------

    func testRouteOrderSecureBeatsEverything() {
        let route = Inserter.route(text: "hi", secureInput: true, accessibilityTrusted: false,
                                   bundleID: "com.apple.Terminal", terminalBundleIDs: terminals)
        XCTAssertEqual(route, .blockedSecure)
    }

    func testRouteTrustGateBeatsTerminal() {
        let route = Inserter.route(text: "hi", secureInput: false, accessibilityTrusted: false,
                                   bundleID: "com.apple.Terminal", terminalBundleIDs: terminals)
        XCTAssertEqual(route, .notTrusted)
    }

    func testRouteEmptyTextFirst() {
        XCTAssertEqual(Inserter.route(text: "", secureInput: true, accessibilityTrusted: true,
                                      bundleID: nil, terminalBundleIDs: terminals), .emptyText)
    }

    func testRouteTerminalVsClipboard() {
        for bundle in terminals {
            XCTAssertEqual(
                Inserter.route(text: "hi", secureInput: false, accessibilityTrusted: true,
                               bundleID: bundle, terminalBundleIDs: terminals),
                .typed(bundleID: bundle))
        }
        XCTAssertEqual(
            Inserter.route(text: "hi", secureInput: false, accessibilityTrusted: true,
                           bundleID: "com.apple.Notes", terminalBundleIDs: terminals),
            .clipboard(bundleID: "com.apple.Notes"))
        XCTAssertEqual(
            Inserter.route(text: "hi", secureInput: false, accessibilityTrusted: true,
                           bundleID: nil, terminalBundleIDs: terminals),
            .clipboard(bundleID: nil))
    }

    func testDefaultTerminalBundleIDsMatchRuntimePy() {
        XCTAssertEqual(Inserter.defaultTerminalBundleIDs, [
            "com.apple.Terminal",
            "com.googlecode.iterm2",
            "com.github.wez.wezterm",
            "net.kovidgoyal.kitty",
            "io.alacritty",
            "com.mitchellh.ghostty",
        ])
    }

    // --- gates -----------------------------------------------------------------

    func testEmptyTextNeverTouchesTheSystem() {
        let ports = FakeInsertPorts()
        let result = Inserter(ports: ports).insert("", config: config())
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.method, .error)
        XCTAssertEqual(result.detail, "empty text")
        XCTAssertEqual(ports.ops, [])
    }

    func testSecureInputBlocksWithoutProbingAnythingElse() {
        let ports = FakeInsertPorts()
        ports.secure = true
        let result = Inserter(ports: ports).insert("hello", config: config())
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.method, .blockedSecure)
        XCTAssertTrue(result.detail.contains("Secure Keyboard Entry is active"))
        XCTAssertTrue(result.detail.contains("Use paste-last once it clears."))
        // No clipboard was touched, no event posted, no frontmost lookup.
        XCTAssertEqual(ports.ops, [.secureProbe])
    }

    func testAccessibilityGateBlocksBeforeClobberingTheClipboard() {
        let ports = FakeInsertPorts()
        ports.trusted = false
        ports.executable = "/Applications/Wisprit.app/Contents/MacOS/Wisprit"
        let result = Inserter(ports: ports).insert("hello", config: config())
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.method, .error)
        XCTAssertTrue(result.detail.contains("Accessibility permission missing"))
        XCTAssertTrue(result.detail.contains("/Applications/Wisprit.app/Contents/MacOS/Wisprit"))
        XCTAssertTrue(result.detail.contains("System Settings → Privacy & Security → Accessibility"))
        XCTAssertEqual(ports.ops, [.secureProbe, .trustProbe])
    }

    // --- typed injection (terminals) -------------------------------------------

    func testTerminalUsesTypedInjectionWithPacing() {
        let ports = FakeInsertPorts()
        ports.bundleID = "com.mitchellh.ghostty"
        let text = String(repeating: "x", count: 45)   // 3 chunks: 20/20/5
        let result = Inserter(ports: ports).insert(text, config: config())

        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.method, .type)
        XCTAssertEqual(result.detail, "typed into com.mitchellh.ghostty")
        XCTAssertEqual(ports.typedChunks.map(\.count), [20, 20, 5])
        XCTAssertEqual(ports.typedChunks.joined(), text)
        // One 5 ms pause after every chunk.
        XCTAssertEqual(ports.sleeps, [0.005, 0.005, 0.005])
        // The pasteboard is never involved.
        XCTAssertFalse(ports.ops.contains(.snapshot))
        XCTAssertFalse(ports.ops.contains(.commandV))
    }

    func testTypedInjectionPassesUTF16UnitCounts() {
        let ports = FakeInsertPorts()
        ports.bundleID = "io.alacritty"
        _ = Inserter(ports: ports).insert("hi 😀", config: config())
        guard case .type(let chunk, let units)? = ports.ops.first(where: {
            if case .type = $0 { return true } else { return false }
        }) else { return XCTFail("no typed chunk recorded") }
        XCTAssertEqual(chunk, "hi 😀")
        XCTAssertEqual(units, 5)   // 3 ASCII + surrogate pair
    }

    func testTypedInjectionErrorBecomesErrorResult() {
        let ports = FakeInsertPorts()
        ports.bundleID = "com.apple.Terminal"
        ports.typeError = FakeError.boom
        let result = Inserter(ports: ports).insert("hello", config: config())
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.method, .error)
        XCTAssertTrue(result.detail.contains("boom"))
    }

    func testCustomTerminalListIsHonored() {
        let ports = FakeInsertPorts()
        ports.bundleID = "com.example.myterm"
        let result = Inserter(ports: ports).insert("hi", config: config(terminals: ["com.example.myterm"]))
        XCTAssertEqual(result.method, .type)
    }

    // --- clipboard dance --------------------------------------------------------

    func testClipboardCascadeOrderAndRestore() {
        let ports = FakeInsertPorts()
        ports.bundleID = "com.apple.Notes"
        ports.snapshotItems = [[PasteboardEntry(type: "public.utf8-plain-text",
                                                data: Data("old".utf8))]]
        ports.changeCountScript = [12, 12]   // nobody else touched it
        let result = Inserter(ports: ports).insert("hello", config: config(delayMs: 500))

        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.method, .paste)
        XCTAssertEqual(result.detail, "clipboard restored (target com.apple.Notes)")
        XCTAssertEqual(ports.ops, [
            .secureProbe,
            .trustProbe,
            .frontmost,
            .snapshot,                                    // BEFORE clearing
            .clear,
            .declare(["public.utf8-plain-text", "org.nspasteboard.TransientType"]),
            .setString("hello", type: "public.utf8-plain-text"),
            .changeCount,                                 // ours, AFTER the write
            .commandV,
            .sleep(0.5),
            .changeCount,                                 // still ours?
            .restore(items: 1),
        ])
        XCTAssertEqual(ports.writtenString, "hello")
    }

    /// The transient marker is what keeps Maccy/Paste out of the user's
    /// clipboard history; it must be declared alongside the string type.
    func testTransientMarkerIsDeclared() {
        let ports = FakeInsertPorts()
        _ = Inserter(ports: ports).insert("hello", config: config())
        guard case .declare(let types)? = ports.ops.first(where: {
            if case .declare = $0 { return true } else { return false }
        }) else { return XCTFail("no declare recorded") }
        XCTAssertEqual(types, [Inserter.stringPasteboardType, Inserter.transientPasteboardType])
        XCTAssertEqual(Inserter.transientPasteboardType, "org.nspasteboard.TransientType")
    }

    func testExternalPasteboardChangeSkipsRestore() {
        let ports = FakeInsertPorts()
        ports.bundleID = "com.apple.Notes"
        ports.snapshotItems = [[PasteboardEntry(type: "public.utf8-plain-text", data: Data("old".utf8))]]
        ports.changeCountScript = [12, 13]   // a clipboard manager wrote after us
        let result = Inserter(ports: ports).insert("hello", config: config())

        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.detail, "clipboard changed externally; restore skipped (target com.apple.Notes)")
        XCTAssertFalse(ports.ops.contains { if case .restore = $0 { return true } else { return false } })
    }

    func testFailedRestoreIsReportedButStillOK() {
        let ports = FakeInsertPorts()
        ports.bundleID = "com.apple.Notes"
        ports.restoreSucceeds = false
        let result = Inserter(ports: ports).insert("hello", config: config())
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.detail, "clipboard restore failed (target com.apple.Notes)")
    }

    func testUnknownFrontmostOmitsTargetSuffix() {
        let ports = FakeInsertPorts()
        ports.bundleID = nil
        let result = Inserter(ports: ports).insert("hello", config: config())
        XCTAssertEqual(result.detail, "clipboard restored")
    }

    /// A failed write left the pasteboard empty — the old contents must go back
    /// even though nothing will be pasted.
    func testPasteboardWriteFailureRestoresSnapshot() {
        let ports = FakeInsertPorts()
        ports.setStringSucceeds = false
        ports.snapshotItems = [[PasteboardEntry(type: "public.utf8-plain-text", data: Data("old".utf8))]]
        let result = Inserter(ports: ports).insert("hello", config: config())

        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.method, .error)
        XCTAssertEqual(result.detail, "pasteboard write failed")
        XCTAssertTrue(ports.ops.contains(.restore(items: 1)))
        XCTAssertFalse(ports.ops.contains(.commandV))
    }

    func testEmptySnapshotIsRestoredAsEmpty() {
        let ports = FakeInsertPorts()
        ports.snapshotItems = []
        let result = Inserter(ports: ports).insert("hello", config: config())
        XCTAssertTrue(result.ok)
        XCTAssertTrue(ports.ops.contains(.restore(items: 0)))
    }

    func testMultiItemMultiTypeSnapshotSurvivesRoundTrip() {
        let ports = FakeInsertPorts()
        let snapshot: [PasteboardItemSnapshot] = [
            [PasteboardEntry(type: "public.utf8-plain-text", data: Data("a".utf8)),
             PasteboardEntry(type: "public.rtf", data: Data("{\\rtf1 a}".utf8))],
            [PasteboardEntry(type: "public.file-url", data: Data("file:///tmp/x".utf8))],
        ]
        ports.snapshotItems = snapshot
        _ = Inserter(ports: ports).insert("hello", config: config())
        XCTAssertTrue(ports.ops.contains(.restore(items: 2)))
        XCTAssertEqual(ports.restored, snapshot)
    }

    func testPostCommandVFailureBecomesErrorResult() {
        let ports = FakeInsertPorts()
        ports.postVError = FakeError.boom
        let result = Inserter(ports: ports).insert("hello", config: config())
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.method, .error)
        XCTAssertTrue(result.detail.contains("boom"))
    }

    // --- restore delay validation ------------------------------------------------

    func testRestoreDelayComesFromConfig() {
        let ports = FakeInsertPorts()
        _ = Inserter(ports: ports).insert("hello", config: config(delayMs: 120))
        XCTAssertEqual(ports.sleeps, [0.12])
    }

    func testInvalidRestoreDelayFallsBackTo500ms() {
        for bad: Double? in [nil, -1, -0.001, .nan, .infinity] {
            let ports = FakeInsertPorts()
            _ = Inserter(ports: ports).insert("hello", config: config(delayMs: bad))
            XCTAssertEqual(ports.sleeps, [0.5], "delay \(String(describing: bad))")
        }
        XCTAssertEqual(Inserter.defaultRestoreDelayMs, 500)
    }

    func testZeroRestoreDelayIsAllowed() {
        let ports = FakeInsertPorts()
        _ = Inserter(ports: ports).insert("hello", config: config(delayMs: 0))
        XCTAssertEqual(ports.sleeps, [0])
    }

    // --- R6: delivery callback + timestamp (the feedback-inversion fix) ----------

    /// The core of R6: the delivery hook fires after ⌘V is posted and BEFORE
    /// the restore sleep — the success flash it carries can no longer trail
    /// the pasted text by the length of the custody window.
    func testPasteDeliveryHookFiresAfterCommandVAndBeforeTheRestoreSleep() {
        let ports = FakeInsertPorts()
        ports.bundleID = "com.apple.Notes"
        var deliveredCount = 0
        let result = Inserter(ports: ports).insert("hello", config: config(delayMs: 500)) {
            deliveredCount += 1
            XCTAssertEqual(ports.ops.last, .commandV,
                           "delivery is the instant after ⌘V, nothing later")
            XCTAssertTrue(ports.sleeps.isEmpty, "…and strictly before the restore sleep")
        }
        XCTAssertEqual(deliveredCount, 1)
        XCTAssertNotNil(result.deliveredAtMonotonic,
                        "the paste rung stamps the delivery instant for the metric split")
        XCTAssertEqual(ports.sleeps, [0.5], "the restore semantics are unchanged")
        XCTAssertTrue(ports.ops.contains(.restore(items: 0)))
    }

    func testTypedDeliveryHookFiresOnceTypingIsComplete() {
        let ports = FakeInsertPorts()
        ports.bundleID = "com.apple.Terminal"
        var delivered = false
        let result = Inserter(ports: ports).insert("hello world echo", config: config()) {
            delivered = true
            XCTAssertEqual(ports.typedChunks.joined(), "hello world echo",
                           "typing IS the delivery — the hook fires after the last chunk")
        }
        XCTAssertTrue(delivered)
        XCTAssertEqual(result.method, .type)
        XCTAssertNotNil(result.deliveredAtMonotonic)
    }

    /// No failure path may ever claim a delivery.
    func testDeliveryHookNeverFiresOnAFailurePath() {
        let cases: [(String, (FakeInsertPorts) -> Void)] = [
            ("blocked secure", { $0.secure = true }),
            ("not trusted", { $0.trusted = false }),
            ("pasteboard write failed", { $0.setStringSucceeds = false }),
            ("postCommandV threw", { $0.postVError = FakeError.boom }),
            ("typing threw", { $0.bundleID = "com.apple.Terminal"; $0.typeError = FakeError.boom }),
        ]
        for (label, arrange) in cases {
            let ports = FakeInsertPorts()
            arrange(ports)
            let result = Inserter(ports: ports).insert("hello", config: config()) {
                XCTFail("delivery hook fired on: \(label)")
            }
            XCTAssertFalse(result.ok, label)
            XCTAssertNil(result.deliveredAtMonotonic, label)
        }
    }

    // --- misc --------------------------------------------------------------------

    func testConfigProviderIsEvaluatedPerCall() {
        let ports = FakeInsertPorts()
        var delay = 100.0
        let inserter = Inserter(ports: ports)
        _ = inserter.insert("a") { self.config(delayMs: delay) }
        delay = 250
        _ = inserter.insert("b") { self.config(delayMs: delay) }
        XCTAssertEqual(ports.sleeps, [0.1, 0.25])
    }

    func testMethodRawValuesMatchPython() {
        XCTAssertEqual(InsertResult.Method.paste.rawValue, "paste")
        XCTAssertEqual(InsertResult.Method.type.rawValue, "type")
        XCTAssertEqual(InsertResult.Method.blockedSecure.rawValue, "blocked_secure")
        XCTAssertEqual(InsertResult.Method.error.rawValue, "error")
    }
}
