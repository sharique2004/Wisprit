import XCTest
import WispritKit
@testable import WispritPersistence

final class SettingsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wisprit-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func path(_ name: String = "config.json") -> URL {
        root.appendingPathComponent(name)
    }

    private func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: defaults

    // The Python key set, in Python order, as a strict PREFIX — native-only
    // keys are append-only (mid-list inserts would reorder every user's file).
    func testDefaultsHaveThePythonKeysInOrderThenNativeAppendices() {
        XCTAssertEqual(Settings.defaults.keys, [
            "hotkey", "hold_debounce_ms", "locale", "finalize_timeout_ms",
            "filler_removal", "ensure_sentence_period", "leading_space",
            "terminal_bundle_ids", "pill_position", "pill_hidden",
            "history_enabled", "history_limit", "engine", "ai_cleanup",
            "ai_cleanup_max_words", "ai_cleanup_timeout_ms", "mlx_model",
            "paste_restore_delay_ms", "enabled",
            // native appendices (post-Python; keep appending, never insert)
            "live_typing", "im_selection_policy", "emoji_commands", "identity_expansion",
        ])
    }

    func testMissingFileYieldsPureDefaultsAndWritesNothing() throws {
        let p = path()
        let s = Settings(path: p)
        XCTAssertFalse(FileManager.default.fileExists(atPath: p.path),
                       "loading must not create the config file (Python doesn't)")
        XCTAssertEqual(s.hotkey, "fn")
        XCTAssertEqual(s.holdDebounceMs, 150)
        XCTAssertEqual(s.locale, "en-US")
        XCTAssertEqual(s.finalizeTimeoutMs, 1500)
        XCTAssertTrue(s.fillerRemoval)
        XCTAssertFalse(s.ensureSentencePeriod)
        XCTAssertEqual(s.leadingSpace, "auto")
        XCTAssertEqual(s.terminalBundleIDs, Settings.defaultTerminalBundleIDs)
        XCTAssertNil(s.pillPosition)
        XCTAssertFalse(s.pillHidden)
        XCTAssertTrue(s.historyEnabled)
        XCTAssertEqual(s.historyLimit, 1000)
        XCTAssertEqual(s.engine, "auto")
        XCTAssertTrue(s.aiCleanup)
        XCTAssertEqual(s.aiCleanupMaxWords, 350)
        XCTAssertEqual(s.aiCleanupTimeoutMs, 12000)
        XCTAssertEqual(s.mlxModel, "mlx-community/whisper-large-v3-turbo")
        XCTAssertEqual(s.pasteRestoreDelayMs, 500)
        XCTAssertTrue(s.enabled)
        XCTAssertTrue(s.emojiCommands)
    }

    // MARK: golden parity with the Python writer

    func testSetOnFreshDirectoryMatchesPythonBytes() throws {
        let p = path()
        let s = Settings(path: p)
        s.set(SettingsKey.enabled, false)
        XCTAssertEqual(try read(p), Golden.configDefaultsAfterSetEnabledFalse)
    }

    func testUnknownKeysSurviveRoundTripMatchingPythonBytes() throws {
        let p = path()
        try #"{"hotkey": "right_option", "future_key": {"a": [1, 2.5, null, true]}, "zz_unknown": "kept", "locale": "en-GB"}"#
            .write(to: p, atomically: true, encoding: .utf8)
        let s = Settings(path: p)
        s.set(SettingsKey.historyLimit, 42)
        XCTAssertEqual(try read(p), Golden.configUnknownRoundtrip)
        XCTAssertEqual(s.hotkey, "right_option")
        XCTAssertEqual(s.locale, "en-GB")
        XCTAssertEqual(s.historyLimit, 42)
        XCTAssertNotNil(s.get("future_key"))
        XCTAssertNil(s.get("nope"))
    }

    func testUnicodeIsWrittenRawLikeEnsureAsciiFalse() throws {
        let p = path()
        let s = Settings(path: p)
        s.set(SettingsKey.locale, "de-DEé—\t\"\\")
        let text = try read(p)
        XCTAssertTrue(text.contains(Golden.configUnicodeLocaleLine), text)
        // and it reads back identically
        XCTAssertEqual(Settings(path: p).locale, "de-DEé—\t\"\\")
    }

    // MARK: failure modes (must not clobber the user's file)

    func testCorruptFileKeepsDefaultsAndLeavesFileUntouched() throws {
        let p = path()
        try "{not json".write(to: p, atomically: true, encoding: .utf8)
        let s = Settings(path: p)
        XCTAssertEqual(s.asObject(), Settings.defaults)
        XCTAssertEqual(try read(p), "{not json")
    }

    func testNonObjectJSONKeepsDefaults() throws {
        let p = path()
        try "[1,2,3]".write(to: p, atomically: true, encoding: .utf8)
        XCTAssertEqual(Settings(path: p).asObject(), Settings.defaults)
    }

    func testWrongTypeInFileFallsBackToDefaultValue() throws {
        let p = path()
        try #"{"hold_debounce_ms": "soon", "terminal_bundle_ids": 3}"#
            .write(to: p, atomically: true, encoding: .utf8)
        let s = Settings(path: p)
        XCTAssertEqual(s.holdDebounceMs, 150)
        XCTAssertEqual(s.terminalBundleIDs, Settings.defaultTerminalBundleIDs)
    }

    // MARK: persistence semantics

    func testSetPersistsImmediatelyAndReloadPicksUpExternalEdits() throws {
        let p = path()
        let a = Settings(path: p)
        a.set(SettingsKey.pillHidden, true)
        XCTAssertTrue(Settings(path: p).pillHidden, "set() must persist without an explicit save")

        let b = Settings(path: p)
        a.set(SettingsKey.engine, "apple_live")
        XCTAssertEqual(b.engine, "auto", "stale instance keeps its snapshot until reload")
        b.reload()
        XCTAssertEqual(b.engine, "apple_live")
    }

    func testAtomicWriteLeavesNoTempFilesBehind() throws {
        let p = path()
        let s = Settings(path: p)
        for i in 0..<20 { s.set(SettingsKey.historyLimit, i + 1) }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0 != "config.json" }
        XCTAssertEqual(leftovers, [])
    }

    func testPillPositionRoundTrip() throws {
        let p = path()
        let s = Settings(path: p)
        s.setPillPosition(x: 120.5, y: -3.0)
        let reloaded = Settings(path: p)
        let position = try XCTUnwrap(reloaded.pillPosition)
        XCTAssertEqual(position.x, 120.5)
        XCTAssertEqual(position.y, -3.0)
        XCTAssertTrue(try read(p).contains("\"pill_position\": [\n    120.5,\n    -3.0\n  ]"))
    }

    func testOverrideRootDrivesTheDefaultPath() throws {
        let saved = WispritPaths.overrideRoot
        defer { WispritPaths.overrideRoot = saved; Settings.resetSharedForTesting() }
        WispritPaths.overrideRoot = root
        Settings.resetSharedForTesting()
        let s = Settings.load()
        XCTAssertEqual(s.configPath, root.appendingPathComponent("config.json"))
        s.set(SettingsKey.enabled, false)
        XCTAssertEqual(try read(root.appendingPathComponent("config.json")),
                       Golden.configDefaultsAfterSetEnabledFalse)
        XCTAssertTrue(Settings.load() === s, "load() is a singleton")
    }

    func testConcurrentSetsNeverProduceAPartialFile() throws {
        let p = path()
        let s = Settings(path: p)
        DispatchQueue.concurrentPerform(iterations: 64) { i in
            s.set(SettingsKey.historyLimit, i + 1)
            _ = try? self.read(p)
        }
        let final = try read(p)
        XCTAssertNoThrow(try WispritJSON.parse(final))
        XCTAssertTrue(final.hasSuffix("}\n"))
    }
}
