import Foundation

/// Where a PROPOSED identity value can honestly come from.
///
/// PROPOSE, NEVER SEED. The result of this file only ever fills a settings
/// field's DRAFT; `IdentityStore.set` is called from exactly one place, the
/// field's own save action. Nothing here can put a value on disk, and
/// therefore nothing unconfirmed can ever reach the user's document. Three
/// reasons the silent-seed alternative lost:
///
///  1. `git config user.email` is frequently NOT the address you hand to
///     people — routinely a work address or a `…@users.noreply.github.com`
///     alias. A silent seed means the first "my email" pastes the wrong
///     address into a form and the user never learns a substitution happened.
///     This is the one class of state where a wrong value is embarrassing
///     rather than merely annoying.
///  2. The house rule is that a substitution needs EVIDENCE. A git config is
///     weak evidence of "the address you give people"; one confirmation click
///     converts weak evidence into a user decision.
///  3. It costs one click, once, ever.
///
/// THERE IS DELIBERATELY NO GITHUB SEED. Deriving a username from `origin`
/// presupposes a current repository, and Wisprit is a global dictation app
/// with no such thing at dictation time. A fork, an org clone, or a clone of
/// someone else's project all yield a confidently wrong username — the
/// derivation is unsound in general, so it must not run at all. (`~/.config/gh/
/// hosts.yml` records the account the user actually authenticated as and would
/// be sound evidence; it needs a YAML-ish parse and is not required for the
/// feature to be useful.)
public enum IdentitySeed {

    /// `[user] email = …` from the global git config, or nil.
    ///
    /// `home` is a parameter because `WispritPaths.overrideRoot` moves
    /// `~/.wisprit`, not `~` — without it every test here would read the
    /// developer's real gitconfig.
    ///
    /// No subprocess: spawning `git` from a bundled app is a PATH/sandbox/
    /// latency liability for a value we can read directly. The parse is
    /// deliberately conservative — `[user]` section, first `email =` line,
    /// trimmed and unquoted, nil on anything it does not understand. A wrong
    /// parse produces a wrong SUGGESTION, and the confirmation step is also
    /// the safety net for the parser.
    public static func gitConfigEmail(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String? {
        let candidates = [
            home.appendingPathComponent(".gitconfig"),
            home.appendingPathComponent(".config/git/config"),
        ]
        for url in candidates {
            guard let raw = try? String(contentsOf: url, encoding: .utf8),
                  let email = parse(raw) else { continue }
            return email
        }
        return nil
    }

    static func parse(_ contents: String) -> String? {
        var inUserSection = false
        for line in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            var text = line.trimmingCharacters(in: .whitespaces)
            if let hash = text.firstIndex(where: { $0 == "#" || $0 == ";" }) {
                text = String(text[text.startIndex..<hash]).trimmingCharacters(in: .whitespaces)
            }
            if text.hasPrefix("[") {
                // `[user]` only. A conditional or subsectioned header
                // (`[user "work"]`) is something we do not understand, so it
                // closes the section rather than being guessed at.
                inUserSection = text.lowercased() == "[user]"
                continue
            }
            guard inUserSection, let eq = text.firstIndex(of: "=") else { continue }
            guard text[text.startIndex..<eq].trimmingCharacters(in: .whitespaces)
                .lowercased() == "email" else { continue }
            var value = text[text.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            guard !value.isEmpty, value.contains("@") else { return nil }
            // The GitHub no-reply alias is never a hand-over address, and
            // suggesting it would train the user to click through without
            // reading.
            guard !value.lowercased().hasSuffix("users.noreply.github.com") else { return nil }
            return value
        }
        return nil
    }
}
