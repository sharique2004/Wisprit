import XCTest
import WispritKit
@testable import WispritDictionary

final class IdentityStoreTests: XCTestCase {
    private var root: URL!
    private var path: URL { root.appendingPathComponent("identity.json") }

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wisprit-identity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        WispritPaths.overrideRoot = root
    }

    override func tearDownWithError() throws {
        WispritPaths.overrideRoot = nil
        try? FileManager.default.removeItem(at: root)
    }

    private func rawJSON() throws -> String {
        try String(contentsOf: path, encoding: .utf8)
    }

    // MARK: - the inert-slot invariant

    func testAbsentFileMeansEverySlotNil() {
        let store = IdentityStore(path: path)
        for slot in IdentitySlot.allCases { XCTAssertNil(store.value(slot)) }
        XCTAssertTrue(store.values().isEmpty)
    }

    func testSetAndReloadRoundTrips() {
        let store = IdentityStore(path: path)
        XCTAssertTrue(store.set(.email, to: "a@b.com"))
        let other = IdentityStore(path: path)
        XCTAssertEqual(other.value(.email), "a@b.com")
        XCTAssertNil(other.value(.linkedin))
    }

    /// The file physically cannot express "set but empty" — which is what makes
    /// "an unset slot never expands" impossible to get wrong from disk.
    func testEmptyValueIsIndistinguishableFromAbsent() throws {
        let store = IdentityStore(path: path)
        store.set(.linkedin, to: "https://www.linkedin.com/in/x")
        XCTAssertTrue(try rawJSON().contains("linkedin"))
        store.set(.linkedin, to: "")
        XCTAssertNil(store.value(.linkedin))
        XCTAssertFalse(try rawJSON().contains("linkedin"),
                       #"a cleared slot must not persist as "linkedin": """#)
    }

    func testWhitespaceOnlyClears() throws {
        let store = IdentityStore(path: path)
        store.set(.website, to: "https://x.dev")
        store.set(.website, to: "   ")
        XCTAssertNil(store.value(.website))
        XCTAssertFalse(try rawJSON().contains("website"))
    }

    func testWhitespaceInAStoredValueIsNeverExpanded() throws {
        try #"{"version":1,"identity":{"email":"   "}}"#.write(to: path, atomically: true,
                                                               encoding: .utf8)
        let store = IdentityStore(path: path)
        XCTAssertNil(store.value(.email))
        XCTAssertTrue(store.values().isEmpty)
    }

    // MARK: - WYSIWYG

    /// A hand-edited value comes back exactly as written. The "helpfully fix it
    /// up on read" convenience is what this test exists to block.
    func testStoreDoesNotNormalizeOnLoad() throws {
        try #"{"version":1,"identity":{"github":"github.com/x"}}"#.write(to: path,
                                                                         atomically: true,
                                                                         encoding: .utf8)
        XCTAssertEqual(IdentityStore(path: path).value(.github), "github.com/x")
    }

    func testUnknownKeysAreIgnoredNotFatal() throws {
        try #"{"version":1,"identity":{"email":"a@b.com","work_email":"c@d.com"}}"#
            .write(to: path, atomically: true, encoding: .utf8)
        let store = IdentityStore(path: path)
        XCTAssertEqual(store.value(.email), "a@b.com")
        XCTAssertEqual(store.values().values.count, 1)
    }

    func testMalformedJSONYieldsEmptyStore() throws {
        try "{ not json".write(to: path, atomically: true, encoding: .utf8)
        XCTAssertTrue(IdentityStore(path: path).values().isEmpty)
    }

    /// The store is read on the session thread and written on the main thread
    /// from the UI, so an edit must land on the very next utterance rather than
    /// the next launch.
    func testMtimeReloadPicksUpAnExternalEdit() throws {
        let store = IdentityStore(path: path)
        store.set(.email, to: "first@b.com")
        try #"{"version":1,"identity":{"email":"second@b.com"}}"#.write(to: path,
                                                                        atomically: true,
                                                                        encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)],
                                              ofItemAtPath: path.path)
        XCTAssertEqual(store.value(.email), "second@b.com")
    }

    func testSnippetsFileIsNeverTouched() {
        let store = IdentityStore(path: path)
        store.set(.email, to: "a@b.com")
        store.set(.email, to: "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: WispritPaths.snippetsPath.path))
    }
}

final class IdentityValueTests: XCTestCase {

    func testGithubNormalizesEveryInputShape() {
        for input in ["example", "@example", "github.com/example", "www.github.com/example",
                      "https://github.com/example", "https://github.com/example/",
                      "http://www.github.com/example"] {
            XCTAssertEqual(IdentityValue.normalize(input, for: .github),
                           "https://github.com/example", input)
        }
    }

    func testLinkedinNormalizesEveryInputShape() {
        for input in ["example", "in/example", "linkedin.com/in/example",
                      "www.linkedin.com/in/example", "https://www.linkedin.com/in/example",
                      "https://linkedin.com/in/example/"] {
            XCTAssertEqual(IdentityValue.normalize(input, for: .linkedin),
                           "https://www.linkedin.com/in/example", input)
        }
    }

    func testLinkedinCompanyPathIsPreserved() {
        XCTAssertEqual(IdentityValue.normalize("linkedin.com/company/acme", for: .linkedin),
                       "https://www.linkedin.com/company/acme")
    }

