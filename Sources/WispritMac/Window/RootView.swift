#if os(macOS)
import SwiftUI

// The old window is gone (`docs/design/ui-redesign.md` §6.7 step 12). The shell
// moved to `HubShell.swift`, the pages to `SetupPage` / `HomePage` /
// `DictionaryPage` / `InsightsPage` / `SettingsPage`, and the plain-SwiftUI
// furniture they used to share — `StatusDot`, `PageHeader`, `Card`,
// `TranscriptRow` — went with `HistoryView` and `DictionaryView`, all of which
// drew with literal colours §1 retires.
//
// One helper outlives them, because it is copy rather than chrome and both
// `SetupPage` and `DictionaryPage` still want it.

/// Timestamps in the window are relative ("2 minutes ago") — an absolute clock
/// time tells the user nothing about whether *this* was the dictation they just
/// tried.
enum RelativeTime {
    static func string(from unix: Double, now: Date = Date()) -> String {
        let date = Date(timeIntervalSince1970: unix)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
#endif
