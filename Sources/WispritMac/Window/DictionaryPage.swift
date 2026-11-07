#if os(macOS)
import SwiftUI
import WispritKit
import WispritMacUI

/// Dictionary — what Wisprit listens for, and what it turns that into.
///
/// Two jobs, two views behind one toolbar filter:
///
///  * **Needs review** — every entry that wants a decision, first when there
///    is one. The loudest kind is a term whose `hear` list holds everyday
///    words: the exact pass rewrites a `hear` phrase wherever it is said, so
///    "play" → Ploy happens in every dictation. "Everyday word" is the fuzzy
///    layer's own ordinary-word veto (`OrdinaryWords`), so this page and the
///    engine cannot disagree about which words those are. Learn proposals,
///    quarantined learns, duplicate entries and the learned-spelling audit
///    (`LearnedTermCleanup`, the same audit and fix the health sheet runs)
///    join it there.
///  * **All · Learned · Added** — the terms, with where each came from in
///    plain words, what it listens for, and how often it has been used.
///
/// Every write is undoable — inline, and with Edit ▸ Undo — so nothing here
/// asks "are you sure?" first (WindowModel+Dictionary.swift).
///
/// Snippets and personal details are reachable from the list header and open
/// as sheets: they are set once and rarely touched, and 139 terms should not
/// share a scroll view with them.
struct DictionaryPage: View {
    @ObservedObject var model: WispritWindowModel
    @Environment(\.undoManager) private var undoManager

    /// nil until the user picks: then the page opens on Needs review when
    /// anything needs a decision, and on All otherwise.
    @State private var chosenFilter: DictionaryFilter? = DictionaryRenderHook.filter
    @State private var sort: DictionarySort = DictionaryRenderHook.sort
    @State private var editing: EditTarget?
    @State private var hovered: DictionaryListItem.ID?
    @State private var auxiliary: AuxiliarySheet?

    /// nil `row` = adding a new term.
    private struct EditTarget: Identifiable {
        var row: DictionaryRow?
        var id: String { row?.id ?? "" }
    }

    private enum AuxiliarySheet: String, Identifiable {
        case snippets, personalDetails
        var id: String { rawValue }
    }

    private var filter: DictionaryFilter {
        chosenFilter ?? (model.dictionaryReviewCount > 0 ? .review : .all)
    }

