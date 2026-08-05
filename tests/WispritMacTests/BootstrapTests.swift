import XCTest
import WispritKit
import WispritPersistence
@testable import WispritMac

/// Bootstrap always runs against a temp root — never the user's `~/.wisprit`.
final class BootstrapTests: XCTestCase {

    private var root: URL!

    override func setUp() {
        super.setUp()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wisprit-bootstrap-\(UUID().uuidString)")
        WispritPaths.overrideRoot = root
        Settings.resetSharedForTesting()
    }

    override func tearDown() {
        WispritPaths.overrideRoot = nil
        Settings.resetSharedForTesting()
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    func testSeedsConfigAndDictionaryOnFirstRun() throws {
        let report = try Bootstrap.ensureStateDir()

        XCTAssertTrue(report.wroteConfig)
        XCTAssertTrue(report.wroteDictionary)
        XCTAssertTrue(FileManager.default.fileExists(atPath: WispritPaths.configPath.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: WispritPaths.dictionaryPath.path))
    }

    func testIsIdempotentAndNeverOverwritesUserEdits() throws {
        _ = try Bootstrap.ensureStateDir()
        try "{\"hotkey\": \"right_option\"}\n".write(
            to: WispritPaths.configPath, atomically: true, encoding: .utf8)

        let second = try Bootstrap.ensureStateDir()

        XCTAssertFalse(second.wroteConfig)
        XCTAssertFalse(second.wroteDictionary)
        let onDisk = try String(contentsOf: WispritPaths.configPath, encoding: .utf8)
        XCTAssertEqual(onDisk, "{\"hotkey\": \"right_option\"}\n",
                       "an existing file is never touched")
    }

    func testStateDirIsPrivate() throws {
        _ = try Bootstrap.ensureStateDir()
        let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.uint16Value
        XCTAssertEqual(permissions, 0o700, "transcripts are personal")
    }

    func testSeededConfigCarriesEveryShippedDefaultInOrder() throws {
        _ = try Bootstrap.ensureStateDir()
        let raw = try String(contentsOf: WispritPaths.configPath, encoding: .utf8)

        // Same keys, same order as Settings.defaults — no duplicated literals.
        let expectedKeys = Settings.defaults.pairs.map(\.0)
        var cursor = raw.startIndex
        for key in expectedKeys {
            guard let found = raw.range(of: "\"\(key)\"", range: cursor..<raw.endIndex) else {
                return XCTFail("config.json is missing \(key) (or it is out of order)")
            }
            cursor = found.upperBound
        }
        XCTAssertTrue(raw.hasSuffix("\n"))
    }

    func testSeededConfigRoundTripsThroughSettings() throws {
        _ = try Bootstrap.ensureStateDir()
        let settings = Settings()

        XCTAssertEqual(settings.hotkey, "fn")
        XCTAssertEqual(settings.holdDebounceMs, 150)
        XCTAssertEqual(settings.pasteRestoreDelayMs, 500)
        XCTAssertEqual(settings.aiCleanupMaxWords, 350)
        XCTAssertTrue(settings.enabled)
        XCTAssertNil(settings.pillPosition)
    }

    func testSeededDictionaryMatchesThePythonStarterSet() throws {
        _ = try Bootstrap.ensureStateDir()
        let raw = try String(contentsOf: WispritPaths.dictionaryPath, encoding: .utf8)
        let data = Data(raw.utf8)
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let terms = try XCTUnwrap(parsed?["terms"] as? [[String: Any]])

        XCTAssertEqual(terms.count, Bootstrap.seedTerms.count)
        XCTAssertEqual(terms.compactMap { $0["term"] as? String },
                       Bootstrap.seedTerms.map(\.term))
        XCTAssertEqual(terms.first?["hear"] as? [String], ["whisper it", "wisp rit"])
        // No `hear` entry may collide with a common English word.
        for seed in Bootstrap.seedTerms {
            XCTAssertFalse(seed.hear.contains("the"))
            XCTAssertFalse(seed.hear.contains("it"))
        }
    }

    func testSeedJSONIsPrettyPrintedTwoSpaceLikeThePython() {
        let config = Bootstrap.defaultConfigJSON()
        XCTAssertTrue(config.hasPrefix("{\n  \""), "two-space indent, like json.dumps(indent=2)")
        XCTAssertTrue(config.contains("\": "), "\": \" key separator")
    }
}
