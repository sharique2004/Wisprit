import XCTest
@testable import WispritDictionary

/// The order-preserving JSON model exists only so `dictionary.json` survives
/// round-trips; these are its edge cases.
final class JSONValueTests: XCTestCase {

    private func roundTrip(_ text: String) throws -> String {
        try JSONValue.parse(text).serialized()
    }

    func testKeyOrderIsPreserved() throws {
        let text = """
        {
          "zebra": 1,
          "alpha": 2,
          "middle": {
            "z": true,
            "a": null
          }
        }
        """
        XCTAssertEqual(try roundTrip(text), text)
    }

    func testNumbersKeepTheirLiteralSpelling() throws {
        let text = """
        {
          "a": 1.50,
          "b": 1e3,
          "c": -0,
          "d": 12345678901234567890
        }
        """
        XCTAssertEqual(try roundTrip(text), text)
    }

    func testEmptyContainersMatchPythonFormatting() throws {
        let text = """
        {
          "obj": {},
          "arr": [],
          "nested": [
            {}
          ]
        }
        """
        XCTAssertEqual(try roundTrip(text), text)
    }

    func testEscapeHandling() throws {
        let value = try JSONValue.parse(#"{"k": "q\"b\\s\ttab\nnl\u0001ctrlé\/slash"}"#)
        XCTAssertEqual(value.objectValue?["k"]?.stringValue, "q\"b\\s\ttab\nnl\u{01}ctrlé/slash")
        // `/` un-escapes on read and stays bare on write; everything below 0x20
        // is re-escaped the way Python does it.
        XCTAssertEqual(value.serialized(),
                       "{\n  \"k\": \"q\\\"b\\\\s\\ttab\\nnl\\u0001ctrlé/slash\"\n}")
    }

    func testSurrogatePairsDecode() throws {
        let value = try JSONValue.parse(#"{"k": "😀"}"#)
        XCTAssertEqual(value.objectValue?["k"]?.stringValue, "😀")
        XCTAssertEqual(value.serialized(), "{\n  \"k\": \"😀\"\n}")
    }

    func testDuplicateKeysFollowPythonSemantics() throws {
        // Python: last value wins, at the first key's position.
        let value = try JSONValue.parse(#"{"a": 1, "b": 2, "a": 3}"#)
        XCTAssertEqual(value.serialized(), "{\n  \"a\": 3,\n  \"b\": 2\n}")
    }

    func testMalformedInputThrows() {
        for bad in ["", "{", "{\"a\"}", "{\"a\": }", "[1,]", "{} trailing", "\"unterminated"] {
            XCTAssertThrowsError(try JSONValue.parse(bad), bad)
        }
    }

    func testSetIfAbsentDoesNotOverwrite() {
        var object = JSONObject()
        object["a"] = .string("first")
        object.setIfAbsent("a", .string("second"))
        object.setIfAbsent("b", .string("new"))
        XCTAssertEqual(object["a"]?.stringValue, "first")
        XCTAssertEqual(object["b"]?.stringValue, "new")
        XCTAssertEqual(object.entries.map(\.key), ["a", "b"])
    }

    /// `re.escape` parity, spot-checked directly (the 521 generated patterns in
    /// GoldenParityTests are the exhaustive proof).
    func testRelaxedEscapeMatchesPythonReEscape() {
        XCTAssertEqual(DictionaryStore.relaxedEscape("in forge"), #"in\s+forge"#)
        XCTAssertEqual(DictionaryStore.relaxedEscape("mlx-whisper"), #"mlx\-whisper"#)
        XCTAssertEqual(DictionaryStore.relaxedEscape("Next.js"), #"Next\.js"#)
        XCTAssertEqual(DictionaryStore.relaxedEscape("Cal.com"), #"Cal\.com"#)
        XCTAssertEqual(DictionaryStore.relaxedEscape("a (b) [c]"), #"a\s+\(b\)\s+\[c\]"#)
        XCTAssertEqual(DictionaryStore.relaxedEscape("D'nika"), "D'nika")   // ' is not special
        XCTAssertEqual(DictionaryStore.relaxedEscape("Café"), "Café")       // non-ASCII untouched
    }
}
