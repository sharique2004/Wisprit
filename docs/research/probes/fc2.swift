// Independent adversarial probe v2.
// Modes: nil | overshoot | exact | undershoot | silence | session
// "session" = control: fresh analyzer per utterance (Wisprit's current pattern)
import Foundation
import Speech
import AVFoundation

func now() -> Double { Date().timeIntervalSince1970 }
func ms(_ d: Double) -> String { String(format: "%.0fms", d * 1000) }
let BASE = "/private/tmp/claude-501/-Users-shariquekhatri-Wisprit/08bd5841-5936-4964-a20b-5f526dba0b52/scratchpad/"

actor Flag {
  var v: String? = nil
  var at: Double = 0
  func set(_ s: String) { if v == nil { v = s; at = now() } }
  func get() -> (String, Double)? { if let v { return (v, at) }; return nil }
}

actor Sink {
  var finals: [String] = []
  var volatiles = 0
  var firstVolatile: Double? = nil
  var err: String? = nil
  func addFinal(_ s: String) { finals.append(s) }
  func addVolatile() { volatiles += 1; if firstVolatile == nil { firstVolatile = now() } }
  func setErr(_ e: String) { err = e }
  func take() -> (String, Int, Double?, String?) {
    let s = finals.joined(); finals = []
    let v = volatiles; volatiles = 0
    let f = firstVolatile; firstVolatile = nil
    return (s, v, f, err)
  }
}

func makeTranscriber() -> SpeechTranscriber {
  SpeechTranscriber(locale: Locale(identifier: "en-US"),
                    transcriptionOptions: [],
                    reportingOptions: [.volatileResults, .fastResults],
                    attributeOptions: [])
}

// Feed a file real-time paced; returns (accumulated end time, time speaking began)
func feed(_ url: URL, into builder: AsyncStream<AnalyzerInput>.Continuation,
          fmt aFmt: AVAudioFormat, from start: CMTime, stamped: Bool) throws -> (CMTime, Double) {
  let af = try AVAudioFile(forReading: url)
  let fmt = af.processingFormat
  guard let conv = AVAudioConverter(from: fmt, to: aFmt) else { fatalError("conv") }
  let chunk = AVAudioFrameCount(fmt.sampleRate / 10)
  var idx = 0
  let t0 = now()
  var end = start
  while af.framePosition < af.length {
    guard let inBuf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: chunk) else { break }
    try af.read(into: inBuf, frameCount: chunk)
    if inBuf.frameLength == 0 { break }
    guard let outBuf = AVAudioPCMBuffer(pcmFormat: aFmt, frameCapacity: chunk * 2) else { break }
    var served = false
    conv.convert(to: outBuf, error: nil) { _, st in
      if served { st.pointee = .noDataNow; return nil }
      served = true; st.pointee = .haveData; return inBuf
    }
    builder.yield(stamped ? AnalyzerInput(buffer: outBuf, bufferStartTime: end)
                          : AnalyzerInput(buffer: outBuf))
    end = CMTimeAdd(end, CMTime(seconds: Double(outBuf.frameLength) / aFmt.sampleRate,
                                preferredTimescale: 16000))
    idx += 1
    let due = t0 + Double(idx) * 0.1 - now()
    if due > 0 { usleep(UInt32(due * 1_000_000)) }
  }
  return (end, t0)
}

// Run finalize with a hard watchdog; returns (outcomeLabel, elapsedSeconds)
func finalizeWatched(_ analyzer: SpeechAnalyzer, through: CMTime?, timeout: Double) async -> (String, Double) {
  let flag = Flag()
  let start = now()
  Task {
    do { try await analyzer.finalize(through: through); await flag.set("RETURNED") }
    catch { await flag.set("THREW(\(error))") }
  }
  let dl = start + timeout
  while now() < dl {
    if let (o, at) = await flag.get() { return (o, at - start) }
    try? await Task.sleep(nanoseconds: 5_000_000)
  }
  return ("HUNG(>\(Int(timeout))s)", timeout)
}

@main struct M {
  static func main() async throws {
    setvbuf(stdout, nil, _IONBF, 0)
    let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "nil"
    let files = ["s2.wav", "s1.wav", "s2.wav", "s1.wav"].map { URL(fileURLWithPath: BASE + $0) }
    let probe = makeTranscriber()
    guard let aFmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [probe]) else {
      print("no format"); exit(1)
    }
    print("format: \(aFmt) | MODE: \(mode)")

