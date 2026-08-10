#if os(macOS)
import SwiftUI
import WispritMacUI

/// Dictionary — `docs/design/ui-redesign.md` §3.4.
///
/// The page where the user meets what Wisprit has taught itself. Three kinds of
/// row live here and the badges say which: terms typed in by hand, terms
/// learned from a spelled-out correction (`source: "spoken_spelling"`), and
/// **quarantined** ones — `pending: true`, believable but attested exactly once,
/// which `DictionaryStore` keeps out of the corrections, the biasing list and
/// `terms()` until a second sighting promotes it.
///
/// That last kind is the reason this page exists rather than an "Open
/// dictionary.json" button. A pending entry is invisible to the engine and
/// unreachable from anywhere else: without a surface it sits in the file
/// forever, waiting for a second sighting that may never come. Accept promotes
/// it through `DictionaryStore.addPending` — the same transition the second
/// sighting makes, not a second implementation of it — and Dismiss removes it.
///
/// The cleanup banner is the other half: `LearnedTermCleanup` already audits
/// the file on every full probe and the result already rides in
/// `DoctorFacts.learnedTerms`, so the suspects are read from there and the
/// button runs the existing `.cleanLearnedTerms` fix. One audit, one fix, two
/// surfaces (here and Setup) that cannot disagree.
struct DictionaryPage: View {
    @ObservedObject var model: WispritWindowModel

    @State private var sort: DictionarySort = .alphabetical
    @State private var editing: EditTarget?
    @State private var pendingDelete: DictionaryRow?
    @State private var hovered: DictionaryListItem.ID?

    /// nil `row` = adding a new term.
    private struct EditTarget: Identifiable {
        var row: DictionaryRow?
        var id: String { row?.id ?? "" }
    }

    private var items: [DictionaryListItem] {
        DictionaryList.items(model.dictionaryRows, search: model.dictionarySearch, sort: sort)
    }

