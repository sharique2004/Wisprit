#if os(macOS)
import SwiftUI
import WispritMacUI

/// Setup — the health sheet behind the toolbar's status capsule.
///
/// It answers the only question a confused user has: *is this thing working,
/// and if not, what do I press?* It adds no probing of its own — every row,
/// mark, remedy and button comes from `SetupChecklist.items(from:)` over the
/// `DoctorFacts` the model already holds, which is what keeps `wisprit doctor`
/// and this window incapable of disagreeing.
///
/// Shape, from `SetupChecklist.sheet(...)`:
///
///  * **Healthy** — one calm line ("All set — hold 🌐 to dictate") over a
///    compact list: a glyph, a name and a status word per row. A row opens on
///    click to say what it is for.
///  * **Something outstanding** — the essential rows that are not green open
///    expanded at the top, their one Fix button first; secondary fixes (the
///    "Quit & Reopen Wisprit" that makes an Input Monitoring grant take
///    effect) sit with them.
///  * **Developer lines** (`CGPreflightPostEventAccess: …`,
///    `AssetInventory.status: …`) live behind a per-row "Technical details"
///    disclosure or the sheet-wide "Show technical details" switch. They are
///    still in Copy diagnostics, verbatim.
struct SetupPage: View {
    @ObservedObject var model: WispritWindowModel
    /// Closes the sheet. Setup is the health SHEET now (raised by the
    /// toolbar's status capsule), not a sidebar page.
    var onDone: () -> Void = {}

    @State private var copied = false
    /// The developer lines, for every row at once. Off: they are for bug
    /// reports, and Copy diagnostics carries them regardless.
    @State private var showsTechnical = false
    /// Compact rows the user has opened.
    @State private var expanded: Set<String> = []

