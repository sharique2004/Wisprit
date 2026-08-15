import Foundation
import AVFoundation

/// 16 kHz mono Int16 throughout. Measured (`docs/research/spikes-s1.md`,
/// probe q5): `bestAvailableAudioFormat` for BOTH SpeechTranscriber and
/// DictationTranscriber is `1 ch, 16000 Hz, Int16` — the pipeline format is
/// already the analyzer's native one, so the live path does no conversion at all.
public enum PcmFormat {
    public static let sampleRate: Double = 16_000
    public static let channels: AVAudioChannelCount = 1
    /// 100 ms per chunk, matching `runtime.CHUNK_FRAMES`.
    public static let chunkFrames: AVAudioFrameCount = 1_600
    public static let bytesPerFrame = 2

    /// The canonical pipeline format.
    public static let canonical: AVAudioFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: sampleRate,
        channels: channels, interleaved: true)!

    /// True when `format` is already 16 kHz mono Int16, i.e. a plain memcpy.
    public static func isCanonical(_ format: AVAudioFormat) -> Bool {
        format.commonFormat == .pcmFormatInt16
            && format.sampleRate == sampleRate
            && format.channelCount == channels
    }

    /// Int16 bytes → a buffer in `format`. Converts only if `format` is not the
    /// canonical one (never happens on this machine — kept for the iOS device
    /// matrix, where a different best format would otherwise silently corrupt).
    public static func buffer(from pcm: Data, in format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard !pcm.isEmpty else { return nil }
        let frames = AVAudioFrameCount(pcm.count / bytesPerFrame)
        guard frames > 0 else { return nil }
        guard let src = AVAudioPCMBuffer(pcmFormat: canonical, frameCapacity: frames),
              let dst = src.int16ChannelData else { return nil }
        src.frameLength = frames
        pcm.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            memcpy(dst[0], base, Int(frames) * bytesPerFrame)
        }
        if isCanonical(format) { return src }
        return convert(src, to: format)
    }

    /// ONE-SHOT conversion of a complete buffer → canonical 16 kHz mono Int16
    /// bytes. Correct for a whole file or a whole utterance.
    ///
    /// **Not for a stream.** A fresh `AVAudioConverter` holds back its resampler
    /// tail: converting a 100 ms 48 kHz buffer in isolation yields ~1360 frames
    /// instead of 1600, so per-chunk one-shot conversion would silently discard
    /// ~15 % of the audio and add a discontinuity at every chunk boundary. The
    /// mic path uses `PcmDownconverter`, which keeps the converter across buffers.
    public static func canonicalData(from buffer: AVAudioPCMBuffer) -> Data {
        if isCanonical(buffer.format) { return rawInt16Data(from: buffer) }
        guard let converted = convert(buffer, to: canonical) else { return Data() }
        return rawInt16Data(from: converted)
    }

    static func int16Data(from buffer: AVAudioPCMBuffer) -> Data { rawInt16Data(from: buffer) }

    /// Output capacity must be EXACTLY what the input can produce — no slack.
    /// Measured: with a roomier output buffer the converter hits `.noDataNow`
    /// with input still pending and discards it (48 kHz → 16 kHz, 100 ms taps:
    /// 15056 of 16000 frames survive a 1 s stream with a 4096-frame output
    /// buffer, 15760 with an exact 1600-frame one). At exact capacity the only
    /// loss is the resampler's one-time filter delay — 240 frames at 48 kHz,
    /// 120 at 44.1 kHz, once per capture session, not per chunk.
    static func outputCapacity(inputFrames: AVAudioFrameCount, ratio: Double) -> AVAudioFrameCount {
        max(1, AVAudioFrameCount((Double(inputFrames) * ratio).rounded(.up)))
    }

    /// A whole utterance cut into pipeline-sized (100 ms) chunks, for the
    /// off-path passes that feed retained PCM to an analyzer in one burst. One
    /// definition, because two of them (the vocabulary channel and the batch
    /// rescue) must agree: the analyzer's accuracy is invariant to the chunking
    /// only as long as the chunking is the one the eval harness measured.
    public static func split(_ pcm: Data) -> [Data] {
        let step = Int(chunkFrames) * bytesPerFrame
        var out: [Data] = []
        var i = 0
        while i < pcm.count {
            out.append(pcm.subdata(in: i..<min(i + step, pcm.count)))
            i += step
        }
        return out
    }

    /// Normalized RMS level for the pill's input meter, 0…1. Same shape as
    /// `AudioCapture._callback`: RMS over int16/32768, ×4 so quiet speech still
    /// moves the meter, clamped at 1.
    public static func level(of pcm: Data) -> Float {
        level(fromMeanSquare: meanSquare(of: pcm))
    }

    /// The raw mean of squared normalized samples — the pre-scaling statistic
    /// `level(of:)` is built on. Exposed so a consumer that needs to COMBINE
    /// windows (the noise-floor estimate averages three 100 ms chunks) can do
    /// so before the ×4-and-clamp, which does not distribute over averaging.
    public static func meanSquare(of pcm: Data) -> Double {
        let count = pcm.count / bytesPerFrame
        guard count > 0 else { return 0 }
        var sum = 0.0
        pcm.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: Int16.self)
            for i in 0..<count {
                let v = Double(Int16(littleEndian: p[i])) / 32768.0
                sum += v * v
            }
        }
        return sum / Double(count)
    }

    /// Mean-square → the meter's 0…1 scale (RMS × 4, clamped). One place, so
    /// `peak_level` and `noise_floor` are always the same statistic family.
    public static func level(fromMeanSquare meanSquare: Double) -> Float {
        min(1.0, Float(meanSquare.squareRoot()) * 4.0)
    }

    /// Loudest 100 ms chunk of a whole utterance, on the meter's scale — the
    /// same statistic `UtteranceResult.peakLevel` and the `peak_level` metrics
    /// field carry, computed offline over retained PCM instead of live over the
    /// tap. It has to be the same one: the rescue gate below compares against
    /// the engine's live number, and two different definitions of "peak" would
    /// make that comparison meaningless.
    public static func peakLevel(of pcm: Data) -> Float {
        split(pcm).reduce(0) { max($0, level(of: $1)) }
    }

    // MARK: - rescue-path normalization

    /// What `normalized(_:)` aims the loudest chunk at. 0.5 rather than 1.0:
    /// measured, the re-normalized quiet corpora (peak 0.06/0.03/0.015 → 0.5)
    /// scored 1.63 / 1.46 / 1.55 % WER against a 1.72 % control, and leaving
    /// 6 dB of headroom is what keeps the per-sample clamp below from having
    /// anything to do on ordinary speech.
    public static let normalizationTargetPeak: Float = 0.5

    /// 30 dB. Above this the "signal" being amplified is room tone: the level
    /// experiment's deepest rung (peak 0.015, 1.5× the voiced threshold) needs
    /// 30.5 dB to reach 0.5, and everything quieter than that is noise wearing
    /// speech's shape.
    public static let maximumNormalizationGain: Float = 31.6

    /// Below this a normalization is not worth performing. Two reasons, and the
    /// second is the load-bearing one: (1) 0.4 dB cannot change a transcript —
    /// the engine is level-invariant across a 36 dB span (1.72 % → 2.15 % WER
    /// from peak 1.0 to 0.015); (2) without a deadband the operation is not
    /// idempotent, because scaled Int16 samples re-measure a hair either side of
    /// the target and a second pass would rewrite the buffer by ±1 LSB.
    static let minimumUsefulGain: Float = 1.05

    /// The gain `normalized(_:targetPeak:)` would apply — 1 means "leave it
    /// alone", which is the answer for empty audio, for silence, and for
    /// anything already at or above the target.
    ///
    /// The silence exemption is the b0a763f rule reaching down to the sample
    /// level: a hold nobody spoke into must stay a hold nobody spoke into, and
    /// amplifying room tone by 30 dB is the one way to turn it into something
    /// a recognizer will invent words from.
    public static func normalizationGain(of pcm: Data,
                                         targetPeak: Float = normalizationTargetPeak) -> Float {
        guard !pcm.isEmpty else { return 1 }
        let peak = peakLevel(of: pcm)
        guard peak >= SpeechAnalyzerEngine.voicedPeakThreshold else { return 1 }
        let gain = min(targetPeak / peak, maximumNormalizationGain)
        return gain >= minimumUsefulGain ? gain : 1
    }

    /// Peak-normalize a whole utterance for the batch rescue.
    ///
    /// MEASURED CEILING, so nobody re-litigates this as an accuracy lever: on
    /// 60 LibriSpeech clips, normalizing quantized-quiet audio back to 0.5
    /// recovers ~0.6 pt of WER at peak 0.015 and ~0.3 pt at the peak 0.06 the
    /// user's telemetry actually shows — and ~0.26 pt of a 3.9 pt loss when the
    /// quiet speech sits over a real noise floor, because gain amplifies the
    /// floor identically. It is worth its five lines on a path that only runs
    /// after the streaming engine already failed. It is not worth a live stage:
    /// the information is gone at the microphone.
    public static func normalized(_ pcm: Data,
                                  targetPeak: Float = normalizationTargetPeak) -> Data {
        let gain = normalizationGain(of: pcm, targetPeak: targetPeak)
        guard gain > 1 else { return pcm }
        return scaled(pcm, by: gain)
    }

    /// Int16 samples × `gain`, saturating at full scale.
    ///
    /// The clamp is not decoration: a chunk whose crest factor exceeds 8× its
    /// RMS reaches full scale before its metered level does, because the meter
    /// is RMS×4. Measured harmless on the normalization rungs (their WER is at
    /// or under the control's), and saturating is in any case the only
    /// alternative to wrapping — an Int16 overflow would turn a loud syllable
    /// into a click the recognizer has to eat.
    static func scaled(_ pcm: Data, by gain: Float) -> Data {
        let count = pcm.count / bytesPerFrame
        guard count > 0 else { return pcm }
        var out = [Int16](repeating: 0, count: count)
        pcm.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: Int16.self)
            for i in 0..<count {
                let v = (Float(Int16(littleEndian: p[i])) * gain).rounded()
                out[i] = Int16(max(-32_768, min(32_767, v))).littleEndian
            }
        }
        return out.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    // MARK: - internals

    private static func rawInt16Data(from buffer: AVAudioPCMBuffer) -> Data {
        guard let ch = buffer.int16ChannelData, buffer.frameLength > 0 else { return Data() }
        return Data(bytes: ch[0], count: Int(buffer.frameLength) * bytesPerFrame)
    }

    private static func convert(_ input: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let converter = AVAudioConverter(from: input.format, to: format) else { return nil }
        let ratio = format.sampleRate / input.format.sampleRate
        let capacity = outputCapacity(inputFrames: input.frameLength, ratio: ratio)
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var served = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if served { status.pointee = .noDataNow; return nil }
            served = true; status.pointee = .haveData; return input
        }
        if error != nil || out.frameLength == 0 { return nil }
        return out
    }
}

