// Independent adversarial probe: can a RESIDENT SpeechAnalyzer be finalized per-utterance?
// Modes: nil | overshoot | exact
import Foundation
import Speech
import AVFoundation

func now() -> Double { Date().timeIntervalSince1970 }
func ms(_ d: Double) -> String { String(format: "%.0fms", d * 1000) }

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

@main struct M {
  static func main() async throws {
    setvbuf(stdout, nil, _IONBF, 0)
    let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "nil"
    let base = "/private/tmp/claude-501/-Users-shariquekhatri-Wisprit/08bd5841-5936-4964-a20b-5f526dba0b52/scratchpad/"
    let files = ["s2.wav", "s1.wav", "s2.wav", "s1.wav"].map { URL(fileURLWithPath: base + $0) }

    let t = SpeechTranscriber(locale: Locale(identifier: "en-US"),
                              transcriptionOptions: [],
                              reportingOptions: [.volatileResults, .fastResults],
                              attributeOptions: [])
    guard let aFmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [t]) else {
      print("no format"); exit(1)
    }
    print("analyzer format: \(aFmt)")
    print("MODE: \(mode)")

    let (seq, builder) = AsyncStream.makeStream(of: AnalyzerInput.self)
    let analyzer = SpeechAnalyzer(modules: [t])
    let p0 = now()
    try await analyzer.prepareToAnalyze(in: aFmt)
    print("prepareToAnalyze: \(ms(now() - p0))")

    let sink = Sink()
    let collector = Task {
      do {
        for try await r in t.results {
          if r.isFinal { await sink.addFinal(String(r.text.characters)) }
          else { await sink.addVolatile() }
        }
      } catch { await sink.setErr("\(error)") }
    }

    let s0 = now()
    try await analyzer.start(inputSequence: seq)
    print("start(inputSequence:): \(ms(now() - s0))  [analyzer stays resident, stream stays OPEN]")

    var cursor = CMTime.zero

    for (i, f) in files.enumerated() {
      let af = try AVAudioFile(forReading: f)
      let fmt = af.processingFormat
      guard let conv = AVAudioConverter(from: fmt, to: aFmt) else { fatalError("conv") }
      let chunk = AVAudioFrameCount(fmt.sampleRate / 10)   // 100ms
      var idx = 0
      let tStart = now()
      let uttStart = cursor
      var uttEnd = cursor
      let speakBegan = now()

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
        if mode == "exact" {
          builder.yield(AnalyzerInput(buffer: outBuf, bufferStartTime: uttEnd))
        } else {
          builder.yield(AnalyzerInput(buffer: outBuf))
        }
        uttEnd = CMTimeAdd(uttEnd, CMTime(seconds: Double(outBuf.frameLength) / aFmt.sampleRate,
                                          preferredTimescale: 16000))
        idx += 1
        let due = tStart + Double(idx) * 0.1 - now()
        if due > 0 { try? await Task.sleep(nanoseconds: UInt64(due * 1e9)) }
      }

      // ---- KEY-UP ----
      let release = now()
      var target: CMTime? = nil
      switch mode {
      case "nil":       target = nil
      case "overshoot": target = uttEnd            // computed accumulation, same as researcher's probe
      case "exact":     target = uttEnd
      default:          target = nil
      }

      // race finalize against a watchdog so a hang is observable rather than fatal
      let finTask = Task { try await analyzer.finalize(through: target) }
      let watchdog = Task { try await Task.sleep(nanoseconds: 8_000_000_000); return () }
      var hung = false
      await withTaskGroup(of: String.self) { g in
        g.addTask { (try? await finTask.value) != nil ? "done" : "throw" }
        g.addTask { try? await watchdog.value; return "timeout" }
        if let first = await g.next() {
          if first == "timeout" { hung = true }
          g.cancelAll()
        }
      }
      let finMs = now() - release

      // give the results stream a moment to deliver
      try? await Task.sleep(nanoseconds: 150_000_000)
      let (text, vol, firstVol, err) = await sink.take()
      let firstPartial = firstVol.map { ms($0 - speakBegan) } ?? "none"
      print("utt \(i+1) [\(f.lastPathComponent)] uttRange=\(String(format:"%.3f",uttStart.seconds))..\(String(format:"%.3f",uttEnd.seconds)) " +
            "release->finalize=\(ms(finMs))\(hung ? "  *** HUNG (watchdog 8s) ***" : "") " +
            "firstVolatile=\(firstPartial) volatiles=\(vol) err=\(err ?? "-")")
      print("      TEXT: \(text)")
      if hung { print("ABORTING: analyzer wedged"); break }

      cursor = uttEnd
      try? await Task.sleep(nanoseconds: 700_000_000)  // inter-utterance gap, stream still open
    }

    builder.finish()
    await analyzer.cancelAndFinishNow()
    collector.cancel()
    print("DONE")
    exit(0)
  }
}