    private var sheet: SetupSheet {
        SetupChecklist.sheet(items: model.items,
                             summary: model.summary,
                             hotkeyLabel: SetupChecklist.hotkeyLabel(model.hotkey.rawValue),
                             dictationEnabled: model.dictationEnabled)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.s20) {
                    if let notice = model.secureInputNotice {
                        secureInputBanner(notice)
                    }
                    content(sheet)
                    footer
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.Space.s24)
                .padding(.top, Theme.Space.s20)
                .padding(.bottom, Theme.Space.s24)
            }
            // The checklist is empty while the first probe runs and then gains
            // eight rows at once; without an anchor the scroll view holds its
            // old offset, which is how the page came up already past Microphone.
            .defaultScrollAnchor(.top)
        }
        .frame(minWidth: 620, idealWidth: 680, minHeight: 520, idealHeight: 680)
        .background(Theme.surface)
    }

    // MARK: - header

    private var header: some View {
        HStack(alignment: .center, spacing: Theme.Space.s8) {
            Text(WispritWindowModel.Tab.setup.title)
                .font(Theme.font(Theme.Role.pageTitle))
                .tracking(Theme.Role.pageTitle.tracking)
                .foregroundStyle(Theme.ink)
            Spacer(minLength: Theme.Space.s16)
            Button(copied ? "Copied" : "Copy diagnostics") { copyDiagnostics() }
                .controlSize(.small)
                .help("Copies the full technical report, for a bug report")
            Button {
                Task { await model.refreshFull() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .controlSize(.small)
            .help("Check again now")
            .accessibilityLabel("Check again")
            Button("Done", action: onDone)
                .keyboardShortcut(.defaultAction)
                .controlSize(.small)
        }
        .padding(.horizontal, Theme.Space.s24)
        .padding(.vertical, Theme.Space.s16)
    }

    // MARK: - content

    @ViewBuilder
    private func content(_ sheet: SetupSheet) -> some View {
        hero(sheet)
        if !sheet.attention.isEmpty || globeNeedsAttention {
            VStack(alignment: .leading, spacing: Theme.Space.s12) {
                ForEach(sheet.attention) { item in
                    AttentionCard(row: SetupRowContent(item), showsTechnical: showsTechnical,
                                  fix: model.fix)
                }
                if globeNeedsAttention {
                    AttentionCard(row: globeRow, showsTechnical: showsTechnical, fix: model.fix)
                }
            }
        }
        if !compactRows(sheet).isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.s8) {
                groupTitle(sheet.attention.isEmpty ? "Checks" : "Everything else")
                CompactList(rows: compactRows(sheet), expanded: $expanded,
                            showsTechnical: showsTechnical, fix: model.fix)
            }
        }
        if !sheet.optional.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.s8) {
                groupTitle("Optional extras")
                VStack(alignment: .leading, spacing: Theme.Space.s12) {
                    ForEach(sheet.optional) { item in
                        AttentionCard(row: SetupRowContent(item), showsTechnical: showsTechnical,
                                      fix: model.fix, isOptional: true)
                    }
                }
            }
        }
        goodToKnow
    }

    private func compactRows(_ sheet: SetupSheet) -> [SetupRowContent] {
        var rows = sheet.healthy.map(SetupRowContent.init)
        if showsGlobeRow && !globeNeedsAttention { rows.append(globeRow) }
        return rows
    }

    private func groupTitle(_ text: String) -> some View {
        Text(text)
            .font(Theme.font(Theme.Role.captionEmph))
            .tracking(Theme.Role.captionEmph.tracking)
            .textCase(.uppercase)
            .foregroundStyle(Theme.inkTertiary)
    }

    // MARK: - hero

    private func hero(_ sheet: SetupSheet) -> some View {
        HStack(alignment: .center, spacing: Theme.Space.s16) {
            Group {
                if case .checking = sheet.hero {
                    ProgressView().controlSize(.regular)
                } else {
                    Image(systemName: heroSymbol(sheet))
                        .font(.system(size: 30, weight: .regular))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(heroTint(sheet))
                }
            }
            .frame(width: Theme.Space.s40, height: Theme.Space.s40)
            VStack(alignment: .leading, spacing: Theme.Space.s4) {
                Text(sheet.headline)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Text(sheet.subhead)
                    .font(Theme.font(Theme.Role.body))
                    .foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Space.s16)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.group, style: .continuous)
                .fill(Theme.groundRecessed.opacity(0.7)))
        .accessibilityElement(children: .combine)
    }

    private func heroSymbol(_ sheet: SetupSheet) -> String {
        switch sheet.hero {
        case .checking: return "ellipsis.circle"
        case .needsSetup: return "exclamationmark.triangle.fill"
        case .ready: return sheet.isCalm ? "checkmark.circle.fill" : "exclamationmark.circle"
        }
    }

    private func heroTint(_ sheet: SetupSheet) -> Color {
        switch sheet.hero {
        case .checking: return Theme.inkTertiary
        case .needsSetup: return Theme.critical
        case .ready:
            if !model.dictationEnabled { return Theme.inkTertiary }
            return sheet.isCalm ? Theme.positive : Theme.attention
        }
    }

    // MARK: - the 🌐 key

    /// The 🌐 key gets a row of its own: `Doctor` has no Fn check at all,
    /// `GlobeKeyUsage` reads the real HIToolbox preference, and a key that
    /// opens the emoji picker is indistinguishable from Wisprit being broken.
    /// Shown when the key is taken, or whenever it is the configured hotkey.
    private var showsGlobeRow: Bool { !model.globeKey.isClear || model.hotkey == .fn }
    private var globeNeedsAttention: Bool { model.hasProbed && !model.globeKey.isClear }

    private var globeRow: SetupRowContent {
        let clear = model.globeKey.isClear
        return SetupRowContent(
            id: "globe_key",
            mark: clear ? .ok : .warn,
            isOff: false,
            symbol: "globe",
            title: "The 🌐 key",
            status: clear ? "Free for Wisprit" : "Taken",
            summary: model.globeKey.advice,
            note: clear ? nil
                : "System Settings ▸ Keyboard ▸ “Press 🌐 key to” → Do Nothing",
            detail: "",
            primary: clear ? nil : (.openKeyboardSettings, "Open Keyboard Settings"),
            secondary: nil)
    }

    // MARK: - good to know

    /// Plain reminders no probe can check. The doctor's own wording (which
    /// names `config.json`) stays in Copy diagnostics and behind the
    /// technical switch.
    @ViewBuilder
    private var goodToKnow: some View {
        let reminders = showsTechnical && model.hasProbed ? Doctor.report(from: model.facts).reminders : []
        if model.hotkey == .fn || !reminders.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.s8) {
                groupTitle("Good to know")
                if model.hotkey == .fn {
                    Label(SetupChecklist.externalKeyboardTip, systemImage: "keyboard")
                        .font(Theme.font(Theme.Role.body))
                        .foregroundStyle(Theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(reminders, id: \.self) { reminder in
                    TechnicalLine(text: reminder.replacingOccurrences(of: "\n       ", with: " "))
                }
            }
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
    }

    // MARK: - footer

    private var footer: some View {
        HStack(alignment: .center, spacing: Theme.Space.s16) {
            Text(checkedLine)
                .font(Theme.font(Theme.Role.caption))
                .tracking(Theme.Role.caption.tracking)
                .foregroundStyle(Theme.inkTertiary)
            Spacer(minLength: Theme.Space.s16)
            Toggle("Show technical details", isOn: $showsTechnical.animation(.snappy(duration: 0.2)))
                .toggleStyle(.checkbox)
                .controlSize(.small)
            Button("Run the setup guide") { model.beginOnboarding(resuming: false) }
                .controlSize(.small)
        }
        .padding(.top, Theme.Space.s4)
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

// MARK: - one row's content

/// A `SetupItem`, or the 🌐 row that has none behind it, as the sheet draws it.
private struct SetupRowContent: Identifiable {
    var id: String
    var mark: DoctorMark
    var isOff: Bool
    /// Overrides the doctor glyph — only the 🌐 row uses it.
    var symbol: String?
    var title: String
    var status: String
    var summary: String
    var note: String?
    /// The doctor's developer line. Never shown by default.
    var detail: String
    var primary: (SetupFixKind, String)?
    var secondary: (SetupFixKind, String)?

    init(id: String, mark: DoctorMark, isOff: Bool, symbol: String?, title: String,
         status: String, summary: String, note: String?, detail: String,
         primary: (SetupFixKind, String)?, secondary: (SetupFixKind, String)?) {
        self.id = id
        self.mark = mark
        self.isOff = isOff
        self.symbol = symbol
        self.title = title
        self.status = status
        self.summary = summary
        self.note = note
        self.detail = detail
        self.primary = primary
        self.secondary = secondary
    }

    init(_ item: SetupItem) {
        self.init(id: item.id,
                  mark: item.mark,
                  isOff: item.isOff,
                  symbol: nil,
                  title: item.title,
                  status: SetupChecklist.status(of: item),
                  summary: item.summary,
                  note: item.note,
                  detail: item.detail,
                  primary: item.fix == .none ? nil : (item.fix, item.fixTitle),
                  // The row that carries this is `input_monitoring` (and
                  // `post_event`), whose secondary is the relaunch that makes
                  // the grant take effect — the difference between a granted
                  // permission and a working one.
                  secondary: item.secondaryFix == .none ? nil : (item.secondaryFix, item.secondaryFixTitle))
    }
}

// MARK: - an expanded row

/// A row that needs something: title and its one Fix button on the first line,
/// then why it matters, the macOS nuance, the secondary fix, and the developer
/// line behind a disclosure.
private struct AttentionCard: View {
    let row: SetupRowContent
    let showsTechnical: Bool
    let fix: (SetupFixKind) -> Void
    var isOptional = false

    @State private var showsDetail = false

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.s12) {
            DoctorGlyph(mark: row.mark, isOff: row.isOff, symbol: row.symbol)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: Theme.Space.s8) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.title)
                            .font(Theme.font(Theme.Role.rowTitle))
                            .foregroundStyle(Theme.ink)
                        Text(row.status)
                            .font(Theme.font(Theme.Role.caption))
                            .foregroundStyle(Theme.inkSecondary)
                    }
                    Spacer(minLength: Theme.Space.s8)
                    if let primary = row.primary {
                        Button(primary.1) { fix(primary.0) }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.regular)
                    }
                }
                if !row.summary.isEmpty {
                    Text(row.summary)
                        .font(Theme.font(Theme.Role.body))
                        .foregroundStyle(Theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let note = row.note {
                    // Not orange (§1.6): a note explains macOS behaviour, it
                    // does not warn about it.
                    Label(note, systemImage: "info.circle")
                        .font(Theme.font(Theme.Role.body))
                        .foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let secondary = row.secondary {
                    Button(secondary.1) { fix(secondary.0) }
                        .controlSize(.regular)
                }
                if !row.detail.isEmpty {
                    if showsTechnical || showsDetail {
                        TechnicalLine(text: row.detail)
                    } else {
                        DetailToggle(isOn: $showsDetail)
                    }
                }
            }
        }
        .padding(Theme.Space.s16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.group, style: .continuous)
                .fill(Theme.surfaceRaised))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.group, style: .continuous)
                .strokeBorder(isOptional ? Theme.hairline : Theme.hairlineStrong, lineWidth: 1))
    }
}

