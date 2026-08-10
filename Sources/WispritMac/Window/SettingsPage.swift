#if os(macOS)
import AppKit
import SwiftUI
import WispritKit
import WispritMacUI

/// Settings — `docs/design/ui-redesign.md` §3.6.
///
/// Toggle-first, and hairline-separated groups **inside** the content card
/// rather than a `Form` of nested boxes. Three rules do all the work:
///
///  * **Gated sections disappear.** A feature this Mac cannot have has no
///    group; a feature it could have but does not yet gets one row and one
///    button. The old page rendered a permanently-disabled Live Typing toggle,
///    which is a bug report waiting to be filed.
///  * **Advanced sub-rows only exist while their parent is on.** A timeout for
///    a cleanup pass that is switched off is noise.
///  * Every control writes through an explicit `WispritWindowModel` setter, so
///    a write is always one persisted `Settings.set` — never a two-way binding
///    rewriting the file on a view update.
struct SettingsPage: View {
    @ObservedObject var model: WispritWindowModel

    @State private var confirmingDelete = false
    @State private var terminalsExpanded = false
    @State private var terminalDraft = ""

    var body: some View {
        HubPage(title: WispritWindowModel.Tab.settings.title) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    dictation
                    text
                    aiCleanup
                    liveTyping
                    pill
                    historyAndPrivacy
                    advanced
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear { model.reloadSettings() }
        .confirmationDialog("Delete all transcripts?",
                            isPresented: $confirmingDelete,
                            titleVisibility: .visible) {
            Button("Delete All Transcripts", role: .destructive) { model.purgeHistory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(model.historyDeletionWarning)
        }
    }

    // MARK: - Dictation

    private var dictation: some View {
        SectionGroup("Dictation") {
            SectionRow("Dictation enabled") {
                Toggle("", isOn: bind(model.dictationEnabled, model.setDictationEnabled))
                    .labelsHidden()
            }
            SectionRow("Dictation key", description: model.hotkey.explanation) {
                Picker("", selection: binding(model.hotkey, model.setHotkey)) {
                    ForEach(WindowSettings.HotkeyOption.allCases, id: \.self) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
            }
            SectionRow("Ignore taps shorter than",
                       description: "A press shorter than this is treated as an accidental "
                           + "brush and discarded.") {
                HStack(spacing: Theme.Space.s8) {
                    Slider(value: intSlider(model.holdDebounceMs, model.setHoldDebounceMs),
                           in: range(WindowSettings.holdDebounceRange),
                           step: Double(WindowSettings.holdDebounceStep))
                        .frame(width: 160)
                    readout("\(model.holdDebounceMs) ms")
                }
            }
            // A language menu is only a choice when there is more than one
            // installed voice; otherwise it is a control with one option.
            if model.facts.installedLocales.count > 1 {
                SectionRow("Language") {
                    Picker("", selection: binding(model.locale, model.setLocale)) {
                        ForEach(model.facts.installedLocales, id: \.self) { locale in
                            Text(locale).tag(locale)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 160)
                }
            }
        }
    }

    // MARK: - Text

    private var text: some View {
        SectionGroup("Text") {
            SectionRow("Remove filler words",
                       description: "Drops “um”, “uh” and “you know” from what gets inserted.") {
                Toggle("", isOn: bind(model.fillerRemoval, model.setFillerRemoval))
                    .labelsHidden()
            }
            SectionRow("End sentences with a period") {
                Toggle("", isOn: bind(model.ensureSentencePeriod, model.setEnsureSentencePeriod))
                    .labelsHidden()
            }
            SectionRow("Space before inserted text",
                       description: model.leadingSpace.explanation) {
                Picker("", selection: binding(model.leadingSpace, model.setLeadingSpace)) {
                    ForEach(WindowSettings.LeadingSpaceOption.allCases, id: \.self) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 240)
            }
            terminalBundles
        }
    }

    /// The apps that get typed text instead of a paste. Machine values, so the
    /// rows are `mono` (§1.4).
    private var terminalBundles: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s8) {
            SectionRow("Apps that get typed text",
                       description: "Terminals take a paste badly. Wisprit types into these "
                           + "instead.") {
                Button(terminalsExpanded ? "Done" : "\(model.terminalBundleIDs.count) apps") {
                    terminalsExpanded.toggle()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            if terminalsExpanded {
                VStack(alignment: .leading, spacing: Theme.Space.s4) {
                    ForEach(model.terminalBundleIDs, id: \.self) { bundle in
                        HStack(spacing: Theme.Space.s8) {
                            Text(bundle)
                                .font(Theme.font(Theme.Role.mono))
                                .foregroundStyle(Theme.ink)
                            Spacer(minLength: Theme.Space.s8)
                            Button {
                                model.setTerminalBundleIDs(
                                    model.terminalBundleIDs.filter { $0 != bundle })
                            } label: {
                                Image(systemName: "minus.circle")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.inkTertiary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove \(bundle)")
                        }
                        .frame(height: Theme.Size.hitTarget)
                    }
                    HStack(spacing: Theme.Space.s8) {
                        TextField("com.example.terminal", text: $terminalDraft)
                            .textFieldStyle(.plain)
                            .font(Theme.font(Theme.Role.mono))
                            .frame(width: 240, height: Theme.Size.hitTarget)
                            .padding(.horizontal, Theme.Space.s8)
                            .background(
                                RoundedRectangle(cornerRadius: Theme.Radius.control,
                                                 style: .continuous)
                                    .fill(Theme.fillSubtle))
                            .onSubmit(addTerminal)
                        Button("Add", action: addTerminal)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(terminalDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .padding(.leading, Theme.Space.s8)
                .padding(.bottom, Theme.Space.s8)
            }
        }
    }

    private func addTerminal() {
        let value = terminalDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        model.setTerminalBundleIDs(model.terminalBundleIDs + [value])
        terminalDraft = ""
    }

    // MARK: - AI cleanup (gated)

    @ViewBuilder
    private var aiCleanup: some View {
        switch WindowSettings.appleIntelligenceGate(available: model.facts.aiAvailable,
                                                    reason: model.facts.aiReason) {
        case .absent:
            EmptyView()
        case .fixable(let message, let fixTitle, let fix):
            missingGroup("AI cleanup", message: message, fixTitle: fixTitle, fix: fix)
        case .available:
            SectionGroup("AI cleanup") {
                SectionRow("Clean up with Apple Intelligence",
                           description: "Punctuation and tidying, on this Mac. The verbatim "
                               + "text is used whenever the model is slow or unsure.") {
                    Toggle("", isOn: bind(model.aiCleanup, model.setAiCleanup))
                        .labelsHidden()
                }
                if model.aiCleanup {
                    AdvancedRows {
                        SectionRow("Skip transcripts longer than") {
                            HStack(spacing: Theme.Space.s8) {
                                readout("\(model.aiCleanupMaxWords) words")
                                Stepper("", value: intStepper(model.aiCleanupMaxWords,
                                                              model.setAiCleanupMaxWords),
                                        in: WindowSettings.aiCleanupMaxWordsRange,
                                        step: WindowSettings.aiCleanupMaxWordsStep)
                                    .labelsHidden()
                            }
                        }
                        SectionRow("Give up after") {
                            HStack(spacing: Theme.Space.s8) {
                                readout("\(model.aiCleanupTimeoutMs) ms")
                                Stepper("", value: intStepper(model.aiCleanupTimeoutMs,
                                                              model.setAiCleanupTimeoutMs),
                                        in: WindowSettings.aiCleanupTimeoutRange,
                                        step: WindowSettings.aiCleanupTimeoutStep)
                                    .labelsHidden()
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Live Typing (gated)

    @ViewBuilder
    private var liveTyping: some View {
        switch WindowSettings.liveTypingGate(isStaged: model.facts.imStaged,
                                             mark: liveTypingItem?.mark) {
        case .absent:
            EmptyView()
        case .fixable(let message, let fixTitle, let fix):
            missingGroup("Live Typing", message: message, fixTitle: fixTitle, fix: fix)
        case .available:
            SectionGroup("Live Typing", footnote: SetupChecklist.liveTypingPerAppNote) {
                SectionRow("Type into the field as I speak") {
                    Toggle("", isOn: bind(model.liveTypingEnabled, model.setLiveTypingEnabled))
                        .labelsHidden()
                }
                if model.liveTypingEnabled {
                    AdvancedRows {
                        SectionRow("Keep the input source warm",
                                   description: model.imSelectionPolicy.explanation) {
                            Picker("", selection: binding(model.imSelectionPolicy,
                                                          model.setImSelectionPolicy)) {
                                ForEach(WindowSettings.SelectionPolicyOption.allCases,
                                        id: \.self) { option in
                                    Text(option.label).tag(option)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(width: 220)
                        }
                    }
                }
                // What the ladder has actually learned on this machine, so the
                // footnote above stops being an abstraction the moment there is
                // a real example. Hidden when there is none.
                if !model.liveTypingFallbacks.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.Space.s4) {
                        Text("Apps that fall back to pasting")
                            .font(Theme.font(Theme.Role.captionEmph))
                            .tracking(Theme.Role.captionEmph.tracking)
                            .foregroundStyle(Theme.inkTertiary)
                        ForEach(model.liveTypingFallbacks) { verdict in
                            Text("\(verdict.displayName) — \(verdict.behaviour)")
                                .font(Theme.font(Theme.Role.caption))
                                .foregroundStyle(Theme.inkSecondary)
                        }
                    }
                    .padding(.top, Theme.Space.s8)
                }
            }
        }
    }

    private var liveTypingItem: SetupItem? {
        model.items.first { $0.id == SetupChecklist.liveTypingID }
    }

    // MARK: - The pill

    private var pill: some View {
        SectionGroup("The pill") {
            SectionRow("Show the floating pill",
                       description: "The capsule that shows the level meter while you speak.") {
                Toggle("", isOn: Binding(get: { !model.pillHidden },
                                         set: { model.setPillHidden(!$0) }))
                    .labelsHidden()
            }
            SectionRow("Reset its position",
                       description: "Puts it back at the bottom of the screen.") {
                Button("Reset") { model.resetPillPosition() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!model.hasPillPosition)
            }
        }
    }

    // MARK: - History & privacy

    private var historyAndPrivacy: some View {
        SectionGroup("History & privacy") {
            SectionRow("Save transcripts") {
                Toggle("", isOn: bind(model.historyEnabled, model.setHistoryEnabled))
                    .labelsHidden()
            }
            SectionRow("Keep at most") {
                Picker("", selection: binding(model.historyLimit, model.setHistoryLimit)) {
                    ForEach(WindowSettings.historyLimitChoices, id: \.self) { limit in
                        Text(limit.formatted()).tag(limit)
                    }
                }
                .labelsHidden()
                .frame(width: 120)
            }
            SectionRow("Delete all transcripts…") {
                Button("Delete All") { confirmingDelete = true }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(Theme.critical)
            }
            // The one static row in the whole page, and the reason Wisprit
            // exists: there is no network call to switch off, because there is
            // no network code.
            HStack(alignment: .top, spacing: Theme.Space.s12) {
                Image(systemName: "network.slash")
                    .font(.system(size: 15, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Theme.inkSecondary)
                Text("No network calls. Ever.\nAudio and text never leave this Mac.")
                    .font(Theme.font(Theme.Role.body))
                    .foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.vertical, Theme.Space.s12)
        }
    }

    // MARK: - Advanced

    private var advanced: some View {
        SectionGroup("Advanced") {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 0) {
                    SectionRow("Clipboard restore delay",
                               description: "How long Wisprit waits after pasting before it "
                                   + "puts your old clipboard back.") {
                        HStack(spacing: Theme.Space.s8) {
                            Slider(value: intSlider(model.pasteRestoreDelayMs,
                                                    model.setPasteRestoreDelayMs),
                                   in: range(WindowSettings.pasteRestoreRange),
                                   step: Double(WindowSettings.pasteRestoreStep))
                                .frame(width: 160)
                            readout("\(model.pasteRestoreDelayMs) ms")
                        }
                    }
                    SectionRow("Give up on the final after") {
                        HStack(spacing: Theme.Space.s8) {
                            readout("\(model.finalizeTimeoutMs) ms")
                            Stepper("", value: intStepper(model.finalizeTimeoutMs,
                                                          model.setFinalizeTimeoutMs),
                                    in: WindowSettings.finalizeTimeoutRange,
                                    step: WindowSettings.finalizeTimeoutStep)
                                .labelsHidden()
                        }
                    }
                    SectionRow("Speech engine") {
                        Picker("", selection: binding(model.engine, model.setEngine)) {
                            ForEach(WindowSettings.EngineOption.allCases, id: \.self) { option in
                                Text(option.label).tag(option)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 180)
                    }
                    SectionRow("Reveal files") {
                        HStack(spacing: Theme.Space.s8) {
                            revealButton("config.json", model.configPath)
                            revealButton("metrics.log", model.metricsPath)
                            revealButton("dictionary.json", model.dictionaryPath)
                        }
                    }
                    SectionRow("Version") {
                        readout(WispritVersion.string)
                    }
                }
                .padding(.leading, Theme.Space.s8)
            } label: {
                Text("Advanced")
                    .font(Theme.font(Theme.Role.caption))
                    .tracking(Theme.Role.caption.tracking)
                    .foregroundStyle(Theme.inkTertiary)
            }
        }
    }

    private func revealButton(_ title: String, _ url: URL) -> some View {
        Button(title) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            .buttonStyle(.bordered)
            .controlSize(.small)
    }

    // MARK: - shared pieces

    /// The gated-section rule's middle state: the group header, one `body` line
    /// of explanation, and the button that fixes it. Never a disabled toggle.
    private func missingGroup(_ title: String, message: String,
                              fixTitle: String, fix: SetupFixKind) -> some View {
        SectionGroup(title) {
            HStack(alignment: .center, spacing: Theme.Space.s12) {
                Text(message)
                    .font(Theme.font(Theme.Role.body))
                    .foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Theme.Space.s16)
                Button(fixTitle) { model.fix(fix) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            .frame(minHeight: Theme.Size.rowHeightWithDescription)
        }
    }

    /// Latency, counts and config values are machine text (§1.4).
    private func readout(_ value: String) -> some View {
        Text(value)
            .font(Theme.font(Theme.Role.mono))
            .foregroundStyle(Theme.inkSecondary)
            .monospacedDigit()
    }

    private func range(_ bounds: ClosedRange<Int>) -> ClosedRange<Double> {
        Double(bounds.lowerBound)...Double(bounds.upperBound)
    }

    private func bind(_ value: Bool, _ setter: @escaping (Bool) -> Void) -> Binding<Bool> {
        Binding(get: { value }, set: setter)
    }

    private func binding<T>(_ value: T, _ setter: @escaping (T) -> Void) -> Binding<T> {
        Binding(get: { value }, set: setter)
    }

    private func intSlider(_ value: Int, _ setter: @escaping (Int) -> Void) -> Binding<Double> {
        Binding(get: { Double(value) }, set: { setter(Int($0.rounded())) })
    }

    private func intStepper(_ value: Int, _ setter: @escaping (Int) -> Void) -> Binding<Int> {
        Binding(get: { value }, set: setter)
    }
}

/// Sub-rows that only exist while their parent toggle is on, indented 8 pt
/// under a `caption` "Advanced" label (§3.6).
private struct AdvancedRows<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Advanced")
                .font(Theme.font(Theme.Role.caption))
                .tracking(Theme.Role.caption.tracking)
                .foregroundStyle(Theme.inkTertiary)
                .padding(.top, Theme.Space.s8)
            content
        }
        .padding(.leading, Theme.Space.s8)
    }
}
#endif
