import Foundation

// Double Metaphone — vendored, so the module keeps zero third-party dependencies.
//
// PROVENANCE. The algorithm is Lawrence Philips' Double Metaphone, published in
// the June 2000 C/C++ Users Journal and placed in the public domain. This file
// is a line-for-line Swift transcription of the widely-used Python port
// (PyPI `metaphone` 0.6 — metaphone/metaphone.py + metaphone/word.py, BSD;
// Andrew Collins 2007, from Maurice Aubrey's C, from Kevin Atkinson's C++).
//
// That specific port is the reference on purpose: every scorer number in the
// correction-detection research digest was measured against it, so its quirks
// are load-bearing and are reproduced deliberately rather than tidied away:
//   * `step` is instance state, so a character no branch handles (a digit,
//     punctuation) silently RE-APPLIES the previous step's code and advance;
//   * two branches of `processG` fall through without assigning, which is the
//     same carry-over;
//   * word-final 'J' emits a literal SPACE as its secondary code
//     ("Andrzej" → ANTRSJ / "ANTRS ");
//   * 'L' and 'R' and 'W' and 'S' can emit an EMPTY primary or secondary,
//     which drops that side ("Villa" → FL / F).
// Index arithmetic mirrors Python's: the working buffer is padded "--" in front
// and "------" behind, and `sub` reproduces Python slice semantics (including
// negative bounds) so out-of-range lookahead yields "" instead of trapping.

public enum DoubleMetaphone {

    public struct Code: Equatable, Sendable {
        public let primary: String
        /// Empty when identical to `primary` — the reference's convention.
        public let secondary: String

        public init(primary: String, secondary: String) {
            self.primary = primary
            self.secondary = secondary
        }

        /// Both slots verbatim, empty secondary included. The scorer compares
        /// every cross pair, so it needs the raw two-slot shape.
        public var slots: [String] { [primary, secondary] }
    }

    public static func encode(_ input: String) -> Code {
        var encoder = Encoder(input)
        return encoder.run()
    }
}

private struct Encoder {

    private static let vowels: Set<Character> = ["A", "E", "I", "O", "U", "Y"]
    private static let silentStarters: Set<String> = ["GN", "KN", "PN", "WR", "PS"]

    private struct Step {
        var p: String?
        var s: String?
        var advance: Int
    }

    private let buffer: [Character]
    private let startIndex: Int
    private let endIndex: Int
    private let isSlavoGermanic: Bool

    private var position: Int
    private var primary = ""
    private var secondary = ""
    private var step = Step(p: nil, s: nil, advance: 1)

    init(_ input: String) {
        // Ç/ç are folded to "s" BEFORE decomposition; decomposing first would
        // strip the cedilla and yield "c" instead (reference behaviour).
        var decoded = input.replacingOccurrences(of: "\u{00C7}", with: "s")
        decoded = decoded.replacingOccurrences(of: "\u{00E7}", with: "s")
        let stripped = String(
            decoded.decomposedStringWithCanonicalMapping.unicodeScalars.filter {
                $0.properties.generalCategory != .nonspacingMark
            })
        let upper = Array(stripped.uppercased())
        startIndex = 2
        endIndex = 2 + upper.count - 1
        buffer = Array("--") + upper + Array("------")
        let joined = String(upper)
        isSlavoGermanic =
            joined.contains("W") || joined.contains("K")
            || joined.contains("CZ") || joined.contains("WITZ")
        position = 2
    }

    // MARK: - Buffer access (Python semantics)

    private func at(_ index: Int) -> Character {
        (index >= 0 && index < buffer.count) ? buffer[index] : "\u{0}"
    }

    /// Python `buffer[a:b]`, negative bounds and over-runs included.
    private func sub(_ a: Int, _ b: Int) -> String {
        let n = buffer.count
        let lo = a < 0 ? max(n + a, 0) : min(a, n)
        let hi = b < 0 ? max(n + b, 0) : min(b, n)
        guard hi > lo else { return "" }
        return String(buffer[lo..<hi])
    }

    private func same(_ code: String?, _ advance: Int) -> Step {
        Step(p: code, s: code, advance: advance)
    }