/// Stateful hardware-format → 16 kHz mono Int16 converter for the capture tap.
///
/// One instance per capture session: `AVAudioConverter` carries the resampler's
/// filter state, so consecutive 100 ms buffers convert without losing the tail
/// (a fresh converter per buffer drops ~240 of every 1600 output frames).
/// Not thread-safe by design — it is owned by the single audio render thread.
public final class PcmDownconverter {
    private let source: AVAudioFormat
    private let converter: AVAudioConverter?
    /// `AVAudioConverter` is terminal after `.endOfStream`: feeding it again is
    /// undefined. One flush per instance, and `convert` goes quiet afterwards.
    private var flushed = false
    /// Safety cap on the drain loop. The real tail is 240 frames at 48 kHz and
    /// 120 at 44.1 kHz — one chunk of headroom is already 6× that — so this
    /// bound is unreachable in correct operation and exists only so a converter
    /// that answered `.haveData` with zero frames cannot spin the session
    /// thread, which is what calls this (from `MicCapture.stop`).
    private static let flushIterationCap = 10

    public init?(from source: AVAudioFormat) {
        self.source = source
        if PcmFormat.isCanonical(source) {
            self.converter = nil
        } else {
            guard let c = AVAudioConverter(from: source, to: PcmFormat.canonical) else { return nil }
            self.converter = c
        }
    }

