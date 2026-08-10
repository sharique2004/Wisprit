#if os(macOS)
import AVFoundation
import Foundation
import WispritEngine
import WispritEval

/// `Wisprit eval record` — one script line at a time, through the real
/// microphone, into a corpus.
///
/// Deliberately thin. Every decision this file could get wrong lives in
/// `EvalRecordPlan` and `EvalScript`, both pure and both tested; what is left
/// here is a `readLine()` loop, `MicCapture`, and writing two files. The reason
/// is the shape of the failure: a recording session is an hour of a person's
/// voice that cannot be re-run from a cache, and the bug you find at clip 90 has
/// already cost you clips 1–89.
///
/// The capture path is the **live one**, not a copy of it. `MicCapture` is what
/// the hotkey uses, so the corpus is recorded through the same tap, the same
/// `PcmDownconverter` and the same 16 kHz mono Int16 canonical bytes the ASR
/// sees in production. A corpus recorded through a different reader would
/// measure the reader.
struct EvalRecorder {

    let options: EvalCommand.Options

    // MARK: - failures

    enum RecordError: Error, CustomStringConvertible {
        case noCheckout
        case missingScript(URL)
        case script(String)
        case micDenied(String)
        case micUnavailable
        case corpus(String)

        var description: String {
            switch self {
            case .noCheckout:
                return "could not locate the Wisprit checkout (set WISPRIT_EVAL_ROOT to it)"
            case let .missingScript(url):
                return "\(url.path) not found — see tools/eval/scripts/human-v1/README.md"
            case let .script(detail):
                return "script: \(detail)"
            case let .micDenied(state):
                return """
                    microphone access is \(state) for this binary — grant it in \
                    System Settings ▸ Privacy & Security ▸ Microphone, then run this again. \
                    A command-line build asks under its own identity, so granting it to \
                    Wisprit.app is not enough.
                    """
            case .micUnavailable:
                return """
                    the microphone could not be opened (no input device, or the tap was \
                    refused). `Wisprit doctor` reports the permission state; check that an \
                    input device is selected in System Settings ▸ Sound ▸ Input.
                    """
            case let .corpus(detail):
                return "corpus: \(detail)"
            }
        }
    }

    // MARK: - entry point

    func run() -> Int32 {
        do {
            return try record()
        } catch let error as RecordError {
            FileHandle.standardError.write(Data("eval record: \(error.description)\n".utf8))
            return 1
        } catch {
            FileHandle.standardError.write(Data("eval record: \(error)\n".utf8))
            return 1
        }
    }

    private func record() throws -> Int32 {
        guard let root = EvalPaths.repoRoot() else { throw RecordError.noCheckout }
        let script = try loadScript(root: root)
        let speaker = EvalRecordPlan.slug(options.speaker ?? "")
        let mic = EvalRecordPlan.slug(options.mic ?? EvalRecordPlan.defaultMic)
        let split = EvalRecordPlan.split(forSpeaker: speaker, override: options.split)

        let corpusDir = corpusDirectory(root: root)
        let manifestURL = corpusDir.appendingPathComponent("manifest.jsonl")
        let existing = try loadManifest(manifestURL)
        let steps = EvalRecordPlan.steps(script: script, speaker: speaker, mic: mic,
                                         recorded: Set(existing.map(\.id)))
        let todo = EvalRecordPlan.outstanding(steps)

        printHeader(script: script, speaker: speaker, mic: mic, split: split,
                    corpusDir: corpusDir, steps: steps)
        guard !todo.isEmpty else {
            print("nothing to record — every line of \(script.category) is already in the manifest "
                  + "for \(speaker)/\(mic).")
            return 0
        }

        // Checked before the first prompt, never after: asking someone to read
        // thirty sentences and *then* discovering the tap is refused is the one
        // outcome this tool exists to prevent.
        try requireMicrophone()

        let audioDir = corpusDir.appendingPathComponent("audio/\(speaker)", isDirectory: true)
        try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)