    var body: some View {
        HubPage(title: WispritWindowModel.Tab.dictionary.title) {
            filterPicker
            Button {
                editing = EditTarget(row: nil)
            } label: {
                Label("Add Term", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .help("Add Term — a name or word Wisprit keeps getting wrong")
        } content: {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch filter {
                    case .review: reviewContent
                    case .all, .learned, .added: termsContent
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // Room for the undo bar, so it never sits on the last row.
                .padding(.bottom, Theme.Space.s64)
            }
            .scrollIndicators(.automatic)
            // The list is empty until `reloadDictionary` lands and then gains
            // every row at once; without an anchor the scroll view keeps the
            // offset it had while empty.
            .defaultScrollAnchor(.top)
        }
        .searchable(text: $model.dictionarySearch, placement: .toolbar,
                    prompt: "Search terms and phrases")
        .overlay(alignment: .bottom) { undoBar }
        .animation(.snappy(duration: 0.25), value: model.dictionaryLastChange?.id)
        .sheet(item: $editing) { target in
            TermSheet(original: target.row,
                      isEveryday: { model.isEverydayWord($0) }) { term, hear in
                model.saveTerm(original: target.row, term: term, hear: hear)
            }
        }
        .sheet(item: $auxiliary) { sheet in
            switch sheet {
            case .snippets: SnippetsSheet(model: model)
            case .personalDetails: PersonalDetailsSheet(model: model)
            }
        }
        .onAppear {
            model.dictionaryUndoManager = undoManager
            model.reloadDictionary()
            model.reloadSnippets()
            DictionaryRenderHook.apply(to: model)
        }
        .onChange(of: undoManager) { _, manager in
            model.dictionaryUndoManager = manager
        }
    }

    // MARK: - toolbar

    private var filterPicker: some View {
        Picker("Show", selection: Binding(get: { filter }, set: { chosenFilter = $0 })) {
            ForEach(DictionaryFilter.allCases) { option in
                Text(DictionaryList.filterTitle(option, reviewCount: model.dictionaryReviewCount))
                    .tag(option)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .accessibilityLabel("Show")
    }

    // MARK: - needs review

    private var search: String { model.dictionarySearch }

    @ViewBuilder
    private var reviewContent: some View {
        let review = model.dictionaryReview
        let everyday = review.everydayWords.filter {
            DictionaryList.matches(search, term: $0.term, phrases: $0.words)
        }
        let proposals = model.learnProposals.filter {
            DictionaryList.matches(search, term: $0.term, phrases: $0.heard)
        }
        let pending = review.pending.filter { $0.matches(search) }
        let duplicates = review.duplicates.filter {
            DictionaryList.matches(search, term: $0.term, phrases: [])
        }
        let audit = model.facts.learnedTerms
        let suspects = audit.suspects.filter {
            DictionaryList.matches(search, term: $0.term, phrases: $0.hear)
        }
        let total = everyday.count + proposals.count + pending.count + duplicates.count
            + suspects.count

        if total == 0 {
            if model.dictionaryReviewCount == 0 {
                allClear
            } else {
                emptySearch
            }
        } else {
            reviewIntro(total)

            if !everyday.isEmpty {
                ReviewGroup(title: DictionaryList.everydayTitle, count: everyday.count,
                            detail: DictionaryList.everydayDetail) {
                    ForEach(everyday) { item in
                        everydayRow(item)
                    }
                }
            }

            if !proposals.isEmpty {
                ReviewGroup(title: DictionaryList.proposalsTitle, count: proposals.count,
                            detail: DictionaryList.proposalsExplanation) {
                    ForEach(proposals) { proposal in
                        ReviewRow(title: proposal.term, tag: DictionarySource.learnedFromEdits.label) {
                            DetailLine(DictionaryList.proposalEvidence(proposal))
                        } actions: {
                            Button("Add") { model.acceptLearnProposal(proposal) }
                                .accessibilityLabel("Add “\(proposal.term)”")
                            Button("Dismiss") { model.dismissLearnProposal(proposal) }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Dismiss “\(proposal.term)”")
                        }
                    }
                }
            }

            if !pending.isEmpty {
                ReviewGroup(title: DictionaryList.pendingTitle, count: pending.count,
                            detail: DictionaryList.pendingDetail) {
                    ForEach(pending) { row in
                        ReviewRow(title: row.term, tag: row.kind.label) {
                            DetailLine(DictionaryList.pendingEvidence(row))
                        } actions: {
                            Button("Add") { model.promoteTerm(row) }
                                .accessibilityLabel("Add “\(row.term)”")
                            Button("Dismiss") { model.deleteTerm(row.term) }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Dismiss “\(row.term)”")
                        }
                    }
                }
            }

            if !duplicates.isEmpty {
                ReviewGroup(title: DictionaryList.duplicatesTitle, count: duplicates.count,
                            detail: DictionaryList.duplicatesDetail) {
                    ForEach(duplicates) { item in
                        ReviewRow(title: item.term, tag: nil) {
                            DetailLine(DictionaryList.duplicateEvidence(item))
                        } actions: {
                            Button("Merge") { model.mergeDuplicates(item) }
                                .accessibilityLabel("Merge the copies of “\(item.term)”")
                        }
                    }
                }
            }

            if !suspects.isEmpty {
                ReviewGroup(title: DictionaryList.suspectHeadline(audit), count: nil,
                            detail: DictionaryList.suspectExplanation) {
                    ForEach(suspects, id: \.term) { suspect in
                        ReviewRow(title: suspect.term,
                                  tag: DictionarySource.learnedFromSpelling.label) {
                            DetailLine(suspect.summary, mono: true)
                        } actions: {
                            EmptyView()
                        }
                    }
                } accessory: {
                    Button(Doctor.cleanLearnedTermsTitle) {
                        // The checklist's own fix — `SetupFixRunner` owns what
                        // it does, and writes dictionary.json.bak first.
                        model.fix(.cleanLearnedTerms)
                        model.reloadDictionary()
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private func reviewIntro(_ count: Int) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s4) {
            Text(DictionaryList.reviewHeadline(count))
                .font(Theme.font(Theme.Role.pageTitle))
                .tracking(Theme.Role.pageTitle.tracking)
                .foregroundStyle(Theme.ink)
            Text(DictionaryList.reviewSubhead)
                .font(Theme.font(Theme.Role.body))
                .foregroundStyle(Theme.inkSecondary)
        }
        .padding(.top, Theme.Space.s8)
        .padding(.bottom, Theme.Space.s24)
    }

    private func everydayRow(_ item: EverydayWordReview) -> some View {
        ReviewRow(title: item.term, tag: item.kind.label) {
            HStack(spacing: Theme.Space.s4) {
                ForEach(Array(DictionaryList.chips(item.words).visible.enumerated()),
                        id: \.offset) { _, word in
                    WordChip(word, flagged: true)
                }
                let overflow = DictionaryList.chips(item.words).overflow
                if overflow > 0 {
                    Text("+\(overflow)")
                        .font(Theme.font(Theme.Role.caption))
                        .foregroundStyle(Theme.inkTertiary)
                }
                Image(systemName: "arrow.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.inkTertiary)
                    .padding(.horizontal, Theme.Space.s2)
                Text(item.term)
                    .font(Theme.font(Theme.Role.caption))
                    .foregroundStyle(Theme.inkSecondary)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(DictionaryList.everydayAccessibility(item))
        } actions: {
            Button("Stop Matching") { model.stopMatching(item) }
                .help(DictionaryList.stopMatchingHelp(item))
                .accessibilityLabel(DictionaryList.stopMatchingHelp(item))
            Button("Keep") { model.keepEverydayWords(item) }
                .buttonStyle(.borderless)
                .help("Keep listening for these and stop asking")
                .accessibilityLabel("Keep \(DictionaryCopy.quotedList(item.words)) for \(item.term)")
        }
    }

    private var allClear: some View {
        VStack(spacing: Theme.Space.s8) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Theme.positive)
            Text(DictionaryList.allClearTitle)
                .font(Theme.font(Theme.Role.sectionTitle))
                .foregroundStyle(Theme.ink)
            Text(DictionaryList.allClearDetail)
                .font(Theme.font(Theme.Role.body))
                .foregroundStyle(Theme.inkSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Button("Show All Terms") { chosenFilter = .all }
                .buttonStyle(.borderless)
                .padding(.top, Theme.Space.s4)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Theme.Space.s64)
    }

    private var emptySearch: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s4) {
            Text(DictionaryList.emptyTitle(hasRows: true, search: search))
                .font(Theme.font(Theme.Role.sectionTitle))
                .foregroundStyle(Theme.ink)
            Text("Nothing waiting for review matches the search.")
                .font(Theme.font(Theme.Role.body))
                .foregroundStyle(Theme.inkSecondary)
        }
        .padding(.top, Theme.Space.s24)
    }

    // MARK: - the terms

    @ViewBuilder
    private var termsContent: some View {
        let items = DictionaryList.items(model.dictionaryRows, search: search,
                                         sort: sort, filter: filter)
        listHeader(count: items.count)
        if items.isEmpty {
            emptyState
        } else {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(items) { item in
                    TermRow(
                        row: item.row,
                        flagged: Set(model.everydayWords(in: item.row).map { $0.lowercased() }),
                        isHovered: hovered == item.id,
                        edit: { editing = EditTarget(row: item.row) },
                        delete: { model.deleteTerm(item.row.term) })
                        .onHover { inside in
                            hovered = inside ? item.id : (hovered == item.id ? nil : hovered)
                        }
                }
            }
        }
    }

    private func listHeader(count: Int) -> some View {
        HStack(spacing: Theme.Space.s12) {
            Text(DictionaryList.countLabel(count, filter: filter))
                .font(Theme.font(Theme.Role.captionEmph))
                .tracking(Theme.Role.captionEmph.tracking)
                .foregroundStyle(Theme.inkSecondary)
            Spacer(minLength: Theme.Space.s16)
            if model.hasSnippets {
                HeaderButton(DictionaryList.snippetsLink(model.snippetRows.count),
                             symbol: "text.quote") { auxiliary = .snippets }
            }
            if model.hasIdentity {
                HeaderButton("Personal details", symbol: "person.text.rectangle") {
                    auxiliary = .personalDetails
                }
            }
            sortMenu
        }
        .frame(minHeight: Theme.Size.hitTarget)
        .padding(.top, Theme.Space.s4)
        .padding(.bottom, Theme.Space.s8)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.hairline).frame(height: 1)
        }
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort by", selection: $sort) {
                ForEach(DictionarySort.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: Theme.Space.s4) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 10, weight: .semibold))
                Text(sort.title)
                    .font(Theme.font(Theme.Role.caption))
            }
            .foregroundStyle(Theme.inkSecondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Sort, \(sort.title)")
    }

    /// Two different nothings: a dictionary with no terms, and a search that
    /// found none. Saying "add your first term" to someone with 139 terms and a
    /// typo in the search field would be a lie.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s4) {
            Text(DictionaryList.emptyTitle(hasRows: !model.dictionaryRows.isEmpty,
                                           search: search))
                .font(Theme.font(Theme.Role.sectionTitle))
                .foregroundStyle(Theme.ink)
            Text(DictionaryList.emptyDetail(hasRows: !model.dictionaryRows.isEmpty))
                .font(Theme.font(Theme.Role.body))
                .foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, Theme.Space.s24)
    }

    // MARK: - undo

    @ViewBuilder
    private var undoBar: some View {
        if let change = model.dictionaryLastChange {
            HStack(spacing: Theme.Space.s12) {
                Text(change.summary)
                    .font(Theme.font(Theme.Role.body))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                // ⌘Z is Edit ▸ Undo's, through the window's undo manager.
                Button("Undo") { model.undoDictionaryChange() }
                    .buttonStyle(.borderless)
                    .fontWeight(.semibold)
                Button {
                    model.dismissDictionaryChange()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.inkTertiary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Dismiss")
            }
            .padding(.leading, Theme.Space.s16)
            .padding(.trailing, Theme.Space.s12)
            .padding(.vertical, Theme.Space.s8)
            // Opaque, not glass: it floats over rows of text, and a confirmation
            // has to read on any of them.
            .background(Capsule(style: .continuous).fill(Theme.surfaceRaised))
            .overlay(Capsule(style: .continuous).strokeBorder(Theme.hairlineStrong, lineWidth: 1))
            .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
            .padding(.bottom, Theme.Space.s20)
            .frame(maxWidth: 560)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task(id: change.id) {
                try? await Task.sleep(for: .seconds(DictionaryList.undoBarSeconds))
                if model.dictionaryLastChange?.id == change.id {
                    model.dismissDictionaryChange()
                }
            }
        }
    }
}

