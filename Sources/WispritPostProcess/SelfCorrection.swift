// Explicit self-correction — "I said X, no actually Y" -> "Y".
//
// Lifted out of `PostProcess` stage 5 so the same code can run in both places
// it is needed:
//
//   * the finalize path, where `PostProcess.selfCorrect` calls it after stage 1
//     has already stripped the fillers, and
//   * the live path, where it runs on every raw ASR partial (~1/s) and the
//     fillers are still in the text.
//
// That second caller is why every joint tolerates interleaved um/uh/erm, why
// the whole engine is one bounded left-to-right sweep over the string, and why
// `apply` is idempotent: a partial is re-processed from scratch each time it
// grows, so `apply(apply(x))` must equal `apply(x)` for every input.
//
// Two tiers, both explicit-marker-only — the SPEC §postprocessing rule is
// "detect explicit markers only … ambiguous cases pass through verbatim":
//
//   a. CLOSED-CLASS PAIR. "<X> <connective> <Y>" where X and Y are members of
//      the SAME closed class (weekday, month, clock time, number, relative day)
//      keeps Y and drops X plus the joint. Because both sides have to be the
//      same *kind of thing* to fire at all, the weak connectives — a bare
//      "actually", "sorry", a bare "no" — are safe here, and only here.
//      "Thursday umm no actually Friday" -> "Friday"; "that's actually great"
//      and "I actually think Friday works" are untouched, because nothing on
//      the left of "actually" is a weekday.
//
//      POSSESSIVE DATE PAIR, the phrase form of tier (a): "<class>'s <head>
//      <connective> <class>'s <head>" with the SAME head noun on both sides
//      keeps the right phrase wholesale — "tonight's meeting? Actually,
//      tomorrow's meeting" -> "tomorrow's meeting". The repeated head is what
//      makes the weak connectives safe on a two-token side, exactly as class
//      membership does for a bare one. See `possessivePairRx`.
//
//   b. GENERAL MARKER. The Python rule ("no wait"), plus two new markers that
//      are unambiguous enough to work on any word: "no actually" and "I mean".
//      The replaced span is the Python span — the single word before the
//      marker, the marker, and the joint whitespace — with the duplicate
//      function word the deletion tends to leave behind ("… to Bob no wait to
//      Alice" -> "… to to Alice") collapsed afterwards, exactly as before.
//
//      CLAUSE RESTART, the general form of tier (b): when the text after the
//      marker RE-BEGINS the clause in front of it, the user restarted the
//      clause and the restart replaces it wholesale — "I want to meet Vivek,
//      no actually I want it Sharique" -> "I want it Sharique". The evidence
//      requirement — B shares A's first two tokens (case-insensitive, fillers
//      skipped), or its single first token when that token is a non-lexicon
//      content word — is what makes wholesale deletion safe on ARBITRARY
//      content: a name works exactly like a weekday, with no class list to
//      maintain. No shared re-beginning, no clause repair; the single-word
//      span above still applies under its own rules.
//
//   c. SANDWICH CONNECTIVES. "wait" and "instead" are too common as prose
//      to sit in the general joint ("please wait Monday"). They fire only
//      as a closed-class pair, including the compatible crosses (clock↔
//      number, weekday↔relative day): "Thursday wait Friday", "three
//      instead five".
//
//   d. PAST-DAY RESTATEMENT. "yesterday" cannot be listed with a future
//      day the way "today, tomorrow" can, so a pause between them is a
//      correction when the survivor ends the utterance or a prepositional
//      tail: "meet yesterday, tomorrow" → "meet tomorrow". A following
//      "and" or a new subject keeps the list / clause verbatim.
//
//   e. PARALLEL ANCHOR. A cue whose replacement is a fragment PLUS a
//      continuation — "I want to go tomorrow. I mean, day after to the
//      hackathon." — reaches none of the tiers above: "day after" is not a
//      closed class, so no pair forms, and the (b) span refuses a
//      cross-terminator replacement that is not a bare fragment because
//      deleting back into the previous sentence fuses two clauses into
//      garbage. This tier supplies the missing evidence from STRUCTURE
//      instead: a correction RESTATES something, so the replacement and the
//      thing it replaces are the same KIND of phrase. Find that parallel
//      phrase at the end of the clause the cue interrupts and the joint
//      resolves; fail to find it and the text ships verbatim. See
//      `resolveParallelAnchors`.
//
// The two tiers are one regex and one sweep, not two passes, because tier (a)
// has to be able to *veto* tier (b): when both sides of a marker are
// closed-class items of DIFFERENT classes the correction does not type-check
// ("Thursday no actually 3 o'clock" — you cannot correct a weekday into a
// time), which is the definition of ambiguous, so the joint passes verbatim
// and no other rule gets a second look at it. The one marker still largely
// exempt from that veto is "no wait": its span is a Python-parity contract
// pinned by `Goldens.swift`, so inside the parity domain it keeps deleting
// what it is handed. Python's comma-only gap never crossed a sentence
// terminator, so across one (which this engine now permits for the
// "no"-anchored markers) "no wait" obeys the same vetoes as "no actually".
//
// PARITY SUPERSEDED, measured. The blanket exemption was wrong on the LITERAL
// "no wait" — the noun phrase, not the interjection. Two shapes were measured
// through the shipping pipeline and both lost a word: "There is no wait at the
// DMV." -> "There at the DMV." and "The clinic has no wait time today." ->
// "The clinic time today." Python deleted those too, so this is a bug the port
// inherited rather than a divergence the port introduced, and parity is not a
// reason to keep shipping it. The exemption now carries two literal-use
// vetoes (`noWaitLiteralLeaders`, `noWaitObjectWords`) and is otherwise
// unchanged; every parity golden that exercises the interjection still holds.

import Foundation
import WispritKit

// MARK: - Engine

public enum SelfCorrection {
    /// True when `text` ends on a connective whose replacement has not been
    /// spoken yet ("…on Thursday umm no actually"). The live partial path
    /// defers display correction for exactly that frame: applying the engine
    /// there would delete the word being corrected with nothing to put in its
    /// place, and the very next partial resolves it either way.
    public static func endsMidCorrection(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let range = NSRange(text.startIndex..., in: text)
        return midCorrectionTail.firstMatch(in: text, range: range) != nil
    }

    /// Resolve every explicit self-correction in `text`.
    ///
    /// Pure, allocation-light and fast enough to run on every partial: a sweep
    /// only allocates when it actually rewrites something, and a string with no
    /// marker in it costs four regex scans and returns the input unchanged.
    public static func apply(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var text = text
        // A chain ("Tuesday no Wednesday no Thursday") already collapses inside
        // a single sweep — the cursor resumes AT the survivor — so the loop is
        // a fixpoint guarantee for the tiers that interact (a general-marker
        // deletion can expose a new duplicate, a collapsed duplicate can expose
        // a new joint), not the chain mechanism. Bounded so a pathological
        // input can never spin.
        for _ in 0..<maxPasses {
            let next = sweep(text)
            if next == text { break }
            text = next
        }
        return text
    }

    /// Upper bound on the fixpoint loop. Four is well past the observed need
    /// (one sweep changes, the second confirms) and keeps the worst case inside
    /// the <1 ms live budget.
    static let maxPasses = 4

    static func sweep(_ text: String) -> String {
        // Possessive date pair first — its evidence (same head noun on both
        // sides) is stronger than anything the joint sweep can establish, so
        // it gets first claim on the span. See `possessivePairRx`.
        var text = possessivePairRx.replacingAll(in: text, with: "$2")
        // Parallel prepositional restatement: "to marketing sorry to finance"
        // → "to finance". Same evidence shape as the possessive date pair —
        // the preposition repeats — so the weak connectives are safe here.
        text = parallelPrepRx.replacingAll(in: text, with: "$1$4")
        // Same-frame restatement across a pause: "as a gift, as a present"
        // → "as a present". The pause is required so "as a child as a parent"
        // (two roles, no correction) stays verbatim.
        text = sameFrameRx.replacingAll(in: text, with: "$1$3")
        // Past-day restatement: "yesterday" cannot be listed with a future
        // day the way "today, tomorrow" can, so a pause between them is a
        // correction ("meet yesterday, tomorrow" → "meet tomorrow"). A
        // following "and"/"or"/subject keeps the list or the new clause.
        text = applyPastDayRestatement(text)
        // Verb-form restatement across a pause: "it was given, giving me"
        // → "it was giving me". The be-auxiliary and the -ed/-en vs -ing
        // pair are the evidence; "the driver, driving" and "we shipped,
        // shipping tomorrow" stay verbatim.
        text = applyInflectionRestatement(text)
        text = applySandwichConnectives(text)
        // Repeat before pair: "the pet itself not pet pill" is a
        // restatement of an earlier word, not the adjacent pair
        // "itself not pet".
        text = applyNotRestatement(text)
        text = correctJoints(text)
        // Parallel anchor, last of the correction tiers: it runs only on what
        // the joint sweep DECLINED, so it is an extra attempt at an unresolved
        // cue and never a second opinion on a resolved one. That ordering is
        // what keeps every answer the tiers above give byte-identical.
        text = resolveParallelAnchors(text)
        // "scratch that" / "forget that" / "never mind" — keep only what
        // follows the last DIRECTIVE occurrence.
        text = applyScratch(text)
        text = applyRetract(text, probe: forgetProbeRx, rx: forgetRx, allowOpening: false)
        text = applyRetract(text, probe: neverMindProbeRx, rx: neverMindRx, allowOpening: false)
        // Same-utterance term echo: "HackerRank … had the rank" → the
        // earlier spelling. ASR splits a distinctive term into common
        // words; the first sighting is the evidence, no marker required.
        text = applyTermEcho(text)
        // Software-compound twin: "function for holdback" → "function
        // for rollback". The recognizer hears the rhyme; coding context
        // is the evidence, so a financial "holdback" stays.
        text = applySoftwareTwins(text)
        // Repeat until stable so "to to to" fully collapses.
        while true {
            let collapsed = dupRx.replacingAll(in: text, with: "$1")
            if collapsed == text { break }
            text = collapsed
        }
        return text
    }

    /// "scratch that" — delete everything through the LAST occurrence that is
    /// actually the directive, and keep the text after it.
    ///
    /// The Python rule was one greedy `^.*scratch that` substitution with no
    /// guard at all, which is fine for the imperative ("draft the email scratch
    /// that write the memo") and catastrophic for the transitive verb, where
    /// "that" is a determiner introducing the object rather than the marker's
    /// pronoun. Measured through the shipping pipeline: "Don't scratch that
    /// itch, it'll get worse." -> "itch, it'll get worse.", i.e. the sentence
    /// lost its subject, its verb and its negation.
    ///
    /// The guard is a lookback, not a lookahead, because a lookahead cannot
    /// work: a genuine directive is followed by arbitrary content, including
    /// the content words a determiner reading would predict ("scratch that
    /// today", "scratch that write the memo" — both pinned goldens). What the
    /// two readings do NOT share is what stands in FRONT of the verb. The
    /// directive is an imperative, so it opens the utterance or follows the
    /// clause it retracts; the transitive reading needs a negation, a modal, an
    /// infinitive "to" or a nominative subject to license it, and none of those
    /// can end a retracted clause. See `scratchLiteralLeaders`.
    static func applyScratch(_ text: String) -> String {
        applyRetract(text, probe: scratchProbeRx, rx: scratchRx, allowOpening: true)
    }

    /// "meet yesterday, tomorrow" / "meet yesterday umm today" → keep the
    /// later day. The pause is required; "yesterday tomorrow" as two days
    /// in a row stays. A list or a new clause after the survivor
    /// ("yesterday, tomorrow and Friday", "yesterday, tomorrow I'll go")
    /// is ordinary speech and stays verbatim.
    static func applyPastDayRestatement(_ text: String) -> String {
        // Cheap reject: both patterns require "yesterday".
        guard text.range(of: "yesterday", options: [.caseInsensitive, .literal]) != nil
        else { return text }
        func keepSurvivor(_ m: NSTextCheckingResult, _ ns: NSString) -> String? {
            let y = m.range(at: 1)
            guard y.location != NSNotFound else { return nil }
            let survivor = ns.substring(with: y)
            let end = m.range.location + m.range.length
            if end < ns.length {
                let rest = ns.substring(from: end)
                if let next = firstSpokenWord(rest),
                   !pastDayPhraseContinuations.contains(next) {
                    return nil
                }
            }
            return survivor
        }
        var text = pastDayForwardRx.replacing(in: text, keepSurvivor)
        text = pastDayBackRx.replacing(in: text, keepSurvivor)
        return text
    }

