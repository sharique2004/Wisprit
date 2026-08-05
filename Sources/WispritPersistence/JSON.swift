import Foundation

/// Order-preserving JSON model, sized for config.json.
///
/// `JSONSerialization` is unusable here: it hands back an unordered dictionary,
/// and Wisprit's config file must survive a round trip byte-for-byte — the
/// Python writer emits DEFAULTS in declaration order with any unknown keys
/// appended in file order, and a user editing the file by hand should not see
/// it reshuffled. So the value model, the parser and the writer are all local
/// and all order-preserving.

/// One JSON value. `int` is kept distinct from `double` because Python's
/// `json` round-trips `1000` as `1000`, not `1000.0`.
public indirect enum SettingValue: Sendable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([SettingValue])
    case object(JSONObject)
    case null
}

/// Insertion-ordered string-keyed map. Re-assigning an existing key keeps its
/// original position (matching Python's `dict.update`, which the merge relies on).
public struct JSONObject: Sendable, Equatable {
    public private(set) var keys: [String] = []
    private var storage: [String: SettingValue] = [:]

    public init() {}

    public init(_ pairs: [(String, SettingValue)]) {
        for (k, v) in pairs { self[k] = v }
    }

    public subscript(key: String) -> SettingValue? {
        get { storage[key] }
        set {
            if let newValue {
                if storage.updateValue(newValue, forKey: key) == nil { keys.append(key) }
            } else if storage.removeValue(forKey: key) != nil {
                keys.removeAll { $0 == key }
            }
        }
    }

    /// Python's `dict.update`: existing keys keep their slot, new keys append.
    public mutating func merge(_ other: JSONObject) {
        for key in other.keys { self[key] = other[key] }
    }

    public var pairs: [(String, SettingValue)] { keys.map { ($0, storage[$0]!) } }
    public var count: Int { keys.count }
}

// MARK: - Parsing

public enum JSONParseError: Error, Equatable {
    case malformed(offset: Int)
    case trailingData(offset: Int)
}

public enum WispritJSON {
    /// Strict RFC-8259 parse (the subset Python's `json.loads` accepts for our
    /// files — no comments, no trailing commas), preserving object key order.
    public static func parse(_ text: String) throws -> SettingValue {
        var p = Parser(Array(text.unicodeScalars))
        p.skipWhitespace()
        let value = try p.parseValue()
        p.skipWhitespace()
        guard p.atEnd else { throw JSONParseError.trailingData(offset: p.index) }
        return value
    }

    private struct Parser {
        let s: [Unicode.Scalar]
        var index = 0
        init(_ s: [Unicode.Scalar]) { self.s = s }

        var atEnd: Bool { index >= s.count }
        func peek() -> Unicode.Scalar? { index < s.count ? s[index] : nil }

        mutating func skipWhitespace() {
            while index < s.count, s[index] == " " || s[index] == "\t"
                || s[index] == "\n" || s[index] == "\r" { index += 1 }
        }

        mutating func expect(_ scalar: Unicode.Scalar) throws {
            guard index < s.count, s[index] == scalar else {
                throw JSONParseError.malformed(offset: index)
            }
            index += 1
        }

        mutating func parseValue() throws -> SettingValue {
            guard let c = peek() else { throw JSONParseError.malformed(offset: index) }
            switch c {
            case "{": return try parseObject()
            case "[": return try parseArray()
            case "\"": return .string(try parseString())
            case "t": try literal("true"); return .bool(true)
            case "f": try literal("false"); return .bool(false)
            case "n": try literal("null"); return .null
            default: return try parseNumber()
            }
        }

        mutating func literal(_ word: String) throws {
            for scalar in word.unicodeScalars {
                guard index < s.count, s[index] == scalar else {
                    throw JSONParseError.malformed(offset: index)
                }
                index += 1
            }
        }

        mutating func parseObject() throws -> SettingValue {
            try expect("{")
            var object = JSONObject()
            skipWhitespace()
            if peek() == "}" { index += 1; return .object(object) }
            while true {
                skipWhitespace()
                let key = try parseString()
                skipWhitespace()
                try expect(":")
                skipWhitespace()
                object[key] = try parseValue()
                skipWhitespace()
                guard let c = peek() else { throw JSONParseError.malformed(offset: index) }
                if c == "," { index += 1; continue }
                if c == "}" { index += 1; return .object(object) }
                throw JSONParseError.malformed(offset: index)
            }
        }

        mutating func parseArray() throws -> SettingValue {
            try expect("[")
            var items: [SettingValue] = []
            skipWhitespace()
            if peek() == "]" { index += 1; return .array(items) }
            while true {
                skipWhitespace()
                items.append(try parseValue())
                skipWhitespace()
                guard let c = peek() else { throw JSONParseError.malformed(offset: index) }
                if c == "," { index += 1; continue }
                if c == "]" { index += 1; return .array(items) }
                throw JSONParseError.malformed(offset: index)
            }
        }

