import XCTest

@testable import WispritCorrections

/// Golden parity for the vendored Double Metaphone port.
///
/// There is no Python counterpart for this module in `wisprit/`, so parity is
/// against the reference implementation the research digest's scorer numbers
/// were measured with. Regenerate with:
///
///   python3 -m pip install --target /tmp/pylibs metaphone==0.6
///   PYTHONPATH=/tmp/pylibs python3 -c '
///   from metaphone import doublemetaphone as dm
///   for w in WORDS: p, s = dm(w); print(repr(w), "|", p, "|", s)'
///
/// where WORDS is the left column below. Every expectation here is that
/// command's output, not a hand-derived one.
final class DoubleMetaphoneTests: XCTestCase {

    private static let goldens: [(String, String, String)] = [
        // the research's own vocabulary
        ("Sharique", "XRK", ""), ("Shariq", "XRK", ""), ("Sharik", "XRK", ""),
        ("Sherrick", "XRK", ""), ("Cherie", "XR", ""), ("Cheri", "XR", ""),
        ("Krzysztof", "KRSSTF", "KRTSXTF"), ("Caelum", "KLM", ""), ("Kaylum", "KLM", ""),
        ("Jon", "JN", "AN"), ("John", "JN", "AN"),
        ("InsForge", "ANSFRJ", "ANSFRK"), ("Inns Forge", "ANSFRJ", "ANSFRK"),
        ("whispered", "ASPRT", ""), ("Wisprit", "ASPRT", "FSPRT"),
        ("Siobhan", "SPN", "XPN"), ("Shivon", "XFN", ""),
        ("Xiaoli", "SL", ""), ("Shiaowly", "XL", ""),
        ("Aoife", "AF", ""), ("Eefa", "AF", ""),
        ("roadmap", "RTMP", ""), ("tomorrow", "TMR", "TMRF"), ("today", "TT", ""),
        ("production", "PRTKXN", ""), ("email", "AML", ""), ("migration", "MKRXN", ""),
        ("ping", "PNK", ""), ("parser", "PRSR", ""),
        ("JSON", "JSN", "ASN"), ("SHARIQUE", "XRK", ""), ("KRZYSZTOF", "KRSSTF", "KRTSXTF"),
        ("Nguyen", "NKN", ""), ("Win", "AN", "FN"),

        // classic Double Metaphone regression words — these exercise the C, G,
        // H, J, L, S, T, W, X and Z rule tangles and the deliberate quirks
        ("Smith", "SM0", "XMT"), ("Schmidt", "XMT", "SMT"), ("Thompson", "TMPSN", ""),
        ("Xavier", "SF", "SFR"), ("Jose", "JS", "HS"), ("San Jacinto", "SNHSNT", ""),
        ("Knight", "NT", ""), ("Wright", "RT", ""), ("Ghislane", "JLN", ""),
        ("Caesar", "SSR", ""), ("chianti", "KNT", ""), ("McClellan", "MKLLN", ""),
        ("focaccia", "FKX", ""), ("bellocchio", "PLX", ""), ("bacchus", "PKS", ""),
        ("accident", "AKSTNT", ""), ("succeed", "SKST", ""), ("campbell", "KMPL", ""),
        ("raspberry", "RSPR", ""), ("filipowicz", "FLPTS", "FLPFX"), ("breaux", "PR", ""),
        ("zhao", "J", ""), ("school", "SKL", ""),
        ("schermerhorn", "XRMRRN", "SKRMRRN"), ("resnais", "RSN", "RSNS"),
        ("artois", "ART", "ARTS"), ("island", "ALNT", ""), ("carlisle", "KRLL", ""),
        ("sugar", "XKR", "SKR"), ("dumb", "TMP", ""), ("thomas", "TMS", ""),
        ("laugh", "LF", ""), ("hugh", "HH", ""), ("edge", "AJ", ""), ("cagney", "KKN", ""),
        ("tagliaro", "TKLR", "TLR"), ("biaggi", "PJ", "PK"), ("danger", "TNJR", "TNKR"),
        ("van der wal", "FNTRL", ""), ("Von Neumann", "FNNMN", ""),
        ("Wilson", "ALSN", "FLSN"), ("Arnow", "ARN", "ARNF"), ("Arnoff", "ARNF", ""),
        ("Yankelovich", "ANKLFX", "ANKLFK"), ("Jankelowicz", "JNKLTS", "ANKLFX"),
        ("gnome", "NM", ""), ("knot", "NT", ""), ("pneumatic", "NMTK", ""),
        ("wrack", "RK", ""), ("psycho", "SX", "SK"),
        ("cabrillo", "KPRL", "KPR"), ("gallegos", "KLKS", "KKS"),
        ("Michael", "MKL", "MXL"), ("Bacher", "PKR", ""), ("Czerny", "SRN", "XRN"),
        ("Wicz", "AKS", "FKTS"), ("schooner", "SKNR", ""), ("Schenker", "XNKR", "SKNKR"),
        ("dgi", "J", ""), ("judge", "JJ", "AJ"), ("bajador", "PJTR", "PHTR"),
        ("hochmeier", "HKMR", ""), ("rogier", "RJ", "RKR"),
        ("Zosia", "SS", "SX"), ("aaa", "A", ""), ("", "", ""), ("x", "S", ""),
        ("Y", "A", ""), ("O'Brien", "AAPRN", ""), ("MacGregor", "MKRKR", ""),
        ("mac caffrey", "MKFR", ""), ("dumber", "TMPR", ""), ("number", "NMPR", ""),
        ("thumb", "0MP", "TMP"), ("autumn", "ATMN", ""), ("GH", "K", ""),
        ("tough", "TF", ""), ("McLaughlin", "MKLFLN", ""), ("gough", "KF", ""),
        ("ghiradelli", "JRTL", ""), ("Villa", "FL", "F"), ("tortilla", "TRTL", "TRT"),
        ("Zhang", "JNK", ""), ("Zoe", "S", ""), ("Muzza", "MS", "MTS"),
        ("Aachen", "AXN", "AKN"), ("Bach", "PK", ""),

        // word-final J emits a literal SPACE as its secondary — a reference
        // quirk that must survive the port, because it moves code similarity.
        ("Andrzej", "ANTRSJ", "ANTRS "),
    ]

    func testMatchesReferenceImplementation() {
        for (word, primary, secondary) in Self.goldens {
            let code = DoubleMetaphone.encode(word)
            XCTAssertEqual(code.primary, primary, "primary for \(word.debugDescription)")
            XCTAssertEqual(code.secondary, secondary, "secondary for \(word.debugDescription)")
        }
    }

    func testEncodingIsCaseAndAccentInsensitive() {
        XCTAssertEqual(DoubleMetaphone.encode("SHARIQUE"), DoubleMetaphone.encode("sharique"))
        XCTAssertEqual(DoubleMetaphone.encode("Aoife"), DoubleMetaphone.encode("Ao\u{0069}\u{0301}fe"))
    }
}