    /// The resampler's held-back tail, at end of stream.
    ///
    /// The filter delay this recovers is the same 240 frames (15 ms at 48 kHz;
    /// 120 / 7.5 ms at 44.1 kHz) that `PcmFormatTests` already pins as MISSING
    /// from a streamed conversion: 10 × 100 ms of 48 kHz input yields 15,760 of
    /// 16,000 frames, and until now the remainder died with the converter when
    /// `MicCapture.stop()` set it to nil. It is word-final audio — the end of
    /// the last syllable the user spoke — so it is worth one call.
    ///
    /// The "roomy output buffer drops pending input" hazard documented on
    /// `outputCapacity` does not apply here: at flush time there is no pending
    /// input to drop, only filter state to push out.
    public func flush() -> Data {
        guard let converter, !flushed else { return Data() }
        flushed = true
        var out = Data()
        for _ in 0..<Self.flushIterationCap {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: PcmFormat.canonical,
                                                frameCapacity: PcmFormat.chunkFrames) else { break }
            var error: NSError?
            let status = converter.convert(to: buffer, error: &error) { _, status in
                // No more input will ever arrive; this is the whole point.
                status.pointee = .endOfStream
                return nil
            }
            if error != nil { break }
            if buffer.frameLength > 0 { out.append(PcmFormat.int16Data(from: buffer)) }
            guard status == .haveData else { break }
            if out.count >= Int(PcmFormat.chunkFrames) * PcmFormat.bytesPerFrame { break }
        }
        return out
    }

    /// Converted bytes for this buffer, or empty on a conversion error.
    public func convert(_ buffer: AVAudioPCMBuffer) -> Data {
        // Terminal after a flush: the converter has been told the stream ended
        // and must not be fed again (a future refactor that reused the instance
        // would otherwise corrupt audio silently).
        guard !flushed else { return Data() }
        guard let converter else { return PcmFormat.int16Data(from: buffer) }
        let ratio = PcmFormat.sampleRate / source.sampleRate
        let capacity = PcmFormat.outputCapacity(inputFrames: buffer.frameLength, ratio: ratio)
        guard let out = AVAudioPCMBuffer(pcmFormat: PcmFormat.canonical, frameCapacity: capacity) else {
            return Data()
        }
        var served = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if served { status.pointee = .noDataNow; return nil }
            served = true; status.pointee = .haveData; return buffer
        }
        guard error == nil else { return Data() }
        return PcmFormat.int16Data(from: out)
    }
}
