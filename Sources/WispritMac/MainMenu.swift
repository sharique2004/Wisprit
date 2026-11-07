#if os(macOS)
import AppKit

/// The app's main menu.
///
/// Wisprit launches as a menu-bar agent and had no main menu at all, so once
/// the window was open ⌘, did nothing, ⌘Q did nothing, and — worse — ⌘C / ⌘V /
/// ⌘A in the window's text fields did nothing either: AppKit routes those key
/// equivalents through the Edit menu, and there wasn't one. Installing the menu
/// at launch is harmless while the app is an agent (no menu bar is drawn) and
/// is what makes the window behave like a Mac window the moment it opens.
@MainActor
enum MainMenu {
    struct Actions {
        var openSettings: () -> Void
        var showPage: (WispritWindowModel.Tab) -> Void
        var quit: () -> Void
    }

    /// Retains the closure targets for the life of the menu.
    private static var target: MenuTarget?

    static func install(_ actions: Actions) {
        let target = MenuTarget(actions)
        Self.target = target
        NSApp.mainMenu = build(target: target)
    }

    static func build(target: MenuTarget) -> NSMenu {
        let main = NSMenu()

        // Wisprit
        let app = NSMenu(title: "Wisprit")
        app.addItem(withTitle: "About Wisprit",
                    action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                    keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(item("Settings…", #selector(MenuTarget.openSettings(_:)), ",", target))
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Wisprit", action: #selector(NSApplication.hide(_:)),
                    keyEquivalent: "h")
        let hideOthers = NSMenuItem(title: "Hide Others",
                                    action: #selector(NSApplication.hideOtherApplications(_:)),
                                    keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        app.addItem(hideOthers)
        app.addItem(withTitle: "Show All",
                    action: #selector(NSApplication.unhideAllApplications(_:)),
                    keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(item("Quit Wisprit", #selector(MenuTarget.quit(_:)), "q", target))
        main.addItem(submenu(app))

        // Edit — the responder chain does the work; the items only have to exist.
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)),
                     keyEquivalent: "a")
        main.addItem(submenu(edit))

        // View — ⌘1…⌘3 follow the sidebar's order.
        let view = NSMenu(title: "View")
        for (index, tab) in WispritWindowModel.Tab.primary.enumerated() {
            let page = item(tab.title, #selector(MenuTarget.showPage(_:)), "\(index + 1)", target)
            page.representedObject = tab.rawValue
            view.addItem(page)
        }
        view.addItem(.separator())
        let sidebar = NSMenuItem(title: "Toggle Sidebar",
                                 action: #selector(NSSplitViewController.toggleSidebar(_:)),
                                 keyEquivalent: "s")
        sidebar.keyEquivalentModifierMask = [.command, .control]
        view.addItem(sidebar)
        main.addItem(submenu(view))

        // Window
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)),
                       keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)),
                       keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)),
                       keyEquivalent: "w")
        main.addItem(submenu(window))
        NSApp.windowsMenu = window

        return main
    }

    private static func item(_ title: String, _ action: Selector, _ key: String,
                             _ target: MenuTarget) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target
        return item
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let holder = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        holder.submenu = menu
        return holder
    }
}

/// Closure-backed target for the menu's own actions.
@MainActor
final class MenuTarget: NSObject {
    private let actions: MainMenu.Actions

    init(_ actions: MainMenu.Actions) {
        self.actions = actions
    }

    @objc func openSettings(_ sender: Any?) { actions.openSettings() }
    @objc func quit(_ sender: Any?) { actions.quit() }

    @objc func showPage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let tab = WispritWindowModel.Tab(rawValue: raw) else { return }
        actions.showPage(tab)
    }
}
#endif
