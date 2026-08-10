import Foundation

/// The four states the menu-bar glyph reports. `_STATE_GLYPH` in `app.py`.
public enum AppState: String, Equatable, Sendable, CaseIterable {
    case idle
    case recording
    case finalizing
    case inserting
}

/// Everything a menu item can do. The `StatusMenu` maps each to an injected
/// closure; the model itself knows nothing about settings, history or AppKit.
public enum MenuAction: Equatable, Sendable {
    /// Bring up the main window. First row of the menu, because a menu-bar-only
    /// app with a notch-hidden icon otherwise offers no way back to itself.
    case openWindow
    /// The same window, routed to the Setup page (§5.2). A separate case rather
    /// than a payload on `openWindow`: the pure model must stay `Equatable`
    /// against a bare `.openWindow`, and the shell is the only layer that knows
    /// what a "page" is.
    case openSetup
    case toggleDictation
    case toggleAiCleanup
    /// One of the four "Polish Last" submenu rows. The payload is the mode's
    /// stable key (`clean` / `formal` / `casual` / `prompt`) — the same string the
    /// Python used, so an old represented object still resolves.
    case polishLast(mode: String)
    /// Run the input-method onboarding: copy the bundle into
    /// `~/Library/Input Methods`, register it, and ask macOS to activate it.
    /// User-initiated by construction — this is the item that may raise the
    /// system's "wants to activate the third-party input method" dialog.
    case enableLiveTyping
    /// Flip the `live_typing` setting once the input method is installed.
    case toggleLiveTyping
    /// Index into `StatusMenuState.recents`; the full text rides along in
    /// `MenuItemModel.representedText`.
    case copyRecent(index: Int)
    case pasteLast
    case openDictionary
    case openConfig
    case runDoctor
    case purgeHistory
    case quit
}

/// One row of the built menu.
public struct MenuItemModel: Equatable, Sendable {
    public var title: String
    /// nil = an inert row (header, or the disabled AI-unavailable explanation) —
    /// unless `submenu` is non-nil, in which case the row is a live parent.
    public var action: MenuAction?
    public var isSeparator: Bool
    public var isEnabled: Bool
    public var isChecked: Bool
    /// `setRepresentedObject_` payload — the untruncated transcript, or a polish
    /// mode key.
    public var representedText: String?
    /// Child rows. A row with a submenu carries no action of its own.
    public var submenu: [MenuItemModel]?
    /// ⌘-equivalent, applied with `.command` (§5.2 gives `⌘0` to Open Wisprit —
    /// there is no other way back into an `LSUIElement` app whose icon is behind
    /// the notch). Empty means none.
    public var keyEquivalent: String
    /// An SF Symbol drawn on the row, tinted by `symbolTint`.
    public var symbolName: String?
    /// Which token the row's symbol is tinted with. The model cannot name a
    /// `Color` (it is compared in tests), so it names the intent.
    public var symbolTint: MenuSymbolTint

    public init(title: String, action: MenuAction? = nil, isSeparator: Bool = false,
                isEnabled: Bool = true, isChecked: Bool = false,
                representedText: String? = nil, submenu: [MenuItemModel]? = nil,
                keyEquivalent: String = "", symbolName: String? = nil,
                symbolTint: MenuSymbolTint = .none) {
        self.title = title
        self.action = action
        self.isSeparator = isSeparator
        self.isEnabled = isEnabled
        self.isChecked = isChecked
        self.representedText = representedText
        self.submenu = submenu
        self.keyEquivalent = keyEquivalent
        self.symbolName = symbolName
        self.symbolTint = symbolTint
    }

    public static let separator = MenuItemModel(title: "", isSeparator: true, isEnabled: false)

    /// The row's tint, named rather than coloured — `MenuItemModel` is compared
    /// in tests and a `Color` is opaque.
    public enum MenuSymbolTint: String, Equatable, Sendable {
        case none
        /// `Theme.attention` — the doctor's ochre, glyph-only (§1.6).
        case attention
    }

    /// A visible but non-clickable row (`item.setEnabled_(False)`).
    public static func label(_ title: String) -> MenuItemModel {
        MenuItemModel(title: title, action: nil, isEnabled: false)
    }

