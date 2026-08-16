import Foundation

/// The four identity values a user can say by name ("my email", "my GitHub").
///
/// A cross-module seam, and it has to be: `WispritDictionary` owns the STORE
/// (`IdentityStore`, `~/.wisprit/identity.json`) while `WispritPostProcess`
/// owns the GATE (`IdentityExpansion`, which decides when a phrase is a
/// hand-over rather than a reference). Neither target may depend on the other
/// — `Package.swift` couples them only through WispritKit — so the type they
/// both name lives here, exactly like `CorrectionApplying` in Contracts.swift.
///
/// `rawValue` is the on-disk JSON key and is stable: the user can never rename
/// it, unlike a snippet whose identity IS its trigger string.
public enum IdentitySlot: String, CaseIterable, Sendable {
    case email, linkedin, github, website
}

/// A snapshot of the configured identity, injected into the gate so the gate
/// is a pure function with no filesystem in its tests.
///
/// THE INERT-SLOT INVARIANT LIVES HERE, not in the matcher: `value(_:)` is the
/// only reader, and it returns nil for an absent, empty or whitespace-only
/// slot. That is the single mechanism guaranteeing an unset identity can never
/// expand, never emit a placeholder, and never emit an empty string into the
/// user's document — the matcher can only ever ask and get nothing back.
public struct IdentityValues: Sendable, Equatable {
    public var values: [IdentitySlot: String]

    public init(_ values: [IdentitySlot: String] = [:]) {
        self.values = values
    }

    /// The value to type, or nil when the slot is INERT.
    public func value(_ slot: IdentitySlot) -> String? {
        guard let raw = values[slot] else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// No slot has a value — the gate short-circuits to the identity function,
    /// so a default install with no identity.json is a measured no-op.
    public var isEmpty: Bool {
        IdentitySlot.allCases.allSatisfy { value($0) == nil }
    }
}
