#if os(macOS)
import AppKit
import SwiftUI
import WispritMacUI

/// Dictations — the page the window opens on (the `home` tab).
///
/// A notebook of everything the user said: one quiet stat line, a try-it
/// strip, every dictation grouped by day with the icon of the app it went to,
/// and a row for every hold that produced nothing. Selecting a row opens the
/// inspector: what was heard against what was written, Paste again, Copy,
/// Teach, the timing, and where it ran.
///
/// Rules this file keeps:
///
///  * **Every decision is in `DictationsModel`** (matching, misses, chips,
///    search, grouping, copy). This file lays it out; `HomeSource` is the only
///    mapping seam.
///  * **Orange means the mic is live, nowhere else.** Selection is a value
///    step, the primary button is ink, and the try-it field's underline is
///    the one hot mark — drawn only while audio is actually open.
///  * **The keyboard works without a mouse.** ↑/↓ move the selection, ↵
///    pastes again, ⌘C copies, typing filters, ⌘F focuses search, Esc
///    clears the filter and then the selection.
struct HomePage: View {
    @ObservedObject var model: WispritWindowModel

    var body: some View {
        DictationsPage(model: model, feed: model.dictationsFeed)
    }
}

/// Where keyboard focus is on this page.
private enum DictationsFocus: Hashable {
    case list, search, tryIt
}

private struct DictationsPage: View {
    @ObservedObject var model: WispritWindowModel
    @ObservedObject var feed: DictationsFeed

    @FocusState private var focus: DictationsFocus?

    /// The display calendar, read once per render pass — `DictationsModel`'s
    /// contract is that the caller says what "today" means.
    private var calendar: Calendar { .current }

