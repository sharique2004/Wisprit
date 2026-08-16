import XCTest
import WispritDictionary
import WispritKit
import WispritPersistence
@testable import WispritMac

/// The Identity section's model half — four named fields, a normalize →
/// validate → store commit, and the one invariant that matters: nothing the
/// user has not confirmed can reach identity.json.
@MainActor
final class WindowModelIdentityTests: XCTestCase {
    private var root: URL!
    private var settings: Settings!
    private var store: IdentityStore!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wisprit-window-identity-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        settings = Settings(path: root.appendingPathComponent("config.json"))
        store = IdentityStore(path: root.appendingPathComponent("identity.json"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeModel(withStore: Bool = true) -> WispritWindowModel {
        WispritWindowModel(
            settings: settings,
            dictionary: DictionaryEditor(
                store: DictionaryStore(path: root.appendingPathComponent("dictionary.json"))),
            identity: withStore ? store : nil)
    }

    /// Four rows, always, in a fixed order — even with nothing set. They are
    /// named fields, and an unset one must still render as itself.
    func testRowsAreAlwaysFourInFixedOrder() {
        let model = makeModel()
        XCTAssertEqual(model.identityRows.map(\.slot), IdentitySlot.allCases)
        XCTAssertEqual(model.identityRows.map(\.value), ["", "", "", ""])
        XCTAssertEqual(model.identityRows.map(\.label), ["Email", "LinkedIn", "GitHub", "Website"])
    }

    /// The search field filters the snippet LIST below; it must not touch these
    /// fields, or a set value would look unset.
    func testRowsIgnoreTheDictionarySearch() {
        let model = makeModel()
        model.saveIdentity(.email, value: "me@example.com")
        model.dictionarySearch = "zzzz"
        XCTAssertEqual(model.identityRows.count, 4)
        XCTAssertEqual(model.identityRows.first?.value, "me@example.com")
    }

    func testSaveNormalizesThenStores() {
        let model = makeModel()
        XCTAssertEqual(model.saveIdentity(.github, value: "example"),
                       .saved(normalized: "https://github.com/example"))
        XCTAssertEqual(store.value(.github), "https://github.com/example")
        XCTAssertEqual(model.saveIdentity(.linkedin, value: "linkedin.com/in/example"),
                       .saved(normalized: "https://www.linkedin.com/in/example"))
        XCTAssertEqual(model.saveIdentity(.website, value: "wisprit.app"),
                       .saved(normalized: "https://wisprit.app"))
        XCTAssertEqual(model.saveIdentity(.email, value: "Me@Example.com"),
                       .saved(normalized: "Me@Example.com"))
    }

    /// A refused value produces a MESSAGE, and the slot stays empty — a bad
    /// value degrades to no value, never to a broken one that gets typed.
    func testRejectedValueIsNotStored() {
        let model = makeModel()
        guard case .rejected = model.saveIdentity(.email, value: "notanemail") else {
            return XCTFail("an address with no domain must be refused")
        }
        XCTAssertNil(store.value(.email))
        XCTAssertEqual(model.identityRows.first?.value, "")
    }

    /// Blank input short-circuits BEFORE normalize, so the clear path can never
    /// be turned into a `https://github.com/` stub by the normalizer.
    func testBlankInputClearsRatherThanNormalizing() {
        let model = makeModel()
        model.saveIdentity(.github, value: "example")
        XCTAssertEqual(model.saveIdentity(.github, value: "   "), .cleared)
        XCTAssertNil(store.value(.github))
        model.saveIdentity(.website, value: "wisprit.app")
        model.clearIdentity(.website)
        XCTAssertNil(store.value(.website))
    }

    func testHasIdentityIsFalseWithoutAStore() {
        XCTAssertFalse(makeModel(withStore: false).hasIdentity)
        XCTAssertTrue(makeModel().hasIdentity)
    }

    /// A suggestion is DRAFT material. Building the whole model must leave
    /// identity.json non-existent — the only writer is `saveIdentity`, which
    /// only the user's save action calls.
    func testConstructingTheModelWritesNothing() {
        let model = makeModel()
        _ = model.suggestedEmail
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("identity.json").path))
        for slot in IdentitySlot.allCases { XCTAssertNil(store.value(slot)) }
    }

    func testDismissingTheSuggestionHidesItForTheSession() {
        let model = makeModel()
        model.dismissEmailSuggestion()
        XCTAssertNil(model.suggestedEmail)
    }

    /// Every row shows the phrase that triggers it, and the placeholder is the
    /// SHAPE — never a value that could be mistaken for something real.
    func testEveryRowNamesItsSpokenTrigger() {
        for row in makeModel().identityRows {
            XCTAssertTrue(row.spokenTrigger.hasPrefix("Say "), row.spokenTrigger)
            XCTAssertFalse(row.placeholder.isEmpty)
            XCTAssertNil(IdentityValue.validate(row.value, for: row.slot),
                         "an unset row must not carry a value at all")
        }
    }
}