    var body: some View {
        HubPage(title: WispritWindowModel.Tab.dictionary.title) {
            HStack(spacing: Theme.Space.s8) {
                SearchField("Search terms and phrases", text: $model.dictionarySearch)
                sortMenu
                Button {
                    editing = EditTarget(row: nil)
                } label: {
                    Label("Add Term", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        } content: {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    proposalsBanner
                    cleanupBanner
                    if items.isEmpty {
                        emptyState
                    } else {
                        list
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // The list is empty until `reloadDictionary` lands and then gains
            // every row at once; without an anchor the scroll view keeps the
            // offset it had while empty.
            .defaultScrollAnchor(.top)
        }
        .sheet(item: $editing) { target in
            TermSheet(original: target.row) { term, hear in
                model.saveTerm(original: target.row, term: term, hear: hear)
            }
        }
        .alert("Delete this term?",
               isPresented: Binding(get: { pendingDelete != nil },
                                    set: { if !$0 { pendingDelete = nil } }),
               presenting: pendingDelete) { row in
            Button("Delete", role: .destructive) { model.deleteTerm(row.term) }
            Button("Cancel", role: .cancel) {}
        } message: { row in
            Text("Wisprit will stop correcting misheard spellings of “\(row.term)”.")
        }
        .onAppear { model.reloadDictionary() }
    }

    // MARK: - header

    private var sortMenu: some View {
        Picker("Sort", selection: $sort) {
            ForEach(DictionarySort.allCases) { option in
                Text(option.title).tag(option)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
        .accessibilityLabel("Sort")
    }

    // MARK: - edit-derived learn proposals (Phase 5)

    /// Words the flywheel saw the user type over Wisprit's output in two or
    /// more distinct utterances. They are NOT vocabulary yet — nothing here is
    /// in `dictionary.json` — so they render as a decision banner, not as rows:
    /// Accept writes the term (the same `add` + `promoteConsumed` transition
    /// auto-accept makes), Dismiss records a permanent no.
    @ViewBuilder
    private var proposalsBanner: some View {
        if !model.learnProposals.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.s8) {
                HStack(alignment: .top, spacing: Theme.Space.s12) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.attention)
                    VStack(alignment: .leading, spacing: Theme.Space.s4) {
                        Text(DictionaryList.proposalsHeadline(model.learnProposals.count))
                            .font(Theme.font(Theme.Role.rowTitle))
                            .foregroundStyle(Theme.ink)
                        Text(DictionaryList.proposalsExplanation)
                            .font(Theme.font(Theme.Role.body))
                            .foregroundStyle(Theme.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: Theme.Space.s16)
                }
                ForEach(model.learnProposals) { proposal in
                    HStack(spacing: Theme.Space.s8) {
                        Text(proposal.term)
                            .font(Theme.font(Theme.Role.rowTitle))
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                        // What the recognizer wrote instead — machine output,
                        // so mono (§1.4).
                        Text(DictionaryList.proposalEvidence(proposal))
                            .font(Theme.font(Theme.Role.mono))
                            .foregroundStyle(Theme.inkSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: Theme.Space.s8)
                        Button("Accept") { model.acceptLearnProposal(proposal) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .accessibilityLabel("Accept “\(proposal.term)”")
                        Button("Dismiss") { model.dismissLearnProposal(proposal) }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                            .accessibilityLabel("Dismiss “\(proposal.term)”")
                    }
                }
            }
            .padding(Theme.Space.s12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                    .fill(Theme.groundRecessed)
            )
            .padding(.bottom, Theme.Space.s16)
        }
    }

    // MARK: - the cleanup affordance

    /// Surfaces exactly what `wisprit doctor` and the Setup page already say —
    /// same audit, same fix — on the page whose rows it is about.
    @ViewBuilder
    private var cleanupBanner: some View {
        let audit = model.facts.learnedTerms
        if !audit.isClean {
            VStack(alignment: .leading, spacing: Theme.Space.s8) {
                HStack(alignment: .top, spacing: Theme.Space.s12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.attention)
                    VStack(alignment: .leading, spacing: Theme.Space.s4) {
                        Text(DictionaryList.suspectHeadline(audit))
                            .font(Theme.font(Theme.Role.rowTitle))
                            .foregroundStyle(Theme.ink)
                        Text(DictionaryList.suspectExplanation)
                            .font(Theme.font(Theme.Role.body))
                            .foregroundStyle(Theme.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: Theme.Space.s16)
                    Button(Doctor.cleanLearnedTermsTitle) { cleanUp() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                // The spellings themselves, in mono: this is what the ASR
                // produced, not what a human wrote (§1.4).
                ForEach(audit.suspects, id: \.term) { suspect in
                    Text(suspect.summary)
                        .font(Theme.font(Theme.Role.mono))
                        .foregroundStyle(Theme.inkSecondary)
                }
            }
            .padding(Theme.Space.s12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                    .fill(Theme.groundRecessed)
            )
            .padding(.bottom, Theme.Space.s16)
        }
    }

    private func cleanUp() {
        // The same seam the checklist button uses — `SetupFixRunner` owns what
        // the fix actually does, and it writes dictionary.json.bak first.
        model.fix(.cleanLearnedTerms)
        model.reloadDictionary()
    }

    // MARK: - rows

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(items) { item in
                DictionaryTermRow(
                    row: item.row,
                    isHovered: hovered == item.id,
                    accept: { model.promoteTerm(item.row) },
                    dismiss: { model.deleteTerm(item.row.term) },
                    edit: { editing = EditTarget(row: item.row) },
                    delete: { pendingDelete = item.row })
                    .onHover { inside in
                        hovered = inside ? item.id : (hovered == item.id ? nil : hovered)
                    }
            }
        }
    }

    // MARK: - empty states

    /// Two different nothings: a dictionary with no terms, and a search that
    /// found none. Saying "add your first term" to someone with 139 terms and a
    /// typo in the search field would be a lie.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s4) {
            Text(DictionaryList.emptyTitle(hasRows: !model.dictionaryRows.isEmpty,
                                           search: model.dictionarySearch))
                .font(Theme.font(Theme.Role.sectionTitle))
                .foregroundStyle(Theme.ink)
            Text(DictionaryList.emptyDetail(hasRows: !model.dictionaryRows.isEmpty))
                .font(Theme.font(Theme.Role.body))
                .foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, Theme.Space.s24)
    }
}

// MARK: - one term

private struct DictionaryTermRow: View {
    let row: DictionaryRow
    let isHovered: Bool
    let accept: () -> Void
    let dismiss: () -> Void
    let edit: () -> Void
    let delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s4) {
            HStack(alignment: .center, spacing: Theme.Space.s8) {
                Text(row.term)
                    .font(Theme.font(Theme.Role.rowTitle))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Spacer(minLength: Theme.Space.s16)
                ForEach(DictionaryList.badges(for: row), id: \.self) { badge in
                    Badge(badge.title, symbol: badge.symbol, tint: badge.tint)
                }
                if let used = lastUsed {
                    Text(used)
                        .font(Theme.font(Theme.Role.caption))
                        .tracking(Theme.Role.caption.tracking)
                        .foregroundStyle(Theme.inkTertiary)
                        .lineLimit(1)
                }
                trailingControls
            }
            hearsLine
        }
        .padding(.vertical, Theme.Space.s12)
        .padding(.horizontal, Theme.Space.s8)
        .frame(minHeight: DictionaryList.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                .fill(isHovered ? Theme.fillHover : Color.clear)
        )
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 1)
        }
    }

    /// A quarantined entry gets the decision, not the menu: accepting or
    /// dismissing it is the only thing anyone can usefully do with one, and
    /// Dismiss already covers the destructive half.
    @ViewBuilder
    private var trailingControls: some View {
        if row.isPending {
            HStack(spacing: Theme.Space.s8) {
                Button("Accept") { accept() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel("Accept “\(row.term)”")
                Button("Dismiss") { dismiss() }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .accessibilityLabel("Dismiss “\(row.term)”")
            }
        } else {
            Menu {
                Button("Edit…") { edit() }
                Button("Delete…", role: .destructive) { delete() }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.inkSecondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: Theme.Size.hitTarget)
            .accessibilityLabel("Actions for “\(row.term)”")
        }
    }

    private var hearsLine: some View {
        let chips = DictionaryList.chips(row.phrases)
        return HStack(spacing: Theme.Space.s4) {
            Text(chips.visible.isEmpty ? DictionaryList.noPhrases : DictionaryList.hearsLabel)
                .font(Theme.font(Theme.Role.caption))
                .tracking(Theme.Role.caption.tracking)
                .foregroundStyle(Theme.inkTertiary)
            ForEach(chips.visible, id: \.self) { phrase in
                PhraseChip(phrase)
            }
            if chips.overflow > 0 {
                Text("+\(chips.overflow)")
                    .font(Theme.font(Theme.Role.caption))
                    .foregroundStyle(Theme.inkTertiary)
            }
            Spacer(minLength: 0)
        }
    }

    private var lastUsed: String? {
        guard !row.isPending, let at = row.lastUsed else { return nil }
        return RelativeTime.string(from: at.timeIntervalSince1970)
    }
}

