#if os(macOS)
import Foundation
import AVFoundation
import WispritKit

/// Push-to-talk microphone capture, ported from `wisprit/audio.py`.
///
/// The analyzer layer above is platform-neutral; only this file is gated, so an
/// iOS shell can supply its own capture (the mic lives in the container app —
/// keyboard extensions cannot open one) and reuse everything else unchanged.
///
/// Privacy: the engine is fully stopped and the tap removed on `stop()`, so the
/// macOS orange microphone indicator goes dark between utterances — the mic is
/// live only while the hotkey is held.
public final class MicCapture: @unchecked Sendable {
    private let log = WLog.logger("engine.capture")
    private let onChunk: @Sendable (Data) -> Void
    private let engine = AVAudioEngine()
    private let lock = UnfairLock()
    private var active = false
    private var levelValue: Float = 0
    /// Owned by the render thread for the lifetime of one capture session; a
    /// per-buffer converter would drop the resampler tail on every chunk.
    private var downconverter: PcmDownconverter?

    /// `onChunk` receives 16 kHz mono Int16 bytes on the render thread — it must
    /// not block (`AsrManager.feed` is the intended sink and does not).
    public init(onChunk: @escaping @Sendable (Data) -> Void) {
        self.onChunk = onChunk
    }

    /// Normalized input level 0…1 for the pill's meter.
    public var level: Float {
        lock.lock(); defer { lock.unlock() }
        return levelValue
    }

    public var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return active
    }

    /// Returns false when the input could not be opened (mic permission denied,
    /// no input device); the session then aborts the utterance cleanly.
    @discardableResult
    public func start() -> Bool {
        lock.lock(); active = true; levelValue = 0; lock.unlock()

        let input = engine.inputNode
        let hardware = input.outputFormat(forBus: 0)
        guard hardware.sampleRate > 0, hardware.channelCount > 0 else {
            log.error("no usable audio input device")
            lock.lock(); active = false; lock.unlock()
            return false
        }
        // Tap in the hardware's own format and down-convert; installing a tap with
        // a mismatched format throws at runtime on some devices.
        guard let converter = PcmDownconverter(from: hardware) else {
            log.error("cannot convert \(hardware) to 16 kHz mono Int16")
            lock.lock(); active = false; lock.unlock()
            return false
        }
        downconverter = converter
        let tapFrames = AVAudioFrameCount(hardware.sampleRate / 10)   // 100 ms
        input.installTap(onBus: 0, bufferSize: tapFrames, format: hardware) { [weak self] buffer, _ in
            guard let self, self.isActive else { return }
            let pcm = converter.convert(buffer)
            guard !pcm.isEmpty else { return }
            let l = PcmFormat.level(of: pcm)
            self.lock.lock(); self.levelValue = l; self.lock.unlock()
            self.onChunk(pcm)
        }
        do {
            engine.prepare()
            try engine.start()
            return true
        } catch {
            log.error("could not start audio input (mic permission?): \(error.localizedDescription, privacy: .public)")
            input.removeTap(onBus: 0)
            lock.lock(); active = false; lock.unlock()
            return false
        }
    }

    /// Stop capture and fully release the input (mic indicator goes dark).
    public func stop() {
        lock.lock(); active = false; levelValue = 0; lock.unlock()
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        engine.reset()
        downconverter = nil
    }
}
#endif
