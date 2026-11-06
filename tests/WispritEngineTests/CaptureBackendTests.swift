#if os(macOS)
import AVFoundation
import CoreAudio
import XCTest
@testable import WispritEngine

/// The capture-backend change (docs/eval/AUDIT-2026-11-06.md): the pieces of
/// it that are decidable without opening a microphone.
final class CaptureBackendTests: XCTestCase {

    // MARK: - PcmChunker: HAL slices → 100 ms pipeline chunks

    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                       channels: 1, interleaved: false)!

    private func samples(_ range: Range<Int>) -> [Float] { range.map { Float($0) } }

    private func values(_ buffer: AVAudioPCMBuffer) -> [Float] {
        Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }

    func testChunkerReformsSlicesIntoFullChunksInOrderAndLosesNothing() {
        var emitted: [AVAudioPCMBuffer] = []
        let chunker = PcmChunker(format: format, chunkFrames: 1000, emit: { emitted.append($0) })
        // 512-frame IO slices, the HAL's usual size, straddling chunk edges.
        var next = 0
        for _ in 0..<5 {
            let slice = samples(next..<(next + 512))
            slice.withUnsafeBufferPointer { chunker.append($0.baseAddress!, count: $0.count) }
            next += 512
        }
        XCTAssertEqual(emitted.map(\.frameLength), [1000, 1000])
        let tail = chunker.drain()
        XCTAssertEqual(tail?.frameLength, 560)
        let all = emitted.flatMap(values) + (tail.map(values) ?? [])
        XCTAssertEqual(all, samples(0..<2560), "every frame, once, in capture order")
    }

    /// The key-up tail: the partial chunk is handed back, not dropped — the
    /// engine path lost it with the tap.
    func testDrainReturnsThePartialChunkOnceAndThenNothing() {
        let chunker = PcmChunker(format: format, chunkFrames: 4800, emit: { _ in XCTFail("no full chunk") })
        let slice = samples(0..<300)
        slice.withUnsafeBufferPointer { chunker.append($0.baseAddress!, count: $0.count) }
        XCTAssertEqual(chunker.drain()?.frameLength, 300)
        XCTAssertNil(chunker.drain())
        // Spent: appends after a drain are ignored rather than resurrected.
        slice.withUnsafeBufferPointer { chunker.append($0.baseAddress!, count: $0.count) }
        XCTAssertNil(chunker.drain())
    }

    func testAnEmptyChunkerDrainsToNil() {
        let chunker = PcmChunker(format: format, chunkFrames: 4800, emit: { _ in })
        XCTAssertNil(chunker.drain())
    }

    // MARK: - engine-path attribution

    private func device(_ id: AudioDeviceID, _ name: String, _ transport: UInt32) -> InputDeviceInfo {
        InputDeviceInfo(deviceID: id, name: name, transport: transport, nominalSampleRate: 48_000)
    }

    /// Every November row said `CADefaultDeviceAggregate-…`/`aggregate` and hid
    /// a Bluetooth headset. The aggregate's input is the default input.
    func testTheEnginesPrivateAggregateIsAttributedToTheDefaultInput() {
        let aggregate = device(142, "CADefaultDeviceAggregate-1470-0", kAudioDeviceTransportTypeAggregate)
        let headset = device(110, "Headphones", kAudioDeviceTransportTypeBluetooth)
        let attributed = MicCapture.attribution(landed: aggregate, pinned: false, defaultInput: { headset })
        XCTAssertEqual(attributed, headset)
        XCTAssertTrue(InputDevicePolicy.isClassicBluetooth(attributed!.transport),
                      "the connecting-pill and narrowband warner key on this")
    }

    func testAPinnedOrOrdinaryDeviceIsReportedAsLanded() {
        let builtIn = device(97, "MacBook Pro Microphone", kAudioDeviceTransportTypeBuiltIn)
        let headset = device(110, "Headphones", kAudioDeviceTransportTypeBluetooth)
        XCTAssertEqual(MicCapture.attribution(landed: builtIn, pinned: true, defaultInput: { headset }), builtIn)
        XCTAssertEqual(MicCapture.attribution(landed: builtIn, pinned: false, defaultInput: { headset }), builtIn)
        // A user-built aggregate (a real device the user chose) is not ours to
        // see through.
        let userAggregate = device(150, "Studio Aggregate", kAudioDeviceTransportTypeAggregate)
        XCTAssertEqual(MicCapture.attribution(landed: userAggregate, pinned: false, defaultInput: { headset }),
                       userAggregate)
        // No default input to name → keep what we have.
        let aggregate = device(142, "CADefaultDeviceAggregate-1-0", kAudioDeviceTransportTypeAggregate)
        XCTAssertEqual(MicCapture.attribution(landed: aggregate, pinned: false, defaultInput: { nil }), aggregate)
        XCTAssertNil(MicCapture.attribution(landed: nil, pinned: false, defaultInput: { headset }))
    }

    // MARK: - lifecycle without a microphone

    /// The prestart hook, the session and the parachute all stop defensively;
    /// a capture that never opened must treat that as the no-op it is (it used
    /// to log "microphone delivered no audio" 2–4 times per utterance).
    func testStoppingACaptureThatNeverStartedIsANoOp() {
        let capture = MicCapture(onChunk: { _ in XCTFail("no audio") })
        capture.stop()
        capture.stop()
        XCTAssertFalse(capture.isActive)
        XCTAssertEqual(capture.capturedBytes, 0)
        XCTAssertNil(capture.activeBackend)
    }

    /// The parachute can never hold its caller: November's engine-backed
    /// parachute sat ~3 s in a Bluetooth format wait on the session thread.
    /// `wanted` stands in for any slow open here (and declines, so no mic).
    func testTheParachuteNeverBlocksItsCaller() {
        let gate = DispatchSemaphore(value: 0)
        let secondary = SecondaryCapture(wanted: {
            gate.wait()          // an open that takes as long as the test likes
            return false
        }, device: { nil })
        let began = Date()
        secondary.start()
        secondary.start()        // idempotent while requested
        XCTAssertTrue(secondary.isActive)
        secondary.stop()
        XCTAssertFalse(secondary.isActive)
        XCTAssertLessThan(Date().timeIntervalSince(began), 0.2,
                          "start/stop returned while the open was still in flight")
        gate.signal()
        secondary.waitUntilIdle()
        XCTAssertTrue(secondary.audio.isEmpty)
    }

    func testAParachuteStopWithoutAStartIsANoOp() {
        let secondary = SecondaryCapture(wanted: { false }, device: { nil })
        secondary.stop()
        secondary.waitUntilIdle()
        XCTAssertFalse(secondary.isActive)
    }
}
#endif
