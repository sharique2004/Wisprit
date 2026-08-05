import Foundation
import Speech
import AVFoundation
func now() -> Double { Date().timeIntervalSince1970 }

@main struct M { static func main() async throws {
  setvbuf(stdout, nil, _IONBF, 0)
  let files = [URL(fileURLWithPath:"s2.wav"), URL(fileURLWithPath:"s1.wav"), URL(fileURLWithPath:"s2.wav"), URL(fileURLWithPath:"s1.wav")]
  let t = SpeechTranscriber(locale: Locale(identifier:"en-US"), transcriptionOptions: [], reportingOptions: [.volatileResults,.fastResults], attributeOptions: [.audioTimeRange])
  let (seq, builder) = AsyncStream.makeStream(of: AnalyzerInput.self)
  let analyzer = SpeechAnalyzer(modules: [t])
  guard let aFmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [t]) else { fatalError() }
  let p0 = now(); try await analyzer.prepareToAnalyze(in: aFmt)
  print(String(format:"prepareToAnalyze: %.0fms", (now()-p0)*1000))
  try await analyzer.start(inputSequence: seq)
  let box = Box()
  let collector = Task { for try await r in t.results { await box.add(String(r.text.characters), r.isFinal, r.range.end) } }
  var cursor = CMTime.zero
  for (i,f) in files.enumerated() {
    let af = try AVAudioFile(forReading: f); let fmt = af.processingFormat
    guard let conv = AVAudioConverter(from: fmt, to: aFmt) else { fatalError() }
    let chunk = AVAudioFrameCount(fmt.sampleRate/10); var idx = 0; let s = now()
    var t0samples = cursor
    while af.framePosition < af.length {
      guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: chunk) else { break }
      try af.read(into: buf, frameCount: chunk); if buf.frameLength == 0 { break }
      guard let out = AVAudioPCMBuffer(pcmFormat: aFmt, frameCapacity: chunk*2) else { break }
      var served = false
      conv.convert(to: out, error: nil) { _, st in if served { st.pointee = .noDataNow; return nil }; served = true; st.pointee = .haveData; return buf }
      builder.yield(AnalyzerInput(buffer: out))
      t0samples = CMTimeAdd(t0samples, CMTime(seconds: Double(out.frameLength)/aFmt.sampleRate, preferredTimescale: 48000))
      idx += 1
      let d = s + Double(idx)*0.1 - now(); if d > 0 { try? await Task.sleep(nanoseconds: UInt64(d*1e9)) }
    }
    let rel = now()
    await box.mark()
    try await analyzer.finalize(through: t0samples)
    // wait until a final covering t0samples arrives
    var waited = 0.0
    while await !box.sawFinalSinceMark() && waited < 3.0 { try? await Task.sleep(nanoseconds: 2_000_000); waited += 0.002 }
    print(String(format:"utt %d: RELEASE->FINAL(resident analyzer) = %.0fms | %@", i+1, (now()-rel)*1000, await box.drain()))
    cursor = t0samples
    // gap between utterances
    try? await Task.sleep(nanoseconds: 500_000_000)
  }
  builder.finish(); await analyzer.cancelAndFinishNow(); collector.cancel()
}}

actor Box {
  var buf = ""; var finalSince = false
  func add(_ s: String, _ f: Bool, _ end: CMTime) { if f { buf += s; finalSince = true } }
  func mark() { finalSince = false }
  func sawFinalSinceMark() -> Bool { finalSince }
  func drain() -> String { let b = buf; buf = ""; return b }
}
