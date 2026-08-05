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
    case replace(range: NSRange, text: String, newCommitted: String, newCommittedRange: NSRange)
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
public enum RetroEditPlanner {

    public static func plan(edit: IMEdit,
                            committed: String,
                            committedRange: NSRange?,
                            window: IMDocumentWindow?) -> RetroEditPlan {
        guard !edit.replace.isEmpty else { return .abort(.emptyEdit) }
        guard !committed.isEmpty, committedRange != nil else { return .abort(.targetNotFound) }
        guard let window else { return .abort(.readFailed) }

        let haystack = window.text as NSString
        let needle = committed as NSString

        // 1. Where is the text WE committed, right now? (`committedRange` is a
        //    liveness precondition only — the location is re-derived from the
        //    document, never trusted.)
        let occurrences = locateOwnedRun(haystack: haystack, needle: needle)
        guard occurrences.count == 1 else {
            return .abort(occurrences.isEmpty ? .fieldChanged : .ambiguousRelocation)
        }
        let ownedRel = occurrences[0]

        // 2. Where is the word to fix, inside our own run only? Correcting text
        //    the user typed themselves is never our business.
        let target = edit.replace as NSString
        let found: NSRange
        switch edit.occurrence {
        case .last:
            found = haystack.range(of: target as String, options: [.backwards, .literal], range: ownedRel)
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
                        newCommitted: newCommitted, newCommittedRange: newRange)
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
