import Foundation
import WispritKit
import os

/// The four identity values, in `~/.wisprit/identity.json`.
///
/// ```json
/// {"version": 1, "identity": {"email": "you@example.com",
///                             "github": "https://github.com/you"}}
/// ```
///
/// WHY ITS OWN FILE AND NOT A SNIPPET KIND. Three facts about `SnippetStore`,
/// each load-bearing:
///  1. `reload()` DROPS any row whose expansion is empty. Identity needs four
///     NAMED fields the UI keeps rendering with zero, one or four of them
///     filled; the snippet file physically cannot store the empty ones.
///  2. `persist()` rebuilds every row as exactly {trigger, expansion}. A
///     `{"kind": "identity"}` marker would be destroyed the first time the
///     user edited an unrelated snippet.
///  3. A snippet's identity IS its user-editable trigger string. `email` /
///     `linkedin` / `github` / `website` must survive a phrasing change.
///
/// AN ABSENT KEY AND AN EMPTY STRING MEAN THE SAME THING: no value. `persist`
/// omits empty values entirely, so the file cannot even express the difference,
/// and `value(_:)` is the only reader.
///
/// THE STORE DOES NOT NORMALIZE ON LOAD. A value hand-edited into identity.json
/// is used exactly as written — that is the WYSIWYG contract with the UI field,
/// and it is why a "helpfully fix it up on read" convenience must not be added.
///
/// Concurrency shape copied from `SnippetStore`: read on the session worker
/// thread every utterance, written on the main thread from the UI, so
/// `values()` must `maybeReload()` or a UI edit would not take effect until
/// relaunch.
public final class IdentityStore: @unchecked Sendable {
    public let path: URL
    private let log = WLog.logger("identity")
    private let lock = NSLock()
    private var stored: [IdentitySlot: String] = [:]
    private var mtime: Date?

    public init(path: URL = WispritPaths.identityPath) {
        self.path = path
        reload()
    }

    /// nil when the slot is unset OR stored blank. There is no other reader.
    public func value(_ slot: IdentitySlot) -> String? {
        values().value(slot)
    }

    /// The snapshot handed to the (pure) expansion gate.
    public func values() -> IdentityValues {
        maybeReload()
        lock.lock(); defer { lock.unlock() }
        return IdentityValues(stored)
    }

    /// `""` (or whitespace only) CLEARS the slot and removes the key.
    @discardableResult
    public func set(_ slot: IdentitySlot, to value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.lock()
        if trimmed.isEmpty { stored.removeValue(forKey: slot) } else { stored[slot] = trimmed }
        lock.unlock()
        return persist()
    }

