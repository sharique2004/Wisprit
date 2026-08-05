import Foundation

/// Splitting for `CGEventKeyboardSetUnicodeString`, ported from
/// `insert._utf16_chunks`.
///
/// The API takes a UTF-16 buffer and long payloads are unreliable, so we cap
/// each keyDown/keyUp pair at 20 code units. Chunk boundaries are placed
/// between *characters*, never inside one: an astral character (emoji, some CJK
/// extensions) is 2 UTF-16 units and splitting it would post two lone
/// surrogates, which render as garbage.
///
/// Boundaries fall between **unicode scalars**, matching Python's iteration
/// over `str` (a sequence of code points) exactly — so a grapheme cluster
/// (combining accent, ZWJ emoji sequence, regional-indicator flag) may span two
/// events. That is harmless: the receiver appends code units to one text buffer
/// and composition happens at render time. A split *surrogate pair* would not
/// be harmless, and cannot happen: the cap is checked per scalar, and a scalar
/// worth 2 units is never begun with only 1 unit of room.
///
/// A single scalar wider than the cap is emitted alone in an over-long chunk
/// rather than being torn apart — same as the Python, which only breaks when
/// the pending chunk is non-empty.
public enum UnicodeChunker {
    /// Max UTF-16 code units per synthetic typing event.
    public static let maxUTF16UnitsPerEvent = 20

    public static func utf16Units(of text: String) -> Int {
        text.utf16.count
    }

    public static func chunks(_ text: String, maxUnits: Int = maxUTF16UnitsPerEvent) -> [String] {
        guard !text.isEmpty else { return [] }
        let cap = max(1, maxUnits)
        var out: [String] = []
        var current = String.UnicodeScalarView()
        var units = 0
        for scalar in text.unicodeScalars {
            let n = scalar.value > 0xFFFF ? 2 : 1
            if units + n > cap && !current.isEmpty {
                out.append(String(current))
                current = String.UnicodeScalarView()
                units = 0
            }
            current.append(scalar)
            units += n
        }
        if !current.isEmpty { out.append(String(current)) }
        return out
    }
}
