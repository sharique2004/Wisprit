#if os(macOS)
import SwiftUI
import WispritEngine
import WispritMacUI

/// Microphone — which mic the next dictation uses, whether the system will
/// hand it a usable level, and what happens when headphones are on.
///
/// This pane never opens the microphone. The product rule is that the mic is
/// live only while the dictation key is held, so there is no level meter here:
/// everything shown is a Core Audio property read (device, transport, the
/// input-volume slider) and the test is the real one — hold the key.
struct MicrophonePane: View {
    @ObservedObject var session: SettingsSession
    @ObservedObject var model: WispritWindowModel

    /// The system input-volume slider, 0…1; nil when the device has none or
    /// it has not been read yet.
    @State private var inputVolume: Float?
    @State private var volumeRead = false

    var body: some View {
        PaneForm(pane: .microphone, session: session, model: model) {
            if model.hasProbed, model.facts.microphone != "granted" {
                Section {
                    LabeledContent {
                        Button(model.facts.microphone == "undetermined"
                               ? "Allow Microphone…" : "Open Privacy Settings…") {
                            model.fix(model.facts.microphone == "undetermined"
                                      ? .requestMicrophone : .openMicrophoneSettings)
                        }
                    } label: {
                        Label {
                            rowLabel("Microphone access is off",
                                     "Wisprit can't hear you until macOS allows it.")
                        } icon: {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(.yellow)
                        }
                    }
                }
            }

            Section("Input") {
                let device = deviceLine
                LabeledContent {
                    Text(device.title)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } label: {
                    rowLabel("Dictate with", device.help)
                }
                let volume = MicrophoneCopy.volume(inputVolume,
                                                   lowCeiling: InputVolumeAdvisor.lowVolumeCeiling)
                LabeledContent {
                    HStack(spacing: 8) {
                        if volume.isLow {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.yellow)
                                .accessibilityLabel("Low")
                        }
                        Readout(text: volumeRead ? volume.value : "…")
                        Button("Sound Settings…") { SystemSettingsLink.open(SystemSettingsLink.sound) }
                    }
                } label: {
                    rowLabel("Input volume", volumeRead ? volume.help : "Reading the system slider.")
                }
                LabeledContent {
                    KeycapView(symbol: model.hotkey == .fn ? "globe" : "option",
                               label: "", size: .small)
                        .accessibilityHidden(true)
                } label: {
                    rowLabel("Test your mic",
                             MicrophoneCopy.testHint(hotkey: model.hotkey,
                                                     notchShown: !model.pillHidden))
                }
            }

            Section("Headphones") {
                Toggle(isOn: useHeadset) {
                    rowLabel("Use the headset mic",
                             "Closer to your mouth. Playback drops to call quality while you talk.")
                }
                if model.inputDevicePolicy != .preferBuiltin {
                    Toggle(isOn: mentionTradeOff) {
                        rowLabel("Mention it once per headset",
                                 "A short notch notice about playback and low volume.")
                    }
                    Toggle(isOn: Binding(get: { model.dualCapture }, set: model.setDualCapture)) {
                        rowLabel("Mac mic as backup",
                                 "Rescues words if the headset drops out. Never replaces a good take.")
                    }
                }
            }
        }
        .task(id: session.refreshTick) { await readVolume() }
        .onChange(of: model.facts.inputDeviceName) { Task { await readVolume() } }
    }

    private var deviceLine: MicrophoneCopy.Line {
        MicrophoneCopy.dictatingDevice(name: model.facts.inputDeviceName,
                                       transport: model.facts.inputDeviceTransport,
                                       narrowband: model.facts.inputDeviceNarrowband,
                                       headsetRisk: model.facts.inputDeviceHeadsetRisk,
                                       policy: model.inputDevicePolicy,
                                       hasProbed: model.hasProbed)
    }

    /// `input_device_policy` as two switches: off pins the Mac mic
    /// (`prefer_builtin`); on is the headset, with or without the one-time
    /// notice (`warn` / `off`). All three stored values stay reachable.
    private var useHeadset: Binding<Bool> {
        Binding(get: { model.inputDevicePolicy != .preferBuiltin },
                set: { model.setInputDevicePolicy($0 ? .warn : .preferBuiltin) })
    }

    private var mentionTradeOff: Binding<Bool> {
        Binding(get: { model.inputDevicePolicy == .warn },
                set: { model.setInputDevicePolicy($0 ? .warn : .off) })
    }

    /// One Core Audio property read, off the main actor. Read-only, always:
    /// Wisprit never moves the user's input slider (`InputVolumeAdvisor`).
    private func readVolume() async {
        let read = await Task.detached(priority: .utility) {
            InputDeviceProbe.defaultInputVolume()?.volume
        }.value
        inputVolume = read
        volumeRead = true
    }
}
#endif
