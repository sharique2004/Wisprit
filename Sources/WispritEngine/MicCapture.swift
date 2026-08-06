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
///
/// **A capture session never outlives one utterance (2026-08-05 incident).**
/// The original port kept ONE `AVAudioEngine` for the app's lifetime and only
/// re-installed the tap per utterance. That strands the user permanently the
/// first time the default input device changes, and it did: metrics rows
/// 1785971800–1785971842 show utterances 1–2 succeeding, then five consecutive
/// `outcome=empty, finalize_ms≈1500`. The system log for that window shows the
/// input render format going `1 ch, 48000 Hz` (both successes) →
/// `1 ch, 24000 Hz` (every failure) as a Bluetooth input became the default
/// device between 16:16:32 and 16:16:35. `AVAudioEngine.h` documents exactly
/// this: on a hardware channel-count/sample-rate change the engine "stops
/// itself", the nodes "remain attached and connected with previously set
/// formats", and "the app must reestablish connections … in an input node
/// chain, connections must follow the hardware sample rate". A reused engine
/// never reestablishes them, so the tap silently stops delivering buffers —
/// forever, because nothing in the old code could ever rebuild the graph.
/// A fresh `AVAudioEngine` per `start()` establishes the input chain against
/// the format the hardware has *now*, which is the only state that is correct
/// by construction.
public final class MicCapture: @unchecked Sendable {
    private let log = WLog.logger("engine.capture")
    private let onChunk: @Sendable (Data) -> Void
    private let lock = UnfairLock()
    /// Rebuilt by every `start()` — see the type comment. Never reused.
    private var engine = AVAudioEngine()
    private var observer: NSObjectProtocol?
    private var active = false
    private var levelValue: Float = 0
    private var deliveredBytes = 0
    private var reconfigured = false
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

    /// Bytes of 16 kHz mono Int16 handed to `onChunk` during the current (or
    /// most recent) session. Zero after a held key means the microphone
    /// delivered nothing — a capture fault, NOT a silent user.
    public var capturedBytes: Int {
        lock.lock(); defer { lock.unlock() }
        return deliveredBytes
    }

    /// The audio hardware was reconfigured under this session. Per
    /// `AVAudioEngine.h` the engine stops itself and keeps the old formats, so
    /// any audio after that point is lost; the utterance is known-bad rather
    /// than mysteriously empty.
    public var sawConfigurationChange: Bool {
        lock.lock(); defer { lock.unlock() }
        return reconfigured
    }

    /// Returns false when the input could not be opened (mic permission denied,
    /// no input device); the session then aborts the utterance cleanly.
    @discardableResult
    public func start() -> Bool {
        // A fresh engine per utterance: the previous one may have been stopped
        // by the system on a device change, with its input chain still wired for
        // the old sample rate.
        let engine = AVAudioEngine()
        lock.lock()
        self.engine = engine
        active = true
        levelValue = 0
        deliveredBytes = 0
        reconfigured = false
        lock.unlock()

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

        // Observe THIS engine only. The handler must not deallocate the engine —
        // it runs on an internal dispatch queue and would deadlock (AVAudioEngine.h).
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.lock.lock(); self.reconfigured = true; self.lock.unlock()
            self.log.error("audio hardware reconfigured mid-utterance; this capture is dead and the engine is rebuilt on the next press")
        }

        let tapFrames = AVAudioFrameCount(hardware.sampleRate / 10)   // 100 ms
        input.installTap(onBus: 0, bufferSize: tapFrames, format: hardware) { [weak self] buffer, _ in
            guard let self, self.isActive else { return }
            let pcm = converter.convert(buffer)
            guard !pcm.isEmpty else { return }
            let l = PcmFormat.level(of: pcm)
            self.lock.lock()
            self.levelValue = l
            self.deliveredBytes += pcm.count
            self.lock.unlock()
            self.onChunk(pcm)
        }
        do {
            engine.prepare()
            try engine.start()
            return true
        } catch {
            log.error("could not start audio input (mic permission?): \(error.localizedDescription, privacy: .public)")
            input.removeTap(onBus: 0)
            removeObserver()
            lock.lock(); active = false; lock.unlock()
            return false
        }
    }

    /// Stop capture and fully release the input (mic indicator goes dark).
    public func stop() {
        lock.lock()
        active = false
        levelValue = 0
        let engine = self.engine
        let silent = deliveredBytes == 0
        let changed = reconfigured
        lock.unlock()

        removeObserver()
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        downconverter = nil
        if silent && !changed {
            // The engine reported a healthy start yet no buffer ever arrived.
            // This is what a wedged input chain looks like from up here, and it
            // used to reach the user as a bare "nothing recognized".
            log.error("microphone delivered no audio for this utterance (input wedged or muted)")
        }
    }

    private func removeObserver() {
        guard let observer else { return }
        NotificationCenter.default.removeObserver(observer)
        self.observer = nil
    }
}
#endif
