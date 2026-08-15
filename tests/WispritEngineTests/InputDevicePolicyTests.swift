#if os(macOS)
import CoreAudio
import XCTest
@testable import WispritEngine

/// The narrowband-microphone policy, with no Bluetooth headset on the desk.
///
/// `InputDeviceProbe` itself is a thin Core Audio adapter and stays uncovered by
/// the repo's own rule; everything that decides anything lives here.
final class InputDevicePolicyTests: XCTestCase {

    // MARK: - isNarrowband

    /// HFP/SCO presentations: CVSD at 8 kHz, mSBC at 16 kHz, and the 24 kHz the
    /// 2026-08-05 incident actually logged.
    func testClassicBluetoothUnderTheFloorIsNarrowband() {
        for rate in [8_000.0, 16_000.0, 24_000.0, 31_999.0] {
            XCTAssertTrue(
                InputDevicePolicy.isNarrowband(transport: kAudioDeviceTransportTypeBluetooth,
                                               sampleRate: rate),
                "\(rate) Hz over classic BT is an HFP mic")
        }
    }

    /// A classic-BT device presenting a wideband rate is being used as a
    /// wideband input; second-guessing it would nag users of good hardware.
    func testWidebandBluetoothIsNotFlagged() {
        for rate in [32_000.0, 44_100.0, 48_000.0] {
            XCTAssertFalse(
                InputDevicePolicy.isNarrowband(transport: kAudioDeviceTransportTypeBluetooth,
                                               sampleRate: rate))
        }
    }

    /// LE Audio/LC3 microphones are wideband by design — deliberately exempt,
    /// whatever nominal rate they report.
    func testBluetoothLEIsNeverFlagged() {
        XCTAssertFalse(
            InputDevicePolicy.isNarrowband(transport: kAudioDeviceTransportTypeBluetoothLE,
                                           sampleRate: 24_000))
    }

    /// The transport, not the rate, is the first gate: a wired device at a low
    /// rate is not an HFP link.
    func testWiredTransportsAreNeverFlagged() {
        for transport in [kAudioDeviceTransportTypeBuiltIn,
                          kAudioDeviceTransportTypeUSB,
                          kAudioDeviceTransportTypeAggregate,
                          kAudioDeviceTransportTypeVirtual] {
            XCTAssertFalse(InputDevicePolicy.isNarrowband(transport: transport, sampleRate: 16_000))
            XCTAssertFalse(InputDevicePolicy.isNarrowband(transport: transport, sampleRate: 44_100))
        }
    }

    func testTheFloorIsTheWidebandBoundary() {
        XCTAssertEqual(InputDevicePolicy.narrowbandCeilingHz, 32_000)
    }

    func testTransportNamesAreHumanReadable() {
        XCTAssertEqual(InputDevicePolicy.transportName(kAudioDeviceTransportTypeBuiltIn), "built-in")
        XCTAssertEqual(InputDevicePolicy.transportName(kAudioDeviceTransportTypeBluetooth), "Bluetooth")
        XCTAssertEqual(InputDevicePolicy.transportName(kAudioDeviceTransportTypeBluetoothLE), "Bluetooth LE")
        XCTAssertEqual(InputDevicePolicy.transportName(kAudioDeviceTransportTypeUSB), "USB")
        XCTAssertEqual(InputDevicePolicy.transportName(0x77686174), "other")
    }

    // MARK: - NarrowbandWarner

    private func device(_ id: AudioDeviceID, transport: UInt32 = kAudioDeviceTransportTypeBluetooth,
                        rate: Double = 16_000) -> InputDeviceInfo {
        InputDeviceInfo(deviceID: id, name: "AirPods Pro", transport: transport,
                        nominalSampleRate: rate)
    }

    /// Once per device appearance, never per utterance: the whole reason this
    /// is a warning and not a nag.
    func testTheSameDeviceIsWarnedAboutOnce() {
        let probe = DeviceBox(device(7))
        let warner = NarrowbandWarner(probe: { probe.value })
        XCTAssertEqual(warner.warning(), NarrowbandWarner.message)
        XCTAssertNil(warner.warning())
        XCTAssertNil(warner.warning())
    }

    func testADifferentDeviceWarnsAgain() {
        let probe = DeviceBox(device(7))
        let warner = NarrowbandWarner(probe: { probe.value })
        XCTAssertNotNil(warner.warning())
        probe.value = device(8)
        XCTAssertNotNil(warner.warning(), "a new headset is a new fact")
    }

    func testAWidebandDeviceIsNeverWarnedAbout() {
        let probe = DeviceBox(device(7, transport: kAudioDeviceTransportTypeBuiltIn, rate: 48_000))
        XCTAssertNil(NarrowbandWarner(probe: { probe.value }).warning())
    }

    func testNoDeviceIsNotAWarning() {
        XCTAssertNil(NarrowbandWarner(probe: { nil }).warning())
    }

    /// `input_device_policy = off` silences it, and silences it BEFORE the
    /// probe runs — an opted-out user pays nothing at key-down.
    func testPolicyOffSilencesTheWarningWithoutProbing() {
        let probed = Counter()
        let warner = NarrowbandWarner(isEnabled: { false },
                                      probe: { probed.bump(); return nil })
        XCTAssertNil(warner.warning())
        XCTAssertEqual(probed.value, 0)
    }

    final class DeviceBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: InputDeviceInfo?
        init(_ value: InputDeviceInfo?) { stored = value }
        var value: InputDeviceInfo? {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func bump() { lock.lock(); count += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }
}
#endif
