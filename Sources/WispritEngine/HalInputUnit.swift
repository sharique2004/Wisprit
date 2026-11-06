#if os(macOS)
import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation
import WispritKit

/// An input-only AUHAL on one explicit Core Audio device — the capture
/// backend `MicCapture` uses by default since 2026-11-06.
///
/// **Why not `AVAudioEngine` (docs/eval/AUDIT-2026-11-06.md).** On macOS 27 an
/// engine's input node no longer opens the microphone: it opens a private
/// `CADefaultDeviceAggregate-<pid>-N` that glues the default INPUT to the
/// default OUTPUT, clocked by the output, and AVFoundation caches the AUHAL
/// behind it across engine instances. Every November `metrics.log` row rode
/// that aggregate, and the system log shows what it costs:
///
/// - with Bluetooth headphones as the output, a second engine pinned to the
///   built-in mic (the dual-capture parachute) sat ~3.0 s per utterance in
///   `SetBluetoothAudioFormatAndWait(...): Waiting for format change timed
///   out` — on the session thread, so key-ups were processed seconds late and
///   the prestart hook stopped primaries that had delivered nothing;
/// - the aggregate zero-fills its input until the input side runs, so a cold
///   Bluetooth (SCO) mic looked like a quiet user (`noise_floor` 0.0 on 21 of
///   22 November rows) and `first_chunk_ms` stopped measuring SCO bring-up;
/// - the device attribution read `CADefaultDeviceAggregate-…`/`aggregate`,
///   which hid the Bluetooth headset from the metrics, the narrowband warner
///   and the "Connecting headset mic…" notice alike;
/// - pinning the engine's input node to the real device (the obvious
///   workaround) posts an `AVAudioEngineConfigurationChange` of its own, which
///   `MicCapture` must treat as a dead capture.
///
/// This unit asks Core Audio for exactly one thing — the input stream of one
/// device — with output disabled. No aggregate, no output device in the loop,
/// no Bluetooth output format negotiation, a fresh AudioUnit per capture
/// session (nothing cached between utterances), and the IO cycle is clocked by
/// the microphone itself: the first buffer arrives when the mic has audio, so
/// `first_chunk_ms` is SCO bring-up again and silence is never synthesized.
///
/// Delivery: the HAL IO thread renders ~10 ms slices into a preallocated
/// scratch buffer and accumulates them into one pipeline chunk (`chunkFrames`,
/// 100 ms at the device rate — the shape every consumer downstream was
/// measured with). Full chunks are handed to `deliveryQueue`, so the stateful
/// converter, the meter math and `onChunk` never run on the real-time thread.
/// `stop()` delivers the partial chunk still accumulating at key-up — up to
/// 100 ms of word-final audio the engine tap used to drop with the tap.
final class HalInputUnit: @unchecked Sendable {
    enum Failure: Error, CustomStringConvertible {
        case noComponent
        case status(String, OSStatus)
        case unusableFormat(String)

        var description: String {
            switch self {
            case .noComponent: return "no AUHAL component"
            case .status(let what, let status): return "\(what) failed (OSStatus \(status))"
            case .unusableFormat(let what): return "unusable input format: \(what)"
            }
        }
    }

    let device: AudioDeviceID
    /// What `deliver` receives: Float32, mono, non-interleaved, at the
    /// device's own rate. Mono because the engine path's converter took
    /// channel 0 of a multi-channel device anyway (`AVAudioConverter` remaps
    /// rather than downmixes by default); asking the AUHAL for channel 0
    /// directly is the same audio without the extra channels' bandwidth.
    private(set) var format: AVAudioFormat?

    private let log = WLog.logger("engine.capture.hal")
    private let deliveryQueue: DispatchQueue
    private let deliver: (AVAudioPCMBuffer) -> Void
    private let onReconfigured: () -> Void

    private var unit: AudioUnit?
    /// Render target for one IO slice. Allocated once in `prepare()`.
    private var scratch: UnsafeMutablePointer<Float>?
    private var scratchCapacity = 0
    /// Slices → pipeline chunks. Touched by the IO thread and, after the IO
    /// has stopped, by `stop()` — its lock is uncontended in steady state.
    private var chunker: PcmChunker?
    private var renderErrorCount = 0
    private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private let listenerQueue = DispatchQueue(label: "wisprit.capture.hal.listener")
    private var running = false

