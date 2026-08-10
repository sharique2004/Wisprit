#if os(macOS)
import Foundation
import WispritEval

/// Everything `eval verify` decides, with no terminal in it.
///
/// Verification exists because of a failure mode that has no other detector: a
/// reader who says "the payload is JSON, not YAML" as "the payload is JSON, not
/// XML" writes a permanent 1-in-6 error into the reference, and every WER
/// afterwards is measured against a sentence nobody said. There is no automatic
/// way to tell that from an ASR error — only a person comparing the two.
///
/// So the loop is: transcribe, show the alignment, and let a human say which
/// side was wrong. The three answers are the three things that can be true —
/// the ASR was wrong (accept), the reference was wrong (fix), or the take was
/// (discard) — and each one is a pure function on the manifest.
enum EvalVerifyPlan {

    // MARK: - the keys

    enum Decision: Equatable {
        /// The reference is right and the hypothesis is just wrong — which is
        /// what the corpus is *for*. `verified: true`.
        case accept
        /// The reader said something other than the script. Rewrite `ref`.
        case fix
        /// The take is unusable (coughed, clipped, wrong line). The manifest
        /// line goes; the audio stays on disk under `.discarded`.
        case discard
        /// Stop here. Everything decided so far is already written.
        case quit
        case unknown(String)
    }

    /// Return is `accept`, because on a good corpus it is nine answers in ten
    /// and a review that costs a keystroke per clip does not get finished. The
    /// prompt spells the default in capitals so the cheap key is the visible one.
    static func decision(for input: String?) -> Decision {
        guard let input else { return .quit }
        switch input.trimmingCharacters(in: .whitespaces).lowercased() {
        case "", "a": return .accept
        case "f": return .fix
        case "d": return .discard
        case "q": return .quit
        case let other: return .unknown(other)
        }
    }

    // MARK: - applying a decision

    /// What one decision did, in manifest terms.
    enum Outcome: Equatable {
        case verified(CorpusEntry)
        /// Carries the old reference so the session log can show what changed —
        /// a silently rewritten reference is the same disease as a silently
        /// wrong one.
        case corrected(CorpusEntry, was: String)
        case removed(id: String, audio: String)
    }

    /// `fixed` is the edited reference, and is required for `.fix`. An empty or
    /// unchanged edit is **not** a fix: it means the reader changed their mind
    /// at the prompt, so it lands as a plain accept rather than as a rewrite to
    /// the same string with a `corrected` note nobody can act on.
    static func apply(_ decision: Decision, to entry: CorpusEntry, fixed: String? = nil)
        -> Outcome? {
        switch decision {
        case .accept:
            var out = entry
            out.verified = true
            return .verified(out)

        case .fix:
            let trimmed = (fixed ?? "").trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, trimmed != entry.ref else { return apply(.accept, to: entry) }
            var out = entry
            out.ref = trimmed
            out.verified = true
            return .corrected(out, was: entry.ref)

        case .discard:
            return .removed(id: entry.id, audio: entry.audio)

        case .quit, .unknown:
            return nil
        }
    }

    /// The manifest after one decision. Order is preserved and only the decided
    /// line moves: a manifest is reviewed with `git diff`, and a verify pass
    /// that reorders 130 lines is unreviewable.
    static func applying(_ outcome: Outcome, to entries: [CorpusEntry]) -> [CorpusEntry] {
        switch outcome {
        case let .verified(entry), let .corrected(entry, _):
            return entries.map { $0.id == entry.id ? entry : $0 }
        case let .removed(id, _):
            return entries.filter { $0.id != id }
        }
    }

    /// A discarded take is renamed, never deleted. The audio is the only
    /// irreplaceable thing in this directory — a reader is not coming back to
    /// say that sentence again — and the suffix is enough to keep it out of
    /// every glob the harness walks.
    static func discardedPath(_ audio: String) -> String { audio + ".discarded" }

    // MARK: - the alignment

    /// `ref` vs `hyp` as one line, over `.asr` tokens — the same normalization
    /// WER runs on, so what the reviewer reads is what the number will count.
    /// Casing and punctuation differences are invisible here **on purpose**:
    /// they are the formatter's problem (CER's), not evidence that the reader
    /// misread the line.
    ///
    /// Read every marker as reference→hypothesis: `[-x]` is a word the reference
    /// has and the transcript does not, `[+x]` is one the transcript invented.
    ///
    ///     the payload is json not [yaml→xml]
    ///     we should [-just] ship it [+today]
    static func diff(ref: String, hyp: String) -> String {
        let ops = Score.align(ref: Normalize.tokens(ref, profile: .asr),
                              hyp: Normalize.tokens(hyp, profile: .asr))
        guard !ops.pairs.isEmpty else { return "(both empty)" }
        return ops.pairs.map { pair in
            switch pair.op {
            case .hit: return pair.ref ?? ""
            case .sub: return "[\(pair.ref ?? "")→\(pair.hyp ?? "")]"
            case .del: return "[-\(pair.ref ?? "")]"
            case .ins: return "[+\(pair.hyp ?? "")]"
            }
        }.joined(separator: " ")
    }

    /// `1 sub, 0 del, 1 ins over 9 words — WER 0.222`. Printed next to the diff
    /// so a reviewer can triage on the number and read the words only when it
    /// is surprising.
    static func summary(ref: String, hyp: String) -> String {
        let wer = Score.wer(ref: ref, hyp: hyp, profile: .asr)
        return String(format: "%d sub, %d del, %d ins over %d words — WER %.3f",
                      wer.sub, wer.del, wer.ins, wer.refWords, wer.rate)
    }

    /// Clips a verify pass should look at, in manifest order.
    ///
    /// Already-verified clips are skipped so a resumed pass picks up where it
    /// stopped, exactly as `eval record` resumes — a 130-clip review does not
    /// happen in one sitting either. `--speaker` narrows it further.
    static func pending(_ entries: [CorpusEntry], speaker: String? = nil) -> [CorpusEntry] {
        entries.filter { entry in
            guard entry.verified != true else { return false }
            guard let speaker else { return true }
            return entry.speaker == speaker
        }
    }
}
#endif
