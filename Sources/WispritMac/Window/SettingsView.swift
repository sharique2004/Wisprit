#if os(macOS)
import SwiftUI

/// Everything `config.json` holds that a person should be able to change without
/// opening a text editor.
///
/// Each control writes straight through to the existing `Settings` object, which
/// persists atomically and keeps the on-disk key order — no new keys are
/// introduced here, so a config edited in this window stays readable by every
/// other build.
struct SettingsView: View {
    @ObservedObject var model: WispritWindowModel

    var body: some View {
        Form {
            Section {
                Picker("Dictation key", selection: hotkeyBinding) {
                    ForEach(WindowSettings.HotkeyOption.allCases, id: \.self) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.radioGroup)
                Text(model.hotkey.explanation)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Hotkey")
            } footer: {
                Text("Wisprit records only while the key is held down.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Behaviour") {
                Toggle("Dictation enabled", isOn: bind(model.dictationEnabled,
                                                       model.setDictationEnabled))
                Toggle("AI Cleanup (Apple Intelligence)", isOn: bind(model.aiCleanup,
                                                                     model.setAiCleanup))
                Toggle("Remove filler words (um, uh, you know)",
                       isOn: bind(model.fillerRemoval, model.setFillerRemoval))
                Picker("Leading space", selection: leadingSpaceBinding) {
                    ForEach(WindowSettings.LeadingSpaceOption.allCases, id: \.self) { option in
                        Text(option.label).tag(option)
                    }
                }
                Text(model.leadingSpace.explanation)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Toggle("Live Typing (types into the field as you speak)",
                       isOn: bind(model.liveTypingEnabled, model.setLiveTypingEnabled))
                    .disabled(!liveTypingInstalled)
                Text(SetupChecklist.liveTypingPerAppNote)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !liveTypingInstalled {
                    HStack(spacing: 10) {
                        Text(liveTypingDetail)
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Enable Live Typing…") { model.fix(.enableLiveTyping) }
                            .controlSize(.small)
                    }
                }
                // What the ladder has actually learned on this machine, so the
                // sentence above stops being an abstraction the moment it has a
                // real example.
                if !model.liveTypingFallbacks.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Apps where Wisprit falls back to pasting")
                            .font(.caption).fontWeight(.semibold)
                        ForEach(model.liveTypingFallbacks) { verdict in
                            Text("\(verdict.displayName) — \(verdict.behaviour)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text("Noticed while you dictated. The list starts empty each "
                             + "time Wisprit launches.")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            } header: {
                Text("Live Typing")
            }

            Section("Interface") {
                Toggle("Hide the floating pill", isOn: bind(model.pillHidden, model.setPillHidden))
                Toggle("Save transcripts to history",
                       isOn: bind(model.historyEnabled, model.setHistoryEnabled))
            }

            Section {
                Stepper(value: holdDebounceBinding,
                        in: WindowSettings.holdDebounceRange,
                        step: WindowSettings.holdDebounceStep) {
                    LabeledContent("Hold debounce", value: "\(model.holdDebounceMs) ms")
                }
                Text("A press shorter than this is treated as an accidental brush "
                     + "and discarded.")
                    .font(.caption).foregroundStyle(.secondary)

                Stepper(value: pasteRestoreBinding,
                        in: WindowSettings.pasteRestoreRange,
                        step: WindowSettings.pasteRestoreStep) {
                    LabeledContent("Clipboard restore delay",
                                   value: "\(model.pasteRestoreDelayMs) ms")
                }
                Text("How long Wisprit waits after pasting before it puts your old "
                     + "clipboard back. Too short and the paste picks up stale content.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Timing")
            }

            Section {
                LabeledContent("Config file") {
                    Text(model.configPath.path)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.head)
                        .textSelection(.enabled)
                }
                LabeledContent("Version", value: WispritVersion.string)
            } header: {
                Text("About")
            }
        }
        .formStyle(.grouped)
        .onAppear { model.reloadSettings() }
    }

    // MARK: - Bindings
    //
    // The model publishes read-only mirrors and exposes explicit setters, so a
    // write is always one persisted `Settings.set` — no two-way binding quietly
    // rewriting the file on every view update.

    private func bind(_ value: Bool, _ setter: @escaping (Bool) -> Void) -> Binding<Bool> {
        Binding(get: { value }, set: setter)
    }

    private var hotkeyBinding: Binding<WindowSettings.HotkeyOption> {
        Binding(get: { model.hotkey }, set: { model.setHotkey($0) })
    }

    private var leadingSpaceBinding: Binding<WindowSettings.LeadingSpaceOption> {
        Binding(get: { model.leadingSpace }, set: { model.setLeadingSpace($0) })
    }

    private var holdDebounceBinding: Binding<Int> {
        Binding(get: { model.holdDebounceMs }, set: { model.setHoldDebounceMs($0) })
    }

    private var pasteRestoreBinding: Binding<Int> {
        Binding(get: { model.pasteRestoreDelayMs }, set: { model.setPasteRestoreDelayMs($0) })
    }

    private var liveTypingItem: SetupItem? {
        model.items.first { $0.id == SetupChecklist.liveTypingID }
    }

    /// Installed and working — deliberately NOT `isSatisfied`, which also
    /// requires the switch to be on. Reading satisfaction here disabled the very
    /// toggle that turns it on.
    private var liveTypingInstalled: Bool { liveTypingItem?.mark == .ok }

    private var liveTypingDetail: String {
        liveTypingItem?.detail ?? "Checking the input method…"
    }
}
#endif
