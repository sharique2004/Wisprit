import XCTest
import WispritKit

@testable import WispritCorrections

/// Golden parity for Jaro-Winkler and the hybrid scorer.
///
/// Regenerate with the same libraries the research measured on this machine:
///
///   python3 -m pip install --target /tmp/pylibs jellyfish==1.2.1 metaphone==0.6 rapidfuzz==3.14.5
///   PYTHONPATH=/tmp/pylibs python3 -c '
///   import jellyfish
///   from metaphone import doublemetaphone as dm
///   from rapidfuzz.distance import Levenshtein
///   def codesim(a, b):
///       return max((1 - Levenshtein.normalized_distance(x, y)
///                   for x in dm(a) for y in dm(b) if x or y), default=0.0)
///   def score(a, b):
///       jw = jellyfish.jaro_winkler_similarity(a.lower(), b.lower())
///       return max(0.6 * codesim(a, b) + 0.4 * jw, 0.9 * jw)
///   for a, b in PAIRS: print(repr(a), repr(b), repr(score(a, b)))'
final class PhoneticScorerTests: XCTestCase {

    private static let accuracy = 1e-9

    // jellyfish.jaro_winkler_similarity — note the prefix boost applies only
    // when raw Jaro EXCEEDS 0.7 ("abcde"/"abfgh" stays at 0.6), and an empty
    // operand scores 0 even against another empty string.
    func testJaroWinklerMatchesJellyfish() {
        let goldens: [(String, String, Double)] = [
            ("abcde", "abfgh", 0.6),
            ("ab", "abcdefgh", 0.8),
            ("dwayne", "duane", 0.84),
            ("martha", "marhta", 0.961111111111),
            ("dixon", "dicksonx", 0.813333333333),
            ("jellyfish", "smellyfish", 0.896296296296),
            ("", "abc", 0.0),
            ("abc", "", 0.0),
            ("", "", 0.0),
            ("a", "a", 1.0),
            ("cherie", "sharique", 0.722222222222),
            ("krzysztof", "cherie", 0.425925925926),
            ("sharique", "sharique", 1.0),
            ("xrk", "xr", 0.911111111111),
            ("insforge", "inns forge", 0.946666666667),
        ]
        for (a, b, expected) in goldens {
            XCTAssertEqual(
                StringMetrics.jaroWinkler(a, b), expected, accuracy: 1e-11,
                "jaroWinkler(\(a.debugDescription), \(b.debugDescription))")
        }
    }

    func testNormalizedLevenshtein() {
        XCTAssertEqual(StringMetrics.normalizedLevenshtein("", ""), 0)
        XCTAssertEqual(StringMetrics.normalizedLevenshtein("", "XRK"), 1)
        XCTAssertEqual(StringMetrics.normalizedLevenshtein("XRK", "XR"), 1.0 / 3.0, accuracy: Self.accuracy)
        XCTAssertEqual(StringMetrics.normalizedLevenshtein("XRK", "XRK"), 0)
    }

    /// The 11 true and 5 false pairs the digest enumerates, plus the pairs the
    /// decision tests depend on. Threshold 0.62 separates them cleanly.
    private static let truePairs: [(String, String, Double)] = [
        ("Shariq", "Sharique", 0.98),
        ("Sharik", "Sharique", 0.956666666667),
        ("Sherrick", "Sharique", 0.866666666667),
        ("Caelum", "Kaylum", 0.911111111111),
        ("Jon", "John", 0.973333333333),
        ("Inns Forge", "InsForge", 0.978666666667),
        ("whispered", "Wisprit", 0.912380952381),
        ("Cherie", "Sharique", 0.688888888889),
        ("Siobhan", "Shivon", 0.708571428571),
        ("Xiaoli", "Shiaowly", 0.65),
        ("Aoife", "Eefa", 0.793333333333),
        // observed DictationTranscriber misrecognition, and the uppercase form
        // the detector actually hands the scorer
        ("Cheri", "Sharique", 0.663333333333),
        ("Shariq", "SHARIQUE", 0.98),
        ("Cherie", "SHARIQUE", 0.688888888889),
    ]

    private static let falsePairs: [(String, String, Double)] = [
        ("roadmap", "Sharique", 0.310714285714),
        ("tomorrow", "Sharique", 0.375),
        ("today", "Kaylum", 0.52),
        ("production", "Wisprit", 0.516428571429),
        ("email", "Sharique", 0.495),
        // the unfixable tail: ASR mangled "Krzysztof" into "Cherie"
        ("Cherie", "Krzysztof", 0.383333333333),
        ("roadmap", "Krzysztof", 0.376190476190),
        ("migration", "Krzysztof", 0.5),
        ("ping", "Sharique", 0.4125),
        ("migration", "Sharique", 0.4125),
        ("Correction", "SHARIQUE", 0.418888888889),
        ("spelled", "SHARIQUE", 0.460714285714),
        ("actually", "SHARIQUE", 0.45),
        ("parser", "JSON", 0.425),
        ("Shariq", "JSON", 0.425),
    ]

    func testScorerMatchesResearchGoldens() {
        for (a, b, expected) in Self.truePairs + Self.falsePairs {
            XCTAssertEqual(
                PhoneticScorer.score(a, b), expected, accuracy: 1e-11,
                "score(\(a.debugDescription), \(b.debugDescription))")
        }
    }

    func testThresholdSeparatesTrueFromFalsePairs() {
        for (a, b, _) in Self.truePairs {
            XCTAssertGreaterThanOrEqual(
                PhoneticScorer.score(a, b), AntecedentMatcher.threshold, "\(a) vs \(b)")
        }
        for (a, b, _) in Self.falsePairs {
            XCTAssertLessThan(
                PhoneticScorer.score(a, b), AntecedentMatcher.threshold, "\(a) vs \(b)")
        }
    }

    /// Double Metaphone alone misses this pair (XR vs XRK); the 0.9·JW term is
    /// the only reason "Cherie" is recoverable at all.
    func testJaroWinklerTermRescuesWhereDoubleMetaphoneFails() {
        XCTAssertNotEqual(
            DoubleMetaphone.encode("Cherie").primary,
            DoubleMetaphone.encode("Sharique").primary)
        XCTAssertLessThan(PhoneticScorer.codeSimilarity("Cherie", "Sharique"), 0.7)
        XCTAssertGreaterThanOrEqual(
            PhoneticScorer.score("Cherie", "Sharique"), AntecedentMatcher.threshold)
    }
}
