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
///
/// **2026-11-06: the engine is no longer the default.** On macOS 27 the engine's
/// input node opens a private default-device AGGREGATE (input + output, clocked
/// by the output, its AUHAL cached across engine instances) rather than the
/// microphone — see `HalInputUnit` and docs/eval/AUDIT-2026-11-06.md for what
/// that cost. `CaptureBackend.hal` (the default) opens an input-only AUHAL on
/// the actual device instead, fresh per `start()`, which restores the
/// fresh-per-utterance guarantee this type was built around one level lower.
/// The engine path stays, byte-for-byte, as `capture_backend = engine` and as
/// the automatic fallback when the AUHAL cannot open.
public final class MicCapture: @unchecked Sendable {
    /// Which Core Audio path opens the microphone. Evaluated per `start()`.
    public enum Backend: String, Sendable, CaseIterable {
        /// Input-only AUHAL on the resolved device. Default.
        case hal
        /// `AVAudioEngine` input node + tap — the pre-2026-11 path, kept as an
        /// opt-out and as the fallback when the AUHAL will not open.
        case engine
    }

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
    /// Rebuilt by every engine-backend `start()` — see the type comment. Never
    /// reused. nil while the HAL backend owns the session.
    private var engine: AVAudioEngine?
    /// The HAL backend's unit for the current session; nil otherwise.
    private var halUnit: HalInputUnit?
    /// Where the HAL backend's chunks are converted, metered and handed to
    /// `onChunk` — serial, so capture order is delivery order.
    private let deliveryQueue = DispatchQueue(label: "wisprit.capture.delivery",
                                              qos: .userInteractive)
    /// The backend the current (or most recent) session actually ran on —
    /// after any fallback.
    private var backendValue: Backend?
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
    /// mic-live → first tap buffer, voiced or not. On a classic-Bluetooth mic
    /// this is the SCO bring-up made visible: the radio can spend 1–3 s
    /// negotiating before the first sample exists, and nothing upstream can
    /// tell "slow link" from "silent user" without it.
    private var firstChunkMsValue: Double?
    /// The device the AUHAL actually landed on for this session (post-pin) and
    /// the input-chain rate it opened at — the negotiated truth, as opposed to
    /// the rate the device advertised before the mic was live.
    private var captureDeviceValue: InputDeviceInfo?
    private var negotiatedRateHzValue: Double?
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
    /// ever returns an id, and only when opening the default would force a
    /// Bluetooth headset into HFP or the default already is a narrowband
    /// classic-Bluetooth mic.
    public var preferredDevice: (@Sendable () -> AudioDeviceID?)?

    /// The backend to open the next session on, asked at every `start()`.
    /// nil (the default) means `.hal`. `capture_backend = engine` is the
    /// user-facing opt-out; the parachute and miclab set it explicitly.
    public var backend: (@Sendable () -> Backend)?

