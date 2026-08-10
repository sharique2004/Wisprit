import Foundation

/// "Is this an ordinary word?" — the question that separates a biasing
/// candidate from noise. Wispr Flow's auto-add shipped without this check and
/// filled dictionaries with "sprint" and "deploy"; every consumer in this
/// module rejects a candidate the lexicon recognizes.
public protocol Lexicon: Sendable {
    /// Case-insensitive membership. Implementations lower-case internally, so
    /// callers may pass tokens in their original casing.
    func contains(_ word: String) -> Bool
}

/// Exactly the set it was given — the deterministic lexicon tests use, and the
/// fallback an integration layer can build from `HighFrequencyWords.words`
/// when the system dictionary is unavailable.
public struct FixedLexicon: Lexicon, Sendable {
    private let words: Set<String>

    public init(_ words: Set<String>) {
        self.words = Set(words.map { $0.lowercased() })
    }

    public func contains(_ word: String) -> Bool {
        words.contains(word.lowercased())
    }
}

/// `/usr/share/dict/words` (≈235k entries, ~2.4 MB) unioned with the
/// compiled-in `HighFrequencyWords` list.
///
/// The file is read lazily, ONCE, and always off the calling thread: the first
/// `contains` (or an explicit `prewarm()`, which integration should call when
/// the consent toggle flips on) kicks a utility-QoS load and returns
/// immediately. Until the load lands, queries answer from the compiled-in list
/// alone — a temporarily smaller lexicon only means a temporarily more
/// permissive extractor, never a blocked caller. Thread-safe via one lock
/// around the loaded set.
public final class SystemLexicon: Lexicon, @unchecked Sendable {
    public static let defaultPath = "/usr/share/dict/words"

    private let path: String
    private let lock = NSLock()
    private var systemWords: Set<String> = []
    private var started = false
    private var loaded = false

    public init(path: String = SystemLexicon.defaultPath) {
        self.path = path
    }

    public func contains(_ word: String) -> Bool {
        startLoadIfNeeded()  // first query of ANY kind kicks the one-time load
        let key = word.lowercased()
        if HighFrequencyWords.words.contains(key) { return true }
        lock.lock()
        defer { lock.unlock() }
        return systemWords.contains(key)
    }

    /// Start the one-time load without waiting for it. Call at consent time so
    /// the dictionary is warm before the first utterance needs it.
    public func prewarm() {
        startLoadIfNeeded()
    }

    private func startLoadIfNeeded() {
        lock.lock()
        if started {
            lock.unlock()
            return
        }
        started = true
        lock.unlock()
        let path = self.path
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var parsed: Set<String> = []
            if let contents = try? String(contentsOfFile: path, encoding: .utf8) {
                parsed.reserveCapacity(250_000)
                contents.enumerateLines { line, _ in
                    if !line.isEmpty { parsed.insert(line.lowercased()) }
                }
            }
            guard let self else { return }
            self.lock.lock()
            self.systemWords = parsed
            self.loaded = true
            self.lock.unlock()
        }
    }

    /// Test hook: true once the file read has finished (successfully or not).
    func waitUntilLoaded(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            lock.lock()
            let done = loaded
            lock.unlock()
            if done { return true }
            usleep(5_000)
        }
        return false
    }
}
