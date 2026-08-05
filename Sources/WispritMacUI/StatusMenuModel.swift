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
    case toggleDictation
    case toggleAiCleanup
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
    /// nil = an inert row (header, or the disabled AI-unavailable explanation).
    public var action: MenuAction?
    public var isSeparator: Bool
    public var isEnabled: Bool
    public var isChecked: Bool
    /// `setRepresentedObject_` payload — the untruncated transcript.
    public var representedText: String?

    public init(title: String, action: MenuAction? = nil, isSeparator: Bool = false,
                isEnabled: Bool = true, isChecked: Bool = false,
                representedText: String? = nil) {
        self.title = title
        self.action = action
        self.isSeparator = isSeparator
        self.isEnabled = isEnabled
        self.isChecked = isChecked
        self.representedText = representedText
    }

    public static let separator = MenuItemModel(title: "", isSeparator: true, isEnabled: false)

    /// A visible but non-clickable row (`item.setEnabled_(False)`).
    public static func label(_ title: String) -> MenuItemModel {
        MenuItemModel(title: title, action: nil, isEnabled: false)
    }
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

    public init(dictationEnabled: Bool = true, aiCleanupEnabled: Bool = true,
                aiAvailability: Bool? = nil, recents: [String] = []) {
        self.dictationEnabled = dictationEnabled
        self.aiCleanupEnabled = aiCleanupEnabled
        self.aiAvailability = aiAvailability
        self.recents = recents
    }
}

/// Pure construction of the status-bar menu — a 1:1 port of `app.py`'s
/// `_rebuild_menu`, minus the "Polish Last with Claude" submenu.
///
// CONTRACT-DEVIATION: the Polish submenu is not ported. It shells out to the
// user's `claude` CLI (`polish.py`), which the research digest (§3, "needs
// redesign") rules out for a shippable app; the four modes belong on
// FoundationModels if they come back, which is `WispritRefine`'s territory, not
// this target's.
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
}
