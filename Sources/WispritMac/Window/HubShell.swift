#if os(macOS)
import AppKit
import SwiftUI
import WispritMacUI

/// The Hub — `docs/design/ui-redesign.md` §3.1–3.2.
///
/// A vibrant sidebar and an inset content card on `ground`, under a transparent
/// full-size titlebar. Three things make it that rather than a plain
/// `NavigationSplitView`:
///
///  * The sidebar has a *pinned* bottom group (Setup · Settings) and a status
///    footer. A `List(selection:)` can express neither without fighting it.
///  * The nav row's selection, badge dot and pitch are all specified to the
///    point (§3.2), and the system sidebar style overrides most of them.
///  * The 52 pt titlebar band has to be laid out, not inherited: the window is
///    `fullSizeContentView` with a hidden title, so nothing else reserves it.
///
/// What is NOT hand-rolled is the material. `NSVisualEffectView` with
/// `.sidebar` / `.behindWindow` / `.followsWindowActiveState` is the whole
/// native-advantage moment (§1.7) and there is no SwiftUI equivalent that
/// blends behind the window.
struct HubShell: View {
    @ObservedObject var model: WispritWindowModel

    var body: some View {
        HStack(spacing: 0) {
            HubSidebar(model: model)
                .frame(width: HubMetrics.sidebarWidth)
                .background(VibrantSidebar())
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.ground)
        }
        // The titlebar band is drawn by this view, not reserved by AppKit: the
        // sidebar material has to run behind the traffic lights, and the content
        // card has to start below them.
        .ignoresSafeArea(.container, edges: .top)
        .sheet(isPresented: onboardingPresented) {
            OnboardingSheet(model: model)
        }
    }

    @ViewBuilder
    private var detail: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: HubMetrics.titlebarBand)
            ContentCard {
                page
            }
        }
    }

    @ViewBuilder
    private var page: some View {
        switch model.selectedTab {
        case .home: HomePage(model: model)
        case .dictionary: DictionaryPage(model: model)
        case .insights: InsightsPage(model: model)
        case .setup: SetupPage(model: model)
        case .settings: SettingsPage(model: model)
        }
    }

    private var onboardingPresented: Binding<Bool> {
        Binding(get: { model.isOnboarding },
                set: { if !$0 { model.dismissOnboarding() } })
    }
}

// MARK: - metrics

/// §3.2's table, in one place. These are *sizes*, not paddings — the 4 pt
/// spacing scale in `Theme.Space` still governs everything inside a page.
enum HubMetrics {
    static let sidebarWidth: Double = 216
    /// Room for the traffic lights. Sidebar content and the content card both
    /// begin below it.
    static let titlebarBand: Double = 52
    /// The page header inside the card: title left, actions right.
    static let pageHeader: Double = 52
    static let navRowHeight: Double = 32
    /// Row height + 4 pt gap.
    static let navRowPitch: Double = 36
    static let navRowInsetLeading: Double = 12
    static let navRowInsetTrailing: Double = 10
    static let cardInset: Double = 10
    static let statusDot: Double = 6
    static let badgeDot: Double = 6
    static let footerHeight: Double = 28
}

// MARK: - sidebar