        mutating func parseString() throws -> String {
            try expect("\"")
            var out = String.UnicodeScalarView()
            while true {
                guard index < s.count else { throw JSONParseError.malformed(offset: index) }
                let c = s[index]
                index += 1
                if c == "\"" { return String(out) }
                if c != "\\" {
                    guard c.value >= 0x20 else { throw JSONParseError.malformed(offset: index) }
                    out.append(c)
                    continue
                }
                guard index < s.count else { throw JSONParseError.malformed(offset: index) }
                let e = s[index]
                index += 1
                switch e {
                case "\"": out.append("\"")
                case "\\": out.append("\\")
                case "/": out.append("/")
                case "b": out.append(Unicode.Scalar(8))
                case "f": out.append(Unicode.Scalar(12))
                case "n": out.append("\n")
                case "r": out.append("\r")
                case "t": out.append("\t")
                case "u":
                    let unit = try hex4()
                    // A high surrogate must be paired; an unpaired one is not
                    // representable as a Unicode.Scalar, so substitute U+FFFD
                    // rather than failing the whole config load.
                    if unit >= 0xD800, unit <= 0xDBFF,
                       index + 1 < s.count, s[index] == "\\", s[index + 1] == "u" {
                        let save = index
                        index += 2
                        let low = try hex4()
                        if low >= 0xDC00, low <= 0xDFFF {
                            let combined = 0x10000 + (UInt32(unit - 0xD800) << 10) + UInt32(low - 0xDC00)
                            out.append(Unicode.Scalar(combined) ?? "\u{FFFD}")
                        } else {
                            index = save
                            out.append("\u{FFFD}")
                        }
                    } else {
                        out.append(Unicode.Scalar(UInt32(unit)) ?? "\u{FFFD}")
                    }
                default: throw JSONParseError.malformed(offset: index)
                }
            }
        }

        mutating func hex4() throws -> UInt16 {
            guard index + 3 < s.count else { throw JSONParseError.malformed(offset: index) }
            var value: UInt16 = 0
            for _ in 0..<4 {
                let c = s[index]
                index += 1
                guard let digit = c.hexDigitValue else {
                    throw JSONParseError.malformed(offset: index)
                }
                value = value << 4 | UInt16(digit)
            }
            return value
        }

        mutating func parseNumber() throws -> SettingValue {
            let start = index
            if peek() == "-" { index += 1 }
            var isInteger = true
            while index < s.count {
                let c = s[index]
                if c >= "0", c <= "9" { index += 1; continue }
                if c == "." || c == "e" || c == "E" || c == "+" || c == "-" {
                    isInteger = false
                    index += 1
                    continue
                }
                break
            }
            guard index > start else { throw JSONParseError.malformed(offset: index) }
            let text = String(String.UnicodeScalarView(s[start..<index]))
            if isInteger, let i = Int(text) { return .int(i) }
            guard let d = Double(text) else { throw JSONParseError.malformed(offset: start) }
            return .double(d)
        }
    }
}

private extension Unicode.Scalar {
    var hexDigitValue: Int? {
        switch self {
        case "0"..."9": return Int(value - 48)
        case "a"..."f": return Int(value - 87)
        case "A"..."F": return Int(value - 55)
        default: return nil
        }
    }
}

// MARK: - Serialization

public extension WispritJSON {
    /// Byte-compatible with Python's `json.dumps(obj, indent=2, ensure_ascii=False)`:
    /// two-space indent, `": "` key separator, non-ASCII written raw, `/` never
    /// escaped. config.json is co-owned with the Python era; a formatting drift
    /// would show up as a spurious diff on every write.
    static func serializePretty(_ value: SettingValue, indent: Int = 2) -> String {
        var out = ""
        write(value, into: &out, indentWidth: indent, depth: 0)
        return out
    }

    /// Python's `json.dumps(obj)` default: `", "` and `": "` separators, one line.
    static func serializeCompact(_ value: SettingValue) -> String {
        var out = ""
        write(value, into: &out, indentWidth: nil, depth: 0)
        return out
    }

    private static func write(_ value: SettingValue, into out: inout String,
                              indentWidth: Int?, depth: Int) {
        switch value {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .int(let i): out += String(i)
        case .double(let d): out += pythonRepr(d)
        case .string(let s): out += quote(s)
        case .array(let items):
            if items.isEmpty { out += "[]"; return }
            out += "["
            for (i, item) in items.enumerated() {
                out += separator(first: i == 0, indentWidth, depth + 1)
                write(item, into: &out, indentWidth: indentWidth, depth: depth + 1)
            }
            out += closer(indentWidth, depth)
            out += "]"
        case .object(let object):
            if object.count == 0 { out += "{}"; return }
            out += "{"
            for (i, pair) in object.pairs.enumerated() {
                out += separator(first: i == 0, indentWidth, depth + 1)
                out += quote(pair.0)
                out += ": "
                write(pair.1, into: &out, indentWidth: indentWidth, depth: depth + 1)
            }
            out += closer(indentWidth, depth)
            out += "}"
        }
    }

    private static func separator(first: Bool, _ indentWidth: Int?, _ depth: Int) -> String {
        guard let indentWidth else { return first ? "" : ", " }
        return (first ? "\n" : ",\n") + String(repeating: " ", count: indentWidth * depth)
    }

    private static func closer(_ indentWidth: Int?, _ depth: Int) -> String {
        guard let indentWidth else { return "" }
        return "\n" + String(repeating: " ", count: indentWidth * depth)
    }

    /// Python `json` escapes only `"`, `\` and C0 controls; DEL and every
    /// non-ASCII scalar go through raw under `ensure_ascii=False`.
    static func quote(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case Unicode.Scalar(8): out += "\\b"
            case Unicode.Scalar(12): out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    /// Shortest round-tripping decimal, matching CPython's `float.__repr__`
    /// (which JSON uses for floats). Swift's `Double.description` uses the same
    /// shortest-round-trip rule and the same `1e+16` / `1e-05` exponent shape.
    static func pythonRepr(_ d: Double) -> String {
        if d.isNaN { return "NaN" }
        if d.isInfinite { return d < 0 ? "-Infinity" : "Infinity" }
        return d.description
    }
}
