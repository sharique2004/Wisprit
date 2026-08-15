import Foundation
import WispritIMProtocol

/// A slice of the client's document plus where it starts, because
/// `stringFromRange:actualRange:` is allowed to hand back less than you asked
/// for (Chromium serves a cached window around the selection). Every offset
/// computed from this window is relative to `base`.
public struct IMDocumentWindow: Sendable, Equatable {
    public var text: String
    public var base: Int

    public init(text: String, base: Int) {
        self.text = text
        self.base = base
    }
}

/// What to do about a retroactive correction, decided from a FRESH read of the
/// document — never from cached offsets.
public enum RetroEditPlan: Sendable, Equatable {
    /// Apply exactly one `insertText:replacementRange:` over an absolute range,
    /// and then remember this as the session's committed text.
    ///
    /// `appliedUtf16LocationInCommitted` is where the replacement lands
    /// *relative to the committed run* — the value that travels back to the app
    /// so its mirror rewrites the same characters this plan does, whether the
    /// anchor was honoured or the backwards fallback resolved it.
    case replace(range: NSRange, text: String, newCommitted: String, newCommittedRange: NSRange,
                 appliedUtf16LocationInCommitted: Int)
    /// Do nothing. The caller reports the reason and the app falls back to a
    /// non-destructive path (learn the term, tell the user) rather than guessing
    /// at a range and mangling the user's writing.
    case abort(IMEditDetail)
}

/// The range arithmetic behind "actually, it's spelled S-H-A-R-I-Q-U-E".
///
/// The dangerous case this exists to prevent: the user keeps typing while the
/// correction is in flight (Apple explicitly supports typing during Dictation),
/// so the offsets the app saw when it committed "Hi Sharik" are already wrong.
/// Every plan therefore starts from a fresh read and only proceeds when the text
/// this session committed is still findable, unambiguously, in the live document.
/// Anything less certain aborts.
///
/// WHICH occurrence is a separate question from WHERE the run is, and it has
/// its own rule. `edit.utf16LocationInCommitted` names the instance the caller
/// meant, measured inside our own committed run; it is honoured only when the
/// record still bears it out, and otherwise the pre-anchor last-occurrence
/// search resolves the target. One session spans consecutive utterances, so a
/// word occurring twice in that run is ordinary — before the anchor existed,
/// an edit meant for the FIRST "fox" in "a fox saw a fox" could only ever
/// rewrite the second.
public enum RetroEditPlanner {

    public static func plan(edit: IMEdit,
                            committed: String,
                            committedRange: NSRange?,
                            window: IMDocumentWindow?) -> RetroEditPlan {
        guard !edit.replace.isEmpty else { return .abort(.emptyEdit) }
        guard !committed.isEmpty, committedRange != nil else { return .abort(.targetNotFound) }
        guard let window else { return .abort(.readFailed) }

        let haystack = window.text as NSString

        // 1. Where is the text WE committed, right now? (`committedRange` is a
        //    liveness precondition only — the location is re-derived from the
        //    document, never trusted.)
        let ownedRel: NSRange
        switch locate(committed: committed, in: window) {
        case .found(let range): ownedRel = range
        case .gone: return .abort(.fieldChanged)
        case .ambiguous: return .abort(.ambiguousRelocation)
        }

        // 2. Where is the word to fix, inside our own run only? Correcting text
        //    the user typed themselves is never our business.
        let target = edit.replace as NSString
        var found = anchored(edit, target: target, committed: committed, ownedRel: ownedRel)
        if found.location == NSNotFound {
            // No anchor, or an anchor the record does not bear out. Either way
            // the pre-anchor rule stands: the last occurrence inside our run.
            // Degrading here is deliberate — a wrong-but-plausible offset must
            // cost the user the old behaviour, not a mangled sentence.
            switch edit.occurrence {
            case .last:
                found = haystack.range(of: target as String, options: [.backwards, .literal],
                                       range: ownedRel)
            }
        }
        guard found.location != NSNotFound else { return .abort(.targetNotFound) }

        // 3. One absolute-range replacement.
        let absolute = NSRange(location: window.base + found.location, length: found.length)
        let relativeToCommitted = NSRange(location: found.location - ownedRel.location, length: found.length)
        let newCommitted = (committed as NSString)
            .replacingCharacters(in: relativeToCommitted, with: edit.with)
        let newRange = NSRange(location: window.base + ownedRel.location,
                               length: (newCommitted as NSString).length)
        return .replace(range: absolute, text: edit.with,
                        newCommitted: newCommitted, newCommittedRange: newRange,
                        appliedUtf16LocationInCommitted: relativeToCommitted.location)
    }

