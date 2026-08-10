#if os(macOS)
import Foundation
import WispritEval

/// Everything `eval record` decides, with no microphone and no terminal in it.
///
/// The interactive half of a recorder is four lines of `readLine()`. The part
/// that can be wrong — which lines are still outstanding, what a clip is called,
/// which split it lands in, what the manifest line says — is all here, pure, so
/// a recording session that goes wrong goes wrong in a way a test already
/// covered.
enum EvalRecordPlan {

    // MARK: - names

    /// The manifest id: `spk01.internal.pn-01`.
    ///
    /// The clip id alone (category + index) is what the reader sees and what the
    /// filename carries, but it cannot be the manifest id: the corpus holds
    /// every speaker's take of `pn-01`, plus a second take per microphone, and
    /// `Corpus.parse` refuses duplicate ids. Putting speaker and mic in front is
    /// what makes "record the same script again on Bluetooth" mean *new clips*
    /// rather than a collision — and what makes the resume rule below correct
    /// for free.
    static func manifestID(speaker: String, mic: String, clipID: String) -> String {
        "\(speaker).\(mic).\(clipID)"
    }

    /// `audio/<speaker>/<id>.wav`, relative to the manifest.
    static func audioPath(speaker: String, id: String) -> String {
        "audio/\(speaker)/\(id).wav"
    }

    /// A label a person typed, made safe for an id and a filename: lowercased,
    /// runs of anything that is not an ASCII letter or digit collapsed to one
    /// hyphen. "AirPods Pro" → `airpods-pro`, "MacBook internal" →
    /// `macbook-internal`.
    ///
    /// ASCII-only, deliberately. This string becomes a filename, a JSON value
    /// and half of a manifest id that other tools match on; a `café` that is
    /// precomposed on one machine and decomposed on another is two different
    /// ids for the same microphone. Losing an accent from a label is a smaller
    /// problem than a corpus that silently splits in half.
    static func slug(_ raw: String) -> String {
        var out = ""
        var pendingSeparator = false
        for character in raw.lowercased() {
            if character.isASCII, character.isLetter || character.isNumber {
                if pendingSeparator, !out.isEmpty { out.append("-") }
                pendingSeparator = false
                out.append(character)
            } else {
                pendingSeparator = true
            }
        }
        return out
    }

    /// The microphone label when none was given. Every corpus row records where
    /// the audio came from, so there is no "unspecified" — the default names the
    /// pass the protocol asks for first.
    static let defaultMic = "internal"

    // MARK: - the split

    /// `dev` for the first speaker, `held` for everyone else.
    ///
    /// The split is **by speaker**, not by utterance: thresholds tune on one
    /// person's voice and are reported on voices the tuning never saw. An
    /// utterance-level split would let the same speaker's other 129 clips leak
    /// their acoustics into the held set, which is exactly the leak the rule
    /// exists to prevent. `--split` overrides it for a speaker who is joining an
    /// existing side.
    static let devSpeaker = "spk01"
    static let splits: Set<String> = ["dev", "held"]

    static func split(forSpeaker speaker: String, override: String? = nil) -> String {
        if let override { return override }
        return speaker == devSpeaker ? "dev" : "held"
    }

    // MARK: - the plan

    /// What the recorder should do with one script line.
    enum Step: Equatable {
        case record(EvalScript.Line, id: String)
        /// Already in the manifest for this speaker and microphone. Reported
        /// rather than silently dropped: a resumed session that skips 40 lines
        /// should say so, so an unexpected 130 means the manifest was lost.
        case done(EvalScript.Line, id: String)
    }

    /// Idempotent resume. `recorded` is the set of manifest ids that already
    /// exist — pass every id in the manifest; the speaker and mic are already
    /// baked into each one, so nothing needs filtering first.
    static func steps(script: EvalScript.File, speaker: String, mic: String,
                      recorded: Set<String>) -> [Step] {
        script.lines.map { line in
            let id = manifestID(speaker: speaker, mic: mic, clipID: line.clipID)
            return recorded.contains(id) ? .done(line, id: id) : .record(line, id: id)
        }
    }

    static func outstanding(_ steps: [Step]) -> [(line: EvalScript.Line, id: String)] {
        steps.compactMap {
            guard case let .record(line, id) = $0 else { return nil }
            return (line, id)
        }
    }

    // MARK: - the manifest line

    /// One recorded take, as the corpus sees it.
    ///
    /// `source` is `.human` and can be nothing else here — that is the whole
    /// point of the verb, and the scoreboard's honesty rule keys on it.
    static func entry(line: EvalScript.Line, id: String, category: String, speaker: String,
                      mic: String, split: String, sha256: String,
                      durationMs: Int) -> CorpusEntry {
        CorpusEntry(id: id, audio: audioPath(speaker: speaker, id: id), sha256: sha256,
                    ref: line.ref, category: category, speaker: speaker, source: .human,
                    mic: mic, script: line.spoken, durationMs: durationMs,
                    expect: line.expectation, split: split, verified: nil)
    }

    // MARK: - the keys

    /// What the reader pressed. One vocabulary for both prompts — arming a take
    /// and ending one are the same three choices from the reader's side, and two
    /// enums would be two things to remember at 2 a.m.
    enum Key: Equatable {
        /// Return on its own: arm the take, or keep the one just recorded.
        case go
        /// A space (or `r`): throw this take away and read the line again.
        case retake
        /// `s`: leave this line unrecorded and move on.
        case skip
        /// `q`, or end of input — a piped stdin must not loop forever.
        case quit
        case unknown(String)
    }

    /// Deliberately does **not** trim before testing for empty: "Return" and
    /// "space then Return" are different keys and trimming would make them the
    /// same one. Everything else is trimmed and lowercased, so `S ` is `s`.
    static func key(for input: String?) -> Key {
        guard let input else { return .quit }
        var stripped = Substring(input)
        // `isNewline` rather than a comparison against "\n": Swift folds CRLF
        // into ONE Character, so `last == "\n"` is false for a line ending the
        // terminal is entitled to send.
        while let last = stripped.last, last.isNewline { stripped.removeLast() }
        if stripped.isEmpty { return .go }
        let trimmed = stripped.trimmingCharacters(in: .whitespaces).lowercased()
        switch trimmed {
        case "": return .retake            // whitespace only, i.e. the space key
        case "r": return .retake
        case "s": return .skip
        case "q": return .quit
        default: return .unknown(trimmed)
        }
    }
}
#endif