// MARK: - the compact list

/// One line per healthy row — glyph, name, status word — in one grouped
/// box. A click opens a row in place.
private struct CompactList: View {
    let rows: [SetupRowContent]
    @Binding var expanded: Set<String>
    let showsTechnical: Bool
    let fix: (SetupFixKind) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 {
                    Rectangle().fill(Theme.hairline).frame(height: 1)
                        .padding(.leading, 44)
                }
                CompactRow(row: row,
                           isExpanded: expanded.contains(row.id),
                           showsTechnical: showsTechnical,
                           toggle: { toggle(row.id) },
                           fix: fix)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.group, style: .continuous)
                .fill(Theme.surfaceRaised))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.group, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1))
    }

    private func toggle(_ id: String) {
        withAnimation(.snappy(duration: 0.2)) {
            if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        }
    }
}

private struct CompactRow: View {
    let row: SetupRowContent
    let isExpanded: Bool
    let showsTechnical: Bool
    let toggle: () -> Void
    let fix: (SetupFixKind) -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: Theme.Space.s12) {
                    DoctorGlyph(mark: row.mark, isOff: row.isOff, symbol: row.symbol)
                        .frame(width: 20)
                    Text(row.title)
                        .font(Theme.font(Theme.Role.rowTitle))
                        .foregroundStyle(Theme.ink)
                    Spacer(minLength: Theme.Space.s8)
                    Text(row.status)
                        .font(Theme.font(Theme.Role.body))
                        .foregroundStyle(Theme.inkSecondary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.inkTertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.horizontal, Theme.Space.s12)
                .frame(minHeight: 36)
                .contentShape(Rectangle())
                .background(isHovering ? Theme.fillHover.opacity(0.6) : .clear)
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .accessibilityLabel("\(row.title), \(row.status)")
            .accessibilityHint(isExpanded ? "Hides the explanation" : "Shows what this is for")

            if showsTechnical && !isExpanded && !row.detail.isEmpty {
                TechnicalLine(text: row.detail)
                    .padding(.leading, 44)
                    .padding(.trailing, Theme.Space.s12)
                    .padding(.bottom, Theme.Space.s8)
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: Theme.Space.s8) {
                    if !row.summary.isEmpty {
                        Text(row.summary)
                            .font(Theme.font(Theme.Role.body))
                            .foregroundStyle(Theme.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let note = row.note {
                        Label(note, systemImage: "info.circle")
                            .font(Theme.font(Theme.Role.body))
                            .foregroundStyle(Theme.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if row.primary != nil || row.secondary != nil {
                        HStack(spacing: Theme.Space.s8) {
                            if let primary = row.primary {
                                Button(primary.1) { fix(primary.0) }
                                    .controlSize(.small)
                            }
                            if let secondary = row.secondary {
                                Button(secondary.1) { fix(secondary.0) }
                                    .controlSize(.small)
                            }
                        }
                    }
                    if !row.detail.isEmpty {
                        TechnicalLine(text: row.detail)
                    }
                }
                .padding(.leading, 44)
                .padding(.trailing, Theme.Space.s12)
                .padding(.bottom, Theme.Space.s12)
            }
        }
    }
}

// MARK: - technical lines

/// A doctor developer line: small, mono, quiet, selectable for a bug report.
private struct TechnicalLine: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Theme.font(Theme.Role.mono))
            .foregroundStyle(Theme.inkTertiary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct DetailToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { isOn.toggle() }
        } label: {
            HStack(spacing: Theme.Space.s4) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                Text("Technical details")
            }
            .font(Theme.font(Theme.Role.caption))
            .foregroundStyle(Theme.inkTertiary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - the glyph

/// The checklist's status glyph.
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
