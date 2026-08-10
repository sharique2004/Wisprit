#if os(macOS)
import SwiftUI
import WispritMacUI

/// Home — `docs/design/ui-redesign.md` §3.3.
///
/// The page a user lands on: one big number, everything they have ever
/// dictated grouped by day, and a 240 pt rail that answers "am I actually using
/// this?" without a chart in sight.
///
/// Three decisions worth keeping:
///
///  * **Every rule is in `HomeModel`.** Grouping, the Today/Yesterday labels,
///    the streak, the heatmap buckets, the WPM median and the search predicate
///    are pure functions over `TranscriptItem` with an explicit `now` and
///    `calendar`, tested with no disk. This file lays them out and nothing
///    else. `HomeSource` is the only mapping seam (§6.1).
///  * **No orange anywhere.** The streak grid is four steps of `ink` and the
///    heaviest day is still ink (§1.6). The tally means "the microphone is
///    open"; a heatmap is history.
///  * **The insertion tier is deliberately absent** from a row's caption line.
///    It lives in `metrics.log`, not the history table, and joining the two by
///    timestamp would lie every time a row was written and the insertion then
///    failed (§3.3). Tiers appear on Insights.
struct HomePage: View {
    @ObservedObject var model: WispritWindowModel

    /// The display calendar, taken once per render pass rather than reached for
    /// inside each helper — `HomeModel`'s whole contract is that the caller
    /// says what "today" means.
    private var calendar: Calendar { .current }

    var body: some View {
        HubPage(title: WispritWindowModel.Tab.home.title) {
            SearchField("Search transcripts", text: $model.historySearch)
        } content: {
            HStack(alignment: .top, spacing: Theme.Space.s24) {
                list
                    .frame(maxWidth: .infinity, alignment: .leading)
                // The column is reserved whether or not the rail has landed:
                // the list must not be laid out at 756 pt for one frame and
                // then reflow to 492.
                Group {
                    if let stats = model.homeStats {
                        StatRail(stats: stats, calendar: calendar)
                    }
                }
                .frame(width: StatTile.width, alignment: .topLeading)
            }
        }
        // The window's own open already asks for the rail; this covers the page
        // being reached some other way (a `Wisprit window home` into an
        // already-open window, a tab switch before the first read landed).
        // After that the 2-second preview keeps it current — see
        // `refreshHomeStats`.
        .task {
            if model.homeStats == nil { model.refreshHomeStats() }
        }
    }

    // MARK: - the list column

    @ViewBuilder
    private var list: some View {
        let items = HomeModel.filter(model.homeItems, query: model.historySearch)
        if items.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    headline
                    ForEach(HomeModel.groups(items, now: Date(), calendar: calendar)) { group in
                        DayGroupHeader(title: group.title)
                        ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                            TranscriptRowView(
                                item: item,
                                caption: HomeSource.caption(for: item, calendar: calendar),
                                isLast: index == group.items.count - 1,
                                canPaste: model.canPasteAtCursor,
                                copy: { model.copy(item.text) },
                                paste: { model.pasteAtCursor(item.text) },
                                addTerm: { term in
                                    _ = model.saveTerm(original: nil, term: term, hear: [])
                                })
                        }
                    }
                    loadMore
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .defaultScrollAnchor(.top)
        }
    }

    /// The one big number on the page (§1.3): lifetime words, in the serif, over
    /// a `body` sub-line. Only ever drawn from the rail's own read — the page
    /// on screen is fifty rows and a lifetime is not.
    @ViewBuilder
    private var headline: some View {
        if let stats = model.homeStats {
            VStack(alignment: .leading, spacing: Theme.Space.s4) {
                Text(HomeSource.decimal(stats.lifetimeWords))
                    .font(Theme.font(Theme.Role.numeralXL))
                    .tracking(Theme.Role.numeralXL.tracking)
                    .foregroundStyle(Theme.ink)
                Text(HomeSource.headlineSubline(stats))
                    .font(Theme.font(Theme.Role.body))
                    .foregroundStyle(Theme.inkSecondary)
            }
            .accessibilityElement(children: .combine)
            .padding(.bottom, Theme.Space.s8)
        }
    }

    @ViewBuilder
    private var loadMore: some View {
        // Only ever offered on the unfiltered list: "load older" against a
        // search box would look like the search had finished, when it has only
        // finished with the rows fetched so far.
        if model.historyHasMore && model.historySearch.isEmpty {
            Button("Load older transcripts") { model.loadMoreHistory() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .padding(.top, Theme.Space.s16)
        }
    }

    // MARK: - empty states (§3.3)

    /// 96 pt, centred, one glyph and two lines. No illustration and no button:
    /// the only thing to do here is hold a key somewhere else.
    @ViewBuilder
    private var emptyState: some View {
        if model.homeStats == nil {
            // The first read has not landed. Drawing "Nothing here yet." over a
            // full history for a frame is worse than drawing nothing.
            Color.clear
        } else if !model.historySearch.isEmpty {
            EmptyBlock(symbol: "magnifyingglass", title: "No matches.") {
                Text("Nothing in your history contains that.")
                    .font(Theme.font(Theme.Role.body))
                    .foregroundStyle(Theme.inkSecondary)
            }
        } else {
            EmptyBlock(symbol: "waveform", title: "Nothing here yet.") {
                HStack(spacing: Theme.Space.s8) {
                    Text("Hold")
                    KeycapView(symbol: keycapSymbol, label: keycapLabel, size: .small)
                    Text("anywhere you can type.")
                }
                .font(Theme.font(Theme.Role.body))
                .foregroundStyle(Theme.inkSecondary)
                if !model.historyEnabled {
                    // Otherwise the line above is a promise the app will not
                    // keep: nothing dictated is being saved.
                    Text("Saving transcripts is switched off in Settings.")
                        .font(Theme.font(Theme.Role.caption))
                        .tracking(Theme.Role.caption.tracking)
                        .foregroundStyle(Theme.inkTertiary)
                }
            }
        }
    }

    private var keycapSymbol: String {
        model.hotkey == .fn ? "globe" : "option"
    }

    private var keycapLabel: String {
        model.hotkey == .fn ? "fn" : "⌥"
    }
}