    /// "Thursday wait Friday" / "three instead five" — connectives that are
    /// too common as prose to sit in the general joint pattern (a bare
    /// "wait" would make every partial pay for it). Same-class sides only,
    /// including the compatible pairs (clock↔number, weekday↔relative day).
    static func applySandwichConnectives(_ text: String) -> String {
        guard text.range(of: "wait", options: [.caseInsensitive, .literal]) != nil
                || text.range(of: "instead", options: [.caseInsensitive, .literal]) != nil
        else { return text }
        return sandwichOnlyRx.replacing(in: text) { m, ns in
            guard let xClass = classIndex(m, sandwichXClassFirst),
                  let yClass = classIndex(m, sandwichYClassFirst),
                  classesCompatible(xClass, yClass) else { return nil }
            let y = m.range(at: sandwichYWhole)
            guard y.location != NSNotFound else { return nil }
            return ns.substring(with: y)
        }
    }

    /// A follow-up that is only the correction — "not a pet pill",
    /// "not pet, pill", "not pet but pill". The rejected word has to
    /// already stand in an earlier utterance; the session applies that
    /// as a retro-edit so the cue is not inserted as prose.
    public struct NotRestatement: Equatable, Sendable {
        public var rejected: String
        public var replacement: String
    }

    /// Parse a standalone "not X Y" cue. nil when the utterance is a
    /// real sentence ("I did not go") or a lone negation ("not a problem").
    public static func standaloneNotCorrection(_ text: String) -> NotRestatement? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let ns = trimmed as NSString
        guard let m = standaloneNotRx.allMatches(trimmed, ns).first,
              m.range.location == 0, m.range.length == ns.length
        else { return nil }
        let xRange = m.range(at: 1)
        let yRange = m.range(at: 2)
        guard xRange.location != NSNotFound, yRange.location != NSNotFound else { return nil }
        let x = comparisonForm(ns.substring(with: xRange))
        let yRaw = ns.substring(with: yRange)
        let y = comparisonForm(yRaw)
        guard isCorrectionContent(x), isCorrectionContent(y), x != y else { return nil }
        return NotRestatement(rejected: x, replacement: yRaw)
    }

    /// True when `word` occurs as a whole token in `text`.
    public static func containsWord(_ word: String, in text: String) -> Bool {
        let needle = comparisonForm(word)
        guard !needle.isEmpty else { return false }
        return lastOccurrence(of: needle, in: text) != nil
    }

    /// "the pet itself not a pet pill" → keep the replacement. The speaker
    /// named the wrong word, then negated it and supplied the right one.
    /// Function-word "not" ("I did not go") stays: both sides have to be
    /// content words, length ≥ 3.
    ///
    /// WITHDRAWN, measured: the bare-pair form "X not Y" → "Y". It read
    /// "pet not pill" as a correction, which it can be — but the identical
    /// shape is ordinary English contrastive negation, where the speaker
    /// ASSERTS X and denies Y. The rule returns the denied word, so it does
    /// not merely delete, it inverts the sentence's meaning. Measured through
    /// the shipping pipeline on prose that carries no correction at all:
    ///
    ///   "It was luck, not skill."            -> "It was skill."
    ///   "We need speed, not perfection."     -> "We need perfection."
    ///   "The problem is culture, not tooling."-> "The problem is tooling."
    ///   "He wanted coffee not tea."          -> "He wanted tea."
    ///
    /// …and on the ls-test-clean rung, two clips of ordinary narration:
    /// "but he dared not interfere" -> "but he interfere" (the semi-modal
    /// reading of "not"), and "the farm Olaf not yet I answered" -> "the farm
    /// yet I answered" (the fixed adverbial "not yet").
    ///
    /// The two readings are not separable from the text. "send it to marketing
    /// not finance" (correction) and "He wanted coffee not tea" (assertion)
    /// have the same shape, the same punctuation and the same parts of speech;
    /// only intonation and intent tell them apart, and neither survives
    /// transcription. Guarding the leader (a semi-modal) and the follower (a
    /// "not"-idiom adverb) removes the two measured clips but leaves the
    /// inversion class untouched, so the guards would buy a corpus number
    /// rather than correctness.
    ///
    /// So the pair form is gone and its cases pass through verbatim. The
    /// REPEAT form below survives because its evidence is real: "not" precedes
    /// the REJECTED word there ("not a pet pill"), which is the standard
    /// English contrastive order, AND the rejected word must already stand in
    /// the clause for the rewrite to have a target.
    static func applyNotRestatement(_ text: String) -> String {
        guard text.range(of: " not ", options: [.caseInsensitive, .literal]) != nil
        else { return text }
        return applyNotRepeatRestatement(text)
    }

    /// "the pet itself not a pet pill" → "the pill itself". The rejected
    /// word has to already stand in the clause; the cue repeats it and
    /// names the replacement. Only the last earlier occurrence is
    /// rewritten, so a list of pets is not flattened.
    private static func applyNotRepeatRestatement(_ text: String) -> String {
        let ns = text as NSString
        guard let m = notRepeatRx.firstMatch(text, ns, from: 0) else { return text }
        let xRange = m.range(at: 1)
        let yRange = m.range(at: 2)
        guard xRange.location != NSNotFound, yRange.location != NSNotFound else { return text }
        let x = comparisonForm(ns.substring(with: xRange))
        let yRaw = ns.substring(with: yRange)
        let y = comparisonForm(yRaw)
        guard isCorrectionContent(x), isCorrectionContent(y), x != y else { return text }
        // "not yet", "not only", "not once" — "not" plus one of these is a
        // fixed adverbial, so the word after it is not a rejected NOUN and the
        // word after that is not its replacement. The pair form died on
        // exactly this shape ("the farm Olaf not yet I answered"); the repeat
        // form reaches it far less often, but the veto costs one lookup and
        // the failure it prevents is a deleted word.
        guard !notIdiomAdverbs.contains(x) else { return text }
        // "writing or not writing any code" is a whether-or-not, not
        // "not a pet pill". The rejected word repeating after "or not"
        // is the construction; rewriting it deletes the verbs.
        if let cue = tokenBefore(ns, m.range.location), cue.text == "or",
           wordBefore(ns, cue.start) == x {
            return text
        }
        let prefix = ns.substring(to: m.range.location)
        guard let earlier = lastOccurrence(of: x, in: prefix) else { return text }
        var rebuilt = prefix
        let start = rebuilt.index(rebuilt.startIndex, offsetBy: earlier.location)
        let end = rebuilt.index(start, offsetBy: earlier.length)
        rebuilt.replaceSubrange(start..<end, with: yRaw)
        rebuilt += ns.substring(from: m.range.location + m.range.length)
        while rebuilt.contains("  ") {
            rebuilt = rebuilt.replacingOccurrences(of: "  ", with: " ")
        }
        return rebuilt.trimmingCharacters(in: .whitespaces)
    }

    private static func isCorrectionContent(_ word: String) -> Bool {
        word.count >= 3 && !correctionFunctionWords.contains(word)
    }

    /// Last whole-word occurrence of `word` (comparison-form) in `text`.
    private static func lastOccurrence(of word: String, in text: String) -> NSRange? {
        let ns = text as NSString
        var i = ns.length
        while i > 0 {
            while i > 0, isWhitespace(ns.character(at: i - 1)) { i -= 1 }
            guard i > 0 else { return nil }
            let end = i
            while i > 0, !isWhitespace(ns.character(at: i - 1)) { i -= 1 }
            let range = NSRange(location: i, length: end - i)
            if comparisonForm(ns.substring(with: range)) == word { return range }
        }
        return nil
    }

    /// First non-filler word in `s`, comparison-form, skipping leading
    /// punctuation. nil when the tail holds no word.
    private static func firstSpokenWord(_ s: String) -> String? {
        let ns = s as NSString
        var i = 0
        let n = ns.length
        while i < n {
            while i < n, isWhitespace(ns.character(at: i))
                    || isSentenceTerminator(ns.character(at: i)) { i += 1 }
            guard i < n else { return nil }
            let start = i
            while i < n, !isWhitespace(ns.character(at: i)) { i += 1 }
            let word = comparisonForm(ns.substring(with: NSRange(location: start, length: i - start)))
            if !word.isEmpty, !fillerSet.contains(word) { return word }
        }
        return nil
    }

    /// "HackerRank … had the rank" / "InsForge … inns forge" → keep the
    /// earlier spelling. The recognizer often splits a distinctive term
    /// into common words the second time it hears it. No marker: the
    /// first sighting is the evidence.
    ///
    /// Fenced so "I finished the HackerRank then I had the rank of
    /// captain" stays verbatim — the later span has to sound like the
    /// term, share a prefix or suffix, and not be a "rank of …" phrase.
    static func applyTermEcho(_ text: String) -> String {
        guard text.contains(where: { $0.isUppercase }) else { return text }
        let tokens = echoTokens(text)
        guard tokens.count >= 3, tokens.contains(where: isEchoAnchor) else { return text }
        var best: (term: String, range: NSRange, score: Double)?
        for (index, anchor) in tokens.enumerated() where isEchoAnchor(anchor) {
            var start = index + 1
            while start < tokens.count {
                for length in [4, 3, 2] {
                    let end = start + length
                    guard end <= tokens.count else { continue }
                    let window = Array(tokens[start..<end])
                    if window.contains(where: { $0.lower == anchor.lower }) { continue }
                    if echoOpenerVeto.contains(window[0].lower) { continue }
                    if start > 0, echoOpenerVeto.contains(tokens[start - 1].lower) {
                        continue
                    }
                    if window.contains(where: { echoFollowerVeto.contains($0.lower) }) {
                        continue
                    }
                    if echoWindowCarriesInflection(window) { continue }
                    guard echoAffixOverlaps(anchor.lower, window) else { continue }
                    if end < tokens.count, echoFollowerVeto.contains(tokens[end].lower) {
                        continue
                    }
                    let score = echoScore(anchor.raw, window)
                    guard score >= echoFloor else { continue }
                    if let current = best, score <= current.score { continue }
                    guard let first = window.first(where: { !echoGlue.contains($0.lower) })
                    else { continue }
                    let last = window[window.count - 1].range
                    let range = NSRange(location: first.range.location,
                                        length: last.location + last.length - first.range.location)
                    best = (anchor.raw, range, score)
                }
                start += 1
            }
        }
        guard let hit = best else { return text }
        let ns = text as NSString
        return ns.substring(to: hit.range.location)
            + hit.term
            + ns.substring(from: hit.range.location + hit.range.length)
    }

    /// "it was given, giving me a 7" → "it was giving me a 7".
    ///
    /// ASR often emits the wrong verb form, then the right one after a
    /// comma. Keep the later form when a be-auxiliary licenses the first
    /// word as a participle and the two share a stem. A pause is required
    /// so "was given giving" (no hesitation) stays, and a determiner or a
    /// following "and"/"or" keeps the participial and the list.
    static func applyInflectionRestatement(_ text: String) -> String {
        // Cheap reject: the pair is always a be-auxiliary plus an -ing form.
        // The live path re-runs this on every partial, so a 200-word
        // utterance with neither must not tokenize.
        guard text.range(of: "ing", options: [.caseInsensitive, .literal]) != nil,
              inflectionAuxiliaryRx.matches(text) else { return text }
        var text = text
        while true {
            let next = applyInflectionRestatementOnce(text)
            if next == text { return text }
            text = next
        }
    }

    private static func applyInflectionRestatementOnce(_ text: String) -> String {
        let tokens = echoTokens(text)
        guard tokens.count >= 3 else { return text }
        let ns = text as NSString
        for (index, first) in tokens.enumerated() {
            guard isCorrectionContent(first.lower),
                  !closedClassWordRx.matches(first.lower) else { continue }
            guard let secondIndex = nextContentToken(in: tokens, after: index)
            else { continue }
            let second = tokens[secondIndex]
            guard isCorrectionContent(second.lower),
                  !closedClassWordRx.matches(second.lower),
                  isInflectionPair(first.lower, second.lower) else { continue }
            guard isInflectionPause(tokens, from: index, to: secondIndex, ns: ns)
            else { continue }
            if let leader = contentToken(in: tokens, before: index) {
                if inflectionDeterminers.contains(leader.lower) { continue }
                guard inflectionAuxiliaries.contains(leader.lower) else { continue }
            } else {
                continue
            }
            if let follower = nextContentToken(in: tokens, after: secondIndex),
               inflectionListFollowers.contains(tokens[follower].lower) {
                continue
            }
            let start = first.range.location
            let end = second.range.location + second.range.length
            return ns.substring(to: start)
                + second.raw
                + ns.substring(from: end)
        }
        return text
    }

    /// "the last function for holdback" → "the last function for rollback".
    ///
    /// Whole-word only, and only when the utterance is already about a
    /// function/method or a HackerRank-style test. "There's a holdback on
    /// the payment" is ordinary English and stays.
    static func applySoftwareTwins(_ text: String) -> String {
        guard text.range(of: "holdback", options: [.caseInsensitive, .literal]) != nil
        else { return text }
        let tokens = echoTokens(text)
        guard !tokens.isEmpty else { return text }
        let lowers = tokens.map(\.lower)
        let codingContext = lowers.contains("hackerrank")
            && (lowers.contains("function") || lowers.contains("functions")
                || (lowers.contains("test") && lowers.contains("cases")))
        var edits: [(range: NSRange, replacement: String)] = []
        for (index, token) in tokens.enumerated() where token.lower == "holdback" {
            let namedFor = index >= 2
                && tokens[index - 1].lower == "for"
                && softwareTwinLeaders.contains(tokens[index - 2].lower)
            guard namedFor || codingContext else { continue }
            edits.append((token.range, matchTwinCase(token.raw, "rollback")))
        }
        guard !edits.isEmpty else { return text }
        let ns = text as NSString
        var out = ""
        var cursor = 0
        for edit in edits {
            if edit.range.location > cursor {
                out += ns.substring(with: NSRange(location: cursor,
                                                  length: edit.range.location - cursor))
            }
            out += edit.replacement
            cursor = edit.range.location + edit.range.length
        }
        if cursor < ns.length { out += ns.substring(from: cursor) }
        return out
    }

    private static func nextContentToken(in tokens: [EchoToken], after index: Int) -> Int? {
        var i = index + 1
        while i < tokens.count {
            if !fillerSet.contains(tokens[i].lower) { return i }
            i += 1
        }
        return nil
    }

    private static func contentToken(in tokens: [EchoToken], before index: Int) -> EchoToken? {
        var i = index - 1
        while i >= 0 {
            if !fillerSet.contains(tokens[i].lower) { return tokens[i] }
            i -= 1
        }
        return nil
    }

    private static func isInflectionPause(_ tokens: [EchoToken], from: Int, to: Int,
                                          ns: NSString) -> Bool {
        guard to > from else { return false }
        for i in (from + 1)..<to where !fillerSet.contains(tokens[i].lower) {
            return false
        }
        let start = tokens[from].range.location + tokens[from].range.length
        let end = tokens[to].range.location
        guard end >= start else { return false }
        let gap = ns.substring(with: NSRange(location: start, length: end - start))
        if gap.contains(where: { ".!?\u{2026}".contains($0) }) { return false }
        return gap.contains(",") || to > from + 1
    }

    private static func isInflectionPair(_ a: String, _ b: String) -> Bool {
        guard a != b else { return false }
        guard (isPastVerbForm(a) && isIngVerbForm(b))
                || (isIngVerbForm(a) && isPastVerbForm(b)) else { return false }
        let left = inflectionStem(a)
        let right = inflectionStem(b)
        return left.count >= 3 && left == right
    }

    private static func isIngVerbForm(_ word: String) -> Bool {
        word.hasSuffix("ing") && word.count >= 6
    }

    private static func isPastVerbForm(_ word: String) -> Bool {
        (word.hasSuffix("ed") && word.count >= 6)
            || (word.hasSuffix("en") && word.count >= 5)
    }

    private static func inflectionStem(_ word: String) -> String {
        var stem = word
        for suffix in ["ing", "ied", "ies", "ed", "en", "es", "s"]
        where stem.count > suffix.count + 2 && stem.hasSuffix(suffix) {
            stem = String(stem.dropLast(suffix.count))
            if stem.count >= 3, let last = stem.last, stem.dropLast().last == last {
                stem.removeLast()
            }
            return stem
        }
        return stem
    }

    private static func matchTwinCase(_ sample: String, _ replacement: String) -> String {
        if sample.count > 1, sample == sample.uppercased() {
            return replacement.uppercased()
        }
        if sample.first?.isUppercase == true {
            return replacement.prefix(1).uppercased() + replacement.dropFirst()
        }
        return replacement
    }

    private static func echoTokens(_ text: String) -> [EchoToken] {
        let ns = text as NSString
        var tokens: [EchoToken] = []
        var i = 0
        let n = ns.length
        while i < n {
            while i < n, !isLetter(ns.character(at: i)) { i += 1 }
            guard i < n else { break }
            let start = i
            while i < n, isLetter(ns.character(at: i)) || ns.character(at: i) == 0x27
                    || ns.character(at: i) == 0x2019 { i += 1 }
            let range = NSRange(location: start, length: i - start)
            let raw = ns.substring(with: range).replacingOccurrences(of: "\u{2019}", with: "'")
            let lower = comparisonForm(raw)
            if !lower.isEmpty { tokens.append(EchoToken(range: range, raw: raw, lower: lower)) }
        }
        return tokens
    }

    private static func isLetter(_ c: unichar) -> Bool {
        guard let scalar = UnicodeScalar(c) else { return false }
        return CharacterSet.letters.contains(scalar)
    }

    /// Whether a word is a term the echo tier may snap a later span back to.
    ///
    /// An INTERNAL capital, always — never length alone. The tier's whole
    /// premise is that the recognizer spelled a distinctive term correctly
    /// once and then split it into common words; "distinctive" has to be a
    /// property of the SPELLING, because that is the only thing separating a
    /// term from prose. Internal capitalization is that property, and it is
    /// one an ordinary English word cannot have.
    ///
    /// The `letters.count >= 8` shortcut this replaces admitted any long
    /// common word as an anchor, and long common words are exactly what
    /// narration is made of. Measured on the ls-test-clean rung, two clips:
    ///
    ///   "…whilst the rest of them detained her family…"
    ///     -> "…whilst the rest of themselves her family…"   (anchor
    ///        "themselves", 10 letters, from earlier in the sentence; the
    ///        merge ate the verb "detained")
    ///   "…a rare thing in America, a pleasantly toned voice…"
    ///     -> "…a rare thing in American toned voice…"       (anchor
    ///        "American", 8 letters, from "a strong American accent")
    ///
    /// Both intended cases keep working, because both were always camelCase:
    /// "HackerRank" and "InsForge" satisfy the internal capital directly and
    /// never needed the length shortcut.
    private static func isEchoAnchor(_ token: EchoToken) -> Bool {
        let letters = token.raw.filter(\.isLetter)
        guard letters.count >= 6 else { return false }
        guard !correctionFunctionWords.contains(token.lower),
              !closedClassWordRx.matches(token.lower) else { return false }
        return letters.dropFirst().contains(where: \.isUppercase)
    }

    /// Whether the span the echo tier would swallow contains an inflected
    /// content word — a verb or an adverb.
    ///
    /// The second fence, independent of the anchor rule. A term that the
    /// recognizer split into common words splits into STEMS ("HackerRank" ->
    /// "had the rank", "InsForge" -> "inns forge"); it does not split into
    /// something carrying tense or an adverbial ending, because those endings
    /// are grammar the surrounding sentence supplied, not sound the term
    /// contains. So a window holding one is a window holding real syntax, and
    /// merging it deletes a word the speaker meant — "them detained" ->
    /// "themselves" eats the clause's verb, "America, a pleasantly" eats its
    /// adverb.
    private static func echoWindowCarriesInflection(_ window: [EchoToken]) -> Bool {
        window.contains { token in
            let word = token.lower
            guard word.count >= 5 else { return false }
            return word.hasSuffix("ed") || word.hasSuffix("ing") || word.hasSuffix("ly")
        }
    }

    private static func echoAffixOverlaps(_ term: String, _ window: [EchoToken]) -> Bool {
        let content = window.map(\.lower).filter { !echoGlue.contains($0) && $0.count >= 3 }
        guard content.count >= 2, let first = content.first, let last = content.last
        else { return false }
        return term.hasSuffix(last) || term.hasPrefix(first)
    }

    private static func echoScore(_ term: String, _ window: [EchoToken]) -> Double {
        let joined = window.map(\.raw).joined(separator: " ")
        let collapsed = window.map(\.lower).joined()
        let content = window.map(\.lower).filter { !echoGlue.contains($0) }.joined()
        return max(PhoneticScorer.score(term, joined),
                   PhoneticScorer.score(term, collapsed),
                   content.count >= 6 ? PhoneticScorer.score(term, content) : 0)
    }

    /// Shared cut for "scratch that" / "forget that" / "never mind": delete
    /// through the last directive occurrence and keep the text after it.
    /// `allowOpening` is true only for "scratch that" — that phrase is the
    /// classic utterance-initial imperative. "forget that" / "never mind"
    /// opening an utterance are ordinary English ("never mind the noise")
    /// and must stay verbatim.
    static func applyRetract(_ text: String, probe: Rx, rx: Rx, allowOpening: Bool) -> String {
        guard probe.matches(text) else { return text }
        let ns = text as NSString
        var cut: Int?
        for m in rx.allMatches(text, ns)
        where isRetractDirective(at: m.range.location, ns, allowOpening: allowOpening) {
            cut = m.range.location + m.range.length
        }
        guard let cut else { return text }
        return ns.substring(from: cut)
    }

    private static func isRetractDirective(at start: Int, _ ns: NSString,
                                           allowOpening: Bool) -> Bool {
        guard let leader = wordBefore(ns, start) else { return allowOpening }
        return !scratchLiteralLeaders.contains(leader)
    }

    /// Comparison form of the last non-filler word before `index`, nil when the
    /// text in front of it holds no word at all.
    private static func wordBefore(_ ns: NSString, _ index: Int) -> String? {
        tokenBefore(ns, index)?.text
    }

    /// `wordBefore` with the offset kept: the parallel-preposition rules need
    /// to compare that word AND, when it matches, delete from where it starts.
    private static func tokenBefore(_ ns: NSString, _ index: Int) -> (start: Int, text: String)? {
        var i = min(index, ns.length)
        while i > 0 {
            while i > 0, isWhitespace(ns.character(at: i - 1)) { i -= 1 }
            guard i > 0 else { return nil }
            let end = i
            while i > 0, !isWhitespace(ns.character(at: i - 1)) { i -= 1 }
            let word = comparisonForm(ns.substring(with: NSRange(location: i, length: end - i)))
            if !word.isEmpty, !fillerSet.contains(word) { return (start: i, text: word) }
        }
        return nil
    }

    /// One left-to-right sweep over the correction joints. The cursor only ever
    /// moves forward, so the sweep is linear in the number of joints.
    static func correctJoints(_ text: String) -> String {
        let ns = text as NSString
        guard var match = jointRx.firstMatch(text, ns, from: 0),
              match.numberOfRanges > yClassFirst + classCount - 1 else { return text }
        var out = ""
        out.reserveCapacity(ns.length)
        var cursor = 0
        while true {
            // Exactly one of the two X branches participates: the closed-class
            // item, or the single spoken word tier (b) works on.
            let xClassRange = match.range(at: xWhole)
            let x = xClassRange.location == NSNotFound ? match.range(at: xWord) : xClassRange
            // Unreachable — the alternation is not optional — but the pipeline's
            // contract is that no stage ever raises, so a pattern edit that
            // broke the group layout must degrade to verbatim, not to a trap.
            guard x.location != NSNotFound else { return text }
            let xEnd = x.location + x.length
            let y = match.range(at: yWhole)
            let xClass = classIndex(match, xClassFirst)
            let yClass = y.location == NSNotFound ? nil : classIndex(match, yClassFirst)
            let next: Int
            if let xClass, let yClass, classesCompatible(xClass, yClass) {
                // Tier (a). Keep Y, drop X and the joint; resume AT Y so
                // "Tuesday no Wednesday no Thursday" resolves in this sweep.
                out += ns.substring(with: NSRange(location: cursor,
                                                  length: match.range.location - cursor))
                next = y.location
            } else if let marker = generalMarker(match),
                      let plan = repairPlan(marker, x, y, ns, xClass, yClass,
                                            matchEnd: match.range.location + match.range.length,
                                            cursor: cursor) {
                switch plan {
                case .restart(let aStart, let bStart):
                    // Clause restart. B re-begins the clause that ends at X,
                    // so B replaces it wholesale: everything from the clause
                    // start through the marker goes, and B — casing,
                    // punctuation and all — stays verbatim.
                    out += ns.substring(with: NSRange(location: cursor,
                                                      length: aStart - cursor))
                    next = bStart
                case .span(let drop):
                    // Tier (b). The Python span: the single word before the
                    // marker, the marker, and the joint whitespace — widened to
                    // the function word in front of X when the replacement
                    // repeats it (`spanDrop`). Y — which this pattern consumed
                    // and the Python one never did — is re-emitted verbatim, so
                    // the result is identical either way.
                    out += ns.substring(with: NSRange(location: cursor,
                                                      length: drop - cursor))
                    if y.location != NSNotFound { out += ns.substring(with: y) }
                    next = match.range.location + match.range.length
                }
            } else {
                // Ambiguous. Verbatim, and resume just past X so a later joint
                // in the same sentence still gets its own look — but not so far
                // back that the vetoed joint can be re-read with a new X.
                out += ns.substring(with: NSRange(location: cursor, length: xEnd - cursor))
                next = xEnd
            }
            cursor = next
            guard let more = jointRx.firstMatch(text, ns, from: cursor) else { break }
            match = more
        }
        out += ns.substring(from: cursor)
        return out
    }

    /// What a general marker may do to a joint its vetoes allow — repair the
    /// whole clause, delete the single-word span — or nil when they refuse.
    private static func repairPlan(_ marker: GeneralMarker, _ x: NSRange, _ y: NSRange,
                                   _ ns: NSString, _ xClass: Int?, _ yClass: Int?,
                                   matchEnd: Int, cursor: Int) -> Repair? {
        let xEnd = x.location + x.length
        // B — the replacement text — starts at Y when the pattern consumed a
        // closed-class Y, otherwise right after the marker's trailing gap.
        let bStart = y.location == NSNotFound ? matchEnd : y.location
        let crossed = terminatorCount(ns, from: xEnd, to: bStart)
        guard isCorrection(marker, x, ns, xClass, yClass, crossed: crossed,
                           bStart: bStart) else { return nil }
        if let aStart = restartStart(x, bStart: bStart, ns, floor: cursor) {
            return .restart(aStart: aStart, bStart: bStart)
        }
        // Across a terminator the span may only replace with a content word:
        // a clause opener after "No," is a denial of the previous sentence,
        // not a replacement ("I finished the report. No, actually I think we
        // should celebrate." stays verbatim).
        //
        // …and it may only replace with a bare FRAGMENT. The single-word span
        // reaches back into the PREVIOUS sentence and deletes its last word, so
        // when the text after the marker is itself a whole clause the edit
        // fuses two sentences into garbage rather than correcting anything:
        // "I finished the report. No, actually Jane finished it." measured as
        // "I finished the Jane finished it." The restart tier above is the
        // mechanism for a re-stated CLAUSE and it already declined this one
        // (the clauses share no re-beginning — "finished" appears in both, but
        // an incidentally shared verb is not evidence of a restart, only a
        // shared opening is). What is left for the span is the shape it was
        // measured to get right — a replacement noun phrase standing alone
        // after the marker, "…to Viveque. No, actually, Shariq." — so the span
        // now requires that shape as its evidence and passes everything else
        // through verbatim. See `isReplacementFragment`.
        if crossed > 0 {
            let b = restartTokens(ns, from: bStart, to: ns.length,
                                  stopAtSentenceEnd: true, limit: fragmentWindow + 1)
            guard let head = b.first, !hedgeLeaders.contains(head.text) else { return nil }
            guard isReplacementFragment(b) else { return nil }
        }
        return .span(drop: spanDrop(x, ns, bStart: bStart, crossed: crossed))
    }

    /// Where the tier (b) span starts deleting: the single word before the
    /// marker (the Python span), or — the parallel-preposition shape — that
    /// word AND the function word in front of it.
    ///
    /// The extension is what makes the escape above USABLE. The span deletes
    /// only X, so "meet at three no wait at four" would resolve to "meet at at
    /// four": the replacement brings its own preposition and X's is left
    /// stranded. `dupRx` used to clean that up, but its "in in"/"on on" entries
    /// were removed for deleting from correction-free speech ("Please hand it
    /// in in March.") and must not come back — a collapse rule cannot tell the
    /// grammatical double from the artifact, because by the time it runs the
    /// marker that made one an artifact is gone.
    ///
    /// So the deletion is made correct at the point where the marker is still
    /// visible. Marker-scoped, single-sentence, and gated on the SAME equality
    /// as the escape: the first word after the marker is a function word and it
    /// repeats the word before X, which is what "restating the phrase" looks
    /// like. "send it to Bob no wait to Alice" takes this route and lands on
    /// the byte-identical "send it to Alice" it used to reach through `dupRx`.
    private static func spanDrop(_ x: NSRange, _ ns: NSString, bStart: Int, crossed: Int) -> Int {
        let drop = lastTokenStart(x, ns)
        guard crossed == 0,
              let after = restartTokens(ns, from: bStart, to: ns.length,
                                        stopAtSentenceEnd: true, limit: 1).first,
              parallelFunctionWords.contains(after.text),
              let before = tokenBefore(ns, x.location), before.text == after.text
        else { return drop }
        return before.start
    }

    /// Whether the tokens after a cross-terminator marker are a replacement
    /// noun phrase rather than a new clause: one bare token ("Shariq.",
    /// "production."), or two whose first opens a noun phrase ("the footer",
    /// "next quarter"). Anything longer, or a two-token pair that starts with
    /// its own subject ("Jane finished"), is prose the span must not touch.
    ///
    /// Deliberately shape evidence rather than token evidence: a shared token
    /// between the two clauses is NOT usable here, because the false-fire that
    /// motivated the rule shares one ("…the report. No, actually Jane finished
    /// it."). Phonetic evidence — the mishear-restatement channel — would be
    /// the natural third signal, but `WispritPostProcess` depends on
    /// `WispritKit` alone (Package.swift), so `WispritCorrections`'
    /// DoubleMetaphone is out of reach and a second copy of it is not worth a
    /// case the shape rule already covers.
    private static func isReplacementFragment(_ b: [(start: Int, text: String)]) -> Bool {
        switch b.count {
        case 1: return true
        case 2: return fragmentOpeners.contains(b[0].text)
        default: return false
        }
    }

    /// Upper bound, in words, on a cross-terminator replacement fragment.
    static let fragmentWindow = 2

    private enum Repair {
        case restart(aStart: Int, bStart: Int)
        /// `drop` is where the deletion starts — see `spanDrop`.
        case span(drop: Int)
    }

    /// Whether a general marker may correct at this joint at all. `crossed` is
    /// the number of sentence terminators between X and B.
    private static func isCorrection(_ marker: GeneralMarker, _ x: NSRange, _ ns: NSString,
                                     _ xClass: Int?, _ yClass: Int?, crossed: Int,
                                     bStart: Int) -> Bool {
        // Sentence-boundary veto, narrowed by anchor. The "no"-anchored
        // markers may cross ONE terminator: the recognizer routinely
        // punctuates the pause before a correction ("Vivek. No, actually …"),
        // and a "No," opening the next sentence is a denial/correction
        // discourse cue, not prose. "I mean" is the hedge that caused the
        // original regression ("…is fine. I mean it.") and still refuses every
        // terminator — Python's comma-only gap could never match one, so
        // refusing there is what parity actually means.
        switch marker {
        case .iMean, .iMeant: guard crossed == 0 else { return false }
        case .noWait, .noActually, .waitNo: guard crossed <= 1 else { return false }
        }
        // "no wait" is the Python marker and its span is a parity contract —
        // but the parity domain is what Python could match, and that never
        // crossed a terminator. Inside it, "no wait" keeps deleting whatever
        // it is handed; across one, it obeys the same vetoes as "no actually".
        //
        // Minus the LITERAL reading, which parity does not protect: "no wait"
        // is also an ordinary noun phrase, and there the "no" is a determiner
        // on "wait", not an interjection. Two high-precision signals, both
        // measured on the false fires in the header note, and both of them
        // shapes the interjection cannot take:
        //   * the word the span would delete is a copula / possession verb /
        //     preposition ("there IS no wait", "the clinic HAS no wait") — the
        //     interjection replaces the content word it follows, and a
        //     correction never replaces "is";
        //   * "wait" carries a noun continuation ("no wait TIME", "no wait AT
        //     the DMV") — the interjection is a complete utterance, so what
        //     follows it is the replacement, never the phrase's own tail.
        // "…to Bob no wait to Alice" and "…three no wait four pm" are untouched
        // by both: "Bob"/"three" are content, and "to"/"four" are not tails.
        //
        // Signal two carries an EQUALITY ESCAPE, because the bare prepositions
        // in its list are ambiguous in a way the noun tails are not: "at" ends
        // the literal phrase in "no wait AT the DMV" and OPENS the replacement
        // in "meet at three no wait AT four". What separates them is the word
        // in front of X. A correction restates a phrase, so the preposition
        // after the marker repeats the one before X ("meet AT three … AT
        // four"); the literal noun phrase cannot take that shape, because its
        // "at" belongs to "wait" and has nothing to parallel ("They promised no
        // wait at signup" — before-X is "they"). Measured cost of not having
        // this: "meet at three no wait at four", "meet him on Monday no wait on
        // Tuesday" and "the deadline is in April no wait in May" all resolved
        // before the literal-use guards shipped and passed through verbatim
        // after. The escape restores exactly those and nothing else — the
        // preposition entries stay in the list, so every literal keep the
        // guards were added for is still vetoed.
        if marker == .noWait, crossed == 0 {
            if xClass == nil, noWaitLiteralLeaders.contains(leaderWord(x, ns)) { return false }
            if let after = restartTokens(ns, from: bStart, to: ns.length,
                                         stopAtSentenceEnd: true, limit: 1).first,
               noWaitObjectWords.contains(after.text),
               after.text != wordBefore(ns, x.location) { return false }
            return true
        }
        // Cross-class veto — tier (a) looked at this joint and refused it.
        if xClass != nil, yClass != nil { return false }
        // Discourse-hedge veto: "no actually" and "I mean" are also ordinary
        // conversational filler ("so I mean we should go", "well no actually
        // that's fine", "what I mean is …"). A correction replaces a CONTENT
        // word, so a function word or interjection in front of the marker means
        // the user is talking, not correcting.
        if xClass == nil, hedgeLeaders.contains(leaderWord(x, ns)) { return false }
        return true
    }

    /// The lowercased last token of X — the single word a tier (b) span would
    /// delete, even when the pattern matched a multi-token closed-class item.
    private static func leaderWord(_ x: NSRange, _ ns: NSString) -> String {
        let start = lastTokenStart(x, ns)
        return ns.substring(with: NSRange(location: start,
                                          length: x.location + x.length - start)).lowercased()
    }

    /// The clause-restart evidence check: start of the deleted span when the
    /// text after the marker re-begins the clause that ends at X, nil when the
    /// evidence is missing. A = the clause ending at X — from the last
    /// sentence start (or `floor`, the sweep cursor, so a restart can never
    /// reach back into text an earlier joint already resolved), capped at
    /// `restartWindow` words. B = what follows the marker, up to its own
    /// sentence end. The deleted span is [aStart, bStart), which by
    /// construction crosses at most the one terminator the narrowed veto
    /// already allowed.
    private static func restartStart(_ x: NSRange, bStart: Int, _ ns: NSString,
                                     floor: Int) -> Int? {
        var clauseStart = floor
        var i = x.location
        while i > floor {
            let c = ns.character(at: i - 1)
            if isSentenceTerminator(c) || c == 0x0A || c == 0x0D {
                clauseStart = i
                break
            }
            i -= 1
        }
        let a = Array(restartTokens(ns, from: clauseStart, to: x.location + x.length,
                                    stopAtSentenceEnd: false, limit: Int.max)
            .suffix(restartWindow))
        guard let first = a.first else { return nil }
        let b = restartTokens(ns, from: bStart, to: ns.length,
                              stopAtSentenceEnd: true, limit: a.count)
        var shared = 0
        for (ta, tb) in zip(a, b) {
            guard ta.text == tb.text else { break }
            shared += 1
        }
        if shared >= 2 { return first.start }
        // One shared token is enough only when it is a non-lexicon content
        // word — a name re-begins a clause the way "I" or "the" never can.
        if shared == 1, !restartFunctionWords.contains(a[0].text),
           !closedClassWordRx.matches(a[0].text) { return first.start }
        return nil
    }

    /// Upper bound, in words, on the clause a restart may delete.
    static let restartWindow = 12

    /// Whitespace-delimited tokens of `ns` in `from..<to`, fillers skipped,
    /// each carrying its start offset and comparison form (lowercased, edge
    /// punctuation stripped, curly apostrophe normalized). `stopAtSentenceEnd`
    /// cuts the list at the first token that closes a sentence — B never reads
    /// past its own sentence. `limit` bounds the work, not the meaning.
    private static func restartTokens(_ ns: NSString, from: Int, to: Int,
                                      stopAtSentenceEnd: Bool,
                                      limit: Int) -> [(start: Int, text: String)] {
        var tokens: [(start: Int, text: String)] = []
        var i = from
        while i < to, tokens.count < limit {
            while i < to, isWhitespace(ns.character(at: i)) { i += 1 }
            guard i < to else { break }
            let start = i
            var closesSentence = false
            while i < to, !isWhitespace(ns.character(at: i)) {
                if isSentenceTerminator(ns.character(at: i)) { closesSentence = true }
                i += 1
            }
            let text = comparisonForm(ns.substring(with: NSRange(location: start,
                                                                 length: i - start)))
            if !text.isEmpty, !fillerSet.contains(text) {
                tokens.append((start: start, text: text))
            }
            if stopAtSentenceEnd, closesSentence { break }
        }
        return tokens
    }

    private static func comparisonForm(_ raw: String) -> String {
        raw.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .trimmingCharacters(in: comparisonTrim)
    }

    private static func terminatorCount(_ ns: NSString, from: Int, to: Int) -> Int {
        var count = 0
        for i in from..<to where isSentenceTerminator(ns.character(at: i)) { count += 1 }
        return count
    }

    private static func isSentenceTerminator(_ c: unichar) -> Bool {
        switch c {
        case 0x2E, 0x21, 0x3F, 0x2026: return true  // . ! ? …
        default: return false
        }
    }

    private static func isWhitespace(_ c: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(c) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    /// Start of the last whitespace-delimited token inside `range` — the word
    /// the Python `\b[\w']+` captured, even when the pattern matched a
    /// multi-token closed-class item ("half past three no wait Bob").
    private static func lastTokenStart(_ range: NSRange, _ ns: NSString) -> Int {
        var i = range.location + range.length
        while i > range.location {
            guard let scalar = Unicode.Scalar(ns.character(at: i - 1)),
                  !CharacterSet.whitespacesAndNewlines.contains(scalar) else { break }
            i -= 1
        }
        return i
    }

    /// Which closed class the side rooted at `base` matched, if any. Exactly
    /// one of the five discriminator groups participates per side.
    private static func classIndex(_ m: NSTextCheckingResult, _ base: Int) -> Int? {
        for i in 0..<classCount where m.range(at: base + i).location != NSNotFound { return i }
        return nil
    }

    private static func generalMarker(_ m: NSTextCheckingResult) -> GeneralMarker? {
        if m.range(at: markerNoWait).location != NSNotFound { return .noWait }
        if m.range(at: markerNoActually).location != NSNotFound { return .noActually }
        if m.range(at: markerWaitNo).location != NSNotFound { return .waitNo }
        if m.range(at: markerIMeant).location != NSNotFound { return .iMeant }
        if m.range(at: markerIMean).location != NSNotFound { return .iMean }
        return nil
    }

    /// Whether two closed-class sides are the same *kind of thing* — exact
    /// class match, plus the two pairs Wispr Flow treats as interchangeable:
    /// a bare number correcting a clock time ("5 actually 6 pm") and a
    /// weekday correcting a relative day ("Friday actually tomorrow").
    static func classesCompatible(_ a: Int, _ b: Int) -> Bool {
        if a == b { return true }
        switch (a, b) {
        case (0, 1), (1, 0): return true   // clock ↔ number
        case (2, 4), (4, 2): return true   // weekday ↔ relative day
        default: return false
        }
    }

    enum GeneralMarker { case noWait, noActually, waitNo, iMean, iMeant }
}

