import Foundation

/// A key-order-preserving JSON model.
///
/// `JSONSerialization` round-trips through `[String: Any]`, which loses key
/// order and normalises number formatting — unacceptable here, because
/// `dictionary.json` is a hand-edited file: an `add()` that touches one entry
/// must leave every other byte (and every unknown key) exactly as the user
/// wrote it. The serialiser below is byte-compatible with the Python side's
/// `json.dumps(data, indent=2, ensure_ascii=False) + "\n"`.
enum JSONValue {
    case object(JSONObject)
    case array([JSONValue])
    case string(String)
    /// Kept as the literal source text so numbers round-trip byte-for-byte.
    case number(String)
    case bool(Bool)
    case null
}

/// Insertion-ordered string→value map. Duplicate keys follow Python's `json`:
/// the last value wins, at the first key's position.
struct JSONObject {
    private(set) var entries: [(key: String, value: JSONValue)] = []

    init() {}

    subscript(key: String) -> JSONValue? {
        get { entries.first(where: { $0.key == key })?.value }
        set {
            guard let newValue else {
                entries.removeAll { $0.key == key }
                return
            }
            if let idx = entries.firstIndex(where: { $0.key == key }) {
                entries[idx].value = newValue
            } else {
                entries.append((key, newValue))
            }
        }
    }

    /// Set `key` only when it is absent — used so a learn event never rewrites
    /// provenance a human already recorded.
    mutating func setIfAbsent(_ key: String, _ value: JSONValue) {
        if self[key] == nil { self[key] = value }
    }
}

// MARK: - Accessors

extension JSONValue {
    var objectValue: JSONObject? { if case .object(let o) = self { return o }; return nil }
    var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    var intValue: Int? {
        guard case .number(let t) = self else { return nil }
        return Int(t) ?? Double(t).map { Int($0) }
    }

    static func int(_ v: Int) -> JSONValue { .number(String(v)) }
}

// MARK: - Parsing

enum JSONParseError: Error, CustomStringConvertible {
    case syntax(String, Int)
    var description: String {
        if case .syntax(let m, let i) = self { return "JSON syntax error at \(i): \(m)" }
        return "JSON syntax error"
    }
}

extension JSONValue {
    static func parse(_ text: String) throws -> JSONValue {
        var scanner = JSONScanner(Array(text.unicodeScalars))
        let value = try scanner.parseValue()
        scanner.skipWhitespace()
        guard scanner.atEnd else { throw JSONParseError.syntax("trailing data", scanner.index) }
        return value
    }
}

private struct JSONScanner {
    private let s: [Unicode.Scalar]
    private(set) var index = 0

    init(_ scalars: [Unicode.Scalar]) { s = scalars }

    var atEnd: Bool { index >= s.count }
    private var peek: Unicode.Scalar? { index < s.count ? s[index] : nil }

    mutating func skipWhitespace() {
        while let c = peek, c == " " || c == "\t" || c == "\n" || c == "\r" { index += 1 }
    }

    mutating func parseValue() throws -> JSONValue {
        skipWhitespace()
        guard let c = peek else { throw JSONParseError.syntax("unexpected end", index) }
        switch c {
        case "{": return try parseObject()
        case "[": return try parseArray()
        case "\"": return .string(try parseString())
        case "t": try expect("true"); return .bool(true)
        case "f": try expect("false"); return .bool(false)
        case "n": try expect("null"); return .null
        default: return try parseNumber()
        }
    }

    private mutating func expect(_ literal: String) throws {
        for ch in literal.unicodeScalars {
            guard peek == ch else { throw JSONParseError.syntax("expected \(literal)", index) }
            index += 1
        }
    }

    private mutating func parseObject() throws -> JSONValue {
        index += 1  // {
        var obj = JSONObject()
        skipWhitespace()
        if peek == "}" { index += 1; return .object(obj) }
        while true {
            skipWhitespace()
            guard peek == "\"" else { throw JSONParseError.syntax("expected key", index) }
            let key = try parseString()
            skipWhitespace()
            guard peek == ":" else { throw JSONParseError.syntax("expected ':'", index) }
            index += 1
            obj[key] = try parseValue()
            skipWhitespace()
            if peek == "," { index += 1; continue }
            if peek == "}" { index += 1; return .object(obj) }
            throw JSONParseError.syntax("expected ',' or '}'", index)
        }
    }

