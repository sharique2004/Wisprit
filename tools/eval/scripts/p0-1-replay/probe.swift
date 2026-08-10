// P0-1 hear-phrase replay probe (FINAL-PLAN R8 / A-5). Tooling, not app code.
//
// Question it answers: if the hear-phrase miner (personalization.md P0-1) had
// existed, how many *new* catches per 100 utterances would it have produced on
// this user's own history? The kill bar is pre-registered: fewer than a
// handful/100 and the full miner (R25) never gets built.
//
// Method (the report's own replay design):
//   1. Split `utterance_detail` rows chronologically in half.
//   2. Mine half 1: align `raw` against the resolved text (`inserted`, falling
//      back to `corrected`) with the same word-level LCS + mismatch-block
//      logic `EditObservationGate` uses (ported verbatim below); a mismatch
//      block whose resolved side is a known dictionary term makes the raw side
//      a candidate hear phrase for that term.
//   3. Promote candidates seen in >= 2 distinct utterances (the ledger
//      discipline) into a *copy* of the dictionary via the real
//      `DictionaryStore.add` merge path -> hear-set v2.
//   4. Replay half 2's raw strings through `DictionaryStore.applyCorrections`
//      v1 vs v2; rows where v2 changes text that v1 left alone are new catches.
//
// Compiled by run.sh together with the app's own WispritKit + WispritDictionary
// sources (read-only; intra-package `import` lines stripped for a flat build),
// so `applyCorrections` and the learn merge are the real machinery, not a
// re-implementation. Reads only the copies run.sh made — never ~/.wisprit.

import Foundation

// MARK: - inputs (exported by run.sh)

struct Row: Codable {
    var id: Int
    var raw: String?
    var corrected: String?
    var inserted: String?
    var created: Double?
}

// MARK: - alignment (verbatim port of EditObservationGate's table + blocks)

func lcs(_ a: [String], _ b: [String]) -> [(ours: Int, theirs: Int)] {
    guard !a.isEmpty, !b.isEmpty else { return [] }
    var table = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1),
                        count: a.count + 1)
    for i in stride(from: a.count - 1, through: 0, by: -1) {
        for j in stride(from: b.count - 1, through: 0, by: -1) {
            table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1
                                       : max(table[i + 1][j], table[i][j + 1])
        }
    }
    var pairs: [(ours: Int, theirs: Int)] = []
    var i = 0, j = 0
    while i < a.count, j < b.count {
        if a[i] == b[j] { pairs.append((i, j)); i += 1; j += 1 }
        else if table[i + 1][j] >= table[i][j + 1] { i += 1 }
        else { j += 1 }
    }
    return pairs
}

struct Block { var ours: Range<Int>; var theirs: Range<Int> }

func mismatchBlocks(oursCount: Int, theirsCount: Int,
                    matched: [(ours: Int, theirs: Int)]) -> [Block] {
    var blocks: [Block] = []
    var oursCursor = 0, theirsCursor = 0
    for pair in matched {
        if pair.ours > oursCursor || pair.theirs > theirsCursor {
            blocks.append(Block(ours: oursCursor..<pair.ours,
                                theirs: theirsCursor..<pair.theirs))
        }
        oursCursor = pair.ours + 1
        theirsCursor = pair.theirs + 1
    }
    if oursCursor < oursCount || theirsCursor < theirsCount {
        blocks.append(Block(ours: oursCursor..<oursCount,
                            theirs: theirsCursor..<theirsCount))
    }
    return blocks
}

func tokens(_ text: String) -> [String] {
    text.lowercased()
        .replacingOccurrences(of: "\u{2019}", with: "'")
        .split { !($0.isLetter || $0.isNumber || $0 == "'") }
        .map(String.init)
        .filter { !$0.isEmpty }
}

struct Candidate: Hashable { var term: String; var heard: String }

// MARK: - the probe

@main
enum Probe {
    static func main() throws {
        guard CommandLine.arguments.count == 4 else {
            FileHandle.standardError.write(
                Data("usage: probe <rows.json> <dictionary-v1.json> <workdir>\n".utf8))
            exit(2)
        }
        let rowsURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let dictV1URL = URL(fileURLWithPath: CommandLine.arguments[2])
        let workDir = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)

        let rows = try JSONDecoder().decode([Row].self, from: Data(contentsOf: rowsURL))
            .sorted { ($0.created ?? 0, $0.id) < ($1.created ?? 0, $1.id) }