    private func split(_ p: String?, _ s: String?, _ advance: Int) -> Step {
        Step(p: p, s: s, advance: advance)
    }

    // MARK: - Driver

    mutating func run() -> DoubleMetaphone.Code {
        checkWordStart()
        while position <= endIndex {
            let c = buffer[position]
            if Encoder.vowels.contains(c) {
                processInitialVowels()
            } else if c == " " {
                position += 1
                continue
            } else {
                switch c {
                case "B": processB()
                case "C": processC()
                case "D": processD()
                case "F": processF()
                case "G": processG()
                case "H": processH()
                case "J": processJ()
                case "K": processK()
                case "L": processL()
                case "M": processM()
                case "N": processN()
                case "P": processP()
                case "Q": processQ()
                case "R": processR()
                case "S": processS()
                case "T": processT()
                case "V": processV()
                case "W": processW()
                case "X": processX()
                case "Z": processZ()
                default: break  // carry the previous step over, as the reference does
                }
            }
            if let p = step.p, !p.isEmpty { primary += p }
            if let s = step.s, !s.isEmpty { secondary += s }
            position += step.advance
        }
        return DoubleMetaphone.Code(
            primary: primary, secondary: primary == secondary ? "" : secondary)
    }

    private mutating func checkWordStart() {
        if Encoder.silentStarters.contains(sub(startIndex, startIndex + 2)) {
            position += 1
        }
        // Initial 'X' is pronounced 'Z' e.g. 'Xavier'; note this ASSIGNS both
        // codes rather than appending.
        if sub(startIndex, startIndex + 1) == "X" {
            primary = "S"
            secondary = "S"
            position += 1
        }
    }

    private mutating func processInitialVowels() {
        step = same(nil, 1)
        if position == startIndex { step = same("A", 1) }
    }

    // MARK: - Per-letter rules

    private mutating func processB() {
        step = at(position + 1) == "B" ? same("P", 2) : same("P", 1)
    }

    private mutating func processC() {
        let p = position, si = startIndex
        // various germanic
        if p > si + 1
            && !Encoder.vowels.contains(at(p - 2))
            && sub(p - 1, p + 2) == "ACH"
            && at(p + 2) != "I"
            && (at(p + 2) != "E" || ["BACHER", "MACHER"].contains(sub(p - 2, p + 4)))
        {
            step = same("K", 2)
        } else if p == si && sub(si, si + 6) == "CAESAR" {
            step = same("S", 2)
        } else if sub(p, p + 4) == "CHIA" {  // italian 'chianti'
            step = same("K", 2)
        } else if sub(p, p + 2) == "CH" {
            if p > si && sub(p, p + 4) == "CHAE" {  // 'michael'
                step = split("K", "X", 2)
            } else if p == si
                && (["HARAC", "HARIS"].contains(sub(p + 1, p + 6))
                    || ["HOR", "HYM", "HIA", "HEM"].contains(sub(p + 1, p + 4)))
                && sub(si, si + 5) != "CHORE"
            {
                step = same("K", 2)
            } else if ["VAN ", "VON "].contains(sub(si, si + 4))
                || sub(si, si + 3) == "SCH"
                || ["ORCHES", "ARCHIT", "ORCHID"].contains(sub(p - 2, p + 4))
                || "TS".contains(at(p + 2))
                || (("AOUE".contains(at(p - 1)) || p == si)
                    && "LRNMBHFVW".contains(at(p + 2)))
            {
                step = same("K", 2)
            } else if p > si {
                step = sub(si, si + 2) == "MC" ? same("K", 2) : split("X", "K", 2)
            } else {
                step = same("X", 2)
            }
        } else if sub(p, p + 2) == "CZ" && sub(p - 2, p + 2) != "WICZ" {  // 'czerny'
            step = split("S", "X", 2)
        } else if sub(p + 1, p + 4) == "CIA" {  // 'focaccia'
            step = same("X", 3)
        } else if sub(p, p + 2) == "CC" && !(p == si + 1 && at(si) == "M") {
            if "IEH".contains(at(p + 2)) && sub(p + 2, p + 4) != "HU" {
                if (p == si + 1 && at(si) == "A")
                    || ["UCCEE", "UCCES"].contains(sub(p - 1, p + 4))
                {
                    step = same("KS", 3)
                } else {
                    step = same("X", 3)  // 'bacci', other italian
                }
            } else {
                step = same("K", 2)
            }
        } else if ["CK", "CG", "CQ"].contains(sub(p, p + 2)) {
            step = same("K", 2)
        } else if ["CI", "CE", "CY"].contains(sub(p, p + 2)) {
            step = ["CIO", "CIE", "CIA"].contains(sub(p, p + 3))
                ? split("S", "X", 2) : same("S", 2)
        } else if [" C", " Q", " G"].contains(sub(p + 1, p + 3)) {
            step = same("K", 3)  // 'mac caffrey', 'mac gregor'
        } else if "CKQ".contains(at(p + 1)) && !["CE", "CI"].contains(sub(p + 1, p + 3)) {
            step = same("K", 2)
        } else {
            step = same("K", 1)
        }
    }

