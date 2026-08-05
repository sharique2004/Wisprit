import Foundation
import Speech
import AVFoundation

func run(file: URL, mode: String, ctx: [String], lmURL: URL?) async throws -> String {
  let context = AnalysisContext()
  if !ctx.isEmpty { context.contextualStrings = [.general: ctx] }
  var module: any SpeechModule
  if mode == "st" {
    module = SpeechTranscriber(locale: Locale(identifier:"en-US"), preset: .transcription)
  } else {
    var hints: Set<DictationTranscriber.ContentHint> = [.shortForm]
    if let lmURL { hints.insert(.customizedLanguage(modelConfiguration: SFSpeechLanguageModel.Configuration(languageModel: lmURL))) }
    module = DictationTranscriber(locale: Locale(identifier:"en-US"),
      contentHints: hints, transcriptionOptions: [.punctuation], reportingOptions: [], attributeOptions: [])
  }
  let analyzer = SpeechAnalyzer(modules: [module])
  try await analyzer.setContext(context)
  var out = ""
  let collector = Task {
    if let m = module as? SpeechTranscriber { for try await r in m.results { out += String(r.text.characters) } }
    else if let m = module as? DictationTranscriber { for try await r in m.results { out += String(r.text.characters) } }
  }
  let af = try AVAudioFile(forReading: file)
  let last = try await analyzer.analyzeSequence(from: af)
  if let last { try await analyzer.finalizeAndFinish(through: last) } else { await analyzer.cancelAndFinishNow() }
  try await collector.value
  return out
}

@main struct M {
  static func main() async throws {
    let f = URL(fileURLWithPath: CommandLine.arguments[1])
    let terms = ["Sharique","Wisprit","InsForge","Sharique Khatri"]
    var lm: URL? = nil
    if CommandLine.arguments.contains("--lm") {
      let dir = FileManager.default.temporaryDirectory
      let dataURL = dir.appendingPathComponent("lmdata.bin")
      let outURL = dir.appendingPathComponent("lm.bin")
      let data = SFCustomLanguageModelData(locale: Locale(identifier:"en_US"), identifier: "com.wisprit.test", version: "1")
      for t in terms { for _ in 0..<5 { data.insert(phraseCount: .init(phrase: t, count: 20)) } }
      data.insert(phraseCount: .init(phrase: "Hi Sharique", count: 50))
      data.insert(phraseCount: .init(phrase: "add this to Wisprit and InsForge", count: 50))
      data.insert(term: .init(grapheme: "Sharique", phonemes: ["S @ r i k"]))
      data.insert(term: .init(grapheme: "Wisprit", phonemes: ["w I s p r I t"]))
      let t0 = Date()
      try await data.export(to: dataURL)
      let exportT = Date().timeIntervalSince(t0)
      let t1 = Date()
      try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void,Error>) in
        SFSpeechLanguageModel.prepareCustomLanguageModel(for: dataURL, clientIdentifier: "com.wisprit.test",
          configuration: SFSpeechLanguageModel.Configuration(languageModel: outURL), ignoresCache: true) { err in
          if let err { c.resume(throwing: err) } else { c.resume() } }
      }
      let prepT = Date().timeIntervalSince(t1)
      let sz = (try? FileManager.default.attributesOfItem(atPath: outURL.path)[.size] as? Int) ?? 0
      FileHandle.standardError.write("LM export \(String(format:"%.2f",exportT))s prepare \(String(format:"%.2f",prepT))s size \(sz ?? 0)B at \(outURL.path)\n".data(using:.utf8)!)
      lm = outURL
    }
    for mode in ["st","dt"] {
      for withCtx in [false,true] {
        let t0 = Date()
        let r = try await run(file: f, mode: mode, ctx: withCtx ? terms : [], lmURL: nil)
        print("\(mode) ctx=\(withCtx) [\(String(format:"%.2f",Date().timeIntervalSince(t0)))s]: \(r)")
      }
    }
    if let lm {
      let r = try await run(file: f, mode: "dt", ctx: [], lmURL: lm)
      print("dt customLM (no ctx): \(r)")
      let r2 = try await run(file: f, mode: "dt", ctx: terms, lmURL: lm)
      print("dt customLM + ctx: \(r2)")
    }
  }
}