    var body: some View {
        let visible = DictationsModel.filter(feed.entries, query: model.historySearch)
        HubPage(title: WispritWindowModel.Tab.home.title) {
            DictationsSearchField(text: $model.historySearch, focus: $focus) {
                // ↓ or ↵ in the field hands the keyboard to the list.
                if feed.selection == nil || !visible.contains(where: { $0.id == feed.selection }) {
                    feed.selection = visible.first?.id
                }
                focus = .list
            }
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                StatLine(parts: DictationsModel.statParts(
                    stats: model.homeStats,
                    secondsToText: feed.secondsToText,
                    decimal: { HomeSource.decimal($0) }))
                TryItStrip(text: $model.playgroundText,
                           focus: $focus,
                           hotkey: model.hotkey,
                           isListening: model.sessionState == .recording)
                    .padding(.top, Theme.Space.s12)
                    .padding(.bottom, Theme.Space.s4)
                list(visible)
            }
        }
        .inspector(isPresented: inspectorShown(visible)) {
            Group {
                if let entry = feed.selectedEntry, visible.contains(where: { $0.id == entry.id }) {
                    DictationInspector(entry: entry, model: model, feed: feed)
                } else {
                    Color.clear
                }
            }
            .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
        }
        .background { shortcuts }
        // Typing a search widens the feed to everything retained (and
        // clearing it narrows back to the page), through the same reload the
        // tick uses.
        .onChange(of: model.historySearch) { _, _ in model.loadHistory() }
        // The window's own open already asks for the stats; this covers the
        // page being reached some other way.
        .task {
            if model.homeStats == nil { model.refreshHomeStats() }
        }
    }

    /// Open while the selected row is on screen. A filter that hides it
    /// closes the inspector without forgetting the selection, so clearing the
    /// filter brings it back.
    private func inspectorShown(_ visible: [DictationEntry]) -> Binding<Bool> {
        let shown = feed.selection.map { id in visible.contains { $0.id == id } } ?? false
        return Binding(get: { shown },
                       set: { if !$0 { feed.selection = nil } })
    }

    /// ⌘F. A zero-size button rather than a menu item: the shortcut belongs
    /// to this page only, and the search field it focuses lives in the
    /// toolbar this page owns.
    private var shortcuts: some View {
        Button("Find") { focus = .search }
            .keyboardShortcut("f", modifiers: .command)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }

    // MARK: - the list

    @ViewBuilder
    private func list(_ visible: [DictationEntry]) -> some View {
        if visible.isEmpty {
            emptyState
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.Space.s2) {
                        ForEach(DictationsModel.days(visible, now: Date(), calendar: calendar)) { day in
                            DayHeader(title: day.title)
                            ForEach(day.entries) { entry in
                                DictationRowView(entry: entry,
                                                 isSelected: feed.selection == entry.id,
                                                 calendar: calendar)
                                    .id(entry.id)
                                    .onTapGesture {
                                        feed.selection = entry.id
                                        focus = .list
                                    }
                                    .contextMenu { rowMenu(entry) }
                            }
                        }
                        loadMore
                    }
                    .padding(.bottom, Theme.Space.s24)
                }
                .scrollIndicators(.automatic)
                // Rows fade out under the try-it strip instead of being sliced
                // off at a hard edge. At rest the fade only covers the first
                // day header's top padding.
                .mask {
                    VStack(spacing: 0) {
                        LinearGradient(colors: [.clear, .black],
                                       startPoint: .top, endPoint: .bottom)
                            .frame(height: Theme.Space.s12)
                        Color.black
                    }
                }
                .focusable()
                .focused($focus, equals: .list)
                .focusEffectDisabled()
                .onKeyPress(.upArrow) { move(-1, in: visible) }
                .onKeyPress(.downArrow) { move(1, in: visible) }
                .onKeyPress(.return) { pasteSelected() }
                .onKeyPress(.escape) { escape() }
                .onKeyPress(.delete) { backspaceFilter() }
                .onKeyPress(phases: .down) { typeToFilter($0) }
                .onCopyCommand { copySelected() }
                .onChange(of: feed.selection) { _, id in
                    guard let id else { return }
                    proxy.scrollTo(id)
                }
                .onAppear {
                    // A selection made before the list existed (a reopened
                    // window, `render-window --select`) is still worth seeing.
                    guard let id = feed.selection else { return }
                    proxy.scrollTo(id, anchor: .center)
                }
                .task {
                    // Give the list the keyboard so ↑/↓ work without a click —
                    // but only after `MainWindowController.raise` has finished
                    // clearing the first responder (it does so up to a quarter
                    // second after the window shows), and only if nothing else
                    // took it meanwhile. The list is a plain focus target, not
                    // a text field, so nothing scrolls to reveal it.
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    if focus == nil { focus = .list }
                }
            }
        }
    }

    @ViewBuilder
    private func rowMenu(_ entry: DictationEntry) -> some View {
        if let record = entry.record {
            if model.canPasteAtCursor {
                Button("Paste Again") { model.pasteAgain(record) }
                    .disabled(model.sessionState != .idle)
            }
            Button("Copy") { model.copy(record.text) }
        }
    }

    @ViewBuilder
    private var loadMore: some View {
        // Only on the unfiltered list: "show older" under a search box would
        // read as though the search had finished.
        if model.historyHasMore && model.historySearch.isEmpty {
            Button("Show older dictations") { model.loadMoreHistory() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .padding(.top, Theme.Space.s16)
                .padding(.leading, Theme.Space.s8)
        }
    }

    // MARK: - keyboard

    private func move(_ step: Int, in visible: [DictationEntry]) -> KeyPress.Result {
        guard let next = DictationsModel.move(feed.selection, by: step, in: visible) else {
            return .ignored
        }
        feed.selection = next
        return .handled
    }

    private var selectedRecord: DictationRecord? { feed.selectedEntry?.record }

    private func pasteSelected() -> KeyPress.Result {
        guard let record = selectedRecord, model.canPasteAtCursor else { return .ignored }
        model.pasteAgain(record)
        return .handled
    }

    private func copySelected() -> [NSItemProvider] {
        guard let record = selectedRecord else { return [] }
        return [NSItemProvider(object: record.text as NSString)]
    }

    /// Esc peels one layer: the filter first, then the selection.
    private func escape() -> KeyPress.Result {
        if !model.historySearch.isEmpty {
            model.historySearch = ""
            return .handled
        }
        if feed.selection != nil {
            feed.selection = nil
            return .handled
        }
        return .ignored
    }

    private func backspaceFilter() -> KeyPress.Result {
        guard !model.historySearch.isEmpty else { return .ignored }
        model.historySearch.removeLast()
        return .handled
    }

    /// Typing while the list has the keyboard filters it, Finder-style, and
    /// the keyboard stays on the list — so the next ↓ and ↵ still work.
    private func typeToFilter(_ press: KeyPress) -> KeyPress.Result {
        guard press.modifiers.isDisjoint(with: [.command, .control, .option]) else { return .ignored }
        let characters = press.characters
        guard !characters.isEmpty,
              characters.unicodeScalars.allSatisfy({ scalar in
                  // Arrow and function keys arrive as private-use scalars.
                  scalar.properties.generalCategory != .privateUse
                      && !CharacterSet.controlCharacters.contains(scalar)
                      && !CharacterSet.newlines.contains(scalar)
              }) else { return .ignored }
        // A leading space is not a search.
        if model.historySearch.isEmpty, characters.allSatisfy(\.isWhitespace) { return .ignored }
        model.historySearch += characters
        return .handled
    }

    // MARK: - empty states

    @ViewBuilder
    private var emptyState: some View {
        if !feed.hasLoaded {
            // The first read has not landed; an empty state over a full
            // history for one frame is worse than nothing.
            Color.clear
        } else if !model.historySearch.isEmpty {
            EmptyBlock(symbol: "magnifyingglass", title: "No matches") {
                Text("Nothing you said contains that.")
                    .font(Theme.font(Theme.Role.body))
                    .foregroundStyle(Theme.inkSecondary)
            }
        } else {
            EmptyBlock(symbol: "text.bubble", title: nil) {
                HStack(spacing: Theme.Space.s8) {
                    Text("Hold")
                    KeycapView(symbol: keycapSymbol, label: keycapLabel, size: .small)
                    Text("anywhere and say something.")
                }
                .font(Theme.font(Theme.Role.body))
                .foregroundStyle(Theme.ink)
                Text("It shows up here, and nowhere else.")
                    .font(Theme.font(Theme.Role.body))
                    .foregroundStyle(Theme.inkSecondary)
                if !model.historyEnabled {
                    // Otherwise the line above is a promise the app will not
                    // keep: nothing dictated is being saved.
                    Text("Saving dictations is switched off in Settings.")
                        .font(Theme.font(Theme.Role.caption))
                        .tracking(Theme.Role.caption.tracking)
                        .foregroundStyle(Theme.inkTertiary)
                        .padding(.top, Theme.Space.s4)
                }
            }
        }
    }

    private var keycapSymbol: String { model.hotkey == .fn ? "globe" : "option" }
    private var keycapLabel: String { model.hotkey == .fn ? "fn" : "⌥" }
}