// MARK: - review pieces

/// A review group: a section title with its count, one sentence of why, then
/// hairline-separated rows. No card around it — depth is hairlines (§1.7).
private struct ReviewGroup<Content: View, Accessory: View>: View {
    let title: String
    let count: Int?
    let detail: String
    @ViewBuilder var content: Content
    @ViewBuilder var accessory: Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s8) {
                Text(title)
                    .font(Theme.font(Theme.Role.sectionTitle))
                    .foregroundStyle(Theme.ink)
                if let count {
                    Text("\(count)")
                        .font(Theme.font(Theme.Role.sectionTitle))
                        .monospacedDigit()
                        .foregroundStyle(Theme.inkTertiary)
                }
                Spacer(minLength: Theme.Space.s16)
                accessory
            }
            Text(detail)
                .font(Theme.font(Theme.Role.body))
                .foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 620, alignment: .leading)
                .padding(.top, Theme.Space.s4)
                .padding(.bottom, Theme.Space.s8)
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .overlay(alignment: .top) {
                Rectangle().fill(Theme.hairline).frame(height: 1)
            }
        }
        .padding(.bottom, Theme.Space.s32)
    }
}

extension ReviewGroup where Accessory == EmptyView {
    init(title: String, count: Int?, detail: String, @ViewBuilder content: () -> Content) {
        self.init(title: title, count: count, detail: detail, content: content,
                  accessory: { EmptyView() })
    }
}

