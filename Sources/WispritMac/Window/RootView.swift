#if os(macOS)
import SwiftUI

/// The shell: a sidebar of four pages, and the first-run wizard on top of it.
///
/// Deliberately plain SwiftUI with system materials and no custom chrome — the
/// job of this window is to be legible and obviously part of macOS, not to have
/// a look of its own.
struct RootView: View {
    @ObservedObject var model: WispritWindowModel

    var body: some View {
        NavigationSplitView {
            List(selection: tabSelection) {
                Section("Wisprit") {
                    ForEach(WispritWindowModel.Tab.allCases) { tab in
                        Label(tab.title, systemImage: tab.symbol).tag(tab)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
            .listStyle(.sidebar)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        // The window's identity is the app, not the page. `.navigationTitle`
        // alone overrode `window.title`, so Mission Control, the Window menu and
        // ⌘-Tab all offered the user a window called "Status" when they were
        // looking for one called "Wisprit".
        .navigationTitle("Wisprit")
        .navigationSubtitle(model.selectedTab.title)
        .sheet(isPresented: onboardingPresented) {
            OnboardingView(model: model)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch model.selectedTab {
        case .status: StatusView(model: model)
        case .dictionary: DictionaryView(model: model)
        case .history: HistoryView(model: model)
        case .settings: SettingsView(model: model)
        }
    }

    private var tabSelection: Binding<WispritWindowModel.Tab?> {
        Binding(get: { model.selectedTab },
                set: { if let value = $0 { model.selectedTab = value } })
    }

    private var onboardingPresented: Binding<Bool> {
        Binding(get: { model.isOnboarding },
                set: { if !$0 { model.dismissOnboarding() } })
    }
}

// MARK: - Shared pieces

/// The coloured dot every checklist row leads with. Colour AND symbol, so the
/// state survives a colour-blind reader and a greyscale screenshot.
struct StatusDot: View {
    let mark: DoctorMark
    /// Switched off by the user. Neither green nor a warning: nothing is wrong,
    /// and there is nothing here to fix unless the user wants the feature.
    var isOff: Bool = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(color)
            .accessibilityLabel(label)
    }

    private var symbol: String {
        if isOff { return "minus.circle.fill" }
        switch mark {
        case .ok: return "checkmark.circle.fill"
        case .warn: return "exclamationmark.circle.fill"
        case .bad: return "xmark.circle.fill"
        }
    }

    private var color: Color {
        if isOff { return .secondary }
        switch mark {
        case .ok: return .green
        case .warn: return .orange
        case .bad: return .red
        }
    }

    private var label: String {
        if isOff { return "off" }
        switch mark {
        case .ok: return "ready"
        case .warn: return "needs attention"
        case .bad: return "missing"
        }
    }
}

/// A page header: title, one line of context, generous top margin.
struct PageHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.title2).fontWeight(.semibold)
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A framed group with a heading — the window's only container style.
struct Card<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title).font(.headline)
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Copy-on-click transcript row, used by both the playground and History.
struct TranscriptRow: View {
    let text: String
    let subtitle: String
    let onCopy: () -> Void

    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(text)
                    .font(.body)
                    .textSelection(.enabled)
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Button {
                onCopy()
                copied = true
                Task {
                    try? await Task.sleep(nanoseconds: 1_400_000_000)
                    copied = false
                }
            } label: {
                Label(copied ? "Copied" : "Copy",
                      systemImage: copied ? "checkmark" : "doc.on.doc")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture { onCopy(); copied = true }
    }
}

/// Timestamps in the window are relative ("2 minutes ago") — an absolute clock
/// time tells the user nothing about whether *this* was the dictation they just
/// tried.
enum RelativeTime {
    static func string(from unix: Double, now: Date = Date()) -> String {
        let date = Date(timeIntervalSince1970: unix)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
#endif
