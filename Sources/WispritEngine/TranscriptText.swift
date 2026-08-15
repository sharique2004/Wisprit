import Foundation

/// Content-only comparison of two readings of the same audio.
///
/// Two places in the engine layer have to ask "did this text already say that?"
/// — the last-partial salvage in `SpeechAnalyzerEngine.finalize` and the
/// streaming-vs-batch choice in `AsrManager.rescue` — and both of them are
/// comparing output from recognizers that punctuate and capitalize differently
/// (the batch pass runs with `transcriptionOptions: []`; the live one is cut
/// mid-sentence by its deadline). Comparing raw strings therefore answers a
/// question nobody asked. This normalizes to words and nothing else.
enum TranscriptText {

    /// Lowercased words with punctuation and symbols removed. Everything else —
    /// digits, accents, non-Latin scripts — is left alone: this is a
    /// *comparison* helper, never a rewriting one, and nothing it returns is
    /// ever shown to the user.
    static func words(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.punctuationCharacters.union(.symbols))
            .joined(separator: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
    }

    /// Does `text` already END with `tail`, word for word?
    ///
    /// A SUFFIX test, not a containment test, and the difference is a measured
    /// data-loss bug: the salvage path used `text.contains(tail)`, so a trailing
    /// volatile of "and" — or "the", or a name said twice — was thrown away
    /// whenever that word had occurred anywhere earlier in the utterance. That
    /// discarded genuinely new words on the timeout/crash path, which is exactly
    /// the path where they are the only words left.
    static func isSuffix(_ tail: String, of text: String) -> Bool {
        let tailWords = words(tail)
        guard !tailWords.isEmpty else { return true }   // nothing to add
        let textWords = words(text)
        guard textWords.count >= tailWords.count else { return false }
        return Array(textWords.suffix(tailWords.count)) == tailWords
    }

    /// `text` with `tail` appended, unless `tail` is already its ending.
    /// The APPENDED form is the original `tail`, not the normalized one — the
    /// normalization decides, it never edits what the user sees.
    static func appendingTail(_ tail: String, to text: String) -> String {
        let trimmedTail = tail.trimmingCharacters(in: .whitespaces)
        guard !trimmedTail.isEmpty, !isSuffix(trimmedTail, of: text) else { return text }
        return (text + " " + trimmedTail).trimmingCharacters(in: .whitespaces)
    }
}
