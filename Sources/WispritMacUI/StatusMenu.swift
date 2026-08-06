#if canImport(AppKit)
import AppKit
import WispritKit

/// The menu-bar item and its menu — the thin AppKit edge over
/// `StatusMenuModel`. Port of `app.py`'s `WispritApp` UI half.
///
/// Everything it needs from the app arrives as a closure, so this target
/// imports no core module: state is *pulled* on every open (the Python rebuilds
/// the whole menu in `menuNeedsUpdate_`, which is what keeps the recents and
/// the toggles honest without any change notification).
///
/// Main-thread only; callers come through `WispritUI.callOnMain`.
@MainActor
public final class StatusMenu: NSObject, NSMenuDelegate {
    public struct Actions {
        /// Sampled on every menu open.
        public var state: () -> StatusMenuState
        /// Show the main window (and flip the app to a Dock-visible policy).
        public var openWindow: () -> Void
        public var toggleDictation: () -> Void
        public var toggleAiCleanup: () -> Void
        /// One of the four polish modes, by key (`clean`/`formal`/…).
        public var polishLast: (String) -> Void
        /// Run the input-method install/register/enable flow. May raise the
        /// system activation dialog — that is why it lives behind a menu click.
        public var enableLiveTyping: () -> Void
        public var toggleLiveTyping: () -> Void
        /// Defaults to the general pasteboard; injectable so tests and the
        /// integration layer can route it.
        public var copyToClipboard: (String) -> Void
        /// `session.request_paste_last()` — enqueued on the session thread so
        /// clipboard transactions stay serialised.
        public var pasteLast: () -> Void
        public var openDictionary: () -> Void
        public var openConfig: () -> Void
        public var runDoctor: () -> Void
        public var purgeHistory: () -> Void
        public var quit: () -> Void

        public init(state: @escaping () -> StatusMenuState,
                    openWindow: @escaping () -> Void = {},
                    toggleDictation: @escaping () -> Void,
                    toggleAiCleanup: @escaping () -> Void,
                    polishLast: @escaping (String) -> Void = { _ in },
                    enableLiveTyping: @escaping () -> Void = {},
                    toggleLiveTyping: @escaping () -> Void = {},
                    copyToClipboard: @escaping (String) -> Void = StatusMenu.copyToPasteboard,
                    pasteLast: @escaping () -> Void,
                    openDictionary: @escaping () -> Void,
                    openConfig: @escaping () -> Void,
                    runDoctor: @escaping () -> Void,
                    purgeHistory: @escaping () -> Void,
                    quit: @escaping () -> Void) {
            self.state = state
            self.openWindow = openWindow
            self.toggleDictation = toggleDictation
            self.toggleAiCleanup = toggleAiCleanup
            self.polishLast = polishLast
            self.enableLiveTyping = enableLiveTyping
            self.toggleLiveTyping = toggleLiveTyping
            self.copyToClipboard = copyToClipboard
            self.pasteLast = pasteLast
            self.openDictionary = openDictionary
            self.openConfig = openConfig
            self.runDoctor = runDoctor
            self.purgeHistory = purgeHistory
            self.quit = quit
        }
    }

    private let log = WLog.logger("app")
    private let actions: Actions
    private var statusItem: NSStatusItem?
    private var menu: NSMenu?
    /// Built rows, indexed by `NSMenuItem.tag`.
    private var rows: [MenuItemModel] = []

    public init(actions: Actions) {
        self.actions = actions
        super.init()
    }

    /// `_build_menu`: claim the status item, attach a delegate-driven menu.
    public func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = StatusMenuModel.glyph(for: .idle)
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        self.statusItem = item
        self.menu = menu
        rebuild()
    }

    /// `update_state`: swap the menu-bar glyph.
    public func update(state: AppState) {
        statusItem?.button?.title = StatusMenuModel.glyph(for: state)
    }

    /// String-keyed variant for callers whose state enum lives elsewhere.
    public func update(stateNamed name: String) {
        statusItem?.button?.title = StatusMenuModel.glyph(forStateNamed: name)
    }

    /// `_rebuild_menu`: throw the menu away and rebuild it from fresh state.
    ///
    /// `rows` is FLAT and tag-indexed, submenu children included, so a fired item
    /// resolves to its model with one array lookup no matter how deep it sat.
    public func rebuild() {
        guard let menu else { return }
        rows = []
        menu.removeAllItems()
        append(StatusMenuModel.build(actions.state()), to: menu)
    }

    private func append(_ models: [MenuItemModel], to menu: NSMenu) {
        for row in models {
            if row.isSeparator {
                menu.addItem(NSMenuItem.separator())
                continue
            }
            let isClickable = row.action != nil
            let item = NSMenuItem(title: row.title,
                                  action: isClickable ? #selector(itemFired(_:)) : nil,
                                  keyEquivalent: "")
            item.tag = rows.count
            rows.append(row)
            item.isEnabled = row.isEnabled && (isClickable || row.isSubmenu)
            item.state = row.isChecked ? .on : .off
            if isClickable { item.target = self }
            if let text = row.representedText { item.representedObject = text }
            menu.addItem(item)
            if let children = row.submenu {
                let sub = NSMenu(title: row.title)
                sub.autoenablesItems = false
                append(children, to: sub)
                menu.setSubmenu(sub, for: item)
            }
        }
    }

    // MARK: - NSMenuDelegate

    /// Refresh recents/toggles each time the menu opens.
    public func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild()
    }

    // MARK: - dispatch

    @objc private func itemFired(_ sender: NSMenuItem) {
        guard rows.indices.contains(sender.tag), let action = rows[sender.tag].action else { return }
        switch action {
        case .openWindow:
            actions.openWindow()
        case .toggleDictation:
            actions.toggleDictation()
            rebuild()
        case .toggleAiCleanup:
            actions.toggleAiCleanup()
            rebuild()
        case .polishLast(let mode):
            // Prefer the represented object so an item built by an older
            // version still names its mode the same way.
            actions.polishLast((sender.representedObject as? String) ?? mode)
        case .enableLiveTyping:
            actions.enableLiveTyping()
            rebuild()
        case .toggleLiveTyping:
            actions.toggleLiveTyping()
            rebuild()
        case .copyRecent:
            if let text = sender.representedObject as? String, !text.isEmpty {
                actions.copyToClipboard(text)
            }
        case .pasteLast:
            actions.pasteLast()
        case .openDictionary:
            actions.openDictionary()
        case .openConfig:
            actions.openConfig()
        case .runDoctor:
            actions.runDoctor()
        case .purgeHistory:
            actions.purgeHistory()
            rebuild()
        case .quit:
            actions.quit()
        }
    }

    /// Default `copyToClipboard`: `clearContents` + `setString_forType_`.
    /// `nonisolated` because `NSPasteboard` is one of the few AppKit types the
    /// Python already treated as thread-safe enough (see INTERFACES.md's
    /// threading note) — and because a `@MainActor` default argument would not
    /// fit the plain closure the struct stores.
    nonisolated public static func copyToPasteboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}
#endif
