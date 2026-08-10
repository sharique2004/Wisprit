// parakeet-probe — Parakeet TDT v3 (FluidAudio CoreML) B-0 gating spike.
//
// Measures, per corpus clip: batch decode latency, raw transcript (casing +
// punctuation exactly as the model emits it), and — when --vocab is given —
// the CTC keyword-spotting + vocabulary-rescoring pass (the FluidAudio
// "custom vocabulary boosting" pipeline) with timings, replacements, and
// optionally the full candidate evidence (--evidence).
//
// Output: JSONL on --out (or stdout). One {"kind":"utt"} row per clip, a
// {"kind":"rerun"} row (first clip decoded again warm, so cold-start ANE cost
// is visible by comparison), and one final {"kind":"summary"} row with load
// times and memory.
//
// Usage:
//   parakeet-probe --manifest <manifest.jsonl> --models-dir <tdt-repo-dir>
//                  [--vocab vocab.json] [--out out.jsonl]
//                  [--precision int8|int4] [--language en] [--evidence]
//
// --models-dir is the REPO directory (the one containing Encoder.mlmodelc,
// parakeet_v3_vocab.json, ...), e.g.
//   ~/MeetingScribe/native/asr-ab/models/parakeet-tdt-0.6b-v3
// It is opened READ-ONLY by AsrModels.load; nothing is written there. The CTC
// models for --vocab download to FluidAudio's default cache
// (~/Library/Application Support/FluidAudio/Models/) on first use.

import AVFoundation
import FluidAudio
import Foundation

let PINNED_REVISION = "5390df9752c8fc583596018360c5fd70d6fa6c75"

func die(_ msg: String) -> Never {
    FileHandle.standardError.write(("parakeet-probe: " + msg + "\n").data(using: .utf8)!)
    exit(1)
}

// MARK: - Arguments

var manifestPath: String?
var modelsDir: String?
var vocabPath: String?
var outPath: String?
var precisionRaw = "int8"
var languageCode = "en"
var wantEvidence = false
var noRescue = false

var it = CommandLine.arguments.dropFirst().makeIterator()
func next(_ flag: String) -> String {
    guard let v = it.next() else { die("\(flag) needs a value") }
    return v
}
while let a = it.next() {
    switch a {
    case "--manifest": manifestPath = next(a)
    case "--models-dir": modelsDir = next(a)
    case "--vocab": vocabPath = next(a)
    case "--out": outPath = next(a)
    case "--precision": precisionRaw = next(a)
    case "--language": languageCode = next(a)
    case "--evidence": wantEvidence = true
    case "--no-rescue": noRescue = true  // spotterRescueEnabled: false (#702/#724 — vendor-recommended for short vocabularies)
    case "--help", "-h":
        print("usage: parakeet-probe --manifest m.jsonl --models-dir DIR [--vocab v.json] [--out o.jsonl] [--precision int8|int4] [--language en] [--evidence]")
        exit(0)
    default: die("unknown argument \(a)")
    }
}

guard let manifestPath, FileManager.default.fileExists(atPath: manifestPath) else {
    die("--manifest required and must exist")
}
guard let modelsDir, FileManager.default.fileExists(atPath: modelsDir) else {
    die("--models-dir required and must exist")
}
guard let precision = ParakeetEncoderPrecision(rawValue: precisionRaw) else {
    die("--precision must be int8 or int4")
}
guard let language = Language(rawValue: languageCode) else {
    die("--language \(languageCode) unknown to this FluidAudio build")
}

// MARK: - Memory helpers

