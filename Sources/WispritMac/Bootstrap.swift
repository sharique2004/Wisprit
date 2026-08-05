import Foundation
import WispritKit
import WispritPersistence

/// First-run state bootstrap — port of `wisprit/bootstrap.py`.
///
/// Creates `~/.wisprit` (0700; transcripts are personal) and seeds it with a
/// default `config.json` and a starter `dictionary.json`. Strictly
/// non-destructive: a file that already exists is never touched, so user edits
/// — and everything the Python era wrote into the same directory — survive
/// every launch.
///
/// The config seed comes from `Settings.defaults` serialized with
/// `WispritJSON.serializePretty`, so the shipped defaults live in exactly one
/// place. (The Python carried a hand-copied duplicate as a fallback for a
/// broken `settings` module; a Swift target that fails to link cannot run at
/// all, so the duplicate has no reason to exist here.)
public enum Bootstrap {

    /// Starter vocabulary — names SpeechAnalyzer is likely to fumble.
    /// `term` biases recognition; `hear` entries become post-ASR word-boundary
    /// corrections. Deliberately conservative: no `hear` entry collides with a
    /// common English word. Byte-for-byte `bootstrap._SEED_TERMS`.
    static let seedTerms: [(term: String, hear: [String])] = [
        ("Wisprit", ["whisper it", "wisp rit"]),
        ("Wispr Flow", ["whisper flow", "wisper flow"]),
        ("InsForge", ["in forge", "ins forge"]),
        ("MeetingScribe", ["meeting scribe"]),
        ("Claude", ["clod"]),
        ("Anthropic", ["and thropic", "anthropik"]),
        ("MLX", ["m l x", "em el ex"]),
        ("Sharique", ["shariq", "sharik", "shreek"]),
        ("Khatri", ["katri", "kathri"]),
        ("hackathon", ["hacker thought", "hacker thoughts",
                       "hack a thon", "hackerthon", "hacker thon"]),
        ("Penn State", ["pen state", "penn state university"]),
    ]

    /// What a bootstrap run actually did — reported by `wisprit bootstrap`.
    public struct Report: Equatable, Sendable {
        public var stateDir: URL
        public var wroteConfig: Bool
        public var wroteDictionary: Bool
    }

    /// Idempotent. Returns which files it had to create.
    @discardableResult
    public static func ensureStateDir() throws -> Report {
        try WispritPaths.ensureStateDir()
        // ensureStateDir only sets the mode at creation time; an existing dir
        // from an older build may be 0755. Personal transcripts live here.
        try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                               ofItemAtPath: WispritPaths.stateDir.path)

        var wroteConfig = false
        if !FileManager.default.fileExists(atPath: WispritPaths.configPath.path) {
            try writeSeed(defaultConfigJSON(), to: WispritPaths.configPath)
            wroteConfig = true
        }

        var wroteDictionary = false
        if !FileManager.default.fileExists(atPath: WispritPaths.dictionaryPath.path) {
            try writeSeed(seedDictionaryJSON(), to: WispritPaths.dictionaryPath)
            wroteDictionary = true
        }

        return Report(stateDir: WispritPaths.stateDir,
                      wroteConfig: wroteConfig,
                      wroteDictionary: wroteDictionary)
    }

    private static func writeSeed(_ text: String, to url: URL) throws {
        try AtomicWrite.write(text, to: url)
    }

    /// The exact bytes a fresh `config.json` gets — the shipped defaults, in
    /// declaration order, pretty-printed with a trailing newline.
    public static func defaultConfigJSON() -> String {
        WispritJSON.serializePretty(.object(Settings.defaults)) + "\n"
    }

    /// The exact bytes a fresh `dictionary.json` gets.
    public static func seedDictionaryJSON() -> String {
        let terms = seedTerms.map { seed -> SettingValue in
            .object(JSONObject([
                ("term", .string(seed.term)),
                ("hear", .array(seed.hear.map { .string($0) })),
            ]))
        }
        return WispritJSON.serializePretty(.object(JSONObject([
            ("terms", .array(terms)),
        ]))) + "\n"
    }
}