// MARK: - search

/// The toolbar's search field. Same look as the shared `SearchField`, with
/// focus this page can drive: ⌘F lands here, ↓ and ↵ hand the keyboard to the
/// list, Esc clears.
private struct DictationsSearchField: View {
    @Binding var text: String
    var focus: FocusState<DictationsFocus?>.Binding
    let toList: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.s8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Theme.inkTertiary)
            TextField("Search what you said", text: $text)
                .textFieldStyle(.plain)
                .font(Theme.font(Theme.Role.body))
                .foregroundStyle(Theme.ink)
                .focused(focus, equals: .search)
                .onSubmit(toList)
                .onKeyPress(.downArrow) {
                    toList()
                    return .handled
                }
                .onKeyPress(.escape) {
                    guard !text.isEmpty else {
                        toList()
                        return .handled
                    }
                    text = ""
                    return .handled
                }
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.inkTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, Theme.Space.s8)
        .frame(width: SearchField.width, height: Theme.Size.hitTarget)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(Theme.fillSubtle)
        )
        .help("Search what you said (⌘F)")
    }
}

// MARK: - the header

/// "Today 27 words · 123 wpm · 0.20 s to text · 25,934 all time" — values in
/// ink, labels quiet, one line.
private struct StatLine: View {
    let parts: [DictationsModel.StatPart]

    var body: some View {
        if parts.isEmpty {
            // Reserve the line so the list does not jump when it lands.
            Text(" ").font(Theme.font(Theme.Role.body)).hidden()
        } else {
            // A narrow window drops parts from the end — never a word cut in
            // half. "Today" always stays.
            // (`ViewThatFits` compares each option's IDEAL width; pinning
            // them with `fixedSize` would make the full line the page's
            // minimum width and grow the window.)
            ViewThatFits(in: .horizontal) {
                ForEach((1...parts.count).reversed(), id: \.self) { count in
                    Text(line(Array(parts.prefix(count))))
                }
            }
            .font(Theme.font(Theme.Role.body).monospacedDigit())
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(parts.map { $0.lead + $0.value + $0.label }.joined(separator: ", "))
        }
    }

    private func line(_ parts: [DictationsModel.StatPart]) -> AttributedString {
        var out = AttributedString()
        for (index, part) in parts.enumerated() {
            if index > 0 { out += run("  ·  ", Theme.inkQuaternary) }
            out += run(part.lead, Theme.inkTertiary)
            var value = run(part.value, Theme.ink)
            value.font = Theme.font(Theme.Role.body).monospacedDigit().weight(.medium)
            out += value
            out += run(part.label, Theme.inkTertiary)
        }
        return out
    }

