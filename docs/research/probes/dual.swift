import Foundation
import Speech
import AVFoundation
func now() -> Double { Date().timeIntervalSince1970 }
@main struct M { static func main() async throws {
  setvbuf(stdout, nil, _IONBF, 0)
  let terms = ["Sharique","Wisprit","InsForge"]
  let ctx = AnalysisContext(); ctx.contextualStrings = [.general: terms]
  let st = SpeechTranscriber(locale: Locale(identifier:"en-US"), transcriptionOptions: [], reportingOptions: [.volatileResults,.fastResults], attributeOptions: [])
  let dt = DictationTranscriber(locale: Locale(identifier:"en-US"), contentHints: [.shortForm], transcriptionOptions: [.punctuation], reportingOptions: [.volatileResults,.frequentFinalization], attributeOptions: [])
  let analyzer = SpeechAnalyzer(modules: [st, dt])
  try await analyzer.setContext(ctx)
  guard let f = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [st, dt]) else { fatalError("no common format") }
  print("common format:", f)
  let (seq, builder) = AsyncStream.makeStream(of: AnalyzerInput.self)
  let c1 = Task { () -> String in var s=""; for try await r in st.results where r.isFinal { s += String(r.text.characters) }; return s }
  let c2 = Task { () -> String in var s=""; for try await r in dt.results where r.isFinal { s += String(r.text.characters) }; return s }
  try await analyzer.start(inputSequence: seq)
  let af = try AVAudioFile(forReading: URL(fileURLWithPath:"s1.wav")); let fmt = af.processingFormat
  guard let conv = AVAudioConverter(from: fmt, to: f) else { fatalError() }
  let chunk = AVAudioFrameCount(fmt.sampleRate/10); var i = 0; let s0 = now()
  while af.framePosition < af.length {
    guard let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: chunk) else { break }
    try af.read(into: b, frameCount: chunk); if b.frameLength == 0 { break }
    guard let o = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: chunk*2) else { break }
    var served = false
    conv.convert(to: o, error: nil) { _, st2 in if served { st2.pointee = .noDataNow; return nil }; served = true; st2.pointee = .haveData; return b }
    builder.yield(AnalyzerInput(buffer: o)); i += 1
    let d = s0 + Double(i)*0.1 - now(); if d > 0 { try? await Task.sleep(nanoseconds: UInt64(d*1e9)) }
  }
  let rel = now(); builder.finish()
  do { try await analyzer.finalizeAndFinishThroughEndOfInput() } catch { print("FIN ERR", error) }
  let a = (try? await c1.value) ?? "<st err>"; let b = (try? await c2.value) ?? "<dt err>"
  print(String(format:"release->done %.0fms", (now()-rel)*1000))
  print("ST :", a); print("DT :", b)
}}
