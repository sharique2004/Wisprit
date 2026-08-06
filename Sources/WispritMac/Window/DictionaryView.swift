#if os(macOS)
import SwiftUI

/// The custom-vocabulary table.
///
/// Two kinds of row live here and the badges say which: terms the user typed in,
/// and terms Wisprit taught itself when the user spelled a word out loud
/// ("actually it's S-H-A-R-I-Q-U-E"). Every edit goes through `DictionaryStore`,
/// so it is atomic and the running session hot-reloads it without a restart.
struct DictionaryView: View {
    @ObservedObject var model: WispritWindowModel

    @State private var selection: DictionaryRow.ID?
    @State private var editing: EditTarget?
    @State private var pendingDelete: DictionaryRow?

    /// nil `row` = adding a new term.
    private struct EditTarget: Identifiable {
        var row: DictionaryRow?
        var id: String { row?.id ?? "" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                PageHeader(
                    title: "Dictionary",
                    subtitle: "Names and jargon speech recognition keeps getting wrong. "
                        + "Each term lists the phrases Wisprit should replace with it.")
                HStack {
                    TextField("Search terms and misheard phrases", text: $model.dictionarySearch)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 320)
                    Spacer()
                    Text("\(model.filteredDictionaryRows.count) of \(model.dictionaryRows.count)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(24)

            Divider()

            Table(model.filteredDictionaryRows, selection: $selection) {
                TableColumn("Term") { row in
                    HStack(spacing: 8) {
                        Text(row.term).fontWeight(.medium)
                        ForEach(row.badges, id: \.self) { badge in
                            Text(badge)
                                .font(.caption2)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(badge == "learned" ? Color.accentColor.opacity(0.18)
                                                               : Color.secondary.opacity(0.15),
                                            in: Capsule())
                        }
                    }
                }
                TableColumn("Wisprit hears") { row in
                    Text(row.hear.isEmpty ? "—" : row.hear.joined(separator: ", "))
                        .foregroundStyle(row.hear.isEmpty ? .tertiary : .primary)
                }
                TableColumn("Last used") { row in
                    Text(row.lastUsed.map { RelativeTime.string(from: $0.timeIntervalSince1970) }
                         ?? "never")
                        .foregroundStyle(.secondary)
                }
            }
            .contextMenu(forSelectionType: DictionaryRow.ID.self) { ids in
                if let id = ids.first, let row = row(for: id) {
                    Button("Edit…") { editing = EditTarget(row: row) }
                    Button("Delete…", role: .destructive) { pendingDelete = row }
                }
            } primaryAction: { ids in
                if let id = ids.first, let row = row(for: id) {
                    editing = EditTarget(row: row)
                }
            }

            Divider()

            HStack(spacing: 10) {
                Button {
                    editing = EditTarget(row: nil)
                } label: {
                    Label("Add Term", systemImage: "plus")
                }
                Button {
                    if let id = selection, let row = row(for: id) { editing = EditTarget(row: row) }
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
                .disabled(selection == nil)
                Button(role: .destructive) {
                    if let id = selection, let row = row(for: id) { pendingDelete = row }
                } label: {
                    Label("Delete", systemImage: "minus")
                }
                .disabled(selection == nil)
                Spacer()
                Text(model.dictionaryPath.path)
                    .font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
            }
            .padding(.horizontal, 24).padding(.vertical, 12)
        }
        .sheet(item: $editing) { target in
            TermEditor(row: target.row) { term, hear in
                model.saveTerm(original: target.row, term: term, hear: hear)
            }
        }
        .alert("Delete this term?",
               isPresented: Binding(get: { pendingDelete != nil },
                                    set: { if !$0 { pendingDelete = nil } }),
               presenting: pendingDelete) { row in
            Button("Delete", role: .destructive) {
                model.deleteTerm(row.term)
                selection = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: { row in
            Text("Wisprit will stop correcting misheard spellings of “\(row.term)”.")
        }
        .onAppear { model.reloadDictionary() }
    }

    private func row(for id: DictionaryRow.ID) -> DictionaryRow? {
        model.dictionaryRows.first { $0.id == id }
    }
}

/// Add / edit sheet. The "Wisprit hears" field is comma-separated because that
/// is how the same data reads in `dictionary.json`.
private struct TermEditor: View {
    let row: DictionaryRow?
    let onSave: (String, [String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var term: String
    @State private var hear: String

    init(row: DictionaryRow?, onSave: @escaping (String, [String]) -> Void) {
        self.row = row
        self.onSave = onSave
        _term = State(initialValue: row?.term ?? "")
        _hear = State(initialValue: DictionaryEdit.formatHearField(row?.hear ?? []))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(row == nil ? "Add a term" : "Edit “\(row?.term ?? "")”")
                .font(.title3).fontWeight(.semibold)

            Form {
                TextField("Term", text: $term, prompt: Text("Sharique"))
                TextField("Wisprit hears", text: $hear,
                          prompt: Text("Shariq, Cherie"), axis: .vertical)
                    .lineLimit(2...5)
            }
            .formStyle(.grouped)

            Text("Separate misheard phrases with commas. Matching is "
                 + "case-insensitive and whole-word.")
                .font(.caption).foregroundStyle(.secondary)

            if let row, row.isLearned {
                Label("Wisprit learned this term from a spelled-out correction.",
                      systemImage: "sparkles")
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(term, DictionaryEdit.parseHearField(hear))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
#endif
