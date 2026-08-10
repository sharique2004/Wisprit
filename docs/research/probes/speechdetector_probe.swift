// SpeechDetector off-path probe (FINAL-PLAN B-6 / R16, judge-feasibility §6.2).
//
// Question: is Apple's `SpeechDetector` VERDICT-REPORTING (a usable
// silent-vs-speech oracle over retained PCM) or gating-only? If it reports
// verdicts, it can replace the hand-tuned `voicedPeakThreshold` in the
// `EmptyReason` silent/produced_nothing split with an engine-calibrated one
// (obsoleting R26's constant, per the plan). This probe is OFF-PATH by
// construction: fresh analyzer, pre-recorded PCM, no mic, no network beyond
// `say`'s local synthesis.
//
// API surface (macOS 26 SDK swiftinterface, read 2026-08-10):
//   SpeechDetector(detectionOptions: .init(sensitivityLevel: .low|.medium|.high),
//                  reportResults: Bool)  : SpeechModule
//   .results : AsyncSequence<SpeechDetector.Result>  where Result carries
//   range: CMTimeRange, resultsFinalizationTime: CMTime, speechDetected: Bool
// — so the TYPE is verdict-reporting; the probe tests whether results actually
// arrive when fed utterance-shaped PCM, in both topologies (detector alone,
// detector + transcriber), across silence / speech / quiet speech.
//
// Run:  cd docs/research/probes
//       say -o sdp_speech.aiff "Hello there, this is a quick test of speech detection."
//       afconvert -f WAVE -d LEI16@16000 -c 1 sdp_speech.aiff sdp_speech.wav
//       swiftc -O -parse-as-library speechdetector_probe.swift -o sdp && ./sdp
// Findings: docs/notes/asr-notes.md (appended 2026-08-10).

import AVFoundation
import Foundation
import Speech

func loadPcm(_ path: String) throws -> [Int16] {
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                               channels: 1, interleaved: true)!
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                  frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: buffer)
    if file.processingFormat.commonFormat == .pcmFormatInt16,
       file.processingFormat.sampleRate == 16_000 {
        let p = buffer.int16ChannelData![0]
        return Array(UnsafeBufferPointer(start: p, count: Int(buffer.frameLength)))
    }
    let converter = AVAudioConverter(from: file.processingFormat, to: format)!
    let out = AVAudioPCMBuffer(pcmFormat: format,
                               frameCapacity: AVAudioFrameCount(Double(buffer.frameLength)
                                   * 16_000 / file.processingFormat.sampleRate + 1))!
    var served = false
    var err: NSError?
    converter.convert(to: out, error: &err) { _, status in
        if served { status.pointee = .noDataNow; return nil }
        served = true; status.pointee = .haveData; return buffer
    }
    let p = out.int16ChannelData![0]
    return Array(UnsafeBufferPointer(start: p, count: Int(out.frameLength)))
}

func scale(_ samples: [Int16], by factor: Double) -> [Int16] {
    samples.map { Int16(max(-32768, min(32767, (Double($0) * factor).rounded()))) }
}

func meterPeak(_ samples: [Int16]) -> Double {
    // The production meter: per-100ms-chunk RMS ×4 clamped, max over chunks.
    var peak = 0.0
    var i = 0
    while i < samples.count {
        let end = min(i + 1600, samples.count)
        var sum = 0.0
        for j in i..<end { let v = Double(samples[j]) / 32768.0; sum += v * v }
        let rms = (sum / Double(end - i)).squareRoot()
        peak = max(peak, min(1.0, rms * 4.0))
        i = end
    }
    return peak
}

struct CaseResult {
    var label: String
    var results: [(range: String, detected: Bool)]
    var errorText: String?
    var transcript: String?
}

