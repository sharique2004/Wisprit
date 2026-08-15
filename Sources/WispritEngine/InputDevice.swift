#if os(macOS)
import CoreAudio
import Foundation
import WispritKit

/// What the system's default audio input actually is.
///
/// Until this existed, `MicCapture.start()` read `inputNode.outputFormat` and
/// asked nothing else — so a Bluetooth headset presenting an 8/16/24 kHz HFP
/// microphone was indistinguishable from a studio interface, and the user got
/// degraded recognition with no warning and no way to opt out. The 2026-08-05
/// incident (`metrics.log` 1785971800–1785971842) is that failure with the
/// volume turned up: the input render format went 48 kHz → 24 kHz as a
/// Bluetooth device became default, and five consecutive utterances came back
/// empty.
///
/// Everything here is local Core Audio property reads — three of them, tens of
/// microseconds, run at key-down. No network, ever.
public struct InputDeviceInfo: Sendable, Equatable {
    public var deviceID: AudioDeviceID
    public var name: String
    /// `kAudioDevicePropertyTransportType` — a FourCC (`bltn`, `blue`, `usb `…).
    public var transport: UInt32
    public var nominalSampleRate: Double

    public init(deviceID: AudioDeviceID, name: String, transport: UInt32,
                nominalSampleRate: Double) {
        self.deviceID = deviceID
        self.name = name
        self.transport = transport
        self.nominalSampleRate = nominalSampleRate
    }

    /// Human-readable transport for the doctor row.
    public var transportName: String { InputDevicePolicy.transportName(transport) }

    public var isNarrowband: Bool {
        InputDevicePolicy.isNarrowband(transport: transport, sampleRate: nominalSampleRate)
    }
}

/// The judgement, split from the probe so it is testable without a mic, a TCC
/// grant, or a Bluetooth headset on the desk.
public enum InputDevicePolicy {

    /// Below this, a microphone is not carrying the fricative energy that
    /// separates "test" from "tess": HFP/SCO links present CVSD at 8 kHz,
    /// mSBC at 16 kHz, and — the 2026-08-05 incident — 24 kHz.
    public static let narrowbandCeilingHz: Double = 32_000

    /// Classic-Bluetooth input under the wideband floor.
    ///
    /// Deliberately narrow on both axes. Only `kAudioDeviceTransportTypeBluetooth`
    /// counts — `…BluetoothLE` is LE Audio/LC3, whose microphones are wideband,
    /// and flagging them would nag users of perfectly good hardware. And only
    /// the SAMPLE RATE decides: a classic-BT device presenting 48 kHz is being
    /// used as a wideband input (A2DP-era or a dongle), and we have no business
    /// second-guessing it.
    public static func isNarrowband(transport: UInt32, sampleRate: Double) -> Bool {
        transport == kAudioDeviceTransportTypeBluetooth && sampleRate < narrowbandCeilingHz
    }

    /// FourCC → the word a human reads in `wisprit doctor`.
    public static func transportName(_ transport: UInt32) -> String {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return "built-in"
        case kAudioDeviceTransportTypeBluetooth: return "Bluetooth"
        case kAudioDeviceTransportTypeBluetoothLE: return "Bluetooth LE"
        case kAudioDeviceTransportTypeUSB: return "USB"
        case kAudioDeviceTransportTypeAggregate: return "aggregate"
        case kAudioDeviceTransportTypeVirtual: return "virtual"
        case kAudioDeviceTransportTypeAirPlay: return "AirPlay"
        case kAudioDeviceTransportTypeDisplayPort: return "DisplayPort"
        case kAudioDeviceTransportTypeHDMI: return "HDMI"
        case kAudioDeviceTransportTypeThunderbolt: return "Thunderbolt"
        case kAudioDeviceTransportTypeContinuityCaptureWired,
             kAudioDeviceTransportTypeContinuityCaptureWireless: return "Continuity Camera"
        case kAudioDeviceTransportTypeUnknown: return "unknown"
        default: return "other"
        }
    }
}

/// One warning per device appearance, never per utterance.
///
/// A narrowband headset is rare and actionable, which is exactly the shape of
/// thing worth one line — and exactly the shape of thing that becomes noise if
/// it repeats every time the user dictates. The probe is injected so the policy
/// is testable without hardware.
public final class NarrowbandWarner: @unchecked Sendable {
    public static let message =
        "Bluetooth headset mic is narrowband — dictation may be less accurate"

    private let probe: @Sendable () -> InputDeviceInfo?
    private let isEnabled: @Sendable () -> Bool
    private let lock = UnfairLock()
    private var lastWarnedDeviceID: AudioDeviceID?

    public init(isEnabled: @escaping @Sendable () -> Bool = { true },
                probe: @escaping @Sendable () -> InputDeviceInfo? = { InputDeviceProbe.defaultInput() }) {
        self.isEnabled = isEnabled
        self.probe = probe
    }

    /// The line to show, or nil — which is the answer almost always.
    public func warning() -> String? {
        guard isEnabled(), let device = probe(), device.isNarrowband else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard lastWarnedDeviceID != device.deviceID else { return nil }
        lastWarnedDeviceID = device.deviceID
        return Self.message
    }
}

/// The Core Audio adapter. Thin and untested by design (SessionPorts' rule):
/// every judgement it feeds lives in `InputDevicePolicy`.
public enum InputDeviceProbe {

    public static func defaultInput() -> InputDeviceInfo? {
        guard let id = defaultInputDeviceID() else { return nil }
        return InputDeviceInfo(deviceID: id,
                               name: name(of: id) ?? "(unknown)",
                               transport: transport(of: id) ?? kAudioDeviceTransportTypeUnknown,
                               nominalSampleRate: nominalSampleRate(of: id) ?? 0)
    }

    /// The built-in microphone, for `input_device_policy = prefer_builtin`.
    /// nil on a Mac with no internal input (a Mac mini, a headless build box),
    /// where the policy correctly does nothing.
    public static func builtInInput() -> AudioDeviceID? {
        allDevices().first {
            transport(of: $0) == kAudioDeviceTransportTypeBuiltIn && hasInputStreams($0)
        }
    }

    // MARK: - property reads

    private static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                                &address, 0, nil, &size, &device)
        guard status == noErr, device != kAudioObjectUnknown else { return nil }
        return device
    }

    private static func allDevices() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &address, 0, nil, &size) == noErr, size > 0
        else { return [] }
        var devices = [AudioDeviceID](repeating: 0,
                                      count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &devices) == noErr
        else { return [] }
        return devices
    }

    private static func hasInputStreams(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr
        else { return false }
        return size > 0
    }

    private static func name(of device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &name) {
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0)
        }
        guard status == noErr else { return nil }
        return name as String
    }

    private static func transport(of device: AudioDeviceID) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr
        else { return nil }
        return transport
    }

    private static func nominalSampleRate(of device: AudioDeviceID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate) == noErr
        else { return nil }
        return Double(rate)
    }
}
#endif