// MARK: - add / edit sheet

/// 420 × 300 (§3.4). Every write goes through `DictionaryEditor.save`, which
/// plans merge-vs-rebuild before touching the file — and this sheet says which
/// one it is going to be *before* the user presses Save, because a rebuild
/// restarts `learned_at` and `hit_count` and there is no way to warn afterwards.
private struct TermSheet: View {
    let original: DictionaryRow?
    let onSave: (String, [String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var term: String
    @State private var hear: String

    init(original: DictionaryRow?, onSave: @escaping (String, [String]) -> Void) {
        self.original = original
        self.onSave = onSave
        _term = State(initialValue: original?.term ?? "")
        // A pending entry's phrases are its observations, and they are what
        // promotion would fold into `hear` — so they are what the field shows.
        _hear = State(initialValue: DictionaryEdit.formatHearField(original?.phrases ?? []))
    }

    private var phrases: [String] { DictionaryEdit.parseHearField(hear) }

    private var plan: DictionaryEditPlan {
        DictionaryEdit.plan(original: original, term: term, hear: phrases)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s16) {
            Text(original == nil ? "Add a term" : "Edit “\(original?.term ?? "")”")
                .font(Theme.font(Theme.Role.sectionTitle))
                .foregroundStyle(Theme.ink)

            field("Term") {
                TextField("Sharique", text: $term)
                    .textFieldStyle(.plain)
                    .font(Theme.font(Theme.Role.body))
                    .foregroundStyle(Theme.ink)
            }

            field("Wisprit sometimes hears") {
                TextField("Shariq, Cherie", text: $hear, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Theme.font(Theme.Role.body))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2...4)
            }

            preview

            if let warning = DictionaryList.warning(for: plan) {
                Text(warning)
                    .font(Theme.font(Theme.Role.caption))
                    .tracking(Theme.Role.caption.tracking)
                    .foregroundStyle(Theme.attention)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            HStack(spacing: Theme.Space.s8) {
                Spacer(minLength: 0)
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(term, phrases)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(Theme.Space.s20)
        .frame(width: DictionaryList.sheetWidth, height: DictionaryList.sheetHeight)
        .background(Theme.surface)
    }

    /// What the correction will actually do, in the recognizer's own words.
    private var preview: some View {
        let line = DictionaryList.preview(term: term, hear: phrases)
        return Text(line ?? DictionaryList.previewPlaceholder)
            .font(Theme.font(Theme.Role.mono))
            .foregroundStyle(line == nil ? Theme.inkTertiary : Theme.inkSecondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, Theme.Space.s8)
            .frame(maxWidth: .infinity, minHeight: Theme.Size.hitTarget, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                    .fill(Theme.groundRecessed)
            )
    }

    private func field<Content: View>(_ label: String,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s4) {
            Text(label)
                .font(Theme.font(Theme.Role.caption))
                .tracking(Theme.Role.caption.tracking)
                .foregroundStyle(Theme.inkTertiary)
            content()
                .padding(.horizontal, Theme.Space.s8)
                .padding(.vertical, Theme.Space.s4)
                .frame(minHeight: Theme.Size.hitTarget, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                        .fill(Theme.fillSubtle)
                )
        }
    }
}

// MARK: - pure presentation

/// §3.4's sort menu. Every option is a field the store already persists —
/// there is no "Starred first", because nothing persists a star.
enum DictionarySort: String, CaseIterable, Identifiable, Equatable, Sendable {
    case alphabetical, recentlyUsed, recentlyAdded, mostUsed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .alphabetical: return "A–Z"
        case .recentlyUsed: return "Recently used"
        case .recentlyAdded: return "Recently added"
        case .mostUsed: return "Most used"
        }
    }
}

