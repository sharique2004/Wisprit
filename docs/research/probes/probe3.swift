// probe3 — per-utterance contextualStrings tax on a LONG-LIVED analyzer.
// Feeds the same audio N times through one analyzer, timing yield -> final text.
// usage: probe3 <audio.wav> <ctx.json> <reps>
import AVFoundation
import CoreMedia
import Foundation
import Speech

actor Rec {
    var events: [(Double, String)] = []
    func add(_ t: Double, _ s: String) { events.append((t, s)) }
    func all() -> [(Double, String)] { events }
}

@main
struct Probe3 {
    static func main() async {
        let a = Array(CommandLine.arguments.dropFirst())
        guard a.count >= 3, let reps = Int(a[2]) else { exit(2) }
        var strings: [String] = []
        if let d = FileManager.default.contents(atPath: a[1]),
           let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
           let s = o["strings"] as? [String] { strings = s }
        do { try await run(path: a[0], strings: strings, reps: reps) }
        catch { FileHandle.standardError.write(Data("err \(error)\n".utf8)); exit(3) }
    }

    static func run(path: String, strings: [String], reps: Int) async throws {
        let t = DictationTranscriber(locale: Locale(identifier: "en-US"),
                                     contentHints: [],
                                     transcriptionOptions: [.punctuation],
                                     reportingOptions: [],
                                     attributeOptions: [])
        if let r = try await AssetInventory.assetInstallationRequest(supporting: [t]) {
            try await r.downloadAndInstall()
        }
        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
        let ctx = AnalysisContext()
        if !strings.isEmpty { ctx.contextualStrings[.general] = strings }
        let analyzer = SpeechAnalyzer(inputSequence: stream, modules: [t], options: nil,
                                      analysisContext: ctx)

        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        guard let fmt = await t.availableCompatibleAudioFormats.first else { exit(4) }
        let inBuf = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                     frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: inBuf)
        let conv = AVAudioConverter(from: file.processingFormat, to: fmt)!
        let ratio = fmt.sampleRate / file.processingFormat.sampleRate
        let outBuf = AVAudioPCMBuffer(pcmFormat: fmt,
                                      frameCapacity: AVAudioFrameCount(Double(inBuf.frameLength) * ratio + 4096))!
        var fed = false
        var e: NSError?
        conv.convert(to: outBuf, error: &e) { _, st in
            if fed { st.pointee = .endOfStream; return nil }
            fed = true; st.pointee = .haveData; return inBuf
        }
        // silence buffer to force endpointing between repeats
        let sil = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(fmt.sampleRate))!
        sil.frameLength = AVAudioFrameCount(fmt.sampleRate)

        let rec = Rec()
        let start = Date()
        let collector = Task {
            do { for try await r in t.results {
                let s = String(r.text.characters)
                if !s.isEmpty { await rec.add(Date().timeIntervalSince(start) * 1000, s) }
            } } catch {}
        }

        var yields: [Double] = []
        for _ in 0..<reps {
            yields.append(Date().timeIntervalSince(start) * 1000)
            cont.yield(AnalyzerInput(buffer: outBuf))
            cont.yield(AnalyzerInput(buffer: sil))
            try await Task.sleep(nanoseconds: 4_000_000_000)
        }
        cont.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        _ = await collector.value
        let ev = await rec.all()
        var out: [String: Any] = ["n": strings.count,
                                  "yield_ms": yields.map { Int($0) },
                                  "results": ev.map { ["t": Int($0.0), "s": $0.1] }]
        out["lat_ms"] = zip(yields, ev.map { $0.0 }).map { Int($1 - $0) }
        let d = try JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])
        FileHandle.standardOutput.write(d); FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