    if mode == "session" {
      // CONTROL: fresh analyzer + fresh stream per utterance
      for (i, f) in files.enumerated() {
        let t = makeTranscriber()
        let sink = Sink()
        let (seq, builder) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let analyzer = SpeechAnalyzer(modules: [t])
        let setup0 = now()
        try await analyzer.prepareToAnalyze(in: aFmt)
        try await analyzer.start(inputSequence: seq)
        let setupMs = now() - setup0
        let col = Task {
          do { for try await r in t.results {
                 if r.isFinal { await sink.addFinal(String(r.text.characters)) } else { await sink.addVolatile() } }
          } catch { await sink.setErr("\(error)") }
        }
        let (_, spoke) = try feed(f, into: builder, fmt: aFmt, from: .zero, stamped: false)
        let rel = now()
        builder.finish()
        var outcome = "RETURNED"
        do { try await analyzer.finalizeAndFinishThroughEndOfInput() } catch { outcome = "THREW(\(error))" }
        let finMs = now() - rel
        try? await Task.sleep(nanoseconds: 100_000_000)
        let (text, vol, fv, err) = await sink.take()
        col.cancel()
        print("utt \(i+1) [\(f.lastPathComponent)] setup=\(ms(setupMs)) release->final=\(ms(finMs)) \(outcome) firstVol=\(fv.map{ms($0-spoke)} ?? "none") vol=\(vol) err=\(err ?? "-")")
        print("      TEXT: \(text)")
        try? await Task.sleep(nanoseconds: 700_000_000)
      }
      print("DONE"); exit(0)
    }

    // RESIDENT modes
    let t = makeTranscriber()
    let sink = Sink()
    let (seq, builder) = AsyncStream.makeStream(of: AnalyzerInput.self)
    let analyzer = SpeechAnalyzer(modules: [t])
    let p0 = now()
    try await analyzer.prepareToAnalyze(in: aFmt)
    print("prepareToAnalyze: \(ms(now() - p0))")
    let col = Task {
      do { for try await r in t.results {
             if r.isFinal { await sink.addFinal(String(r.text.characters)) } else { await sink.addVolatile() } }
      } catch { await sink.setErr("\(error)") }
    }
    try await analyzer.start(inputSequence: seq)
    print("resident analyzer started; input stream stays OPEN across utterances")

    var cursor = CMTime.zero
    for (i, f) in files.enumerated() {
      let stamped = (mode == "exact")
      let (end, spoke) = try feed(f, into: builder, fmt: aFmt, from: cursor, stamped: stamped)
      var target: CMTime? = nil
      switch mode {
      case "nil":        target = nil
      case "overshoot":  target = end
      case "exact":      target = end
      case "undershoot": target = CMTimeSubtract(end, CMTime(seconds: 0.15, preferredTimescale: 16000))
      case "delayed":
        // wait 600ms with NO new audio, so `end` is certainly already consumed, THEN finalize(through: end)
        try? await Task.sleep(nanoseconds: 600_000_000)
        target = end
      case "silence":
        // pad 500ms of silence AFTER release so `end` is definitely consumed
        if let z = AVAudioPCMBuffer(pcmFormat: aFmt, frameCapacity: 8000) {
          z.frameLength = 8000
          if let ch = z.int16ChannelData { memset(ch[0], 0, 16000) }
          builder.yield(AnalyzerInput(buffer: z))
        }
        target = end
      default: target = nil
      }
      let rel = now()
      let (outcome, elapsed) = await finalizeWatched(analyzer, through: target, timeout: 8.0)
      try? await Task.sleep(nanoseconds: 150_000_000)
      let (text, vol, fv, err) = await sink.take()
      print("utt \(i+1) [\(f.lastPathComponent)] range=\(String(format:"%.3f",cursor.seconds))..\(String(format:"%.3f",end.seconds)) " +
            "target=\(target.map{String(format:"%.3f",$0.seconds)} ?? "nil") release->finalize=\(ms(elapsed)) \(outcome) " +
            "firstVol=\(fv.map{ms($0-spoke)} ?? "none") vol=\(vol) err=\(err ?? "-")")
      print("      TEXT: \(text)")
      if outcome.hasPrefix("HUNG") { print("ABORT: wedged"); break }
      cursor = (mode == "silence") ? CMTimeAdd(end, CMTime(seconds: 0.5, preferredTimescale: 16000)) : end
      try? await Task.sleep(nanoseconds: 700_000_000)
    }
    builder.finish()
    await analyzer.cancelAndFinishNow()
    col.cancel()
    print("DONE")
    exit(0)
  }
}
