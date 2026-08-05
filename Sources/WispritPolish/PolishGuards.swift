import Foundation
import WispritRefine

/// The deterministic half of the polish cage.
///
/// Two lineages meet here:
///
/// * `sanitize` is a 1:1 port of `polish.py`'s `_sanitize` — the leaked
///   self-commentary stripper ("Wait — that's wrong. Let me give the correct
///   output:"). Pinned byte-for-byte against the real Python by
///   `SanitizeGoldenTests`.
/// * `launder` wraps it in `RefineGuards.stripWrappers`, the wrapper/preamble
///   fixpoint the refine agent already owns (fences, echoed tag pairs, full
///   quoting). Reused rather than re-derived — it is `public` and this target
///   depends on WispritRefine.
///
/// Everything else (`refused`, `plausible`) is new: polish's failure policy is
/// the inverse of refine's, so a bad rewrite has to be *detected* rather than
/// quietly swapped for the verbatim text.
public enum PolishGuards {

    // MARK: - patterns (ported from polish.py)

    /// Specific self-commentary phrases the model emits before its real answer.
    /// Deliberately narrow — bare words like "wait" / "here" are excluded so a
    /// genuine multi-paragraph email ("Please wait for the report") is never
    /// truncated. `polish._META_MARKERS`, verbatim.
    static let metaMarkers = [
        "let me redo", "let me give", "let me try", "let me correct", "let me clean",
        "let me provide", "let me rewrite", "here is the corrected",
        "here's the corrected", "here is the cleaned", "here's the cleaned",
        "corrected version", "cleaned version", "correct output", "that's wrong",
        "that is wrong", "my apologies", "i apologize", "apologies,",
    ]

    /// A leaked meta-clause on the same line as the answer, e.g. "Actually,
    /// cleaned directly: Hi Bob…" → strip up to and including the colon.
    /// Requires a clearly-meta keyword before the colon so real text like
    /// "Actually, the meeting is at 3: …" survives. `polish._PREFIX_RE`.
    static let prefix = regex(
        #"^\s*[^:\n]{0,80}?"#
            + #"(?:cleaned|corrected|here is the|here's the|let me|final version|"#
            + #"the cleaned|the corrected|output)"#
            + #"[^:\n]{0,40}:\s+(?=\S)"#,
        [.caseInsensitive])

    /// Length threshold for "this paragraph is pure meta", in Python `len()`
    /// units (code points), from `_sanitize`.
    static let metaParagraphLimit = 120

    // MARK: - patterns (new)

    /// The model declining the job. Requires an apology/self-reference opener
    /// AND a refusal verb close behind, so a dictated apology ("Sorry I missed
    /// your call, let's sync tomorrow") is never mistaken for one. Measured
    /// failure mode: short or odd inputs come back as "I'm sorry, I can't help
    /// with that."
    static let refusal = regex(
        #"^(?:i'm sorry|i am sorry|sorry|unfortunately|as an ai|i cannot|i can't|"#
            + #"i'm unable|i am unable|i won't)\b[^\n]{0,120}?"#
            + #"\b(?:cannot|can't|can not|unable|not able|won't|will not|"#
            + #"don't have|do not have|not appropriate|isn't appropriate|against)\b"#,
        [.caseInsensitive])

    /// An output that *opens* like an assistant reply means the model answered
    /// the dictation instead of rewriting it. Split in two:
    ///
    /// - `assistantOpener` is the mode-independent set: pure meta ("Sure,",
    ///   "Certainly", "Here's the…", "Great question"). Damning everywhere.
    /// - the apology openers live only in `RefineGuards`' strict check, used
    ///   for `.cleanUp`, because a *tone* rewrite may legitimately open "I am
    ///   sorry that I missed your call" when the speaker apologized.
    static let assistantOpener = regex(
        #"^(?:here(?:'s| is)\b|certainly\b|sure[,!]|of course\b|as an ai\b|"#
            + #"great question\b|you're welcome\b|you are welcome\b|happy to help\b|"#
            + #"glad to help\b|how can i (?:help|assist)\b|no problem[,!.])"#,
        [.caseInsensitive])

    static let wordPunctuation =
        CharacterSet(charactersIn: ".,!?\"'\u{201C}\u{201D}\u{2018}\u{2019}")

    // MARK: - laundering

    /// Peel invented wrappers, then leaked self-commentary, then any wrapper
    /// the unwrapping exposed. The two failure modes compose (a fenced block
    /// whose first paragraph is the model narrating), and each pass is
    /// idempotent on already-clean text.
    public static func launder(_ raw: String) -> String {
        let unwrapped = RefineGuards.stripWrappers(raw)
        let sanitized = sanitize(unwrapped)
        return RefineGuards.stripWrappers(sanitized)
    }

