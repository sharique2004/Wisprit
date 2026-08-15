import XCTest
import WispritKit
@testable import WispritDictionary

final class SnippetStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wisprit-snippets-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        WispritPaths.overrideRoot = root
    }

    override func tearDownWithError() throws {
        WispritPaths.overrideRoot = nil
        try? FileManager.default.removeItem(at: root)
    }

    func testExpandReplacesWholePhrase() {
        let store = SnippetStore(path: root.appendingPathComponent("snippets.json"))
        XCTAssertTrue(store.upsert(.init(trigger: "my address",
                                         expansion: "123 Main Street")))
        XCTAssertEqual(store.expand("send the package to my address please"),
                       "send the package to 123 Main Street please")
        XCTAssertEqual(store.expand("My address"), "123 Main Street")
        XCTAssertEqual(store.expand("my addresses"), "my addresses")
    }

    func testLongestTriggerWins() {
        let store = SnippetStore(path: root.appendingPathComponent("snippets.json"))
        XCTAssertTrue(store.upsert(.init(trigger: "my address", expansion: "home")))
        XCTAssertTrue(store.upsert(.init(trigger: "my work address", expansion: "office")))
        XCTAssertEqual(store.expand("go to my work address"), "go to office")
    }

    func testRemoveAndReload() {
        let path = root.appendingPathComponent("snippets.json")
        let store = SnippetStore(path: path)
        XCTAssertTrue(store.upsert(.init(trigger: "sign off", expansion: "Best,\nSharique")))
        XCTAssertEqual(store.all().count, 1)
        let other = SnippetStore(path: path)
        XCTAssertEqual(other.expand("sign off"), "Best,\nSharique")
        store.remove(trigger: "sign off")
        XCTAssertEqual(store.expand("sign off"), "sign off")
    }
}
