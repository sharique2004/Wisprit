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

    /// Where the post-⌘V clipboard custody window is served.
    ///
    /// R33: that window is a `sleep(500 ms)` and it used to run on the SESSION
    /// thread, after delivery — which meant a user who re-pressed the hotkey
    /// immediately had the microphone held shut for half a second by clipboard
    /// hygiene that had nothing to do with them. Moving it here keeps the
    /// semantics (snapshot, wait, restore only if `changeCount` still says the
    /// write is ours) and takes the wait off the path to the next utterance.
    ///
    /// Serial, and STATIC because there is more than one `Inserter`: the window
    /// paste path builds its own (`AppController.pasteFromWindow`), and two
    /// instances restoring the pasteboard concurrently is precisely the "it
    /// pasted my old clipboard" bug. One queue, one custody order, whoever asks.
    private static let custodyQueue = DispatchQueue(label: "wisprit.clipboard-custody")

    /// Wait out any restore still pending, from any `Inserter`.
    ///
    /// Required at quit (`AppController.terminate`): the restore is asynchronous
    /// now, so a quit inside the custody window would otherwise leave the user's
    /// clipboard holding our dictation forever — a permanent loss the old
    /// on-thread sleep made impossible.
    public static func drainClipboardCustody() {
        custodyQueue.sync {}
    }

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

    /// `onDelivered` fires at the instant the text is in the target app —
    /// after the last typed chunk on the terminal path, after ⌘V (and BEFORE
    /// the restore sleep) on the clipboard path, never on a failure. It is the
    /// session's hook for truth-in-feedback (R6): the success flash must land
    /// with the words, not half a second after them.
    public func insert(_ text: String, config: InserterConfig,
                       onDelivered: () -> Void = {}) -> InsertResult {
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
                // Typing IS the delivery; there is no post-delivery window on
                // this rung, so the stamp and the return coincide.
                let deliveredAt = MonotonicClock.now()
                onDelivered()
                return InsertResult(ok: true, method: .type, detail: "typed into \(bundle)",
                                    deliveredAtMonotonic: deliveredAt)

            case .clipboard(let bundle):
                return try pasteViaClipboard(text, config: config, bundle: bundle,
                                             onDelivered: onDelivered)
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

    /// Post Return after a successful insert, or alone when the utterance
    /// was only "press enter". Failures are silent — the text (if any) already
    /// landed, and a missed Enter is recoverable.
    public func pressReturn() {
        do {
            try ports.postReturn()
        } catch {
            log.error("press enter failed: \(String(describing: error), privacy: .public)")
        }
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
                                   bundle: String?,
                                   onDelivered: () -> Void) throws -> InsertResult {
        // Barrier before the snapshot: if a previous paste's restore is still
        // pending, the pasteboard currently holds OUR text, not the user's.
        // Snapshotting through it would capture the dictation and then restore
        // it later as if it were the user's clipboard.
        Inserter.custodyQueue.sync {}
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
        // ⌘V is posted: the text is visible in the user's document NOW. Stamp
        // and notify BEFORE the restore sleep — everything below this line is
        // clipboard custody hygiene, not delivery, and must never again be
        // billed to `release_to_text_ms` or delay the success flash (R6).
        let deliveredAt = MonotonicClock.now()
        onDelivered()

        // Custody, off this thread. Everything below the ⌘V is hygiene the user
        // never waits for, and the caller of this function is the session
        // thread — the same thread the NEXT utterance needs to open its
        // microphone on. The delay, the changeCount re-read and the restore all
        // move together so the decision is still made at the END of the window,
        // never before it.
        let delay = config.effectiveRestoreDelayMs / 1000.0
        let ports = self.ports
        let log = self.log
        Inserter.custodyQueue.async {
            ports.sleep(delay)
            guard ports.pasteboardChangeCount() == ourChangeCount else {
                // Another app (a clipboard manager?) mutated the pasteboard
                // meanwhile; restoring now would clobber THEIR write.
                log.warning("pasteboard changeCount moved during paste window; not restoring")
                return
            }
            if !ports.pasteboardRestore(snapshot) {
                log.warning("clipboard restore failed")
            }
        }

        // CONTRACT-DEVIATION (R33): the detail no longer reports the restore's
        // OUTCOME, because at return there isn't one yet. The R6-era strings
        // ("clipboard restored" / "restore failed" / "changed externally") are
        // now log lines; `restore scheduled` is the honest thing to say here.
        var detail = "restore scheduled"
        if let bundle { detail = "\(detail) (target \(bundle))" }
        return InsertResult(ok: true, method: .paste, detail: detail,
                            deliveredAtMonotonic: deliveredAt)
    }
}
