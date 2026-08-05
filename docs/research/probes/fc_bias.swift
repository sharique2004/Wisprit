// Independent adversarial probe: does SpeechTranscriber really ignore contextualStrings?
// Controls: (a) read back analyzer.context to prove the strings were actually set
//           (b) try BOTH setContext(...) and the init(analysisContext:) path
import Foundation
import Speech
import AVFoundation

let TERMS = ["Sharique", "Wisprit", "InsForge", "Sharique Khatri", "Khatri"]

enum Engine { case st, dt }
enum CtxPath { case none, viaSetContext, viaInit }

func transcribe(file: URL, engine: Engine, path: CtxPath) async throws -> (String, Int) {
    let ctx = AnalysisContext()
    if path != .none { ctx.contextualStrings = [.general: TERMS] }

    let module: any SpeechModule
    switch engine {
    case .st:
        module = SpeechTranscriber(locale: Locale(identifier: "en-US"), preset: .transcription)
    case .dt:
        module = DictationTranscriber(locale: Locale(identifier: "en-US"),
                                      contentHints: [.shortForm],
                                      transcriptionOptions: [.punctuation],
                                      reportingOptions: [], attributeOptions: [])
    }

    let af = try AVAudioFile(forReading: file)
    let analyzer: SpeechAnalyzer
    if path == .viaInit {
        // context supplied at construction time, via the file-input initializer
        analyzer = try await SpeechAnalyzer(inputAudioFile: af, modules: [module],
                                           analysisContext: ctx, finishAfterFile: true)
    } else {
        analyzer = SpeechAnalyzer(modules: [module])
        if path == .viaSetContext { try await analyzer.setContext(ctx) }
    }

    // CONTROL: read the context back off the analyzer
    let readBack = await analyzer.context.contextualStrings[.general]?.count ?? 0

    var out = ""
    let collector = Task {
        switch engine {
        case .st:
            if let m = module as? SpeechTranscriber {
                for try await r in m.results where r.isFinal { out += String(r.text.characters) }
            }
        case .dt:
            if let m = module as? DictationTranscriber {
                for try await r in m.results where r.isFinal { out += String(r.text.characters) }
            }
        }
    }
    if path == .viaInit {
        // init(inputAudioFile:) already attaches the file; just drain to the end
        try await analyzer.finalizeAndFinishThroughEndOfInput()
    } else if let last = try await analyzer.analyzeSequence(from: af) {
        try await analyzer.finalizeAndFinish(through: last)
    } else {
        await analyzer.cancelAndFinishNow()
    }
    try await collector.value
    return (out.trimmingCharacters(in: .whitespaces), readBack)
}

@main struct M {
    static func main() async throws {
        setvbuf(stdout, nil, _IONBF, 0)
        let dir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
        let files = (1...6).map { URL(fileURLWithPath: "\(dir)/c\($0).wav") }

        for (i, f) in files.enumerated() {
            print("=== c\(i+1).wav ===")
            for engine in [Engine.st, Engine.dt] {
                let name = engine == .st ? "ST" : "DT"
                var results: [CtxPath: String] = [:]
                for path in [CtxPath.none, .viaSetContext, .viaInit] {
                    let (txt, rb) = try await transcribe(file: f, engine: engine, path: path)
                    results[path] = txt
                    let label: String
                    switch path {
                    case .none: label = "ctx=OFF        "
                    case .viaSetContext: label = "ctx=setContext "
                    case .viaInit: label = "ctx=init       "
                    }
                    print("  \(name) \(label) [ctxReadBack=\(rb)] \(txt)")
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                }
                let off = results[.none] ?? ""
                let sc = results[.viaSetContext] ?? ""
                let vi = results[.viaInit] ?? ""
                print("  \(name) -> setContext changed output? \(sc != off ? "YES" : "no") | init changed output? \(vi != off ? "YES" : "no")")
            }
            print("")
        }
        print("DONE"); exit(0)
    }
}