/// One row, carrying the file position it came from.
///
/// The position IS the identity: `DictionaryRow.id` is the case-folded term,
/// and `dictionary.json` really can hold the same term twice (the store's own
/// vocabulary ranking de-duplicates for exactly that reason). Two rows with one
/// id is a `ForEach` that drops a row and animates the survivor wrongly.
struct DictionaryListItem: Identifiable, Equatable {
    let index: Int
    let row: DictionaryRow

    var id: Int { index }
}

/// The badges §3.4 maps to real data. `starred` is absent because
/// `DictionaryStore` does not persist one — a disabled control would be worse.
enum DictionaryBadgeKind: Hashable, Sendable {
    case learned
    case pending
    case used(Int)

    var title: String {
        switch self {
        case .learned: return "Learned"
        case .pending: return "Pending"
        case .used(let count): return "Used \(count)×"
        }
    }

    var symbol: String? {
        switch self {
        case .learned: return "sparkles"
        case .pending: return "clock"
        case .used: return nil
        }
    }

    var tint: Color {
        switch self {
        case .learned: return Theme.positive
        case .pending: return Theme.attention
        case .used: return Theme.inkSecondary
        }
    }
}

/// Everything the Dictionary page *decides*, as functions of values: which rows
/// are shown and in what order, which badges a row wears, what the sheet warns
/// about. None of it needs a window, so all of it is asserted in
/// `DictionaryPageTests` rather than eyeballed.
enum DictionaryList {

    /// §3.4: 44 pt, two lines.
    static let rowHeight: Double = 44
    static let sheetWidth: Double = 420
    static let sheetHeight: Double = 300
    /// Heard phrases shown before the list collapses to `+N`.
    static let maxChips = 3

    static let hearsLabel = "hears"
    static let noPhrases = "no misheard phrases yet"
    static let previewPlaceholder = "add a phrase to see the correction"

    /// §3.4, verbatim: the one consequence of an edit the user cannot undo by
    /// editing again.
    static let rebuildWarning =
        "Renaming or removing a phrase resets this term's learn date and use count."

    static let suspectExplanation =
        "Cleaning them up folds each one back into the word it is a spelling of. "
        + "Your own entries are left alone, and a backup is written first."

    // MARK: rows

