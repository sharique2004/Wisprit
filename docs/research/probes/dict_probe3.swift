// dict_probe3 — contextualStrings size vs latency; mid-stream setContext.
import Foundation
import Speech
import AVFoundation

@main
struct Main {
    static func main() async {
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        for n in [0, 10, 25, 50, 100, 200, 500] {
            do {
                let loc = Locale(identifier: "en-US")
                let dict = DictationTranscriber(locale: loc, contentHints: [],
                                                transcriptionOptions: [],
                                                reportingOptions: [],
                                                attributeOptions: [])
                let task = Task { () -> String in
                    var fin = ""
                    for try await r in dict.results where r.isFinal {
                        fin += String(r.text.characters) + " "
                    }
                    return fin.trimmingCharacters(in: .whitespaces)
                }
                let a = SpeechAnalyzer(modules: [dict])
                if n > 0 {
                    let c = AnalysisContext()
                    var words = (0..<max(0, n - 3)).map { "Zyxwvu\($0)" }
                    words += ["Sharique", "InsForge", "Wisprit"]
                    c.contextualStrings = [AnalysisContext.ContextualStringsTag("vocabulary"): words]
                    try await a.setContext(c)
                }
                let file = try AVAudioFile(forReading: url)
                let t0 = Date()
                if let last = try await a.analyzeSequence(from: file) {
                    try await a.finalizeAndFinish(through: last)
                } else { try await a.finalizeAndFinishThroughEndOfInput() }
                let text = try await task.value
                print("n=\(n)\tms=\(Int(Date().timeIntervalSince(t0)*1000))\t\(text)")
            } catch { print("n=\(n) error \(error)") }
        }
    }
}
