import Foundation
import Speech
import AVFoundation

func now() -> Double { Date().timeIntervalSince1970 }

func stream(file: URL, mode: String, fast: Bool, prewarm: Bool) async throws {
  let start = now()
  var module: any SpeechModule
  if mode == "st" {
    var rep: Set<SpeechTranscriber.ReportingOption> = [.volatileResults]
    if fast { rep.insert(.fastResults) }
    module = SpeechTranscriber(locale: Locale(identifier:"en-US"), transcriptionOptions: [], reportingOptions: rep, attributeOptions: [])
  } else {
    var rep: Set<DictationTranscriber.ReportingOption> = [.volatileResults]
    if fast { rep.insert(.frequentFinalization) }
    module = DictationTranscriber(locale: Locale(identifier:"en-US"), contentHints: [.shortForm], transcriptionOptions: [.punctuation], reportingOptions: rep, attributeOptions: [])
  }
  let (seq, builder) = AsyncStream.makeStream(of: AnalyzerInput.self)
  let analyzer = SpeechAnalyzer(modules: [module])
  guard let aFmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else { fatalError("no fmt") }
  if prewarm { try await analyzer.prepareToAnalyze(in: nil) }
  let prep = now()
  let collector = Task { () -> (Double?, String) in
    var fv: Double? = nil
    var txt = ""
    if let m = module as? SpeechTranscriber { for try await r in m.results { if fv == nil { fv = now() }; if r.isFinal { txt += String(r.text.characters) } } }
    else if let m = module as? DictationTranscriber { for try await r in m.results { if fv == nil { fv = now() }; if r.isFinal { txt += String(r.text.characters) } } }
    return (fv, txt)
  }
  do { try await analyzer.start(inputSequence: seq) } catch { FileHandle.standardError.write("START ERR \(error)\n".data(using:.utf8)!); throw error }
  // feed real-time paced 100ms chunks
  let af = try AVAudioFile(forReading: file)
  let fmt = af.processingFormat
  let chunk = AVAudioFrameCount(fmt.sampleRate/10)
  let dur = Double(af.length)/fmt.sampleRate
  guard let conv = AVAudioConverter(from: fmt, to: aFmt) else { fatalError("noconv") }
  let feedStart = now()
  var idx = 0
  while true {
    guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: chunk) else { break }
    if af.framePosition >= af.length { break }
    do { try af.read(into: buf, frameCount: chunk) } catch { FileHandle.standardError.write("READ ERR \(error)\n".data(using:.utf8)!); break }
    if buf.frameLength == 0 { break }
    guard let out = AVAudioPCMBuffer(pcmFormat: aFmt, frameCapacity: AVAudioFrameCount(Double(buf.frameLength)*aFmt.sampleRate/fmt.sampleRate)+1024) else { break }
    var served = false
    conv.convert(to: out, error: nil) { _, st in
      if served { st.pointee = .noDataNow; return nil }
      served = true; st.pointee = .haveData; return buf }
    builder.yield(AnalyzerInput(buffer: out))
    idx += 1
    let target = feedStart + Double(idx)*0.1
    let d = target - now(); if d > 0 { try? await Task.sleep(nanoseconds: UInt64(d*1e9)) }
  }
  let release = now()   // == user releases key
  builder.finish()
  do { try await analyzer.finalizeAndFinishThroughEndOfInput() } catch { FileHandle.standardError.write("FIN ERR \(error)\n".data(using:.utf8)!) }
  var firstVolatile: Double? = nil; var lastFinalText = ""
  do { let v = try await collector.value; firstVolatile = v.0; lastFinalText = v.1 } catch { FileHandle.standardError.write("COLLECT ERR \(error)\n".data(using:.utf8)!) }
  let done = now()
  print(String(format:"%@ fast=%@ prewarm=%@ audio=%.2fs | setup=%.0fms firstResult=%@ | RELEASE->FINAL=%.0fms | text=%@",
    mode, fast ? "Y":"N", prewarm ? "Y":"N", dur, (prep-start)*1000,
    firstVolatile == nil ? "none" : String(format:"%.0fms after audio start", (firstVolatile!-feedStart)*1000),
    (done-release)*1000, lastFinalText))
}

@main struct M { static func main() async throws {
  let f = URL(fileURLWithPath: CommandLine.arguments[1])
  for mode in ["st","dt"] { for fast in [false,true] { for pw in [false,true] {
    try await stream(file: f, mode: mode, fast: fast, prewarm: pw) } } }
}}
