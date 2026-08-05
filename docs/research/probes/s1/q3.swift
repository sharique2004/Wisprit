// S1/Q3 — contextualStrings cost + efficacy on DictationTranscriber at n = 0/50/200/500.
// Two lifetimes: "fresh" = new module + new analyzer per utterance,
//                "resident" = ONE module object reused across per-utterance analyzers.
// Also asserts [.volatileResults, .frequentFinalization] yields real (isFinal) results.
// argv: <dir> <lifetime:fresh|resident> [repeats]
import Foundation
import Speech
import AVFoundation

func now() -> Double { Date().timeIntervalSince1970 }
func ms(_ d: Double) -> String { String(format: "%.0f", d * 1000) }

actor Sink {
    var finals: [String] = []
    var vol = 0
    var err: String?
    func addFinal(_ s: String) { finals.append(s) }
    func addVol() { vol += 1 }
    func setErr(_ e: String) { err = e }
    func take() -> (String, Int, String?) { let s = finals.joined(); finals = []; let v = vol; vol = 0; return (s, v, err) }
}

func load(_ url: URL, _ fmt: AVAudioFormat) throws -> [AVAudioPCMBuffer] {
    let af = try AVAudioFile(forReading: url)
    let src = af.processingFormat
    let conv = AVAudioConverter(from: src, to: fmt)!
    let n = AVAudioFrameCount(src.sampleRate / 10)
    var out: [AVAudioPCMBuffer] = []
    while af.framePosition < af.length {
        let i = AVAudioPCMBuffer(pcmFormat: src, frameCapacity: n)!
        try af.read(into: i, frameCount: n)
        if i.frameLength == 0 { break }
        let o = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n * 4)!
        var served = false
        conv.convert(to: o, error: nil) { _, st in
            if served { st.pointee = .noDataNow; return nil }
            served = true; st.pointee = .haveData; return i
        }
        out.append(o)
    }
    return out
}

func mkDT() -> DictationTranscriber {
    DictationTranscriber(locale: Locale(identifier: "en-US"),
                         contentHints: [.shortForm],
                         transcriptionOptions: [.punctuation],
                         reportingOptions: [.volatileResults, .frequentFinalization],
                         attributeOptions: [])
}

@main struct M {
    static func main() async throws {
        setvbuf(stdout, nil, _IONBF, 0)
        let dir = CommandLine.arguments[1]
        let lifetime = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "fresh"
        let reps = CommandLine.arguments.count > 3 ? Int(CommandLine.arguments[3])! : 3

        let all = try JSONDecoder().decode([String].self,
                    from: Data(contentsOf: URL(fileURLWithPath: "\(dir)/terms.json")))
        let probe = mkDT()
        guard let aFmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [probe]) else { exit(1) }
        let bufs = try load(URL(fileURLWithPath: "\(dir)/u1.wav"), aFmt)
        let audioSec = Double(bufs.count) * 0.1
        print("lifetime=\(lifetime) audio=\(String(format: "%.1f", audioSec))s terms available=\(all.count) fmt=\(Int(aFmt.sampleRate))Hz")

        // one module object shared across analyzers in "resident" mode
        var shared: DictationTranscriber? = (lifetime == "resident") ? mkDT() : nil
        var sharedCollector: Task<Void, Never>?
        let sharedSink = Sink()
        if let s = shared {
            sharedCollector = Task {
                do { for try await r in s.results {
                    if r.isFinal { await sharedSink.addFinal(String(r.text.characters)) } else { await sharedSink.addVol() }
                } } catch { await sharedSink.setErr("\(error)") }
            }
        }

        for n in [0, 50, 200, 500] {
            var setups: [Double] = [], fins: [Double] = [], totals: [Double] = []
            var lastText = "", lastVol = 0, lastFinals = 0
            for _ in 0..<reps {
                let sink: Sink
                let dt: DictationTranscriber
                var collector: Task<Void, Never>?
                if let s = shared { dt = s; sink = sharedSink } else {
                    dt = mkDT(); sink = Sink()
                    collector = Task {
                        do { for try await r in dt.results {
                            if r.isFinal { await sink.addFinal(String(r.text.characters)) } else { await sink.addVol() }
                        } } catch { await sink.setErr("\(error)") }
                    }
                }
                let ctx = AnalysisContext()
                if n > 0 { ctx.contextualStrings = [.general: Array(all.prefix(n))] }

                let t0 = now()
                let (seq, builder) = AsyncStream.makeStream(of: AnalyzerInput.self)
                let a = SpeechAnalyzer(modules: [dt])
                try await a.setContext(ctx)
                try await a.prepareToAnalyze(in: aFmt)
                try await a.start(inputSequence: seq)
                let setup = now() - t0
                // off-paste-path: feed as fast as the analyzer will take it
                for b in bufs { builder.yield(AnalyzerInput(buffer: b)) }
                let rel = now()
                builder.finish()
                try await a.finalizeAndFinishThroughEndOfInput()
                if let c = collector { _ = await c.value }
                let fin = now() - rel
                let (txt, vol, err) = await sink.take()
                if err != nil { print("  ERR n=\(n): \(err!)") }
                setups.append(setup); fins.append(fin); totals.append(now() - t0)
                lastText = txt.trimmingCharacters(in: .whitespaces); lastVol = vol
                lastFinals = txt.isEmpty ? 0 : 1
                try? await Task.sleep(nanoseconds: 1_200_000_000)
            }
            func med(_ x: [Double]) -> Double { x.sorted()[x.count / 2] }
            print("n=\(String(format: "%3d", n)) setup(med)=\(ms(med(setups)))ms " +
                  "release->final(med)=\(ms(med(fins)))ms total(med)=\(ms(med(totals)))ms " +
                  "vol=\(lastVol) finals=\(lastFinals)")
            print("      text: \(lastText)")
        }
        if let s = shared { _ = s; sharedCollector?.cancel() }
        shared = nil
        print("DONE"); exit(0)
    }
}
