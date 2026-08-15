#if os(macOS)
import AudioToolbox
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
    /// The hardware reconfigured under this session. Fired on the notification
    /// centre's own queue, so it must be lock-only cheap (`AsrManager
    /// .noteConfigurationChange` is).
    private let onConfigurationChange: (@Sendable () -> Void)?
    private let lock = UnfairLock()
    /// Serializes whole `start()`/`stop()` bodies against each other.
    ///
    /// R33 opens the mic from the hotkey tap's prestart queue at key-down while
    /// the session thread may still be finishing the previous utterance, so the
    /// two lifecycle calls genuinely race now. Without this a second `start()`
    /// would overwrite `self.engine` and strand a running tap on the old one.
    /// Deliberately NOT the hot-path `lock`: this one is held across ~50 ms of
    /// AVAudioEngine work and the render thread must never wait on it.
    private let transitionLock = NSLock()
    /// Held across the tap's convert+deliver and across `stop()`'s flush, so
    /// the end-of-stream tail can never interleave with — or overtake — a
    /// chunk that was already mid-conversion on the render thread.
    private let converterLock = UnfairLock()
    /// Rebuilt by every `start()` — see the type comment. Never reused.
    private var engine = AVAudioEngine()
    private var observer: NSObjectProtocol?
    private var active = false
    private var levelValue: Float = 0
    private var deliveredBytes = 0
    private var reconfigured = false
    // R4 telemetry, per capture session (reset by `start()`, stable after
    // `stop()` so the session thread can read them at finalize).
    /// Nanosecond stamp when `start()` went live — the `first_voiced_ms` epoch.
    private var startedAtNs: UInt64 = 0
    private var firstVoicedMsValue: Double?
    /// Mean-squares of the two most recent chunks (the sliding window's tail).
    private var recentMeanSquares: [Double] = []
    /// Smallest 3-chunk (~300 ms) window mean-square seen this session.
    private var floorMeanSquare: Double?
    /// Owned by the render thread for the lifetime of one capture session; a
    /// per-buffer converter would drop the resampler tail on every chunk.
    private var downconverter: PcmDownconverter?

    /// `onChunk` receives 16 kHz mono Int16 bytes on the render thread — it must
    /// not block (`AsrManager.feed` is the intended sink and does not).
    ///
    /// `onConfigurationChange` fires once per capture session when the audio
    /// hardware is reconfigured under it. Until it existed, the fact was
    /// readable only through `sawConfigurationChange`, which nothing outside
    /// this file ever read — so the 2026-08-05 failure class stayed invisible
    /// to the rescue policy, the empty-reason classifier and `metrics.log`.
    public init(onChunk: @escaping @Sendable (Data) -> Void,
                onConfigurationChange: (@Sendable () -> Void)? = nil) {
        self.onChunk = onChunk
        self.onConfigurationChange = onConfigurationChange
    }

    /// Pin capture to a specific Core Audio input device, evaluated at every
    /// `start()`. nil (the default, and a nil answer) keeps the system default
    /// input — `input_device_policy = prefer_builtin` is the only thing that
    /// ever returns an id, and only when the default input is a narrowband
    /// classic-Bluetooth mic.
    public var preferredDevice: (@Sendable () -> AudioDeviceID?)?

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

    /// Quietest ~300 ms window of the current (or most recent) session on the
    /// meter's own scale — RMS × 4, clamped, the same statistic family as
    /// `peak_level`, so the (peak, floor) pair reads as an SNR proxy on one
    /// axis (measurement §7). nil until three chunks have been delivered.
    public var noiseFloor: Double? {
        lock.lock(); defer { lock.unlock() }
        return floorMeanSquare.map { Double(PcmFormat.level(fromMeanSquare: $0)) }
    }

    /// mic-live → first chunk whose metered level cleared the voiced threshold,
    /// in ms; nil when no chunk ever did. The clipping-exposure clock (acoustic
    /// §3 fix 2): its live p5 decides whether cold-start head-loss was ever
    /// real exposure. The threshold's job here is measurement, not judgment —
    /// R26 recalibrates the classification floor separately, from telemetry.
    public var firstVoicedMs: Double? {
        lock.lock(); defer { lock.unlock() }
        return firstVoicedMsValue
    }

    /// Returns false when the input could not be opened (mic permission denied,
    /// no input device); the session then aborts the utterance cleanly.
    ///
    /// **Idempotent.** R33 starts the mic at key-down from the hotkey hook and
    /// the session's `begin()` starts it again a few ms later; the second call
    /// must be a no-op rather than a restart, because a restart would reset
    /// `startedAtNs`/`firstVoicedMs`/`floorMeanSquare`/`deliveredBytes` — the
    /// R4 acoustic pair the accuracy audit reads — and would strand the tap
    /// that is already delivering the utterance's head.
    @discardableResult
    public func start() -> Bool {
        transitionLock.lock()
        defer { transitionLock.unlock() }
        if isActive { return true }

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
        startedAtNs = 0
        firstVoicedMsValue = nil
        recentMeanSquares.removeAll()
        floorMeanSquare = nil
        lock.unlock()

        let input = engine.inputNode
        // Device pinning BEFORE the format is read: the AUHAL's current device
        // decides what `outputFormat(forBus:)` reports, and the tap must be
        // installed in the format of the device we actually end up on. A
        // non-zero OSStatus is not fatal — we fall back to the default input,
        // which is exactly today's behaviour.
        pinPreferredDevice(on: input)
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
            // Tell the layer above, so the utterance is known-bad rather than
            // mysteriously empty (or, worse, silently truncated with text).
            self.onConfigurationChange?()
        }

        let tapFrames = AVAudioFrameCount(hardware.sampleRate / 10)   // 100 ms
        input.installTap(onBus: 0, bufferSize: tapFrames, format: hardware) { [weak self] buffer, _ in
            guard let self, self.isActive else { return }
            // The converter is stateful and `stop()` drains it; taking the lock
            // across BOTH the conversion and the delivery is what keeps the
            // drained tail strictly after this chunk instead of interleaved
            // with it (the sink is lock-only by contract, so this cannot stall
            // the HAL thread on anything but our own flush).
            self.converterLock.lock()
            let pcm = converter.convert(buffer)
            guard !pcm.isEmpty else { self.converterLock.unlock(); return }
            // One pass over the samples; the meter level and the telemetry
            // pair below are all derived from this chunk's mean-square.
            let meanSquare = PcmFormat.meanSquare(of: pcm)
            let l = PcmFormat.level(fromMeanSquare: meanSquare)
            self.lock.lock()
            self.levelValue = l
            self.deliveredBytes += pcm.count
            // first_voiced_ms: the first chunk that cleared the voiced
            // threshold stops the clock (R4's clipping-exposure metric).
            if self.firstVoicedMsValue == nil, self.startedAtNs > 0,
               l >= SpeechAnalyzerEngine.voicedPeakThreshold {
                let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                self.firstVoicedMsValue = Double(now - self.startedAtNs) / 1_000_000.0
            }
            // noise_floor: minimum over sliding ~300 ms (3-chunk) windows,
            // averaged in mean-square space where averaging is legitimate.
            self.recentMeanSquares.append(meanSquare)
            if self.recentMeanSquares.count == 3 {
                let window = (self.recentMeanSquares[0] + self.recentMeanSquares[1]
                              + self.recentMeanSquares[2]) / 3.0
                if self.floorMeanSquare.map({ window < $0 }) ?? true {
                    self.floorMeanSquare = window
                }
                self.recentMeanSquares.removeFirst()
            }
            self.lock.unlock()
            self.onChunk(pcm)
            self.converterLock.unlock()
        }
        do {
            engine.prepare()
            try engine.start()
            // The `first_voiced_ms` epoch is mic-LIVE — the HAL I/O proc is
            // running from here — not key-down; the ~45–55 ms start cost is
            // the hard privacy floor and is accounted separately (acoustic §3).
            lock.lock()
            startedAtNs = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            lock.unlock()
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
        transitionLock.lock()
        defer { transitionLock.unlock() }

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
        // The resampler's held-back tail — the last 15 ms (48 kHz) of the
        // utterance, which used to die with the converter one line below. Only
        // for a session that actually delivered audio: draining a converter
        // that was never fed could emit priming zeros, and `deliveredBytes`
        // going non-zero would mask the wedged-mic diagnostic under it.
        if !silent {
            converterLock.lock()
            let tail = downconverter?.flush() ?? Data()
            converterLock.unlock()
            if !tail.isEmpty {
                lock.lock(); deliveredBytes += tail.count; lock.unlock()
                // The analyzer is still installed (the session stops audio
                // before it finalizes), so this reaches both retention and the
                // live engine, exactly like any other chunk.
                onChunk(tail)
            }
        }
        downconverter = nil
        if silent && !changed {
            // The engine reported a healthy start yet no buffer ever arrived.
            // This is what a wedged input chain looks like from up here, and it
            // used to reach the user as a bare "nothing recognized".
            log.error("microphone delivered no audio for this utterance (input wedged or muted)")
        }
    }

    /// `input_device_policy = prefer_builtin`, applied to THIS engine's AUHAL.
    ///
    /// Best-effort by design: any failure logs and leaves the node on the
    /// system default input, which is the behaviour of every build before the
    /// policy existed. It never overrides a deliberate device choice — the
    /// closure only returns an id when the default input is a narrowband
    /// classic-Bluetooth mic.
    private func pinPreferredDevice(on input: AVAudioInputNode) {
        guard let preferredDevice, var deviceID = preferredDevice() else { return }
        guard let unit = input.audioUnit else {
            log.error("cannot pin input device: the input node has no audio unit")
            return
        }
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global, 0, &deviceID,
                                          UInt32(MemoryLayout<AudioDeviceID>.size))
        if status != noErr {
            log.error("could not pin input device \(deviceID) (OSStatus \(status)); using the system default")
        } else {
            log.info("input pinned to device \(deviceID) by input_device_policy")
        }
    }

    private func removeObserver() {
        guard let observer else { return }
        NotificationCenter.default.removeObserver(observer)
        self.observer = nil
    }
}
#endif