        // ---- mine half 1
        let half = rows.count / 2
        let mineRows = Array(rows.prefix(half))
        let replayRows = Array(rows.suffix(rows.count - half))

        let v1 = DictionaryStore(path: dictV1URL)
        // Tokens are normalized to lowercase; the mined term must be the
        // canonical dictionary spelling — the hear phrase points at the term,
        // it never re-spells it.
        var canonicalByLower: [String: String] = [:]
        for term in v1.terms() where canonicalByLower[term.lowercased()] == nil {
            canonicalByLower[term.lowercased()] = term
        }
        var seenIn: [Candidate: Set<Int>] = [:]
        var alreadyCaught = 0

        for row in mineRows {
            guard let raw = row.raw, !raw.isEmpty else { continue }
            let resolved = (row.inserted?.isEmpty == false ? row.inserted
                                                           : row.corrected) ?? ""
            guard !resolved.isEmpty else { continue }
            let a = tokens(raw)
            let b = tokens(resolved)
            guard !a.isEmpty, !b.isEmpty, a != b else { continue }
            let blocks = mismatchBlocks(oursCount: a.count, theirsCount: b.count,
                                        matched: lcs(a, b))
            for block in blocks {
                guard !block.ours.isEmpty, !block.theirs.isEmpty,
                      block.theirs.count <= 3, block.ours.count <= 4 else { continue }
                let lower = b[block.theirs].joined(separator: " ")
                let heard = a[block.ours].joined(separator: " ")
                guard let term = canonicalByLower[lower], heard != lower else { continue }
                // Already caught by the existing hear set? Count it (the
                // per-user misrecognition statistic P0-2 wants), don't re-mine.
                if v1.applyCorrections(to: heard).lowercased() == term.lowercased() {
                    alreadyCaught += 1
                    continue
                }
                seenIn[Candidate(term: term, heard: heard), default: []].insert(row.id)
            }
        }

        let promoted = seenIn.filter { $0.value.count >= 2 }
        let singletons = seenIn.filter { $0.value.count == 1 }

        // ---- build v2 through the real learn path
        let dictV2URL = workDir.appendingPathComponent("dictionary-v2.json")
        try? FileManager.default.removeItem(at: dictV2URL)
        try Data(contentsOf: dictV1URL).write(to: dictV2URL)
        let v2 = DictionaryStore(path: dictV2URL)
        for (candidate, _) in promoted {
            v2.add(LearnedTerm(term: candidate.term, heard: [candidate.heard],
                               source: "p0-1-probe"))
        }

        // ---- replay half 2
        var newCatches = 0
        var changedRows: [(Int, String, String)] = []
        for row in replayRows {
            guard let raw = row.raw, !raw.isEmpty else { continue }
            let before = v1.applyCorrections(to: raw)
            let after = v2.applyCorrections(to: raw)
            if before != after {
                newCatches += 1
                changedRows.append((row.id, before, after))
            }
        }

        // ---- report
        let per100 = replayRows.isEmpty ? 0
            : Double(newCatches) * 100.0 / Double(replayRows.count)
        print("p0-1 replay probe — hear-phrase mining, chronological split")
        print("  rows: \(rows.count) utterance_detail triples "
              + "(mine \(mineRows.count) / replay \(replayRows.count))")
        print("  dictionary v1: \(v1.terms().count) terms")
        print("  mined candidates: \(seenIn.count) distinct (term, heard) pairs "
              + "(\(singletons.count) singletons below the >=2-utterance ledger floor)")
        print("  already caught by existing hear set: \(alreadyCaught)")
        print("  promoted into v2: \(promoted.count)")
        for (candidate, ids) in promoted.sorted(by: { $0.key.term < $1.key.term }) {
            print("    '\(candidate.heard)' -> '\(candidate.term)' "
                  + "(seen in \(ids.count) utterances)")
        }
        print("  NEW CATCHES on replay half: \(newCatches) / \(replayRows.count) "
              + String(format: "= %.1f per 100 utterances", per100))
        for (id, before, after) in changedRows.prefix(10) {
            print("    row \(id): '\(before)' -> '\(after)'")
        }
        print("")
        print("kill bar (pre-registered, FINAL-PLAN G3): < a handful per 100 => the")
        print("full miner (R25) is not built. Supply caveats: utterance_detail only")
        print("exists where history is enabled, capped at 1000 rows; a small n is")
        print("an underpowered-but-honest outcome the plan accepts.")
    }
}