    private mutating func parseArray() throws -> JSONValue {
        index += 1  // [
        var items: [JSONValue] = []
        skipWhitespace()
        if peek == "]" { index += 1; return .array(items) }
        while true {
            items.append(try parseValue())
            skipWhitespace()
            if peek == "," { index += 1; continue }
            if peek == "]" { index += 1; return .array(items) }
            throw JSONParseError.syntax("expected ',' or ']'", index)
        }
    }

    private mutating func parseString() throws -> String {
        index += 1  // opening quote
        var out = String.UnicodeScalarView()
        while true {
            guard let c = peek else { throw JSONParseError.syntax("unterminated string", index) }
            index += 1
            if c == "\"" { return String(out) }
            if c != "\\" { out.append(c); continue }
            guard let esc = peek else { throw JSONParseError.syntax("unterminated escape", index) }
            index += 1
            switch esc {
            case "\"", "\\", "/": out.append(esc)
            case "b": out.append("\u{08}")
            case "f": out.append("\u{0C}")
            case "n": out.append("\n")
            case "r": out.append("\r")
            case "t": out.append("\t")
            case "u":
                let hi = try parseHex4()
                if hi >= 0xD800, hi <= 0xDBFF, peek == "\\", index + 1 < s.count, s[index + 1] == "u" {
                    index += 2
                    let lo = try parseHex4()
                    let combined = 0x10000 + ((hi - 0xD800) << 10) + (lo - 0xDC00)
                    guard let scalar = Unicode.Scalar(UInt32(combined)) else {
                        throw JSONParseError.syntax("bad surrogate pair", index)
                    }
                    out.append(scalar)
                } else {
                    guard let scalar = Unicode.Scalar(UInt32(hi)) else {
                        throw JSONParseError.syntax("bad \\u escape", index)
                    }
                    out.append(scalar)
                }
            default: throw JSONParseError.syntax("bad escape", index)
            }
        }
    }

    private mutating func parseHex4() throws -> Int {
        var value = 0
        for _ in 0..<4 {
            guard let c = peek, let digit = c.hexDigitValue else {
                throw JSONParseError.syntax("bad hex escape", index)
            }
            value = value << 4 | digit
            index += 1
        }
        return value
    }

    private mutating func parseNumber() throws -> JSONValue {
        let start = index
        if peek == "-" { index += 1 }
        while let c = peek, ("0"..."9").contains(c) || c == "." || c == "e" || c == "E"
                || c == "+" || c == "-" {
            index += 1
        }
        guard index > start else { throw JSONParseError.syntax("expected value", index) }
        return .number(String(String.UnicodeScalarView(s[start..<index])))
    }
}

private extension Unicode.Scalar {
    var hexDigitValue: Int? {
        switch self {
        case "0"..."9": return Int(value - 0x30)
        case "a"..."f": return Int(value - 0x61) + 10
        case "A"..."F": return Int(value - 0x41) + 10
        default: return nil
        }
    }
}

// MARK: - Serialisation (byte-compatible with Python json.dumps indent=2, ensure_ascii=False)

extension JSONValue {
    func serialized(indent: Int = 2) -> String {
        var out = ""
        write(into: &out, indent: indent, depth: 0)
        return out
    }

    private func write(into out: inout String, indent: Int, depth: Int) {
        let pad = String(repeating: " ", count: indent * (depth + 1))
        let closePad = String(repeating: " ", count: indent * depth)
        switch self {
        case .object(let obj):
            if obj.entries.isEmpty { out += "{}"; return }
            out += "{\n"
            for (n, entry) in obj.entries.enumerated() {
                out += pad + JSONValue.encode(entry.key) + ": "
                entry.value.write(into: &out, indent: indent, depth: depth + 1)
                out += n == obj.entries.count - 1 ? "\n" : ",\n"
            }
            out += closePad + "}"
        case .array(let items):
            if items.isEmpty { out += "[]"; return }
            out += "[\n"
            for (n, item) in items.enumerated() {
                out += pad
                item.write(into: &out, indent: indent, depth: depth + 1)
                out += n == items.count - 1 ? "\n" : ",\n"
            }
            out += closePad + "]"
        case .string(let str): out += JSONValue.encode(str)
        case .number(let text): out += text
        case .bool(let flag): out += flag ? "true" : "false"
        case .null: out += "null"
        }
    }

    /// Python's `ensure_ascii=False` escapes exactly `"`, `\` and C0 controls.
    static func encode(_ str: String) -> String {
        var out = "\""
        for u in str.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if u.value < 0x20 {
                    out += String(format: "\\u%04x", u.value)
                } else {
                    out.unicodeScalars.append(u)
                }
            }
        }
        return out + "\""
    }
}
