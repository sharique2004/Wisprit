import Foundation
import WispritKit

/// Retro-correction planner for the off-path vocabulary channel.
///
/// `VocabularyChannel` re-transcribes the utterance with the whole dictionary
/// loaded as `contextualStrings` — the only Apple mechanism that makes a learned
/// name actually *recognized*. Its transcript arrives 0.5–2.5 s after the live
/// text is already in the user's document, and until now it was thrown away.
/// This file decides, from that transcript, which words in the document are
/// worth going back and fixing.
///
/// **It is not a diff.** The two engines are different models with different
/// options: DictationTranscriber punctuates differently, cases differently, and
/// makes its own word choices. None of that is evidence about anything. The one
/// thing it knows that the live path cannot is which **dictionary terms** it
/// heard, because those are the strings it was biased toward — so a mismatch is
/// only actionable when the reconciled side of it is, exactly, one of those
/// terms. Everything else the two readings disagree about is left alone.
///
/// **Every accepted edit substitutes 1–3 live tokens by exactly one dictionary
/// term.** Pure deletions and pure insertions are refused unconditionally, which
/// is what makes "never retro-delete a word the user actually said" true by
/// construction rather than by threshold: there is no code path that removes
/// text without putting a canonical term in its place.

/// One substitution, ready for `RetroEditPlanner`.
public struct VocabularyRetroEdit: Equatable, Sendable {
    /// The text to find, as an EXACT substring of the inserted text — sliced by
    /// token range, never rebuilt from tokens. `RetroEditPlanner` searches the
    /// live document for this literally, so a re-spaced or re-cased
    /// reconstruction would simply never be found.
    public var replace: String
    /// The canonical dictionary spelling that replaces it.
    public var with: String
    /// `PhoneticScorer.score(replace, with)` — recorded so a refusal threshold
    /// can be re-tuned against real accepted edits later.
    public var score: Double

    public init(replace: String, with: String, score: Double) {
        self.replace = replace
        self.with = with
        self.score = score
    }
}

/// Why nothing was proposed. Every gate has its own value: the whole point of
/// the planner is that it refuses most of the time, so "it did nothing" has to
/// be readable in metrics and pinnable in tests.
public enum VocabularyRetroRefusal: String, Equatable, Sendable {
    /// No inserted text, or no reconciled transcript, to compare.
    case noText
    /// The biased pass recovered no dictionary term at all. Without one there is
    /// nothing this planner is allowed to act on.
    case noTermHits
    /// The two readings disagree about too much of the utterance to treat either
    /// as a reading of the other. Refuses the whole plan, not just a block.
    case divergent
    /// The readings agree token for token — nothing to correct.
    case aligned
    /// The reconciled side adds tokens the live side never had.
    case pureInsert
    /// The live side has tokens the reconciled side dropped.
    case pureDelete
    /// The reconciled block is not a dictionary term (it is just a different
    /// word choice, which is not evidence).
    case notADictionaryTerm
    /// Two canonical terms normalize to the same block; we cannot tell which.
    case ambiguousTerm
    /// More live tokens than one term can plausibly have been misheard as.
    case blockTooLong
    /// Not enough agreed context around the block to trust its boundaries.
    case noAnchor
    /// The live words do not sound like the term. A biased engine hearing a
    /// different word is a re-wording, not a recovery.
    case phoneticallyUnrelated
    /// The live text already says the term.
    case alreadyCorrect
    /// A live token is itself a canonical term — never overwrite a word the
    /// dictionary has already blessed.
    case knownTerm
}

/// The planner's verdict. `refusal` is populated exactly when `edits` is empty:
/// it names the FIRST gate that turned something down, which for a plan with a
/// single mismatch block is simply why that block lost.
public struct VocabularyRetroPlan: Equatable, Sendable {
    public var edits: [VocabularyRetroEdit]
    public var refusal: VocabularyRetroRefusal?

    public init(edits: [VocabularyRetroEdit] = [], refusal: VocabularyRetroRefusal? = nil) {
        self.edits = edits
        self.refusal = refusal
    }

    public var isEmpty: Bool { edits.isEmpty }

    static func refused(_ reason: VocabularyRetroRefusal) -> VocabularyRetroPlan {
        VocabularyRetroPlan(edits: [], refusal: reason)
    }
}

public enum VocabularyReconciler {

