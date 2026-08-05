import Foundation
import WispritKit

/// One spoken-spelling run as the ASR actually emitted it.
///
/// Offsets are CHARACTER offsets into the utterance the run was found in, so a
/// caller can splice without re-deriving indices.
public struct LetterRun: Equatable, Sendable {
    /// Exactly as transcribed, e.g. "S-HA-R-I-Q-U-E".
    public let raw: String
    /// Separators stripped, e.g. "SHARIQUE".
    public let collapsed: String
    /// The run itself.
    public let range: Range<Int>
    /// Trigger phrase found in the ~45 characters before the run, lowercased.
    /// A confidence booster — never a gate (research: "that's spelled" came
    /// back from the ASR as "Let's spell").
    public let trigger: String?
    /// Trigger start through run end; equals `range` when there is no trigger.
    public let directiveRange: Range<Int>
    /// The run is the last thing in the utterance, bar whitespace/punctuation.
    public let isTail: Bool
    /// At least one separator was a hyphen or a dot rather than a space.
    public let isDelimited: Bool
}

/// Finds spoken letter runs in a RAW ASR final.
///
/// Detection keys on UPPERCASE, not on hyphens. The verification pass over the
/// research measured 13 probes across 7 voices and 2 rates: the separator is
/// unstable ("S-H-A-R-I-Q-U-E", "S-HA-R-I-Q-U-E", "S H-A-R-I-Q-U-E") and
/// DictationTranscriber does not hyphenate at all, but every probe returned the
/// run as an all-caps token. Runs must be read off FINAL results only —
/// partials carry an unsettled form ("SH- A-R-IQ UE").
public struct LetterRunDetector {

    /// Longest observed glued segment was 3 ("KRZ-Y-S-Z-T-O-F"); 4 leaves head-room
    /// without letting ordinary all-caps words in.
    public static let maxSegmentLength = 4
    /// Two segments is "US GDP"; three is a spelling.
    public static let minSegmentCount = 3
    /// COVID-19 and two-letter initials fall out below this.
    public static let minCollapsedLength = 3
    /// Research: the trigger regex runs over the 45 characters preceding the run.
    public static let triggerWindow = 45

    /// Exactly the phrases the research measured as surviving transcription.
    /// Deliberately NOT widened to bare "spell" — "Let's spell J-O-N" is the
    /// ASR mangling "that's spelled", and treating it as intent would let a
    /// mis-transcription authorise a retro-edit.
    static let triggerPattern =
        #"\b(actually|no,?\s+no|correction|it'?s\s+spelled|spell\s+that|i\s+mean|sorry,?\s+it'?s)\b"#

    private static let triggerRegex = try! NSRegularExpression(
        pattern: triggerPattern, options: [.caseInsensitive])

    private let vocabulary: (any VocabularySource)?

    public init(vocabulary: (any VocabularySource)? = nil) {
        self.vocabulary = vocabulary
    }

    /// Cheap predicate for the refine bypass (the LLM stage corrupts spelled
    /// runs — "S-H-A-R-I-Q-U-E" → "Sharifue", deterministically).
    public func containsLetterRun(_ text: String) -> Bool { !detect(in: text).isEmpty }

    public func detect(in text: String) -> [LetterRun] {
        let chars = Array(text)
        var runs: [LetterRun] = []
        var index = 0
        while index < chars.count {
            guard Self.isUppercaseLetter(chars[index]) else {
                index += 1
                continue
            }
            // Never start mid-token: "McDONALD" must not yield "DONALD".
            if index > 0 && Self.isWordCharacter(chars[index - 1]) {
                index += 1
                continue
            }
            guard let parsed = Self.parseRun(chars, from: index) else {
                index += 1
                continue
            }
            let collapsed = parsed.segments.joined()
            index = parsed.end
            // Already a known term? Then it is content, not a directive.
            if vocabulary?.isKnownTerm(collapsed) == true { continue }

            let runRange = parsed.start..<parsed.end
            let (trigger, triggerStart) = Self.findTrigger(chars, before: parsed.start)
            runs.append(
                LetterRun(
                    raw: String(chars[runRange]),
                    collapsed: collapsed,
                    range: runRange,
                    trigger: trigger,
                    directiveRange: (triggerStart ?? parsed.start)..<parsed.end,
                    isTail: Self.isTail(chars, after: parsed.end),
                    isDelimited: parsed.isDelimited))
        }
        return runs
    }