    /// `deliver` runs on `deliveryQueue` with every full chunk (and, at stop,
    /// the partial one) in capture order. `onReconfigured` fires at most once,
    /// on a private queue, when the device disappears or changes rate under
    /// the running unit — the same "this capture is dead" fact the engine path
    /// reports through `AVAudioEngineConfigurationChange`.
    init(device: AudioDeviceID,
         deliveryQueue: DispatchQueue,
         deliver: @escaping (AVAudioPCMBuffer) -> Void,
         onReconfigured: @escaping () -> Void) {
        self.device = device
        self.deliveryQueue = deliveryQueue
        self.deliver = deliver
        self.onReconfigured = onReconfigured
    }

    deinit {
        // `stop()` is the contract; this only guarantees a unit that was
        // prepared and never started (an error path) is not leaked.
        if let unit {
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        scratch?.deallocate()
    }

    /// Create and configure the unit; on success `format` is set. Nothing is
    /// running yet — the mic indicator is still dark.
    func prepare() throws {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw Failure.noComponent
        }
        var created: AudioUnit?
        try check("AudioComponentInstanceNew", AudioComponentInstanceNew(component, &created))
        guard let unit = created else { throw Failure.noComponent }
        self.unit = unit

        // Input on, output OFF: the whole point. With output disabled the
        // AUHAL never touches the default output device, so nothing here can
        // renegotiate a Bluetooth headset's playback format.
        var enable: UInt32 = 1
        var disable: UInt32 = 0
        try check("EnableIO(input)", AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1,
            &enable, UInt32(MemoryLayout<UInt32>.size)))
        try check("EnableIO(output)", AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0,
            &disable, UInt32(MemoryLayout<UInt32>.size)))
        var deviceID = device
        try check("CurrentDevice", AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size)))

        // The device side of the input element is the hardware's format; the
        // client side must keep its sample rate (the AUHAL does not resample
        // input), so only the sample type and channel count change.
        var hardware = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check("StreamFormat(device side)", AudioUnitGetProperty(
            unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1,
            &hardware, &size))
        guard hardware.mSampleRate > 0, hardware.mChannelsPerFrame > 0 else {
            throw Failure.unusableFormat("\(hardware.mSampleRate) Hz × \(hardware.mChannelsPerFrame) ch")
        }
        guard let client = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: hardware.mSampleRate,
                                         channels: 1, interleaved: false) else {
            throw Failure.unusableFormat("Float32 mono at \(hardware.mSampleRate) Hz")
        }
        var clientDescription = client.streamDescription.pointee
        try check("StreamFormat(client side)", AudioUnitSetProperty(
            unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1,
            &clientDescription, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)))

        var callback = AURenderCallbackStruct(
            inputProc: halInputProc,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        try check("SetInputCallback", AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
            &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)))
        try check("AudioUnitInitialize", AudioUnitInitialize(unit))

        // The largest slice the IO thread can ask for. 4096 frames is the
        // AUHAL's documented default; never size below it.
        var maxFrames: UInt32 = 4096
        size = UInt32(MemoryLayout<UInt32>.size)
        if AudioUnitGetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice,
                                kAudioUnitScope_Global, 0, &maxFrames, &size) != noErr {
            maxFrames = 4096
        }
        scratchCapacity = Int(max(maxFrames, 4096))
        scratch = .allocate(capacity: scratchCapacity)

        let deliver = self.deliver
        let queue = deliveryQueue
        chunker = PcmChunker(format: client,
                             chunkFrames: AVAudioFrameCount((hardware.mSampleRate / 10).rounded()),
                             emit: { chunk in queue.async { deliver(chunk) } })   // 100 ms
        format = client
    }

    /// Start the IO. The microphone is live when this returns.
    func start() throws {
        guard let unit else { throw Failure.noComponent }
        installListeners()
        do {
            try check("AudioOutputUnitStart", AudioOutputUnitStart(unit))
        } catch {
            removeListeners()
            throw error
        }
        running = true
    }

    /// Stop the IO, deliver the partial chunk, and wait until every delivery
    /// has run. When this returns no further `deliver` call will happen and
    /// the device is closed (the orange indicator can go dark).
    func stop() {
        guard let unit else { return }
        if running {
            // Synchronous: once it returns the IO proc is no longer called.
            AudioOutputUnitStop(unit)
            running = false
        }
        removeListeners()
        if let tail = chunker?.drain() {
            let deliver = self.deliver
            deliveryQueue.async { deliver(tail) }
        }
        // Drain: every chunk the IO thread handed off, and the tail above,
        // has been processed when this returns.
        deliveryQueue.sync {}
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        self.unit = nil
        if renderErrorCount > 0 {
            log.error("input render failed \(self.renderErrorCount) time(s) this session")
        }
    }

    // MARK: - IO thread

    fileprivate func render(flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                            timeStamp: UnsafePointer<AudioTimeStamp>,
                            bus: UInt32, frames: UInt32) -> OSStatus {
        guard let unit, let scratch, Int(frames) <= scratchCapacity else { return noErr }
        var list = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(mNumberChannels: 1,
                                  mDataByteSize: frames * UInt32(MemoryLayout<Float>.size),
                                  mData: UnsafeMutableRawPointer(scratch)))
        let status = AudioUnitRender(unit, flags, timeStamp, bus, frames, &list)
        guard status == noErr else {
            renderErrorCount += 1
            return status
        }
        chunker?.append(scratch, count: Int(frames))
        return noErr
    }

    // MARK: - device listeners

    private func installListeners() {
        let alive = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let rate = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let openedRate = format?.sampleRate ?? 0
        let device = self.device
        var fired = false
        let fire: () -> Void = { [weak self] in
            // Serial listener queue: `fired` needs no lock.
            guard !fired else { return }
            fired = true
            self?.onReconfigured()
        }
        let aliveBlock: AudioObjectPropertyListenerBlock = { _, _ in
            if !HalInputUnit.isAlive(device) { fire() }
        }
        let rateBlock: AudioObjectPropertyListenerBlock = { _, _ in
            if let now = HalInputUnit.nominalRate(device), now != openedRate { fire() }
        }
        for (address, block) in [(alive, aliveBlock), (rate, rateBlock)] {
            var address = address
            if AudioObjectAddPropertyListenerBlock(device, &address, listenerQueue, block) == noErr {
                listeners.append((address, block))
            }
        }
    }

    private func removeListeners() {
        for (address, block) in listeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(device, &address, listenerQueue, block)
        }
        listeners.removeAll()
    }

    private static func isAlive(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 1
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr
        else { return false }
        return value != 0
    }

    private static func nominalRate(_ device: AudioDeviceID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr
        else { return nil }
        return Double(value)
    }

    private func check(_ what: String, _ status: OSStatus) throws {
        guard status == noErr else { throw Failure.status(what, status) }
    }
}