    static func items(_ rows: [DictionaryRow], search: String,
                      sort: DictionarySort) -> [DictionaryListItem] {
        rows.enumerated()
            .filter { $0.element.matches(search) }
            .map { DictionaryListItem(index: $0.offset, row: $0.element) }
            .sorted { lhs, rhs in
                switch sort {
                case .alphabetical:
                    let order = lhs.row.term.localizedStandardCompare(rhs.row.term)
                    if order != .orderedSame { return order == .orderedAscending }
                case .recentlyUsed:
                    if let decided = newerFirst(lhs.row.lastUsed, rhs.row.lastUsed) {
                        return decided
                    }
                case .recentlyAdded:
                    if let decided = newerFirst(lhs.row.learnedAt, rhs.row.learnedAt) {
                        return decided
                    }
                case .mostUsed:
                    if lhs.row.hitCount != rhs.row.hitCount {
                        return lhs.row.hitCount > rhs.row.hitCount
                    }
                }
                // File order breaks every tie, so the list is stable and a
                // re-sort never shuffles equal rows.
                return lhs.index < rhs.index
            }
    }

    /// Newest first, "never" last. A nil date is not an old date: the term has
    /// no such event at all, and sorting it as 1970 would bury real rows under
    /// it in the other direction.
    private static func newerFirst(_ lhs: Date?, _ rhs: Date?) -> Bool? {
        switch (lhs, rhs) {
        case (nil, nil): return nil
        case (nil, _): return false
        case (_, nil): return true
        case (let a?, let b?): return a == b ? nil : a > b
        }
    }

    static func badges(for row: DictionaryRow) -> [DictionaryBadgeKind] {
        // A quarantined entry is not vocabulary: it corrects nothing and has
        // never been used, so "Learned" and "Used" would both be false.
        if row.isPending { return [.pending] }
        var out: [DictionaryBadgeKind] = []
        if row.isLearned { out.append(.learned) }
        if row.hitCount > 0 { out.append(.used(row.hitCount)) }
        return out
    }

    static func chips(_ phrases: [String]) -> (visible: [String], overflow: Int) {
        guard phrases.count > maxChips else { return (phrases, 0) }
        return (Array(phrases.prefix(maxChips)), phrases.count - maxChips)
    }

    // MARK: sheet

    /// The first heard phrase, rewritten to the term — one line of exactly what
    /// the compiled correction will do. nil when there is nothing to show yet.
    static func preview(term: String, hear: [String]) -> String? {
        let canonical = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !canonical.isEmpty, let phrase = DictionaryEdit.normalize(hear).first else {
            return nil
        }
        return "\(phrase)  →  \(canonical)"
    }

    /// The rebuild warning, and only for a plan that really is one. A merge
    /// keeps `learned_at`, `source` and every unknown key, so warning about it
    /// would train the user to ignore the line that matters.
    static func warning(for plan: DictionaryEditPlan) -> String? {
        switch plan {
        case .rebuild: return rebuildWarning
        case .merge, .noop: return nil
        }
    }

    // MARK: banners and empty states

    /// The proposals banner's copy. Pure, so "one word" vs "N words" and the
    /// evidence line are pinned facts rather than eyeballed strings.
    static func proposalsHeadline(_ count: Int) -> String {
        "\(count) new word\(count == 1 ? "" : "s") heard in your edits"
    }

    static let proposalsExplanation =
        "You typed these over what Wisprit wrote, more than once. Accept adds "
        + "one to your dictionary; Dismiss never asks about it again."

    /// "heard “Shariq” · 2×" — what the recognizer produced, and how often the
    /// correction was seen.
    static func proposalEvidence(_ row: WispritWindowModel.LearnProposalRow) -> String {
        var parts: [String] = []
        if let heard = row.heard.first, !heard.isEmpty {
            parts.append("heard “\(heard)”")
        }
        parts.append("\(row.count)×")
        return parts.joined(separator: " · ")
    }

    static func suspectHeadline(_ audit: LearnedTermCleanup.Audit) -> String {
        let count = audit.suspects.count
        return "\(count) learned spelling\(count == 1 ? "" : "s") "
            + "look\(count == 1 ? "s" : "") wrong"
    }

    static func emptyTitle(hasRows: Bool, search: String) -> String {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hasRows else { return "No terms yet." }
        return query.isEmpty ? "No terms yet." : "Nothing matches “\(query)”."
    }

    static func emptyDetail(hasRows: Bool) -> String {
        hasRows
            ? "Search looks at the term and at every phrase Wisprit mishears it as."
            : "Add the names and jargon speech recognition keeps getting wrong — "
                + "or spell one out loud mid-sentence and Wisprit will learn it here."
    }
}
#endif