/// One decision: the term and where it came from, the evidence underneath,
/// the choices on the right.
private struct ReviewRow<Detail: View, Actions: View>: View {
    let title: String
    let tag: String?
    @ViewBuilder var detail: Detail
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.s16) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s8) {
                    Text(title)
                        .font(Theme.font(Theme.Role.rowTitle))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    if let tag {
                        Text(tag)
                            .font(Theme.font(Theme.Role.caption))
                            .tracking(Theme.Role.caption.tracking)
                            .foregroundStyle(Theme.inkTertiary)
                            .lineLimit(1)
                    }
                }
                detail
            }
            Spacer(minLength: Theme.Space.s16)
            HStack(spacing: Theme.Space.s8) {
                actions
            }
            .controlSize(.small)
        }
        .padding(.vertical, Theme.Space.s12)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.hairline).frame(height: 1)
        }
    }
}

private struct DetailLine: View {
    let text: String
    let mono: Bool

    init(_ text: String, mono: Bool = false) {
        self.text = text
        self.mono = mono
    }

    var body: some View {
        Text(text)
            .font(Theme.font(mono ? Theme.Role.mono : Theme.Role.caption))
            .foregroundStyle(Theme.inkSecondary)
            .lineLimit(1)
            .truncationMode(.middle)
    }
}

/// What the recognizer hears, as a chip (§1.4: machine text, quoted). A
/// flagged chip is an everyday word the term rewrites; it says so in the
/// `attention` ink, never a fill (§1.6).
private struct WordChip: View {
    let phrase: String
    let flagged: Bool

    init(_ phrase: String, flagged: Bool = false) {
        self.phrase = phrase
        self.flagged = flagged
    }

    var body: some View {
        HStack(spacing: 3) {
            if flagged {
                Circle()
                    .fill(Theme.attention)
                    .frame(width: 5, height: 5)
            }
            Text("“\(phrase)”")
                .font(Theme.font(Theme.Role.caption))
                .foregroundStyle(flagged ? Theme.ink : Theme.inkSecondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, Theme.Space.s2)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                .fill(Theme.fillSubtle)
        )
        .help(flagged ? "An everyday word: Wisprit changes it every time you say it" : "")
    }
}

private struct HeaderButton: View {
    let title: String
    let symbol: String
    let action: () -> Void

    init(_ title: String, symbol: String, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.s4) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
                Text(title)
                    .font(Theme.font(Theme.Role.caption))
            }
            .foregroundStyle(Theme.inkSecondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
    }
}

// MARK: - one term

private struct TermRow: View {
    let row: DictionaryRow
    /// Lowercased everyday-word phrases on this row.
    let flagged: Set<String>
    let isHovered: Bool
    let edit: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.s12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s8) {
                    Text(row.term)
                        .font(Theme.font(Theme.Role.rowTitle))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    SourceTag(row: row)
                }
                hearsLine
            }
            Spacer(minLength: Theme.Space.s16)
            // Hover swaps the stats for the row's actions in the same slot, so
            // nothing shifts and the numbers sit on the right edge.
            ZStack(alignment: .trailing) {
                usage.opacity(isHovered ? 0 : 1)
                controls
            }
        }
        .padding(.vertical, 9)
        .padding(.horizontal, Theme.Space.s8)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                .fill(isHovered ? Theme.fillHover : Color.clear)
        )
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 1)
                .padding(.horizontal, Theme.Space.s8)
                .opacity(isHovered ? 0 : 1)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: edit)
        .contextMenu {
            Button("Edit…", action: edit)
            Button("Delete", role: .destructive, action: delete)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Edit", edit)
        .accessibilityAction(named: "Delete", delete)
    }

    private var hearsLine: some View {
        let chips = DictionaryList.chips(row.phrases)
        return HStack(spacing: Theme.Space.s4) {
            if chips.visible.isEmpty {
                Text(DictionaryList.noPhrases)
                    .font(Theme.font(Theme.Role.caption))
                    .foregroundStyle(Theme.inkTertiary)
            }
            ForEach(Array(chips.visible.enumerated()), id: \.offset) { _, phrase in
                WordChip(phrase, flagged: flagged.contains(phrase.lowercased()))
            }
            if chips.overflow > 0 {
                Text("+\(chips.overflow)")
                    .font(Theme.font(Theme.Role.caption))
                    .foregroundStyle(Theme.inkTertiary)
                    .help(chips.hidden.map { "“\($0)”" }.joined(separator: ", "))
            }
        }
    }

    private var usage: some View {
        let usage = DictionaryList.usage(row)
        return VStack(alignment: .trailing, spacing: 3) {
            if let count = usage.count {
                Text(count)
                    .font(Theme.font(Theme.Role.caption))
                    .monospacedDigit()
                    .foregroundStyle(Theme.inkSecondary)
            }
            if let date = usage.date {
                Text(date)
                    .font(Theme.font(Theme.Role.caption))
                    .foregroundStyle(Theme.inkTertiary)
            }
        }
        .lineLimit(1)
        .frame(width: 104, alignment: .trailing)
        .help(usage.help ?? "")
    }

    /// Present but invisible until hover (the context menu and the
    /// accessibility actions carry the same two actions without it).
    private var controls: some View {
        HStack(spacing: 0) {
            Button(action: edit) {
                Image(systemName: "pencil")
                    .frame(width: 24, height: 24)
            }
            .help("Edit")
            Button(action: delete) {
                Image(systemName: "trash")
                    .frame(width: 24, height: 24)
            }
            .help("Delete")
        }
        .buttonStyle(.borderless)
        .font(.system(size: 12))
        .foregroundStyle(Theme.inkSecondary)
        .opacity(isHovered ? 1 : 0)
        .allowsHitTesting(isHovered)
        .accessibilityHidden(true)
    }
}