    private func run(_ text: String, _ color: Color) -> AttributedString {
        var run = AttributedString(text)
        run.foregroundColor = color
        return run
    }
}

// MARK: - try it here

/// A one-line field to dictate into without leaving the window. It never
/// opens the microphone itself — the key does, wherever the cursor is — so
/// this is only a place for the text to land. The underline is the page's one
/// orange mark, and it is drawn only while audio is open.
private struct TryItStrip: View {
    @Binding var text: String
    var focus: FocusState<DictationsFocus?>.Binding
    let hotkey: WindowSettings.HotkeyOption
    let isListening: Bool

    var body: some View {
        HStack(spacing: Theme.Space.s12) {
            KeycapView(symbol: hotkey == .fn ? "globe" : "option",
                       label: hotkey == .fn ? "fn" : "⌥",
                       size: .small,
                       isHeld: isListening && focus.wrappedValue == .tryIt)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(Theme.font(Theme.Role.body))
                .foregroundStyle(Theme.ink)
                .focused(focus, equals: .tryIt)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
            if !text.isEmpty {
                Button("Clear") { text = "" }
                    .buttonStyle(.plain)
                    .font(Theme.font(Theme.Role.caption))
                    .foregroundStyle(Theme.inkTertiary)
            }
        }
        .padding(.leading, Theme.Space.s8)
        .padding(.trailing, Theme.Space.s12)
        .frame(height: 40)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous)
                .fill(Theme.groundRecessed)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous)
                .strokeBorder(focus.wrappedValue == .tryIt ? Theme.hairlineStrong : Theme.hairline,
                              lineWidth: 1)
        )
        .overlay(alignment: .bottom) {
            if isListening && focus.wrappedValue == .tryIt {
                Rectangle()
                    .fill(Theme.hot(.liveTranscriptRow))
                    .frame(height: 2)
                    .padding(.horizontal, Theme.Space.s12)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Try it here")
    }

    private var prompt: String {
        "Try it here: click, hold the key, talk"
    }
}

// MARK: - rows

/// `captionEmph`, uppercase, `inkTertiary`.
private struct DayHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(Theme.font(Theme.Role.captionEmph))
            .tracking(Theme.Role.captionEmph.tracking)
            .textCase(.uppercase)
            .foregroundStyle(Theme.inkTertiary)
            .padding(.top, Theme.Space.s16)
            .padding(.bottom, Theme.Space.s4)
            .padding(.leading, Theme.Space.s8)
            .accessibilityAddTraits(.isHeader)
    }
}

