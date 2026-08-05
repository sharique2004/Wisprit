// clm_probe — can we build an SFCustomLanguageModelData on macOS 26 and feed it
// to DictationTranscriber via .customizedLanguage?  Also dumps supportedPhonemes.
import Foundation
import Speech
import AVFoundation

@main
struct Main {
    static func main() async {
        let loc = Locale(identifier: "en-US")
        do {
            let ph = await SFCustomLanguageModelData.supportedPhonemes(locale: loc)
            FileHandle.standardError.write("supportedPhonemes(en-US) count=\(ph.count)\n".data(using: .utf8)!)
            FileHandle.standardError.write("\(ph.sorted().joined(separator: " "))\n".data(using: .utf8)!)
        } catch {
            FileHandle.standardError.write("supportedPhonemes error: \(error)\n".data(using: .utf8)!)
        }

        let tmp = FileManager.default.temporaryDirectory
        let binURL = tmp.appendingPathComponent("wisprit_clm.bin")
        let prepURL = tmp.appendingPathComponent("wisprit_clm_prepared")

        do {
            let data = SFCustomLanguageModelData(locale: loc,
                                                 identifier: "com.wisprit.test",
                                                 version: "1") {
                SFCustomLanguageModelData.PhraseCount(phrase: "please ping Sharique", count: 10)
                SFCustomLanguageModelData.PhraseCount(phrase: "email Sharique about InsForge", count: 10)
                SFCustomLanguageModelData.PhraseCount(phrase: "Sharique", count: 10)
                SFCustomLanguageModelData.CustomPronunciation(grapheme: "Sharique",
                                                              phonemes: ["S @ \"r i k"])
            }
            try await data.export(to: binURL)
            FileHandle.standardError.write("exported LM to \(binURL.path)\n".data(using: .utf8)!)

            let cfg = SFSpeechLanguageModel.Configuration(languageModel: binURL)
            try await SFSpeechLanguageModel.prepareCustomLanguageModel(for: binURL,
                                                                       configuration: cfg)
            FileHandle.standardError.write("prepared OK\n".data(using: .utf8)!)

            let url = URL(fileURLWithPath: CommandLine.arguments[1])
            let dict = DictationTranscriber(locale: loc,
                                            contentHints: [.customizedLanguage(modelConfiguration: cfg)],
                                            transcriptionOptions: [],
                                            reportingOptions: [],
                                            attributeOptions: [])
            let task = Task { () -> String in
                var fin = ""
                for try await r in dict.results where r.isFinal { fin += String(r.text.characters) + " " }
                return fin.trimmingCharacters(in: .whitespaces)
            }
            let a = SpeechAnalyzer(modules: [dict])
            let file = try AVAudioFile(forReading: url)
            let t0 = Date()
            if let last = try await a.analyzeSequence(from: file) {
                try await a.finalizeAndFinish(through: last)
            } else { try await a.finalizeAndFinishThroughEndOfInput() }
            let text = try await task.value
            print("customLM: ms=\(Int(Date().timeIntervalSince(t0)*1000))  text=\(text)")
        } catch {
            print("customLM ERROR: \(error)")
        }
        _ = prepURL
    }
}