func residentMB() -> Double {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(
        MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576.0 : -1
}

func peakRSSMB() -> Double {
    var ru = rusage()
    getrusage(RUSAGE_SELF, &ru)
    return Double(ru.ru_maxrss) / 1_048_576.0  // ru_maxrss is bytes on macOS
}

// MARK: - Manifest

struct Clip {
    let id: String
    let audioURL: URL
    let ref: String
}

let manifestURL = URL(fileURLWithPath: manifestPath)
let manifestRoot = manifestURL.deletingLastPathComponent()
var clips: [Clip] = []
for line in try String(contentsOf: manifestURL, encoding: .utf8).split(separator: "\n") {
    guard !line.isEmpty,
        let obj = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
        let id = obj["id"] as? String,
        let audio = obj["audio"] as? String
    else { continue }
    let ref = (obj["ref"] as? String) ?? ""
    clips.append(Clip(id: id, audioURL: manifestRoot.appendingPathComponent(audio), ref: ref))
}
guard !clips.isEmpty else { die("manifest has no rows") }

// MARK: - Output

var outLines: [String] = []
func emit(_ obj: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
    outLines.append(String(data: data, encoding: .utf8)!)
}

// MARK: - Run

let semaphore = DispatchSemaphore(value: 0)

Task {
    do {
        let converter = AudioConverter()

        // --- TDT model load (timed; READ-ONLY on modelsDir) ---
        let rssBeforeLoad = residentMB()
        let tLoad0 = Date()
        let models = try await AsrModels.load(
            from: URL(fileURLWithPath: modelsDir), version: .v3, encoderPrecision: precision)
        let tdtLoadMs = Date().timeIntervalSince(tLoad0) * 1000
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        let rssAfterLoad = residentMB()

        // --- Optional vocabulary pipeline (CTC models: download on first use) ---
        var vocab: CustomVocabularyContext?
        var spotter: CtcKeywordSpotter?
        var rescorer: VocabularyRescorer?
        var ctcLoadMs = -1.0
        var rescorerCreateMs = -1.0
        var vocabTermCount = 0
        var vocabMinSim: Float = 0
        var vocabCbw: Float = 0
        if let vocabPath {
            let tCtc0 = Date()
            let (v, ctcModels) = try await CustomVocabularyContext.loadWithCtcTokens(from: vocabPath)
            ctcLoadMs = Date().timeIntervalSince(tCtc0) * 1000
            vocab = v
            vocabTermCount = v.terms.count
            let blankId = ctcModels.vocabulary.count
            let sp = CtcKeywordSpotter(models: ctcModels, blankId: blankId)
            spotter = sp
            let sizeCfg = ContextBiasingConstants.rescorerConfig(forVocabSize: v.terms.count)
            vocabMinSim = sizeCfg.minSimilarity
            vocabCbw = sizeCfg.cbw
            let rescorerConfig =
                noRescue
                ? VocabularyRescorer.Config(spotterRescueEnabled: false)
                : VocabularyRescorer.Config.default
            let tRe0 = Date()
            rescorer = try await VocabularyRescorer.create(
                spotter: sp,
                vocabulary: v,
                config: rescorerConfig,
                ctcModelDirectory: CtcModels.defaultCacheDirectory(for: ctcModels.variant)
            )
            rescorerCreateMs = Date().timeIntervalSince(tRe0) * 1000
        }
        let rssAfterVocab = residentMB()

        // --- Per-clip decode (+ boost) ---
        func runClip(_ clip: Clip, kind: String) async throws {
            let samples: [Float]
            do {
                samples = try converter.resampleAudioFile(clip.audioURL)
            } catch {
                emit(["kind": kind, "id": clip.id, "error": "audio read failed: \(error)"])
                return
            }
            let audioSeconds = Double(samples.count) / 16000.0

            var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
            let tDec0 = Date()
            let result = try await manager.transcribe(
                samples, decoderState: &decoderState, language: language)
            let decodeMs = Date().timeIntervalSince(tDec0) * 1000

            var row: [String: Any] = [
                "kind": kind,
                "id": clip.id,
                "ref": clip.ref,
                "audio_s": audioSeconds,
                "decode_ms": decodeMs,
                "raw": result.text,
                "confidence": Double(result.confidence),
            ]

            if let vocab, let spotter, let rescorer {
                let tSpot0 = Date()
                let spot = try await spotter.spotKeywordsWithLogProbs(
                    audioSamples: samples, customVocabulary: vocab, minScore: nil)
                let spotMs = Date().timeIntervalSince(tSpot0) * 1000
                row["spot_ms"] = spotMs
                row["spot_detections"] = spot.detections.map {
                    ["term": $0.term.text, "score": Double($0.score),
                     "start": $0.startTime, "end": $0.endTime]
                }

                if let timings = result.tokenTimings, !timings.isEmpty, !spot.logProbs.isEmpty {
                    let tRes0 = Date()
                    let rescored = rescorer.ctcTokenRescore(
                        transcript: result.text,
                        tokenTimings: timings,
                        logProbs: spot.logProbs,
                        frameDuration: spot.frameDuration,
                        cbw: vocabCbw,
                        marginSeconds: ContextBiasingConstants.defaultMarginSeconds,
                        minSimilarity: vocabMinSim
                    )
                    let rescoreMs = Date().timeIntervalSince(tRes0) * 1000
                    row["rescore_ms"] = rescoreMs
                    row["boosted"] = rescored.text
                    row["boost_modified"] = rescored.wasModified
                    row["replacements"] = rescored.replacements.map {
                        ["orig": $0.originalWord,
                         "repl": $0.replacementWord ?? "",
                         "orig_score": Double($0.originalScore),
                         "repl_score": Double($0.replacementScore ?? 0),
                         "apply": $0.shouldReplace,
                         "reason": $0.reason]
                    }

                    if wantEvidence {
                        let ev = rescorer.ctcTokenEvaluateCandidates(
                            transcript: result.text,
                            tokenTimings: timings,
                            logProbs: spot.logProbs,
                            frameDuration: spot.frameDuration,
                            cbw: vocabCbw,
                            marginSeconds: ContextBiasingConstants.defaultMarginSeconds,
                            minSimilarity: vocabMinSim
                        )
                        row["candidates"] = ev.candidates.map { c -> [String: Any] in
                            var d: [String: Any] = [
                                "origin": c.origin.rawValue,
                                "base_phrase": c.basePhrase,
                                "term": c.canonicalTerm,
                                "similarity": Double(c.similarity),
                                "comparison_passed": c.comparisonPassed,
                                "outcome": c.legacyOutcome.rawValue,
                                "reason": c.reason,
                            ]
                            if let a = c.matchedAlias { d["alias"] = a }
                            if let s = c.rawVocabularyCTCScore { d["vocab_ctc"] = Double(s) }
                            if let s = c.rawOriginalCTCScore { d["orig_ctc"] = Double(s) }
                            if let b = c.effectiveBoost { d["boost"] = Double(b) }
                            if let r = c.baseTextUTF8Range {
                                d["utf8_range"] = [r.lowerBound, r.upperBound]
                            }
                            return d
                        }
                    }
                } else {
                    row["boosted"] = result.text
                    row["boost_modified"] = false
                    row["boost_skipped"] = "no tokenTimings or empty logProbs"
                }
            }
            emit(row)
            FileHandle.standardError.write(
                ("  \(clip.id): \(String(format: "%5.0f", decodeMs)) ms  \(result.text)\n")
                    .data(using: .utf8)!)
        }

        for clip in clips {
            try await runClip(clip, kind: "utt")
        }
        // First clip again, warm — the delta vs its first run is ANE cold-start.
        if let first = clips.first {
            try await runClip(first, kind: "rerun")
        }

        emit([
            "kind": "summary",
            "revision": PINNED_REVISION,
            "precision": precision.rawValue,
            "language": languageCode,
            "models_dir": modelsDir,
            "tdt_load_ms": tdtLoadMs,
            "ctc_vocab_load_ms": ctcLoadMs,
            "rescorer_create_ms": rescorerCreateMs,
            "vocab_terms": vocabTermCount,
            "vocab_min_similarity": Double(vocabMinSim),
            "vocab_cbw": Double(vocabCbw),
            "spotter_rescue": !noRescue,
            "rss_before_load_mb": rssBeforeLoad,
            "rss_after_tdt_load_mb": rssAfterLoad,
            "rss_after_vocab_load_mb": rssAfterVocab,
            "rss_end_mb": residentMB(),
            "peak_rss_mb": peakRSSMB(),
        ])

        let payload = outLines.joined(separator: "\n") + "\n"
        if let outPath {
            try payload.write(to: URL(fileURLWithPath: outPath), atomically: true, encoding: .utf8)
            FileHandle.standardError.write(
                "parakeet-probe: \(clips.count) clips -> \(outPath)\n".data(using: .utf8)!)
        } else {
            print(payload)
        }
        semaphore.signal()
    } catch {
        FileHandle.standardError.write(
            "parakeet-probe: failed: \(error)\n".data(using: .utf8)!)
        exit(1)
    }
}

semaphore.wait()
exit(0)
