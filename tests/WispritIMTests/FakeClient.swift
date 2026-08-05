import Foundation
@testable import WispritIM

/// A text field that only exists in memory.
///
/// It behaves like a real client on the two things that matter: `insertText`
/// with an absolute range really replaces those characters, and marked text
/// really occupies space in the document. That is enough to catch the bug this
/// whole module is built to avoid — writing the right correction into the wrong
/// place.
final class FakeClient: IMClientSeam {

    enum Op: Equatable, CustomStringConvertible {
        case marked(String, selection: NSRange, replacement: NSRange)
        case insert(String, replacement: NSRange)

        var description: String {
            switch self {
            case .marked(let text, _, let replacement):
                return "marked(\"\(text)\", replacing: \(rangeText(replacement)))"
            case .insert(let text, let replacement):
                return "insert(\"\(text)\", replacing: \(rangeText(replacement)))"
            }
        }

        private func rangeText(_ range: NSRange) -> String {
            range.location == NSNotFound ? "none" : "\(range.location)..<\(range.location + range.length)"
        }
    }

    // Configuration
    var bundleID: String = "com.apple.TextEdit"
    var supportsUnicode: Bool = true
    var supportsDocumentAccess: Bool = true
    var clientID: String = "fake-client"
    /// Simulates a client that refuses marked text (Java/Qt/games).
    var acceptsMarkedText: Bool = true
    /// Simulates a dead client.
    var acceptsInsert: Bool = true
    /// Simulates a client whose reads return nothing.
    var readsFail: Bool = false
    /// Simulates Chromium's cached read window: reads are clipped to this range.
    var readWindow: NSRange?

    // Observable state
    private(set) var ops: [Op] = []
    /// Committed (unmarked) contents of the field.
    private(set) var document: NSMutableString = ""
    /// The marked (provisional) run, which lives at `markedLocation`.
    private(set) var marked: String = ""
    private var markedLocation: Int = 0
    private var caret: Int = 0

    init(document: String = "", caret: Int? = nil) {
        self.document = NSMutableString(string: document)
        self.caret = caret ?? (document as NSString).length
        self.markedLocation = self.caret
    }

    /// What the user sees: committed text with the marked run spliced in.
    var visibleText: String {
        let copy = NSMutableString(string: document)
        copy.insert(marked, at: min(markedLocation, copy.length))
        return copy as String
    }

    func documentLength() -> Int { document.length + (marked as NSString).length }

    func selectedRange() -> NSRange { NSRange(location: caret, length: 0) }

    func markedRange() -> NSRange {
        marked.isEmpty ? NSRange(location: NSNotFound, length: 0)
                       : NSRange(location: markedLocation, length: (marked as NSString).length)
    }

    func string(in range: NSRange) -> (text: String, actual: NSRange)? {
        guard !readsFail else { return nil }
        let whole = visibleText as NSString
        var wanted = NSIntersectionRange(range, NSRange(location: 0, length: whole.length))
        if let window = readWindow {
            wanted = NSIntersectionRange(wanted, window)
        }
        guard wanted.length > 0 else { return nil }
        return (whole.substring(with: wanted), wanted)
    }

    @discardableResult
    func setMarkedText(_ text: String, selection: NSRange, replacement: NSRange) -> Bool {
        ops.append(.marked(text, selection: selection, replacement: replacement))
        guard acceptsMarkedText else { return false }
        if replacement.location != NSNotFound {
            // Marked text placed somewhere other than the insertion point.
            markedLocation = min(replacement.location, document.length)
            caret = markedLocation
        } else if marked.isEmpty {
            markedLocation = caret
        }
        marked = text
        return true
    }

    @discardableResult
    func insertText(_ text: String, replacement: NSRange) -> Bool {
        ops.append(.insert(text, replacement: replacement))
        guard acceptsInsert else { return false }

        // A real client drops the marked run when text is committed.
        let hadMarked = !marked.isEmpty
        marked = ""

        if replacement.location == NSNotFound {
            let at = hadMarked ? min(markedLocation, document.length) : min(caret, document.length)
            document.insert(text, at: at)
            caret = at + (text as NSString).length
        } else {
            let clipped = NSIntersectionRange(replacement, NSRange(location: 0, length: document.length))
            guard clipped.length == replacement.length else { return false }
            document.replaceCharacters(in: clipped, with: text)
            caret = clipped.location + (text as NSString).length
        }
        markedLocation = caret
        return true
    }

    /// The user typing while Wisprit is mid-utterance.
    func userTypes(_ text: String, at location: Int) {
        document.insert(text, at: min(location, document.length))
        if location <= caret { caret += (text as NSString).length }
        if location <= markedLocation { markedLocation += (text as NSString).length }
    }

    /// The target app rewriting the field under us (autocorrect, form reset).
    func fieldRewritten(to text: String) {
        document = NSMutableString(string: text)
        marked = ""
        caret = document.length
        markedLocation = caret
    }
}
