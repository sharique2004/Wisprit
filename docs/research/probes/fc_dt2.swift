import Foundation
import Speech
import AVFoundation

let TERMS = ["Sharique", "Wisprit", "InsForge", "Sharique Khatri", "Khatri"]

func dtRun(file: URL, ctxOn: Bool, preset: Bool, opts: Set<DictationTranscriber.ReportingOption>) async -> String {
    do {
        let ctx = AnalysisContext()
        if ctxOn { ctx.contextualStrings = [.general: TERMS] }
        let m: DictationTranscriber = preset
            ? DictationTranscriber(locale: Locale(identifier: "en-US"), preset: .shortDictation)
            : DictationTranscriber(locale: Locale(identifier: "en-US"),
                                   contentHints: [.shortForm],
                                   transcriptionOptions: [.punctuation],
                                   reportingOptions: opts, attributeOptions: [])
        let analyzer = SpeechAnalyzer(modules: [m])
        if ctxOn { try await analyzer.setContext(ctx) }
        let collector = Task { () -> String in
            var s = ""
            do {
                for try await r in m.results {
                    s += "[\(r.isFinal ? "F" : "v")]'\(String(r.text.characters))' "
                }
            } catch { s += "<<STREAM ERROR: \(error)>>" }
            return s
        }
        let af = try AVAudioFile(forReading: file)
        if let last = try await analyzer.analyzeSequence(from: af) {
            try await analyzer.finalizeAndFinish(through: last)
        } else { await analyzer.cancelAndFinishNow() }
        return await collector.value
    } catch { return "<<RUN ERROR: \(error)>>" }
}

@main struct M {
    static func main() async throws {
        setvbuf(stdout, nil, _IONBF, 0)
        let f = URL(fileURLWithPath: CommandLine.arguments[1])
        print("A preset:.shortDictation ctxOFF : \(await dtRun(file: f, ctxOn: false, preset: true, opts: []))")
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        print("B preset:.shortDictation ctxON  : \(await dtRun(file: f, ctxOn: true,  preset: true, opts: []))")
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        print("C manual opts:[] ctxOFF         : \(await dtRun(file: f, ctxOn: false, preset: false, opts: []))")
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        print("D manual opts:[.volatileResults,.frequentFinalization] ctxOFF: \(await dtRun(file: f, ctxOn: false, preset: false, opts: [.volatileResults, .frequentFinalization]))")
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        print("E manual opts:[.volatileResults,.frequentFinalization] ctxON : \(await dtRun(file: f, ctxOn: true,  preset: false, opts: [.volatileResults, .frequentFinalization]))")
        print("DONE"); exit(0)
    }
}
