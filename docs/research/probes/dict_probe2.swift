// dict_probe2 — DictationTranscriber volatile results, dual-module analyzer,
// and contextualStrings scale test.
import Foundation
import Speech
import AVFoundation

@main
struct Main {
    static func main() async {
        let args = CommandLine.arguments
        let url = URL(fileURLWithPath: args[1])
        let mode = args.count > 2 ? args[2] : "volatile"   // volatile | dual | big
        var ctx: [String] = ["Sharique", "InsForge", "Wisprit"]
        if mode == "big" {
            // 500 filler terms + the real ones, to probe a size ceiling.
            ctx = (0..<500).map { "Zyxwvu\($0)" } + ctx
        }
        do {
            let loc = Locale(identifier: "en-US")
            let dict = DictationTranscriber(locale: loc, contentHints: [],
                                            transcriptionOptions: [],
                                            reportingOptions: [.volatileResults],
                                            attributeOptions: [])
            let speech = SpeechTranscriber(locale: loc, transcriptionOptions: [],
                                           reportingOptions: [.volatileResults],
                                           attributeOptions: [])
            let modules: [any SpeechModule] = (mode == "dual") ? [dict, speech] : [dict]

            let dTask = Task { () -> (String, Int, String) in
                var fin = "", vol = "", n = 0
                for try await r in dict.results {
                    if r.isFinal { fin += String(r.text.characters) + " "; }
                    else { vol = String(r.text.characters); n += 1 }
                }
                return (fin.trimmingCharacters(in: .whitespaces), n, vol)
            }
            let sTask = Task { () -> String in
                guard mode == "dual" else { return "" }
                var fin = ""
                for try await r in speech.results where r.isFinal {
                    fin += String(r.text.characters) + " "
                }
                return fin.trimmingCharacters(in: .whitespaces)
            }

            if let req = try await AssetInventory.assetInstallationRequest(supporting: modules) {
                try await req.downloadAndInstall()
            }
            let analyzer = SpeechAnalyzer(modules: modules)
            let c = AnalysisContext()
            c.contextualStrings = [AnalysisContext.ContextualStringsTag("vocabulary"): ctx]
            try await analyzer.setContext(c)

            let file = try AVAudioFile(forReading: url)
            let t0 = Date()
            if let last = try await analyzer.analyzeSequence(from: file) {
                try await analyzer.finalizeAndFinish(through: last)
            } else { try await analyzer.finalizeAndFinishThroughEndOfInput() }
            let (dfin, nvol, lastvol) = try await dTask.value
            let sfin = try await sTask.value
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            let obj: [String: Any] = ["mode": mode, "ctxCount": ctx.count,
                                      "dictation": dfin, "dictVolatileCount": nvol,
                                      "dictLastVolatile": lastvol,
                                      "speech": sfin, "ms": ms]
            print(String(data: try JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!)
        } catch { print("{\"mode\":\"\(mode)\",\"error\":\"\(error)\"}"); exit(2) }
    }
}