func runCase(label: String, samples: [Int16], sensitivity: SpeechDetector.SensitivityLevel,
             withTranscriber: Bool) async -> CaseResult {
    let detector = SpeechDetector(
        detectionOptions: .init(sensitivityLevel: sensitivity), reportResults: true)
    var modules: [any SpeechModule] = [detector]
    var transcriber: SpeechTranscriber?
    if withTranscriber {
        let st = SpeechTranscriber(locale: Locale(identifier: "en-US"),
                                   transcriptionOptions: [],
                                   reportingOptions: [.volatileResults, .fastResults],
                                   attributeOptions: [])
        transcriber = st
        modules.append(st)
    }
    guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules) else {
        return CaseResult(label: label, results: [], errorText: "no compatible format")
    }
    let analyzer = SpeechAnalyzer(modules: modules)
    let (sequence, builder) = AsyncStream.makeStream(of: AnalyzerInput.self)

    let collector = Task { () -> [(String, Bool)] in
        var seen: [(String, Bool)] = []
        do {
            for try await result in detector.results {
                let r = result.range
                let desc = String(format: "%.2f–%.2f s",
                                  CMTimeGetSeconds(r.start),
                                  CMTimeGetSeconds(CMTimeRangeGetEnd(r)))
                seen.append((desc, result.speechDetected))
            }
        } catch {
            seen.append(("stream error: \(error)", false))
        }
        return seen
    }
    let textTask = Task { () -> String in
        guard let transcriber else { return "" }
        var text = ""
        do {
            for try await result in transcriber.results where result.isFinal {
                text += String(result.text.characters)
            }
        } catch { text += " <error: \(error)>" }
        return text
    }

    do {
        try await analyzer.prepareToAnalyze(in: format)
        try await analyzer.start(inputSequence: sequence)
    } catch {
        collector.cancel(); textTask.cancel(); builder.finish()
        return CaseResult(label: label, results: [], errorText: "start failed: \(error)")
    }

    // Burst-feed in 100 ms chunks, the unpaced eval-harness shape.
    let canonical = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                                  channels: 1, interleaved: true)!
    var i = 0
    while i < samples.count {
        let end = min(i + 1600, samples.count)
        let frames = AVAudioFrameCount(end - i)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: canonical, frameCapacity: frames) else { break }
        buffer.frameLength = frames
        samples.withUnsafeBufferPointer { src in
            buffer.int16ChannelData![0].update(from: src.baseAddress! + i, count: end - i)
        }
        if canonical.commonFormat == format.commonFormat, canonical.sampleRate == format.sampleRate {
            builder.yield(AnalyzerInput(buffer: buffer))
        } else {
            let converter = AVAudioConverter(from: canonical, to: format)!
            let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames * 4)!
            var served = false
            converter.convert(to: out, error: nil) { _, status in
                if served { status.pointee = .noDataNow; return nil }
                served = true; status.pointee = .haveData; return buffer
            }
            builder.yield(AnalyzerInput(buffer: out))
        }
        i = end
    }
    builder.finish()
    do { try await analyzer.finalizeAndFinishThroughEndOfInput() } catch {
        collector.cancel(); textTask.cancel()
        return CaseResult(label: label, results: [], errorText: "finalize failed: \(error)")
    }
    let verdicts = await collector.value
    let transcript = await textTask.value
    return CaseResult(label: label,
                      results: verdicts.map { (range: $0.0, detected: $0.1) },
                      errorText: nil,
                      transcript: withTranscriber ? transcript : nil)
}

@main struct Probe {
    static func main() async throws {
        setvbuf(stdout, nil, _IONBF, 0)
        let speech = try loadPcm("sdp_speech.wav")
        let silence = [Int16](repeating: 0, count: 32_000)          // 2 s digital silence
        let quiet = scale(speech, by: 0.01)                          // engine-audible, meter-silent
        let veryQuiet = scale(speech, by: 0.003)                     // acoustic §2's degradation edge

        let cases: [(String, [Int16])] = [
            ("silence-2s      (meter peak \(String(format: "%.4f", meterPeak(silence))))", silence),
            ("speech-full     (meter peak \(String(format: "%.4f", meterPeak(speech))))", speech),
            ("speech-x0.01    (meter peak \(String(format: "%.4f", meterPeak(quiet))))", quiet),
            ("speech-x0.003   (meter peak \(String(format: "%.4f", meterPeak(veryQuiet))))", veryQuiet),
        ]

        // MEASURED (this machine, macOS 26.5, 2026-08-10): a detector-ONLY
        // analyzer is not a supported topology — SpeechAnalyzer traps with
        //   Speech/SpeechDetector.swift:223: Fatal error: Cannot create
        //   SpeechDetector-only worker; use with a transcriber module
        // (a trap, not a catchable error). Reproduce with `./sdp --detector-only`.
        // The default run therefore probes the supported co-located topology.
        let topologies = CommandLine.arguments.contains("--detector-only") ? [false] : [true]
        for withTranscriber in topologies {
            print("\n=== topology: detector\(withTranscriber ? " + SpeechTranscriber" : " ONLY") ===")
            for sensitivity in SpeechDetector.SensitivityLevel.allCases {
                for (label, samples) in cases {
                    let r = await runCase(label: label, samples: samples,
                                          sensitivity: sensitivity,
                                          withTranscriber: withTranscriber)
                    print("case \(label) [sens \(sensitivity)]")
                    if let e = r.errorText { print("   ERROR: \(e)") }
                    if r.results.isEmpty { print("   results: NONE") }
                    for v in r.results { print("   result: \(v.range)  speechDetected=\(v.detected)") }
                    if let t = r.transcript { print("   transcript: \"\(t)\"") }
                }
            }
        }
    }
}
