import Foundation

/// One `type → data` pair inside a pasteboard item.
public struct PasteboardEntry: Sendable, Equatable {
    public let type: String
    public let data: Data
    public init(type: String, data: Data) {
        self.type = type
        self.data = data
    }
}

/// One pasteboard item: EVERY type it carries, in the order the pasteboard
/// reported them. A snapshot is an array of these — the general pasteboard can
/// hold several items (multi-file copies, Numbers ranges, …) and restoring only
/// the string type would quietly destroy the rest.
public typealias PasteboardItemSnapshot = [PasteboardEntry]

/// Everything insertion needs from the system, behind one protocol so the whole
/// cascade (order of operations, transient marker, changeCount-conditional
/// restore, chunk pacing) can be tested against a fake — no real clipboard, no
/// posted events, no TCC grants.
///
/// Implementations must not throw for "expected" conditions; throwing is the
/// equivalent of Python's bare `except Exception` around `insert_text`, and
/// lands in an `InsertResult(method: .error)`.
public protocol InsertPorts: AnyObject, Sendable {
    /// `IsSecureEventInputEnabled()`.
    func secureInputEnabled() -> Bool
    /// `AXIsProcessTrusted()`. Returns true when the check itself is
    /// unavailable, so we attempt the post rather than falsely refusing.
    func accessibilityTrusted() -> Bool
    /// Bundle id of the frontmost app, or nil if undeterminable.
    func frontmostBundleID() -> String?
    /// Path shown in the "grant Accessibility to THIS binary" remedy text.
    func executablePath() -> String

    /// One typed-unicode keyDown/keyUp pair carrying `chunk`
    /// (`CGEventKeyboardSetUnicodeString`). `utf16Units` is the payload length.
    func typeUnicode(_ chunk: String, utf16Units: Int) throws
    /// Post ⌘V (virtual keycode 9 + command flag) to `kCGHIDEventTap`.
    func postCommandV() throws
    /// Post Return (virtual keycode 36) — Flow's "press enter".
    func postReturn() throws
    /// Blocking sleep on the calling (session) thread.
    func sleep(_ seconds: Double)

    /// Every item × every type, best effort.
    func pasteboardSnapshot() -> [PasteboardItemSnapshot]
    func pasteboardClearContents()
    /// `declareTypes(_:owner:)` — declaring the transient marker alongside the
    /// string type is what keeps clipboard managers out of our dictation write.
    func pasteboardDeclareTypes(_ types: [String])
    func pasteboardSetString(_ text: String, forType type: String) -> Bool
    func pasteboardChangeCount() -> Int
    /// Write a snapshot back. An empty snapshot restores an empty pasteboard.
    func pasteboardRestore(_ snapshot: [PasteboardItemSnapshot]) -> Bool
}
