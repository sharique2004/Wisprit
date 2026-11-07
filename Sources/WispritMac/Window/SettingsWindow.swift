#if os(macOS)
import AppKit
import SwiftUI
import WispritMacUI

/// The ⌘, Settings window: toolbar panes over grouped forms, the System
/// Settings shape (HIG: settings live in their own window, titled by the pane,
/// reopening the last pane used).
///
/// AppKit owns the chrome because SwiftUI's `Settings` scene needs a SwiftUI
/// `App`, and Wisprit is an AppKit agent. An `NSTabViewController` in toolbar
/// style is what that scene builds anyway: the pane icons are real toolbar
/// items (so they get the `.preference` toolbar's centring, selection capsule
/// and accessibility for free), the window title follows the selected pane,
/// and each pane is a plain SwiftUI `Form` in an `NSHostingController`.
enum SettingsPane: String, CaseIterable, Identifiable, Sendable {
    case general, microphone, writing, privacy, advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .microphone: return "Microphone"
        case .writing: return "Writing"
        case .privacy: return "Privacy"
        case .advanced: return "Advanced"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .microphone: return "mic"
        case .writing: return "character.cursor.ibeam"
        case .privacy: return "hand.raised"
        case .advanced: return "gearshape.2"
        }
    }

    /// Where the last-used pane is remembered. Window state, so it lives in
    /// the app's defaults beside the frame autosave — not in `config.json`,
    /// which holds what dictation does.
    static let defaultsKey = "SettingsSelectedPane"

    static func restored(_ raw: String?) -> SettingsPane {
        raw.flatMap(SettingsPane.init(rawValue:)) ?? .general
    }
}

/// What every pane shares beyond the model: the window's own actions, the
/// launch-time baseline the restart notice compares against, and a tick that
/// tells panes the window came back to the front.
@MainActor
final class SettingsSession: ObservableObject {
    let model: WispritWindowModel
    /// Opens the main window with the health sheet up (Setup is a sheet on
    /// the Hub, so it needs that window).
    let openSetup: () -> Void
    /// Bumped whenever the window becomes key — the Microphone pane re-reads
    /// the input volume on it.
    @Published private(set) var refreshTick = 0
    /// A pane reporting the height its form wants; the controller sizes the
    /// window to it.
    var onContentHeight: ((SettingsPane, CGFloat) -> Void)?

    /// Effective values of the launch-time settings when this window was first
    /// built — in practice, the values the running app launched with, since
    /// this window is their only writer.
    private let launchBaseline: [String]

    init(model: WispritWindowModel, openSetup: @escaping () -> Void) {
        self.model = model
        self.openSetup = openSetup
        self.launchBaseline = LaunchTimeSettings.snapshot(model.settings)
    }

    /// Titles of the settings changed here that only a restart applies.
    var pendingRestart: [String] {
        LaunchTimeSettings.changed(since: launchBaseline,
                                   now: LaunchTimeSettings.snapshot(model.settings))
    }

    func restart() { model.fix(.relaunch) }

    /// Opening the window fires both `viewWillAppear` and `didBecomeKey`;
    /// one refresh serves both.
    private var lastRefresh: Date?

    func refresh(now: Date = Date()) {
        if let lastRefresh, now.timeIntervalSince(lastRefresh) < 1 { return }
        lastRefresh = now
        model.refreshForSettings()
        refreshTick &+= 1
    }

    func report(height: CGFloat, for pane: SettingsPane) {
        onContentHeight?(pane, height)
    }
}

/// The pane switcher. One hosting controller per pane, laid out up front so a
/// pane's height is known before it is first shown and the window can animate
/// straight to it.
@MainActor
final class SettingsTabController: NSTabViewController {
    static let contentWidth: CGFloat = 640
    static let minimumHeight: CGFloat = 220
    /// Past this a pane scrolls rather than growing the window — a settings
    /// window that fills the screen stops reading as one. The screen caps it
    /// further on a small display.
    static let maximumHeight: CGFloat = 720

    /// The renderer lifts the cap to draw a whole pane for review.
    var maximumHeight = SettingsTabController.maximumHeight

    let session: SettingsSession
    private let defaults: UserDefaults?
    private let initialPane: SettingsPane
    private var heights: [SettingsPane: CGFloat] = [:]
    private var keyObserver: NSObjectProtocol?