    /// The backend the current (or most recent) session actually opened on —
    /// `.engine` when a `.hal` request fell back. nil before the first start.
    public var activeBackend: Backend? {
        lock.lock(); defer { lock.unlock() }
        return backendValue
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

    /// mic-live → first delivered chunk, in ms; nil when none ever arrived.
    /// Unlike `firstVoicedMs` this stops on ANY buffer, so it measures the
    /// capture path (SCO bring-up, HAL wake), not the speaker.
    public var firstChunkMs: Double? {
        lock.lock(); defer { lock.unlock() }
        return firstChunkMsValue
    }

    /// The device this (or the most recent) session actually captured from,
    /// resolved from the AUHAL after pinning — not the system default, not the
    /// pre-open advertisement. nil before the first `start()`.
    public var captureDevice: InputDeviceInfo? {
        lock.lock(); defer { lock.unlock() }
        return captureDeviceValue
    }

    /// The input-chain sample rate the session opened at. For a classic-BT
    /// headset this is the negotiated HFP truth (8 k CVSD / 16 k mSBC), which
    /// the advertised nominal rate routinely lies about until the link is up.
    public var negotiatedRateHz: Double? {
        lock.lock(); defer { lock.unlock() }
        return negotiatedRateHzValue
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
        // Fast path BEFORE the transition lock: a start already in flight (the
        // prestart hook's, at key-down) owns this session, and the session
        // thread's own `begin()` must not queue behind it — opening a
        // Bluetooth input can take as long as its SCO link does, and the
        // session thread waiting on that is how November's key-ups were
        // handled seconds late. A start that then fails leaves a starved
        // utterance, which is exactly what it would have been anyway.
        if isActive { return true }
        transitionLock.lock()
        defer { transitionLock.unlock() }
        if isActive { return true }

        lock.lock()
        active = true
        levelValue = 0
        deliveredBytes = 0
        reconfigured = false
        startedAtNs = 0
        firstVoicedMsValue = nil
        firstChunkMsValue = nil
        captureDeviceValue = nil
        negotiatedRateHzValue = nil
        recentMeanSquares.removeAll()
        floorMeanSquare = nil
        backendValue = nil
        lock.unlock()

        let requested = preferredDevice?()
        if (backend?() ?? .hal) == .hal {
            if startHal(requested: requested) { return true }
            // Fall back rather than fail the press: the engine path is what
            // every build before 2026-11 ran, so a device the AUHAL refuses
            // still dictates exactly as it used to.
            log.error("input-only capture could not open; falling back to the engine path for this utterance")
        }
        return startEngine()
    }

    /// The HAL backend: an input-only AUHAL on the pinned device, else the
    /// system default input resolved NOW — never an aggregate.
    private func startHal(requested: AudioDeviceID?) -> Bool {
        guard let deviceID = requested ?? InputDeviceProbe.defaultInputID() else {
            log.error("no default audio input device")
            return false
        }
        let unit = HalInputUnit(
            device: deviceID,
            deliveryQueue: deliveryQueue,
            deliver: { [weak self] buffer in self?.process(buffer) },
            onReconfigured: { [weak self] in self?.noteReconfigured() })
        do {
            try unit.prepare()
        } catch {
            log.error("cannot prepare input-only capture on device \(deviceID): \(String(describing: error), privacy: .public)")
            return false
        }
        guard let format = unit.format, let converter = PcmDownconverter(from: format) else {
            log.error("cannot convert the device format to 16 kHz mono Int16")
            return false
        }
        converterLock.lock(); downconverter = converter; converterLock.unlock()
        // The device we opened IS the device we capture from — the attribution
        // is exact by construction, which the engine path can no longer say.
        let info = InputDeviceProbe.info(of: deviceID)
        lock.lock()
        captureDeviceValue = info
        negotiatedRateHzValue = format.sampleRate
        halUnit = unit
        backendValue = .hal
        lock.unlock()
        do {
            try unit.start()
        } catch {
            log.error("could not start input-only capture (mic permission?): \(String(describing: error), privacy: .public)")
            unit.stop()
            lock.lock(); halUnit = nil; backendValue = nil; lock.unlock()
            converterLock.lock(); downconverter = nil; converterLock.unlock()
            return false
        }
        lock.lock()
        startedAtNs = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        lock.unlock()
        return true
    }

    /// The pre-2026-11 path, unchanged in behaviour. Leaves `active` false on
    /// failure, like it always did.
    private func startEngine() -> Bool {
        // A fresh engine per utterance: the previous one may have been stopped
        // by the system on a device change, with its input chain still wired for
        // the old sample rate.
        let engine = AVAudioEngine()
        lock.lock()
        self.engine = engine
        backendValue = .engine
        lock.unlock()

        let input = engine.inputNode
        // Device pinning BEFORE the format is read: the AUHAL's current device
        // decides what `outputFormat(forBus:)` reports, and the tap must be
        // installed in the format of the device we actually end up on. A
        // non-zero OSStatus is not fatal — we fall back to the default input,
        // which is exactly today's behaviour.
        let pinned = pinPreferredDevice(on: input)
        let hardware = input.outputFormat(forBus: 0)
        guard hardware.sampleRate > 0, hardware.channelCount > 0 else {
            log.error("no usable audio input device")
            lock.lock(); active = false; self.engine = nil; backendValue = nil; lock.unlock()
            return false
        }
        // Which device the AUHAL actually landed on (post-pin), and the rate
        // the input chain opened at. Read here, once, because this is the only
        // moment the negotiated truth exists: before `start()` the device
        // advertises whatever it likes, and after `stop()` the link is gone.
        //
        // Unpinned on macOS 27 the AUHAL lands on the engine's private
        // default-device aggregate, whose name and transport (`aggregate`) say
        // nothing about the microphone — every November row read that way and
        // hid a Bluetooth headset. The aggregate's input IS the default input,
        // so that is the honest attribution; the rate stays the chain's own.
        let landed = resolvedDevice(of: input).map { InputDeviceProbe.info(of: $0) }
        let device = Self.attribution(landed: landed, pinned: pinned,
                                      defaultInput: { InputDeviceProbe.defaultInput() })
        lock.lock()
        captureDeviceValue = device
        negotiatedRateHzValue = hardware.sampleRate
        lock.unlock()
        // Tap in the hardware's own format and down-convert; installing a tap with
        // a mismatched format throws at runtime on some devices.
        guard let converter = PcmDownconverter(from: hardware) else {
            log.error("cannot convert \(hardware) to 16 kHz mono Int16")
            lock.lock(); active = false; self.engine = nil; backendValue = nil; lock.unlock()
            return false
        }
        converterLock.lock(); downconverter = converter; converterLock.unlock()

        // Observe THIS engine only. The handler must not deallocate the engine —
        // it runs on an internal dispatch queue and would deadlock (AVAudioEngine.h).
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            self?.noteReconfigured()
        }

        let tapFrames = AVAudioFrameCount(hardware.sampleRate / 10)   // 100 ms
        input.installTap(onBus: 0, bufferSize: tapFrames, format: hardware) { [weak self] buffer, _ in
            self?.process(buffer)
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
            lock.lock(); active = false; self.engine = nil; backendValue = nil; lock.unlock()
            return false
        }
    }