    /// The calibrated numbers. Defaults are the shipping configuration; the
    /// struct exists so a test can tighten one gate without restating the rest.
    public struct Limits: Sendable, Equatable {
        /// At most this many words may be replaced by one term. Three covers
        /// "in s forge" / "mail ex swift"; beyond that a "misrecognition" is a
        /// different sentence.
        public var maxLiveTokens: Int
        /// The same 0.62 `AntecedentMatcher` cuts at, on the same scorer, for
        /// the same reason: below it the two strings are unrelated words.
        public var minScore: Double
        /// Fraction of tokens the two readings may disagree about before the
        /// whole plan is refused. Above it they are not two readings of one
        /// utterance and no block boundary means anything.
        public var maxDivergence: Double
        /// Agreed tokens required on each side of a block. A block at the very
        /// start or end of the text has no context on the outside, so the
        /// inside has to carry it.
        public var minAnchors: Int
        public var minInnerAnchors: Int
        /// Per utterance. Two is already a lot of the user's document to rewrite
        /// after the fact.
        public var maxEdits: Int

        public init(maxLiveTokens: Int = 3,
                    minScore: Double = AntecedentMatcher.threshold,
                    maxDivergence: Double = 0.35,
                    minAnchors: Int = 1,
                    minInnerAnchors: Int = 2,
                    maxEdits: Int = 2) {
            self.maxLiveTokens = maxLiveTokens
            self.minScore = minScore
            self.maxDivergence = maxDivergence
            self.minAnchors = minAnchors
            self.minInnerAnchors = minInnerAnchors
            self.maxEdits = maxEdits
        }
    }

    // MARK: - Planning

    /// Judge one utterance against its biased re-transcription.
    ///
    /// - Parameters:
    ///   - inserted: the text that actually reached the field — post-refine,
    ///     post-dictionary-regex, post-everything. Planning against anything
    ///     earlier would emit `replace` strings that are not in the document.
    ///   - reconciled: `VocabularyReconciliation.transcript`.
    ///   - termHits: `VocabularyReconciliation.termHits`. The canonical
    ///     spellings here are the ONLY replacements this planner may propose.
    ///   - vocabulary: consulted only to refuse — a live token that is already a
    ///     canonical term is never overwritten. `vocabularyTerms()` excludes
    ///     pending entries, so a quarantined spelling cannot protect itself.
    public static func plan(inserted: String,
                            reconciled: String,
                            termHits: [String: Int],
                            vocabulary: (any VocabularySource)?,
                            limits: Limits = Limits()) -> VocabularyRetroPlan {
        plan(inserted: inserted, reconciled: reconciled, termHits: termHits,
             knownTerm: { vocabulary?.isKnownTerm($0) ?? false }, limits: limits)
    }

    /// Same rules with the known-term check supplied directly — what a caller
    /// holding a narrower dictionary seam (the session's `VocabularyPort`) uses.
    public static func plan(inserted: String,
                            reconciled: String,
                            termHits: [String: Int],
                            knownTerm: (String) -> Bool,
                            limits: Limits = Limits()) -> VocabularyRetroPlan {
        let live = Tokenizer.tokens(in: inserted)
        let other = Tokenizer.tokens(in: reconciled)
        guard !live.isEmpty, !other.isEmpty else { return .refused(.noText) }

        // Index the terms the biased pass actually recovered, by their
        // whitespace-relaxed normal form. A term nobody heard is not a candidate
        // however well it scores.
        var candidates: [String: [String]] = [:]
        for (term, hits) in termHits where hits > 0 {
            let key = Tokenizer.normalForm(term)
            guard !key.isEmpty else { continue }
            candidates[key, default: []].append(term)
        }
        guard !candidates.isEmpty else { return .refused(.noTermHits) }

        let matched = longestCommonSubsequence(live.map(\.normalized), other.map(\.normalized))
        let blocks = mismatchBlocks(liveCount: live.count, otherCount: other.count, matched: matched)
        guard !blocks.isEmpty else { return .refused(.aligned) }

        // One global sanity check before any block is considered: if the two
        // readings disagree about more than a third of the utterance they are
        // not the same sentence, and no boundary inside them is trustworthy.
        let agreed = matched.count
        let divergence = Double(live.count + other.count - 2 * agreed)
            / Double(live.count + other.count)
        guard divergence <= limits.maxDivergence else { return .refused(.divergent) }

        let chars = Array(inserted)
        var edits: [VocabularyRetroEdit] = []
        var firstRefusal: VocabularyRetroRefusal?

        for block in blocks {
            guard edits.count < limits.maxEdits else { break }
            switch judge(block, live: live, other: other, chars: chars,
                         candidates: candidates, knownTerm: knownTerm, limits: limits) {
            case .accept(let edit):
                edits.append(edit)
            case .refuse(let reason):
                if firstRefusal == nil { firstRefusal = reason }
            }
        }

        return VocabularyRetroPlan(edits: edits, refusal: edits.isEmpty ? firstRefusal : nil)
    }