/// IO slices → fixed-size pipeline chunks, in order, without losing a frame.
///
/// The HAL renders ~10 ms at a time; every consumer downstream (the meter's
/// 100 ms chunk statistic, the 3-chunk noise floor, the feed queue's 10 s
/// capacity) was measured on 100 ms chunks, so the HAL backend re-forms them
/// here. `drain()` hands back whatever partial chunk is still accumulating —
/// at key-up that is word-final audio, and it is delivered, not dropped.
final class PcmChunker: @unchecked Sendable {
    private let format: AVAudioFormat
    private let chunkFrames: AVAudioFrameCount
    private let emit: (AVAudioPCMBuffer) -> Void
    private let lock = UnfairLock()
    private var pending: AVAudioPCMBuffer?

    /// `format` must be mono Float32 non-interleaved (what the unit renders).
    init(format: AVAudioFormat, chunkFrames: AVAudioFrameCount,
         emit: @escaping (AVAudioPCMBuffer) -> Void) {
        self.format = format
        self.chunkFrames = max(1, chunkFrames)
        self.emit = emit
        self.pending = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: self.chunkFrames)
    }

    func append(_ samples: UnsafePointer<Float>, count: Int) {
        var offset = 0
        lock.lock()
        defer { lock.unlock() }
        while offset < count {
            guard let chunk = pending, let dst = chunk.floatChannelData?[0] else { return }
            let filled = Int(chunk.frameLength)
            let take = min(count - offset, Int(chunk.frameCapacity) - filled)
            (dst + filled).update(from: samples + offset, count: take)
            chunk.frameLength = AVAudioFrameCount(filled + take)
            offset += take
            if chunk.frameLength == chunk.frameCapacity {
                // Ten times a second: one buffer allocation and one queue hop,
                // the same cost AVAudioEngine's tap machinery pays internally.
                pending = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames)
                emit(chunk)
            }
        }
    }

    /// The partial chunk, if any frames are waiting; the chunker is spent
    /// afterwards (`append` becomes a no-op).
    func drain() -> AVAudioPCMBuffer? {
        lock.lock()
        defer { lock.unlock() }
        let tail = pending
        pending = nil
        guard let tail, tail.frameLength > 0 else { return nil }
        return tail
    }
}

/// The AUHAL input callback: a C function pointer, so it cannot capture —
/// the unit rides in `refCon`, unretained (the owner keeps it alive until
/// `stop()` has returned, after which the HAL no longer calls this).
private let halInputProc: AURenderCallback = { refCon, flags, timeStamp, bus, frames, _ in
    Unmanaged<HalInputUnit>.fromOpaque(refCon).takeUnretainedValue()
        .render(flags: flags, timeStamp: timeStamp, bus: bus, frames: frames)
}
#endif
