#if os(macOS)
import AppKit
import SwiftUI
import WispritKit

/// Advanced — the timing knobs, the engines, and the files. Everything here
/// has a shipped value that is right for almost everyone; Restore Defaults puts
/// every one of them back.
struct AdvancedPane: View {
    @ObservedObject var session: SettingsSession
    @ObservedObject var model: WispritWindowModel

    @State private var confirmingRestore = false

    var body: some View {
        PaneForm(pane: .advanced, session: session, model: model) {
            Section("Dictation key") {
                MillisecondRow(title: "Ignore taps shorter than",
                               help: "Shorter presses count as accidental.",
                               value: model.holdDebounceMs,
                               range: WindowSettings.holdDebounceRange,
                               step: WindowSettings.holdDebounceStep,
                               set: model.setHoldDebounceMs)
                MillisecondRow(title: "Keep listening after release",
                               help: "Catches the last syllable as you let go.",
                               value: model.keyupGraceMs,
                               range: WindowSettings.keyupGraceRange,
                               step: WindowSettings.keyupGraceStep,
                               set: model.setKeyupGraceMs)
                Toggle(isOn: Binding(get: { model.adaptiveGrace }, set: model.setAdaptiveGrace)) {
                    rowLabel("Keep listening while you talk",
                             "Waits a little longer if you're mid-word, up to 0.5 s.")
                }
            }

            Section("Recognition") {
                Picker(selection: Binding(get: { model.engine }, set: model.setEngine)) {
                    ForEach(WindowSettings.EngineOption.allCases, id: \.self) { option in
                        Text(option.label).tag(option)
                    }
                } label: {
                    rowLabel("Speech engine", "Both run on this Mac.")
                }
                StepperRow(title: "Finish waiting after",
                           help: "How long to wait for the final words before using what's in.",
                           value: model.finalizeTimeoutMs, unit: "ms",
                           range: WindowSettings.finalizeTimeoutRange,
                           step: WindowSettings.finalizeTimeoutStep,
                           set: model.setFinalizeTimeoutMs)
                Picker(selection: Binding(get: { model.captureBackend },
                                          set: model.setCaptureBackend)) {
                    ForEach(WindowSettings.CaptureBackendOption.allCases, id: \.self) { option in
                        Text(option.label).tag(option)
                    }
                } label: {
                    rowLabel("Microphone path", "How Wisprit opens the mic. Change only to troubleshoot.")
                }
            }

            if aiCleanupAvailable, model.aiCleanup {
                Section("AI cleanup") {
                    StepperRow(title: "Skip dictations longer than",
                               help: "Long ones go in as heard, without waiting.",
                               value: model.aiCleanupMaxWords, unit: "words",
                               range: WindowSettings.aiCleanupMaxWordsRange,
                               step: WindowSettings.aiCleanupMaxWordsStep,
                               set: model.setAiCleanupMaxWords)
                    StepperRow(title: "Give up after",
                               help: "Uses the text as heard if cleanup is slower.",
                               value: model.aiCleanupTimeoutMs, unit: "ms",
                               range: WindowSettings.aiCleanupTimeoutRange,
                               step: WindowSettings.aiCleanupTimeoutStep,
                               set: model.setAiCleanupTimeoutMs)
                }
            }

            Section("Inserting") {
                MillisecondRow(title: "Restore the clipboard after",
                               help: "Waits this long after pasting to put your clipboard back.",
                               value: model.pasteRestoreDelayMs,
                               range: WindowSettings.pasteRestoreRange,
                               step: WindowSettings.pasteRestoreStep,
                               set: model.setPasteRestoreDelayMs)
                if liveTypingOn {
                    Picker(selection: Binding(get: { model.imSelectionPolicy },
                                              set: model.setImSelectionPolicy)) {
                        ForEach(WindowSettings.SelectionPolicyOption.allCases, id: \.self) { option in
                            Text(option.label).tag(option)
                        }
                    } label: {
                        rowLabel("Live Typing input source", selectionHelp)
                    }
                }
            }

            Section("Files") {
                LabeledContent {
                    HStack(spacing: 6) {
                        reveal("config.json", model.configPath)
                        reveal("metrics.log", model.metricsPath)
                        reveal("dictionary.json", model.dictionaryPath)
                    }
                } label: {
                    rowLabel("Show in Finder", "Plain files you can read and back up.")
                }
                LabeledContent("Version") {
                    Text(WispritVersion.string)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            Section {
                LabeledContent {
                    Button("Restore Defaults…") { confirmingRestore = true }
                        .disabled(model.isTuningAtDefaults)
                } label: {
                    rowLabel("Restore defaults", "Resets every setting on this pane.")
                }
            }
        }
        .confirmationDialog("Restore the default advanced settings?",
                            isPresented: $confirmingRestore,
                            titleVisibility: .visible) {
            Button("Restore Defaults") { model.restoreDefaultTuning() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Timings, engines and the microphone path go back to their shipped values. "
                 + "Your key, language and other settings stay.")
        }
    }

    private var aiCleanupAvailable: Bool {
        WindowSettings.appleIntelligenceGate(available: model.facts.aiAvailable,
                                             reason: model.facts.aiReason) == .available
    }

    private var liveTypingOn: Bool {
        guard model.liveTypingEnabled else { return false }
        let mark = model.items.first { $0.id == SetupChecklist.liveTypingID }?.mark
        return WindowSettings.liveTypingGate(isStaged: model.facts.imStaged, mark: mark) == .available
    }

    private var selectionHelp: String {
        switch model.imSelectionPolicy {
        case .warm: return "Stays selected between dictations, so the first word is quick."
        case .perUtterance: return "Selected only while you speak."
        }
    }

    private func reveal(_ title: String, _ url: URL) -> some View {
        Button(title) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            .font(.system(.body, design: .monospaced))
    }
}
#endif