// MARK: - Closed classes

// The five closed classes tier (a) recognizes, in the order their discriminator
// groups appear in the pattern. `SelfCorrection.classIndex` returns an offset
// into this order, so the order is the contract — the values themselves are
// never compared to anything but each other.
//
// Every sub-pattern below is group-free (`(?:…)` only): the joint pattern
// counts capture groups by position, so a stray `(` here would shift every
// index in `SelfCorrection`.

private let unitWords = "one|two|three|four|five|six|seven|eight|nine"
private let teenWords =
    "ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen"
private let ordinalUnitWords = "first|second|third|fourth|fifth|sixth|seventh|eighth|ninth"
private let ordinalTeenWords = "tenth|eleventh|twelfth|thirteenth|fourteenth|fifteenth|"
    + "sixteenth|seventeenth|eighteenth|nineteenth"

// Spelled 1–31, cardinal and ordinal, plus the digit forms. Compound forms
// accept either joiner ("twenty one", "twenty-one"). Longest alternative first
// throughout, so "thirteen" never resolves as "three" and "4th" never as "4".
private let cardinalWordPattern = "(?:twenty[\\s-]?(?:" + unitWords + ")|thirty[\\s-]?one|"
    + teenWords + "|twenty|thirty|" + unitWords + ")"
private let ordinalWordPattern = "(?:twenty[\\s-]?(?:" + ordinalUnitWords + ")|"
    + "thirty[\\s-]?first|twentieth|thirtieth|" + ordinalTeenWords + "|" + ordinalUnitWords + ")"