    /// Resolve `edit.utf16LocationInCommitted` against the run we located, or
    /// `NSNotFound` when there is no anchor or the anchor is not borne out.
    ///
    /// Validation is against `committed` — our own record — rather than against
    /// the document, and that is sufficient because `ownedRel` is an EXACT
    /// content match of `committed` in the fresh window: those bytes are
    /// identical by construction, so a run-relative offset that holds in the
    /// record holds in the window. The divergences that could break it are all
    /// already handled upstream. The user typing outside our run only moves
    /// `ownedRel.location`, and the offset is relative to it. The user typing
    /// INSIDE our run makes `locate` return `.gone` and the plan aborts
    /// `.fieldChanged` before this is ever consulted; duplicating the run
    /// returns `.ambiguous` and aborts likewise.
    ///
    /// What this catches instead is app-side skew: a mirror that drifted from
    /// the input method's record hands us a number that names the wrong
    /// characters, and comparing the substring is what turns that into a
    /// fallback rather than into a rewrite of a word the user meant to keep.
    private static func anchored(_ edit: IMEdit,
                                 target: NSString,
                                 committed: String,
                                 ownedRel: NSRange) -> NSRange {
        guard let location = edit.utf16LocationInCommitted else {
            return NSRange(location: NSNotFound, length: 0)
        }
        let record = committed as NSString
        // Written as a subtraction rather than `location + target.length <=
        // record.length` because `location` arrives off the wire and could be
        // anything; this cannot overflow.
        guard location >= 0, location <= record.length - target.length,
              record.substring(with: NSRange(location: location, length: target.length))
                  == edit.replace
        else { return NSRange(location: NSNotFound, length: 0) }
        return NSRange(location: ownedRel.location + location, length: target.length)
    }

    /// Where the run this session committed sits in a freshly read window — or
    /// why we cannot say.
    ///
    /// Shared by the correction path and the read-back path (`readCommitted`) so
    /// there is exactly one answer in this process to "is that still our text?".
    /// The ranges are relative to `window.text`; add `window.base` for document
    /// coordinates.
    public enum OwnedRun: Sendable, Equatable {
        /// Exactly one match. This, and only this, is knowledge.
        case found(NSRange)
        /// No match: our text is not in the field any more. Something changed it.
        case gone
        /// More than one match. We genuinely cannot tell which run is ours, and
        /// picking one is how the wrong words get rewritten.
        case ambiguous
    }

    public static func locate(committed: String, in window: IMDocumentWindow) -> OwnedRun {
        guard !committed.isEmpty else { return .gone }
        let occurrences = locateOwnedRun(haystack: window.text as NSString,
                                         needle: committed as NSString)
        switch occurrences.count {
        case 0: return .gone
        case 1: return .found(occurrences[0])
        default: return .ambiguous
        }
    }

    // CONTRACT-DEVIATION (stricter, not looser): the brief said re-read the client
    // fresh and abort rather than guess. This goes further and ignores the
    // remembered offset entirely — see below for the case where trusting it
    // rewrites the user's own words.
    /// Find our committed run by CONTENT, not by remembered offset.
    ///
    /// The remembered offset is deliberately ignored here. If the user types
    /// above our text, everything shifts — and the remembered range can then land
    /// on text that merely *looks* like ours (type "Hi Sharik." above our own
    /// "Hi Sharik." and the old range now points at the user's copy). Matching by
    /// content and insisting on a single occurrence is the only rule that cannot
    /// silently rewrite the wrong words. Two matches means we genuinely cannot
    /// tell, so the caller aborts and the app degrades to learning the term and
    /// saying so.
    ///
    /// Stops after the second hit: we only ever need "none / one / more".
    private static func locateOwnedRun(haystack: NSString, needle: NSString) -> [NSRange] {
        var occurrences: [NSRange] = []
        var searchFrom = 0
        while searchFrom < haystack.length {
            let remaining = NSRange(location: searchFrom, length: haystack.length - searchFrom)
            let hit = haystack.range(of: needle as String, options: [.literal], range: remaining)
            if hit.location == NSNotFound { break }
            occurrences.append(hit)
            if occurrences.count > 1 { return occurrences }
            searchFrom = hit.location + max(1, hit.length)
        }
        return occurrences
    }
}