    // MARK: - Run grammar

    private struct ParsedRun {
        let start: Int
        let end: Int
        let segments: [String]
        let isDelimited: Bool
    }

    /// Maximal separator width. Covers the ". " the ASR leaves between dictated
    /// letters; anything wider is a sentence gap, not a spelling.
    private static let maxSeparatorLength = 2

    private static func parseRun(_ chars: [Character], from start: Int) -> ParsedRun? {
        var segments: [String] = []
        var cursor = start
        var end = start
        var isDelimited = false

        while true {
            let segmentEnd = scanSegment(chars, from: cursor)
            let length = segmentEnd - cursor
            guard length >= 1, length <= maxSegmentLength else { return nil }
            // A lowercase letter, digit or apostrophe directly after means this
            // was never a letter run — "AB1", "COVID-19", "McDonald", "I'm".
            if segmentEnd < chars.count && isWordCharacter(chars[segmentEnd]) { return nil }
            segments.append(String(chars[cursor..<segmentEnd]))
            end = segmentEnd

            var separatorEnd = segmentEnd
            while separatorEnd < chars.count && isSeparator(chars[separatorEnd]) {
                separatorEnd += 1
            }
            let separator = chars[segmentEnd..<separatorEnd]
            guard !separator.isEmpty, separator.count <= maxSeparatorLength,
                separatorEnd < chars.count, isUppercaseLetter(chars[separatorEnd])
            else { break }
            // A SPACE is not evidence of spelling on its own — ordinary all-caps
            // text is full of them. A separator containing one continues the run
            // only between single letters ("S H A R I Q U E", "S H-A-R-I-Q-U-E",
            // "S. H. A. R. I. Q. U. E."), which keeps "URL AND API", "NOT FOR
            // SALE" and "U.S. GDP" out.
            if separator.contains(" ") {
                let nextEnd = scanSegment(chars, from: separatorEnd)
                guard length == 1, nextEnd - separatorEnd == 1 else { break }
            }
            if separator.contains(where: { $0 != " " }) { isDelimited = true }
            cursor = separatorEnd
        }

        guard segments.count >= minSegmentCount else { return nil }
        let collapsedLength = segments.reduce(0) { $0 + $1.count }
        guard collapsedLength >= minCollapsedLength else { return nil }
        return ParsedRun(start: start, end: end, segments: segments, isDelimited: isDelimited)
    }

    private static func scanSegment(_ chars: [Character], from start: Int) -> Int {
        var end = start
        while end < chars.count && isUppercaseLetter(chars[end]) { end += 1 }
        return end
    }

    private static func isUppercaseLetter(_ c: Character) -> Bool {
        c.isLetter && c.isUppercase
    }

    private static func isWordCharacter(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "'" || c == "\u{2019}"
    }

    private static func isSeparator(_ c: Character) -> Bool {
        c == "-" || c == "." || c == " " || c == "\u{2010}" || c == "\u{2011}"
    }

    private static func isTail(_ chars: [Character], after end: Int) -> Bool {
        for c in chars[end...] where !(c.isWhitespace || c.isPunctuation || c.isSymbol) {
            return false
        }
        return true
    }

    // MARK: - Trigger scan

    private static func findTrigger(_ chars: [Character], before start: Int)
        -> (String?, Int?)
    {
        let windowStart = max(0, start - triggerWindow)
        guard windowStart < start else { return (nil, nil) }
        let window = String(chars[windowStart..<start])
        let full = NSRange(window.startIndex..<window.endIndex, in: window)
        // Nearest trigger wins — the last match in the window.
        guard
            let match = triggerRegex.matches(in: window, options: [], range: full).last,
            let matched = Range(match.range, in: window)
        else { return (nil, nil) }
        let offset = window.distance(from: window.startIndex, to: matched.lowerBound)
        return (String(window[matched]).lowercased(), windowStart + offset)
    }
}