    /// True for a parent row: no action, but not inert either.
    public var isSubmenu: Bool { submenu != nil }
}

/// One "Polish Last" mode, as the menu needs it. The key/label pair is passed in
/// rather than imported: this target depends only on `WispritKit`, so it must not
/// name `WispritPolish.PolishMode` — and keeping the key a plain string is what
/// lets the represented object stay byte-compatible with the Python era.
public struct PolishModeItem: Equatable, Sendable {
    public var key: String
    public var label: String

    public init(key: String, label: String) {
        self.key = key
        self.label = label
    }
}

/// How far along the live-in-field-streaming setup is, in the menu's own
/// vocabulary (the input-method types live in `WispritIMProtocol`, which this
/// target does not depend on — the shell maps `IMPreflightVerdict` onto this).
public enum LiveTypingMenuStatus: String, Equatable, Sendable, CaseIterable {
    /// This build cannot do it at all (no bundled input method).
    case unsupported
    /// The status probe has not answered yet.
    case probing
    /// No `WispritIM.app` in `~/Library/Input Methods`.
    case notInstalled
    /// Installed but macOS has not registered it, or the user has not approved
    /// the activation prompt yet. Same remedy: run onboarding.
    case needsEnable
    /// A newer input method ships inside this Wisprit than the installed one.
    case needsUpdate
    /// Installed, registered and enabled — but `live_typing` is off.
    case readyOff
    /// Installed, registered, enabled, and switched on.
    case readyOn
}

/// The data the menu is built from, sampled fresh on every open
/// (`menuNeedsUpdate_` → `_rebuild_menu`).
public struct StatusMenuState: Equatable, Sendable {
    /// The `enabled` setting — master dictation toggle.
    public var dictationEnabled: Bool
    /// The `ai_cleanup` setting.
    public var aiCleanupEnabled: Bool
    /// `Refiner.availability`: **nil means the probe has not finished** (or the
    /// model is still warming) — show the toggle anyway, refinement
    /// self-disables until it is actually usable. Only an explicit `false`
    /// replaces the toggle with the disabled explanation row.
    public var aiAvailability: Bool?
    /// Most recent transcripts, newest first (`history.last(5)`), full text.
    public var recents: [String]
    /// `Polisher.availability`, same tri-state rule as `aiAvailability`.
    public var polishAvailability: Bool?
    /// Reason shown on the disabled row when `polishAvailability == false`.
    public var polishUnavailableReason: String
    /// The four modes, in menu order.
    public var polishModes: [PolishModeItem]
    public var liveTyping: LiveTypingMenuStatus
    /// Remedy / explanation for the live-typing row's inert states.
    public var liveTypingDetail: String
    /// Some `SetupItem.isBlocking` — dictation cannot work until the user
    /// finishes setup. Adds the "Finish setup…" row (§5.2) and takes priority
    /// over every other menu-bar icon state (§5.1).
    public var needsSetup: Bool

    public init(dictationEnabled: Bool = true, aiCleanupEnabled: Bool = true,
                aiAvailability: Bool? = nil, recents: [String] = [],
                polishAvailability: Bool? = nil,
                polishUnavailableReason: String = "",
                polishModes: [PolishModeItem] = [],
                liveTyping: LiveTypingMenuStatus = .notInstalled,
                liveTypingDetail: String = "",
                needsSetup: Bool = false) {
        self.dictationEnabled = dictationEnabled
        self.aiCleanupEnabled = aiCleanupEnabled
        self.aiAvailability = aiAvailability
        self.recents = recents
        self.polishAvailability = polishAvailability
        self.polishUnavailableReason = polishUnavailableReason
        self.polishModes = polishModes
        self.liveTyping = liveTyping
        self.liveTypingDetail = liveTypingDetail
        self.needsSetup = needsSetup
    }
}