/// One dictation, or one miss.
///
/// Selection is a value step and a hairline — never an accent fill: the row
/// is a record to look at, and the only colour on this page is the live mic.
private struct DictationRowView: View {
    let entry: DictationEntry
    let isSelected: Bool
    let calendar: Calendar

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.s8 + 2) {
            leading
                .frame(width: 18, height: 18)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                title
                HStack(spacing: Theme.Space.s8 - 2) {
                    Text(caption)
                        .font(Theme.font(Theme.Role.caption))
                        .tracking(Theme.Role.caption.tracking)
                        .foregroundStyle(Theme.inkTertiary)
                        .lineLimit(1)
                    ForEach(chips, id: \.self) { ChipView(chip: $0) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Theme.Space.s8 + 2)
        .padding(.vertical, Theme.Space.s8)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                .fill(isSelected ? Theme.fillSubtle : (isHovering ? Theme.fillHover : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                .strokeBorder(isSelected ? Theme.hairlineStrong : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    @ViewBuilder
    private var leading: some View {
        switch entry {
        case .dictation(let record):
            AppIconView(bundleID: record.appBundleID, size: 18)
        case .missed:
            Image(systemName: "waveform.badge.exclamationmark")
                .font(.system(size: 12, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Theme.inkTertiary)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var title: some View {
        switch entry {
        case .dictation(let record):
            Text(record.text)
                .font(Theme.font(Theme.Role.body))
                .foregroundStyle(Theme.ink)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        case .missed:
            Text(MissCopy.rowTitle)
                .font(Theme.font(Theme.Role.body))
                .italic()
                .foregroundStyle(Theme.inkSecondary)
        }
    }

    private var caption: String {
        switch entry {
        case .dictation(let record): return HomeSource.dictationCaption(record, calendar: calendar)
        case .missed(let miss): return HomeSource.missCaption(miss, calendar: calendar)
        }
    }

    private var chips: [DictationChip] {
        entry.record.map(DictationsModel.chips(for:)) ?? []
    }
}

/// A quiet outlined tag — no fill, so it reads on a selected row too.
private struct ChipView: View {
    let chip: DictationChip

    var body: some View {
        Text(chip.rawValue)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Theme.inkSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Theme.hairlineStrong, lineWidth: 1)
            )
    }
}

// MARK: - app identity

/// The icon and name of the app a dictation went to, resolved once per bundle
/// id through LaunchServices. An app that is not installed any more resolves to
/// nothing — the row keeps its slot and shows no icon.
@MainActor
enum AppIdentity {
    struct Resolved {
        let icon: NSImage?
        let name: String?
    }

    private static var cache: [String: Resolved] = [:]

    static func resolve(_ bundleID: String) -> Resolved {
        if let hit = cache[bundleID] { return hit }
        var resolved = Resolved(icon: nil, name: nil)
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            var name = FileManager.default.displayName(atPath: url.path)
            if name.hasSuffix(".app") { name.removeLast(4) }
            resolved = Resolved(icon: NSWorkspace.shared.icon(forFile: url.path), name: name)
        }
        cache[bundleID] = resolved
        return resolved
    }

    static func name(_ bundleID: String?) -> String? {
        bundleID.flatMap { resolve($0).name }
    }
}

private struct AppIconView: View {
    let bundleID: String?
    let size: Double

    var body: some View {
        if let bundleID, let icon = AppIdentity.resolve(bundleID).icon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .help(AppIdentity.name(bundleID) ?? "")
                .accessibilityLabel(AppIdentity.name(bundleID).map { "Sent to \($0)" } ?? "")
        } else {
            Color.clear.frame(width: size, height: size)
        }
    }
}

// MARK: - the inspector

private struct DictationInspector: View {
    let entry: DictationEntry
    @ObservedObject var model: WispritWindowModel
    @ObservedObject var feed: DictationsFeed

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.s16) {
                switch entry {
                case .dictation(let record):
                    DictationDetail(record: record, model: model, feed: feed)
                case .missed(let miss):
                    MissDetail(miss: miss)
                }
            }
            .padding(Theme.Space.s16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // A new row is a new document: no scroll offset, no half-made
        // selection, no open popover carried across.
        .id(entry.id)
    }
}

/// One dictation, in full.
private struct DictationDetail: View {
    let record: DictationRecord
    @ObservedObject var model: WispritWindowModel
    @ObservedObject var feed: DictationsFeed

    @State private var selectedText = ""
    @State private var isTeaching = false
    @State private var copied = false
    @State private var taught: String?

    private var calendar: Calendar { .current }

    private var diff: WordDiff.Result? {
        record.heard.map { WordDiff.diff(heard: $0, written: record.text) }
    }

    var body: some View {
        header
        // Above the text, not under it: a 400-word dictation must not push
        // Paste again below the fold, and buttons that stay put are buttons
        // the hand learns.
        actions
        textBlock
        if let timing = record.timing, !timing.isEmpty {
            InspectorSection(title: "Timing") {
                if let ms = timing.releaseToTextMs {
                    KeyValueRow(label: "Key up → text", value: DictationsModel.duration(ms: ms))
                }
                if let ms = timing.recognizeMs {
                    KeyValueRow(label: "Recognize", value: DictationsModel.duration(ms: ms))
                }
                if let ms = timing.cleanupMs, DictationsModel.cleanupRan(record.ai) {
                    KeyValueRow(label: "Cleanup", value: DictationsModel.duration(ms: ms))
                }
            }
        }
        InspectorSection(title: "Where it ran") {
            KeyValueRow(label: "Speech",
                        value: DictationsModel.speechEngineName(record.engine) + " · on this Mac")
            if let cleanup = DictationsModel.cleanupDescription(record.ai) {
                KeyValueRow(label: "Cleanup",
                            value: DictationsModel.cleanupRan(record.ai)
                                ? cleanup + " · on this Mac" : cleanup)
            }
            if let mic = DictationsModel.micName(record.inputDevice) {
                KeyValueRow(label: "Mic", value: mic)
            }
        }
        Text("Audio is never kept. Only the text stays, on this Mac.")
            .font(Theme.font(Theme.Role.caption))
            .tracking(Theme.Role.caption.tracking)
            .foregroundStyle(Theme.inkTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: Theme.Space.s8 + 2) {
            if record.appBundleID != nil {
                AppIconView(bundleID: record.appBundleID, size: 28)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(AppIdentity.name(record.appBundleID) ?? "Dictation")
                    .font(Theme.font(Theme.Role.rowTitle))
                    .foregroundStyle(Theme.ink)
                Text(InspectorFormat.when(record.date, calendar: calendar)
                     + " · " + HomeSource.words(record.wordCount))
                    .font(Theme.font(Theme.Role.caption))
                    .tracking(Theme.Role.caption.tracking)
                    .foregroundStyle(Theme.inkTertiary)
            }
        }
    }

    @ViewBuilder
    private var textBlock: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s8) {
            if record.heard != nil {
                Picker("Show", selection: $feed.showsHeard) {
                    Text("Heard").tag(true)
                    Text("Written").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
            }
            DiffText(segments: segments, selection: $selectedText)
                .padding(Theme.Space.s12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                        .fill(Theme.groundRecessed)
                )
            Text(changeSummary)
                .font(Theme.font(Theme.Role.caption))
                .tracking(Theme.Role.caption.tracking)
                .foregroundStyle(Theme.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
            if record.delivered == false {
                Text("This was saved but never reached the app. Paste it again to put it there.")
                    .font(Theme.font(Theme.Role.caption))
                    .tracking(Theme.Role.caption.tracking)
                    .foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var segments: [WordDiff.Segment] {
        guard let diff else { return [WordDiff.Segment(record.text, changed: false)] }
        return feed.showsHeard ? diff.heard : diff.written
    }

    private var changeSummary: String {
        guard let diff else { return "What was heard wasn't kept for this one." }
        if diff.isUnchanged { return "Written exactly as heard." }
        let count = diff.changeCount
        return count == 1 ? "1 change, underlined." : "\(count) changes, underlined."
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s8) {
            HStack(spacing: Theme.Space.s8) {
                if model.canPasteAtCursor {
                    Button {
                        model.pasteAgain(record)
                    } label: {
                        ActionLabel(title: "Paste again", hint: "↵")
                    }
                    .buttonStyle(InkButtonStyle(prominent: true))
                    .disabled(model.sessionState != .idle)
                    .help("Put this text back where your cursor was")
                }
                Button {
                    model.copy(record.text)
                    flashCopied()
                } label: {
                    ActionLabel(title: copied ? "Copied" : "Copy", hint: copied ? nil : "⌘C")
                }
                .buttonStyle(InkButtonStyle(prominent: false))
                Button {
                    isTeaching = true
                } label: {
                    ActionLabel(title: "Teach…", hint: nil)
                }
                .buttonStyle(InkButtonStyle(prominent: false))
                .help("Teach Wisprit how to spell a word it got wrong")
                .popover(isPresented: $isTeaching, arrowEdge: .bottom) {
                    TeachPopover(heard: DictationsModel.teachablePhrase(selectedText),
                                 spelling: suggestedSpelling,
                                 teach: { heard, spelling in
                                     model.teach(heard: heard, spelling: spelling)
                                 },
                                 done: { term in
                                     taught = term
                                     isTeaching = false
                                 },
                                 cancel: { isTeaching = false })
                }
            }
            if let taught {
                Label("Added “\(taught)” to your Dictionary.", systemImage: "checkmark")
                    .font(Theme.font(Theme.Role.caption))
                    .foregroundStyle(Theme.positive)
            }
        }
    }

    private var suggestedSpelling: String {
        guard let diff, feed.showsHeard else { return "" }
        return DictationsModel.suggestedSpelling(for: selectedText, diff: diff) ?? ""
    }

    private func flashCopied() {
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            copied = false
        }
    }
}

/// One miss: what happened and what to do, never a Retry — there is no audio.
private struct MissDetail: View {
    let miss: MissedCapture
    private var calendar: Calendar { .current }

    var body: some View {
        let copy = miss.copy
        HStack(alignment: .center, spacing: Theme.Space.s8 + 2) {
            Image(systemName: "waveform.badge.exclamationmark")
                .font(.system(size: 18, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Theme.inkSecondary)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(MissCopy.rowTitle)
                    .font(Theme.font(Theme.Role.rowTitle))
                    .foregroundStyle(Theme.ink)
                Text(subtitle)
                    .font(Theme.font(Theme.Role.caption))
                    .tracking(Theme.Role.caption.tracking)
                    .foregroundStyle(Theme.inkTertiary)
            }
        }
        VStack(alignment: .leading, spacing: Theme.Space.s8) {
            Text(copy.title)
                .font(Theme.font(Theme.Role.sectionTitle))
                .foregroundStyle(Theme.ink)
            Text(copy.explanation)
                .font(Theme.font(Theme.Role.body))
                .foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        InspectorSection(title: "Try this") {
            Text(copy.advice)
                .font(Theme.font(Theme.Role.body))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        InspectorSection(title: "Details") {
            if miss.count > 1 {
                KeyValueRow(label: "Tries", value: "\(miss.count)")
                KeyValueRow(label: "Last hold", value: DictationsModel.heldLength(ms: miss.heldMs))
            } else {
                KeyValueRow(label: "Key held", value: DictationsModel.heldLength(ms: miss.heldMs))
            }
            if let mic = DictationsModel.micName(miss.inputDevice) {
                KeyValueRow(label: "Mic", value: mic)
            }
        }
        Text(MissCopy.noAudioNote)
            .font(Theme.font(Theme.Role.caption))
            .tracking(Theme.Role.caption.tracking)
            .foregroundStyle(Theme.inkTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var subtitle: String {
        guard miss.count > 1 else {
            return InspectorFormat.when(miss.date, calendar: calendar)
                + " · \(DictationsModel.heldLength(ms: miss.heldMs)) of audio"
        }
        let first = HomeSource.time(Date(timeIntervalSince1970: miss.firstTs), calendar: calendar)
        return InspectorFormat.when(miss.date, calendar: calendar)
            + " · \(miss.count) tries since \(first)"
    }
}

private enum InspectorFormat {
    /// "Today at 00:30", "Yesterday at 02:31", "Thursday, 5 Nov at 00:55".
    static func when(_ date: Date, calendar: Calendar) -> String {
        let day = HomeModel.title(for: calendar.startOfDay(for: date), now: Date(), calendar: calendar)
        return "\(day) at \(HomeSource.time(date, calendar: calendar))"
    }
}

private struct InspectorSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s8) {
            Text(title)
                .font(Theme.font(Theme.Role.captionEmph))
                .tracking(Theme.Role.captionEmph.tracking)
                .textCase(.uppercase)
                .foregroundStyle(Theme.inkTertiary)
                .accessibilityAddTraits(.isHeader)
            content
        }
        .padding(.top, Theme.Space.s4)
    }
}

private struct KeyValueRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s12) {
            Text(label)
                .foregroundStyle(Theme.inkTertiary)
                .layoutPriority(1)
            Spacer(minLength: 0)
            Text(value)
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(Theme.font(Theme.Role.caption))
        .accessibilityElement(children: .combine)
    }
}

private struct ActionLabel: View {
    let title: String
    let hint: String?

    var body: some View {
        HStack(spacing: 5) {
            Text(title)
            if let hint {
                Text(hint).opacity(0.55)
            }
        }
    }
}

/// The inspector's buttons. The primary one is ink on surface — the mock's
/// "Paste again ↵" — because orange belongs to the live mic and the accent
/// colour belongs to the sidebar's selection.
private struct InkButtonStyle: ButtonStyle {
    let prominent: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: prominent ? .semibold : .regular))
            .foregroundStyle(prominent ? Theme.surface : Theme.ink)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(prominent ? Theme.ink : Theme.fillSubtle)
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
            .contentShape(Rectangle())
    }
}

