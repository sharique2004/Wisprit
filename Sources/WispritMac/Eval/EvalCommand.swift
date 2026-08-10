#if os(macOS)
import Foundation

/// `Wisprit eval <verb> [flags]` — the accuracy harness's command line.
///
/// Parsing lives here, alone and pure, for the same reason `StatsCommand.parse`
/// does: the argument spelling is a contract with the scoreboard (a row records
/// the `config` string this parser produced), and a contract asserted by a test
/// is worth more than one asserted by a string comparison inside `main`.
///
/// Two-phase by design — `asr` turns audio into text once per (corpus, engine)
/// and caches it, `stages` replays the text through refine/dictionary
/// combinations offline. Everything after `stages` is arithmetic.
enum EvalCommand {

    // MARK: - the grammar

    /// `record` and `verify` are the two interactive verbs — a person with a
    /// microphone and a person with a judgement call. They are routed away from
    /// `EvalRunner` in `run`, because a harness that replays cached transcripts
    /// and a harness that opens the microphone have nothing in common but a
    /// noun.
    enum Verb: String, CaseIterable {
        case asr
        case stages
        case score
        case refine
        case report
        case all
        case record
        case verify

        /// True for the verbs that read from stdin. Used to pick the corpus
        /// default: recording into the synthetic corpus is never what anyone
        /// means, and a human take landing in `tts-samantha` would poison the
        /// one corpus whose whole job is to be admittedly synthetic.
        var isInteractive: Bool { self == .record || self == .verify }
    }

    /// Which recognizer produced the transcript. `speech` is the live path
    /// (`SpeechAnalyzerEngine`); `dictation` is the off-path
    /// `VocabularyChannel`, the only engine whose `contextualStrings` biasing
    /// actually works — measuring both is how Phase 3 gets a before-number.
    enum Engine: String, CaseIterable {
        case speech
        case dictation
    }

    /// A pipeline stage the matrix switches on. Absent means "measure both",
    /// which is what `eval all` needs and what a bare `eval stages` should do.
    enum Toggle: String, CaseIterable {
        case on
        case off

        var isOn: Bool { self == .on }
    }

    struct Options: Equatable {
        var verb: Verb
        /// Defaulted per verb by `parse` — `humanCorpus` for the interactive
        /// verbs, `defaultCorpus` for the replay ones. Constructing `Options`
        /// directly (a test) gets the replay default and can override it.
        var corpus: String = defaultCorpus
        var engine: Engine = .speech
        /// nil = both, i.e. the full matrix.
        var refine: Toggle?
        /// nil = both.
        var dict: Toggle?
        /// Run directory; nil = `docs/eval/runs`.
        var out: String?
        /// `eval refine` samples each battery case this many times — the model
        /// is stochastic, so a single pass is an anecdote.
        var repeatCount: Int = 3
        /// Baseline file to compare against; nil = `docs/eval/BASELINE.json`.
        var baseline: String?
        /// Restrict to these corpus categories; empty = all of them.
        var categories: [String] = []
        /// Feed audio at wall-clock speed. Off by default: real-time pacing
        /// costs one wall-second per audio-second and changes no transcript
        /// (the analyzer sees the same samples), so it is only worth paying
        /// when the question is about latency rather than accuracy.
        var realtime: Bool = false

        // MARK: the interactive verbs

        /// `record`: the script file to read, absolute or repo-relative.
        var script: String?
        /// `record`: who is reading. `verify`: whose clips to review.
        /// Slugged before it reaches an id — see `EvalRecordPlan.slug`.
        var speaker: String?
        /// `record`: which microphone this pass is on. Part of the clip id, so
        /// the Bluetooth pass of a script the internal mic already recorded is
        /// new clips rather than a duplicate-id error.
        var mic: String?
        /// `record`: force the dev/held side. Absent means the by-speaker rule
        /// (`EvalRecordPlan.split`), which is the one that should normally
        /// decide — an override is for a speaker joining an existing side.
        var split: String?
    }

    enum Parsed: Equatable {
        case run(Options)
        case invalid(String)
    }

    static let defaultCorpus = "tts-samantha"
    /// Where human takes go. The interactive verbs default to it — see
    /// `Verb.isInteractive`.
    static let humanCorpus = "human-v1"

    static let usage = """
        usage: Wisprit eval <asr|stages|score|refine|report|all|record|verify> [flags]

          asr       audio → text, once per (corpus, engine); cached by audio sha
          stages    replay cached text through corrections → refine → postprocess
          score     WER/CER/term-recall/zero-edit per stage from a replay
          refine    score the RefineBattery against the live model
          report    append a RESULTS.md section + write the run JSON
          all       asr → stages × the config matrix → score → report; the
                    refine=on rows also carry a battery score
          record    read a script aloud into the corpus, one line at a time,
                    through the live microphone path (resumable)
          verify    review ref vs hyp per clip and accept / fix / discard

        flags:
          --corpus <id>          corpus under tools/eval/corpus
                                 (default: \(defaultCorpus); \(humanCorpus) for record/verify)
          --engine speech|dictation
                                 recognizer for the asr phase (default: speech)
          --refine on|off        default: both
          --dict on|off          default: both
          --out <dir>            run artifacts (default: docs/eval/runs); for
                                 `record`, the corpus directory itself
          --repeat N             battery samples per case (default: 3)
          --baseline <path>      default: docs/eval/BASELINE.json
          --categories a,b       restrict to these corpus categories
          --realtime             pace audio at wall-clock speed

        record / verify:
          --script <file>        one category per file, under
                                 tools/eval/scripts/human-v1 (record; required)
          --speaker <id>         who is reading (record; required) or whose
                                 clips to review (verify; optional filter)
          --mic <label>          microphone for this pass, e.g. internal,
                                 airpods-pro (default: \(EvalRecordPlan.defaultMic))
          --split dev|held       override the by-speaker split rule
                                 (default: \(EvalRecordPlan.devSpeaker) is dev, everyone else held)

        Recording protocol — speakers, passes, and why the split is by speaker:
        tools/eval/scripts/human-v1/README.md
        """

