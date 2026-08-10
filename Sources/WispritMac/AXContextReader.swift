#if os(macOS)
import ApplicationServices
import Foundation
import WispritContext
import WispritKit

/// The Accessibility fallback reader — rungs 3–4, where no input method holds
/// the field and the only way to see the text near the cursor is to ask the AX
/// server for it.
///
/// The whole design is a refusal to walk anything. Wispr Flow's measured
/// 336 ms / 214-element tree walk is a worse design, not a target: this reader
/// makes at most FOUR attribute calls against the focused element and no other
/// element, ever —
///
///   1. system-wide → `kAXFocusedUIElement`
///   2. element → `kAXSelectedTextRange`
///   3. element → `kAXNumberOfCharacters`
///   4. element → `kAXStringForRange` over one bounded, clamped window
///
/// (The focused-app hop the sketch listed is unnecessary — the system-wide
/// element answers `kAXFocusedUIElement` directly — and the saved call is spent
/// on the character count, which is what makes the window clamp correct instead
/// of hoping the app tolerates an out-of-bounds range.)
///
/// `AXUIElementSetMessagingTimeout` on the system-wide element is the real
/// budget: every call above inherits it, so a wedged peer costs at most
/// 4 × the timeout ON THIS READER'S OWN THREAD — one dedicated serial utility
/// queue, depth 1. A request while one is in flight is dropped and reported
/// (`false`), never queued: a queue of stale reads behind a hung app is worse
/// than no signal, and the coordinator records the drop as `ctx: busy`.
///
/// The four calls live in one static function injected as a closure, so every
/// test of the depth-1/threading behaviour runs with a fake and no TCC grant.
public final class AXContextReader: AXContextReading, @unchecked Sendable {

    /// Per-call AX messaging budget, seconds. Generous against the measured
    /// single-element read (~1–10 ms) and still small enough that four timeouts
    /// stay invisible next to a finalize.
    public static let messagingTimeout: Float = 0.25

    /// Window per side, in UTF-16 units — matches `ContextPolicy.maxFieldChars`
    /// so the clamp downstream never has anything to cut on the AX path.
    static let windowBefore = 800
    static let windowAfter = 800

    private let queue = DispatchQueue(label: "com.wisprit.context.ax", qos: .utility)
    private let lock = NSLock()
    private var inFlight = false
    private let perform: @Sendable () -> ContextFieldText?

    public init(perform: @escaping @Sendable () -> ContextFieldText? = { AXContextReader.systemRead() }) {
        self.perform = perform
    }

    /// Test hook: is a read being served right now?
    var isBusy: Bool {
        lock.lock(); defer { lock.unlock() }
        return inFlight
    }

    // MARK: AXContextReading

    @discardableResult
    public func read(_ completion: @escaping @Sendable (ContextFieldText?) -> Void) -> Bool {
        lock.lock()
        guard !inFlight else {
            lock.unlock()
            return false
        }
        inFlight = true
        lock.unlock()

        let perform = self.perform
        queue.async { [weak self] in
            let result = perform()
            if let self {
                self.lock.lock()
                self.inFlight = false
                self.lock.unlock()
            }
            completion(result)
        }
        return true
    }

    // MARK: - the four calls

    /// The real read. nil = no signal: nothing focused, an app that answers
    /// none of the text attributes (no AX text support — permanently true of
    /// some views), a range that cannot be resolved, or no Accessibility grant
    /// at all. Every one of those is the same honest outcome — this utterance
    /// gets no context.
    public static func systemRead() -> ContextFieldText? {
        let systemWide = AXUIElementCreateSystemWide()
        // The system-wide setting is inherited by every element this process
        // talks to — one call budgets all four.
        AXUIElementSetMessagingTimeout(systemWide, messagingTimeout)

        // 1. The focused element, straight off the system-wide element.
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide,
                                            kAXFocusedUIElementAttribute as CFString,
                                            &focusedRef) == .success,
              let focused = focusedRef, CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return nil }
        let element = unsafeDowncast(focused as AnyObject, to: AXUIElement.self)

        // 2. Where the caret/selection sits.
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element,
                                            kAXSelectedTextRangeAttribute as CFString,
                                            &rangeRef) == .success,
              let rangeValue = rangeRef, CFGetTypeID(rangeValue) == AXValueGetTypeID()
        else { return nil }
        var selection = CFRange()
        guard AXValueGetValue(unsafeDowncast(rangeValue as AnyObject, to: AXValue.self),
                              .cfRange, &selection),
              selection.location >= 0, selection.length >= 0
        else { return nil }

        // 3. How long the document is — the clamp.
        var countRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element,
                                            kAXNumberOfCharactersAttribute as CFString,
                                            &countRef) == .success,
              let count = (countRef as? NSNumber)?.intValue, count >= 0
        else { return nil }
        guard count > 0 else {
            return ContextFieldText()  // an empty field is a reading, not a failure
        }

        return windowedRead(element: element, selection: selection, documentLength: count)
    }

    /// 4. One `kAXStringForRange` over the clamped window, split back into
    /// before/selected/after at UTF-16 offsets (AX text ranges are UTF-16).
    static func windowedRead(element: AXUIElement, selection: CFRange,
                             documentLength: Int) -> ContextFieldText? {
        let selStart = min(selection.location, documentLength)
        let selEnd = min(selStart + selection.length, documentLength)
        let start = max(0, selStart - windowBefore)
        let end = min(documentLength, selEnd + windowAfter)
        guard end > start else { return ContextFieldText() }

        var window = CFRange(location: start, length: end - start)
        guard let windowValue = AXValueCreate(.cfRange, &window) else { return nil }
        var textRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
                element,
                kAXStringForRangeParameterizedAttribute as CFString,
                windowValue, &textRef) == .success,
              let text = textRef as? String
        else { return nil }

        return split(window: text, selectionStart: selStart - start,
                     selectionLength: selEnd - selStart)
    }

    /// Pure and separately testable: UTF-16 offsets in, three fields out, with
    /// out-of-range offsets clamped rather than trapped — apps have been known
    /// to answer a shorter window than they were asked for.
    static func split(window text: String, selectionStart: Int,
                      selectionLength: Int) -> ContextFieldText {
        let units = Array(text.utf16)
        let selStart = max(0, min(selectionStart, units.count))
        let selEnd = max(selStart, min(selStart + max(0, selectionLength), units.count))
        return ContextFieldText(
            before: String(decoding: units[0..<selStart], as: UTF16.self),
            selected: String(decoding: units[selStart..<selEnd], as: UTF16.self),
            after: String(decoding: units[selEnd...], as: UTF16.self))
    }
}
#endif