/// What the menu-bar button draws — `docs/design/ui-redesign.md` §5.1.
///
/// A pair, not an image: the decision stays pure (and tested in
/// `WispritMacUITests`) while the AppKit layer owns `NSImage`.
public struct MenuIconSpec: Equatable, Sendable {
    public var symbolName: String
    /// `true` for every state but recording. macOS tints a template image for
    /// the menu-bar appearance; the recording icon is the one image in the app
    /// that must stay `hot` in both appearances (§1.6 site 2).
    public var isTemplate: Bool

    public init(symbolName: String, isTemplate: Bool) {
        self.symbolName = symbolName
        self.isTemplate = isTemplate
    }
}

/// Everything `iconSpec(for:)` needs: the session state plus the two flags that
/// outrank it.
public struct StatusIconState: Equatable, Sendable {
    public var state: AppState
    /// The `enabled` setting — master dictation toggle.
    public var dictationEnabled: Bool
    /// Some `SetupItem.isBlocking`.
    public var needsSetup: Bool

    public init(state: AppState = .idle, dictationEnabled: Bool = true,
                needsSetup: Bool = false) {
        self.state = state
        self.dictationEnabled = dictationEnabled
        self.needsSetup = needsSetup
    }
}

/// Pure construction of the status-bar menu — a 1:1 port of `app.py`'s
/// `_rebuild_menu`, with the "Polish Last with Claude" submenu replaced by
/// "Polish Last" (same four modes, same keys, Apple Intelligence instead of a
/// CLI subprocess) and one new row for the live-streaming onboarding.
public enum StatusMenuModel {
    /// Preview budget for a recent-transcript row (`len(preview) > 48`).
    public static let previewLimit = 48
    /// `history.last(5)`.
    public static let recentsLimit = 5

    private static let glyphs: [AppState: String] = [
        .idle: "🎙", .recording: "🔴", .finalizing: "…", .inserting: "⌨",
    ]

    public static func glyph(for state: AppState) -> String {
        glyphs[state] ?? "🎙"
    }

    /// `_STATE_GLYPH.get(state, "🎙")` for callers holding a raw state string
    /// (the session's own state enum lives in another target).
    public static func glyph(forStateNamed name: String) -> String {
        guard let state = AppState(rawValue: name) else { return "🎙" }
        return glyph(for: state)
    }

    // MARK: - the menu-bar icon (§5.1)

    /// The image the status button draws, by state.
    ///
    /// Priority when states collide is fixed and total:
    /// `needsSetup > disabled > recording > working > idle`. A Mac that cannot
    /// dictate says so before it says anything else, and the orange recording
    /// icon is never shown for a run that is not actually recording.
    ///
    /// `glyph(for:)` above is kept — the emoji is still the title fallback when
    /// a symbol cannot be made — but `StatusMenu` reads this.
    public static func iconSpec(for icon: StatusIconState) -> MenuIconSpec {
        if icon.needsSetup {
            return MenuIconSpec(symbolName: "exclamationmark.circle", isTemplate: true)
        }
        if !icon.dictationEnabled {
            return MenuIconSpec(symbolName: "mic.slash", isTemplate: true)
        }
        switch icon.state {
        case .recording:
            // The one non-template status image in the app (§1.6 site 2): the
            // mic is open, so the tally is lit.
            return MenuIconSpec(symbolName: "mic.fill", isTemplate: false)
        case .finalizing, .inserting:
            return MenuIconSpec(symbolName: "mic.fill", isTemplate: true)
        case .idle:
            return MenuIconSpec(symbolName: "mic", isTemplate: true)
        }
    }

    /// Point size and weight for the status image (§5.1).
    public static let iconPointSize: Double = 16

    /// `preview = row["text"].replace("\n", " ")`, then a 48-character budget
    /// with an ellipsis in the 48th slot.
    public static func elide(_ text: String, limit: Int = previewLimit) -> String {
        let flattened = text.replacingOccurrences(of: "\n", with: " ")
        guard flattened.count > limit else { return flattened }
        return String(flattened.prefix(max(0, limit - 1))) + "…"
    }

