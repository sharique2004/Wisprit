#if os(macOS)
import CoreAudio
import Foundation
import WispritKit

/// The Mac-mic parachute behind the headphone-mic default
/// (docs/research/hearing-and-corrections.md, dual capture).
///
/// A second `MicCapture`, pinned to the built-in microphone, that feeds ONLY a
/// retention buffer — never the live engine, never a transcript the user sees
/// directly. It exists for the two moments a classic-Bluetooth primary is
/// structurally weak: SCO bring-up (1–3 s of radio negotiation during which the
/// headset mic delivers nothing while the built-in mic wakes in ~50 ms) and
/// packet loss in crowded 2.4 GHz air. When the headset utterance fails, the
/// batch rescue re-reads THIS audio under the same "may add words, never lose
/// them" contract; when the headset utterance succeeds, these bytes are dropped
/// on the floor unread.
///
/// Lifecycle mirrors the primary exactly — started with it, stopped with it —
/// so the orange-indicator privacy invariant is unchanged: during a hold there
/// are simply two microphones behind the one indicator, and both go dark at
/// key-up. `wanted` is re-evaluated at every start, so unplugging the headset
/// (or flipping the setting) silences the parachute with no relaunch.
///
/// **Never on the caller's thread (2026-11-06).** The first implementation
/// opened the parachute synchronously with an `AVAudioEngine` pinned to the
/// built-in mic. With Bluetooth headphones as the default OUTPUT, macOS 27's
/// engine then sat ~3.0 s in `SetBluetoothAudioFormatAndWait` on every start
/// — measured on every one of the November headset utterances — and the
/// caller was the session thread (or the prestart queue the session's own
/// stop then waited on): key-ups were handled seconds late, primaries were
/// stopped before their SCO link delivered a byte, and every hold recorded at
/// least ~3 s whatever its length. Two independent fixes, both here: the
/// parachute opens an input-only AUHAL (`MicCapture.Backend.hal` — no output
/// device in the loop, so nothing renegotiates the headset), and start/stop
/// are serialized on the parachute's own queue, so no caller can ever wait on
/// it. Ordering is preserved (a stop always follows its start) and stop is
/// still issued at key-up, so the indicator invariant is unchanged.
public final class SecondaryCapture: @unchecked Sendable {
    private let log = WLog.logger("engine.capture.secondary")
    private let retention: PcmRetentionBuffer
    private let wanted: @Sendable () -> Bool
    private let capture: MicCapture
    private let queue = DispatchQueue(label: "wisprit.capture.secondary", qos: .userInitiated)
    private let lock = UnfairLock()
    /// The caller-visible state: true from `start()` until `stop()`, whether
    /// or not the queued open has happened yet (or `wanted` declined it).
    private var requested = false

    /// `wanted` answers "should the parachute run for THIS utterance" — the
    /// wiring supplies the policy (classic-BT primary, built-in mic present,
    /// `dual_capture` enabled). `device` names the mic to pin; built-in in
    /// every real wiring, injectable for tests. `backend` is the HAL path in
    /// every real wiring; injectable so a test can exercise the queueing
    /// contract without a microphone.
    public init(wanted: @escaping @Sendable () -> Bool,
                device: @escaping @Sendable () -> AudioDeviceID? = { InputDeviceProbe.builtInInput() },
                backend: MicCapture.Backend = .hal) {
        self.wanted = wanted
        let retention = PcmRetentionBuffer()
        self.retention = retention
        self.capture = MicCapture(onChunk: { retention.append($0) })
        self.capture.preferredDevice = device
        self.capture.backend = { backend }
    }

    /// Idempotent, like the primary's `start()` — the prestart hook and the
    /// session's `begin()` both call it, and the second call must not reset a
    /// retention buffer already collecting the utterance's head. Returns at
    /// once: the open happens on the parachute's queue.
    public func start() {
        lock.lock()
        guard !requested else { lock.unlock(); return }
        requested = true
        lock.unlock()
        queue.async { [self] in
            guard wanted() else { return }
            retention.reset()
            if !capture.start() {
                log.info("secondary capture unavailable — the parachute sits this utterance out")
            }
        }
    }

    /// Returns at once; the close is queued behind any open still in flight.
    public func stop() {
        lock.lock()
        guard requested else { lock.unlock(); return }
        requested = false
        lock.unlock()
        queue.async { [capture] in capture.stop() }
    }

    /// Block until every queued open/close has run. For tests; nothing in
    /// production needs it — the retention buffer is lock-protected and the
    /// finalize snapshot reads it as a value.
    public func waitUntilIdle() {
        queue.sync {}
    }

    public var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return requested
    }

    /// The utterance's audio as captured by this mic — read on the session
    /// thread at finalize, AFTER `stop()`, and snapshotted there (the next
    /// press's `start()` resets the buffer). Empty when the parachute was not
    /// wanted or could not open.
    public var audio: Data { retention.data }
}
#endif
