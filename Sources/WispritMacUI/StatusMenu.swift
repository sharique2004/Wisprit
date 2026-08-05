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
        public var toggleDictation: () -> Void
        public var toggleAiCleanup: () -> Void
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
                    toggleDictation: @escaping () -> Void,
                    toggleAiCleanup: @escaping () -> Void,
                    copyToClipboard: @escaping (String) -> Void = StatusMenu.copyToPasteboard,
                    pasteLast: @escaping () -> Void,
                    openDictionary: @escaping () -> Void,
                    openConfig: @escaping () -> Void,
                    runDoctor: @escaping () -> Void,
                    purgeHistory: @escaping () -> Void,
                    quit: @escaping () -> Void) {
            self.state = state
            self.toggleDictation = toggleDictation
            self.toggleAiCleanup = toggleAiCleanup
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
    public func rebuild() {
        guard let menu else { return }
        rows = StatusMenuModel.build(actions.state())
        menu.removeAllItems()
        for (index, row) in rows.enumerated() {
            if row.isSeparator {
                menu.addItem(NSMenuItem.separator())
                continue
            }
            let item = NSMenuItem(title: row.title,
                                  action: row.action == nil ? nil : #selector(itemFired(_:)),
                                  keyEquivalent: "")
            item.tag = index
            item.isEnabled = row.isEnabled && row.action != nil
            item.state = row.isChecked ? .on : .off
            if row.action != nil { item.target = self }
            if let text = row.representedText { item.representedObject = text }
            menu.addItem(item)
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
        case .toggleDictation:
            actions.toggleDictation()
            rebuild()
        case .toggleAiCleanup:
            actions.toggleAiCleanup()
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
