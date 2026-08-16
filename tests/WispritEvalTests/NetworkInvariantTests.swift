import XCTest

/// Wisprit's headline promise is that nothing leaves the machine. Until now
/// that promise had no test — it was a property of everyone remembering.
///
/// This scans every file under `Sources/` for the ways a Swift target can talk
/// to a network and fails with the file and line of anything that is not
/// explicitly allowlisted. Comments are stripped first (Swift-aware, so a `//`
/// inside a string literal is not mistaken for a comment) — documentation links
/// are prose, not traffic.
///
/// When a future target genuinely needs the network — the Parakeet model
/// download is the only planned one — it goes on the allowlist BELOW, with a
/// rationale, and the code lives in exactly one file.
final class NetworkInvariantTests: XCTestCase {

    /// APIs and literals that mean "this file can reach the network".
    static let forbidden = ["URLSession", "URLRequest", "NWConnection",
                            "http://", "https://"]

    /// A repo-relative path that is allowed to contain specific tokens, and why.
    /// Code hits belong here ONLY when they are provably non-networking.
    struct Allowance {
        let path: String
        let tokens: Set<String>
        let reason: String
    }

    static let allowlist: [Allowance] = [
        // The generated input-method Info.plist carries Apple's PLIST DOCTYPE
        // line, whose public identifier is a `http://www.apple.com/DTDs/…` URL.
        // It is a *name*, never fetched: property lists are parsed offline by
        // the system, and this file contains no networking API at all — it only
        // builds strings and writes them into a bundle.
        Allowance(path: "Sources/WispritIMProtocol/IMBundleTemplate.swift",
                  tokens: ["http://"],
                  reason: "PLIST DOCTYPE public identifier in a generated Info.plist"),
        // The identity fields normalize a typed-in profile URL to a canonical
        // form. `https://` here is a SCHEME PREFIX being written into a string
        // the user's document will receive — the value's whole job is to
        // autolink once pasted. Nothing fetches it: the file contains no
        // networking API, only `URL(string:)` for structural validation
        // (scheme/host/path segments), which performs no I/O.
        Allowance(path: "Sources/WispritDictionary/IdentityStore.swift",
                  tokens: ["https://"],
                  reason: "URL scheme prefix for a value that is TYPED, never fetched"),
        // The ONE planned runtime network call (Phase 6, spikes-parakeet.md):
        // the explicit, user-invoked Parakeet model download. Pinned HF assets
        // verified byte-for-byte against a SHA-256 manifest before any
        // FluidAudio load may run; WISPRIT_NO_NETWORK=1 hard-refuses before
        // the fetcher is asked; nothing else in the target — or the package —
        // may touch the network. WispritParakeet is not linked into WispritMac,
        // so today this code cannot even ride in the shipped binary.
        Allowance(path: "Sources/WispritParakeet/ParakeetModelStore.swift",
                  tokens: ["URLSession", "https://"],
                  reason: "explicit user-invoked Parakeet model download, "
                      + "SHA-256-manifest-verified, WISPRIT_NO_NETWORK-guarded"),
    ]

    // MARK: - the invariant

    func testSourcesMakeNoNetworkCalls() throws {
        let hits = try Self.scanSources(applyingAllowlist: true)
        XCTAssertTrue(hits.isEmpty,
                      "Wisprit makes zero network calls. Un-allowlisted hits:\n"
                          + hits.joined(separator: "\n"))
    }

    /// A stale allowlist is a hole. Every entry must still correspond to a real
    /// hit — and this doubles as an end-to-end check that the comment stripper
    /// keeps string literals, since that is the only reason the entry exists.
    func testAllowlistEntriesAreStillLoadBearing() throws {
        let all = try Self.scanSources(applyingAllowlist: false)
        for allowance in Self.allowlist {
            for token in allowance.tokens {
                XCTAssertTrue(all.contains { $0.hasPrefix(allowance.path + ":")
                                  && $0.contains("'\(token)'") },
                              "allowlist entry is stale: \(allowance.path) no longer "
                                  + "contains '\(token)' (\(allowance.reason))")
            }
        }
    }

    func testScanActuallyReachesTheSources() throws {
        let root = try Self.repoRoot()
        let files = try Self.swiftFiles(under: root.appendingPathComponent("Sources"))
        XCTAssertGreaterThan(files.count, 50, "the scan found almost nothing to read")
    }

    // MARK: - the scanner