private let numberPattern = "(?:\\d{1,4}(?:st|nd|rd|th)|" + ordinalWordPattern + "|"
    + cardinalWordPattern + "|\\d{1,4})"

// Spoken hour-minute times — "nine thirty", "ten fifteen". Added because the
// class list not having them was a WORD DELETION, measured through the shipping
// pipeline: "Let's do nine thirty. I mean ten fifteen, in the small room." came
// back "Let's do nine ten fifteen, in the small room." — tier (a) read the
// TAILS "thirty" and "ten" as two bare numbers, corrected one into the other,
// and left the hour of the time it deleted standing in the sentence.
//
// The hour is 1–12, and that restriction is the whole safety argument: English
// speaks a compound number tens-first ("twenty five", "thirty one"), so no
// compound number can open with a value the clock accepts as an hour, and
// "twenty five" stays the number it is. The minute list is likewise closed —
// the forms a speaker actually says — so "three items", "nine people" and
// "ten years" are not times.
private let minuteWords = "o[h]?[\\s-](?:" + unitWords + ")|fifteen|thirty|"
    + "forty[\\s-]?five|forty|fifty[\\s-]?five|fifty|twenty[\\s-]?five|twenty|ten"
private let spokenClockPattern = "(?:1[0-2]|[1-9]|one|two|three|four|five|six|seven|eight|"
    + "nine|ten|eleven|twelve)[\\s-](?:" + minuteWords + ")"