    func testWebsiteGetsHttpsOnlyWhenNoSchemeIsPresent() {
        XCTAssertEqual(IdentityValue.normalize("wisprit.app", for: .website), "https://wisprit.app")
        XCTAssertEqual(IdentityValue.normalize("http://wisprit.app", for: .website),
                       "http://wisprit.app")
        XCTAssertEqual(IdentityValue.normalize("https://wisprit.app/about?x=1", for: .website),
                       "https://wisprit.app/about?x=1", "a path and query are never stripped")
    }

    func testEmailStripsMailtoAndPreservesCase() {
        XCTAssertEqual(IdentityValue.normalize("mailto:Sharique.Khatri@example.com", for: .email),
                       "Sharique.Khatri@example.com")
        XCTAssertNil(IdentityValue.validate("Sharique.Khatri@example.com", for: .email))
    }

    /// The stub bug, pinned: blank or degenerate input must NEVER become a
    /// valid-looking `https://github.com/`, because the store would then hold
    /// it and rule 1 would type it into a document.
    func testDegenerateInputNeverBecomesAValidStub() {
        for (raw, slot) in [("", IdentitySlot.github), ("@", .github), ("github.com/", .github),
                            ("", .linkedin), ("in/", .linkedin), ("linkedin.com/", .linkedin),
                            ("", .website), ("https://", .website)] {
            let normalized = IdentityValue.normalize(raw, for: slot)
            for stub in ["https://github.com/", "https://www.linkedin.com/in/",
                         "https://www.linkedin.com/in/in"] {
                XCTAssertNotEqual(normalized, stub, "\(raw) for \(slot) fabricated a stub")
            }
            // Blank stays blank (the caller's clear path); anything else comes
            // back as the raw input and must be REFUSED, so it is never stored
            // and therefore can never be typed.
            if raw.isEmpty {
                XCTAssertEqual(normalized, "")
            } else {
                XCTAssertNotNil(IdentityValue.validate(normalized, for: slot),
                                "\(raw) for \(slot) must be rejected, not stored")
            }
        }
    }

    func testValidateRejectsTheObviousBadValues() {
        XCTAssertNotNil(IdentityValue.validate("notanemail", for: .email))
        XCTAssertNotNil(IdentityValue.validate("a@b", for: .email))
        XCTAssertNotNil(IdentityValue.validate("a b@c.com", for: .email))
        XCTAssertNotNil(IdentityValue.validate("https://example", for: .website),
                        "a host with no dot is a bare username, not a site")
        XCTAssertNotNil(IdentityValue.validate("https://github.com/a/b", for: .github),
                        "a repo path is not a profile")
        XCTAssertNil(IdentityValue.validate("https://github.com/example", for: .github))
        XCTAssertNil(IdentityValue.validate("https://www.linkedin.com/in/example", for: .linkedin))
        XCTAssertNil(IdentityValue.validate("https://wisprit.app", for: .website))
    }
}

final class IdentitySeedTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wisprit-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func writeGitConfig(_ contents: String) throws {
        try contents.write(to: home.appendingPathComponent(".gitconfig"),
                           atomically: true, encoding: .utf8)
    }

    func testParsesTabIndentedGitConfig() throws {
        try writeGitConfig("[user]\n\tname = Someone\n\temail = someone@example.com\n")
        XCTAssertEqual(IdentitySeed.gitConfigEmail(home: home), "someone@example.com")
    }

    func testParsesSpaceIndentedAndQuotedForms() throws {
        try writeGitConfig("[user]\n    email = \"someone@example.com\"\n")
        XCTAssertEqual(IdentitySeed.gitConfigEmail(home: home), "someone@example.com")
    }

    func testIgnoresEmailOutsideTheUserSection() throws {
        try writeGitConfig("[github]\n\temail = wrong@example.com\n[core]\n\teditor = vim\n")
        XCTAssertNil(IdentitySeed.gitConfigEmail(home: home))
    }

    func testSubsectionedUserHeaderIsNotGuessedAt() throws {
        try writeGitConfig("[user \"work\"]\n\temail = work@example.com\n")
        XCTAssertNil(IdentitySeed.gitConfigEmail(home: home))
    }

    func testNoReplyAliasProducesNoSuggestion() throws {
        try writeGitConfig("[user]\n\temail = 1234+me@users.noreply.github.com\n")
        XCTAssertNil(IdentitySeed.gitConfigEmail(home: home))
    }

    func testMissingFileReturnsNil() {
        XCTAssertNil(IdentitySeed.gitConfigEmail(home: home))
    }

    func testFallsBackToXDGConfigPath() throws {
        let dir = home.appendingPathComponent(".config/git", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "[user]\n\temail = xdg@example.com\n".write(to: dir.appendingPathComponent("config"),
                                                        atomically: true, encoding: .utf8)
        XCTAssertEqual(IdentitySeed.gitConfigEmail(home: home), "xdg@example.com")
    }

    /// The load-bearing one: reading a git config must not be able to write
    /// anything. Nothing unconfirmed can reach identity.json, and therefore
    /// nothing unconfirmed can reach a document.
    func testSeedNeverWritesTheStore() throws {
        try writeGitConfig("[user]\n\temail = someone@example.com\n")
        let root = home.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = IdentityStore(path: root.appendingPathComponent("identity.json"))
        XCTAssertNotNil(IdentitySeed.gitConfigEmail(home: home))
        XCTAssertNil(store.value(.email))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("identity.json").path))
    }
}
