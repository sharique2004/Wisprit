import Foundation
import WispritKit

/// What a spoken-spelling run has actually earned in the dictionary.
///
/// The learn loop shipped without this gate, and the live dictionary shows the
/// bill: three canonical terms — `Sharhuue`, `Shaikd`, `Shariq`, every one of
/// them `hear: ["Sharik"]`, `source: "spoken_spelling"` — created on the three
/// occasions the ASR misheard the spelled LETTERS themselves. A canonical term
/// is also a biasing string and a correction target, so each one makes the next
/// misrecognition likelier. They were survivable only because the good
/// `Sharique` entry happens to sit earlier in the file and wins the
/// equal-length tie in the compiled correction order.
///
/// The three outcomes are ordered by how much evidence they need. `merge` is
/// the load-bearing one: a run that is a mangled spelling of a term the
/// dictionary already knows must not become a second term for the same name.
public enum LearnDecision: Equatable, Sendable {

    /// The run is an existing canonical term, garbled. Nothing new is learned:
    /// the antecedent is recorded as another `hear` phrase of `into`, and
    /// `into` — the spelling the user already approved — becomes the
    /// replacement text, so spelling S-H-A-R-I-Q-U-E and getting SHARHUUE back
    /// from the ASR still puts "Sharique" in the document.
    case merge(into: String)

    /// Believable, but attested exactly once. Goes in as `pending: true` with
    /// the antecedent as its first observation; a second sighting promotes it.
    case quarantine(term: String)

    /// The ASR did not read the letters. There is nothing here worth keeping
    /// and nothing worth writing into the user's text.
    case reject(reason: Reason)

    /// Why a run cannot be a spelling of anything.
    ///
    /// Deliberately no consonant-cluster rule: "KRZYSZTOF" is the research
    /// digest's named hard case and has to survive as a genuinely new name.
    public enum Reason: String, Equatable, Sendable {
        /// Not one of a/e/i/o/u/y anywhere in the run.
        case noVowel
        /// The same letter three or more times running.
        case repeatedLetter
        /// Longer than any name worth believing off a single spelling.
        case tooLong
        /// A digit or a punctuation mark survived the collapse.
        case nonLetter
        /// A doubled vowel English does not write — the "UU" in SHARHUUE.
        case implausibleDigraph
    }
}

/// A learn the corrector wants persisted, plus how much evidence stands behind
/// it. `isPending` is the difference between "write a canonical term" and
/// "write a note to self" — see `DictionaryStore.addPending(term:observation:)`.
public struct LearnProposal: Equatable, Sendable {
    public var term: LearnedTerm
    /// True for a quarantined run: real vocabulary only after a second sighting.
    public var isPending: Bool

    public init(term: LearnedTerm, isPending: Bool) {
        self.term = term
        self.isPending = isPending
    }
}

/// Pure classifier for the learn loop. No IO, no state, no vocabulary of its
/// own — the caller supplies the canonical terms to judge against.
public enum LearnPlausibility {

    // MARK: - Calibration

    /// Phonetic near-neighbour of an existing term. `SHARHUUE`/`Sharique`
    /// scores 0.810 and `SHARIQ`/`Sharique` 0.980 on the existing scorer.
    public static let mergeScore = 0.80
    /// Orthographic near-neighbour: `1 − levenshtein/maxLen`. `SHARHUUE` is two
    /// edits from `Sharique` (0.75); an unrelated name is nowhere near.
    public static let mergeSimilarity = 0.66
    /// The anchored rule, and the reason `antecedent` is a parameter at all.
    /// `SHAIKD` misses both direct rules (0.725 / 0.500) yet is unmistakably
    /// the same event as the other two: the ASR's OWN heard token, "Sharik",
    /// scores 0.957 against `Sharique`. When the word being corrected already
    /// IS a known term, a spelled run that is even loosely like it is a
    /// re-spelling, not a new name.
    public static let anchorScore = 0.80
    /// The orthographic veto floor. Letters are ground truth — the user just
    /// spelled them — so phonetics alone must never pick the merge target. The
    /// live incident: A-L-I-X, spelled to correct "Alex", merged into `WellX`
    /// because Double Metaphone codes ALIX, Alex, and WellX identically (ALKS,
    /// phonetic 0.853/0.869) while the letters disagree almost everywhere
    /// (similarity 0.400). A candidate sharing neither half its letters nor
    /// its first letter with the run is a phonetic twin, not a mangled
    /// spelling. 0.5 keeps `SHAIKD` (exactly 0.500 against `Sharique`, same
    /// initial besides) inside the anchored rule it calibrates.
    public static let orthographicFloor = 0.5
    /// Floor the run itself must clear under the anchored rule — the same 0.62
    /// the antecedent matcher cuts at, so the two gates agree on "related".
    public static let anchorFloor = AntecedentMatcher.threshold
    /// Longer than this and the "spelling" is a transcription accident.
    public static let maxLength = 24

