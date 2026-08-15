import Foundation
import WispritCorrections
import WispritKit

/// One observed correction the flywheel may eventually learn from.
///
/// `replaced` is the token WE committed — the ASR's own misrecognition, which
/// becomes the `hear` evidence if this ever reaches the dictionary.
/// `replacement` is what the user typed over it: the learn candidate. This
/// module only ever PROPOSES; the integration layer routes proposals to
/// `PendingLearnStore`, where the ≥2-observations rule and the Accept/Dismiss
/// UX live. Nothing is stored here.
public struct EditLearnProposal: Equatable, Sendable {
    public var replaced: String
    public var replacement: String
    /// `PhoneticScorer.score(replaced, replacement)` — recorded so thresholds
    /// can be re-tuned against real accepted proposals later.
    public var score: Double
    /// `ContextInfo.extractorVersion` at proposal time, so a learn is
    /// attributable to the rules that produced it.
    public var extractorVersion: Int

    public init(replaced: String, replacement: String, score: Double,
                extractorVersion: Int = ContextInfo.extractorVersion) {
        self.replaced = replaced
        self.replacement = replacement
        self.score = score
        self.extractorVersion = extractorVersion
    }
}

/// Why an observation produced nothing. Refusing is this gate's normal
/// behavior — most field diffs are the user writing, not correcting — so
/// every silent outcome is nameable in metrics and pinnable in tests.
public enum EditObservationRefusal: String, Equatable, Sendable {
    /// One side is empty; there is nothing to compare.
    case noText
    /// Token streams identical (case, punctuation, and whitespace folded):
    /// nothing was corrected. Pure re-wrapping lands here by construction.
    case unchanged
    /// More than one mismatch region — a rewrite or reflow, not a correction.
    case reflow
    /// The field grew: the user typed MORE text. Never evidence of a
    /// misrecognition.
    case insertion
    /// The field shrank: the user deleted words. Learning from deletions is
    /// how "never retro-delete a correct word" dies, so: nothing.
    case deletion
    /// The one mismatch swaps more than one token per side. Multi-word
    /// rewrites are edits of intent, not spelling.
    case multiToken
    /// The replacement does not sound like what it replaced (< 0.70 on the
    /// shared scorer): a re-wording, not a correction.
    case phoneticallyUnrelated
    /// The replacement fails `CandidateExtractor`'s acceptance rules — common
    /// word, email, URL, digit run, over-length, or junk shape. The hard
    /// nevers all land here.
    case notACandidate
    /// The dictionary already knows the replacement; there is nothing to learn.
    case knownTerm
    /// Either side exceeds the alignment bound; a field that large is not one
    /// utterance's commit anymore.
    case tooMuchText
}

/// The gate's verdict, `VocabularyRetroPlan`-shaped: `refusal` is populated
/// exactly when `proposal` is nil.
public struct EditObservation: Equatable, Sendable {
    public var proposal: EditLearnProposal?
    public var refusal: EditObservationRefusal?

    public init(proposal: EditLearnProposal? = nil, refusal: EditObservationRefusal? = nil) {
        self.proposal = proposal
        self.refusal = refusal
    }

    static func refused(_ reason: EditObservationRefusal) -> EditObservation {
        EditObservation(proposal: nil, refusal: reason)
    }
}

/// Phase 5's shared classifier: given the text we committed and the field as
/// it reads now, emit AT MOST one learn proposal — a single-token substitution
/// that sounds like what it replaced, passes the extractor's acceptance rules,
/// and is not already known. Everything else — insertions, deletions, reflow,
/// multi-word rewrites — is the user writing, and produces nothing.
///
/// Pure and synchronous. The caller owns locating our committed run in the
/// field (`RetroEditPlanner.locateOwnedRun`), the ≥2-observations rule
/// (`PendingLearnStore`), and consent/secure-context gating (`ContextPolicy`).
public enum EditObservationGate {

    /// Same bar the plan sets for auto-learn, above the 0.62 "related" floor
    /// the antecedent matcher uses: a correction has to SOUND like the word it
    /// replaces before it can claim to be a respelling of it.
    public static let minScore = 0.70
    /// Alignment bound per side. The quadratic LCS is fine at this size, and a
    /// field bigger than this is not a single utterance's commit.
    public static let maxTokens = 800

