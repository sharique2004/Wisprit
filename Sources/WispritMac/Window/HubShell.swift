#if os(macOS)
import AppKit
import SwiftUI
import WispritMacUI

/// The Hub — a stock `NavigationSplitView` with a system toolbar.
///
/// The first Hub drew its own sidebar (an `NSVisualEffectView` slab), its own
/// 52 pt titlebar band, and an inset content card. All three are gone, on the
/// research in docs/design (Apple HIG + WWDC25 219/356): Liquid Glass belongs
/// to the navigation layer, which the system draws, and macOS 27 changed that
/// layer again (edge-to-edge sidebars, one window corner radius, a system glass
/// slider) — a hand-drawn sidebar picks up none of it, the stock one picks up
/// all of it, including Reduce Transparency / Increase Contrast behaviour.
///
/// So: the sidebar is a `List` of the three daily destinations; page titles
/// and page actions live in the window toolbar (bridged from SwiftUI by
/// `MainWindowController`); the studio palette is the CONTENT layer only.
/// Setup became the health sheet behind the toolbar's status capsule, and
/// Settings moved to its own ⌘, window.
struct HubShell: View {
    @ObservedObject var model: WispritWindowModel

    var body: some View {
        NavigationSplitView {
            List(selection: sidebarSelection) {
                ForEach(WispritWindowModel.Tab.primary) { tab in
                    Label(tab.title, systemImage: tab.symbol)
                        .badge(badgeCount(for: tab))
                        .tag(tab)
                }
            }
            .navigationSplitViewColumnWidth(min: 176, ideal: 196, max: 260)
        } detail: {
            page
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Theme.surface)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        StatusCapsule(model: model)
                    }
                }
        }
        .sheet(isPresented: onboardingPresented) {
            OnboardingSheet(model: model)
        }
        .sheet(isPresented: $model.isShowingHealth) {
            SetupPage(model: model, onDone: { model.isShowingHealth = false })
        }
    }

    @ViewBuilder
    private var page: some View {
        switch model.selectedTab {
        case .home: HomePage(model: model)
        case .dictionary: DictionaryPage(model: model)
        case .insights: InsightsPage(model: model)
        // Never selected (see `route(to:)`); kept total so a stale value can
        // never blank the window.
        case .setup, .settings: HomePage(model: model)
        }
    }

    /// `List` wants an optional selection; nil (a click in empty sidebar
    /// space) keeps the page that is already showing.
    private var sidebarSelection: Binding<WispritWindowModel.Tab?> {
        Binding(get: { model.selectedTab },
                set: { if let tab = $0 { model.route(to: tab) } })
    }

    /// Dictionary's count of items waiting on a decision. Zero hides the badge.
    private func badgeCount(for tab: WispritWindowModel.Tab) -> Int {
        tab == .dictionary ? model.dictionaryReviewCount : 0
    }

    private var onboardingPresented: Binding<Bool> {
        Binding(get: { model.isOnboarding },
                set: { if !$0 { model.dismissOnboarding() } })
    }
}

// MARK: - status capsule

/// The toolbar's one piece of live state, replacing the sidebar footer (the
/// HIG: no critical information at the bottom of a sidebar). It names the
/// microphone that will be used, so a headset that is about to dictate is
/// visible BEFORE the key goes down, and it is the door to the health sheet.
///
/// The dot is `hot` only while audio is actually open (§1.6's orange rule).
struct StatusCapsule: View {
    @ObservedObject var model: WispritWindowModel

    var body: some View {
        let status = model.sidebarStatus
        Button {
            model.route(to: .setup)
        } label: {
            HStack(spacing: Theme.Space.s8) {
                Circle()
                    .fill(color(for: status))
                    .frame(width: 7, height: 7)
                Text(label(for: status))
                    .font(Theme.font(Theme.Role.caption))
                    .foregroundStyle(status == .needsSetup ? Theme.ink : Theme.inkSecondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, Theme.Space.s4)
        }
        .help(status == .needsSetup ? "Something needs fixing — open Setup" : "Setup and health")
        .accessibilityLabel("Wisprit is \(status.label.lowercased()). Open setup.")
    }

    private func label(for status: WispritWindowModel.SidebarStatus) -> String {
        switch status {
        case .needsSetup:
            return "Needs setup · Fix"
        case .ready, .listening:
            let mic = model.facts.inputDeviceName
            return mic.isEmpty ? status.label : "\(status.label) · \(mic)"
        case .dictationOff:
            return status.label
        }
    }

    private func color(for status: WispritWindowModel.SidebarStatus) -> Color {
        switch status {
        case .listening: return Theme.hot(.sidebarStatusDot)
        case .needsSetup: return Theme.critical
        case .dictationOff: return Theme.inkTertiary
        case .ready: return Theme.positive
        }
    }
}

// MARK: - page container

/// A page in the Hub. The title becomes the window title (bridged into the
/// toolbar) and `actions` become the page's toolbar group, trailing — so the
/// page body starts at the top of the content area instead of under a header
/// row of its own, and an action can never be squeezed into "+ …" again.
struct HubPage<Actions: View, Content: View>: View {
    let title: String
    @ViewBuilder var actions: Actions
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, Theme.Space.s24)
            .padding(.top, Theme.Space.s16)
            .navigationTitle(title)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    actions
                }
            }
    }
}

extension HubPage where Actions == EmptyView {
    init(title: String, @ViewBuilder content: () -> Content) {
        self.init(title: title, actions: { EmptyView() }, content: content)
    }
}
#endif