// Clock times, tried BEFORE bare numbers so "3 o'clock" is one time rather than
// the number 3 followed by a word.
private let clockPattern = "(?:" + [
    "(?:half|quarter)\\s+(?:past|to)\\s+(?:\\d{1,2}|" + cardinalWordPattern + ")",
    "\\d{1,2}:\\d{2}(?:\\s*[ap]\\.?m\\.?)?",
    "(?:\\d{1,2}|" + cardinalWordPattern + ")\\s+o['\u{2019}]?\\s?clock",
    "\\d{1,2}\\s*[ap]\\.?m\\.?",
    spokenClockPattern,
].joined(separator: "|") + ")"

/// Longest-first, ties broken alphabetically — the `emojiNamePattern` idiom:
/// `sorted` is not stable and the compiled pattern must be.
private func alternation(_ words: [String]) -> String {
    "(?:" + words.sorted { ($0.count, $1) > ($1.count, $0) }.joined(separator: "|") + ")"
}

// Weekdays. Full names only — "wed"/"sat"/"sun" are ordinary English words and
// the abbreviations buy nothing, since SpeechAnalyzer spells the day out. The
// second row is the misspelling family this recognizer actually emits for a
// fast-spoken weekday; none of them are words, so they cost no false positives.
private let weekdayPattern = alternation([
    "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
    "mondy", "teusday", "tuesay", "wendsday", "wensday", "wedsday",
    "thuersday", "thuersay", "thursay", "thersday", "thurdsay",
    "saterday", "satuday", "sundy",
])

// Months, split by ambiguity. The unambiguous names are not English words, so
// they are matched case-insensitively like every other class.
private let unambiguousMonthPattern = alternation([
    "january", "february", "april", "june", "july",
    "august", "september", "october", "november", "december",
    "jan", "feb", "apr", "jun", "jul", "aug", "sept", "sep", "oct", "nov", "dec",
])

// "may", "march" and "mar" are also a modal and two verbs, and the class list
// is what tier (a) uses to decide that BOTH sides of a connective are the same
// kind of thing — so a bare lowercase "may" made every "<verb> actually <verb>"
// sentence look like a month correction. Measured: "He may actually march in
// the parade." -> "He march in the parade.", a sentence with no correction in
// it at all losing its modal.
//
// Month sense therefore has to be evidenced, and dictated text carries exactly
// two cheap signals for it:
//   * capitalization. The recognizer capitalizes a month and lowercases the
//     modal, so `(?-i:…)` (an inline ICU flag, since the compiled pattern is
//     case-insensitive as a whole) is the discriminator. Sentence-initial "May
//     I …" is capitalized too, but tier (a) needs a same-class item on the
//     OTHER side of the connective as well, which no modal reading supplies;
//   * an adjacent day or year number ("march 5", "may 2026") — the date shape,
//     which the verb reading does not have.
// Everything else stays a plain word. The pinned pairs are unaffected:
// "March. Sorry, April." and "May no June" are both capitalized.
// ("MAR" is left out of the shouted forms on purpose: a three-letter all-caps
// token is an acronym far more often than a shouted month abbreviation.)
private let ambiguousMonthPattern = "(?:(?-i:"
    + alternation(["March", "May", "Mar", "MARCH", "MAY"]) + ")|"
    + alternation(["march", "may", "mar"])
    + "(?=\\s+(?:\\d{1,2}(?:st|nd|rd|th)?|\\d{4})(?![\\w-])))"

private let monthPattern = "(?:" + unambiguousMonthPattern + "|" + ambiguousMonthPattern + ")"

private let relativeDayPattern = alternation(["today", "tonight", "tomorrow", "yesterday"])

private let classCount = 5
private let classAlternation = "(?:(" + clockPattern + ")|(" + numberPattern + ")|("
    + weekdayPattern + ")|(" + monthPattern + ")|(" + relativeDayPattern + "))"

// MARK: - The joint pattern

// Shares the pipeline's filler vocabulary (`PostProcess` stage 1) rather than
// keeping a second copy: the live path hands this engine text stage 1 has not
// seen yet, so the two lists have to agree by construction.
private let filler = "(?:" + fillerWords.joined(separator: "|") + ")"

/// The separator on either side of a connective: the Python `[,]?\s+`, extended
/// to swallow the fillers the live path has not stripped. With no filler in the
/// text it matches a superset of what the Python rule matched: real recognizer
/// output punctuates the hesitation ("on Thursday, umm. No, actually Friday"),
/// so a single terminal mark is tolerated before the whitespace — measured on
/// the tts corpus, where the comma-only form never occurred.
private let gap = "[,.!?…]?\\s+(?:" + filler + "[,.!?…]?\\s+)*"

/// Whitespace *inside* a two-word connective ("no umm wait", and the ASR's
/// "No, actually"), likewise filler-tolerant. "uh no" / "umm no" need no entry
/// of their own — a leading filler is already part of `gap`.
private let innerGap = "[,]?\\s+(?:" + filler + "\\s+)*"

// The connectives, longest first so "no wait"/"no actually" always beat the
// bare "no". The three that are also general (tier b) markers are captured; the
// rest fire only inside a same-closed-class sandwich. One phrase list feeds
// both the joint pattern and the mid-correction tail probe below, so the two
// can never disagree about what a connective is.
private let markerPhrases: [(pattern: String, captured: Bool)] = [
    ("no" + innerGap + "wait", true),
    ("no" + innerGap + "actually", true),
    ("wait" + innerGap + "no", true),
    ("i" + innerGap + "meant", true),
    ("i" + innerGap + "mean", true),
    ("or" + innerGap + "rather", false),
    ("make" + innerGap + "that", false),
    ("actually", false),
    ("sorry", false),
    ("no", false),
]
private let markerAlternation = markerPhrases
    .map { $0.captured ? "(" + $0.pattern + ")" : $0.pattern }
    .joined(separator: "|")

/// A partial that ENDS on a connective (plus trailing fillers/punctuation) is
/// a correction whose Y has not been spoken yet. The live path defers display
/// correction for exactly that frame — otherwise the general markers fire with
/// nothing to keep and the word being corrected visibly vanishes until the
/// next partial arrives.
private let midCorrectionTail: NSRegularExpression = {
    let bare = markerPhrases.map(\.pattern).joined(separator: "|")
    let retract = "scratch\\s+that|forget\\s+that|never\\s*mind"
    let sandwich = "wait|instead"
    let pattern = "\\b(?:" + bare + "|" + retract + "|" + sandwich
        + ")(?:[,.]?\\s+" + filler + ")*[,.…]?\\s*$"
    return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
}()

