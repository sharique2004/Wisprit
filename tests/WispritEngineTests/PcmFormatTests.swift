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

    // MARK: - end-of-stream flush (the keyup tail)
    //
    // The two tests above pin what a streamed conversion LOSES: 240 frames at
    // 48 kHz, 120 at 44.1 kHz, held inside the converter's resampler at stream
    // end. `MicCapture.stop()` used to drop that on the floor along with the
    // undelivered tap buffer — word-final audio, every single utterance.

    func testFlushRecoversTheResamplerTail() {
        let src = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                channels: 1, interleaved: false)!
        let converter = PcmDownconverter(from: src)!
        var frames = 0
        for chunk in 0..<10 {   // the same 1 s the streaming test uses
            frames += converter.convert(floatBuffer(frames: 4_800, sampleRate: 48_000, hz: 440,
                                                    phaseOffset: chunk * 4_800)).count / 2
        }
        XCTAssertEqual(frames, 15_760, "the streamed total is unchanged")
        frames += converter.flush().count / 2
        XCTAssertEqual(Double(frames), 16_000, accuracy: 16,
                       "flush returns the 240-frame filter delay: a full second of audio")
    }

    func testFlushRecoversTheResamplerTailAt44k() {
        let src = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100,
                                channels: 1, interleaved: false)!
        let converter = PcmDownconverter(from: src)!
        var frames = 0
        for chunk in 0..<50 {   // 5 s
            frames += converter.convert(floatBuffer(frames: 4_410, sampleRate: 44_100, hz: 440,
                                                    phaseOffset: chunk * 4_410)).count / 2
        }
        XCTAssertEqual(frames, 79_880)
        frames += converter.flush().count / 2
        XCTAssertEqual(Double(frames), 80_000, accuracy: 16, "the 120-frame tail at 44.1 kHz")
    }

    /// The tail is SIGNAL, not padding: it is the last few ms of the last word.
    func testFlushedTailCarriesSignal() {
        let src = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                channels: 1, interleaved: false)!
        let converter = PcmDownconverter(from: src)!
        for chunk in 0..<10 {
            _ = converter.convert(floatBuffer(frames: 4_800, sampleRate: 48_000, hz: 440,
                                              phaseOffset: chunk * 4_800))
        }
        let tail = converter.flush()
        XCTAssertFalse(tail.isEmpty)
        // A 0.5-amplitude sine reads ≈1.0 on the ×4-and-clamp meter even after
        // the resampler's edge decay; anything over 0.5 is unambiguously audio.
        XCTAssertGreaterThan(PcmFormat.level(of: tail), 0.5, "real samples, not zeros")
    }

    /// A passthrough converter holds no filter state, so it has no tail — and
    /// must not fabricate one.
    func testFlushOnCanonicalPassthroughIsEmpty() {
        XCTAssertEqual(PcmDownconverter(from: PcmFormat.canonical)!.flush(), Data())
    }

    /// The wedged-microphone diagnostic depends on this: if a drain of a
    /// never-fed converter emitted priming zeros, `deliveredBytes` would go
    /// non-zero and "microphone delivered no audio" would stop being logged.
    func testFlushWithoutInputIsEmpty() {
        let src = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                channels: 1, interleaved: false)!
        XCTAssertEqual(PcmDownconverter(from: src)!.flush(), Data())
    }

    /// `AVAudioConverter` is terminal after `.endOfStream`. The instance must
    /// refuse to be reused rather than emit corrupt audio.
    func testFlushIsTerminal() {
        let src = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                channels: 1, interleaved: false)!
        let converter = PcmDownconverter(from: src)!
        _ = converter.convert(floatBuffer(frames: 4_800, sampleRate: 48_000, hz: 440))
        XCTAssertFalse(converter.flush().isEmpty)
        XCTAssertEqual(converter.flush(), Data(), "one flush per instance")
        XCTAssertEqual(converter.convert(floatBuffer(frames: 4_800, sampleRate: 48_000, hz: 440)),
                       Data(), "and no feeding it afterwards")
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

    // MARK: - rescue-path normalization (2026-08-15)

    /// A constant-amplitude buffer at a chosen METER level, so a test can name
    /// the number the rescue gate actually compares against (RMS × 4, clamped)
    /// instead of an amplitude nobody reads.
    private func tone(atLevel level: Float, seconds: Double = 1.0) -> Data {
        let amplitude = Double(level) / 4.0
        let count = Int(seconds * PcmFormat.sampleRate)
        let samples = [Int16](repeating: Int16((amplitude * 32768).rounded()), count: count)
        return samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// The b0a763f silence rule, at the sample level: a hold nobody spoke into
    /// must come out of the rescue exactly as it went in. Amplifying room tone
    /// by 30 dB is precisely how a silent push-to-talk starts inserting words.
    func testNormalizationLeavesSilenceExactlyAsItFoundIt() {
        let silence = Data(count: 32_000)
        XCTAssertEqual(PcmFormat.normalizationGain(of: silence), 1)
        XCTAssertEqual(PcmFormat.normalized(silence), silence)

        // Room tone below the voiced threshold is the same refusal.
        let roomTone = tone(atLevel: SpeechAnalyzerEngine.voicedPeakThreshold - 0.002)
        XCTAssertEqual(PcmFormat.normalizationGain(of: roomTone), 1)
        XCTAssertEqual(PcmFormat.normalized(roomTone), roomTone)

        XCTAssertEqual(PcmFormat.normalized(Data()), Data(), "and empty audio is not a special case")
    }

    /// The production band: peak 0.06 over a 0.5 target is 18.4 dB, applied.
    func testAQuietUtteranceLandsOnTheTarget() {
        let quiet = tone(atLevel: 0.06)
        let gain = PcmFormat.normalizationGain(of: quiet)
        XCTAssertEqual(gain, 0.5 / 0.06, accuracy: 0.01)
        XCTAssertEqual(PcmFormat.peakLevel(of: PcmFormat.normalized(quiet)),
                       PcmFormat.normalizationTargetPeak, accuracy: 0.005)
    }

    /// 30 dB and not a decibel more: below ~0.0158 the target is unreachable,
    /// and what is left down there is room, not speech.
    func testTheGainIsCappedAtThirtyDecibels() {
        let barelyVoiced = tone(atLevel: 0.012)
        XCTAssertEqual(PcmFormat.normalizationGain(of: barelyVoiced),
                       PcmFormat.maximumNormalizationGain, accuracy: 1e-4)
        let out = PcmFormat.normalized(barelyVoiced)
        XCTAssertLessThan(PcmFormat.peakLevel(of: out), PcmFormat.normalizationTargetPeak,
                          "the cap is a cap — it does not get to reach the target")
        XCTAssertEqual(PcmFormat.peakLevel(of: out),
                       0.012 * PcmFormat.maximumNormalizationGain, accuracy: 0.005)
    }

    /// Audio already at or above the target is not touched at all, and neither
    /// is audio a hair under it — a 0.4 dB nudge cannot change a transcript and
    /// would cost the operation its idempotence.
    func testAudioAtOrNearTheTargetIsUntouched() {
        for level: Float in [0.5, 0.8, 0.48] {
            let loud = tone(atLevel: level)
            XCTAssertEqual(PcmFormat.normalizationGain(of: loud), 1, "level \(level)")
            XCTAssertEqual(PcmFormat.normalized(loud), loud, "level \(level)")
        }
    }

    func testNormalizingAnAlreadyNormalizedBufferIsAByteForByteNoOp() {
        let once = PcmFormat.normalized(tone(atLevel: 0.06))
        XCTAssertEqual(PcmFormat.normalized(once), once)
    }

    /// A high-crest chunk reaches full scale before its METERED level does —
    /// the meter is RMS × 4 — so the per-sample clamp is load-bearing. What it
    /// must never do is wrap: an Int16 overflow turns a loud syllable into a
    /// click, which is a worse thing to hand a recognizer than a quiet one.
    func testLoudTransientsSaturateAndNeverWrap() {
        var samples = [Int16](repeating: 100, count: 1_600)
        for i in stride(from: 0, to: 1_600, by: 320) { samples[i] = 32_000 }
        let spiky = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        XCTAssertGreaterThan(PcmFormat.normalizationGain(of: spiky), 1, "precondition: it is quiet")

        let out = PcmFormat.normalized(spiky)
        XCTAssertEqual(out.count, spiky.count)
        out.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: Int16.self)
            for i in 0..<(out.count / 2) {
                let v = Int16(littleEndian: p[i])
                XCTAssertGreaterThan(v, 0, "sample \(i) changed sign — that is a wrap, not a clamp")
                XCTAssertLessThanOrEqual(v, 32_767)
            }
        }
    }

    /// `peakLevel(of:)` has to be the SAME statistic the engine meters live, or
    /// the rescue gate is comparing two different numbers.
    func testPeakLevelIsTheLoudestChunkNotTheWholeBufferAverage() {
        let quiet = tone(atLevel: 0.02, seconds: 1.0)
        let loudChunk = tone(atLevel: 0.6, seconds: 0.1)
        let mixed = quiet + loudChunk
        XCTAssertEqual(PcmFormat.peakLevel(of: mixed), 0.6, accuracy: 0.01)
        XCTAssertLessThan(PcmFormat.level(of: mixed), 0.3,
                          "the whole-buffer mean would have missed the speech entirely")
    }
}
