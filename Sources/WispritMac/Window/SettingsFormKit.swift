#if os(macOS)
import AppKit
import SwiftUI
import WispritMacUI

// The furniture every Settings pane shares. Panes are stock grouped `Form`s —
// the System Settings look comes from the system, not from here — so this file
// is only the pieces a stock form does not have: the restart notice, the
// height report the window sizes itself to, a millisecond slider row, and the
// bundle-list editor.

/// A pane's form. Grouped, with the restart notice on top when one is due, and
/// the content height reported so the window can fit it.
struct PaneForm<Content: View>: View {
    let pane: SettingsPane
    @ObservedObject var session: SettingsSession
    @ObservedObject var model: WispritWindowModel
    @ViewBuilder var content: Content

    var body: some View {
        Form {
            let pending = session.pendingRestart
            if !pending.isEmpty {
                Section {
                    LabeledContent {
                        Button("Restart Wisprit") { session.restart() }
                    } label: {
                        Label {
                            Text("Restart to apply")
                            Text("\(LaunchTimeSettings.sentence(pending)) take effect next launch.")
                        } icon: {
                            Image(systemName: "arrow.clockwise.circle")
                        }
                    }
                }
            }
            content
        }
        .formStyle(.grouped)
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentSize.height + geometry.contentInsets.top + geometry.contentInsets.bottom
        } action: { _, height in
            session.report(height: height, for: pane)
        }
    }
}

/// Title over one line of help — the two-`Text` label a grouped form styles as
/// a row title and its secondary line. A function rather than a view so the
/// form sees the two texts directly.
@ViewBuilder
func rowLabel(_ title: String, _ help: String? = nil) -> some View {
    Text(title)
    if let help { Text(help) }
}

/// Machine numbers (milliseconds, counts) read in the monospaced digits the
/// rest of the window uses for them.
struct Readout: View {
    let text: String
    var body: some View {
        Text(text)
            .monospacedDigit()
            .foregroundStyle(.secondary)
    }
}

/// A slider row for an integer setting in milliseconds.
struct MillisecondRow: View {
    let title: String
    let help: String
    let value: Int
    let range: ClosedRange<Int>
    let step: Int
    let set: (Int) -> Void

    var body: some View {
        LabeledContent {
            HStack(spacing: 10) {
                // Continuous, snapped in the setter: a stepped macOS slider
                // draws a tick per step, which at 10 ms is a dotted rule.
                Slider(value: Binding(get: { Double(value) },
                                      set: { set(Self.snap($0, to: step)) }),
                       in: Double(range.lowerBound)...Double(range.upperBound))
                    .labelsHidden()
                    .frame(width: 150)
                Readout(text: "\(value) ms")
                    .frame(width: 58, alignment: .trailing)
            }
        } label: {
            rowLabel(title, help)
        }
    }

    static func snap(_ raw: Double, to step: Int) -> Int {
        guard step > 0 else { return Int(raw.rounded()) }
        return Int((raw / Double(step)).rounded()) * step
    }
}

/// A stepper row for an integer setting with a unit.
struct StepperRow: View {
    let title: String
    let help: String?
    let value: Int
    let unit: String
    let range: ClosedRange<Int>
    let step: Int
    let set: (Int) -> Void

    var body: some View {
        LabeledContent {
            HStack(spacing: 6) {
                Readout(text: "\(value.formatted()) \(unit)")
                Stepper("", value: Binding(get: { value }, set: set), in: range, step: step)
                    .labelsHidden()
            }
        } label: {
            rowLabel(title, help)
        }
    }
}

// MARK: - App lists

/// What a bundle id is called on this Mac, and its icon — LaunchServices'
/// answer when the app is installed, the id's last component otherwise.
enum InstalledApp {
    static func url(_ bundleID: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    static func name(_ bundleID: String) -> String {
        if let url = url(bundleID) {
            return FileManager.default.displayName(atPath: url.path)
                .replacingOccurrences(of: ".app", with: "")
        }
        return bundleID.split(separator: ".").last.map(String.init) ?? bundleID
    }

    static func icon(_ bundleID: String) -> NSImage? {
        guard let url = url(bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    /// "Terminal, iTerm and 4 more".
    static func summary(_ ids: [String], limit: Int = 2) -> String {
        guard !ids.isEmpty else { return "None" }
        let names = ids.prefix(limit).map(name)
        let rest = ids.count - names.count
        if rest <= 0 { return names.joined(separator: ", ") }
        return names.joined(separator: ", ") + " and \(rest) more"
    }
}

/// A row naming an app list, with Edit… opening the editor sheet.
struct AppListRow: View {
    let title: String
    let help: String
    let sheetTitle: String
    let sheetHelp: String
    let ids: [String]
    let onChange: ([String]) -> Void

    @State private var editing = false

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                Text(ids.count == 1 ? "1 app" : "\(ids.count) apps")
                    .foregroundStyle(.secondary)
                Button("Edit…") { editing = true }
            }
        } label: {
            rowLabel(title, help)
        }
        .sheet(isPresented: $editing) {
            AppListSheet(title: sheetTitle, help: sheetHelp, ids: ids,
                         onChange: onChange, onDone: { editing = false })
        }
    }
}

/// The list editor: installed apps by name and icon, bundle ids beside them,
/// + to choose an app (or type an id), − to remove the selection.
struct AppListSheet: View {
    let title: String
    let help: String
    let ids: [String]
    let onChange: ([String]) -> Void
    let onDone: () -> Void

    @State private var selection = Set<String>()
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(help).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(ids, id: \.self) { id in
                        HStack(spacing: 8) {
                            AppIcon(bundleID: id)
                            Text(InstalledApp.name(id))
                            Spacer(minLength: 8)
                            Text(id)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .tag(id)
                    }
                }
                .listStyle(.plain)
                .alternatingRowBackgrounds()
                .frame(minHeight: 200)
                Divider()
                // The +/− bar inside the list's frame, as System Settings'
                // own lists have it.
                HStack(spacing: 0) {
                    Button { chooseApp() } label: {
                        Image(systemName: "plus").frame(width: 24, height: 20)
                    }
                    .help("Choose an app")
                    .accessibilityLabel("Add an app")
                    Divider().frame(height: 14)
                    Button { remove() } label: {
                        Image(systemName: "minus").frame(width: 24, height: 20)
                    }
                    .disabled(selection.isEmpty)
                    .help("Remove the selected apps")
                    .accessibilityLabel("Remove the selected apps")
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor)))
            HStack(spacing: 8) {
                TextField("Or type a bundle ID, like com.example.app", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addDraft)
                Button("Add", action: addDraft)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            HStack {
                Spacer()
                Button("Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func addDraft() {
        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        onChange(ids + [value])
        draft = ""
    }

    private func remove() {
        onChange(ids.filter { !selection.contains($0) })
        selection = []
    }

    /// An open panel on /Applications; every chosen app's bundle id is added.
    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        let added = panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
        guard !added.isEmpty else { return }
        onChange(ids + added)
    }
}

private struct AppIcon: View {
    let bundleID: String
    var body: some View {
        Group {
            if let icon = InstalledApp.icon(bundleID) {
                Image(nsImage: icon).resizable()
            } else {
                Image(systemName: "app.dashed").resizable().foregroundStyle(.tertiary)
            }
        }
        .frame(width: 18, height: 18)
    }
}

/// A System Settings deep link, opened by the user's click. Opening a pane of
/// System Settings never touches the microphone.
enum SystemSettingsLink {
    static let sound = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension?input")!
    static let keyboard = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!

    static func open(_ url: URL) { NSWorkspace.shared.open(url) }
}
#endif