// MARK: - day group header

/// `captionEmph` `inkTertiary`, 20 pt above / 8 pt below (§3.3).
private struct DayGroupHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(Theme.font(Theme.Role.captionEmph))
            .tracking(Theme.Role.captionEmph.tracking)
            .textCase(.uppercase)
            .foregroundStyle(Theme.inkTertiary)
            .padding(.top, Theme.Space.s20)
            .padding(.bottom, Theme.Space.s8)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - one transcript

/// A committed transcript (§3.3).
///
/// Proportional, not monospace: this is prose a human said, and the mono rule
/// (§1.4) is what keeps the pill's provisional tail visibly different from the
/// finished sentence here. Selection is enabled because the row is text the
/// user may want a fragment of, and the row's own hover actions cover the rest.
///
/// The `trash` action §3.3 specifies is **absent**, not disabled:
/// `History.delete(id:)` does not exist yet (§6.6), and a delete button that
/// cannot delete is a worse answer than no button.
private struct TranscriptRowView: View {
    let item: TranscriptItem
    let caption: String
    let isLast: Bool
    let canPaste: Bool
    let copy: () -> Void
    let paste: () -> Void
    let addTerm: (String) -> Void

    @State private var isHovering = false
    @State private var copied = false
    @State private var isAddingTerm = false

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.s12) {
            VStack(alignment: .leading, spacing: Theme.Space.s4) {
                Text(item.text)
                    .font(Theme.font(Theme.Role.body))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(caption)
                    .font(Theme.font(Theme.Role.caption))
                    .tracking(Theme.Role.caption.tracking)
                    .foregroundStyle(Theme.inkTertiary)
            }
            actions
        }
        .padding(.horizontal, Theme.Space.s12)
        .padding(.vertical, Theme.Space.s8)
        .frame(minHeight: Theme.Size.rowHeightWithDescription, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                .fill(isHovering ? Theme.fillHover : Color.clear)
        )
        .overlay(alignment: .bottom) {
            if !isLast {
                Rectangle()
                    .fill(Theme.hairline)
                    .frame(height: 1)
                    .padding(.horizontal, Theme.Space.s12)
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }

    /// Revealed on hover, but always laid out: a row that changes width when
    /// the pointer crosses it makes the whole list twitch.
    private var actions: some View {
        HStack(spacing: Theme.Space.s2) {
            RowAction(symbol: copied ? "checkmark" : "doc.on.doc",
                      label: copied ? "Copied" : "Copy", action: markCopied)
            if canPaste {
                RowAction(symbol: "text.insert", label: "Paste at cursor", action: paste)
            }
            RowAction(symbol: "text.badge.plus", label: "Add to Dictionary") {
                isAddingTerm = true
            }
            .popover(isPresented: $isAddingTerm) {
                AddTermPopover(transcript: item.text,
                               add: addTerm,
                               dismiss: { isAddingTerm = false })
            }
        }
        // Faded, not removed: the buttons stay in the accessibility tree, so a
        // VoiceOver user — who has no pointer to hover with — can still reach
        // Copy.
        .opacity(isHovering || isAddingTerm ? 1 : 0)
    }

    private func markCopied() {
        copy()
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            copied = false
        }
    }
}