    // MARK: - One block

    /// A run of tokens the two readings disagree about, bounded by tokens they
    /// agree on. `anchorsBefore`/`anchorsAfter` count the agreed pairs that
    /// touch it — the evidence that the boundaries are where we think they are.
    struct Block: Equatable {
        var live: Range<Int>
        var other: Range<Int>
        var anchorsBefore: Int
        var anchorsAfter: Int
        var atStart: Bool
        var atEnd: Bool
    }

    /// One block's verdict. Deliberately not `Result`: a refusal is the normal,
    /// expected answer here, not an error anybody throws.
    enum Verdict {
        case accept(VocabularyRetroEdit)
        case refuse(VocabularyRetroRefusal)
    }

    private static func judge(_ block: Block,
                              live: [Tokenizer.Token],
                              other: [Tokenizer.Token],
                              chars: [Character],
                              candidates: [String: [String]],
                              knownTerm: (String) -> Bool,
                              limits: Limits) -> Verdict {
        // STRUCTURAL RULE, first and unconditional. A block with nothing on the
        // live side would insert words the user never said; a block with nothing
        // on the reconciled side would delete words they did. Neither is ever a
        // dictionary recovery, so neither is ever allowed.
        guard !block.live.isEmpty else { return .refuse(.pureInsert) }
        guard !block.other.isEmpty else { return .refuse(.pureDelete) }

        // GATE 1, load-bearing: the reconciled side must be exactly one
        // canonical term, whole-block. This is the only reason to believe the
        // biased pass over the live pass at all.
        let reconciledForm = other[block.other].map(\.normalized).joined(separator: " ")
        guard let terms = candidates[reconciledForm] else { return .refuse(.notADictionaryTerm) }
        guard terms.count == 1, let term = terms.first else { return .refuse(.ambiguousTerm) }

        guard block.live.count <= limits.maxLiveTokens else { return .refuse(.blockTooLong) }

        // GATE 2: agreed context on both sides. At a text boundary there is no
        // outside context at all, so the inside has to be that much stronger.
        guard !(block.atStart && block.atEnd) else { return .refuse(.noAnchor) }
        let needBefore = block.atStart ? 0 : limits.minAnchors
        let needAfter = block.atEnd ? 0 : limits.minAnchors
        let inner = block.atStart ? block.anchorsAfter : block.anchorsBefore
        let needInner = (block.atStart || block.atEnd) ? limits.minInnerAnchors : 0
        guard block.anchorsBefore >= needBefore, block.anchorsAfter >= needAfter,
              inner >= needInner else { return .refuse(.noAnchor) }

        // GATE 4a: never overwrite a word the dictionary has already blessed.
        // Checked on the raw token, which is what a dictionary lookup sees.
        let liveTokens = Array(live[block.live])
        for token in liveTokens where knownTerm(String(chars[token.range])) {
            return .refuse(.knownTerm)
        }

        // GATE 4b: already correct. Casing and punctuation are already folded
        // out by normalization, and WHITESPACE is folded out here as well —
        // "Ins Forge" against a canonical "InsForge" is the second engine
        // expressing a spacing opinion, and its opinions are not evidence. Only
        // a genuine misrecognition is worth rewriting the user's document for.
        let liveForm = liveTokens.map(\.normalized).joined(separator: " ")
        guard squeezed(liveForm) != squeezed(Tokenizer.normalForm(term)) else {
            return .refuse(.alreadyCorrect)
        }

        // GATE 3: it has to SOUND like the term. Same scorer and same 0.62 the
        // antecedent matcher uses, so the two gates agree on "related".
        let score = PhoneticScorer.score(liveForm, term)
        guard score >= limits.minScore else { return .refuse(.phoneticallyUnrelated) }

        // GATE 5: the replacement text is sliced out of the inserted string by
        // token range — never rebuilt — so `RetroEditPlanner`'s literal search
        // finds it in the document exactly as we committed it. Whatever sat
        // between the tokens (a comma, a stray emoji) travels with them.
        let from = live[block.live.lowerBound].range.lowerBound
        let upTo = live[block.live.upperBound - 1].range.upperBound
        return .accept(VocabularyRetroEdit(replace: String(chars[from..<upTo]),
                                           with: term, score: score))
    }

