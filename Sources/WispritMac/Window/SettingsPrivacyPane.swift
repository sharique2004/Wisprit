#if os(macOS)
import SwiftUI

/// Privacy — the promise, what is kept, and the deletes.
///
/// Local-only is not a switch here because there is nothing to switch: there
/// is no network code. The pane says so once, then lists every store Wisprit
/// writes with its size and its own delete (R17), plus delete-everything.
struct PrivacyPane: View {
    @ObservedObject var session: SettingsSession
    @ObservedObject var model: WispritWindowModel

    /// Which delete is awaiting confirmation — one dialog serves every store
    /// plus delete-everything, so the copy and the action stay side by side.
    @State private var pendingPurge: PurgeRequest?

    enum PurgeRequest: Equatable {
        case store(DataStoreID)
        case everything
    }

    var body: some View {
        PaneForm(pane: .privacy, session: session, model: model) {
            Section {
                Label {
                    rowLabel("Audio and text never leave this Mac",
                             "Wisprit makes no network calls. Speech and cleanup run on device.")
                } icon: {
                    Image(systemName: "lock.shield")
                        .foregroundStyle(.secondary)
                }
            }

            Section("History") {
                Toggle(isOn: Binding(get: { model.historyEnabled }, set: model.setHistoryEnabled)) {
                    rowLabel("Save transcripts", "So you can search, copy and paste them again.")
                }
                if model.historyEnabled {
                    Picker(selection: Binding(get: { model.historyLimit }, set: model.setHistoryLimit)) {
                        ForEach(WindowSettings.historyLimitChoices, id: \.self) { limit in
                            Text("\(limit.formatted()) dictations").tag(limit)
                        }
                    } label: {
                        rowLabel("Keep the last", "Older ones are deleted as new ones arrive.")
                    }
                    Toggle(isOn: Binding(get: { model.historyDetail }, set: model.setHistoryDetail)) {
                        rowLabel("Keep what was heard",
                                 "Stores the raw words beside the cleaned-up text.")
                    }
                }
            }

            if !model.dataStores.isEmpty {
                Section {
                    ForEach(model.dataStores) { store in
                        LabeledContent {
                            HStack(spacing: 8) {
                                Readout(text: DataInventory.sizeLabel(store))
                                if store.deletable {
                                    Button("Delete…", role: .destructive) {
                                        pendingPurge = .store(store.id)
                                    }
                                    .disabled(!store.exists)
                                }
                            }
                        } label: {
                            rowLabel(store.title, DataStoreCopy.help(store.id))
                        }
                    }
                } header: {
                    Text("Stored on this Mac")
                } footer: {
                    Text(DataStoreCopy.footer).foregroundStyle(.secondary)
                }

                Section {
                    LabeledContent {
                        Button("Delete Everything…", role: .destructive) {
                            pendingPurge = .everything
                        }
                        .disabled(!model.dataStores.contains { $0.deletable && $0.exists })
                    } label: {
                        rowLabel("Delete all data", "Every store above at once. Settings stay.")
                    }
                }
            }
        }
        .confirmationDialog(purgeTitle,
                            isPresented: Binding(get: { pendingPurge != nil },
                                                 set: { if !$0 { pendingPurge = nil } }),
                            titleVisibility: .visible) {
            Button(purgeActionTitle, role: .destructive) { performPendingPurge() }
            Button("Cancel", role: .cancel) { pendingPurge = nil }
        } message: {
            Text(purgeMessage)
        }
    }

    // MARK: - the purge dialog (copy unchanged from the single-page Settings)

    private var purgeTitle: String {
        switch pendingPurge {
        case .store(let id): return "Delete \(DataInventory.title(for: id).lowercased())?"
        case .everything: return "Delete everything Wisprit keeps?"
        case nil: return ""
        }
    }

    private var purgeActionTitle: String {
        switch pendingPurge {
        case .store(.transcripts): return "Delete All Transcripts"
        case .store(let id): return "Delete \(DataInventory.title(for: id))"
        case .everything: return "Delete Everything"
        case nil: return "Delete"
        }
    }

    private var purgeMessage: String {
        switch pendingPurge {
        case .store(.transcripts):
            return model.historyDeletionWarning
        case .store(.metrics):
            return "Deletes the timing log the Insights page and `Wisprit stats` "
                + "read. It holds durations and counters, never your words. "
                + "This cannot be undone."
        case .store(.dictionary):
            return "Deletes your whole dictionary — your own terms and every "
                + "spelling Wisprit learned from your corrections. This cannot "
                + "be undone."
        case .store(.learnLedger):
            return "Deletes the pending-term evidence and your dismissals. "
                + "Terms you said no to may be proposed again."
        case .store(.models):
            return "Deletes downloaded speech models. Dictation is unaffected; "
                + "they can be downloaded again."
        case .store(.settings), nil:
            return ""
        case .everything:
            return "Transcripts, metrics, dictionary, learning ledger, and "
                + "downloaded models — every store above, in one purge. Your "
                + "settings stay. This cannot be undone."
        }
    }

    private func performPendingPurge() {
        switch pendingPurge {
        case .store(let id): model.purgeDataStore(id)
        case .everything: model.purgeAllData()
        case nil: break
        }
        pendingPurge = nil
    }
}
#endif