    /// `defaults: nil` remembers nothing — the offscreen renderer must not
    /// move the user's last-used pane.
    init(session: SettingsSession, initialPane: SettingsPane? = nil,
         defaults: UserDefaults? = .standard) {
        self.session = session
        self.defaults = defaults
        self.initialPane = initialPane
            ?? SettingsPane.restored(defaults?.string(forKey: SettingsPane.defaultsKey))
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var selectedPane: SettingsPane {
        let index = selectedTabViewItemIndex
        return SettingsPane.allCases.indices.contains(index) ? SettingsPane.allCases[index] : .general
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tabStyle = .toolbar
        // The crossfade is the System Settings feel; the resize is ours (see
        // `fitWindow`), so the hosting controllers report no preferred size
        // for this controller to act on as well.
        transitionOptions = [.crossfade, .allowUserInteraction]
        canPropagateSelectedChildViewControllerTitle = true

        session.onContentHeight = { [weak self] pane, height in
            self?.noteHeight(height, for: pane)
        }
        for pane in SettingsPane.allCases {
            let host = NSHostingController(rootView: SettingsPaneRoot(pane: pane, session: session))
            host.sizingOptions = []
            host.title = pane.title
            let item = NSTabViewItem(viewController: host)
            item.label = pane.title
            item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
            item.identifier = pane.rawValue
            addTabViewItem(item)
        }
        selectedTabViewItemIndex = SettingsPane.allCases.firstIndex(of: initialPane) ?? 0
        title = initialPane.title
        // Lay every pane out once at the window's width, so each form reports
        // its height before it is first shown and a pane switch can animate
        // straight to the right size.
        for item in tabViewItems {
            guard let view = item.viewController?.view else { continue }
            view.frame = NSRect(x: 0, y: 0, width: Self.contentWidth, height: 480)
            view.layoutSubtreeIfNeeded()
        }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        session.refresh()
        guard keyObserver == nil, let window = view.window else { return }
        // Coming back to the window (after plugging in a headset, say) is when
        // the device row should catch up — not on a timer.
        keyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.session.refresh() }
        }
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        keyObserver = nil
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        fitWindow(animated: false)
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        let pane = selectedPane
        title = pane.title
        view.window?.title = pane.title
        defaults?.set(pane.rawValue, forKey: SettingsPane.defaultsKey)
        fitWindow(animated: view.window?.isVisible ?? false)
    }

    private func noteHeight(_ height: CGFloat, for pane: SettingsPane) {
        guard height.isFinite, height > 0 else { return }
        let rounded = height.rounded(.up)
        guard heights[pane] != rounded else { return }
        heights[pane] = rounded
        if pane == selectedPane {
            fitWindow(animated: view.window?.isVisible ?? false)
        }
    }

    /// Size the window to the selected pane's form, top edge fixed — the
    /// pane switch in every first-party settings window. Capped to the screen,
    /// past which the form scrolls.
    func fitWindow(animated: Bool) {
        guard let window = view.window, let wanted = heights[selectedPane],
              let contentView = window.contentView else { return }
        let screen = (window.screen ?? NSScreen.main)?.visibleFrame.height ?? 900
        let chrome = window.frame.height - contentView.frame.height
        let cap = maximumHeight.isFinite ? min(maximumHeight, screen - chrome - 40) : maximumHeight
        let target = min(max(wanted, Self.minimumHeight), cap)
        let deltaH = target - contentView.frame.height
        let deltaW = Self.contentWidth - contentView.frame.width
        guard abs(deltaH) > 0.5 || abs(deltaW) > 0.5 else { return }
        var frame = window.frame
        frame.size.height += deltaH
        frame.size.width += deltaW
        frame.origin.y -= deltaH
        window.setFrame(frame, display: true, animate: animated)
    }
}

/// Builds the Settings window — shared by `MainWindowController.showSettings`
/// and the offscreen renderer, so what gets rendered is what ships.
@MainActor
enum SettingsWindowFactory {
    static func make(model: WispritWindowModel,
                     openSetup: @escaping () -> Void,
                     initialPane: SettingsPane? = nil,
                     defaults: UserDefaults? = .standard) -> NSWindow {
        let session = SettingsSession(model: model, openSetup: openSetup)
        let controller = SettingsTabController(session: session, initialPane: initialPane,
                                               defaults: defaults)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: SettingsTabController.contentWidth, height: 480),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false)
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(NSSize(width: SettingsTabController.contentWidth, height: 480))
        window.title = controller.selectedPane.title
        return window
    }
}

/// One pane, by case.
struct SettingsPaneRoot: View {
    let pane: SettingsPane
    @ObservedObject var session: SettingsSession

    var body: some View {
        switch pane {
        case .general: GeneralPane(session: session, model: session.model)
        case .microphone: MicrophonePane(session: session, model: session.model)
        case .writing: WritingPane(session: session, model: session.model)
        case .privacy: PrivacyPane(session: session, model: session.model)
        case .advanced: AdvancedPane(session: session, model: session.model)
        }
    }
}
#endif
