// dict_probe — does DictationTranscriber + AnalysisContext.contextualStrings
// actually bias recognition toward a custom name?  Reads a 16 kHz mono WAV file
// path + optional context words from argv.
//
// usage: dict_probe <wav> [--context word1,word2] [--speech]
import Foundation
import Speech
import AVFoundation

@main
struct Main {
    static func main() async {
        let args = CommandLine.arguments
        guard args.count > 1 else { print("usage: dict_probe <wav> [--context a,b] [--speech]"); exit(1) }
        let url = URL(fileURLWithPath: args[1])
        var ctxWords: [String] = []
        var useSpeechTranscriber = false
        var i = 2
        while i < args.count {
            if args[i] == "--context", i + 1 < args.count {
                ctxWords = args[i+1].components(separatedBy: ",")
                i += 2
            } else if args[i] == "--speech" { useSpeechTranscriber = true; i += 1 }
            else { i += 1 }
        }

        do {
            let locale = Locale(identifier: "en-US")
            var module: any SpeechModule
            var resultsTask: Task<String, Error>

            if useSpeechTranscriber {
                let t = SpeechTranscriber(locale: locale,
                                          transcriptionOptions: [],
                                          reportingOptions: [],
                                          attributeOptions: [])
                module = t
                resultsTask = Task {
                    var out = ""
                    for try await r in t.results where r.isFinal {
                        out += String(r.text.characters) + " "
                    }
                    return out
                }
            } else {
                let t = DictationTranscriber(locale: locale,
                                             contentHints: [],
                                             transcriptionOptions: [],
                                             reportingOptions: [],
                                             attributeOptions: [])
                module = t
                resultsTask = Task {
                    var out = ""
                    for try await r in t.results where r.isFinal {
                        out += String(r.text.characters) + " "
                    }
                    return out
                }
            }

            // Ensure the locale asset is installed.
            let installed = useSpeechTranscriber
                ? await SpeechTranscriber.installedLocales
                : await DictationTranscriber.installedLocales
            FileHandle.standardError.write("installed: \(installed.map{$0.identifier})\n".data(using:.utf8)!)
            if let req = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                FileHandle.standardError.write("downloading assets…\n".data(using:.utf8)!)
                try await req.downloadAndInstall()
            }

            let analyzer = SpeechAnalyzer(modules: [module])
            if !ctxWords.isEmpty {
                let ctx = AnalysisContext()
                ctx.contextualStrings = [
                    AnalysisContext.ContextualStringsTag("vocabulary"): ctxWords
                ]
                try await analyzer.setContext(ctx)
                FileHandle.standardError.write("context set: \(ctxWords)\n".data(using:.utf8)!)
            }

            let file = try AVAudioFile(forReading: url)
            let t0 = Date()
            if let last = try await analyzer.analyzeSequence(from: file) {
                try await analyzer.finalizeAndFinish(through: last)
            } else {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            }
            let text = try await resultsTask.value
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            let obj: [String: Any] = [
                "module": useSpeechTranscriber ? "SpeechTranscriber" : "DictationTranscriber",
                "context": ctxWords, "text": text.trimmingCharacters(in: .whitespaces), "ms": ms]
            print(String(data: try JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!)
        } catch {
            print("{\"error\":\"\(error)\"}")
            exit(2)
        }
    }
}
