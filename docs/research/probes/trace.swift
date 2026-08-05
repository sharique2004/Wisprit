import Foundation
import Speech
import AVFoundation
func now() -> Double { Date().timeIntervalSince1970 }

@main struct M { static func main() async throws {
  let f = URL(fileURLWithPath: CommandLine.arguments[1])
  let mode = CommandLine.arguments[2]           // st | dt
  let opts = Set(CommandLine.arguments.dropFirst(3))
  let terms = ["Sharique","Wisprit","InsForge","Sharique Khatri","Sharique's"]
  let ctx = AnalysisContext()
  if opts.contains("--ctx") { ctx.contextualStrings = [.general: terms] }
  if opts.contains("--ctx100") {
    var big = terms
    for i in 0..<95 { big.append("Filler\(i)term") }
    ctx.contextualStrings = [.general: big]
  }
  var module: any SpeechModule
  if mode == "st" {
    var rep: Set<SpeechTranscriber.ReportingOption> = [.volatileResults]
    if opts.contains("--fast") { rep.insert(.fastResults) }
    module = SpeechTranscriber(locale: Locale(identifier:"en-US"), transcriptionOptions: [], reportingOptions: rep, attributeOptions: [])
  } else {
    var rep: Set<DictationTranscriber.ReportingOption> = [.volatileResults]
    if opts.contains("--fast") { rep.insert(.frequentFinalization) }
    var hints: Set<DictationTranscriber.ContentHint> = opts.contains("--long") ? [] : [.shortForm]
    if opts.contains("--lm") {
      let dir = FileManager.default.temporaryDirectory
      let dataURL = dir.appendingPathComponent("d2.bin"), outURL = dir.appendingPathComponent("m2.bin")
      let data = SFCustomLanguageModelData(locale: Locale(identifier:"en_US"), identifier: "com.wisprit.t2", version: "1")
      for t in terms { data.insert(phraseCount: .init(phrase: t, count: 100)) }
      data.insert(phraseCount: .init(phrase: "Hi Sharique", count: 100))
      data.insert(term: .init(grapheme: "Sharique", phonemes: ["S @ r i k"]))
      try await data.export(to: dataURL)
      try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void,Error>) in
        SFSpeechLanguageModel.prepareCustomLanguageModel(for: dataURL, configuration: .init(languageModel: outURL), ignoresCache: true) { e in e == nil ? c.resume() : c.resume(throwing: e!) } }
      hints.insert(.customizedLanguage(modelConfiguration: .init(languageModel: outURL)))
    }
    module = DictationTranscriber(locale: Locale(identifier:"en-US"), contentHints: hints, transcriptionOptions: [.punctuation], reportingOptions: rep, attributeOptions: [])
  }
  if opts.contains("--purge") { await SpeechModels.endRetention() }
  let (seq, builder) = AsyncStream.makeStream(of: AnalyzerInput.self)
  let analyzer = SpeechAnalyzer(modules: [module])
  try await analyzer.setContext(ctx)
  guard let aFmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else { fatalError() }
  let t0 = now()
  let collector = Task { () -> [String] in
    var log: [String] = []
    if let m = module as? SpeechTranscriber { for try await r in m.results { log.append(String(format:"  %6.0fms final=%@ | %@",(now()-t0)*1000, r.isFinal ? "Y":"n", String(r.text.characters))) } }
    else if let m = module as? DictationTranscriber { for try await r in m.results { log.append(String(format:"  %6.0fms final=%@ | %@",(now()-t0)*1000, r.isFinal ? "Y":"n", String(r.text.characters))) } }
    return log
  }
  try await analyzer.start(inputSequence: seq)
  let af = try AVAudioFile(forReading: f); let fmt = af.processingFormat
  guard let conv = AVAudioConverter(from: fmt, to: aFmt) else { fatalError() }
  let chunk = AVAudioFrameCount(fmt.sampleRate/10); var idx = 0; let feedStart = now()
  while af.framePosition < af.length {
    guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: chunk) else { break }
    try af.read(into: buf, frameCount: chunk); if buf.frameLength == 0 { break }
    guard let out = AVAudioPCMBuffer(pcmFormat: aFmt, frameCapacity: chunk*2) else { break }
    var served = false
    conv.convert(to: out, error: nil) { _, st in if served { st.pointee = .noDataNow; return nil }; served = true; st.pointee = .haveData; return buf }
    builder.yield(AnalyzerInput(buffer: out)); idx += 1
    let d = feedStart + Double(idx)*0.1 - now(); if d > 0 { try? await Task.sleep(nanoseconds: UInt64(d*1e9)) }
  }
  let rel = now(); builder.finish()
  do { try await analyzer.finalizeAndFinishThroughEndOfInput() } catch { FileHandle.standardError.write("FINALIZE ERROR: \(error)\n".data(using:.utf8)!) }
  var log: [String] = []
  do { log = try await collector.value } catch { FileHandle.standardError.write("RESULTS-STREAM ERROR: \(error)\n".data(using:.utf8)!) }
  let firstT = log.first.flatMap { Double($0.trimmingCharacters(in:.whitespaces).components(separatedBy:"ms").first ?? "") }
  let finals = log.filter { $0.contains("final=Y") }
  let text = finals.map { $0.components(separatedBy:"| ").dropFirst().joined(separator:"| ") }.joined()
  print(String(format:"%-26@ audio=%.1fs firstPartial=%@ nFinals=%d RELEASE->FINAL=%.0fms | %@",
    (mode + " " + opts.sorted().joined(separator:" ")) as NSString, (rel-feedStart),
    firstT == nil ? "none" : String(format:"%.0fms",firstT! - (feedStart-t0)*1000), finals.count, (now()-rel)*1000, text))
  if opts.contains("--v") { for l in log { print(l) } }
}}