    /// One captured buffer → canonical PCM, meter, telemetry, `onChunk`.
    /// Both backends deliver here: the engine from its tap thread, the HAL
    /// backend from `deliveryQueue` — never the real-time IO thread.
    private func process(_ buffer: AVAudioPCMBuffer) {
        guard isActive else { return }
        // The converter is stateful and `stop()` drains it; taking the lock
        // across BOTH the conversion and the delivery is what keeps the
        // drained tail strictly after this chunk instead of interleaved
        // with it (the sink is lock-only by contract, so this cannot stall
        // the HAL thread on anything but our own flush).
        converterLock.lock()
        defer { converterLock.unlock() }
        guard let converter = downconverter else { return }
        let pcm = converter.convert(buffer)
        guard !pcm.isEmpty else { return }
        // One pass over the samples; the meter level and the telemetry
        // pair below are all derived from this chunk's mean-square.
        let meanSquare = PcmFormat.meanSquare(of: pcm)
        let l = PcmFormat.level(fromMeanSquare: meanSquare)
        lock.lock()
        levelValue = l
        deliveredBytes += pcm.count
        // first_chunk_ms: ANY buffer stops this clock — the capture path's
        // own latency (SCO bring-up, HAL wake), independent of the speaker.
        if firstChunkMsValue == nil, startedAtNs > 0 {
            let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            firstChunkMsValue = Double(now - startedAtNs) / 1_000_000.0
        }
        // first_voiced_ms: the first chunk that cleared the voiced
        // threshold stops the clock (R4's clipping-exposure metric).
        if firstVoicedMsValue == nil, startedAtNs > 0,
           l >= SpeechAnalyzerEngine.voicedPeakThreshold {
            let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            firstVoicedMsValue = Double(now - startedAtNs) / 1_000_000.0
        }
        // noise_floor: minimum over sliding ~300 ms (3-chunk) windows,
        // averaged in mean-square space where averaging is legitimate.
        recentMeanSquares.append(meanSquare)
        if recentMeanSquares.count == 3 {
            let window = (recentMeanSquares[0] + recentMeanSquares[1]
                          + recentMeanSquares[2]) / 3.0
            if floorMeanSquare.map({ window < $0 }) ?? true {
                floorMeanSquare = window
            }
            recentMeanSquares.removeFirst()
        }
        lock.unlock()
        onChunk(pcm)
    }

    /// The capture died under the session (device gone, format changed).
    private func noteReconfigured() {
        lock.lock()
        let first = !reconfigured
        reconfigured = true
        lock.unlock()
        guard first else { return }
        log.error("audio hardware reconfigured mid-utterance; this capture is dead and is rebuilt on the next press")
        // Tell the layer above, so the utterance is known-bad rather than
        // mysteriously empty (or, worse, silently truncated with text).
        onConfigurationChange?()
    }

