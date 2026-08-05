import Foundation
import WispritIMProtocol

#if os(macOS)
import InputMethodKit
#endif

/// The slice of `IMKTextInput` this input method actually uses.
///
/// Everything that decides *what* to write goes through this protocol, so the
/// whole decision layer — marked vs commit vs degrade, retro-edit vs abort — is
/// exercisable in `swift test` with a fake, on a machine where Wisprit is not
/// installed as an input method and nothing is focused.
///
/// Ranges are UTF-16 (`NSRange`), because that is what the text system speaks.
public protocol IMClientSeam: AnyObject {
    var bundleID: String { get }
    var supportsUnicode: Bool { get }
    /// `supportsProperty(kTSMDocumentSupportDocumentAccessPropertyTag)`. False
    /// means reads return nothing and an absolute `replacementRange` is silently
    /// dropped — the gate for retroactive correction.
    var supportsDocumentAccess: Bool { get }
    var clientID: String { get }
    /// Length of the client's document in UTF-16 units, or 0 when unknown.
    func documentLength() -> Int
    func selectedRange() -> NSRange
    func markedRange() -> NSRange
    /// `stringFromRange:actualRange:`. The actual range can be narrower than the
    /// requested one (Chromium serves a cached window around the selection), so
    /// callers must use `actual` as the coordinate base, never the request.
    func string(in range: NSRange) -> (text: String, actual: NSRange)?
    /// `setMarkedText:selectionRange:replacementRange:`. Returns false if the
    /// client is gone, which degrades the session to commit-only.
    @discardableResult
    func setMarkedText(_ text: String, selection: NSRange, replacement: NSRange) -> Bool
    /// `insertText:replacementRange:`. With `replacement.location == NSNotFound`
    /// this commits at the insertion point, replacing any marked text — one call,
    /// one undo step in the target app.
    @discardableResult
    func insertText(_ text: String, replacement: NSRange) -> Bool
}

/// The range that means "wherever the insertion point is".
public let IMNoRange = NSRange(location: NSNotFound, length: 0)

extension IMClientSeam {
    public var capabilities: IMClientCapabilities {
        IMClientCapabilities(supportsUnicode: supportsUnicode,
                             bundleID: bundleID,
                             supportsDocumentAccess: supportsDocumentAccess,
                             clientID: clientID)
    }
}

#if os(macOS)
/// The real thing: a live `IMKTextInput` client handed to us by the Text Services
/// Manager in `activateServer:`.
///
/// Holds the client weakly-ish (TSM owns it) and never caches document state —
/// every read goes back to the client, because the user can type into the field
/// at any moment and any offset we remember is a corruption waiting to happen.
public final class IMKClientSeam: IMClientSeam {
    private let client: IMKTextInput

    public init(_ client: IMKTextInput) {
        self.client = client
    }

    public var bundleID: String { client.bundleIdentifier() ?? "" }
    public var supportsUnicode: Bool { client.supportsUnicode() }
    public var clientID: String { client.uniqueClientIdentifierString() ?? "" }

    public var supportsDocumentAccess: Bool {
        client.supportsProperty(TSMDocumentPropertyTag(kTSMDocumentSupportDocumentAccessPropertyTag))
    }

    public func documentLength() -> Int {
        let length = client.length()
        return length == NSNotFound || length < 0 ? 0 : length
    }

    public func selectedRange() -> NSRange { client.selectedRange() }
    public func markedRange() -> NSRange { client.markedRange() }

    public func string(in range: NSRange) -> (text: String, actual: NSRange)? {
        var actual = NSRange(location: NSNotFound, length: 0)
        guard let text = client.string(from: range, actualRange: &actual) else { return nil }
        if actual.location == NSNotFound { actual = NSRange(location: range.location, length: (text as NSString).length) }
        return (text, actual)
    }

    @discardableResult
    public func setMarkedText(_ text: String, selection: NSRange, replacement: NSRange) -> Bool {
        client.setMarkedText(text, selectionRange: selection, replacementRange: replacement)
        return true
    }

    @discardableResult
    public func insertText(_ text: String, replacement: NSRange) -> Bool {
        client.insertText(text, replacementRange: replacement)
        return true
    }
}
#endif
