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
        /// The same window, opened on the Setup page (§5.2).
        public var openSetup: () -> Void
        /// The two flags the menu-bar icon needs beyond the session state
        /// (§5.1). Sampled on every state change, so it must stay cheap — no
        /// disk, no probe.
        public var iconState: () -> StatusIconState
        public var toggleDictation: () -> Void
        public var toggleAiCleanup: () -> Void
        /// One of the four polish modes, by key (`clean`/`formal`/…).
        public var polishLast: (String) -> Void
        /// Run the input-method install/register/enable flow. May raise the
        /// system activation dialog — that is why it lives behind a menu click.
        public var enableLiveTyping: () -> Void
        public var toggleLiveTyping: () -> Void
        /// Run the context-awareness consent flow (sheet → optional AX prompt
        /// → flip). Behind a menu click for the same reason as the row above.
        public var enableContextAwareness: () -> Void
        /// Switch context awareness off (on always re-runs the consent flow).
        public var toggleContextAwareness: () -> Void
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
                    openSetup: @escaping () -> Void = {},
                    iconState: @escaping () -> StatusIconState = { StatusIconState() },
                    toggleDictation: @escaping () -> Void,
                    toggleAiCleanup: @escaping () -> Void,
                    polishLast: @escaping (String) -> Void = { _ in },
                    enableLiveTyping: @escaping () -> Void = {},
                    toggleLiveTyping: @escaping () -> Void = {},
                    enableContextAwareness: @escaping () -> Void = {},
                    toggleContextAwareness: @escaping () -> Void = {},
                    copyToClipboard: @escaping (String) -> Void = StatusMenu.copyToPasteboard,
                    pasteLast: @escaping () -> Void,
                    openDictionary: @escaping () -> Void,
                    openConfig: @escaping () -> Void,
                    runDoctor: @escaping () -> Void,
                    purgeHistory: @escaping () -> Void,
                    quit: @escaping () -> Void) {
            self.state = state
            self.openWindow = openWindow
            self.openSetup = openSetup
            self.iconState = iconState
            self.toggleDictation = toggleDictation
            self.toggleAiCleanup = toggleAiCleanup
            self.polishLast = polishLast
            self.enableLiveTyping = enableLiveTyping
            self.toggleLiveTyping = toggleLiveTyping
            self.enableContextAwareness = enableContextAwareness
            self.toggleContextAwareness = toggleContextAwareness
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
    /// Last session state the app reported. Held because the icon is a function
    /// of that *plus* two flags that change without a state transition (§5.1),
    /// so every icon refresh needs both halves.
    private var sessionState: AppState = .idle

    public init(actions: Actions) {
        self.actions = actions
        super.init()
    }

    /// `_build_menu`: claim the status item, attach a delegate-driven menu.
    public func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        self.statusItem = item
        self.menu = menu
        refreshIcon()
        rebuild()
    }

    /// `update_state`: swap the menu-bar image (§5.1).
    public func update(state: AppState) {
        sessionState = state
        refreshIcon()
    }

    /// String-keyed variant for callers whose state enum lives elsewhere.
    public func update(stateNamed name: String) {
        update(state: AppState(rawValue: name) ?? .idle)
    }

    /// Re-draw the button from `iconSpec(for:)`.
    ///
    /// Called on every state change *and* on every menu open, because
    /// `needsSetup` and the master toggle both move without a session
    /// transition — a permission granted in System Settings has to clear the
    /// warning icon on its own.
    public func refreshIcon() {
        guard let button = statusItem?.button else { return }
        var icon = actions.iconState()
        icon.state = sessionState
        let spec = StatusMenuModel.iconSpec(for: icon)
        guard let image = Self.image(for: spec) else {
            // The emoji title is the fallback the model still owns: a status
            // item with neither image nor title is an invisible menu bar.
            button.image = nil
            button.title = StatusMenuModel.glyph(for: icon.state)
            return
        }
        button.title = ""
        button.image = image
        // Only the recording icon carries its own colour; every other state is a
        // template macOS tints for the menu bar's appearance.
        button.contentTintColor = spec.isTemplate ? nil : Self.dynamic(Theme.Token.hot)
    }

    /// A token as a dynamic `NSColor`, so a menu bar that flips appearance flips
    /// with it (§6.2 — the same discipline the SwiftUI side uses).
    private static func dynamic(_ token: ColorToken) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: token.hex(dark: isDark), alpha: token.alpha)
        }
    }

    private static func image(for spec: MenuIconSpec) -> NSImage? {
        guard let image = NSImage(systemSymbolName: spec.symbolName,
                                  accessibilityDescription: "Wisprit") else { return nil }
        let configured = image.withSymbolConfiguration(
            .init(pointSize: StatusMenuModel.iconPointSize, weight: .regular)) ?? image
        configured.isTemplate = spec.isTemplate
        return configured
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
        refreshIcon()
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
                                  keyEquivalent: row.keyEquivalent)
            if !row.keyEquivalent.isEmpty { item.keyEquivalentModifierMask = [.command] }
            item.tag = rows.count
            rows.append(row)
            item.isEnabled = row.isEnabled && (isClickable || row.isSubmenu)
            item.state = row.isChecked ? .on : .off
            if isClickable { item.target = self }
            if let text = row.representedText { item.representedObject = text }
            if let symbol = row.symbolName {
                item.image = Self.rowImage(symbol, tint: row.symbolTint)
            }
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
        case .openSetup:
            actions.openSetup()
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
        case .enableContextAwareness:
            actions.enableContextAwareness()
            rebuild()
        case .toggleContextAwareness:
            actions.toggleContextAwareness()
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

    /// A row's leading glyph. 13 pt, the list-row size (§1.8); `attention` is a
    /// glyph tint and never a fill (§1.6).
    private static func rowImage(_ symbol: String,
                                 tint: MenuItemModel.MenuSymbolTint) -> NSImage? {
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil),
              let configured = image.withSymbolConfiguration(
                .init(pointSize: 13, weight: .medium)) else { return nil }
        switch tint {
        case .none:
            configured.isTemplate = true
            return configured
        case .attention:
            return configured.tinted(with: dynamic(Theme.Token.attention))
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

private extension NSImage {
    /// A coloured copy. The draw block re-runs on every draw, so a dynamic
    /// `NSColor` still resolves against the appearance in effect at that moment.
    func tinted(with color: NSColor) -> NSImage {
        let tinted = NSImage(size: size, flipped: false) { [self] rect in
            draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        tinted.isTemplate = false
        return tinted
    }
}
#endif