    static func repoRoot() throws -> URL {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // WispritEvalTests
            .deletingLastPathComponent()   // tests
            .deletingLastPathComponent()   // repo root
        guard FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Sources").path) else {
            throw XCTSkip("Sources/ not in this checkout")
        }
        return root
    }

    static func swiftFiles(under directory: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]) else { return [] }
        var out: [URL] = []
        for case let url as URL in enumerator {
            let regular = (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile
            if regular == true { out.append(url) }
        }
        return out.sorted { $0.path < $1.path }
    }

    /// Returns "path:line: forbidden 'token'" for every match.
    static func scanSources(applyingAllowlist: Bool) throws -> [String] {
        let root = try repoRoot()
        let prefix = root.standardizedFileURL.path + "/"
        var hits: [String] = []
        for url in try swiftFiles(under: root.appendingPathComponent("Sources")) {
            guard let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let path = url.standardizedFileURL.path.replacingOccurrences(of: prefix, with: "")
            // Comments are stripped only for Swift; any other file is scanned raw.
            let lines = url.pathExtension == "swift"
                ? strippingComments(source)
                : source.components(separatedBy: "\n")
            for (offset, line) in lines.enumerated() {
                for token in forbidden where line.contains(token) {
                    if applyingAllowlist, isAllowed(path: path, token: token) { continue }
                    hits.append("\(path):\(offset + 1): forbidden '\(token)'")
                }
            }
        }
        return hits
    }

    static func isAllowed(path: String, token: String) -> Bool {
        allowlist.contains { $0.path == path && $0.tokens.contains(token) }
    }

    /// Blank out comments while preserving line numbering and — critically —
    /// string literals, including raw (`#"…"#`) and multi-line (`"""`) ones. A
    /// naive stripper would treat the `//` inside `"http://…"` as a comment and
    /// hide everything after it on that line.
    static func strippingComments(_ source: String) -> [String] {
        let chars = Array(source)
        var out = ""
        out.reserveCapacity(chars.count)
        var i = 0
        var blockDepth = 0
        var inLineComment = false
        var stringHashes: Int?
        var stringIsMultiline = false

        func peek(_ offset: Int) -> Character? {
            let j = i + offset
            return j < chars.count ? chars[j] : nil
        }
        /// A closing delimiter: `count` quotes followed by `hashes` pound signs.
        func closes(quotes count: Int, hashes: Int) -> Bool {
            for k in 0..<count where peek(k) != "\"" { return false }
            for k in 0..<hashes where peek(count + k) != "#" { return false }
            return true
        }

        while i < chars.count {
            let c = chars[i]

            if inLineComment {
                if c == "\n" { inLineComment = false; out.append("\n") } else { out.append(" ") }
                i += 1
                continue
            }

            if blockDepth > 0 {
                // Swift block comments nest.
                if c == "/", peek(1) == "*" { blockDepth += 1; out += "  "; i += 2; continue }
                if c == "*", peek(1) == "/" { blockDepth -= 1; out += "  "; i += 2; continue }
                out.append(c == "\n" ? "\n" : " ")
                i += 1
                continue
            }

            if let hashes = stringHashes {
                // Only a non-raw literal has backslash escapes.
                if hashes == 0, c == "\\", let next = peek(1) {
                    out.append(c); out.append(next); i += 2; continue
                }
                let quotes = stringIsMultiline ? 3 : 1
                if c == "\"", closes(quotes: quotes, hashes: hashes) {
                    out += String(repeating: "\"", count: quotes)
                    out += String(repeating: "#", count: hashes)
                    i += quotes + hashes
                    stringHashes = nil
                    continue
                }
                out.append(c)
                i += 1
                continue
            }

            if c == "/", peek(1) == "/" { inLineComment = true; out += "  "; i += 2; continue }
            if c == "/", peek(1) == "*" { blockDepth = 1; out += "  "; i += 2; continue }

            // A string opener, with any number of raw-string pound signs.
            var hashes = 0
            while peek(hashes) == "#" { hashes += 1 }
            if peek(hashes) == "\"" {
                let multiline = peek(hashes + 1) == "\"" && peek(hashes + 2) == "\""
                let quotes = multiline ? 3 : 1
                stringHashes = hashes
                stringIsMultiline = multiline
                for k in 0..<(hashes + quotes) { out.append(chars[i + k]) }
                i += hashes + quotes
                continue
            }

            out.append(c)
            i += 1
        }
        return out.components(separatedBy: "\n")
    }

    // MARK: - the scanner's own tests

    func testStripperRemovesCommentsButKeepsStringLiterals() {
        let sample = """
            // https://example.invalid/docs — prose, not traffic
            let a = "keep http://in-a-string"
            /* https://example.invalid/block
               /* nested */ still a comment https://example.invalid/nested */
            let b = #"raw http://in-a-raw-string"#
            let c = \"""
            multi https://in-a-multiline "quoted" inside
            \"""
            let d = 1 // trailing https://example.invalid
            """
        let lines = NetworkInvariantTests.strippingComments(sample)
        XCTAssertEqual(lines.count, 9)
        XCTAssertFalse(lines[0].contains("https://"), lines[0])
        XCTAssertTrue(lines[1].contains("http://in-a-string"), lines[1])
        XCTAssertFalse(lines[2].contains("https://"), lines[2])
        XCTAssertFalse(lines[3].contains("https://"), lines[3])
        XCTAssertTrue(lines[4].contains("http://in-a-raw-string"), lines[4])
        XCTAssertTrue(lines[6].contains("https://in-a-multiline"), lines[6])
        XCTAssertTrue(lines[8].contains("let d = 1"), lines[8])
        XCTAssertFalse(lines[8].contains("https://"), lines[8])
    }
}
