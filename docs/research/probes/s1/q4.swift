// S1 follow-ups:
//  A) can one SpeechModule instance be reused across successive SpeechAnalyzers?
//  B) does DictationTranscriber yield real finals WITHOUT .frequentFinalization?
//  C) alternating module configs at <4 s gaps — degradation, and SpeechModels.endRetention() recovery.
import Foundation
import Speech
import AVFoundation

func now() -> Double { Date().timeIntervalSince1970 }
func ms(_ d: Double) -> String { String(format: "%.0f", d * 1000) }

actor Sink {
    var finals: [String] = []; var vol = 0; var err: String?
    func addFinal(_ s: String) { finals.append(s) }
    func addVol() { vol += 1 }
    func setErr(_ e: String) { err = e }
    func take() -> (String, Int, String?) { let s = finals.joined(); finals = []; let v = vol; vol = 0; let e = err; err = nil; return (s, v, e) }
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

func runST(_ bufs: [AVAudioPCMBuffer], _ fmt: AVAudioFormat) async -> (String, Double, String?) {
    let m = SpeechTranscriber(locale: Locale(identifier: "en-US"), transcriptionOptions: [],
                              reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
    let sink = Sink()
    let c = Task { do { for try await r in m.results { if r.isFinal { await sink.addFinal(String(r.text.characters)) } else { await sink.addVol() } } } catch { await sink.setErr("\(error)") } }
    let (seq, b) = AsyncStream.makeStream(of: AnalyzerInput.self)
    let a = SpeechAnalyzer(modules: [m])
    do {
        try await a.prepareToAnalyze(in: fmt)
        try await a.start(inputSequence: seq)
        for x in bufs { b.yield(AnalyzerInput(buffer: x)) }
        let rel = now()
        b.finish()
        try await a.finalizeAndFinishThroughEndOfInput()
        _ = await c.value
        let (t, _, e) = await sink.take()
        return (t.trimmingCharacters(in: .whitespaces), now() - rel, e)
    } catch { c.cancel(); return ("", 0, "\(error)") }
}

func runDual(_ bufs: [AVAudioPCMBuffer], _ fmt: AVAudioFormat) async -> (String, Double, String?) {
    let st = SpeechTranscriber(locale: Locale(identifier: "en-US"), transcriptionOptions: [],
                               reportingOptions: [.volatileResults], attributeOptions: [])
    let dt = DictationTranscriber(locale: Locale(identifier: "en-US"), contentHints: [.shortForm],
                                  transcriptionOptions: [.punctuation],
                                  reportingOptions: [.volatileResults, .frequentFinalization], attributeOptions: [])
    let sink = Sink()
    let c1 = Task { do { for try await r in st.results where r.isFinal { await sink.addFinal(String(r.text.characters)) } } catch { await sink.setErr("\(error)") } }
    let c2 = Task { do { for try await r in dt.results where r.isFinal { _ = r } } catch {} }
    let (seq, b) = AsyncStream.makeStream(of: AnalyzerInput.self)
    let a = SpeechAnalyzer(modules: [st, dt])
    do {
        guard let f2 = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [st, dt]) else { return ("", 0, "nofmt") }
        try await a.prepareToAnalyze(in: f2)
        try await a.start(inputSequence: seq)
        for x in bufs { b.yield(AnalyzerInput(buffer: x)) }
        let rel = now()
        b.finish()
        try await a.finalizeAndFinishThroughEndOfInput()
        _ = await c1.value; c2.cancel()
        let (t, _, e) = await sink.take()
        return (t.trimmingCharacters(in: .whitespaces), now() - rel, e)
    } catch { c1.cancel(); c2.cancel(); return ("", 0, "\(error)") }
}

@main struct M {
    static func main() async {
        setvbuf(stdout, nil, _IONBF, 0)
        let dir = CommandLine.arguments[1]
        let only = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "abc"
        let stProbe = SpeechTranscriber(locale: Locale(identifier: "en-US"), preset: .progressiveTranscription)
        guard let fmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [stProbe]) else { exit(1) }
        let bufs = try! load(URL(fileURLWithPath: "\(dir)/u1.wav"), fmt)

        if only.contains("a") {
        // ---- A) module reuse across analyzers ----
        print("=== A) reuse ONE module across two analyzers ===")
        let m = SpeechTranscriber(locale: Locale(identifier: "en-US"), transcriptionOptions: [],
                                  reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
        let sinkA = Sink()
        let cA = Task { do { for try await r in m.results where r.isFinal { await sinkA.addFinal(String(r.text.characters)) } } catch { await sinkA.setErr("\(error)") } }
        for pass in 1...2 {
            do {
                let (seq, b) = AsyncStream.makeStream(of: AnalyzerInput.self)
                let a = SpeechAnalyzer(modules: [m])
                try await a.prepareToAnalyze(in: fmt)
                try await a.start(inputSequence: seq)
                for x in bufs { b.yield(AnalyzerInput(buffer: x)) }
                b.finish()
                try await a.finalizeAndFinishThroughEndOfInput()
                try? await Task.sleep(nanoseconds: 300_000_000)
                let (t, _, e) = await sinkA.take()
                print("  pass \(pass): OK text=\(t.isEmpty ? "<EMPTY>" : t) err=\(e ?? "-")")
            } catch { print("  pass \(pass): THREW \(error)") }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        cA.cancel()
        }

        if only.contains("b") {
        // ---- B) DT finals without .frequentFinalization ----
        print("=== B) DictationTranscriber reportingOptions vs finals ===")
        for opts: Set<DictationTranscriber.ReportingOption> in [[], [.volatileResults], [.frequentFinalization], [.volatileResults, .frequentFinalization]] {
            let dt = DictationTranscriber(locale: Locale(identifier: "en-US"), contentHints: [.shortForm],
                                          transcriptionOptions: [.punctuation], reportingOptions: opts, attributeOptions: [])
            let sink = Sink()
            let c = Task { do { for try await r in dt.results { if r.isFinal { await sink.addFinal(String(r.text.characters)) } else { await sink.addVol() } } } catch { await sink.setErr("\(error)") } }
            do {
                let (seq, b) = AsyncStream.makeStream(of: AnalyzerInput.self)
                let a = SpeechAnalyzer(modules: [dt])
                guard let f = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [dt]) else { continue }
                try await a.prepareToAnalyze(in: f)
                try await a.start(inputSequence: seq)
                for x in try! load(URL(fileURLWithPath: "\(dir)/u1.wav"), f) { b.yield(AnalyzerInput(buffer: x)) }
                b.finish()
                try await a.finalizeAndFinishThroughEndOfInput()
                _ = await c.value
                let (t, v, e) = await sink.take()
                let names = opts.map { "\($0)" }.sorted().joined(separator: "+")
                print("  opts=[\(names.isEmpty ? "default" : names)] finalText=\(t.isEmpty ? "<NONE>" : t) volatiles=\(v) err=\(e ?? "-")")
            } catch { print("  opts threw \(error)") }
            try? await Task.sleep(nanoseconds: 1_200_000_000)
        }

        }
        if only.contains("c") {
        // ---- C) alternating configs at <4 s gaps, then endRetention() recovery ----
        print("=== C) alternating ST-only / ST+DT configs, 1.0 s gaps ===")
        var degraded = 0
        for i in 1...8 {
            let (t, fin, e) = (i % 2 == 1) ? await runST(bufs, fmt) : await runDual(bufs, fmt)
            let bad = t.isEmpty || e != nil
            if bad { degraded += 1 }
            print("  \(i % 2 == 1 ? "ST  " : "DUAL") \(i): rel->fin=\(ms(fin))ms err=\(e ?? "-") text=\(t.isEmpty ? "<EMPTY>" : t)")
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        print("  degraded runs: \(degraded)/8")
        print("  --- SpeechModels.endRetention() ---")
        let e0 = now(); await SpeechModels.endRetention(); print("  endRetention took \(ms(now() - e0))ms")
        for i in 1...3 {
            let (t, fin, e) = await runST(bufs, fmt)
            print("  ST post-endRetention \(i): rel->fin=\(ms(fin))ms err=\(e ?? "-") text=\(t.isEmpty ? "<EMPTY>" : t)")
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        }
        print("DONE"); exit(0)
    }
}
