import XCTest
import AVFoundation
@testable import WispritEngine

final class PcmFormatTests: XCTestCase {

    /// 16 kHz mono Int16 — measured `bestAvailableAudioFormat` for both
    /// transcribers, and `runtime.SAMPLE_RATE` / `CHANNELS` / `CHUNK_FRAMES`.
    func testCanonicalFormatMatchesThePythonPipeline() {
        XCTAssertEqual(PcmFormat.sampleRate, 16_000)
        XCTAssertEqual(PcmFormat.channels, 1)
        XCTAssertEqual(PcmFormat.chunkFrames, 1_600)
        XCTAssertEqual(PcmFormat.canonical.commonFormat, .pcmFormatInt16)
        XCTAssertTrue(PcmFormat.isCanonical(PcmFormat.canonical))
    }

    private func sineData(frames: Int, hz: Double, sampleRate: Double, amplitude: Double = 0.5) -> Data {
        var samples = [Int16]()
        samples.reserveCapacity(frames)
        for i in 0..<frames {
            let v = sin(2 * .pi * hz * Double(i) / sampleRate) * amplitude * 32767
            samples.append(Int16(v.rounded()))
        }
        return samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    func testDataToBufferRoundTripIsBitExact() {
        let pcm = sineData(frames: 1_600, hz: 440, sampleRate: 16_000)
        guard let buffer = PcmFormat.buffer(from: pcm, in: PcmFormat.canonical) else {
            return XCTFail("no buffer")
        }
        XCTAssertEqual(buffer.frameLength, 1_600)
        XCTAssertEqual(PcmFormat.canonicalData(from: buffer), pcm)
    }

    func testEmptyAndOddSizedInputsAreRejectedCleanly() {
        XCTAssertNil(PcmFormat.buffer(from: Data(), in: PcmFormat.canonical))
        XCTAssertNil(PcmFormat.buffer(from: Data([0]), in: PcmFormat.canonical))   // < one frame
    }

    private func floatBuffer(frames: AVAudioFrameCount, sampleRate: Double, hz: Double,
                            phaseOffset: Int = 0) -> AVAudioPCMBuffer {
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
        buffer.frameLength = frames
        let ch = buffer.floatChannelData!
        for i in 0..<Int(frames) {
            ch[0][i] = Float(sin(2 * .pi * hz * Double(i + phaseOffset) / sampleRate) * 0.5)
        }
        return buffer
    }

    /// A fresh converter costs the resampler's filter delay — the reason the
    /// capture path owns ONE `PcmDownconverter` for the whole session.
    func testOneShotConversionCostsOnlyTheFilterDelay() {
        let out = PcmFormat.canonicalData(from: floatBuffer(frames: 4_800, sampleRate: 48_000, hz: 440))
        XCTAssertEqual(out.count / 2, 1_360, "48 kHz -> 16 kHz filter delay is 240 frames")
    }

    func testStreamingDownconverterLosesNothingAcrossChunks() {
        let src = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                channels: 1, interleaved: false)!
        let converter = PcmDownconverter(from: src)!
        var frames = 0
        for chunk in 0..<10 {   // 10 × 100 ms = 1 s
            let buffer = floatBuffer(frames: 4_800, sampleRate: 48_000, hz: 440,
                                     phaseOffset: chunk * 4_800)
            frames += converter.convert(buffer).count / 2
        }
        // 1 s at 16 kHz = 16000 frames; only the one-time filter delay is missing.
        XCTAssertEqual(frames, 15_760, "240-frame filter delay, ONCE — not per chunk")
    }

    /// Regression guard for the non-obvious converter rule: a roomier output
    /// buffer makes AVAudioConverter drop pending input on every call, which
    /// would silently discard ~6 % of the mic stream.
    func testLongStreamStaysWithinOneFilterDelayOfExact() {
        let src = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100,
                                channels: 1, interleaved: false)!
        let converter = PcmDownconverter(from: src)!
        var frames = 0
        for chunk in 0..<50 {   // 5 s
            frames += converter.convert(floatBuffer(frames: 4_410, sampleRate: 44_100, hz: 440,
                                                    phaseOffset: chunk * 4_410)).count / 2
        }
        XCTAssertEqual(frames, 79_880, "5 s at 16 kHz minus a single 120-frame filter delay")
    }

    func testDownconverterIsAPassthroughForCanonicalInput() {
        let pcm = sineData(frames: 1_600, hz: 440, sampleRate: 16_000)
        let buffer = PcmFormat.buffer(from: pcm, in: PcmFormat.canonical)!
        XCTAssertEqual(PcmDownconverter(from: PcmFormat.canonical)!.convert(buffer), pcm)
    }

    func testDownconvertPreservesSignalEnergy() {
        let src = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100,
                                channels: 1, interleaved: false)!
        let frames: AVAudioFrameCount = 4_410
        guard let buffer = AVAudioPCMBuffer(pcmFormat: src, frameCapacity: frames),
              let ch = buffer.floatChannelData else { return XCTFail("no buffer") }
        buffer.frameLength = frames
        for i in 0..<Int(frames) {
            ch[0][i] = Float(sin(2 * .pi * 300 * Double(i) / 44_100) * 0.5)
        }
        // A 0.5-amplitude sine has RMS 0.354; the meter multiplies by 4 and clamps at 1.
        XCTAssertEqual(PcmFormat.level(of: PcmFormat.canonicalData(from: buffer)), 1.0, accuracy: 0.001)
    }

    func testLevelMeterMatchesThePythonFormula() {
        XCTAssertEqual(PcmFormat.level(of: Data()), 0)
        XCTAssertEqual(PcmFormat.level(of: Data(count: 3_200)), 0, "silence must not move the meter")
        // Constant 0.05 amplitude → RMS 0.05 → ×4 = 0.2, well under the clamp.
        let quiet = [Int16](repeating: Int16(0.05 * 32768), count: 1_600)
        let data = quiet.withUnsafeBufferPointer { Data(buffer: $0) }
        XCTAssertEqual(PcmFormat.level(of: data), 0.2, accuracy: 0.005)
        // Full scale clamps at 1.
        let loud = [Int16](repeating: 32_000, count: 1_600)
        XCTAssertEqual(PcmFormat.level(of: loud.withUnsafeBufferPointer { Data(buffer: $0) }), 1.0)
    }

    func testLevelMeterIsEndianExplicit() {
        // 0x0100 little-endian = 256; a byte-order slip would read 1.
        let data = Data([0x00, 0x01])
        let expected = min(1.0, Float(256.0 / 32768.0) * 4.0)
        XCTAssertEqual(PcmFormat.level(of: data), expected, accuracy: 1e-6)
    }
}