// MARK: - teach

/// "When it hears ___, write ___." Saving goes through the same
/// `DictionaryEditor` plan the Dictionary page uses.
private struct TeachPopover: View {
    @State private var heard: String
    @State private var spelling: String
    @State private var note: String?
    let teach: (String, String) -> WispritWindowModel.TeachResult
    let done: (String) -> Void
    let cancel: () -> Void

    init(heard: String, spelling: String,
         teach: @escaping (String, String) -> WispritWindowModel.TeachResult,
         done: @escaping (String) -> Void,
         cancel: @escaping () -> Void) {
        _heard = State(initialValue: heard)
        _spelling = State(initialValue: spelling)
        self.teach = teach
        self.done = done
        self.cancel = cancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s12) {
            Text("Teach a spelling")
                .font(Theme.font(Theme.Role.sectionTitle))
                .foregroundStyle(Theme.ink)
            field("When it hears", text: $heard, prompt: "the word it got wrong")
            field("Write", text: $spelling, prompt: "the right spelling")
            Text(note ?? preview)
                .font(Theme.font(Theme.Role.caption))
                .tracking(Theme.Role.caption.tracking)
                .foregroundStyle(Theme.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Theme.Space.s8) {
                Spacer(minLength: 0)
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Teach", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedSpelling.isEmpty)
            }
            .controlSize(.small)
        }
        .padding(Theme.Space.s16)
        .frame(width: 300)
    }

    private func field(_ label: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s4) {
            Text(label)
                .font(Theme.font(Theme.Role.caption))
                .foregroundStyle(Theme.inkSecondary)
            TextField(label, text: text, prompt: Text(prompt))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .onSubmit(save)
        }
    }

    private var trimmedSpelling: String {
        spelling.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var preview: String {
        let phrase = DictationsModel.teachablePhrase(heard)
        guard !trimmedSpelling.isEmpty else {
            return "Select the word in Heard first, or type it here."
        }
        guard !phrase.isEmpty, phrase.lowercased() != trimmedSpelling.lowercased() else {
            return "“\(trimmedSpelling)” will be added to your Dictionary."
        }
        return "From now on, “\(phrase)” will be written “\(trimmedSpelling)”."
    }

    private func save() {
        switch teach(heard, spelling) {
        case .added(let term):
            done(term)
        case .alreadyKnown(let term):
            note = "Your Dictionary already has that for “\(term)”."
        case .invalid:
            break
        }
    }
}