/// A 12 pt row-trailing icon button on a 28 × 28 target (§1.5 / §1.8):
/// `inkTertiary` → `ink` on hover.
private struct RowAction: View {
    let symbol: String
    let label: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(isHovering ? Theme.ink : Theme.inkTertiary)
                .frame(width: Theme.Size.hitTarget, height: Theme.Size.hitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

/// "Add selection to dictionary" (§3.3), as far as SwiftUI allows.
///
/// `Text` with `.textSelection(.enabled)` lets a user select a fragment but
/// exposes nothing to read back, so the field below *is* the selection: a short
/// transcript arrives already filled in (a name, a command — the things that
/// actually need teaching), a sentence arrives empty with the transcript above
/// it to copy from. Saving goes through the same `DictionaryEditor` plan the
/// Dictionary page uses, so a term added here is indistinguishable from one
/// added there.
private struct AddTermPopover: View {
    let transcript: String
    let add: (String) -> Void
    let dismiss: () -> Void

    @State private var term: String

    init(transcript: String, add: @escaping (String) -> Void, dismiss: @escaping () -> Void) {
        self.transcript = transcript
        self.add = add
        self.dismiss = dismiss
        _term = State(initialValue: HomeSource.suggestedTerm(transcript))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s8) {
            Text("Add to Dictionary")
                .font(Theme.font(Theme.Role.sectionTitle))
                .foregroundStyle(Theme.ink)
            Text(transcript)
                .font(Theme.font(Theme.Role.body))
                .foregroundStyle(Theme.inkSecondary)
                .lineLimit(3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Term", text: $term)
                .textFieldStyle(.roundedBorder)
                .font(Theme.font(Theme.Role.body))
                .onSubmit(save)
            Text("Wisprit will listen for this spelling from now on.")
                .font(Theme.font(Theme.Role.caption))
                .tracking(Theme.Role.caption.tracking)
                .foregroundStyle(Theme.inkTertiary)
            HStack(spacing: Theme.Space.s8) {
                Spacer(minLength: 0)
                Button("Cancel", action: dismiss)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button("Add", action: save)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(Theme.Space.s16)
        .frame(width: 280)
    }

    private var trimmed: String {
        term.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func save() {
        guard !trimmed.isEmpty else { return }
        add(trimmed)
        dismiss()
    }
}

// MARK: - the stat rail (§3.3)

/// Three tiles and the streak grid, flat and hairline-separated. No nested
/// cards: the content card is the only card on the page (§1.7).
private struct StatRail: View {
    let stats: HomeStats
    let calendar: Calendar

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StatTile(label: "Today",
                     value: HomeSource.decimal(stats.wordsToday),
                     sub: HomeSource.todaySubline(stats))
            // A rate tile with no rate shows nothing, never a 0: until a row
            // carries a usable hold duration there is no median to report.
            if let wpm = stats.medianWPM {
                divider
                StatTile(label: "Speaking rate",
                         value: HomeSource.rate(wpm),
                         sub: "wpm · median, last \(HomeModel.defaultRateSample)")
            }
            divider
            StatTile(label: "Streak",
                     value: HomeSource.decimal(stats.streakDays),
                     sub: HomeSource.streakSubline(stats.streakDays))
            StreakGrid(weeks: stats.heatmap,
                       today: todayCell)
            Text("\(stats.heatmapWeeks) weeks")
                .font(Theme.font(Theme.Role.caption))
                .tracking(Theme.Role.caption.tracking)
                .foregroundStyle(Theme.inkTertiary)
                .padding(.top, Theme.Space.s8)
        }
    }

    private var todayCell: (week: Int, day: Int)? {
        guard let cell = HomeSource.todayCell(weeks: stats.heatmapWeeks,
                                              now: Date(),
                                              calendar: calendar) else { return nil }
        return (week: cell.week, day: cell.day)
    }

    private var divider: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(width: StatTile.width, height: 1)
            .padding(.bottom, Theme.Space.s12)
    }
}

// MARK: - empty block

/// §3.3's empty state, and the shape any other page's should take: 96 pt tall,
/// centred, a hero glyph in `inkQuaternary`, one `sectionTitle` and one line of
/// `body`. No illustration, no button.
private struct EmptyBlock<Content: View>: View {
    let symbol: String
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: Theme.Space.s8) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Theme.inkQuaternary)
            Text(title)
                .font(Theme.font(Theme.Role.sectionTitle))
                .foregroundStyle(Theme.ink)
            content
        }
        .frame(minHeight: 96)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}
#endif