    /// Every space removed — the form the "already correct" gate compares, so a
    /// re-spacing alone can never be an edit.
    private static func squeezed(_ text: String) -> String {
        text.filter { !$0.isWhitespace }
    }

    // MARK: - Alignment

    /// Maximal runs of disagreement between the matched pairs, plus how much
    /// agreed context each one has on either side.
    static func mismatchBlocks(liveCount: Int, otherCount: Int,
                               matched: [(live: Int, other: Int)]) -> [Block] {
        var blocks: [Block] = []
        var liveCursor = 0
        var otherCursor = 0
        var runBefore = 0

        /// Agreed pairs immediately after the pair at `index` in `matched`.
        func runAfter(from index: Int) -> Int {
            var count = 0
            var i = index
            while i < matched.count {
                if i > index,
                   matched[i].live != matched[i - 1].live + 1
                       || matched[i].other != matched[i - 1].other + 1 { break }
                count += 1
                i += 1
            }
            return count
        }

        for (index, pair) in matched.enumerated() {
            if pair.live > liveCursor || pair.other > otherCursor {
                blocks.append(Block(live: liveCursor..<pair.live,
                                    other: otherCursor..<pair.other,
                                    anchorsBefore: runBefore,
                                    anchorsAfter: runAfter(from: index),
                                    atStart: liveCursor == 0 && otherCursor == 0,
                                    atEnd: false))
                runBefore = 0
            }
            runBefore += 1
            liveCursor = pair.live + 1
            otherCursor = pair.other + 1
        }

        if liveCursor < liveCount || otherCursor < otherCount {
            blocks.append(Block(live: liveCursor..<liveCount,
                                other: otherCursor..<otherCount,
                                anchorsBefore: runBefore,
                                anchorsAfter: 0,
                                atStart: liveCursor == 0 && otherCursor == 0,
                                atEnd: true))
        }
        return blocks
    }

    /// Word-level LCS. Utterances are short (tens of tokens), so the plain
    /// quadratic table is the right implementation — and it runs on a detached
    /// task seconds after the text landed, not on the paste path.
    static func longestCommonSubsequence(_ a: [String], _ b: [String]) -> [(live: Int, other: Int)] {
        guard !a.isEmpty, !b.isEmpty else { return [] }
        var table = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j]
                    ? table[i + 1][j + 1] + 1
                    : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var pairs: [(live: Int, other: Int)] = []
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] {
                pairs.append((i, j))
                i += 1; j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return pairs
    }

    // MARK: - Tokenizing

    /// Word tokens carrying their range back into the source string.
    ///
    /// Ranges are indices into `Array(source)` — grapheme clusters, so an emoji
    /// or a combining mark can never split a slice mid-character.
    enum Tokenizer {

        struct Token: Equatable {
            /// Casing, punctuation and apostrophes folded away: what alignment
            /// compares. The two engines disagree about all three by design.
            let normalized: String
            let range: Range<Int>
        }

        static func tokens(in text: String) -> [Token] {
            let chars = Array(text)
            var tokens: [Token] = []
            var start: Int?
            for index in chars.indices {
                if isWord(chars[index]) {
                    if start == nil { start = index }
                } else if let from = start {
                    append(&tokens, chars, from..<index)
                    start = nil
                }
            }
            if let from = start { append(&tokens, chars, from..<chars.endIndex) }
            return tokens
        }

        /// Whitespace-relaxed normal form of a whole phrase — how a multi-word
        /// dictionary term is compared against a multi-token block.
        static func normalForm(_ text: String) -> String {
            tokens(in: text).map(\.normalized).joined(separator: " ")
        }

        /// Apostrophes stay inside a word so "it's" is one token, and are then
        /// folded out of the normal form so the two engines' quoting styles
        /// (straight, curly, absent) all compare equal.
        private static func isWord(_ character: Character) -> Bool {
            character.isLetter || character.isNumber
                || character == "'" || character == "\u{2019}"
        }

        private static func append(_ tokens: inout [Token], _ chars: [Character],
                                   _ range: Range<Int>) {
            var lower = range.lowerBound, upper = range.upperBound
            while lower < upper && !(chars[lower].isLetter || chars[lower].isNumber) { lower += 1 }
            while upper > lower && !(chars[upper - 1].isLetter || chars[upper - 1].isNumber) {
                upper -= 1
            }
            guard lower < upper else { return }
            let normalized = String(chars[lower..<upper])
                .lowercased()
                .filter { $0 != "'" && $0 != "\u{2019}" }
            guard !normalized.isEmpty else { return }
            tokens.append(Token(normalized: normalized, range: lower..<upper))
        }
    }
}
