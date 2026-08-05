import Foundation
import WispritKit

/// What the session layer should do about a spoken spelling directive.
///
/// The three-way split IS the safety design. The only branch that touches text
/// the user already sees is `retroReplace`, and it needs both signals — a
/// trigger phrase AND a phonetic antecedent above 0.62. Everything weaker
/// degrades to an insertion, because a wrong retro-edit deletes a correct word
/// from the user's document, which is the worst failure a dictation app has.
public enum CorrectionAction: Equatable, Sendable {

    /// Trigger phrase AND antecedent ≥ 0.62. Rewrite `target` (which may live in
    /// an earlier utterance) as `replacement`, and drop `suppress` — the whole
    /// directive, trigger phrase included — from the text being inserted.
    case retroReplace(
        target: String, replacement: String, suppress: Range<Int>, learn: LearnedTerm)

    /// Antecedent ≥ 0.62 but no trigger. Only legal when the antecedent is in
    /// THIS utterance and the run is its tail, so nothing already committed to
    /// the field is touched.
    case tailReplace(
        target: String, replacement: String, suppress: Range<Int>, learn: LearnedTerm)

    /// A run with no confident antecedent: Krzysztof mangled to "Cherie"
    /// (best score 0.383), or a genuinely dictated "J-S-O-N". Inert by
    /// construction — `replace` covers the RUN ONLY, never the trigger phrase
    /// and never anything earlier. The offer is passive UI, not an edit.
    case insertLiterally(word: String, replace: Range<Int>, offer: LearnedTerm)

    /// No letter run in this utterance.
    case none
}

/// Detect → match → decide, in one pure call.
///
/// Runs on the RAW ASR final, BEFORE the refine (FoundationModels) stage:
/// refine deterministically corrupts spelled runs ("Actually, it's
/// S-H-A-R-I-Q-U-E." → "Actually, it's Sharifue." on 3/3 runs), so refine must
/// bypass any utterance where `detector.containsLetterRun` is true.
public struct SpokenSpellingCorrector {

    public static let source = "spoken_spelling"

    public let detector: LetterRunDetector
    public let matcher: AntecedentMatcher

    public init(
        vocabulary: (any VocabularySource)? = nil,
        stoplist: Set<String> = AntecedentMatcher.defaultStoplist
    ) {
        self.detector = LetterRunDetector(vocabulary: vocabulary)
        self.matcher = AntecedentMatcher(stoplist: stoplist)
    }

    public func decide(utterance: String, previousUtterance: String = "") -> CorrectionAction {
        // Last run wins: a second spelling directive supersedes an earlier one.
        guard let run = detector.detect(in: utterance).last else { return .none }

        let antecedent = matcher.bestAntecedent(
            for: run.collapsed, current: utterance,
            before: run.range.lowerBound, previous: previousUtterance)

        guard let candidate = antecedent else {
            return .insertLiterally(
                word: run.collapsed, replace: run.range,
                offer: LearnedTerm(term: run.collapsed, heard: [], source: Self.source))
        }

        let replacement = Self.recase(run.collapsed, like: candidate.token)
        let learned = LearnedTerm(
            term: replacement, heard: [candidate.token], source: Self.source)

        if run.trigger != nil {
            return .retroReplace(
                target: candidate.token, replacement: replacement,
                suppress: run.directiveRange, learn: learned)
        }
        if candidate.inCurrentUtterance && run.isTail {
            return .tailReplace(
                target: candidate.token, replacement: replacement,
                suppress: run.range, learn: learned)
        }
        // Antecedent, no trigger, run not at the tail: too weak to edit.
        return .insertLiterally(
            word: run.collapsed, replace: run.range,
            offer: LearnedTerm(term: run.collapsed, heard: [], source: Self.source))
    }

    /// The run always arrives uppercase, so the intended casing has to come from
    /// somewhere: the antecedent, which the user already saw. With no
    /// antecedent the run is inserted exactly as heard — "JSON" is right and
    /// "KRZYSZTOF" is at least honest; guessing would be inventing evidence.
    static func recase(_ collapsed: String, like antecedent: String) -> String {
        let letters = antecedent.filter { $0.isLetter }
        guard let first = letters.first else { return collapsed }
        if letters.count > 1 && letters.allSatisfy({ $0.isUppercase }) { return collapsed }
        if first.isUppercase {
            return collapsed.prefix(1) + collapsed.dropFirst().lowercased()
        }
        return collapsed.lowercased()
    }
}
