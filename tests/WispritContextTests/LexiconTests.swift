import XCTest

@testable import WispritContext

final class LexiconTests: XCTestCase {

    // MARK: - FixedLexicon

    func testFixedLexiconIsCaseInsensitiveBothWays() {
        let lexicon = FixedLexicon(["Sprint", "deploy"])
        XCTAssertTrue(lexicon.contains("sprint"))
        XCTAssertTrue(lexicon.contains("SPRINT"))
        XCTAssertTrue(lexicon.contains("Deploy"))
        XCTAssertFalse(lexicon.contains("Zorblatt"))
    }

    func testFixedLexiconIsDeterministic() {
        let lexicon = FixedLexicon(HighFrequencyWords.words)
        let probes = ["sprint", "deploy", "standup", "Quixly", "InsForge", "func", "const"]
        let first = probes.map(lexicon.contains)
        for _ in 0..<10 {
            XCTAssertEqual(probes.map(lexicon.contains), first)
        }
    }

    // MARK: - The compiled-in list

    /// The words Wispr Flow's ungated auto-add famously over-learned must all
    /// read as ordinary, along with keyword-class dev vocabulary.
    func testHighFrequencyListCoversTheNegativeSpec() {
        for word in ["sprint", "deploy", "standup", "backlog", "merge", "commit",
                     "func", "guard", "const", "typeof", "meeting", "well", "known"] {
            XCTAssertTrue(HighFrequencyWords.words.contains(word), word)
        }
        XCTAssertGreaterThan(HighFrequencyWords.words.count, 500)
        // And it must NOT contain the proper-noun shapes tests accept.
        for word in ["insforge", "sharique", "wisprit", "quixly"] {
            XCTAssertFalse(HighFrequencyWords.words.contains(word), word)
        }
    }

    // MARK: - SystemLexicon

    private func temporaryWordFile(_ contents: String) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wisprit-lexicon-\(UUID().uuidString).txt")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url.path
    }

    func testSystemLexiconAnswersFromEmbeddedListBeforeLoadAndFileAfter() throws {
        let path = try temporaryWordFile("flibbertigibbet\nZyzzogeton\n")
        let lexicon = SystemLexicon(path: path)
        // Embedded floor is available synchronously, load or no load.
        XCTAssertTrue(lexicon.contains("sprint"))
        XCTAssertTrue(lexicon.waitUntilLoaded(timeout: 5.0), "file load never finished")
        XCTAssertTrue(lexicon.contains("flibbertigibbet"))
        XCTAssertTrue(lexicon.contains("ZYZZOGETON"), "file words compare case-insensitively")
        XCTAssertFalse(lexicon.contains("Quixly"))
    }

    func testSystemLexiconSurvivesAMissingFile() {
        let lexicon = SystemLexicon(path: "/nonexistent/wisprit-no-such-file")
        XCTAssertTrue(lexicon.contains("sprint"))
        XCTAssertTrue(lexicon.waitUntilLoaded(timeout: 5.0), "failed load still completes")
        XCTAssertFalse(lexicon.contains("flibbertigibbet"))
    }

    func testSystemLexiconIsSafeUnderConcurrentQueries() throws {
        let path = try temporaryWordFile((0..<5_000).map { "word\($0)" }.joined(separator: "\n"))
        let lexicon = SystemLexicon(path: path)
        DispatchQueue.concurrentPerform(iterations: 200) { i in
            _ = lexicon.contains("sprint")
            _ = lexicon.contains("word\(i % 5_000)")
        }
        XCTAssertTrue(lexicon.waitUntilLoaded(timeout: 5.0))
        XCTAssertTrue(lexicon.contains("word4999"))
    }
}