    private mutating func processD() {
        let p = position
        if sub(p, p + 2) == "DG" {
            step = "IEY".contains(at(p + 2)) ? same("J", 3) : same("TK", 2)
        } else if ["DT", "DD"].contains(sub(p, p + 2)) {
            step = same("T", 2)
        } else {
            step = same("T", 1)
        }
    }

    private mutating func processF() {
        step = at(position + 1) == "F" ? same("F", 2) : same("F", 1)
    }

    private mutating func processG() {
        let p = position, si = startIndex
        if at(p + 1) == "H" {
            if p > si && !Encoder.vowels.contains(at(p - 1)) {
                step = same("K", 2)
            } else if p < si + 3 {
                // 'ghislane', 'ghiradelli' — otherwise the step CARRIES OVER.
                if p == si {
                    step = at(p + 2) == "I" ? same("J", 2) : same("K", 2)
                }
            } else if (p > si + 1 && "BHD".contains(at(p - 2)))
                || (p > si + 2 && "BHD".contains(at(p - 3)))
                || (p > si + 3 && "BH".contains(at(p - 4)))
            {
                step = same(nil, 2)  // Parker's rule, e.g. 'hugh'
            } else if p > si + 2 && at(p - 1) == "U" && "CGLRT".contains(at(p - 3)) {
                step = same("F", 2)  // 'laugh', 'cough', 'rough'
            } else if p > si && at(p - 1) != "I" {
                step = same("K", 2)
            }
        } else if at(p + 1) == "N" {
            if p == si + 1 && Encoder.vowels.contains(at(si)) && !isSlavoGermanic {
                step = split("KN", "N", 2)
            } else if sub(p + 2, p + 4) != "EY" && at(p + 1) != "Y" && !isSlavoGermanic {
                step = split("N", "KN", 2)  // not e.g. 'cagney'
            } else {
                step = same("KN", 2)
            }
        } else if sub(p + 1, p + 3) == "LI" && !isSlavoGermanic {  // 'tagliaro'
            step = split("KL", "L", 2)
        } else if p == si
            && (at(p + 1) == "Y"
                || ["ES", "EP", "EB", "EL", "EY", "IB", "IL", "IN", "IE", "EI", "ER"]
                    .contains(sub(p + 1, p + 3)))
        {
            step = split("K", "J", 2)
        } else if (sub(p + 1, p + 3) == "ER" || at(p + 1) == "Y")
            && !["DANGER", "RANGER", "MANGER"].contains(sub(si, si + 6))
            && !"EI".contains(at(p - 1))
            && !["RGY", "OGY"].contains(sub(p - 1, p + 2))
        {
            step = split("K", "J", 2)
        } else if "EIY".contains(at(p + 1)) || ["AGGI", "OGGI"].contains(sub(p - 1, p + 3)) {
            if ["VON ", "VAN "].contains(sub(si, si + 4))
                || sub(si, si + 3) == "SCH"
                || sub(p + 1, p + 3) == "ET"
            {
                step = same("K", 2)  // obvious germanic
            } else {
                step = sub(p + 1, p + 5) == "IER " ? same("J", 2) : split("J", "K", 2)
            }
        } else if at(p + 1) == "G" {
            step = same("K", 2)
        } else {
            step = same("K", 1)
        }
    }

