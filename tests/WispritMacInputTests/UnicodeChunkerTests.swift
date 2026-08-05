import XCTest
@testable import WispritMacInput

/// `CGEventKeyboardSetUnicodeString` chunking. A split surrogate pair posts two
/// lone surrogates and the terminal shows garbage, so the never-split property
/// is the point of this file.
final class UnicodeChunkerTests: XCTestCase {

    private func units(_ s: String) -> Int { s.utf16.count }

    func testEmptyTextYieldsNoChunks() {
        XCTAssertEqual(UnicodeChunker.chunks(""), [])
    }

    func testShortTextIsOneChunk() {
        XCTAssertEqual(UnicodeChunker.chunks("hello"), ["hello"])
    }

    func testExactlyTwentyUnitsIsOneChunk() {
        let s = String(repeating: "a", count: 20)
        XCTAssertEqual(UnicodeChunker.chunks(s), [s])
    }

    func testTwentyOneUnitsSplitsAtTwenty() {
        let s = String(repeating: "a", count: 21)
        let chunks = UnicodeChunker.chunks(s)
        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(units(chunks[0]), 20)
        XCTAssertEqual(units(chunks[1]), 1)
        XCTAssertEqual(chunks.joined(), s)
    }

    func testEveryChunkIsWithinTheCapAndRoundTrips() {
        let text = "The quick brown fox jumps over the lazy dog — 0123456789, "
                 + "and then some more text to force many chunks."
        let chunks = UnicodeChunker.chunks(text)
        XCTAssertGreaterThan(chunks.count, 4)
        for c in chunks { XCTAssertLessThanOrEqual(units(c), 20) }
        XCTAssertEqual(chunks.joined(), text)
    }

    /// Astral characters are 2 UTF-16 units; a boundary must never fall inside
    /// one. Odd-length prefixes are what expose an off-by-one here.
    func testSurrogatePairsAreNeverSplit() {
        for prefixLength in 0...25 {
            let text = String(repeating: "a", count: prefixLength)
                     + String(repeating: "😀", count: 12)
            let chunks = UnicodeChunker.chunks(text)
            XCTAssertEqual(chunks.joined(), text, "prefix \(prefixLength)")
            for c in chunks {
                XCTAssertLessThanOrEqual(units(c), 20, "prefix \(prefixLength)")
                for scalar in c.unicodeScalars {
                    XCTAssertFalse((0xD800...0xDFFF).contains(Int(scalar.value)),
                                   "lone surrogate leaked at prefix \(prefixLength)")
                }
            }
            // No chunk may end mid-pair: re-decoding each chunk must be lossless.
            for c in chunks {
                XCTAssertEqual(String(decoding: Array(c.utf16), as: UTF16.self), c)
            }
        }
    }

    func testOddPrefixPushesEmojiToNextChunk() {
        // 19 'a' then an emoji: 19 + 2 > 20, so the emoji starts a new chunk
        // rather than being torn in half.
        let text = String(repeating: "a", count: 19) + "😀"
        let chunks = UnicodeChunker.chunks(text)
        XCTAssertEqual(chunks, [String(repeating: "a", count: 19), "😀"])
    }

    /// A single scalar wider than the cap is emitted alone (over-long) rather
    /// than torn apart — same as Python's "only break when chunk is non-empty".
    func testOversizedSingleScalarIsEmittedWhole() {
        XCTAssertEqual(UnicodeChunker.chunks("😀", maxUnits: 1), ["😀"])
        XCTAssertEqual(UnicodeChunker.chunks("a😀b", maxUnits: 1), ["a", "😀", "b"])
    }

    /// Boundaries fall between unicode scalars, matching Python's iteration over
    /// `str`. A grapheme cluster therefore MAY span two events (harmless — the
    /// receiver concatenates code units into one buffer); the invariant that
    /// matters is that no chunk ever contains a lone surrogate.
    func testGraphemeClustersMaySplitButScalarsNever() {
        let family = "👨‍👩‍👧‍👦"     // one Character, 7 scalars, 11 UTF-16 units
        let chunks = UnicodeChunker.chunks(family, maxUnits: 4)
        XCTAssertGreaterThan(chunks.count, 1, "scalar-level chunking splits the cluster")
        XCTAssertEqual(chunks.joined(), family)
        for c in chunks {
            for scalar in c.unicodeScalars {
                XCTAssertFalse((0xD800...0xDFFF).contains(Int(scalar.value)))
            }
        }
    }

    func testNewlinesAndTabsSurvive() {
        let text = "line one\nline two\tend"
        XCTAssertEqual(UnicodeChunker.chunks(text).joined(), text)
    }

    func testUnitCountHelper() {
        XCTAssertEqual(UnicodeChunker.utf16Units(of: "abc"), 3)
        XCTAssertEqual(UnicodeChunker.utf16Units(of: "😀"), 2)
        XCTAssertEqual(UnicodeChunker.maxUTF16UnitsPerEvent, 20)
    }
}