    // MARK: - parsing

    /// Pure. Every failure is a message, never an exit — `run` owns the exit
    /// code so a test can exercise the whole grammar without a process.
    static func parse(_ arguments: [String]) -> Parsed {
        guard let head = arguments.first, !head.isEmpty else {
            return .invalid("eval needs a verb")
        }
        guard let verb = Verb(rawValue: head) else {
            return .invalid("unknown verb: \(head)")
        }

        var options = Options(verb: verb)
        if verb.isInteractive { options.corpus = humanCorpus }
        var index = arguments.index(after: arguments.startIndex)
        while index < arguments.endIndex {
            let argument = arguments[index]
            guard argument.hasPrefix("--") else {
                return .invalid("unexpected argument: \(argument)")
            }
            // `--realtime` is the only flag without a value; taking it first
            // keeps the value-reading path below free of special cases.
            if argument == "--realtime" {
                options.realtime = true
                index += 1
                continue
            }

            let name: String
            var value: String?
            if let split = argument.firstIndex(of: "=") {
                name = String(argument[argument.startIndex..<split])
                value = String(argument[argument.index(after: split)...])
            } else {
                name = argument
                index += 1
                value = index < arguments.endIndex ? arguments[index] : nil
            }
            index += 1

            guard let raw = value, !raw.isEmpty else {
                return .invalid("\(name) needs a value")
            }
            switch name {
            case "--corpus":
                options.corpus = raw
            case "--engine":
                guard let engine = Engine(rawValue: raw) else {
                    return .invalid("--engine must be "
                                    + Engine.allCases.map(\.rawValue).joined(separator: "|"))
                }
                options.engine = engine
            case "--refine":
                guard let toggle = Toggle(rawValue: raw) else {
                    return .invalid("--refine must be on|off")
                }
                options.refine = toggle
            case "--dict":
                guard let toggle = Toggle(rawValue: raw) else {
                    return .invalid("--dict must be on|off")
                }
                options.dict = toggle
            case "--out":
                options.out = raw
            case "--repeat":
                guard let count = Int(raw), count > 0 else {
                    return .invalid("--repeat needs a positive whole number")
                }
                options.repeatCount = count
            case "--baseline":
                options.baseline = raw
            case "--categories":
                let names = raw.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                guard !names.isEmpty else {
                    return .invalid("--categories needs at least one category name")
                }
                options.categories = names
            case "--script":
                options.script = raw
            case "--speaker":
                options.speaker = raw
            case "--mic":
                options.mic = raw
            case "--split":
                guard EvalRecordPlan.splits.contains(raw) else {
                    return .invalid("--split must be "
                                    + EvalRecordPlan.splits.sorted().joined(separator: "|"))
                }
                options.split = raw
            default:
                return .invalid("unknown option: \(name)")
            }
        }
        return validate(options)
    }

    /// The two flags `record` cannot invent for itself.
    ///
    /// A speaker id is not guessable (the whole corpus is partitioned by it) and
    /// a script is not either — and both failures are only discoverable an hour
    /// into a session if they are allowed through, because that is when the
    /// manifest turns out to be under the wrong name.
    static func validate(_ options: Options) -> Parsed {
        guard options.verb == .record else { return .run(options) }
        guard let script = options.script, !script.isEmpty else {
            return .invalid("record needs --script <file> "
                            + "(one per category, under tools/eval/scripts/\(humanCorpus))")
        }
        guard let speaker = options.speaker,
              !EvalRecordPlan.slug(speaker).isEmpty else {
            return .invalid("record needs --speaker <id> — the corpus is split by speaker, "
                            + "so a take with no speaker has nowhere to go")
        }
        return .run(options)
    }

    // MARK: - the config matrix

    /// One point of the (refine × dictionary) matrix.
    struct Config: Equatable, Hashable {
        var refine: Bool
        var dict: Bool

        /// The exact string a scoreboard row carries in `config`. Pinned by a
        /// test: change it and every previously recorded row stops matching its
        /// baseline band, silently.
        var label: String {
            "refine=\(refine ? "on" : "off"),dict=\(dict ? "on" : "off")"
        }
    }

    /// Expand the toggles into the configurations to measure.
    ///
    /// Order is least-pipeline-first so a RESULTS.md section reads as a ladder:
    /// raw deterministic behaviour, then each layer switched on. It is fixed
    /// rather than incidental because the run JSON files are named after it.
    static func configs(_ options: Options) -> [Config] {
        let refines = options.refine.map { [$0.isOn] } ?? [false, true]
        let dicts = options.dict.map { [$0.isOn] } ?? [false, true]
        return refines.flatMap { refine in dicts.map { Config(refine: refine, dict: $0) } }
    }

    // MARK: - entry point

    static func run(arguments: [String]) -> Int32 {
        switch parse(arguments) {
        case .invalid(let message):
            FileHandle.standardError.write(Data("\(message)\n\n\(usage)\n".utf8))
            return 2
        case .run(let options):
            switch options.verb {
            case .record: return EvalRecorder(options: options).run()
            case .verify: return EvalVerifier(options: options).run()
            default: return EvalRunner(options: options).run()
            }
        }
    }
}
#endif