    private mutating func processH() {
        // Keep only at word start before a vowel, or between two vowels.
        if (position == startIndex || Encoder.vowels.contains(at(position - 1)))
            && Encoder.vowels.contains(at(position + 1))
        {
            step = same("H", 2)
        } else {
            step = same(nil, 1)
        }
    }

    private mutating func processJ() {
        let p = position, si = startIndex
        var sp: String?
        var ss: String?
        if sub(p, p + 4) == "JOSE" || sub(si, si + 4) == "SAN " {
            if (p == si && at(p + 4) == " ") || sub(si, si + 4) == "SAN " {
                sp = "H"; ss = "H"
            } else {
                sp = "J"; ss = "H"
            }
        } else if p == si && sub(p, p + 4) != "JOSE" {
            sp = "J"; ss = "A"  // Yankelovich / Jankelowicz
        } else if Encoder.vowels.contains(at(p - 1)) && !isSlavoGermanic
            && "AO".contains(at(p + 1))
        {
            sp = "J"; ss = "H"  // spanish 'bajador'
        } else if p == endIndex {
            sp = "J"; ss = " "  // reference quirk: a literal space
        } else if !"LTKSNMBZ".contains(at(p + 1)) && !"SKL".contains(at(p - 1)) {
            sp = "J"; ss = "J"
        } else {
            sp = nil; ss = nil
        }
        step = Step(p: sp, s: ss, advance: at(p + 1) == "J" ? 2 : 1)
    }

    private mutating func processK() {
        step = at(position + 1) == "K" ? same("K", 2) : same("K", 1)
    }

    private mutating func processL() {
        let p = position
        if at(p + 1) == "L" {
            if (p == endIndex - 2 && ["ILLO", "ILLA", "ALLE"].contains(sub(p - 1, p + 3)))
                || ((["AS", "OS"].contains(sub(endIndex - 1, endIndex + 1))
                    || "AO".contains(at(endIndex)))
                    && sub(p - 1, p + 3) == "ALLE")
            {
                step = split("L", "", 2)  // spanish 'cabrillo', 'gallegos'
            } else {
                step = same("L", 2)
            }
        } else {
            step = same("L", 1)
        }
    }

    private mutating func processM() {
        let p = position
        if (sub(p + 1, p + 4) == "UMB" && (p + 1 == endIndex || sub(p + 2, p + 4) == "ER"))
            || at(p + 1) == "M"
        {
            step = same("M", 2)
        } else {
            step = same("M", 1)
        }
    }

    private mutating func processN() {
        step = at(position + 1) == "N" ? same("N", 2) : same("N", 1)
    }

    private mutating func processP() {
        let p = position
        if at(p + 1) == "H" {
            step = same("F", 2)
        } else if "PB".contains(at(p + 1)) {  // 'campbell', 'raspberry'
            step = same("P", 2)
        } else {
            step = same("P", 1)
        }
    }

    private mutating func processQ() {
        step = at(position + 1) == "Q" ? same("K", 2) : same("K", 1)
    }

    private mutating func processR() {
        let p = position
        var sp: String?
        var ss: String?
        // french 'rogier', but exclude 'hochmeier'
        if p == endIndex && !isSlavoGermanic && sub(p - 2, p) == "IE"
            && !["ME", "MA"].contains(sub(p - 4, p - 2))
        {
            sp = ""; ss = "R"
        } else {
            sp = "R"; ss = "R"
        }
        step = Step(p: sp, s: ss, advance: at(p + 1) == "R" ? 2 : 1)
    }

