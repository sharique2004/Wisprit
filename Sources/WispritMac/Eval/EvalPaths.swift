#if os(macOS)
import CryptoKit
import Foundation

/// Where the harness reads and writes, and what it names things.
///
/// Split out of the runner because every one of these is a pure function of its
/// inputs: an artifact name is part of the scoreboard's contract with git (which
/// files are committed, which are gitignored detail), and a cache key is the
/// only thing standing between a re-run and a stale transcript. Both are worth a
/// test that does not need a filesystem.
enum EvalPaths {

    // MARK: - the checkout

    /// The repo this binary was built from.
    ///
    /// `#filePath` first, exactly as the tests do (`PromptLockTests`): a dev
    /// tool that reads `tools/eval` and appends to `docs/eval` is only ever run
    /// against the checkout it was compiled in, and the source path is the one
    /// locator that survives being run from any working directory or from
    /// inside `Wisprit.app`. `WISPRIT_EVAL_ROOT` overrides it for a copied
    /// checkout; the current directory is the last resort.
    static func repoRoot(environment: [String: String] = ProcessInfo.processInfo.environment,
                         currentDirectory: String = FileManager.default.currentDirectoryPath)
        -> URL? {
        if let raw = environment["WISPRIT_EVAL_ROOT"], !raw.isEmpty {
            let url = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath,
                          isDirectory: true)
            return isCheckout(url) ? url : nil
        }
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Eval
            .deletingLastPathComponent()   // WispritMac
            .deletingLastPathComponent()   // Sources
            .deletingLastPathComponent()   // repo root
        if isCheckout(source) { return source }
        return walkUp(from: URL(fileURLWithPath: currentDirectory, isDirectory: true))
    }

    /// A directory is the checkout when it holds the package manifest AND the
    /// corpora — the harness needs both, and failing here beats failing later
    /// with "manifest not found" from somewhere plausible-looking.
    static func isCheckout(_ url: URL) -> Bool {
        let manager = FileManager.default
        return manager.fileExists(atPath: url.appendingPathComponent("Package.swift").path)
            && manager.fileExists(atPath: url.appendingPathComponent("tools/eval").path)
    }

    static func walkUp(from start: URL) -> URL? {
        var url = start.standardizedFileURL
        while url.path != "/" {
            if isCheckout(url) { return url }
            url = url.deletingLastPathComponent()
        }
        return nil
    }

    // MARK: - locations

    static func corpusDir(root: URL, corpus: String) -> URL {
        root.appendingPathComponent("tools/eval/corpus/\(corpus)", isDirectory: true)
    }

    static func manifest(root: URL, corpus: String) -> URL {
        corpusDir(root: root, corpus: corpus).appendingPathComponent("manifest.jsonl")
    }

    /// The dictionary the replay loads. Deliberately a repo fixture and never
    /// `~/.wisprit/dictionary.json`: a scoreboard row has to be reproducible on
    /// another machine, and the user's dictionary changes under their hands
    /// (that is the whole point of the learn loop).
    static func dictionaryFixture(root: URL) -> URL {
        root.appendingPathComponent("tools/eval/fixtures/eval-dictionary.json")
    }

    static func evalDocs(root: URL) -> URL {
        root.appendingPathComponent("docs/eval", isDirectory: true)
    }

    static func results(root: URL) -> URL {
        evalDocs(root: root).appendingPathComponent("RESULTS.md")
    }

    static func baseline(root: URL) -> URL {
        evalDocs(root: root).appendingPathComponent("BASELINE.json")
    }

    static func runs(root: URL) -> URL {
        evalDocs(root: root).appendingPathComponent("runs", isDirectory: true)
    }

    // MARK: - artifact names

    /// Per-utterance artifacts all end in `.detail.jsonl`, which is the one
    /// gitignore rule that covers them — the aggregates are committed, the
    /// transcripts are not.
    static func asrDetailName(corpus: String, engine: String, settingsHash: String) -> String {
        "asr.\(corpus).\(engine).\(settingsHash).detail.jsonl"
    }

    /// The ASR cache. Same records as the file above plus the audio sha they
    /// were produced from, which `StageRecord` has no field for — so it is a
    /// second file rather than a schema the eval library does not own.
    static func asrCacheName(corpus: String, engine: String, settingsHash: String) -> String {
        "asr.\(corpus).\(engine).\(settingsHash).cache.detail.jsonl"
    }

    static func stagesDetailName(corpus: String, engine: String, config: String) -> String {
        "stages.\(corpus).\(engine).\(slug(config)).detail.jsonl"
    }

    static func runSummaryName(stamp: String, corpus: String, engine: String,
                               config: String) -> String {
        "\(stamp).\(corpus).\(engine).\(slug(config)).json"
    }

    /// `refine=on,dict=off` → `refine-on.dict-off`. The config string itself is
    /// the scoreboard's identity and must not be reshaped; this is only how it
    /// spells itself as a filename.
    static func slug(_ config: String) -> String {
        config.replacingOccurrences(of: "=", with: "-")
            .replacingOccurrences(of: ",", with: ".")
    }

    /// A filesystem- and URL-safe instant: `2026-08-09T201402Z`.
    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    // MARK: - keys

    /// The ASR cache key. Three components, joined readably rather than hashed
    /// again: a stale cache line is something a human debugs by reading the
    /// file, and `9f3c…a1.apple_live.4d2b0c19` says why it did not match.
    ///
    /// The audio sha comes from the manifest, so a re-recorded take invalidates
    /// its own line without anyone remembering to clear a cache.
    static func cacheKey(audioSha256: String, engine: String, settingsHash: String) -> String {
        "\(audioSha256).\(engine).\(settingsHash)"
    }

    /// Everything about the recognizer configuration that can move a transcript.
    /// Anything not listed here is asserted to be irrelevant to the text — add a
    /// field and every cached transcript is correctly invalidated.
    static func settingsHash(locale: String, engine: String, finalizeTimeoutMs: Double,
                             contextualTermLimit: Int?) -> String {
        let material = [
            "locale=\(locale)",
            "engine=\(engine)",
            "finalize_timeout_ms=\(Int(finalizeTimeoutMs))",
            "contextual_term_limit=\(contextualTermLimit.map(String.init) ?? "all")",
        ].joined(separator: "|")
        return String(sha256Hex(Data(material.utf8)).prefix(8))
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256Hex(_ text: String) -> String { sha256Hex(Data(text.utf8)) }
}
#endif