// MARK: - selectable diff text

/// The inspector's text: selectable (Teach reads the selection), with every
/// changed word underlined. AppKit because SwiftUI's `Text` exposes no
/// selection to read back.
private struct DiffText: NSViewRepresentable {
    let segments: [WordDiff.Segment]
    @Binding var selection: String

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    /// Wraps at exactly the width SwiftUI gave it. `sizeThatFits` is asked
    /// about several widths per pass, and whichever it heard last must not be
    /// the width the text is drawn at.
    final class FittingTextView: NSTextView {
        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            textContainer?.containerSize = NSSize(width: newSize.width,
                                                  height: CGFloat.greatestFiniteMagnitude)
        }
    }

    func makeNSView(context: Context) -> NSTextView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 240, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        let view = FittingTextView(frame: .zero, textContainer: container)
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.delegate = context.coordinator
        view.setAccessibilityLabel("Dictation text")
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.selection = $selection
        let text = attributed
        if view.textStorage?.isEqual(to: text) != true {
            // New text (the other side of the toggle): the old selection
            // means nothing in it. Cleared without reporting from inside the
            // update, then reported on the next turn.
            coordinator.isUpdating = true
            view.textStorage?.setAttributedString(text)
            view.setSelectedRange(NSRange(location: 0, length: 0))
            coordinator.isUpdating = false
            if !selection.isEmpty {
                let binding = $selection
                DispatchQueue.main.async { binding.wrappedValue = "" }
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: NSTextView,
                      context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0,
              let storage = view.textStorage else { return nil }
        // Measured on a scratch layout, so asking about one width never
        // re-wraps the text on screen at that width.
        let probe = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        probe.lineFragmentPadding = 0
        let layout = NSLayoutManager()
        layout.addTextContainer(probe)
        let copy = NSTextStorage(attributedString: storage)
        copy.addLayoutManager(layout)
        layout.ensureLayout(for: probe)
        let height = layout.usedRect(for: probe).height
        return CGSize(width: width, height: ceil(max(height, 16)))
    }

    private var attributed: NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: Self.color(Theme.Token.ink),
            .paragraphStyle: paragraph,
        ]
        let out = NSMutableAttributedString()
        for segment in segments {
            var attributes = base
            if segment.changed {
                attributes[.underlineStyle] = NSUnderlineStyle.thick.rawValue
                attributes[.underlineColor] = Self.color(Theme.Token.positive)
            }
            out.append(NSAttributedString(string: segment.text, attributes: attributes))
        }
        return out
    }

    /// A token as a dynamic `NSColor`, so the text follows the appearance
    /// without a redraw from SwiftUI.
    private static func color(_ token: ColorToken) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? token.dark : token.light, alpha: token.alpha)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var selection: Binding<String>
        var isUpdating = false

        init(selection: Binding<String>) {
            self.selection = selection
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isUpdating, let view = notification.object as? NSTextView else { return }
            let range = view.selectedRange()
            let text = (view.string as NSString)
            let picked = range.length > 0 && NSMaxRange(range) <= text.length
                ? text.substring(with: range) : ""
            if selection.wrappedValue != picked { selection.wrappedValue = picked }
        }
    }
}

// MARK: - empty block

/// Centred, one glyph and a couple of lines. No illustration and no button:
/// the only thing to do here is hold a key somewhere else.
private struct EmptyBlock<Content: View>: View {
    let symbol: String
    let title: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: Theme.Space.s8) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Theme.inkQuaternary)
                .padding(.bottom, Theme.Space.s4)
            if let title {
                Text(title)
                    .font(Theme.font(Theme.Role.sectionTitle))
                    .foregroundStyle(Theme.ink)
            }
            content
        }
        .frame(minHeight: 96)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}
#endif