    /// `y` counts here — "SYZYGY" is a word — but not in the digraph rule,
    /// where "ay"/"oy" are perfectly ordinary English.
    static let vowels: Set<Character> = ["a", "e", "i", "o", "u", "y"]
    static let pureVowels: Set<Character> = ["a", "e", "i", "o", "u"]

    /// The vowel pairs English actually writes. Only DOUBLED vowels are judged
    /// against it: mixed pairs are far too common in real names to gate on
    /// ("ue" in Sharique itself, "ia" in Maria, "io" in Fabio), whereas a
    /// repeated vowel outside `ee`/`oo` is the ASR spelling out its own
    /// confusion.
    public static let vowelDigraphs: Set<String> = [
        "ee", "oo", "ea", "ai", "ie", "ou", "oa", "ei", "au", "eu", "oi", "ui",
        "aa",  // Aaron, Isaac, Klaas — real names; the junk tell was "uu"
    ]

    // MARK: - Classifying

    /// - Parameters:
    ///   - collapsed: the run as the detector produced it, e.g. "SHARHUUE".
    ///   - antecedent: the token the run is correcting — the ASR's own
    ///     misrecognition, and the only pronunciation evidence available.
    ///   - vocabulary: the dictionary to merge against. `vocabularyTerms()`
    ///     already excludes pending entries, so a quarantined run cannot become
    ///     the merge target of the next one.
    public static func classify(collapsed: String, antecedent: String,
                                vocabulary: (any VocabularySource)?) -> LearnDecision {
        classify(collapsed: collapsed, antecedent: antecedent,
                 candidates: vocabulary?.vocabularyTerms() ?? [])
    }

    /// Same rules against an explicit candidate list — what an offline audit of
    /// an already-written dictionary uses.
    public static func classify(collapsed: String, antecedent: String,
                                candidates: [String]) -> LearnDecision {
        // Merge first, and deliberately ahead of the orthographic faults: a run
        // that IS a known term mangled has a correct answer available, and
        // handing the user that answer beats telling them the spelling failed.
        if let existing = mergeTarget(for: collapsed, antecedent: antecedent,
                                      candidates: candidates) {
            return .merge(into: existing)
        }
        if let fault = fault(in: collapsed) { return .reject(reason: fault) }
        return .quarantine(term: collapsed)
    }

    /// Best canonical term to merge into, nil when the run is genuinely new.
    /// Ties go to the earliest candidate, which for `vocabularyTerms()` is the
    /// most-recently-useful term.
    static func mergeTarget(for collapsed: String, antecedent: String,
                            candidates: [String]) -> String? {
        let run = collapsed.lowercased()
        var best: (term: String, score: Double)?
        for term in candidates {
            let score = PhoneticScorer.score(collapsed, term)
            let similarity = 1 - StringMetrics.normalizedLevenshtein(run, term.lowercased())
            // The orthographic veto: sounding alike argues FOR a merge, but
            // only the letters can make one safe (see `orthographicFloor`).
            guard similarity >= orthographicFloor || run.first == term.lowercased().first
            else { continue }
            let anchored = !antecedent.isEmpty && score >= anchorFloor
                && PhoneticScorer.score(antecedent, term) >= anchorScore
            guard score >= mergeScore || similarity >= mergeSimilarity || anchored
            else { continue }
            if best == nil || score > best!.score { best = (term, score) }
        }
        return best?.term
    }

    /// The hard orthographic faults, in the order that reports the most
    /// specific cause: a stray digit invalidates every later reading of the
    /// run, and a triple letter is a more precise complaint than the doubled
    /// vowel inside it.
    static func fault(in collapsed: String) -> LearnDecision.Reason? {
        let letters = Array(collapsed.lowercased())
        guard !letters.isEmpty else { return .noVowel }
        guard letters.allSatisfy({ $0.isLetter }) else { return .nonLetter }
        guard letters.count <= maxLength else { return .tooLong }
        guard letters.contains(where: { vowels.contains($0) }) else { return .noVowel }

        var repeats = 1
        for index in 1..<letters.count {
            repeats = letters[index] == letters[index - 1] ? repeats + 1 : 1
            if repeats >= 3 { return .repeatedLetter }
        }
        for index in 1..<letters.count
        where letters[index] == letters[index - 1] && pureVowels.contains(letters[index]) {
            let pair = String(letters[(index - 1)...index])
            if !vowelDigraphs.contains(pair) { return .implausibleDigraph }
        }
        return nil
    }
}