    private mutating func processS() {
        let p = position, si = startIndex
        if ["ISL", "YSL"].contains(sub(p - 1, p + 2)) {  // 'island', 'carlisle'
            step = same(nil, 1)
        } else if p == si && sub(si, si + 5) == "SUGAR" {
            step = split("X", "S", 1)
        } else if sub(p, p + 2) == "SH" {
            step = ["HEIM", "HOEK", "HOLM", "HOLZ"].contains(sub(p + 1, p + 5))
                ? same("S", 2) : same("X", 2)
        } else if ["SIO", "SIA"].contains(sub(p, p + 3)) || sub(p, p + 4) == "SIAN" {
            step = isSlavoGermanic ? same("S", 3) : split("S", "X", 3)
        } else if (p == si && "MNLW".contains(at(p + 1))) || at(p + 1) == "Z" {
            step = split("S", "X", at(p + 1) == "Z" ? 2 : 1)
        } else if sub(p, p + 2) == "SC" {
            if at(p + 2) == "H" {  // Schlesinger's rule
                if ["OO", "ER", "EN", "UY", "ED", "EM"].contains(sub(p + 3, p + 5)) {
                    step = ["ER", "EN"].contains(sub(p + 3, p + 5))
                        ? split("X", "SK", 3) : same("SK", 3)
                } else if p == si && !Encoder.vowels.contains(at(si + 3)) && at(si + 3) != "W" {
                    step = split("X", "S", 3)
                } else {
                    step = same("X", 3)
                }
            } else if "IEY".contains(at(p + 2)) {
                step = same("S", 3)
            } else {
                step = same("SK", 3)
            }
        } else if p == endIndex && ["AI", "OI"].contains(sub(p - 2, p)) {
            step = split("", "S", 1)  // french 'resnais', 'artois'
        } else {
            step = same("S", "SZ".contains(at(p + 1)) ? 2 : 1)
        }
    }

    private mutating func processT() {
        let p = position, si = startIndex
        if sub(p, p + 4) == "TION" {
            step = same("X", 3)
        } else if ["TIA", "TCH"].contains(sub(p, p + 3)) {
            step = same("X", 3)
        } else if sub(p, p + 2) == "TH" || sub(p, p + 3) == "TTH" {
            if ["OM", "AM"].contains(sub(p + 2, p + 4))
                || ["VON ", "VAN "].contains(sub(si, si + 4))
                || sub(si, si + 3) == "SCH"
            {
                step = same("T", 2)  // 'thomas', 'thames', germanic
            } else {
                step = split("0", "T", 2)
            }
        } else if "TD".contains(at(p + 1)) {
            step = same("T", 2)
        } else {
            step = same("T", 1)
        }
    }

    private mutating func processV() {
        step = at(position + 1) == "V" ? same("F", 2) : same("F", 1)
    }

    private mutating func processW() {
        let p = position, si = startIndex
        if sub(p, p + 2) == "WR" {
            step = same("R", 2)
        } else if p == si && (Encoder.vowels.contains(at(p + 1)) || sub(p, p + 2) == "WH") {
            // Wasserman should match Vasserman
            step = Encoder.vowels.contains(at(p + 1)) ? split("A", "F", 1) : same("A", 1)
        } else if (p == endIndex && Encoder.vowels.contains(at(p - 1)))
            || ["EWSKI", "EWSKY", "OWSKI", "OWSKY"].contains(sub(p - 1, p + 4))
            || sub(si, si + 3) == "SCH"
        {
            step = split("", "F", 1)  // Arnow should match Arnoff
        } else if ["WICZ", "WITZ"].contains(sub(p, p + 4)) {
            step = split("TS", "FX", 4)  // polish 'filipowicz'
        } else {
            step = same(nil, 1)
        }
    }

    private mutating func processX() {
        let p = position
        var code: String?
        // french 'breaux'
        if !(p == endIndex
            && (["IAU", "EAU"].contains(sub(p - 3, p)) || ["AU", "OU"].contains(sub(p - 2, p))))
        {
            code = "KS"
        }
        step = same(code, "CX".contains(at(p + 1)) ? 2 : 1)
    }

    private mutating func processZ() {
        let p = position
        var sp: String?
        var ss: String?
        if at(p + 1) == "H" {  // chinese pinyin 'zhao'
            sp = "J"; ss = "J"
        } else if ["ZO", "ZI", "ZA"].contains(sub(p + 1, p + 3))
            || (isSlavoGermanic && p > startIndex && at(p - 1) != "T")
        {
            sp = "S"; ss = "TS"
        } else {
            sp = "S"; ss = "S"
        }
        let advance = (at(p + 1) == "Z" || at(p + 1) == "H") ? 2 : 1
        step = Step(p: sp, s: ss, advance: advance)
    }
}
