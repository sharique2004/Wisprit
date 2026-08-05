// probe2 — is the contextualStrings cost paid once (at setContext) or per utterance?
// usage: probe2 <audio.wav> <ctx.json> <repeats>
import AVFoundation
import CoreMedia
import Foundation
import Speech

@main
struct Probe2 {
    static func main() async {
        let a = Array(CommandLine.arguments.dropFirst())
        guard a.count >= 3, let reps = Int(a[2]) else {
            FileHandle.standardError.write(Data("usage: probe2 <audio> <ctx.json> <reps>\n".utf8)); exit(2)
        }
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
                                     reportingOptions: [.volatileResults],
                                     attributeOptions: [])
        if let r = try await AssetInventory.assetInstallationRequest(supporting: [t]) {
            try await r.downloadAndInstall()
        }
        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(inputSequence: stream, modules: [t])

        // read + convert file once
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        guard let fmt = await t.availableCompatibleAudioFormats.first else { fatalError("no fmt") }
        let inBuf = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                     frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: inBuf)
        let conv = AVAudioConverter(from: file.processingFormat, to: fmt)!
        let ratio = fmt.sampleRate / file.processingFormat.sampleRate
        let outBuf = AVAudioPCMBuffer(pcmFormat: fmt,
                                      frameCapacity: AVAudioFrameCount(Double(inBuf.frameLength) * ratio + 4096))!
        var done = false
        var err: NSError?
        conv.convert(to: outBuf, error: &err) { _, st in
            if done { st.pointee = .endOfStream; return nil }
            done = true; st.pointee = .haveData; return inBuf
        }

        var results: [String] = []
        let collector = Task {
            var texts: [String] = []
            do { for try await r in t.results where !r.text.characters.isEmpty {
                texts.append(String(r.text.characters)) } } catch {}
            return texts
        }

        // 1) time setContext with the full string list
        let ctx = AnalysisContext()
        if !strings.isEmpty { ctx.contextualStrings[.general] = strings }
        let c0 = Date()
        try await analyzer.setContext(ctx)
        let setMs = Date().timeIntervalSince(c0) * 1000

        // 2) time each utterance through the SAME analyzer
        var utt: [Int] = []
        for _ in 0..<reps {
            let u0 = Date()
            cont.yield(AnalyzerInput(buffer: outBuf))
            try await Task.sleep(nanoseconds: 50_000_000)
            utt.append(Int(Date().timeIntervalSince(u0) * 1000))
        }
        cont.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        results = await collector.value

        let out: [String: Any] = ["n": strings.count,
                                  "setContext_ms": Int(setMs),
                                  "utterance_ms": utt,
                                  "last": results.last ?? ""]
        let d = try JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])
        FileHandle.standardOutput.write(d); FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