private struct HubSidebar: View {
    @ObservedObject var model: WispritWindowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: HubMetrics.titlebarBand)
            navGroup(WispritWindowModel.Tab.primary)
            Spacer(minLength: Theme.Space.s16)
            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 1)
                .padding(.horizontal, Theme.Space.s12)
                .padding(.bottom, Theme.Space.s8)
            navGroup(WispritWindowModel.Tab.pinned)
            footer
        }
    }

    private func navGroup(_ tabs: [WispritWindowModel.Tab]) -> some View {
        VStack(alignment: .leading, spacing: HubMetrics.navRowPitch - HubMetrics.navRowHeight) {
            ForEach(tabs) { tab in
                NavRow(tab: tab,
                       isSelected: model.selectedTab == tab,
                       badge: tab == .setup ? model.setupBadge : nil) {
                    model.selectedTab = tab
                }
            }
        }
        .padding(.horizontal, Theme.Space.s8)
    }

    /// The third sanctioned orange (§1.6): the dot is `hot` only while audio is
    /// actually open.
    private var footer: some View {
        let status = model.sidebarStatus
        return HStack(spacing: Theme.Space.s8) {
            Circle()
                .fill(color(for: status))
                .frame(width: HubMetrics.statusDot, height: HubMetrics.statusDot)
            Text(status.label)
                .font(Theme.font(Theme.Role.caption))
                .tracking(Theme.Role.caption.tracking)
                .foregroundStyle(Theme.inkSecondary)
            Spacer(minLength: 0)
        }
        .frame(height: HubMetrics.footerHeight)
        .padding(.horizontal, Theme.Space.s20)
        .padding(.bottom, Theme.Space.s8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Wisprit is \(status.label.lowercased())")
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

/// One sidebar row. Selection is the single place in the app that defers to the
/// user's macOS accent colour (§3.2) — justified there, and nowhere else.
private struct NavRow: View {
    let tab: WispritWindowModel.Tab
    let isSelected: Bool
    let badge: WispritWindowModel.SetupBadge?
    let select: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: Theme.Space.s8) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 15, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(isSelected ? Color.accentColor : Theme.inkSecondary)
                    .frame(width: Theme.Space.s20, alignment: .center)
                Text(tab.title)
                    .font(Theme.font(Theme.Role.rowTitle))
                    .foregroundStyle(Theme.ink)
                Spacer(minLength: Theme.Space.s4)
                if let badge {
                    Circle()
                        .fill(badge == .blocking ? Theme.critical : Theme.attention)
                        .frame(width: HubMetrics.badgeDot, height: HubMetrics.badgeDot)
                        .accessibilityLabel(badge == .blocking
                                            ? "needs setup" : "needs attention")
                }
            }
            .padding(.leading, HubMetrics.navRowInsetLeading)
            .padding(.trailing, HubMetrics.navRowInsetTrailing)
            .frame(height: HubMetrics.navRowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(background)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    private var background: Color {
        if isSelected { return Color.accentColor.opacity(0.16) }
        return isHovering ? Theme.fillHover : .clear
    }
}

// MARK: - content card

/// The inset card every page lives in: flat `surface`, one hairline, no shadow.
/// Transcripts have to be legible on any desktop, so there is no material here
/// and no elevation beyond the value step (§1.7).
struct ContentCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .fill(Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1)
            )
            .padding(HubMetrics.cardInset)
    }
}

/// A page inside the card: a 52 pt header (title left, actions right) over
/// whatever the page draws, with §3.2's 24 / 20 / 24 padding.
struct HubPage<Actions: View, Content: View>: View {
    let title: String
    @ViewBuilder var actions: Actions
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: Theme.Space.s12) {
                Text(title)
                    .font(Theme.font(Theme.Role.pageTitle))
                    .tracking(Theme.Role.pageTitle.tracking)
                    .foregroundStyle(Theme.ink)
                Spacer(minLength: Theme.Space.s16)
                actions
            }
            .frame(height: HubMetrics.pageHeader)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.horizontal, Theme.Space.s24)
        .padding(.top, Theme.Space.s20)
        .padding(.bottom, Theme.Space.s24)
    }
}

extension HubPage where Actions == EmptyView {
    init(title: String, @ViewBuilder content: () -> Content) {
        self.init(title: title, actions: { EmptyView() }, content: content)
    }
}

// MARK: - material

/// §1.7's one vibrancy site. `.behindWindow` blending is what makes the sidebar
/// sample the desktop rather than the window, and
/// `.followsWindowActiveState` is what dims it when Wisprit is not frontmost —
/// the two behaviours that read as "native" and that no SwiftUI material gives
/// you on macOS.
private struct VibrantSidebar: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
#endif
