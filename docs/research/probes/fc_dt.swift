// DT diagnostic + biasing A/B, collecting ALL results (not just isFinal)
import Foundation
import Speech
import AVFoundation

let TERMS = ["Sharique", "Wisprit", "InsForge", "Sharique Khatri", "Khatri"]

func dtRun(file: URL, ctxOn: Bool) async throws -> (String, Int, Int) {
    let ctx = AnalysisContext()
    if ctxOn { ctx.contextualStrings = [.general: TERMS] }
    let m = DictationTranscriber(locale: Locale(identifier: "en-US"),
                                 contentHints: [.shortForm],
                                 transcriptionOptions: [.punctuation],
                                 reportingOptions: [], attributeOptions: [])
    let analyzer = SpeechAnalyzer(modules: [m])
    if ctxOn { try await analyzer.setContext(ctx) }
    var all = ""
    var nAll = 0, nFinal = 0
    let collector = Task {
        for try await r in m.results {
            nAll += 1
            if r.isFinal { nFinal += 1; all += String(r.text.characters) }
        }
    }
    let af = try AVAudioFile(forReading: file)
    if let last = try await analyzer.analyzeSequence(from: af) {
        try await analyzer.finalizeAndFinish(through: last)
    } else { await analyzer.cancelAndFinishNow() }
    try await collector.value
    return (all.trimmingCharacters(in: .whitespaces), nAll, nFinal)
}

@main struct M {
    static func main() async throws {
        setvbuf(stdout, nil, _IONBF, 0)
        print("DT isAvailable-ish check:")
        let sup = await DictationTranscriber.supportedLocales
        let inst = await DictationTranscriber.installedLocales
        print("  DT supportedLocales=\(sup.count) installedLocales=\(inst.map{$0.identifier})")
        print("  ST isAvailable=\(SpeechTranscriber.isAvailable)")
        let stInst = await SpeechTranscriber.installedLocales
        print("  ST installedLocales=\(stInst.map{$0.identifier})")
        let dir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
        for i in 1...6 {
            let f = URL(fileURLWithPath: "\(dir)/c\(i).wav")
            let (off, na1, nf1) = try await dtRun(file: f, ctxOn: false)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            let (on, na2, nf2) = try await dtRun(file: f, ctxOn: true)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            print("c\(i): changed=\(off != on ? "YES" : "no")")
            print("   DT ctxOFF (n=\(na1)/f=\(nf1)): \(off)")
            print("   DT ctxON  (n=\(na2)/f=\(nf2)): \(on)")
        }
        print("DONE"); exit(0)
    }
}