// Group layout. Positional, so every sub-pattern above is group-free and the
// order here is load-bearing.
private let xWhole = 1
private let xClassFirst = 2          // 2…6  — clock, number, weekday, month, relative day
private let xWord = 7
private let markerNoWait = 8
private let markerNoActually = 9
private let markerWaitNo = 10
private let markerIMeant = 11
private let markerIMean = 12
private let yWhole = 13
private let yClassFirst = 14         // 14…18

// A joint is `<X> <gap> <connective> <gap> <Y?>`, where each side is either a
// closed-class item or (X only) a single spoken word. The class branch is tried
// first so "3 o'clock" reads as one time rather than the word "clock"; a filler
// can never be the word a correction replaces. Y is optional because tier (b)
// does not care what follows the marker — but when it IS a closed-class item,
// tier (a) needs it, so the pattern always consumes it when it can.
private let jointPattern = "(?<![\\w'-])"
    + "(?:(" + classAlternation + ")|(?!" + filler + "\\b)([\\w']+))"
    + gap
        + "(?:" + markerAlternation + ")"
        + gap
        + "(?:(?:(?:to|for|from|with|on|at|in)\\s+)?(" + classAlternation + ")(?![\\w'-]))?"
private let jointRx = Rx(jointPattern)

// MARK: - Possessive date pair

// "tonight's meeting? Actually, tomorrow's meeting" -> "tomorrow's meeting".
//
// Tier (a)'s safety argument, one construction wider: both sides are a
// possessive DATE-class item ("tonight's", "Friday's", "March's") and the head
// noun after it repeats verbatim, so the weak connectives — bare "actually",
// "sorry", "no" — are safe here for the same reason they are safe in a
// closed-class sandwich. The repeated head is the load-bearing evidence: it is
// exactly what the contraction reading ("tomorrow's fine" = "tomorrow is
// fine") can never produce, and without it the sentence is ambiguous prose
// ("Monday's numbers, actually Friday's report is better") and passes
// verbatim. The three DATE classes may cross ("Friday's meeting no actually
// tomorrow's meeting") — a day corrects a day; clock times and numbers are not
// in the rule because their possessives do not occur in speech.
//
// Y — its possessor, its copy of the head, casing and all — stays verbatim;
// X, the joint, and X's copy of the head go, which is what `sweep` replaces
// the whole match with via `$2`. The head may span up to three words
// ("tomorrow's team meeting"), compared case-insensitively through the
// backreference. Chains resolve through the fixpoint loop in `apply`.
private let datePossessive = "(?:" + weekdayPattern + "|" + monthPattern + "|"
    + relativeDayPattern + ")['\u{2019}]s"
private let possessivePairRx = Rx(
    "(?<![\\w'-])" + datePossessive
        + "\\s+([\\w']+(?:\\s+[\\w']+){0,2})" + gap
        + "(?:" + markerPhrases.map(\.pattern).joined(separator: "|") + ")" + gap
        + "(" + datePossessive + "\\s+\\1)(?![\\w'-])")

// "scratch that" — one occurrence, guarded by `SelfCorrection.applyScratch`,
// which walks every match and cuts at the last DIRECTIVE one. (Python spelled
// this as a single greedy `^.*scratch that` substitution; the cut point is the
// same, the guard is what is new.)
private let scratchRx = Rx(#"\bscratch\s+that\b[,.]?\s*"#,
                           [.caseInsensitive, .dotMatchesLineSeparators])
