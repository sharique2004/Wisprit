import Foundation
import AVFoundation
let src = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
let src44 = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 1, interleaved: false)!
let dst = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
func run(_ s: AVAudioFormat, _ chunkFrames: AVAudioFrameCount, _ n: Int) -> Int {
  let c = AVAudioConverter(from: s, to: dst)!
  let ratio = dst.sampleRate / s.sampleRate
  var tot = 0
  for k in 0..<n {
    let b = AVAudioPCMBuffer(pcmFormat: s, frameCapacity: chunkFrames)!; b.frameLength = chunkFrames
    for i in 0..<Int(chunkFrames) { b.floatChannelData![0][i] = Float(sin(2 * .pi * 440 * Double(i + k*Int(chunkFrames)) / s.sampleRate) * 0.5) }
    let cap = AVAudioFrameCount((Double(chunkFrames) * ratio).rounded(.up))
    let out = AVAudioPCMBuffer(pcmFormat: dst, frameCapacity: cap)!
    var served = false; var err: NSError?
    c.convert(to: out, error: &err) { _, st in if served { st.pointee = .noDataNow; return nil }; served = true; st.pointee = .haveData; return b }
    tot += Int(out.frameLength)
  }
  return tot
}
print("48k x10 (want 16000): \(run(src, 4800, 10))")
print("48k x50 (want 80000): \(run(src, 4800, 50))")
print("44.1k x50 (want 80000): \(run(src44, 4410, 50))")
print("48k 1024-frame taps x100 (want 34133): \(run(src, 1024, 100))")
