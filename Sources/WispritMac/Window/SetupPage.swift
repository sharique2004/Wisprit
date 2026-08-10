#if os(macOS)
import SwiftUI
import WispritMacUI

/// Setup — `docs/design/ui-redesign.md` §3.7.
///
/// The page that answers the only question a confused user has: *is this thing
/// working, and if not, what do I press?* It adds no probing of its own —
/// every row, mark, remedy and button comes from `SetupChecklist.items(from:)`
/// over the `DoctorFacts` the model already holds, which is what keeps
/// `wisprit doctor` and this window incapable of disagreeing.
///
/// Two things it does that the old Status page did not: it renders
/// `item.secondaryFix` (the "Quit & Reopen Wisprit" that makes an Input
/// Monitoring grant take effect — previously unreachable from any surface), and
/// it gives the 🌐 key a row of its own, because `GlobeKeyUsage` is a real
/// signal the doctor has no check for.
struct SetupPage: View {
    @ObservedObject var model: WispritWindowModel

    @State private var copied = false

    var body: some View {
        HubPage(title: WispritWindowModel.Tab.setup.title) {
            HStack(spacing: Theme.Space.s8) {
                Button(copied ? "Copied" : "Copy diagnostics") { copyDiagnostics() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button {
                    Task { await model.refreshFull() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Check again now")
                .accessibilityLabel("Check again")
            }
        } content: {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let notice = model.secureInputNotice {
                        secureInputBanner(notice)
                    }
                    hero
                    rows
                    manualChecks
                    footer
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // The checklist is empty while the first probe runs and then gains
            // eight rows at once; without an anchor the scroll view holds its
            // old offset, which is how the page came up already past Microphone.
            .defaultScrollAnchor(.top)
        }
    }

    // MARK: - banner

    /// Above the hero, because while Secure Keyboard Entry is held the hero's
    /// "Ready" is true and useless: macOS is not delivering the key to anyone.
    /// Transient, so it is a banner the 2-second probe brings and takes away —
    /// never a row the user could "fix".
    private func secureInputBanner(_ notice: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.s12) {
            Image(systemName: "lock.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.attention)
            Text(notice)
                .font(Theme.font(Theme.Role.body))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(Theme.Space.s12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                .fill(Theme.groundRecessed)
        )
        .padding(.bottom, Theme.Space.s16)
    }

    // MARK: - hero

    private var hero: some View {
        HStack(alignment: .top, spacing: Theme.Space.s16) {
            Image(systemName: heroSymbol)
                .font(.system(size: 34, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(heroTint)
                .frame(width: Theme.Space.s40, alignment: .center)
            VStack(alignment: .leading, spacing: Theme.Space.s4) {
                Text(model.summary.headline)
                    .font(Theme.font(Theme.Role.pageTitle))
                    .tracking(Theme.Role.pageTitle.tracking)
                    .foregroundStyle(Theme.ink)
                Text(model.summary.subhead)
                    .font(Theme.font(Theme.Role.body))
                    .foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, Theme.Space.s20)
    }

    private var heroSymbol: String {
        switch model.summary.hero {
        case .checking: return "ellipsis.circle"
        case .ready: return "checkmark.seal"
        case .needsSetup: return "exclamationmark.triangle"
        }
    }

    private var heroTint: Color {
        switch model.summary.hero {
        case .checking: return Theme.inkTertiary
        case .ready: return Theme.positive
        case .needsSetup: return Theme.critical
        }
    }

    // MARK: - rows

    private var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(model.items) { item in
                SetupRow(item: item) { model.fix($0) }
            }
        }
    }

    /// The things no probe can answer (§3.7).
    ///
    /// The 🌐 key gets a row of its own rather than a line of prose: `Doctor`
    /// has no Fn check at all, `GlobeKeyUsage` reads the real HIToolbox
    /// preference, and a key that opens the emoji picker is indistinguishable
    /// from Wisprit being broken. Under it, the doctor's own reminders — the
    /// external-keyboard caveat and friends — as plain caption rows.
    ///
    /// Shown when the 🌐 key is taken, or whenever it is the configured hotkey.
    @ViewBuilder
    private var manualChecks: some View {
        if !model.globeKey.isClear || model.hotkey == .fn {
            VStack(alignment: .leading, spacing: 0) {
                Text("Can't be auto-checked")
                    .font(Theme.font(Theme.Role.captionEmph))
                    .tracking(Theme.Role.captionEmph.tracking)
                    .foregroundStyle(Theme.inkTertiary)
                    .padding(.top, Theme.Space.s20)
                    .padding(.bottom, Theme.Space.s8)
                SetupRowShell(mark: model.globeKey.isClear ? .ok : .warn,
                              isOff: false,
                              symbol: "keyboard",
                              title: "The 🌐 key",
                              summary: model.globeKey.advice,
                              detail: model.globeKey.isClear ? ""
                                  : "System Settings ▸ Keyboard ▸ “Press 🌐 key to” → Do Nothing",
                              note: nil,
                              primary: model.globeKey.isClear
                                  ? nil
                                  : (SetupFixKind.openKeyboardSettings, "Open Keyboard Settings"),
                              secondary: nil) { model.fix($0) }
                ForEach(reminders, id: \.self) { reminder in
                    Text(reminder)
                        .font(Theme.font(Theme.Role.caption))
                        .tracking(Theme.Role.caption.tracking)
                        .foregroundStyle(Theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, Theme.Space.s8)
                }
            }
        }
    }

    /// `Doctor.report(from:)` is a pure builder over facts the model already
    /// holds — no probing, no I/O.
    private var reminders: [String] {
        guard model.hasProbed else { return [] }
        return Doctor.report(from: model.facts).reminders
    }

    // MARK: - footer

    private var footer: some View {
        HStack(alignment: .center, spacing: Theme.Space.s12) {
            Text(checkedLine)
                .font(Theme.font(Theme.Role.caption))
                .tracking(Theme.Role.caption.tracking)
                .foregroundStyle(Theme.inkTertiary)
            Spacer(minLength: Theme.Space.s16)
            Button("Run the setup guide") { model.beginOnboarding(resuming: false) }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.top, Theme.Space.s20)
    }

    private var checkedLine: String {
        guard let at = model.lastProbeAt else { return "Checking…" }
        return "Checked \(RelativeTime.string(from: at.timeIntervalSince1970))."
    }

    private func copyDiagnostics() {
        model.copy(Doctor.report(from: model.facts).rendered())
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            copied = false
        }
    }
}

// MARK: - one checklist row

/// A `SetupItem`, drawn. Split from the page so the 🌐 row — which has no
/// `SetupItem` behind it — gets the identical treatment.
private struct SetupRow: View {
    let item: SetupItem
    let fix: (SetupFixKind) -> Void

    var body: some View {
        SetupRowShell(mark: item.mark,
                      isOff: item.isOff,
                      symbol: nil,
                      title: item.title,
                      summary: item.summary,
                      detail: item.detail,
                      note: item.note,
                      primary: item.fix == .none ? nil : (item.fix, item.fixTitle),
                      secondary: item.secondaryFix == .none
                          ? nil : (item.secondaryFix, item.secondaryFixTitle),
                      fix: fix)
    }
}

private struct SetupRowShell: View {
    let mark: DoctorMark
    let isOff: Bool
    /// Overrides the doctor glyph — only the 🌐 row uses it.
    let symbol: String?
    let title: String
    let summary: String
    let detail: String
    let note: String?
    let primary: (SetupFixKind, String)?
    let secondary: (SetupFixKind, String)?
    let fix: (SetupFixKind) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.s12) {
            DoctorGlyph(mark: mark, isOff: isOff, symbol: symbol)
                .padding(.top, Theme.Space.s2)
            VStack(alignment: .leading, spacing: Theme.Space.s4) {
                Text(title)
                    .font(Theme.font(Theme.Role.rowTitle))
                    .foregroundStyle(Theme.ink)
                if !summary.isEmpty {
                    Text(summary)
                        .font(Theme.font(Theme.Role.body))
                        .foregroundStyle(Theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !detail.isEmpty {
                    Text(detail)
                        .font(Theme.font(Theme.Role.caption))
                        .tracking(Theme.Role.caption.tracking)
                        .foregroundStyle(Theme.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let note {
                    // Not orange (§1.6): a note explains macOS behaviour, it does
                    // not warn about it.
                    Label(note, systemImage: "info.circle")
                        .font(Theme.font(Theme.Role.caption))
                        .foregroundStyle(Theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if primary != nil || secondary != nil {
                    HStack(spacing: Theme.Space.s8) {
                        if let primary {
                            Button(primary.1) { fix(primary.0) }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                        }
                        // The row that carries this is `input_monitoring` (and
                        // `post_event`), whose secondary is the relaunch that
                        // makes the grant take effect. It was never rendered
                        // anywhere before, and it is the difference between a
                        // granted permission and a working one.
                        if let secondary {
                            Button(secondary.1) { fix(secondary.0) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                    }
                    .padding(.top, Theme.Space.s2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Theme.Space.s12)
        .frame(minHeight: Theme.Size.rowHeightWithDescription, alignment: .top)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.hairline).frame(height: 1)
        }
    }
}

/// The checklist's status glyph — the restyled `StatusDot` (§3.7).
///
/// Colour AND symbol, so the state survives a colour-blind reader and a
/// greyscale screenshot. `warn` is the **outlined** variant on purpose (§1.8):
/// a filled amber circle would read as a second alarm next to `bad`, and it
/// would put ochre on a fill wider than a glyph (§1.6).
struct DoctorGlyph: View {
    let mark: DoctorMark
    var isOff: Bool = false
    var symbol: String?

    var body: some View {
        Image(systemName: symbol ?? defaultSymbol)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(tint)
            .accessibilityLabel(label)
    }

    private var defaultSymbol: String {
        if isOff { return "minus.circle" }
        switch mark {
        case .ok: return "checkmark.circle.fill"
        case .warn: return "exclamationmark.circle"
        case .bad: return "xmark.circle.fill"
        }
    }

    private var tint: Color {
        if isOff { return Theme.inkTertiary }
        switch mark {
        case .ok: return Theme.positive
        case .warn: return Theme.attention
        case .bad: return Theme.critical
        }
    }

    private var label: String {
        if isOff { return "off" }
        switch mark {
        case .ok: return "ready"
        case .warn: return "needs attention"
        case .bad: return "missing"
        }
    }
}
#endif
