#if os(macOS)
import SwiftUI
import WispritPersistence

/// Everything Wisprit has transcribed, newest first.
///
/// Text only — the audio was never written to disk and never will be. Purge is
/// behind a confirmation because it is irreversible and the same button sits two
/// rows from Copy.
struct HistoryView: View {
    @ObservedObject var model: WispritWindowModel

    @State private var confirmingPurge = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                PageHeader(
                    title: "History",
                    subtitle: "Recent transcripts, stored on this Mac as text. "
                        + "The recording itself is never saved.")
                if !model.historyEnabled {
                    Label("History is switched off in Settings — nothing new is being saved.",
                          systemImage: "exclamationmark.circle")
                        .font(.callout).foregroundStyle(.orange)
                }
            }
            .padding(24)

            Divider()

            if model.recents.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "text.bubble")
                        .font(.system(size: 34)).foregroundStyle(.tertiary)
                    Text("Nothing yet").font(.headline)
                    Text("Hold \(SetupChecklist.hotkeyLabel(model.hotkey.rawValue)) and say "
                         + "something — it will show up here.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(model.recents.enumerated()), id: \.offset) { index, entry in
                            if index > 0 { Divider() }
                            TranscriptRow(text: entry.text,
                                          subtitle: subtitle(for: entry)) {
                                model.copy(entry.text)
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                }
            }

            Divider()

            HStack {
                Button {
                    model.refreshRecents()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                Spacer()
                Button(role: .destructive) {
                    confirmingPurge = true
                } label: {
                    Label("Purge History…", systemImage: "trash")
                }
                .disabled(model.recents.isEmpty)
            }
            .padding(.horizontal, 24).padding(.vertical, 12)
        }
        .confirmationDialog("Delete every saved transcript?",
                            isPresented: $confirmingPurge, titleVisibility: .visible) {
            Button("Delete All", role: .destructive) { model.purgeHistory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone. Paste Last will have nothing to paste.")
        }
        .onAppear { model.refreshRecents() }
    }

    private func subtitle(for entry: HistoryEntry) -> String {
        var parts = [RelativeTime.string(from: entry.ts)]
        if !entry.engine.isEmpty { parts.append(entry.engine) }
        if let ms = entry.durationMs { parts.append("\(Int(ms)) ms") }
        return parts.joined(separator: " · ")
    }
}
#endif
