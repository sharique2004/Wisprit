// S1/Q1 — resident SpeechAnalyzer + per-utterance finalize, >=12 back-to-back utterances, <4s gaps.
// argv: <dir> <mode:nil|cmtime|persession> [n]
import Foundation
import Speech
import AVFoundation

func now() -> Double { Date().timeIntervalSince1970 }
func ms(_ d: Double) -> String { String(format: "%.0f", d * 1000) }

actor Sink {
    var finals: [String] = []
    var sawFinal = false
    var volatiles = 0
    var firstVolatile: Double?
    var err: String?
    func addFinal(_ s: String) { finals.append(s); sawFinal = true }
    func addVolatile() { volatiles += 1; if firstVolatile == nil { firstVolatile = now() } }
    func setErr(_ e: String) { err = e }
    func mark() { sawFinal = false; volatiles = 0; firstVolatile = nil }
    func hasFinal() -> Bool { sawFinal }
    func take() -> (String, Int, Double?, String?) {
        let s = finals.joined(); finals = []
        return (s, volatiles, firstVolatile, err)
    }
}

func chunks(_ url: URL, _ fmt: AVAudioFormat) throws -> [AVAudioPCMBuffer] {
    let af = try AVAudioFile(forReading: url)
    let src = af.processingFormat
    let conv = AVAudioConverter(from: src, to: fmt)!
    let n = AVAudioFrameCount(src.sampleRate / 10)
    var out: [AVAudioPCMBuffer] = []
    while af.framePosition < af.length {
        let inBuf = AVAudioPCMBuffer(pcmFormat: src, frameCapacity: n)!
        try af.read(into: inBuf, frameCount: n)
        if inBuf.frameLength == 0 { break }
        let o = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n * 4)!
        var served = false
        conv.convert(to: o, error: nil) { _, st in
            if served { st.pointee = .noDataNow; return nil }
            served = true; st.pointee = .haveData; return inBuf
        }
        out.append(o)
    }
    return out
}

@main struct M {
    static func main() async throws {
        setvbuf(stdout, nil, _IONBF, 0)
        let dir = CommandLine.arguments[1]
        let mode = CommandLine.arguments[2]
        let n = CommandLine.arguments.count > 3 ? Int(CommandLine.arguments[3])! : 14
        let names = ["u1.wav", "u2.wav", "u3.wav"]

        let t = SpeechTranscriber(locale: Locale(identifier: "en-US"),
                                  transcriptionOptions: [],
                                  reportingOptions: [.volatileResults, .fastResults],
                                  attributeOptions: [])
        guard let aFmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [t]) else {
            print("no format"); exit(1)
        }
        print("format: \(aFmt.channelCount)ch \(Int(aFmt.sampleRate))Hz \(aFmt.commonFormat.rawValue)")
        var cache: [String: [AVAudioPCMBuffer]] = [:]
        for nm in names { cache[nm] = try chunks(URL(fileURLWithPath: "\(dir)/\(nm)"), aFmt) }

        if mode == "persession" {
            for i in 0..<n {
                let nm = names[i % names.count]
                let sink = Sink()
                let m = SpeechTranscriber(locale: Locale(identifier: "en-US"),
                                          transcriptionOptions: [],
                                          reportingOptions: [.volatileResults, .fastResults],
                                          attributeOptions: [])
                let (seq, builder) = AsyncStream.makeStream(of: AnalyzerInput.self)
                let a = SpeechAnalyzer(modules: [m])
                let collector = Task {
                    do { for try await r in m.results {
                        if r.isFinal { await sink.addFinal(String(r.text.characters)) } else { await sink.addVolatile() }
                    } } catch { await sink.setErr("\(error)") }
                }
                let p0 = now()
                try await a.prepareToAnalyze(in: aFmt)
                let prep = now() - p0
                try await a.start(inputSequence: seq)
                let s = now()
                for (k, b) in cache[nm]!.enumerated() {
                    builder.yield(AnalyzerInput(buffer: b))
                    let d = s + Double(k + 1) * 0.1 - now()
                    if d > 0 { try? await Task.sleep(nanoseconds: UInt64(d * 1e9)) }
                }
                let rel = now()
                builder.finish()
                try await a.finalizeAndFinishThroughEndOfInput()
                _ = try? await collector.value
                let fin = now() - rel
                let (txt, vol, _, err) = await sink.take()
                print("utt \(i+1) [\(nm)] prepare=\(ms(prep))ms release->final=\(ms(fin))ms vol=\(vol) err=\(err ?? "-") | \(txt)")
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
            print("DONE"); exit(0)
        }

        // resident analyzer, stream stays open across all utterances
        let sink = Sink()
        let (seq, builder) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let analyzer = SpeechAnalyzer(modules: [t])
        let p0 = now()
        try await analyzer.prepareToAnalyze(in: aFmt)
        print("prepareToAnalyze: \(ms(now() - p0))ms")
        let collector = Task {
            do { for try await r in t.results {
                if r.isFinal { await sink.addFinal(String(r.text.characters)) } else { await sink.addVolatile() }
            } } catch { await sink.setErr("\(error)") }
        }
        try await analyzer.start(inputSequence: seq)

        var cursor = CMTime.zero
        var ok = 0, hangs = 0, empties = 0
        for i in 0..<n {
            let nm = names[i % names.count]
            await sink.mark()
            let s = now()
            for (k, b) in cache[nm]!.enumerated() {
                builder.yield(AnalyzerInput(buffer: b))
                cursor = CMTimeAdd(cursor, CMTime(seconds: Double(b.frameLength) / aFmt.sampleRate,
                                                  preferredTimescale: 16000))
                let d = s + Double(k + 1) * 0.1 - now()
                if d > 0 { try? await Task.sleep(nanoseconds: UInt64(d * 1e9)) }
            }
            let rel = now()
            let target: CMTime? = (mode == "cmtime") ? cursor : nil
            var hung = false
            let fin = Task { try await analyzer.finalize(through: target) }
            await withTaskGroup(of: String.self) { g in
                g.addTask { (try? await fin.value) != nil ? "done" : "throw" }
                g.addTask { try? await Task.sleep(nanoseconds: 8_000_000_000); return "timeout" }
                if let first = await g.next() { if first == "timeout" { hung = true }; g.cancelAll() }
            }
            var waited = 0.0
            while await !sink.hasFinal() && waited < 2.0 {
                try? await Task.sleep(nanoseconds: 2_000_000); waited += 0.002
            }
            let dt = now() - rel
            let (txt, vol, _, err) = await sink.take()
            if hung { hangs += 1 } else if txt.trimmingCharacters(in: .whitespaces).isEmpty { empties += 1 } else { ok += 1 }
            print("utt \(i+1) [\(nm)] release->final=\(ms(dt))ms\(hung ? " *** HUNG(8s) ***" : "") vol=\(vol) err=\(err ?? "-") | \(txt)")
            if hung { break }
            try? await Task.sleep(nanoseconds: 1_500_000_000)   // <4s gap
        }
        print("SUMMARY mode=\(mode) ok=\(ok) empty=\(empties) hung=\(hangs) of \(n)")
        builder.finish()
        await analyzer.cancelAndFinishNow()
        collector.cancel()
        print("DONE"); exit(0)
    }
}
