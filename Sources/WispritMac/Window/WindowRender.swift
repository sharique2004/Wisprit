#if os(macOS)
import AppKit
import SwiftUI
import WispritDictionary
import WispritKit
import WispritMacUI
import WispritPersistence

/// `Wisprit render-window <page> <out.png> [--size WxH] [--light]`
///
/// Renders one window surface offscreen, against this Mac's REAL stores
/// (history, dictionary, metrics, settings — all read-only here), and writes a
/// PNG. It never opens a microphone, installs a hotkey tap, takes the
/// single-instance lock or shows a window, so it is safe to run beside the
/// installed app — which is the point: design work on the window can be
/// looked at without quitting the copy someone is dictating with.
///
/// Pages: `home`, `dictionary`, `insights` (the Hub with its sidebar and
/// toolbar), `setup` (the health sheet), `settings` (the ⌘, window, built by
/// the same factory the app uses; `--pane general|microphone|writing|privacy|
/// advanced` picks the pane, and the window fits that pane's height the way
/// the real one does, so `--size` sets only its starting size; `--full` lifts
/// the height cap to draw a long pane whole).
@MainActor
enum WindowRender {
    static let usage = "usage: Wisprit render-window <home|dictionary|insights|setup|settings> <out.png> [--size WxH] [--light] [--settle SECONDS] [--pane NAME] [--full] [--select first|missed|changed] [--heard] [--search TEXT] [--history PATH]"

    static func run(arguments: [String]) -> Never {
        guard arguments.count >= 2 else {
            FileHandle.standardError.write(Data((usage + "\n").utf8))
            exit(2)
        }
        let page = arguments[0]
        let out = URL(fileURLWithPath: arguments[1])
        var size = NSSize(width: 1040, height: 700)
        var light = false
        var settle: TimeInterval = 2.5
        var pane: SettingsPane?
        var full = false
        // Dictations only: open the inspector on a row, show its Heard side,
        // or render with a filter typed.
        var preselect: DictationsFeed.Preselect?
        var showsHeard = false
        var search: String?
        // A history file other than the live one — a fixture, or a copy.
        var historyPath = WispritPaths.historyPath
        var index = 2
        while index < arguments.count {
            switch arguments[index] {
            case "--light": light = true
            case "--size" where index + 1 < arguments.count:
                let parts = arguments[index + 1].split(separator: "x").compactMap { Double($0) }
                if parts.count == 2 { size = NSSize(width: parts[0], height: parts[1]) }
                index += 1
            case "--settle" where index + 1 < arguments.count:
                settle = Double(arguments[index + 1]) ?? settle
                index += 1
            case "--full": full = true
            case "--pane" where index + 1 < arguments.count:
                guard let named = SettingsPane(rawValue: arguments[index + 1]) else {
                    FileHandle.standardError.write(Data("unknown pane \(arguments[index + 1])\n".utf8))
                    exit(2)
                }
                pane = named
                index += 1
            case "--select" where index + 1 < arguments.count:
                preselect = DictationsFeed.Preselect(rawValue: arguments[index + 1])
                index += 1
            case "--heard": showsHeard = true
            case "--history" where index + 1 < arguments.count:
                historyPath = URL(fileURLWithPath: arguments[index + 1])
                index += 1
            case "--search" where index + 1 < arguments.count:
                search = arguments[index + 1]
                index += 1
            default: break
            }
            index += 1
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        let settings = Settings.load()
        let dictionary = DictionaryStore()
        // Read-only: a render must never write the user's live database, not
        // even an additive CREATE TABLE.
        let history = History(path: historyPath,
                              settings: settings,
                              detailEnabled: HistoryDetailSettings.isEnabled(settings),
                              readOnly: true)
        let model = WispritWindowModel(
            settings: settings,
            dictionary: DictionaryEditor(store: dictionary),
            snippets: SnippetStore(),
            identity: IdentityStore(),
            ports: AppController.makeWindowPorts(history: history,
                                                 settings: settings,
                                                 tierCache: BundleCapabilityCache(),
                                                 dictionary: dictionary,
                                                 pendingLearns: PendingLearnStore(),
                                                 metrics: MetricsWriter(),
                                                 // Read-only render: nothing pastes, nothing fixes.
                                                 paste: { _ in },
                                                 fix: { _ in }))

        let root: AnyView
        switch page {
        case "home", "dictionary", "insights":
            model.selectedTab = WispritWindowModel.Tab(rawValue: page) ?? .home
            root = AnyView(HubShell(model: model))
        case "setup":
            root = AnyView(SetupPage(model: model))
        case "settings":
            root = AnyView(EmptyView())
        default:
            FileHandle.standardError.write(Data("unknown page \(page)\n\(usage)\n".utf8))
            exit(2)
        }

        let window: NSWindow
        if page == "settings" {
            // The shipping window, remembering nothing: a render must not move
            // the user's last-used pane.
            window = SettingsWindowFactory.make(model: model, openSetup: {},
                                                initialPane: pane ?? .general,
                                                defaults: nil)
            // `--full` draws the whole pane instead of the scrolled window.
            if full { (window.contentViewController as? SettingsTabController)?.maximumHeight = .infinity }
            window.setContentSize(size)
        } else {
            window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable,
                                          .fullSizeContentView],
                              backing: .buffered, defer: false)
            window.toolbarStyle = .unified
            window.title = "Wisprit"
            let host = NSHostingController(rootView: root)
            host.sceneBridgingOptions = [.title, .toolbars]
            window.contentViewController = host
            window.setContentSize(size)
        }
        window.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        // Off every screen: laid out and drawn, never seen.
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()

        model.dictationsFeed.preselect = preselect
        model.dictationsFeed.showsHeard = showsHeard
        if let search {
            model.historySearch = search
            model.dictationsFeed.preselectQuery = search
        }
        model.windowDidOpen()
        Task { await model.refreshFull() }
        RunLoop.main.run(until: Date().addingTimeInterval(settle))

        // The theme frame, not the content view, so the toolbar and the
        // sidebar's titlebar region are in the picture too.
        guard let frameView = window.contentView?.superview else { exit(1) }
        let bounds = frameView.bounds
        guard let rep = frameView.bitmapImageRepForCachingDisplay(in: bounds) else { exit(1) }
        frameView.cacheDisplay(in: bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
        do {
            try png.write(to: out)
        } catch {
            FileHandle.standardError.write(Data("cannot write \(out.path): \(error)\n".utf8))
            exit(1)
        }
        print(out.path)
        exit(0)
    }
}
#endif