        var written = 0
        var skipped = 0
        loop: for (position, item) in todo.enumerated() {
            let heading = "[\(position + 1)/\(todo.count)] \(script.category) · \(item.id)"
            switch try take(item: item, heading: heading, script: script, speaker: speaker,
                            mic: mic, split: split, audioDir: audioDir,
                            manifestURL: manifestURL) {
            case .recorded: written += 1
            case .skipped: skipped += 1
            case .quit(let committed):
                if committed { written += 1 }
                break loop
            }
        }

        print("")
        print("recorded \(written), skipped \(skipped), "
              + "\(todo.count - written - skipped) left → \(manifestURL.path)")
        if written > 0 {
            print("next: Wisprit eval verify --corpus \(options.corpus) --speaker \(speaker)")
        }
        return 0
    }

    // MARK: - one line

    /// `quit(committed:)` because stopping is not the same as discarding: a take
    /// already on disk when the reader presses `q` is kept, and the tally has to
    /// say so.
    private enum Take { case recorded, skipped, quit(committed: Bool) }

    private func take(item: (line: EvalScript.Line, id: String), heading: String,
                      script: EvalScript.File, speaker: String, mic: String, split: String,
                      audioDir: URL, manifestURL: URL) throws -> Take {
        while true {
            print("")
            print(heading)
            print("  \(item.line.spoken)")
            // Shown only when the two differ, which is rare — printing "ref: "
            // under every line would train the reader to stop reading it.
            if item.line.ref != item.line.spoken { print("  → \(item.line.ref)") }
            if !item.line.terms.isEmpty {
                print("  terms: \(item.line.terms.joined(separator: ", "))")
            }
            if let bypass = item.line.refineBypass { print("  bypass: \(bypass)") }
            print("  Return to record · s Return to skip · q Return to stop")

            switch EvalRecordPlan.key(for: readLine(strippingNewline: false)) {
            case .go, .retake:
                break
            case .skip:
                print("  skipped")
                return .skipped
            case .quit:
                return .quit(committed: false)
            case .unknown(let text):
                print("  '\(text)' is not one of Return / s / q")
                continue
            }

            let pcm = try capture()
            let seconds = Double(WavFile.durationMs(pcmBytes: pcm.count)) / 1000.0
            print(String(format: "  %.1fs, %.0f kB", seconds, Double(pcm.count) / 1000.0))
            if pcm.isEmpty {
                print("  the microphone delivered nothing — re-reading this line")
                continue
            }

            print("  Return to keep · space Return to re-take · s Return to skip")
            switch EvalRecordPlan.key(for: readLine(strippingNewline: false)) {
            case .retake:
                continue
            case .skip:
                print("  skipped")
                return .skipped
            case .quit:
                // A take already exists and quitting would throw it away, so it
                // is written first.
                try commit(pcm: pcm, item: item, script: script, speaker: speaker, mic: mic,
                           split: split, audioDir: audioDir, manifestURL: manifestURL)
                return .quit(committed: true)
            case .go, .unknown:
                // An unrecognized key keeps the take. The alternative is losing
                // a reading to a typo, and the reviewer sees every clip anyway.
                try commit(pcm: pcm, item: item, script: script, speaker: speaker, mic: mic,
                           split: split, audioDir: audioDir, manifestURL: manifestURL)
                return .recorded
            }
        }
    }

    /// Record until the reader presses Return. The tap runs on its own thread,
    /// so blocking this one on `readLine` is exactly right — and it is why the
    /// stop key is Return rather than a key-up: a terminal has no key-up.
    private func capture() throws -> Data {
        let sink = PcmSink()
        let capture = MicCapture { sink.append($0) }
        guard capture.start() else { throw RecordError.micUnavailable }
        print("  ● recording — Return to stop")
        _ = readLine(strippingNewline: false)
        capture.stop()
        return sink.take()
    }

    private func commit(pcm: Data, item: (line: EvalScript.Line, id: String),
                        script: EvalScript.File, speaker: String, mic: String, split: String,
                        audioDir: URL, manifestURL: URL) throws {
        let audio = audioDir.appendingPathComponent("\(item.id).wav")
        let file = WavFile.data(pcm: pcm)
        try file.write(to: audio, options: .atomic)

        // The sha is of the file on disk, not of the buffer: it is the eval
        // cache key, and the cache is keyed by what `eval asr` will read back.
        let entry = EvalRecordPlan.entry(
            line: item.line, id: item.id, category: script.category, speaker: speaker,
            mic: mic, split: split, sha256: EvalPaths.sha256Hex(file),
            durationMs: WavFile.durationMs(pcmBytes: pcm.count))
        try append(entry, to: manifestURL)
        print("  kept → \(entry.audio)")
    }

    // MARK: - files

    private func loadScript(root: URL) throws -> EvalScript.File {
        guard let raw = options.script else { throw RecordError.script("no --script") }
        let url = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
        let resolved = FileManager.default.fileExists(atPath: url.path)
            ? url
            : root.appendingPathComponent(raw)
        guard FileManager.default.fileExists(atPath: resolved.path) else {
            throw RecordError.missingScript(resolved)
        }
        do {
            return try EvalScript.parse(String(contentsOf: resolved, encoding: .utf8),
                                        name: resolved.lastPathComponent)
        } catch let error as EvalScript.ScriptError {
            throw RecordError.script(error.description)
        }
    }

    private func corpusDirectory(root: URL) -> URL {
        options.out.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath,
                              isDirectory: true) }
            ?? EvalPaths.corpusDir(root: root, corpus: options.corpus)
    }

    /// An absent manifest is an empty one — the first speaker of a new corpus
    /// must not have to create a file by hand before they can start.
    private func loadManifest(_ url: URL) throws -> [CorpusEntry] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            return try Corpus.parse(jsonl: String(contentsOf: url, encoding: .utf8))
        } catch CorpusError.empty {
            return []
        } catch let error as CorpusError {
            throw RecordError.corpus(error.description)
        }
    }

    /// Appended per clip, never buffered to the end: a session that dies at clip
    /// 90 keeps 89 clips, and the resume rule reads exactly this file.
    private func append(_ entry: CorpusEntry, to url: URL) throws {
        let line = try Corpus.jsonLine(entry) + "\n"
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
        guard manager.fileExists(atPath: url.path) else {
            return try line.write(to: url, atomically: true, encoding: .utf8)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(line.utf8))
    }

    // MARK: - the microphone

    /// Reported before the session, and named as a grant rather than as an
    /// error. `.notDetermined` still proceeds: the system prompt is raised here
    /// and answering it is the grant.
    private func requireMicrophone() throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .denied:
            throw RecordError.micDenied("denied")
        case .restricted:
            throw RecordError.micDenied("restricted")
        case .notDetermined:
            print("asking for microphone access — answer the system prompt, then press Return")
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            _ = readLine()
            guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
                throw RecordError.micDenied("not granted")
            }
        @unknown default:
            return
        }
    }

    // MARK: - the header

    private func printHeader(script: EvalScript.File, speaker: String, mic: String,
                             split: String, corpusDir: URL, steps: [EvalRecordPlan.Step]) {
        let done = steps.count - EvalRecordPlan.outstanding(steps).count
        print("corpus   \(options.corpus) → \(corpusDir.path)")
        print("script   \(script.category) (\(script.lines.count) lines)")
        print("speaker  \(speaker) · mic \(mic) · split \(split)")
        if done > 0 { print("resume   \(done) already recorded, skipping") }
        guard !script.directions.isEmpty else { return }
        print("")
        for direction in script.directions { print("  \(direction)") }
    }

    /// The render thread hands chunks in; the main thread takes them out once.
    private final class PcmSink: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func append(_ chunk: Data) {
            lock.lock(); data.append(chunk); lock.unlock()
        }

        func take() -> Data {
            lock.lock(); defer { data = Data(); lock.unlock() }
            return data
        }
    }
}
#endif