    /// - Parameters:
    ///   - committed: the text Wisprit inserted, exactly as committed.
    ///   - current: the same field region as it reads now.
    ///   - lexicon: common-word filter for the replacement.
    ///   - knownTerm: "does the dictionary already know this?" — injectable,
    ///     mirroring `LearnPlausibility`, so the session's narrow dictionary
    ///     seam plugs in without this module importing storage.
    public static func observe(committed: String, current: String,
                               lexicon: any Lexicon,
                               knownTerm: (String) -> Bool) -> EditObservation {
        let ours = ContextTokenizer.tokens(in: committed)
        let theirs = ContextTokenizer.tokens(in: current)
        guard !ours.isEmpty, !theirs.isEmpty else { return .refused(.noText) }
        guard ours.count <= maxTokens, theirs.count <= maxTokens else {
            return .refused(.tooMuchText)
        }

        // Case, apostrophes, punctuation, and whitespace are all folded out of
        // alignment: apps re-wrap, smart-quote, and auto-capitalize on their
        // own, and none of that is a correction. (A case-ONLY edit therefore
        // reads as `unchanged` — deliberate conservatism.)
        let a = ours.map { normalize($0.text) }
        let b = theirs.map { normalize($0.text) }
        guard a != b else { return .refused(.unchanged) }

        let matched = longestCommonSubsequence(a, b)
        let blocks = mismatchBlocks(oursCount: a.count, theirsCount: b.count, matched: matched)
        guard blocks.count == 1, let block = blocks.first else { return .refused(.reflow) }
        guard !block.ours.isEmpty else { return .refused(.insertion) }
        guard !block.theirs.isEmpty else { return .refused(.deletion) }
        guard block.ours.count == 1, block.theirs.count == 1 else {
            return .refused(.multiToken)
        }

        let replaced = ours[block.ours.lowerBound].text
        let replacement = theirs[block.theirs.lowerBound].text

        let score = PhoneticScorer.score(replaced, replacement)
        guard score >= minScore else { return .refused(.phoneticallyUnrelated) }
        guard CandidateExtractor.acceptsTerm(replacement, lexicon: lexicon) else {
            return .refused(.notACandidate)
        }
        guard !knownTerm(replacement) else { return .refused(.knownTerm) }

        return EditObservation(
            proposal: EditLearnProposal(replaced: replaced, replacement: replacement,
                                        score: score))
    }

    static func normalize(_ text: String) -> String {
        text.lowercased().filter { $0 != "'" && $0 != "\u{2019}" }
    }

    // MARK: - Alignment

    /// A run of tokens the two texts disagree about, bounded by agreement.
    struct Block: Equatable {
        var ours: Range<Int>
        var theirs: Range<Int>
    }

    static func mismatchBlocks(oursCount: Int, theirsCount: Int,
                               matched: [(ours: Int, theirs: Int)]) -> [Block] {
        var blocks: [Block] = []
        var oursCursor = 0
        var theirsCursor = 0
        for pair in matched {
            if pair.ours > oursCursor || pair.theirs > theirsCursor {
                blocks.append(Block(ours: oursCursor..<pair.ours,
                                    theirs: theirsCursor..<pair.theirs))
            }
            oursCursor = pair.ours + 1
            theirsCursor = pair.theirs + 1
        }
        if oursCursor < oursCount || theirsCursor < theirsCount {
            blocks.append(Block(ours: oursCursor..<oursCount,
                                theirs: theirsCursor..<theirsCount))
        }
        return blocks
    }

    /// Word-level LCS, the same plain quadratic table `VocabularyReconciler`
    /// uses — texts here are one utterance's worth of tokens, bounded by
    /// `maxTokens`, and the gate runs off-path after the session closes.
    static func longestCommonSubsequence(_ a: [String], _ b: [String]) -> [(ours: Int, theirs: Int)] {
        guard !a.isEmpty, !b.isEmpty else { return [] }
        var table = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1),
                            count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j]
                    ? table[i + 1][j + 1] + 1
                    : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var pairs: [(ours: Int, theirs: Int)] = []
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] {
                pairs.append((i, j))
                i += 1
                j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return pairs
    }
}
