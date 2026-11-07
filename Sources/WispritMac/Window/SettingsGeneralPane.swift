#if os(macOS)
import SwiftUI

/// General — whether dictation runs, which key holds it, and what you see and
/// hear while it does.
struct GeneralPane: View {
    @ObservedObject var session: SettingsSession
    @ObservedObject var model: WispritWindowModel

    var body: some View {
        PaneForm(pane: .general, session: session, model: model) {
            Section {
                Toggle(isOn: Binding(get: { model.dictationEnabled },
                                     set: model.setDictationEnabled)) {
                    rowLabel("Dictation", "Hold the key, speak, and let go to insert.")
                }
                Picker(selection: Binding(get: { model.hotkey }, set: model.setHotkey)) {
                    ForEach(WindowSettings.HotkeyOption.allCases, id: \.self) { option in
                        Text(option.label).tag(option)
                    }
                } label: {
                    rowLabel("Dictation key", keyHelp)
                }
                if showsGlobeAdvice {
                    LabeledContent {
                        Button("Open Keyboard Settings…") {
                            model.fix(.openKeyboardSettings)
                        }
                    } label: {
                        rowLabel("“Press 🌐 key to” is \(model.globeKey.label)",
                                 "Set it to Do Nothing so a press dictates.")
                    }
                }
            }

            Section("While you dictate") {
                Toggle(isOn: Binding(get: { !model.pillHidden },
                                     set: { model.setPillHidden(!$0) })) {
                    rowLabel("Show dictation at the notch",
                             "The notch widens while you talk, then folds away.")
                }
                Toggle(isOn: Binding(get: { model.soundCues }, set: model.setSoundCues)) {
                    rowLabel("Play sounds",
                             "A soft cue when the mic opens and when text lands.")
                }
            }

            Section {
                LabeledContent {
                    Button("Open Setup…") { session.openSetup() }
                } label: {
                    rowLabel("Setup", setupLine)
                }
            }
        }
    }

    private var keyHelp: String {
        switch model.hotkey {
        case .fn: return "Hold 🌐 anywhere to dictate."
        case .rightOption: return "For keyboards that don't send 🌐."
        }
    }

    /// Only for the 🌐 key, and only once the probe has proved the system
    /// setting is in the way — an unknown read stays quiet here (Setup owns
    /// the "couldn't check" case).
    private var showsGlobeAdvice: Bool {
        guard model.hotkey == .fn, model.hasProbed else { return false }
        switch model.globeKey {
        case .doNothing, .unknown: return false
        default: return true
        }
    }

    private var setupLine: String {
        switch model.summary.hero {
        case .checking: return "Checking permissions and the speech model…"
        case .needsSetup(let blocking):
            return blocking == 1 ? "1 thing needs fixing." : "\(blocking) things need fixing."
        case .ready:
            return model.items.contains { $0.isEssential && $0.mark == .warn }
                ? "Working. A few things are worth a look."
                : "Permissions and the speech model are ready."
        }
    }
}
#endif
