import Foundation

/// Word-level difference between what the recognizer heard and what Wisprit
/// wrote — the Dictations inspector's Heard | Written toggle.
///
/// A word is a run of non-whitespace, punctuation included, compared exactly:
/// "slack" → "Slack" and "it's...." → "it's... ." are changes, because they
/// are changes the user can see in their document. The whitespace after each
/// word travels with it, so joining the segments of either side gives back
/// that side's text byte for byte.
///
/// Classic longest-common-subsequence over the words, after trimming the
/// common prefix and suffix (a dictation is mostly unchanged, so the table is
/// usually tiny). A middle too large to table is marked changed wholesale
/// rather than paying a quadratic on the main thread.
public enum WordDiff {

    /// One run of text and whether it is part of a change.
    public struct Segment: Equatable, Sendable {
        public var text: String
        public var changed: Bool

        public init(_ text: String, changed: Bool) {
            self.text = text
            self.changed = changed
        }
    }

    public struct Result: Equatable, Sendable {
        /// The heard text: changed segments are words cleanup removed or replaced.
        public var heard: [Segment]
        /// The written text: changed segments are words cleanup added or replaced.
        public var written: [Segment]
        /// Edits as a reader counts them: a replaced run, an inserted run and a
        /// removed run each count once, however many words they span.
        public var changeCount: Int

        public var isUnchanged: Bool { changeCount == 0 }
    }

    /// Above this many words in the differing middle, skip the table.
    public static let tableLimit = 1_500

    public static func diff(heard: String, written: String) -> Result {
        let a = tokens(heard)
        let b = tokens(written)
        let aw = a.map(\.word)
        let bw = b.map(\.word)

        var prefix = 0
        while prefix < aw.count, prefix < bw.count, aw[prefix] == bw[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < aw.count - prefix, suffix < bw.count - prefix,
              aw[aw.count - 1 - suffix] == bw[bw.count - 1 - suffix] { suffix += 1 }

        let aMid = Array(aw[prefix..<(aw.count - suffix)])
        let bMid = Array(bw[prefix..<(bw.count - suffix)])

        // true = kept (common), per word, for each side.
        var keepA = Array(repeating: true, count: aw.count)
        var keepB = Array(repeating: true, count: bw.count)
        if aMid.count > tableLimit || bMid.count > tableLimit {
            for i in prefix..<(aw.count - suffix) { keepA[i] = false }
            for j in prefix..<(bw.count - suffix) { keepB[j] = false }
        } else {
            let (ka, kb) = lcsKeep(aMid, bMid)
            for (offset, kept) in ka.enumerated() { keepA[prefix + offset] = kept }
            for (offset, kept) in kb.enumerated() { keepB[prefix + offset] = kept }
        }

        return Result(heard: segments(a, keep: keepA),
                      written: segments(b, keep: keepB),
                      changeCount: changeCount(keepA: keepA, keepB: keepB, a: aw, b: bw))
    }

    // MARK: - tokens

    struct Token: Equatable {
        /// The word itself, no whitespace.
        var word: String
        /// Whitespace before the first word (only ever on token 0) plus the
        /// word plus the whitespace after it — the exact source text.
        var source: String
    }

    static func tokens(_ text: String) -> [Token] {
        var out: [Token] = []
        var leading = ""
        var word = ""
        var trailing = ""
        func flush() {
            guard !word.isEmpty else { return }
            out.append(Token(word: word, source: leading + word + trailing))
            leading = ""; word = ""; trailing = ""
        }
        for character in text {
            if character.isWhitespace || character.isNewline {
                if word.isEmpty { leading.append(character) } else { trailing.append(character) }
            } else {
                if !trailing.isEmpty { flush() }
                word.append(character)
            }
        }
        flush()
        if out.isEmpty, !leading.isEmpty {
            // Whitespace only: keep it so the side still round-trips.
            out.append(Token(word: "", source: leading))
        } else if !leading.isEmpty, let last = out.indices.last {
            out[last].source += leading
        }
        return out
    }

    // MARK: - LCS

    private static func lcsKeep(_ a: [String], _ b: [String]) -> ([Bool], [Bool]) {
        let n = a.count, m = b.count
        var keepA = Array(repeating: false, count: n)
        var keepB = Array(repeating: false, count: m)
        guard n > 0, m > 0 else { return (keepA, keepB) }
        // lengths[i][j] = LCS of a[i...] and b[j...], flattened.
        var lengths = Array(repeating: 0, count: (n + 1) * (m + 1))
        let width = m + 1
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                lengths[i * width + j] = a[i] == b[j]
                    ? lengths[(i + 1) * width + j + 1] + 1
                    : max(lengths[(i + 1) * width + j], lengths[i * width + j + 1])
            }
        }
        var i = 0, j = 0
        while i < n, j < m {
            if a[i] == b[j] {
                keepA[i] = true; keepB[j] = true
                i += 1; j += 1
            } else if lengths[(i + 1) * width + j] >= lengths[i * width + j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return (keepA, keepB)
    }

    // MARK: - output

    /// Adjacent tokens with the same status merge into one segment. A change
    /// does not underline the space after its last word: the run ends on the
    /// word, and the gap is handed to whatever follows.
    private static func segments(_ tokens: [Token], keep: [Bool]) -> [Segment] {
        var out: [Segment] = []
        func append(_ text: String, changed: Bool) {
            guard !text.isEmpty else { return }
            if let last = out.last, last.changed == changed {
                out[out.count - 1].text += text
            } else {
                out.append(Segment(text, changed: changed))
            }
        }
        for (index, token) in tokens.enumerated() {
            let changed = !keep[index]
            guard changed else { append(token.source, changed: false); continue }
            // Split the token into leading-space, word, trailing-space so the
            // underline covers the word only.
            let source = token.source
            guard let wordRange = source.range(of: token.word), !token.word.isEmpty else {
                append(source, changed: false)
                continue
            }
            append(String(source[source.startIndex..<wordRange.lowerBound]), changed: false)
            append(String(source[wordRange]), changed: true)
            append(String(source[wordRange.upperBound...]), changed: false)
        }
        // A changed run followed by a single space then another changed run
        // reads as one change: fold the space into it.
        var folded: [Segment] = []
        for segment in out {
            if segment.changed, folded.count >= 2,
               folded[folded.count - 1].changed == false,
               folded[folded.count - 1].text.allSatisfy({ $0 == " " }),
               folded[folded.count - 2].changed {
                let gap = folded.removeLast()
                folded[folded.count - 1].text += gap.text + segment.text
            } else {
                folded.append(segment)
            }
        }
        return folded
    }

    /// Walk both keep-masks in step: every maximal stretch where either side
    /// has unkept words between two common words is one edit.
    private static func changeCount(keepA: [Bool], keepB: [Bool], a: [String], b: [String]) -> Int {
        var count = 0
        var i = 0, j = 0
        while i < keepA.count || j < keepB.count {
            var moved = false
            while i < keepA.count, !keepA[i] { i += 1; moved = true }
            while j < keepB.count, !keepB[j] { j += 1; moved = true }
            if moved { count += 1 }
            // Step past one common pair.
            if i < keepA.count, j < keepB.count { i += 1; j += 1 }
            else if i < keepA.count { i += 1 }
            else if j < keepB.count { j += 1 }
        }
        return count
    }
}