private let scratchProbeRx = Rx(#"\bscratch\s+that\b"#)
private let forgetRx = Rx(#"\bforget\s+that\b[,.]?\s*"#,
                          [.caseInsensitive, .dotMatchesLineSeparators])
private let forgetProbeRx = Rx(#"\bforget\s+that\b"#)
private let neverMindRx = Rx(#"\bnever\s*mind\b[,.]?\s*"#,
                             [.caseInsensitive, .dotMatchesLineSeparators])
private let neverMindProbeRx = Rx(#"\bnever\s*mind\b"#)

// "send it to marketing sorry to finance" → "send it to finance".
// The repeated preposition is the evidence that makes "sorry" / "actually"
// safe on arbitrary nouns — the same argument as the possessive date pair.
private let parallelPrepRx = Rx(
    "(?<![\\w'-])((?:to|for|from|with)\\s+)((?:(?:the|a|an|my|your|our)\\s+)?[\\w']+)"
        + gap
        + "(?:" + markerPhrases.map(\.pattern).joined(separator: "|") + ")"
        + gap
        + "(\\1)((?:(?:the|a|an|my|your|our)\\s+)?[\\w']+)(?![\\w'-])")

// "as a gift, as a present" / "as a gift umm as a present" → "as a present".
// A pause (punctuation or filler) is required so two roles listed without
// hesitation ("as a child as a parent") stay verbatim.
private let sameFrameRx = Rx(
    "(?<![\\w'-])((?:as|for)\\s+(?:a|an|the)\\s+)(\\w+)"
        + "(?:[,.!?…]\\s+|\\s+" + filler + "[,.!?…]?\\s+)"
        + "\\1(\\w+)(?![\\w'-])")

/// Closed-class sandwich for connectives that are too common as prose
/// to live in `jointRx`. Group 1 is unused (the X wrapper); classes
/// start at 2; Y's wrapper is 7; Y's classes start at 8.
private let sandwichXClassFirst = 2
private let sandwichYWhole = 7
private let sandwichYClassFirst = 8
private let sandwichOnlyRx = Rx(
    "(?<![\\w'-])(" + classAlternation + ")"
        + gap
        + "(?:wait|instead)"
        + gap
        + "(" + classAlternation + ")(?![\\w'-])")

/// Pause between a past day and a later one. Same filler-tolerant gap as
/// `sameFrameRx` — a comma, a terminator, or a spoken hesitation.
private let pastDayPause = "(?:[,.!?…]\\s+|\\s+" + filler + "[,.!?…]?\\s+)"
private let pastDayForwardRx = Rx(
    "(?<![\\w'-])yesterday" + pastDayPause + "(today|tonight|tomorrow)(?![\\w'-])")
private let pastDayBackRx = Rx(
    "(?<![\\w'-])(?:today|tonight|tomorrow)" + pastDayPause + "(yesterday)(?![\\w'-])")

/// Adverbs that make "not X" a fixed adverbial rather than a rejected noun.
/// English pairs "not" with these so often that the sequence carries no
/// contrast at all — "not yet", "not only", "not once".
private let notIdiomAdverbs: Set<String> = [
    "yet", "only", "even", "just", "quite", "once", "again", "always",
    "necessarily", "merely", "simply", "entirely", "exactly", "really",
    "nearly", "altogether", "wholly", "totally", "particularly", "especially",
    "longer", "anymore", "unless", "until", "till",
]

/// "not a pet pill" / "not pet, pill" / "not pet but pill".
private let notRepeatRx = Rx(
    "\\bnot\\s+(?:(?:a|an|the)\\s+)?([\\w']+)[,.]?\\s+(?:but\\s+)?([\\w']+)\\b")
/// A follow-up that is the cue and nothing else.
private let standaloneNotRx = Rx(
    "(?:(?:um+|uh+|erm+|uhh+|umm+)\\s+)*not\\s+(?:(?:a|an|the)\\s+)?"
        + "([\\w']+)[,.]?\\s+(?:but\\s+)?([\\w']+)\\s*[.!?…]*")

/// After the surviving day, only a phrase tail (a preposition) is still
/// the same correction. Anything else — "and", a subject, a verb — is a
/// list or a new clause and stays verbatim.
private let pastDayPhraseContinuations: Set<String> = [
    "at", "on", "in", "for", "with", "to", "after", "before",
    "around", "about", "until", "by", "from",
]

/// Words that make "scratch" the transitive verb and "that" its determiner:
/// negations, modals, the infinitive "to" and nominative subjects. Each one
/// licenses a verb phrase and none of them can END a retracted clause, which is
/// what makes the lookback safe — "call him tomorrow scratch that today" and
/// "draft the email scratch that write the memo" lead with "tomorrow"/"email".
private let scratchLiteralLeaders: Set<String> = [
    "don't", "dont", "do", "not", "never", "won't", "wont", "can't", "cant", "cannot",
    "didn't", "didnt", "doesn't", "doesnt", "wouldn't", "wouldnt",
    "shouldn't", "shouldnt", "couldn't", "couldnt",
    "to", "must", "should", "would", "could", "might", "may", "can", "will", "shall",
    "i", "you", "we", "they", "he", "she",
    "i'll", "you'll", "he'll", "she'll", "we'll", "they'll",
    "i'm", "you're", "we're", "they're",
]

// Collapse an immediate duplicate of a function word, which self-correction can
// leave behind ("... to InsForge no wait to production" -> "... to to ...").
//
// The list is an allowlist of doubles that are NEVER grammatical in English,
// and it used to be much longer. Three of its members made the stage delete a
// word from ordinary, correction-free speech — measured through the shipping
// pipeline:
//
//   "Please hand it in in March."        -> "Please hand it in March."
//   "The show must go on on Friday."     -> "The show must go on Friday."
//   "What it is is a resourcing problem."-> "What it is a resourcing problem."
//
// Those doubles are grammatical (particle + preposition; the pseudo-cleft
// copula), so no context test can rescue them and they are simply gone, along
// with "at"/"it"/"i", which buy nothing a correction actually needs. What is
// left is the shape the rule was written for: "to to", "the the", and their
// kin, which only ever occur as an artifact of the deletion above — the pinned
// goldens ("go to the the store", "we need to to to fix it", "…to Bob no wait
// to Alice") all live in that shape.
//
// Content words are deliberately NOT collapsible either: "very very", "long
// long" and the corpus's "just just ship it" are all real speech, and the
// stutter-repair they want belongs to WispritRefine, which already owns it.
private let dupRx = Rx(#"\b(to|the|a|an|and|or|but|of|for|with)\s+\1\b"#)

/// Function words a correction may restate along with the phrase they head, and
/// the entire vocabulary of the parallel-preposition rules: the equality escape
/// in `isCorrection` and the span extension in `spanDrop`.
///
/// Prepositions only, and deliberately not the determiners. A repeated
/// preposition is a restatement of the SAME slot ("at three … at four"); a
/// repeated "the" is just English, and widening this to determiners would let
/// the span eat one out of ordinary speech.
///
/// This is not `dupRx`'s list and must not become it. `dupRx` runs at the end
/// of the sweep, where the marker that made a double an artifact is already
/// gone, which is why "in in"/"on on" had to be removed from it ("Please hand
/// it in in March." lost a word). These rules run while the marker is still in
/// front of the engine, so they can tell the artifact from the grammar.
private let parallelFunctionWords: Set<String> = [
    "to", "for", "on", "in", "at", "from", "with", "of",
]

/// The literal "no wait" (a queue with no waiting), signal one: the word the
/// span would delete. A copula, a possession verb or a preposition is never
/// what a correction replaces — "There IS no wait", "The clinic HAS no wait".
private let noWaitLiteralLeaders: Set<String> = [
    "is", "was", "are", "were", "be", "been", "being", "has", "have", "had",
    "with", "of", "there's", "theres", "that's", "thats", "here's", "heres",
]

/// The literal "no wait", signal two: a noun continuation after "wait". The
/// interjection is a complete utterance, so what follows it is the replacement
/// word, never a tail of the phrase itself — "no wait TIME", "no wait AT the
/// DMV", "no wait LIST". "to" is absent on purpose: "…to Bob no wait to Alice"
/// is the pinned parity golden.
private let noWaitObjectWords: Set<String> = [
    "time", "times", "list", "lists", "at", "for", "on", "in", "anywhere", "whatsoever",
]

/// Words that can open a two-token replacement fragment after a
/// cross-terminator marker ("No, actually, the footer." / "…next quarter.").
/// Determiners, possessives and the ordinal-ish modifiers — everything that
/// announces a noun phrase rather than a new subject.
private let fragmentOpeners: Set<String> = [
    "the", "a", "an", "this", "that", "these", "those", "another", "other", "same",
    "my", "your", "our", "their", "his", "her", "its",
    "next", "last", "first", "second", "third", "final", "every", "each", "any", "some",
    "half", "quarter", "no",
]

/// Words that make "no actually" / "I mean" a discourse hedge rather than a
/// correction. Deliberately small and function-word-only: anything a user would
/// actually be replacing ("Bob", "Thursday", "three") is a content word. The
/// one exception to function-word-only is the say-family: a marker DIRECTLY
/// after a verb of saying means the "no" was the thing said — "I said no,
/// actually, and I stand by it" is the speaker's answer, not a correction —
/// while a real correction after reported speech keeps its content leader
/// ("I said Bob no actually Alice" corrects on "Bob", never on "said").
private let hedgeLeaders: Set<String> = [
    "so", "well", "yeah", "yea", "yes", "no", "nope", "but", "and", "or",
    "ok", "okay", "like", "what", "that", "which", "who", "whom",
    "know", "see", "if", "then", "hey", "look", "right", "sure",
    "i", "you", "he", "she", "it", "we", "they",
    "say", "says", "said", "saying",
]

// MARK: - Clause-restart vocabulary

/// The pipeline's filler list as a set, for the restart tokenizer — a filler is
/// never restart evidence and never a compared token.
private let fillerSet = Set(fillerWords)

/// Edge punctuation stripped from a token before comparison. Inverted
/// alphanumerics so quotes, commas and terminators go while an interior
/// apostrophe ("let's") stays.
private let comparisonTrim = CharacterSet.alphanumerics.inverted

/// The function-word lexicon for the ONE-token restart rule: a single shared
/// token only counts as restart evidence when it is a content word — a name,
/// not a pronoun or determiner, because "I …" re-begins half the clauses in
/// English by accident. Two shared tokens are evidence regardless, so this
/// list only has to catch the words that open clauses on their own.
private let restartFunctionWords: Set<String> = hedgeLeaders.union([
    "the", "a", "an", "this", "these", "those", "there", "here",
    "to", "of", "in", "on", "at", "for", "with", "from", "by", "as",
    "is", "are", "was", "were", "be", "been", "am",
    "do", "does", "did", "have", "has", "had",
    "will", "would", "can", "could", "should", "shall", "may", "might", "must",
    "not", "my", "your", "our", "their", "his", "her", "its",
    "me", "him", "us", "them", "when", "where", "why", "how",
])

/// Words that can never be the X or Y of a "not" restatement.
private let correctionFunctionWords: Set<String> = restartFunctionWords.union([
    "no", "never", "don't", "dont", "isn't", "isnt", "wasn't", "wasnt",
    "aren't", "arent", "won't", "wont", "can't", "cant", "didn't", "didnt",
    "wait", "instead", "actually", "sorry", "well", "like", "just", "really",
    "very", "meant", "mean", "say", "said",
    "any", "some", "all", "every", "each", "both", "few", "many", "more", "most",
    "another", "other",
])

/// The closed-class vocabulary as an anchored probe — the rest of the engine's
/// "lexicon". A weekday or number shared by accident is not the restart
/// evidence a name is; those corrections belong to tier (a) and its classes.
private let closedClassWordRx = Rx("^(?:" + clockPattern + "|" + numberPattern + "|"
    + weekdayPattern + "|" + monthPattern + "|" + relativeDayPattern + ")$")

// MARK: - The parallel-anchor tier

// The user-reported failure, and the shape both tiers above are structurally
// unable to reach:
//
//     "I want to go tomorrow. I mean, day after to the hackathon."
//
// Tier (a) wants a closed-class item on BOTH sides and "day after" is not one.
// Tier (b)'s cross-terminator span wants a bare replacement fragment, and this
// is a fragment plus a continuation — the span would have to reach back into
// the previous sentence and then leave the continuation dangling, which is
// exactly the measured "I finished the Jane finished it." damage the fragment
// rule was added to stop. So the utterance shipped with the mistake in it, and
// the AI layer does not rescue it either: the refine battery's
// `self-correction-weak-cue` case scores 0.00. The deterministic layer is the
// only guarantee this failure class has.
//
// The parallel-anchor tier replaces the evidence tier (b) cannot get ("is what follows the cue
// a replacement, or a new sentence?") with PARALLEL STRUCTURE. A correction
// restates something, so the replacement and the thing it replaces are the same
// KIND of phrase — that is what a restatement IS. The rule is therefore a
// type-check, the same one tier (a) performs, lifted off the closed-class
// lexicon and onto phrases:
//
//   R = the leading phrase after the cue, classified longest-first.
//   X = the TRAILING phrase of the clause the cue interrupts, classified the
//       same way.
//   Resolve iff both classify, and to the same class.
//
// Output is `<text before X> + <the WHOLE post-cue text>`: X, the punctuation
// and the cue go, R keeps its continuation and its own punctuation. Which is
// why X has to be the clause's TRAILING phrase and nothing weaker — the span
// this deletes runs from X to the cue, so an anchor found further back would
// take real words with it, and "deleting a correct word" is the one failure a
// dictation app can never take back. An anchor that is not clause-final does
// not resolve; the text ships verbatim, unchanged and honest.
//
// Two more classes carry the same weight as the semantic ones and are listed
// with them below: a shared PREPOSITION head ("to marketing" ↔ "to finance"),
// where the repeated preposition is the parallelism, and PHONETIC proximity
// for the mishear-restatement channel ("…to Viveque. I mean Vivek."), which is
// the riskiest branch here and is fenced accordingly.

extension SelfCorrection {
    /// Resolve the first cue in `text` that has a parallel anchor behind it.
    ///
    /// One rewrite per call: `apply`'s fixpoint loop re-enters the sweep, so a
    /// second cue in the same utterance gets its own pass with the first one
    /// already resolved. That is the same mechanism `possessivePairRx` chains
    /// through, and it keeps this function a single left-to-right scan.
    static func resolveParallelAnchors(_ text: String) -> String {
        // No cue word, no work — the common case costs one scan and no
        // allocation, which is what the <1 ms live budget is made of.
        guard anchorCueProbeRx.matches(text) else { return text }
        let ns = text as NSString
        for cue in anchorCueRx.allMatches(text, ns) {
            guard let anchorStart = anchorStart(forCue: cue.range, ns) else { continue }
            return splice(ns, anchorStart: anchorStart,
                          postCueStart: cue.range.location + cue.range.length)
        }
        return text
    }

    /// Where the replaced phrase starts, or nil when this cue has no parallel
    /// anchor behind it and the text must ship verbatim.
    private static func anchorStart(forCue cue: NSRange, _ ns: NSString) -> Int? {
        let postCueStart = cue.location + cue.length
        // A partial that ends ON the cue has no replacement yet. The cue
        // pattern's trailing `\s+` already refuses that frame; this is the
        // same refusal for the trailing-whitespace case, and it is why this tier
        // needs no `endsMidCorrection` entry of its own.
        guard postCueStart < ns.length else { return nil }
        let r = anchorTokens(ns, from: postCueStart, to: ns.length,
                             stopAtSentenceEnd: true, limit: anchorWindow + 1)
        // The tier (b) hedge veto, re-used verbatim: a marker followed by a
        // function word or an interjection is the user talking, not correcting.
        guard let head = r.first, !hedgeLeaders.contains(head.lower) else { return nil }
        guard !opensWithDiscourseMarker(r) else { return nil }
        let x = precedingClauseTokens(ns, before: cue.location)
        guard !x.isEmpty else { return nil }
        if let kind = leadingClass(r), let index = trailingIndex(x, of: kind) {
            return x[index].range.location
        }
        return phoneticAnchor(r, x)
    }

    /// Where X's trailing phrase of class `kind` starts, or nil when it has
    /// none.
    ///
    /// X is classified INDEPENDENTLY and only then compared, which is what
    /// makes this a type-check rather than a search for something that will
    /// agree: "Let's do nine thirty." classifies as a clock time, so a bare
    /// number after the cue finds no anchor and the text ships verbatim instead
    /// of swapping the minutes out of a time.
    ///
    /// The one relaxation — retried, never widened — is a prepositional R. A
    /// prepositional phrase WRAPS a phrase rather than competing with it ("for
    /// Monday" is a preposition whose object happens to be a weekday), so a
    /// semantic hit on the object does not rule the wrapper out and the
    /// independent pass can legitimately have seen the wrong layer. Only ever
    /// re-classified as the class R already is, so two SEMANTIC classes still
    /// have to agree on the first look, and "nine thirty" ↔ "four" still bails.
    private static func trailingIndex(_ x: [AnchorToken], of kind: AnchorClass) -> Int? {
        if let trailing = trailingClass(x), trailing.kind == kind { return trailing.index }
        guard case .preposition = kind else { return nil }
        let n = min(x.count, anchorWindow)
        for length in stride(from: n, through: 2, by: -1) {
            let start = x.count - length
            if prepositionalClass(Array(x[start...])) == kind { return start }
        }
        return nil
    }

    /// `<text before X>` + `<the whole post-cue text>`.
    private static func splice(_ ns: NSString, anchorStart: Int, postCueStart: Int) -> String {
        let head = ns.substring(to: anchorStart)
        let tail = ns.substring(from: postCueStart)
        // The replacement keeps its own casing — the contract tier (a) already
        // gives Y — with one exception the splice creates rather than
        // inherits: when X opened the sentence, the capital the recognizer put
        // on X is the one the sentence still needs.
        guard opensSentence(head), let first = tail.first, first.isLowercase else {
            return head + tail
        }
        return head + first.uppercased() + tail.dropFirst()
    }

    private static func opensSentence(_ head: String) -> Bool {
        guard let last = head.trimmingCharacters(in: .whitespacesAndNewlines).last else {
            return true
        }
        return ".!?\u{2026}".contains(last)
    }

    // MARK: classification

    /// The class of the phrase R OPENS, longest-first so "ten fifteen" is one
    /// clock time rather than the number ten.
    ///
    /// Both passes are longest-first, but the SEMANTIC pass runs to completion
    /// before the prepositional one gets a look. Order, not length, is what
    /// stops "to go tomorrow" from reading as a prepositional phrase headed by
    /// "to" and shadowing the relative day that is the actual anchor.
    private static func leadingClass(_ tokens: [AnchorToken]) -> AnchorClass? {
        let n = min(tokens.count, anchorWindow)
        guard n > 0 else { return nil }
        for length in stride(from: n, through: 1, by: -1) {
            if let kind = semanticClass(Array(tokens[0..<length])) { return kind }
        }
        for length in stride(from: n, through: 2, by: -1) {
            if let kind = prepositionalClass(Array(tokens[0..<length])) { return kind }
        }
        return nil
    }

    /// The class of the phrase X CLOSES, and where that phrase starts.
    private static func trailingClass(_ tokens: [AnchorToken]) -> (kind: AnchorClass, index: Int)? {
        let n = min(tokens.count, anchorWindow)
        guard n > 0 else { return nil }
        for length in stride(from: n, through: 1, by: -1) {
            let start = tokens.count - length
            if let kind = semanticClass(Array(tokens[start...])) { return (kind, start) }
        }
        for length in stride(from: n, through: 2, by: -1) {
            let start = tokens.count - length
            if let kind = prepositionalClass(Array(tokens[start...])) { return (kind, start) }
        }
        return nil
    }

    /// The closed semantic classes, probed on the phrase's RAW text: the month
    /// class reads capitalization as its month-sense evidence ("He may actually
    /// march in the parade."), so a lowercased phrase would silently disarm it.
    private static func semanticClass(_ phrase: [AnchorToken]) -> AnchorClass? {
        let text = phrase.map(\.raw).joined(separator: " ")
        if anchorClockRx.matches(text) { return .clock }
        if anchorWeekdayRx.matches(text) { return .weekday }
        if anchorMonthRx.matches(text) { return .month }
        if anchorRelativeRx.matches(text) { return .relative }
        if anchorNumberRx.matches(text) { return .number }
        return nil
    }

    /// A phrase whose parallelism is its PREPOSITION: "to marketing" ↔ "to
    /// finance". The head has to repeat exactly (a "to" does not correct a
    /// "by"), and the tail may not contain a second preposition — "to marketing
    /// by Friday" is two phrases, and treating it as one would delete the
    /// Friday along with the marketing.
    private static func prepositionalClass(_ phrase: [AnchorToken]) -> AnchorClass? {
        guard phrase.count >= 2, let head = phrase.first?.lower,
              anchorPrepositions.contains(head),
              !phrase.dropFirst().contains(where: { anchorPrepositions.contains($0.lower) })
        else { return nil }
        return .preposition(head)
    }

    /// The mishear-restatement channel: one token after the cue, one token
    /// before it, and the two are the same word misheard twice.
    ///
    /// The riskiest branch in the file, so it is the most fenced: R has to be
    /// the WHOLE post-cue clause (the bare-fragment shape tier (b) already
    /// trusts), both words have to be content words outside the engine's own
    /// lexicon, they have to start with the same letter, and they have to be
    /// within `phoneticFloor` of each other. "…is fine. I mean it." — the
    /// regression that made "I mean" refuse terminators in the first place —
    /// fails four of the five: "it" is short, a function word, and shares
    /// neither a letter nor a shape with "fine".
    private static func phoneticAnchor(_ r: [AnchorToken], _ x: [AnchorToken]) -> Int? {
        guard r.count == 1, let replacement = r.first, let replaced = x.last,
              isPhoneticallyClose(replaced.lower, replacement.lower) else { return nil }
        return replaced.range.location
    }

    /// Normalized edit distance over the lowercased forms, with a shared first
    /// letter required.
    ///
    /// Orthographic distance and NOT `PhoneticScorer`, deliberately, now that
    /// `WispritKit` carries the metaphone and this module may import it. The
    /// two are not interchangeable here: the scorer is tuned for the antecedent
    /// matcher, where a candidate has already been proposed and the question is
    /// which of several it is. This branch has no candidate list — it is
    /// deciding whether to DELETE a word on the strength of one resemblance —
    /// so it wants the metric that is hardest to satisfy by accident, and edit
    /// distance behind a shared first letter is that metric.
    ///
    /// The cost is visible and accepted: "Shreek"/"Sharique" scores 0.375 here
    /// and does NOT resolve, where the scorer would. Leaving that one verbatim
    /// is the correct answer under this engine's dogma — a missed correction is
    /// a typo the user can see and fix, a wrong one is a word they never knew
    /// they lost. Moving this branch onto the scorer is a real option, but it
    /// needs its own measurement against the mishear corpus, not a swap.
    static func isPhoneticallyClose(_ a: String, _ b: String) -> Bool {
        guard a.count >= phoneticFloorLength, b.count >= phoneticFloorLength,
              a.first == b.first,
              a.allSatisfy({ $0.isLetter || $0 == "'" }),
              b.allSatisfy({ $0.isLetter || $0 == "'" }),
              !restartFunctionWords.contains(a), !restartFunctionWords.contains(b),
              !closedClassWordRx.matches(a), !closedClassWordRx.matches(b) else { return false }
        return 1 - StringMetrics.normalizedLevenshtein(a, b) >= phoneticFloor
    }

    private static func opensWithDiscourseMarker(_ r: [AnchorToken]) -> Bool {
        guard r.count >= 2 else { return false }
        for length in 2...min(anchorWindow, r.count)
        where anchorDiscourseOpeners.contains(r.prefix(length).map(\.lower)
            .joined(separator: " ")) {
            return true
        }
        return false
    }

    // MARK: tokens

    /// Words of `ns` in `from..<to`, fillers skipped, each carrying its range,
    /// its comparison form and its RAW form (punctuation trimmed, case kept —
    /// the month class needs the capital). `stopAtSentenceEnd` cuts the list at
    /// the first word that closes a sentence, so R never reads past its own.
    private static func anchorTokens(_ ns: NSString, from: Int, to: Int,
                                     stopAtSentenceEnd: Bool, limit: Int) -> [AnchorToken] {
        var tokens: [AnchorToken] = []
        var i = from
        while i < to, tokens.count < limit {
            while i < to, isWhitespace(ns.character(at: i)) { i += 1 }
            guard i < to else { break }
            let start = i
            var closesSentence = false
            while i < to, !isWhitespace(ns.character(at: i)) {
                if isSentenceTerminator(ns.character(at: i)) { closesSentence = true }
                i += 1
            }
            let range = NSRange(location: start, length: i - start)
            let word = ns.substring(with: range).replacingOccurrences(of: "\u{2019}", with: "'")
            let raw = word.trimmingCharacters(in: comparisonTrim)
            let lower = raw.lowercased()
            if !lower.isEmpty, !fillerSet.contains(lower) {
                tokens.append(AnchorToken(range: range, raw: raw, lower: lower,
                                          closesSentence: closesSentence))
            }
            if stopAtSentenceEnd, closesSentence { break }
        }
        return tokens
    }

    /// The trailing words of the clause the cue interrupts — never across a
    /// sentence boundary, because a phrase in the sentence BEFORE the one being
    /// corrected is not the thing being restated. Bounded both ways (a fixed
    /// character lookback, then the last `anchorWindow` words) so the scan
    /// costs the same on a one-line partial and on a paragraph.
    private static func precedingClauseTokens(_ ns: NSString, before cueStart: Int)
        -> [AnchorToken] {
        let floor = max(0, cueStart - anchorLookback)
        let all = anchorTokens(ns, from: floor, to: cueStart,
                               stopAtSentenceEnd: false, limit: Int.max)
        var clause = 0
        for (i, token) in all.enumerated() where token.closesSentence { clause = i + 1 }
        return Array(all[clause...].suffix(anchorWindow))
    }
}

/// A word as the term-echo tier compares them — fillers stay, because
/// "had the rank" is the shape the recognizer emits.
private struct EchoToken {
    let range: NSRange
    let raw: String
    let lower: String
}

/// Glue the recognizer inserts when it splits a compound ("had a rank").
private let echoGlue: Set<String> = ["a", "an", "the"]
/// "had the rank of captain" is a real phrase, not a split of HackerRank.
private let echoFollowerVeto: Set<String> = ["of", "as"]
/// A new clause ("I had the rank") is not a split of an earlier term.
private let echoOpenerVeto: Set<String> = ["i", "we", "they", "he", "she", "you"]
/// Same cut the antecedent matcher uses; the affix + follower gates do
/// the rest of the safety work.
private let echoFloor = 0.62

/// Be-verbs that license a participle, so "it was given, giving" is a
/// restatement and "we shipped, shipping tomorrow" is not.
private let inflectionAuxiliaryRx = Rx(#"\b(?:is|are|was|were|am|be|been|being)\b"#)
private let inflectionAuxiliaries: Set<String> = [
    "is", "are", "was", "were", "am", "be", "been", "being",
]
/// A determiner before X is a noun phrase ("the driver, driving"), not
/// a verb-form correction.
private let inflectionDeterminers: Set<String> = [
    "a", "an", "the", "my", "your", "our", "their", "his", "her", "its",
    "this", "that", "these", "those",
]
private let inflectionListFollowers: Set<String> = ["and", "or"]
/// The noun that makes "for holdback" a function name, not a reason.
private let softwareTwinLeaders: Set<String> = [
    "function", "functions", "method", "methods",
]

/// A word as the parallel-anchor tier compares them.
private struct AnchorToken {
    let range: NSRange
    /// Punctuation trimmed, curly apostrophe normalized, CASE PRESERVED.
    let raw: String
    let lower: String
    let closesSentence: Bool
}

/// The parallel classes, in probe order. A phrase belongs to exactly one, and
/// two phrases anchor each other only when it is the SAME one — the type-check
/// tier (a) performs on its closed classes, performed here on phrases.
private enum AnchorClass: Equatable {
    case clock, weekday, month, relative, number
    case preposition(String)
}

/// Words an anchor phrase may span on either side of the cue. Four covers
/// every shape measured ("the day after tomorrow", "quarter past ten", "next
/// Monday morning") and bounds the deletion at the same time: the span this
/// tier removes is the anchor itself, so the window IS the blast radius.
private let anchorWindow = 4

/// How far back the pre-cue clause scan may look, in characters. Four words
/// cannot span more than this in dictated English, so a longer look could not
/// change the answer — it could only make a long paragraph quadratic.
private let anchorLookback = 200

/// Floor on the normalized edit distance for the phonetic branch, and the
/// shortest word it will look at. Both are deliberately high: see
/// `isPhoneticallyClose`.
private let phoneticFloor = 0.5
private let phoneticFloorLength = 3

// The cue vocabulary, which is the joint pattern's marker list plus the three
// cues that were missing from it — "I meant", a bare "rather" (the joint
// pattern only knows "or rather"), and the "No, rather" the recognizer actually
// writes. They are added HERE and not to `markerPhrases` on purpose: the joint
// pattern's list is what tiers (a) and (b) fire on, and widening it would move
// answers those tiers already give.
//
// Two conditions, always, and neither is sufficient alone:
//
//   * a clause terminator or a comma immediately in front of the cue. This is
//     the whole false-positive defence for the weak cues, and it is what makes
//     "I know what you mean about the deadline.", "That is exactly what I mean
//     when I say fragile.", "I would rather go on Friday." and "I am sorry
//     about Thursday." untouchable — in every one of them the cue word is
//     preceded by a word, so it is being USED, not spoken as a cue;
//   * a parallel anchor. Enforced by `anchorStart`, and the reason a bare "no"
//     is absent from this list entirely: "Did we win? No. We lost by two
//     votes." satisfies the punctuation condition perfectly and is not a
//     correction at all.
private let anchorCuePhrases = [
    "i" + innerGap + "meant",
    "i" + innerGap + "mean",
    "no" + innerGap + "actually",
    "no" + innerGap + "wait",
    "no" + innerGap + "rather",
    "or" + innerGap + "rather",
    "make" + innerGap + "that",
    "rather",
    "sorry",
]

/// Cheap gate: no cue word anywhere in the text, no parallel-anchor work at all.
private let anchorCueProbeRx = Rx("\\b(?:mean|meant|sorry|rather|actually|wait|make)\\b")

/// `<terminator-or-comma> <fillers?> <cue> <punctuation?> <whitespace>`. The
/// trailing `\s+` is load-bearing twice over: it proves the replacement has
/// actually been spoken, and it puts the match's end exactly on the first
/// character this tier keeps.
private let anchorCueRx = Rx(
    "[,.!?\u{2026}]+\\s*(?:" + filler + "[,.!?\u{2026}]*\\s+)*"
        + "(?:" + anchorCuePhrases.joined(separator: "|") + ")"
        + "(?![\\w'-])[,.!?\u{2026}]*\\s+")

// The semantic class probes. Anchored, and built from the SAME sub-patterns
// tier (a) uses, so the two tiers can never disagree about what a weekday is.

private let anchorClockRx = Rx("^(?:" + clockPattern + ")$")

/// A weekday, with the modifiers that still leave it a weekday: "next Monday"
/// is a Monday, and so is "Friday morning". The daypart matters because it is
/// what a chained correction leaves BEHIND — "Ship it Thursday. No, rather
/// Friday morning. Sorry, Saturday morning." can only resolve its second cue if
/// the first one's own output still classifies.
private let anchorWeekdayRx = Rx("^(?:(?:next|last|this|coming)\\s+)?(?:" + weekdayPattern
    + ")(?:\\s+(?:morning|afternoon|evening|night))?$")

private let anchorMonthRx = Rx("^(?:" + monthPattern + ")(?:\\s+\\d{1,2}(?:st|nd|rd|th)?)?$")

/// Cardinals and ordinals, with the determiner a spoken day-of-month carries:
/// "Move it to the 5th. I mean the 6th, before the freeze." is a number
/// correcting a number, and the "the" is part of how English says it.
private let anchorNumberRx = Rx("^(?:the\\s+)?(?:" + numberPattern + ")$")

/// Relative time: tier (a)'s four bare words, plus the phrase forms speech
/// actually uses for the same thing. "day after" is the one the user's
/// sentence turns on — it is a relative day exactly as "tomorrow" is, and the
/// only reason tier (a) cannot see it is that it is two words.
private let anchorRelativeRx = Rx("^(?:" + relativeDayPattern
    + "|(?:the\\s+)?day\\s+(?:after|before)(?:\\s+(?:tomorrow|yesterday))?"
    + "|(?:next|last|this|the\\s+following)\\s+(?:week|month|year|weekend)"
    + "|this\\s+(?:morning|afternoon|evening))$")

/// Prepositions that can head a parallel phrase. Closed and small: each one is
/// a preposition that takes a plain noun-phrase object in dictation, which is
/// what makes "P Y" ↔ "P Z" a restatement rather than a coincidence.
private let anchorPrepositions: Set<String> = [
    "to", "for", "from", "with", "at", "on", "in", "by", "about",
    "into", "onto", "toward", "towards", "under", "over", "against",
]

/// Prepositional phrases that are DISCOURSE markers rather than replacements.
/// Without this, "Put it on the shelf. I mean, on second thought, leave it."
/// reads "on the shelf" ↔ "on second thought" as a parallel pair and deletes
/// the shelf. Every entry opens with a preposition and none of them is ever the
/// object of a correction.
private let anchorDiscourseOpeners: Set<String> = [
    "on second thought", "on the other hand", "on balance",
    "in other words", "in any case", "in fact", "in short", "in general",
    "by the way", "at least", "at any rate", "at the same time",
    "to be clear", "to be honest", "to be fair", "to that end",
    "for what it's worth", "for now", "for once", "for that matter",
]
