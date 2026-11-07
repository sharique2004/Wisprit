#if os(macOS)
import SwiftUI

/// Writing — what happens to the words between hearing and the cursor:
/// language, cleanup, word-level replacements, how text is typed, and the
/// apps that are treated differently.
///
/// Gated features keep the rule the old page set: a feature this Mac cannot
/// have has no row; one it could have but does not yet gets one row and one
/// button — never a disabled switch.
struct WritingPane: View {
    @ObservedObject var session: SettingsSession
    @ObservedObject var model: WispritWindowModel

    var body: some View {
        PaneForm(pane: .writing, session: session, model: model) {
            Section {
                language
            }

            Section("Cleanup") {
                aiCleanup
                Toggle(isOn: Binding(get: { model.fillerRemoval }, set: model.setFillerRemoval)) {
                    rowLabel("Remove filler words", "Drops “um”, “uh” and “you know”.")
                }
                Toggle(isOn: Binding(get: { model.ensureSentencePeriod },
                                     set: model.setEnsureSentencePeriod)) {
                    rowLabel("End with a period", "Adds one when a sentence has none.")
                }
                Picker(selection: Binding(get: { model.leadingSpace }, set: model.setLeadingSpace)) {
                    ForEach(WindowSettings.LeadingSpaceOption.allCases, id: \.self) { option in
                        Text(option.label).tag(option)
                    }
                } label: {
                    rowLabel("Space before text", leadingSpaceHelp)
                }
            }

            Section("Words") {
                Toggle(isOn: Binding(get: { model.vocabularyRetro }, set: model.setVocabularyRetro)) {
                    rowLabel("Fix misheard dictionary terms",
                             "Swaps in your term after the words land.")
                }
                Toggle(isOn: Binding(get: { model.emojiCommands }, set: model.setEmojiCommands)) {
                    rowLabel("Emoji by name", "Say “fire emoji” to type 🔥.")
                }
                Toggle(isOn: Binding(get: { model.identityExpansion },
                                     set: model.setIdentityExpansion)) {
                    rowLabel("Your details", "Say “my email” to type the address saved in Dictionary.")
                }
            }

            liveTyping

            contextAwareness

            Section("Apps") {
                AppListRow(
                    title: "Type instead of paste",
                    help: "Terminals take a paste badly, so Wisprit types there.",
                    sheetTitle: "Apps that get typed text",
                    sheetHelp: "Wisprit types into these apps key by key instead of pasting.",
                    ids: model.terminalBundleIDs,
                    onChange: model.setTerminalBundleIDs)
                AppListRow(
                    title: "Skip AI cleanup in",
                    help: "Terminals and code editors get exactly what you said.",
                    sheetTitle: "Apps that stay verbatim",
                    sheetHelp: "AI cleanup is skipped while one of these apps is in front.",
                    ids: model.contextVerbatimBundleIDs,
                    onChange: model.setContextVerbatimBundleIDs)
            }
        }
    }

    // MARK: - Language

    @ViewBuilder
    private var language: some View {
        let options = model.languageOptions
        let selected = SettingsLanguage.selection(current: model.locale, in: options)
        let current = options.first { $0.id == selected }
        if options.count > 1 {
            Picker(selection: Binding(
                get: { selected ?? "" },
                set: { id in
                    if let option = options.first(where: { $0.id == id }) {
                        model.chooseLanguage(option.value)
                    }
                })) {
                ForEach(options) { option in
                    Text(option.isInstalled ? option.name : "\(option.name) — not installed")
                        .tag(option.id)
                }
            } label: {
                rowLabel("Language", languageHelp(current))
            }
        } else {
            LabeledContent {
                Text(current?.name ?? SettingsLanguage.displayName(model.locale))
                    .foregroundStyle(.secondary)
            } label: {
                rowLabel("Language", languageHelp(current))
            }
        }
    }

    private func languageHelp(_ current: SettingsLanguage.Option?) -> String {
        if let current, !current.isInstalled, model.hasProbed {
            return "Not installed. Add it in Keyboard ▸ Dictation."
        }
        return "The language Wisprit listens for."
    }

    private var leadingSpaceHelp: String {
        switch model.leadingSpace {
        case .auto: return "Only when the character before the cursor needs one."
        case .always: return "Every insertion starts with a space."
        case .never: return "Text goes in exactly at the cursor."
        }
    }

    // MARK: - AI cleanup (gated)

    @ViewBuilder
    private var aiCleanup: some View {
        switch WindowSettings.appleIntelligenceGate(available: model.facts.aiAvailable,
                                                    reason: model.facts.aiReason) {
        case .absent:
            EmptyView()
        case .fixable(_, let fixTitle, let fix):
            LabeledContent {
                Button("\(fixTitle)…") { model.fix(fix) }
            } label: {
                rowLabel("Clean up with Apple Intelligence",
                         "Turn on Apple Intelligence to use it.")
            }
        case .available:
            Toggle(isOn: Binding(get: { model.aiCleanup }, set: model.setAiCleanup)) {
                rowLabel("Clean up with Apple Intelligence",
                         "Punctuation and tidying, on this Mac.")
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
        case .fixable(_, let fixTitle, let fix):
            Section("Typing") {
                LabeledContent {
                    Button(fixTitle) { model.fix(fix) }
                } label: {
                    rowLabel("Live Typing", "Words appear in the field as you speak.")
                }
            }
        case .available:
            Section {
                Toggle(isOn: Binding(get: { model.liveTypingEnabled },
                                     set: model.setLiveTypingEnabled)) {
                    rowLabel("Live Typing", "Words appear in the field as you speak.")
                }
                if !model.liveTypingFallbacks.isEmpty {
                    LabeledContent {
                        Text(model.liveTypingFallbacks.map(\.displayName).joined(separator: ", "))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    } label: {
                        rowLabel("Pastes at the end in", "These apps don't take live text.")
                    }
                }
            } header: {
                Text("Typing")
            } footer: {
                Text("Apps that can't take live text get a paste at the end instead.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var liveTypingItem: SetupItem? {
        model.items.first { $0.id == SetupChecklist.liveTypingID }
    }

    // MARK: - Context awareness (consent-gated)

    /// Off is a button that runs the consent flow — never a bare switch to on —
    /// so the sheet is unskippable from here too. On is a switch whose only
    /// move is off.
    @ViewBuilder
    private var contextAwareness: some View {
        Section {
            if model.contextDisabledByEnvironment {
                LabeledContent {
                    Text("Off").foregroundStyle(.secondary)
                } label: {
                    rowLabel("Use text near the cursor",
                             "Turned off for this launch (WISPRIT_NO_CONTEXT=1).")
                }
            } else if model.contextAwareness {
                Toggle(isOn: Binding(get: { true },
                                     set: { if !$0 { model.setContextAwarenessOff() } })) {
                    rowLabel("Use text near the cursor",
                             "Helps with names already on screen.")
                }
            } else {
                LabeledContent {
                    Button("Turn On…") { model.fix(.enableContextAwareness) }
                } label: {
                    rowLabel("Use text near the cursor",
                             "Helps with names already on screen. Asks first.")
                }
            }
        } header: {
            Text("Context")
        } footer: {
            Text("Read for one dictation, then discarded. Never stored or sent.")
                .foregroundStyle(.secondary)
        }
    }
}
#endif