    /// Strip a leaked meta-commentary preamble, keeping the model's final text.
    ///
    /// If the output has paragraphs and one is clearly the model talking about
    /// its own process, return everything after the LAST such paragraph. A
    /// single paragraph (or no markers) is returned unchanged, so legitimate
    /// multi-paragraph output survives. 1:1 with `polish._sanitize`.
    public static func sanitize(_ output: String) -> String {
        var out = output.trimmingCharacters(in: .whitespacesAndNewlines)
        // Unwrap a fully-quoted response. ASCII quotes only — matching the
        // Python's `out[0] in "\"'"`; the curly pairs are RefineGuards' job.
        if out.count >= 2, let first = out.first, let last = out.last,
           first == last, first == "\"" || first == "'" {
            out = String(out.dropFirst().dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let segments = out.components(separatedBy: "\n\n")
        // Where the real answer starts: after the last short pure-meta
        // paragraph, or at the last paragraph that begins with a meta clause.
        var start = 0
        for (index, segment) in segments.enumerated() {
            let low = segment.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            // Python `len()` counts code points.
            if segment.unicodeScalars.count < metaParagraphLimit,
               metaMarkers.contains(where: { low.contains($0) }) {
                start = index + 1            // pure meta paragraph → answer follows
            } else if matchesAtStart(prefix, segment) {
                start = index                // this paragraph is answer + prefix
            }
        }
        if start >= segments.count { start = segments.count - 1 }  // never strip all
        let joined = segments[start...].joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip a leaked "meta-clause: <answer>" prefix on the first line.
        return replaceFirst(prefix, in: joined, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - verdicts

    /// True when the model declined instead of rewriting.
    public static func refused(_ text: String) -> Bool {
        matchesAtStart(refusal, text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Word-count band per mode, as multipliers of the input word count plus a
    /// fixed slack (and a smaller slack for very short inputs, so "thank you"
    /// can never come back as a paragraph).
    ///
    /// `.cleanUp` is identity-preserving and reuses refine's measured band.
    /// The tone modes stay near the input length — a rewrite, not a letter;
    /// formal gets the wider ceiling because professional phrasing genuinely
    /// inflates speech ("send me that" → "could you please send me that").
    /// `.asAIPrompt` may restructure into a short instruction or a bulleted
    /// one, so it gets slack in BOTH directions — but not unbounded: a model
    /// that answers the prompt instead of writing it produces a wall of text.
    struct Band {
        var lower: Double
        var upper: Double
        var slack: Int
        var shortSlack: Int
    }

    static func band(for mode: PolishMode) -> Band {
        switch mode {
        case .cleanUp: return Band(lower: 0.4, upper: 1.2, slack: 8, shortSlack: 2)
        case .makeFormal: return Band(lower: 0.5, upper: 2.0, slack: 10, shortSlack: 6)
        case .makeCasual: return Band(lower: 0.4, upper: 1.6, slack: 8, shortSlack: 5)
        case .asAIPrompt: return Band(lower: 0.25, upper: 2.5, slack: 16, shortSlack: 12)
        }
    }

    /// True when `polished` is plausibly a rewrite of `raw` in `mode`.
    ///
    /// A big shrink means the model summarized or dropped sentences; a big
    /// growth means it answered the dictation or ran away. Both observed. An
    /// output that opens like an assistant reply is rejected outright unless
    /// the speaker opened that way themselves.
    public static func plausible(raw: String, polished: String, mode: PolishMode) -> Bool {
        let text = polished.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return false }
        if mode == .cleanUp {
            // Same transform as the on-path stage → same measured guard,
            // including its apology-opener handling.
            return RefineGuards.plausible(raw: raw, refined: text)
        }
        if matchesAtStart(assistantOpener, text),
           firstContentWord(raw) != firstContentWord(text) {
            return false
        }
        let bounds = band(for: mode)
        let nRaw = wordCount(raw)
        let nOut = wordCount(text)
        let lower = Int(Double(nRaw) * bounds.lower)
        let upper = Int(Double(nRaw) * bounds.upper) + (nRaw < 6 ? bounds.shortSlack : bounds.slack)
        return lower <= nOut && nOut <= upper
    }

    // MARK: - plumbing

    /// Local copy: `RefineGuards`' equivalents are internal to that module.
    /// Same semantics — leading fillers cannot anchor the identity check
    /// because the model is supposed to delete them.
    static let leadFillers: Set<String> = ["um", "umm", "uh", "uhh", "uhm", "erm", "hmm",
                                           "so", "okay", "ok", "well", "and", "like"]

    static func firstContentWord(_ text: String) -> String {
        for word in text.split(whereSeparator: { $0.isWhitespace }) {
            let bare = String(word).trimmingCharacters(in: wordPunctuation).lowercased()
            if !bare.isEmpty && !leadFillers.contains(bare) { return bare }
        }
        return ""
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    static func regex(_ pattern: String, _ options: NSRegularExpression.Options)
        -> NSRegularExpression {
        // Compile-time literals; a throw here is a programmer error.
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    /// Python's `re.match`: anchored at position 0, not a full match.
    static func matchesAtStart(_ re: NSRegularExpression, _ text: String) -> Bool {
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, options: [.anchored],
                                    range: NSRange(location: 0, length: ns.length))
        else { return false }
        return m.range.location == 0
    }

    /// Python's `re.sub(count=1)` for a `^`-anchored, non-multiline pattern.
    static func replaceFirst(_ re: NSRegularExpression, in text: String, with template: String)
        -> String {
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length))
        else { return text }
        return ns.replacingCharacters(in: m.range, with: template)
    }
}
