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
public final class SecondaryCapture: @unchecked Sendable {
    private let log = WLog.logger("engine.capture.secondary")
    private let retention: PcmRetentionBuffer
    private let wanted: @Sendable () -> Bool
    private let capture: MicCapture

    /// `wanted` answers "should the parachute run for THIS utterance" — the
    /// wiring supplies the policy (classic-BT primary, built-in mic present,
    /// `dual_capture` enabled). `device` names the mic to pin; built-in in
    /// every real wiring, injectable for tests.
    public init(wanted: @escaping @Sendable () -> Bool,
                device: @escaping @Sendable () -> AudioDeviceID? = { InputDeviceProbe.builtInInput() }) {
        self.wanted = wanted
        let retention = PcmRetentionBuffer()
        self.retention = retention
        self.capture = MicCapture(onChunk: { retention.append($0) })
        self.capture.preferredDevice = device
    }

    /// Idempotent, like the primary's `start()` — the prestart hook and the
    /// session's `begin()` both call it, and the second call must not reset a
    /// retention buffer already collecting the utterance's head.
    public func start() {
        guard !capture.isActive, wanted() else { return }
        retention.reset()
        if !capture.start() {
            log.info("secondary capture unavailable — the parachute sits this utterance out")
        }
    }

    public func stop() {
        capture.stop()
    }

    public var isActive: Bool { capture.isActive }

    /// The utterance's audio as captured by this mic — read on the session
    /// thread at finalize, AFTER `stop()`, and snapshotted there (the next
    /// press's `start()` resets the buffer). Empty when the parachute was not
    /// wanted or could not open.
    public var audio: Data { retention.data }
}
#endif