    /// `FileManager.attributesOfItem`, NOT `URL.resourceValues`.
    ///
    /// MEASURED: a `URL` value caches the resource values it has already been
    /// asked for (it holds a bridged `NSURL`), so a `let path: URL` read twice
    /// hands back the FIRST modification date forever. The mtime check then
    /// says "unchanged" and an edit made underneath a live store — the UI
    /// writing while the session thread reads — never lands until relaunch.
    /// `IdentityStoreTests.testMtimeReloadPicksUpAnExternalEdit` fails against
    /// the `resourceValues` form.
    private func diskMtime() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path.path))?[.modificationDate] as? Date
    }

    public func maybeReload() {
        let disk = diskMtime()
        lock.lock()
        let known = self.mtime
        lock.unlock()
        if disk != known { reload() }
    }

    private func reload() {
        var loaded: [IdentitySlot: String] = [:]
        if let data = try? Data(contentsOf: path),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let rows = json["identity"] as? [String: Any] {
            // Unknown keys inside `identity` are ignored, not fatal — forward
            // compatibility with a newer build that adds a fifth slot.
            for slot in IdentitySlot.allCases {
                guard let raw = rows[slot.rawValue] as? String else { continue }
                guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                loaded[slot] = raw
            }
        }
        lock.lock()
        stored = loaded
        mtime = diskMtime()
        lock.unlock()
    }

    private func persist() -> Bool {
        lock.lock()
        var rows: [String: String] = [:]
        for (slot, value) in stored where !value.isEmpty { rows[slot.rawValue] = value }
        lock.unlock()
        do {
            try WispritPaths.ensureStateDir()
            let data = try JSONSerialization.data(
                withJSONObject: ["version": 1, "identity": rows],
                options: [.prettyPrinted, .sortedKeys])
            try data.write(to: path, options: .atomic)
            reload()
            return true
        } catch {
            log.error("identity persist failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}

/// Input normalization and validation for the identity fields.
///
/// THE STORED STRING IS THE TYPED STRING. There is no hidden transform between
/// what the settings field shows and what lands in the user's document —
/// normalization is a UI-input convenience applied ONCE, on commit, and the
/// normalized result is written back into the field so the user sees exactly
/// what will be typed and can edit it freely.
///
/// WHY FULL `https://` FOR THE THREE URL FIELDS AND A BARE ADDRESS FOR EMAIL.
/// The value's whole job is to become a link. `https://…` autolinks
/// deterministically in Slack, Gmail, Notion, Linear, iMessage and every
/// `<input type="url">`; a bare host autolinks inconsistently and is REJECTED
/// by url-typed validators. Eight characters remove a whole class of "it
/// didn't turn into a link". Email is the opposite case: `mailto:` is the
/// thing that breaks paste targets, so the address stays bare.
public enum IdentityValue {

    /// Blank input is returned unchanged — the caller's clear path must not be
    /// able to manufacture a stub like `https://github.com/`.
    public static func normalize(_ raw: String, for slot: IdentitySlot) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        switch slot {
        case .email:
            // Case is NEVER folded: the local part is case-sensitive per RFC 5321.
            return stripPrefix(trimmed, "mailto:")
        case .github:
            var body = stripScheme(trimmed)
            body = stripPrefix(body, "www.")
            body = stripPrefix(body, "github.com/")
            body = stripPrefix(body, "@")
            body = body.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            // Refuse rather than fabricate: an empty username comes back as
            // whatever the user typed, so `validate` can reject it.
            guard !body.isEmpty else { return trimmed }
            return "https://github.com/" + body
        case .linkedin:
            var body = stripScheme(trimmed)
            body = stripPrefix(body, "www.")
            body = stripPrefix(body, "linkedin.com/")
            body = body.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !body.isEmpty else { return trimmed }
            // A path that is not /in/… (a /company/… page, say) is preserved
            // as given rather than forced into /in/.
            if body.contains("/") { return "https://www.linkedin.com/" + body }
            // "in/" on its own is the PREFIX, not a slug. Fabricating
            // `…/in/in` from it is exactly the stub this refusal exists for.
            guard body.lowercased() != "in" else { return trimmed }
            return "https://www.linkedin.com/in/" + body
        case .website:
            guard !hasScheme(trimmed) else { return trimmed }   // http:// survives
            return "https://" + trimmed
        }
    }

    /// nil == acceptable. A rejected value is NOT stored, so a bad value
    /// degrades to no value — never to a broken value that could be typed.
    public static func validate(_ value: String, for slot: IdentitySlot) -> String? {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else { return nil }   // blank is a clear, not a rejection
        switch slot {
        case .email:
            let parts = v.split(separator: "@", omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty, parts[1].contains("."),
                  !parts[1].hasPrefix("."), !parts[1].hasSuffix("."),
                  !v.contains(" ") else {
                return "Needs an @ and a domain — like you@example.com."
            }
            return nil
        case .github:
            guard let url = URL(string: v), url.scheme != nil, url.host == "github.com" else {
                return "Needs a GitHub username — like your-name."
            }
            let segments = url.path.split(separator: "/")
            guard segments.count == 1 else { return "Needs a GitHub username — like your-name." }
            return nil
        case .linkedin:
            guard let url = URL(string: v), url.scheme != nil,
                  let host = url.host, host == "linkedin.com" || host.hasSuffix(".linkedin.com"),
                  !url.path.split(separator: "/").isEmpty else {
                return "Needs a LinkedIn profile — like linkedin.com/in/your-name."
            }
            return nil
        case .website:
            guard let url = URL(string: v), url.scheme != nil,
                  let host = url.host, host.contains("."), !host.hasPrefix("."),
                  !host.hasSuffix(".") else {
                return "Needs a site address — like yoursite.com."
            }
            return nil
        }
    }

    // MARK: - helpers

    private static func hasScheme(_ s: String) -> Bool {
        s.range(of: #"\A[A-Za-z][A-Za-z0-9+.\-]*://"#, options: .regularExpression) != nil
    }

    private static func stripScheme(_ s: String) -> String {
        guard let r = s.range(of: #"\A[A-Za-z][A-Za-z0-9+.\-]*://"#, options: .regularExpression)
        else { return s }
        return String(s[r.upperBound...])
    }

    private static func stripPrefix(_ s: String, _ prefix: String) -> String {
        guard s.lowercased().hasPrefix(prefix.lowercased()) else { return s }
        return String(s.dropFirst(prefix.count))
    }
}