    /// Build the whole menu, in order.
    public static func build(_ state: StatusMenuState) -> [MenuItemModel] {
        var items: [MenuItemModel] = []

        // First, and above the separator: the way back to a visible app. ⌘0
        // because an `LSUIElement` app whose icon sits behind the notch has no
        // other route home (§5.2).
        items.append(MenuItemModel(title: "Open Wisprit", action: .openWindow,
                                   keyEquivalent: "0"))
        // Directly under it, and only while something is actually blocking:
        // the same window, opened on the page that can fix it.
        if state.needsSetup {
            items.append(MenuItemModel(title: "Finish setup…", action: .openSetup,
                                       symbolName: "exclamationmark.circle",
                                       symbolTint: .attention))
        }
        items.append(.separator)

        items.append(MenuItemModel(
            title: "Dictation \(state.dictationEnabled ? "On" : "Off")",
            action: .toggleDictation,
            isChecked: state.dictationEnabled))

        // Apple Intelligence on-path cleanup. availability nil means the probe
        // hasn't finished — show the toggle; refinement self-disables until it
        // is actually usable.
        if state.aiAvailability == false {
            items.append(.label("AI Cleanup unavailable — run Doctor"))
        } else {
            items.append(MenuItemModel(
                title: "AI Cleanup (Apple Intelligence)",
                action: .toggleAiCleanup,
                isChecked: state.aiCleanupEnabled))
        }

        items.append(polishRow(state))
        items.append(liveTypingRow(state))

        items.append(.separator)

        items.append(.label("Recent transcripts"))
        let recents = Array(state.recents.prefix(recentsLimit))
        if recents.isEmpty {
            items.append(.label("  (none yet)"))
        } else {
            for (index, text) in recents.enumerated() {
                items.append(MenuItemModel(
                    title: "  " + elide(text),
                    action: .copyRecent(index: index),
                    representedText: text))
            }
        }

        items.append(.separator)
        items.append(MenuItemModel(title: "Paste Last Transcript  (⌘⌃V)", action: .pasteLast))
        items.append(MenuItemModel(title: "Open Dictionary…", action: .openDictionary))
        items.append(MenuItemModel(title: "Open Config…", action: .openConfig))
        items.append(MenuItemModel(title: "Run Doctor…", action: .runDoctor))
        items.append(MenuItemModel(title: "Purge History", action: .purgeHistory))
        items.append(.separator)
        items.append(MenuItemModel(title: "Quit Wisprit", action: .quit))
        return items
    }

    // MARK: - Polish Last

    public static let polishTitle = "Polish Last"

    /// Same tri-state discipline as AI Cleanup: nil (probing) and true both show
    /// the submenu; only an explicit false swaps in the disabled row, which is
    /// where the Python's "claude CLI not found" title used to go.
    static func polishRow(_ state: StatusMenuState) -> MenuItemModel {
        guard state.polishAvailability != false else {
            let reason = state.polishUnavailableReason.trimmingCharacters(in: .whitespacesAndNewlines)
            return .label(reason.isEmpty
                          ? "\(polishTitle) unavailable — run Doctor"
                          : "\(polishTitle) unavailable — \(reason)")
        }
        let children = state.polishModes.map { mode in
            MenuItemModel(title: mode.label,
                          action: .polishLast(mode: mode.key),
                          representedText: mode.key)
        }
        guard !children.isEmpty else { return .label("\(polishTitle) unavailable — no modes") }
        return MenuItemModel(title: polishTitle, submenu: children)
    }

    // MARK: - Live typing

    static func liveTypingRow(_ state: StatusMenuState) -> MenuItemModel {
        switch state.liveTyping {
        case .unsupported:
            return .label("Live Typing unavailable — run Doctor")
        case .probing:
            return .label("Live Typing — checking…")
        case .notInstalled, .needsEnable:
            return MenuItemModel(title: "Enable Live Typing…", action: .enableLiveTyping)
        case .needsUpdate:
            return MenuItemModel(title: "Update Live Typing…", action: .enableLiveTyping)
        case .readyOff:
            return MenuItemModel(title: "Live Typing", action: .toggleLiveTyping, isChecked: false)
        case .readyOn:
            return MenuItemModel(title: "Live Typing", action: .toggleLiveTyping, isChecked: true)
        }
    }
}