    /// Stop capture and fully release the input (mic indicator goes dark).
    ///
    /// A no-op when no session is open — never started, already stopped, or a
    /// start that failed. The prestart hook, the session and the parachute
    /// all call this defensively, and until 2026-11-06 every redundant call
    /// logged "microphone delivered no audio" for a capture that never opened:
    /// 2–4 false alarms per November utterance, which is why the wedged-mic
    /// diagnostic stopped meaning anything.
    public func stop() {
        transitionLock.lock()
        defer { transitionLock.unlock() }

        lock.lock()
        guard active else { lock.unlock(); return }
        let hal = halUnit
        let engine = self.engine
        lock.unlock()

        if let hal {
            // IO stops first, then the partial chunk is delivered and every
            // queued chunk processed — all while `active` is still true, so
            // none of it is dropped by `process`'s guard.
            hal.stop()
        }

        lock.lock()
        active = false
        levelValue = 0
        halUnit = nil
        self.engine = nil
        let silent = deliveredBytes == 0
        let changed = reconfigured
        lock.unlock()

        if let engine {
            removeObserver()
            engine.inputNode.removeTap(onBus: 0)
            if engine.isRunning { engine.stop() }
        }
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
        converterLock.lock(); downconverter = nil; converterLock.unlock()
        if silent && !changed {
            // The capture reported a healthy start yet no buffer ever arrived.
            // This is what a wedged input chain looks like from up here, and it
            // used to reach the user as a bare "nothing recognized". On the HAL
            // backend it is also what a Bluetooth mic whose SCO link never came
            // up looks like — the aggregate used to paper over that with zeros.
            log.error("microphone delivered no audio for this utterance (input wedged or muted)")
        }
    }

    /// Who the engine path should say it captured from. Pure, for the tests.
    ///
    /// An unpinned engine on macOS 27 lands on its private
    /// `CADefaultDeviceAggregate-<pid>-N`; the aggregate's input sub-device is
    /// the system default input, so that is the device the row names. A pinned
    /// session, or any non-aggregate device, is reported as landed.
    static func attribution(landed: InputDeviceInfo?, pinned: Bool,
                            defaultInput: () -> InputDeviceInfo?) -> InputDeviceInfo? {
        guard let landed, !pinned,
              landed.transport == kAudioDeviceTransportTypeAggregate,
              landed.name.hasPrefix(defaultDeviceAggregatePrefix),
              let underlying = defaultInput()
        else { return landed }
        return underlying
    }

    /// The name Core Audio gives the engine's private default-device aggregate.
    static let defaultDeviceAggregatePrefix = "CADefaultDeviceAggregate"

    /// `input_device_policy = prefer_builtin`, applied to THIS engine's AUHAL.
    /// Returns whether the node now sits on a pinned device.
    ///
    /// Best-effort by design: any failure logs and leaves the node on the
    /// system default input, which is the behaviour of every build before the
    /// policy existed. It never overrides a deliberate USB/external choice —
    /// the closure only returns an id when opening the default input would
    /// force Bluetooth headphones into HFP, or the default already is a
    /// narrowband classic-Bluetooth mic.
    ///
    /// Measured 2026-11-06 (macOS 27): pinning an engine's input node posts an
    /// `AVAudioEngineConfigurationChange` of its own on every pinned start —
    /// one more reason the HAL backend is the default.
    @discardableResult
    private func pinPreferredDevice(on input: AVAudioInputNode) -> Bool {
        guard let preferredDevice, var deviceID = preferredDevice() else { return false }
        guard let unit = input.audioUnit else {
            log.error("cannot pin input device: the input node has no audio unit")
            return false
        }
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global, 0, &deviceID,
                                          UInt32(MemoryLayout<AudioDeviceID>.size))
        if status != noErr {
            log.error("could not pin input device \(deviceID) (OSStatus \(status)); using the system default")
            return false
        }
        log.info("input pinned to device \(deviceID) by input_device_policy")
        return true
    }

    /// The device the input node's AUHAL is actually on — the system default
    /// unless `pinPreferredDevice` moved it. Best-effort like the pin itself.
    private func resolvedDevice(of input: AVAudioInputNode) -> AudioDeviceID? {
        guard let unit = input.audioUnit else { return nil }
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global, 0, &deviceID, &size)
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    private func removeObserver() {
        guard let observer else { return }
        NotificationCenter.default.removeObserver(observer)
        self.observer = nil
    }
}
#endif
