import Foundation
import WispritKit

/// Insert transcribed text at the current cursor position. Port of `insert.py`.
///
/// Three paths, chosen in this order:
///
/// 1. **Secure input active** — some process (password field, Slack's secure
///    entry, a sudo prompt) holds Secure Keyboard Entry: we inject nothing and
///    return `blocked_secure`. The transcript survives in history and via the
///    paste-last hotkey.
/// 2. **Terminal frontmost** (bundle id in `terminal_bundle_ids`) — typed
///    unicode injection, chunked at ≤20 UTF-16 code units per keyDown/keyUp
///    pair, so bracketed-paste and ⌘V quirks in terminals never apply.
/// 3. **Everything else** — clipboard swap: snapshot the pasteboard (all items,
///    all types), write the transcript with a transient marker, post ⌘V, then
///    restore the snapshot only if the `changeCount` proves nobody else touched
///    it in the meantime.
///
/// Event posting requires the Accessibility TCC grant; without it macOS
/// silently drops posted events, so `AXIsProcessTrusted` is checked up front —
/// otherwise we would clobber the user's clipboard for a paste that can never
/// land.
///
/// `insert(_:config:)` never throws: every failure comes back as an
/// `InsertResult` so the session loop can flash the pill and move on. The
/// transcript is expected to already be in history before this is called — a
/// failed insert must never lose words.
public final class Inserter: @unchecked Sendable {
    /// Small pause between typed chunks so slow terminals don't drop input.
    public static let typeInterChunkSleepSeconds: Double = 0.005
    /// Community convention: well-behaved clipboard managers (Maccy, Paste, …)
    /// skip any pasteboard write carrying this type, so our transient dictation
    /// writes do not pollute the user's clipboard history.
    public static let transientPasteboardType = "org.nspasteboard.TransientType"
    /// `NSPasteboard.PasteboardType.string`'s raw value, named here so the
    /// clipboard dance is expressible without AppKit in tests.
    public static let stringPasteboardType = "public.utf8-plain-text"
    /// Fallback restore delay if the configured value is missing/invalid.
    /// Restoring sooner than the target app reads the pasteboard is the #1
    /// competitor bug ("it pasted my old clipboard"), so the floor is generous.
    public static let defaultRestoreDelayMs = 500
    /// `runtime.DEFAULT_TERMINAL_BUNDLE_IDS`.
    public static let defaultTerminalBundleIDs = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.github.wez.wezterm",
        "net.kovidgoyal.kitty",
        "io.alacritty",
        "com.mitchellh.ghostty",
    ]

    private let ports: InsertPorts
    private let log = WLog.logger("insert")

    public init(ports: InsertPorts = SystemInsertPorts()) {
        self.ports = ports
    }

    // --- routing (pure) -------------------------------------------------------

    /// The cascade decision, with no side effects. Exposed so the ordering
    /// (secure → trusted → terminal → clipboard) is asserted directly.
    public static func route(text: String,
                             secureInput: Bool,
                             accessibilityTrusted: Bool,
                             bundleID: String?,
                             terminalBundleIDs: [String]) -> InsertRoute {
        if text.isEmpty { return .emptyText }
        if secureInput { return .blockedSecure }
        if !accessibilityTrusted { return .notTrusted }
        if let bundleID, terminalBundleIDs.contains(bundleID) { return .typed(bundleID: bundleID) }
        return .clipboard(bundleID: bundleID)
    }

    // --- public entry point ---------------------------------------------------

    public func insert(_ text: String, config: InserterConfig) -> InsertResult {
        guard !text.isEmpty else {
            return InsertResult(ok: false, method: .error, detail: "empty text")
        }
        do {
            // Probes run in cascade order and only as far as needed, matching
            // insert.py: a blocked path never touches the workspace.
            let route: InsertRoute
            if ports.secureInputEnabled() {
                route = .blockedSecure
            } else if !ports.accessibilityTrusted() {
                route = .notTrusted
            } else {
                route = Inserter.route(
                    text: text,
                    secureInput: false,
                    accessibilityTrusted: true,
                    bundleID: ports.frontmostBundleID(),
                    terminalBundleIDs: config.terminalBundleIDs)
            }

            switch route {
            case .emptyText:
                return InsertResult(ok: false, method: .error, detail: "empty text")

            case .blockedSecure:
                return InsertResult(
                    ok: false, method: .blockedSecure,
                    detail: "Secure Keyboard Entry is active (password field or an app "
                          + "like Slack holds it); not injecting. Use paste-last once it clears.")

            case .notTrusted:
                return InsertResult(
                    ok: false, method: .error,
                    detail: "Accessibility permission missing for this process "
                          + "(\(ports.executablePath())). macOS silently drops posted events "
                          + "without it. Grant it in System Settings → Privacy & Security → "
                          + "Accessibility, then retry.")

            case .typed(let bundle):
                try typeUnicode(text)
                return InsertResult(ok: true, method: .type, detail: "typed into \(bundle)")

            case .clipboard(let bundle):
                return try pasteViaClipboard(text, config: config, bundle: bundle)
            }
        } catch {
            log.error("insert failed: \(String(describing: error), privacy: .public)")
            return InsertResult(ok: false, method: .error,
                                detail: "\(type(of: error)): \(error)")
        }
    }

    /// Convenience for callers holding a live `Settings` — build the config per
    /// call so edits apply to the next utterance.
    public func insert(_ text: String, configProvider: () -> InserterConfig) -> InsertResult {
        insert(text, config: configProvider())
    }

    // --- typed unicode injection (terminals) ----------------------------------

    private func typeUnicode(_ text: String) throws {
        let chunks = UnicodeChunker.chunks(text)
        for chunk in chunks {
            try ports.typeUnicode(chunk, utf16Units: UnicodeChunker.utf16Units(of: chunk))
            ports.sleep(Inserter.typeInterChunkSleepSeconds)
        }
    }

    // --- clipboard swap + ⌘V ---------------------------------------------------

    private func pasteViaClipboard(_ text: String,
                                   config: InserterConfig,
                                   bundle: String?) throws -> InsertResult {
        let snapshot = ports.pasteboardSnapshot()
        ports.pasteboardClearContents()
        // Declare both the string type and the transient marker so clipboard
        // managers ignore this write, then set the string payload.
        ports.pasteboardDeclareTypes([Inserter.stringPasteboardType, Inserter.transientPasteboardType])
        guard ports.pasteboardSetString(text, forType: Inserter.stringPasteboardType) else {
            // Nothing was pasted and the old contents are gone; put them back.
            _ = ports.pasteboardRestore(snapshot)
            return InsertResult(ok: false, method: .error, detail: "pasteboard write failed")
        }
        let ourChangeCount = ports.pasteboardChangeCount()

        try ports.postCommandV()
        ports.sleep(config.effectiveRestoreDelayMs / 1000.0)

        var detail: String
        if ports.pasteboardChangeCount() == ourChangeCount {
            detail = ports.pasteboardRestore(snapshot) ? "clipboard restored" : "clipboard restore failed"
        } else {
            // Another app (a clipboard manager?) mutated the pasteboard
            // meanwhile; restoring now would clobber THEIR write.
            detail = "clipboard changed externally; restore skipped"
            log.warning("pasteboard changeCount moved during paste window; not restoring")
        }
        if let bundle { detail = "\(detail) (target \(bundle))" }
        return InsertResult(ok: true, method: .paste, detail: detail)
    }
}