/// Where the term came from, in plain words. The user's own entries say so
/// quietly; the ones Wisprit wrote carry a mark, because those are the ones a
/// reader may want to check.
private struct SourceTag: View {
    let row: DictionaryRow

    var body: some View {
        let tag = DictionaryList.tag(for: row)
        HStack(spacing: 3) {
            if let symbol = tag.symbol {
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .semibold))
            }
            Text(tag.title)
                .font(Theme.font(Theme.Role.caption))
                .tracking(Theme.Role.caption.tracking)
        }
        .foregroundStyle(tag.symbol == nil ? Theme.inkTertiary : Theme.inkSecondary)
        .lineLimit(1)
    }
}

// MARK: - add / edit sheet

/// Every write goes through `DictionaryEditor.save`, which plans merge-vs-
/// rebuild before touching the file — and this sheet says which one it is
/// going to be *before* the user presses Save, because a rebuild restarts
/// `learned_at` and `hit_count`. It also says when a phrase is an everyday
/// word, before that word starts being rewritten everywhere.
private struct TermSheet: View {
    let original: DictionaryRow?
    let isEveryday: (String) -> Bool
    let onSave: (String, [String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var term: String
    @State private var hear: String

    init(original: DictionaryRow?, isEveryday: @escaping (String) -> Bool,
         onSave: @escaping (String, [String]) -> Void) {
        self.original = original
        self.isEveryday = isEveryday
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

            field("Write it as") {
                TextField("Sharique", text: $term)
                    .textFieldStyle(.plain)
                    .font(Theme.font(Theme.Role.body))
                    .foregroundStyle(Theme.ink)
            }

            field("When Wisprit hears (separate with commas)") {
                TextField("shariq, sharik", text: $hear, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Theme.font(Theme.Role.body))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2...4)
            }

            preview

            if let warning = DictionaryList.everydayWarning(term: term, hear: phrases,
                                                            isEveryday: isEveryday) {
                note(warning)
            }
            if let warning = DictionaryList.warning(for: plan) {
                note(warning)
            }

            Spacer(minLength: 0)

            HStack(spacing: Theme.Space.s8) {
                Spacer(minLength: 0)
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(original == nil ? "Add" : "Save") {
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

    private func note(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s4) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(Theme.attention)
            Text(text)
                .font(Theme.font(Theme.Role.caption))
                .tracking(Theme.Role.caption.tracking)
                .foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
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

// MARK: - snippets

/// Snippets, as a sheet off the list header: say the trigger, Wisprit types
/// the saved text. List and form share the sheet rather than stacking a
/// second sheet on it.
private struct SnippetsSheet: View {
    @ObservedObject var model: WispritWindowModel

    @Environment(\.dismiss) private var dismiss
    @State private var editing: SnippetEdit?
    @State private var pendingDelete: WispritWindowModel.SnippetRow?

    private struct SnippetEdit: Identifiable {
        var row: WispritWindowModel.SnippetRow?
        var id: String { row?.id ?? "new" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s12) {
            if let editing {
                SnippetForm(original: editing.row,
                            onCancel: { self.editing = nil },
                            onSave: { trigger, expansion in
                                let ok = model.saveSnippet(original: editing.row,
                                                           trigger: trigger,
                                                           expansion: expansion)
                                if ok { self.editing = nil }
                                return ok
                            })
            } else {
                list
            }
        }
        .padding(Theme.Space.s20)
        .frame(width: 520, height: 460)
        .background(Theme.surface)
        .alert("Delete this snippet?",
               isPresented: Binding(get: { pendingDelete != nil },
                                    set: { if !$0 { pendingDelete = nil } }),
               presenting: pendingDelete) { row in
            Button("Delete", role: .destructive) { model.deleteSnippet(row.trigger) }
            Button("Cancel", role: .cancel) {}
        } message: { row in
            Text("Saying “\(row.trigger)” will no longer insert the saved text.")
        }
        .onAppear { model.reloadSnippets() }
    }

    @ViewBuilder
    private var list: some View {
        Text("Snippets")
            .font(Theme.font(Theme.Role.sectionTitle))
            .foregroundStyle(Theme.ink)
        Text("Say the trigger and Wisprit types the saved text — signatures, addresses, links.")
            .font(Theme.font(Theme.Role.body))
            .foregroundStyle(Theme.inkSecondary)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if model.snippetRows.isEmpty {
                    Text("No snippets yet. Add one for anything you say often.")
                        .font(Theme.font(Theme.Role.body))
                        .foregroundStyle(Theme.inkTertiary)
                        .padding(.vertical, Theme.Space.s12)
                }
                ForEach(model.snippetRows) { row in
                    HStack(alignment: .center, spacing: Theme.Space.s12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.trigger)
                                .font(Theme.font(Theme.Role.rowTitle))
                                .foregroundStyle(Theme.ink)
                            Text(row.expansion)
                                .font(Theme.font(Theme.Role.caption))
                                .foregroundStyle(Theme.inkSecondary)
                                .lineLimit(2)
                        }
                        Spacer(minLength: Theme.Space.s8)
                        Button("Edit") { editing = SnippetEdit(row: row) }
                            .buttonStyle(.borderless)
                        Button("Delete", role: .destructive) { pendingDelete = row }
                            .buttonStyle(.borderless)
                    }
                    .controlSize(.small)
                    .padding(.vertical, Theme.Space.s8)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(Theme.hairline).frame(height: 1)
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
        HStack {
            Button {
                editing = SnippetEdit(row: nil)
            } label: {
                Label("Add Snippet", systemImage: "plus")
            }
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
    }
}

private struct SnippetForm: View {
    let original: WispritWindowModel.SnippetRow?
    let onCancel: () -> Void
    let onSave: (String, String) -> Bool

    @State private var trigger: String
    @State private var expansion: String

    init(original: WispritWindowModel.SnippetRow?, onCancel: @escaping () -> Void,
         onSave: @escaping (String, String) -> Bool) {
        self.original = original
        self.onCancel = onCancel
        self.onSave = onSave
        _trigger = State(initialValue: original?.trigger ?? "")
        _expansion = State(initialValue: original?.expansion ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s12) {
            Text(original == nil ? "Add a snippet" : "Edit “\(original?.trigger ?? "")”")
                .font(Theme.font(Theme.Role.sectionTitle))
                .foregroundStyle(Theme.ink)
            TextField("Trigger (what you say)", text: $trigger)
                .textFieldStyle(.roundedBorder)
            TextField("Text (what Wisprit types)", text: $expansion, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(4...10)
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save") { _ = onSave(trigger, expansion) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || expansion.isEmpty)
            }
        }
    }
}

// MARK: - personal details

/// Four NAMED fields, always all four, in a fixed order — so a set field and
/// an unset one are told apart by their value, never by their absence. A
/// field is committed on Return, not on every keystroke, so a half-typed
/// address is never stored.
private struct PersonalDetailsSheet: View {
    @ObservedObject var model: WispritWindowModel

    @Environment(\.dismiss) private var dismiss
    @State private var drafts: [String: String] = [:]
    @State private var errors: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s12) {
            Text("Personal details")
                .font(Theme.font(Theme.Role.sectionTitle))
                .foregroundStyle(Theme.ink)
            // The second sentence is the honest disclosure of the rule's
            // conditionality. Without it the behaviour is inexplicable.
            Text("Say “my email” on its own and Wisprit types the value. "
                 + "Mid-sentence it only expands when you’re handing the value "
                 + "over — “I need to check my email” stays as you said it. "
                 + "What Wisprit types goes into whatever app you’re in, and "
                 + "into your dictation history.")
                .font(Theme.font(Theme.Role.body))
                .foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(model.identityRows) { row in
                    identityRow(row)
                }
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Done") {
                    // Return commits a field; Done commits whatever is typed.
                    for row in model.identityRows where drafts[row.id] != nil
                        && drafts[row.id] != row.value {
                        commit(row)
                    }
                    if errors.isEmpty { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.Space.s20)
        .frame(width: 560, height: 440)
        .background(Theme.surface)
        .onAppear { model.reloadIdentity() }
    }

    @ViewBuilder
    private func identityRow(_ row: WispritWindowModel.IdentityRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.label)
                        .font(Theme.font(Theme.Role.rowTitle))
                        .foregroundStyle(Theme.ink)
                    Text(row.spokenTrigger)
                        .font(Theme.font(Theme.Role.caption))
                        .foregroundStyle(Theme.inkSecondary)
                }
                .frame(width: 150, alignment: .leading)
                TextField(row.placeholder, text: draft(row))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { commit(row) }
                if !row.value.isEmpty {
                    Button("Clear", role: .destructive) {
                        model.clearIdentity(row.slot)
                        drafts[row.id] = ""
                        errors[row.id] = nil
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
            }
            .padding(.vertical, Theme.Space.s8)
            if let reason = errors[row.id] {
                Text(reason)
                    .font(Theme.font(Theme.Role.caption))
                    .foregroundStyle(Theme.critical)
            }
            // Email only, only while unset, and it fills the DRAFT — never the
            // store. The user still has to press Return to save it.
            if row.slot == .email, row.value.isEmpty,
               (drafts[row.id] ?? "").isEmpty, let suggestion = model.suggestedEmail {
                HStack(spacing: Theme.Space.s8) {
                    Button("Use \(suggestion)") { drafts[row.id] = suggestion }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                    Text("found in your git config")
                        .font(Theme.font(Theme.Role.caption))
                        .foregroundStyle(Theme.inkSecondary)
                    Button("Dismiss") { model.dismissEmailSuggestion() }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                }
            }
        }
    }

    private func draft(_ row: WispritWindowModel.IdentityRow) -> Binding<String> {
        Binding(get: { drafts[row.id] ?? row.value },
                set: { drafts[row.id] = $0 })
    }

    /// Normalize → validate → store, then write the NORMALIZED string back into
    /// the field, so what the user sees is exactly what will be typed.
    private func commit(_ row: WispritWindowModel.IdentityRow) {
        let value = drafts[row.id] ?? row.value
        switch model.saveIdentity(row.slot, value: value) {
        case .saved(let normalized):
            drafts[row.id] = normalized
            errors[row.id] = nil
        case .cleared:
            drafts[row.id] = ""
            errors[row.id] = nil
        case .rejected(let reason):
            errors[row.id] = reason
        }
    }
}

// MARK: - pure presentation

/// The toolbar filter. Needs review is first: it is where the page opens
/// whenever anything is waiting.
enum DictionaryFilter: String, CaseIterable, Identifiable, Equatable, Sendable {
    case review, all, learned, added

    var id: String { rawValue }

    var title: String {
        switch self {
        case .review: return "Review"
        case .all: return "All"
        case .learned: return "Learned"
        case .added: return "Added"
        }
    }
}

/// The sort menu. Every option is a field the store already persists — there
/// is no "Starred first", because nothing persists a star.
enum DictionarySort: String, CaseIterable, Identifiable, Equatable, Sendable {
    case alphabetical, mostUsed, recentlyUsed, recentlyAdded

    var id: String { rawValue }

    var title: String {
        switch self {
        case .alphabetical: return "A–Z"
        case .mostUsed: return "Most used"
        case .recentlyUsed: return "Recently used"
        case .recentlyAdded: return "Recently added"
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

/// Everything the Dictionary page *decides*, as functions of values: which rows
/// are shown and in what order, what each row says, what the sheet warns
/// about. None of it needs a window, so all of it is asserted in
/// `DictionaryPageTests` rather than eyeballed.
enum DictionaryList {

    static let sheetWidth: Double = 440
    static let sheetHeight: Double = 360
    /// Heard phrases shown before the list collapses to `+N`.
    static let maxChips = 4
    /// How long the inline Undo stays up. ⌘Z works for as long as the window's
    /// undo stack keeps it.
    static let undoBarSeconds: Double = 8

    static let noPhrases = "listens only for its own spelling"
    static let previewPlaceholder = "add a phrase to see the correction"

    /// The one consequence of an edit the user cannot undo by editing again
    /// (Undo can, but only right away).
    static let rebuildWarning =
        "Renaming or removing a phrase resets this term's learn date and use count."

    static let suspectExplanation =
        "Cleaning them up folds each one back into the word it is a spelling of. "
        + "Your own entries are left alone, and a backup is written first."

    // MARK: rows

    static func items(_ rows: [DictionaryRow], search: String, sort: DictionarySort,
                      filter: DictionaryFilter = .all) -> [DictionaryListItem] {
        rows.enumerated()
            .filter { included($0.element, in: filter) && $0.element.matches(search) }
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

    /// Learned = Wisprit wrote it; Added = everything else. Needs review is not
    /// a row filter — it has its own content.
    static func included(_ row: DictionaryRow, in filter: DictionaryFilter) -> Bool {
        switch filter {
        case .all, .review: return true
        case .learned: return row.isLearned
        case .added: return !row.isLearned
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

    /// The tag next to a term: where it came from, or — for a quarantined
    /// entry, which is not vocabulary yet — that it has been heard once.
    static func tag(for row: DictionaryRow) -> (title: String, symbol: String?) {
        if row.isPending { return ("heard once, not active yet", "clock") }
        switch row.kind {
        case .addedByYou, .imported: return (row.kind.label, nil)
        case .learnedAutomatically: return (row.kind.label, "sparkles")
        case .learnedFromSpelling: return (row.kind.label, "character.cursor.ibeam")
        case .learnedFromEdits: return (row.kind.label, "pencil.line")
        }
    }

    static func chips(_ phrases: [String]) -> (visible: [String], overflow: Int, hidden: [String]) {
        guard phrases.count > maxChips else { return (phrases, 0, []) }
        return (Array(phrases.prefix(maxChips)), phrases.count - maxChips,
                Array(phrases.dropFirst(maxChips)))
    }

    /// The right-hand column: how often the term has been used (`hit_count` —
    /// learn events plus the times the listening pass heard it) and when last.
    /// Nothing at all for a term with no record, rather than a column of "0×".
    static func usage(_ row: DictionaryRow, now: Date = Date(),
                      calendar: Calendar = .current,
                      locale: Locale = .current) -> (count: String?, date: String?, help: String?) {
        guard !row.isPending else { return (nil, nil, nil) }
        let count = row.hitCount > 0 ? "used \(row.hitCount)×" : nil
        let date = row.lastUsed.map { shortDate($0, now: now, calendar: calendar, locale: locale) }
        var help: String?
        if row.hitCount > 0 {
            help = "Used \(row.hitCount) time\(row.hitCount == 1 ? "" : "s")"
            if let date { help? += ", last \(date)" }
        }
        return (count, date, help)
    }

    /// "today", "yesterday", "3 days ago" within the week, then "Aug 23",
    /// with the year once it is not this one.
    static func shortDate(_ date: Date, now: Date = Date(), calendar: Calendar = .current,
                          locale: Locale = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "today" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                           to: calendar.startOfDay(for: now)).day ?? 0
        if days == 1 { return "yesterday" }
        if days > 1, days < 7 { return "\(days) days ago" }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        formatter.setLocalizedDateFormatFromTemplate(sameYear ? "MMMd" : "yMMMd")
        return formatter.string(from: date)
    }

    static func countLabel(_ count: Int, filter: DictionaryFilter) -> String {
        let noun = count == 1 ? "term" : "terms"
        switch filter {
        case .learned: return "\(count) learned \(noun)"
        case .added: return "\(count) \(noun) added by you"
        case .all, .review: return "\(count) \(noun)"
        }
    }

    static func snippetsLink(_ count: Int) -> String {
        count == 0 ? "Snippets" : "Snippets (\(count))"
    }

    /// Search over a review item's term and the phrases it is about.
    static func matches(_ query: String, term: String, phrases: [String]) -> Bool {
        DictionaryRow(term: term, hear: phrases).matches(query)
    }

    // MARK: filter and review copy

    static func filterTitle(_ filter: DictionaryFilter, reviewCount: Int) -> String {
        guard filter == .review, reviewCount > 0 else { return filter.title }
        return "\(filter.title) \(reviewCount)"
    }

    static func reviewHeadline(_ count: Int) -> String {
        count == 1 ? "1 thing needs a decision" : "\(count) things need a decision"
    }

    static let reviewSubhead =
        "Nothing changes until you choose, and every choice can be undone."

    static let everydayTitle = "Listens for everyday words"
    static let everydayDetail =
        "Wisprit swaps these words for the term every time you say them, in every app. "
        + "Stop Matching removes just those words — the term keeps working. "
        + "Keep leaves them and stops asking."

    static func everydayAccessibility(_ item: EverydayWordReview) -> String {
        "\(item.term) changes \(DictionaryCopy.quotedList(item.words)) every time you say "
            + (item.words.count == 1 ? "it" : "them")
    }

    static func stopMatchingHelp(_ item: EverydayWordReview) -> String {
        "Stop changing \(DictionaryCopy.quotedList(item.words)) to \(item.term)"
    }

    static let proposalsTitle = "New words from your edits"
    /// The proposals' copy. Pure, so the evidence line is a pinned fact rather
    /// than an eyeballed string.
    static let proposalsExplanation =
        "You typed these over what Wisprit wrote, more than once. Add puts one in "
        + "your dictionary; Dismiss never asks about it again."

    static func proposalsHeadline(_ count: Int) -> String {
        "\(count) new word\(count == 1 ? "" : "s") heard in your edits"
    }

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

    static let pendingTitle = "Heard once"
    static let pendingDetail =
        "Learned from a single spelling, so not used yet. A second time makes it a "
        + "term on its own; Add does that now."

    static func pendingEvidence(_ row: DictionaryRow) -> String {
        guard let heard = row.observations.first else { return "heard once" }
        return "heard as “\(heard)”"
    }

    static let duplicatesTitle = "Listed more than once"
    static let duplicatesDetail =
        "The same term appears twice in your dictionary. Merging keeps every phrase "
        + "from every copy."

    static func duplicateEvidence(_ item: DuplicateReview) -> String {
        "\(item.copies) copies"
    }

    static func suspectHeadline(_ audit: LearnedTermCleanup.Audit) -> String {
        let count = audit.suspects.count
        return "\(count) learned spelling\(count == 1 ? "" : "s") "
            + "look\(count == 1 ? "s" : "") wrong"
    }

    static let allClearTitle = "Nothing needs review"
    static let allClearDetail =
        "Wisprit asks here when a term starts changing everyday words, or when it "
        + "learns something new from you."

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

    /// Said in the sheet, before an everyday word starts being rewritten in
    /// every dictation. The term's own spelling is never flagged: every term
    /// already matches itself.
    static func everydayWarning(term: String, hear: [String],
                                isEveryday: (String) -> Bool) -> String? {
        let own = term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let words = DictionaryEdit.normalize(hear).filter {
            $0.lowercased() != own && isEveryday($0)
        }
        guard !words.isEmpty else { return nil }
        let name = term.trimmingCharacters(in: .whitespacesAndNewlines)
        let verb = words.count == 1 ? "is an everyday word" : "are everyday words"
        return "\(DictionaryCopy.quotedList(words)) \(verb) — Wisprit will change "
            + (words.count == 1 ? "it" : "them")
            + " to \(name.isEmpty ? "the term" : name) every time you say "
            + (words.count == 1 ? "it." : "them.")
    }

    // MARK: empty states

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

/// Debug builds only: lets `Wisprit render-window dictionary` show the states
/// a read-only render cannot reach by clicking — another filter, a sort, a
/// search, the undo confirmation (a sample; nothing is written). Release
/// builds compile it to nothing.
///
///     WISPRIT_RENDER_DICTIONARY_FILTER=review|all|learned|added
///     WISPRIT_RENDER_DICTIONARY_SORT=alphabetical|mostUsed|recentlyUsed|recentlyAdded
///     WISPRIT_RENDER_DICTIONARY_SEARCH=<text>
///     WISPRIT_RENDER_DICTIONARY_UNDO=1
enum DictionaryRenderHook {
    static var filter: DictionaryFilter? {
        #if DEBUG
        return value("FILTER").flatMap(DictionaryFilter.init(rawValue:))
        #else
        return nil
        #endif
    }

    static var sort: DictionarySort {
        #if DEBUG
        return value("SORT").flatMap(DictionarySort.init(rawValue:)) ?? .alphabetical
        #else
        return .alphabetical
        #endif
    }

    @MainActor
    static func apply(to model: WispritWindowModel) {
        #if DEBUG
        if let search = value("SEARCH") { model.dictionarySearch = search }
        if value("UNDO") == "1" {
            model.dictionaryLastChange = DictionaryChange(
                summary: "Ploy no longer changes “play”, “employ” and “place”.",
                actionName: "Stop Matching", before: [], after: [])
        }
        #endif
    }

    #if DEBUG
    private static func value(_ key: String) -> String? {
        ProcessInfo.processInfo.environment["WISPRIT_RENDER_DICTIONARY_\(key)"]
    }
    #endif
}
#endif
