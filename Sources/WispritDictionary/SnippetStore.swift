import Foundation
import WispritKit
import os

/// Voice-triggered text expansion — Flow Snippets, local-only.
///
/// `~/.wisprit/snippets.json`:
/// ```json
/// {"snippets": [
///   {"trigger": "my address", "expansion": "123 Main Street"},
///   {"trigger": "sign off", "expansion": "Best,\nSharique"}
/// ]}
/// ```
///
/// Matching is case-insensitive and whole-phrase. The expansion keeps the
/// casing the user saved. An utterance that is only the trigger (optional
/// trailing period) still expands.
public final class SnippetStore: @unchecked Sendable {
    public struct Snippet: Equatable, Sendable {
        public var trigger: String
        public var expansion: String
        public init(trigger: String, expansion: String) {
            self.trigger = trigger
            self.expansion = expansion
        }
    }

    private let path: URL
    private let log = WLog.logger("snippets")
    private let lock = NSLock()
    private var snippets: [Snippet] = []
    private var compiled: [(pattern: NSRegularExpression, expansion: String)] = []
    private var mtime: Date?

    public init(path: URL = WispritPaths.snippetsPath) {
        self.path = path
        reload()
    }

    public func all() -> [Snippet] {
        lock.lock(); defer { lock.unlock() }
        return snippets
    }

    @discardableResult
    public func upsert(_ snippet: Snippet) -> Bool {
        let trigger = snippet.trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        let expansion = snippet.expansion
        guard !trigger.isEmpty, !expansion.isEmpty else { return false }
        lock.lock()
        if let idx = snippets.firstIndex(where: { $0.trigger.caseInsensitiveCompare(trigger) == .orderedSame }) {
            snippets[idx] = Snippet(trigger: trigger, expansion: expansion)
        } else {
            snippets.append(Snippet(trigger: trigger, expansion: expansion))
        }
        lock.unlock()
        return persist()
    }

    @discardableResult
    public func remove(trigger: String) -> Bool {
        lock.lock()
        snippets.removeAll { $0.trigger.caseInsensitiveCompare(trigger) == .orderedSame }
        lock.unlock()
        return persist()
    }

    /// Replace every whole-phrase trigger. Longest trigger wins so
    /// "my work address" is not eaten by "my address".
    public func expand(_ text: String) -> String {
        maybeReload()
        lock.lock()
        let rules = compiled
        lock.unlock()
        guard !rules.isEmpty, !text.isEmpty else { return text }
        var out = text
        for rule in rules {
            out = rule.pattern.stringByReplacingMatches(
                in: out, options: [],
                range: NSRange(location: 0, length: (out as NSString).length),
                withTemplate: NSRegularExpression.escapedTemplate(for: rule.expansion))
        }
        return out
    }

    /// `FileManager.attributesOfItem`, NOT `URL.resourceValues` — a `URL` value
    /// caches the resource values it has already been asked for (it holds a
    /// bridged `NSURL`), so re-reading `contentModificationDate` through the
    /// stored `path` returns the FIRST answer forever and a hand-edit to
    /// `snippets.json` never lands until relaunch. Measured while building the
    /// identity store, which hit it verbatim.
    private func fileModified() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path.path))?[.modificationDate] as? Date
    }

    public func maybeReload() {
        let mtime = fileModified()
        lock.lock()
        let known = self.mtime
        lock.unlock()
        if mtime != known { reload() }
    }

    private func reload() {
        guard let data = try? Data(contentsOf: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = json["snippets"] as? [[String: Any]] else {
            lock.lock()
            snippets = []
            compiled = []
            mtime = fileModified()
            lock.unlock()
            return
        }
        var loaded: [Snippet] = []
        for row in rows {
            guard let trigger = row["trigger"] as? String, !trigger.isEmpty,
                  let expansion = row["expansion"] as? String, !expansion.isEmpty else { continue }
            loaded.append(Snippet(trigger: trigger, expansion: expansion))
        }
        lock.lock()
        snippets = loaded
        compiled = compile(loaded)
        mtime = fileModified()
        lock.unlock()
    }

    private func compile(_ items: [Snippet]) -> [(pattern: NSRegularExpression, expansion: String)] {
        items
            .sorted { $0.trigger.count > $1.trigger.count }
            .compactMap { item in
                let escaped = NSRegularExpression.escapedPattern(for: item.trigger)
                    .replacingOccurrences(of: "\\ ", with: #"\s+"#)
                let pattern = #"(?<![\w])"# + escaped + #"(?![\w])"#
                guard let rx = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                    return nil
                }
                return (rx, item.expansion)
            }
    }

    private func persist() -> Bool {
        lock.lock()
        let rows = snippets.map { ["trigger": $0.trigger, "expansion": $0.expansion] }
        lock.unlock()
        do {
            try WispritPaths.ensureStateDir()
            let data = try JSONSerialization.data(
                withJSONObject: ["snippets": rows], options: [.prettyPrinted, .sortedKeys])
            try data.write(to: path, options: .atomic)
            reload()
            return true
        } catch {
            log.error("snippet persist failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
