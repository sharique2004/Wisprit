import Foundation

/// Edit-distance and Jaro-Winkler primitives for the antecedent scorer.
///
/// Behaviour is pinned to the Python libraries the research digest measured
/// with — `jellyfish.jaro_winkler_similarity` and
/// `rapidfuzz.distance.Levenshtein.normalized_distance` — because the 0.62
/// threshold and every published pair score derive from them. Two details that
/// differ between common implementations and matter here: Jaro-Winkler applies
/// its prefix boost only when the raw Jaro score EXCEEDS 0.7, and an empty
/// operand makes Jaro 0 (not 1, even for two empty strings).
public enum StringMetrics {

    public static func levenshtein(_ a: String, _ b: String) -> Int {
        levenshtein(Array(a), Array(b))
    }

    public static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let substitution = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                current[j] = min(previous[j] + 1, current[j - 1] + 1, substitution)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    /// `levenshtein / max(len)`, and 0 when both strings are empty.
    public static func normalizedLevenshtein(_ a: String, _ b: String) -> Double {
        let x = Array(a), y = Array(b)
        let longest = max(x.count, y.count)
        guard longest > 0 else { return 0 }
        return Double(levenshtein(x, y)) / Double(longest)
    }

    public static func jaro(_ a: String, _ b: String) -> Double {
        jaro(Array(a), Array(b))
    }

    public static func jaro(_ a: [Character], _ b: [Character]) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        let longest = max(a.count, b.count)
        let window = longest > 1 ? (longest / 2) - 1 : 0
        var aFlags = [Bool](repeating: false, count: a.count)
        var bFlags = [Bool](repeating: false, count: b.count)
        var matches = 0
        for i in 0..<a.count {
            let lo = max(0, i - window)
            let hi = min(b.count - 1, i + window)
            guard lo <= hi else { continue }
            for j in lo...hi where !bFlags[j] && b[j] == a[i] {
                aFlags[i] = true
                bFlags[j] = true
                matches += 1
                break
            }
        }
        guard matches > 0 else { return 0 }
        var transpositions = 0
        var k = 0
        for i in 0..<a.count where aFlags[i] {
            while !bFlags[k] { k += 1 }
            if a[i] != b[k] { transpositions += 1 }
            k += 1
        }
        let m = Double(matches)
        return (m / Double(a.count) + m / Double(b.count)
            + (m - Double(transpositions / 2)) / m) / 3
    }

    public static func jaroWinkler(_ a: String, _ b: String) -> Double {
        let x = Array(a), y = Array(b)
        let weight = jaro(x, y)
        guard weight > 0.7 else { return weight }
        let limit = min(min(x.count, y.count), 4)
        var prefix = 0
        while prefix < limit && x[prefix] == y[prefix] { prefix += 1 }
        return weight + 0.1 * Double(prefix) * (1 - weight)
    }
}

/// The hybrid phonetic scorer from the research digest, verbatim:
/// `max(0.6·codeSimilarity + 0.4·JaroWinkler, 0.9·JaroWinkler)`.
/// The second term is what rescues the real ASR failures Double Metaphone
/// cannot see — "Cherie" (XR) vs "Sharique" (XRK) would otherwise miss.
public enum PhoneticScorer {

    /// Best `1 − normalizedLevenshtein` over every cross pair of the two words'
    /// primary/secondary codes. Pairs where BOTH slots are empty are skipped,
    /// so an absent secondary never scores a free 1.0.
    public static func codeSimilarity(_ a: String, _ b: String) -> Double {
        let left = DoubleMetaphone.encode(a).slots
        let right = DoubleMetaphone.encode(b).slots
        var best = 0.0
        for x in left {
            for y in right where !(x.isEmpty && y.isEmpty) {
                best = max(best, 1 - StringMetrics.normalizedLevenshtein(x, y))
            }
        }
        return best
    }

    public static func score(_ a: String, _ b: String) -> Double {
        let jw = StringMetrics.jaroWinkler(a.lowercased(), b.lowercased())
        return max(0.6 * codeSimilarity(a, b) + 0.4 * jw, 0.9 * jw)
    }
}
