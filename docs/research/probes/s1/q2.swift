// S1/Q2 — do .fastResults volatile partials LEAD the audio, on utterances >= 8 s fed real-time?
// For each volatile result we log: wall time since audio start, the result's own range.end
// (how much audio it claims to cover), and lag = wall - (feedStart + range.end).
// argv: <wavfile> <fast:0|1>
import Foundation
import Speech
import AVFoundation

func now() -> Double { Date().timeIntervalSince1970 }

struct Ev { var wall: Double; var end: Double; var isFinal: Bool; var text: String }

actor Sink {
    var evs: [Ev] = []
    func add(_ e: Ev) { evs.append(e) }
    func all() -> [Ev] { evs }
}

@main struct M {
    static func main() async throws {
        setvbuf(stdout, nil, _IONBF, 0)
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let fast = CommandLine.arguments[2] == "1"
        var rep: Set<SpeechTranscriber.ReportingOption> = [.volatileResults]
        if fast { rep.insert(.fastResults) }
        let t = SpeechTranscriber(locale: Locale(identifier: "en-US"),
                                  transcriptionOptions: [], reportingOptions: rep,
                                  attributeOptions: [.audioTimeRange])
        guard let aFmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [t]) else { exit(1) }

        let af = try AVAudioFile(forReading: url)
        let src = af.processingFormat
        let dur = Double(af.length) / src.sampleRate
        let conv = AVAudioConverter(from: src, to: aFmt)!
        let n = AVAudioFrameCount(src.sampleRate / 10)
        var bufs: [AVAudioPCMBuffer] = []
        while af.framePosition < af.length {
            let i = AVAudioPCMBuffer(pcmFormat: src, frameCapacity: n)!
            try af.read(into: i, frameCount: n)
            if i.frameLength == 0 { break }
            let o = AVAudioPCMBuffer(pcmFormat: aFmt, frameCapacity: n * 4)!
            var served = false
            conv.convert(to: o, error: nil) { _, st in
                if served { st.pointee = .noDataNow; return nil }
                served = true; st.pointee = .haveData; return i
            }
            bufs.append(o)
        }

        let sink = Sink()
        let (seq, builder) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let analyzer = SpeechAnalyzer(modules: [t])
        try await analyzer.prepareToAnalyze(in: aFmt)
        let collector = Task {
            for try await r in t.results {
                await sink.add(Ev(wall: now(), end: r.range.end.seconds, isFinal: r.isFinal,
                                  text: String(r.text.characters)))
            }
        }
        try await analyzer.start(inputSequence: seq)
        let feedStart = now()
        for (k, b) in bufs.enumerated() {
            builder.yield(AnalyzerInput(buffer: b))
            let d = feedStart + Double(k + 1) * 0.1 - now()
            if d > 0 { try? await Task.sleep(nanoseconds: UInt64(d * 1e9)) }
        }
        let rel = now()
        builder.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        _ = try? await collector.value
        let relMs = (now() - rel) * 1000

        let evs = await sink.all()
        let vols = evs.filter { !$0.isFinal }
        print("=== \(url.lastPathComponent) fast=\(fast ? "Y" : "N") audio=\(String(format: "%.2f", dur))s " +
              "volatiles=\(vols.count) finals=\(evs.count - vols.count) release->final=\(String(format: "%.0f", relMs))ms")
        var lags: [Double] = []
        for e in evs {
            let t0 = e.wall - feedStart
            let lag = t0 - e.end
            if !e.isFinal && e.end > 0 { lags.append(lag) }
            let tail = e.text.count > 46 ? String(e.text.suffix(46)) : e.text
            print(String(format: "  %@ t=%6.2fs rangeEnd=%6.2fs lag=%+6.2fs | …%@",
                         e.isFinal ? "FIN" : "vol", t0, e.end, lag, tail))
        }
        if !lags.isEmpty {
            let mid = lags.sorted()[lags.count / 2]
            print(String(format: "  LAG min=%.2f median=%.2f max=%.2f (positive = partial trails the speaker)",
                         lags.min()!, mid, lags.max()!))
            let before = vols.filter { $0.wall - feedStart < dur - 0.5 }.count
            print("  volatiles delivered BEFORE end-of-audio: \(before)/\(vols.count)")
        }
        exit(0)
    }
}
