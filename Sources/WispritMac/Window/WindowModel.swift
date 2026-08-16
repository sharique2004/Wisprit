#if os(macOS)
import Combine
import Foundation
import WispritContext
import WispritDictionary
import WispritKit
import WispritMacUI
import WispritPersistence

/// The window's single source of truth.
///
/// It owns no dictation state — `SessionController` still runs the pipeline and
/// still reports through `onStateChange`; this object is a shell around it that
/// polls the things a window has to show and writes settings the user changes.
/// Nothing here is ever on the audio path: the heavy probe (`Doctor.gather`)
/// runs on a detached task, the cheap one is four TCC reads, and both are
/// stopped the moment the window closes.
///
/// Every system call arrives as a closure in `Ports`, so the whole model —
/// including states that would need a revoked TCC grant to reach — is driven by
/// fakes in tests.
///
/// The one hard rule: **the window adds no main-thread work while the user is
/// holding the key.** The hotkey tap callback, the pill and the input-method
/// streaming path are all main-thread, and the try-it card asks the user to
/// dictate with this window open. So the timer stops for the duration of a
/// session (`noteSessionState`), and everything it runs — the TCC re-read, the
/// 🌐-key preference, the history queries — happens off the main actor and is
/// published back on it. The only main-thread reads left are one-shots at
/// window open, where nothing is competing for the thread.
@MainActor
public final class WispritWindowModel: ObservableObject {

    /// Seams. Defaults are inert so a test can construct the model with none.
    public struct Ports {
        /// The full picture: TCC + speech assets + Apple Intelligence + input
        /// method. Expensive (asset inventory, a model probe, one IM ping).
        public var fullProbe: @Sendable () async -> DoctorFacts
        /// The cheap re-read: TCC only, patched onto the last full facts. This
        /// is what runs every 2 seconds.
        public var fastProbe: @Sendable (DoctorFacts) -> DoctorFacts
        public var globeKey: @Sendable () -> GlobeKeyUsage
        public var recents: @Sendable (Int) -> [HistoryEntry]
        public var purgeHistory: @Sendable () -> Void
        public var copy: @Sendable (String) -> Void
        /// Put one stored transcript back at the cursor — Home's `text.insert`
        /// row action (§3.3). Optional because it is the one row action that
        /// cannot degrade to something harmless: with no port wired the button
        /// is **absent**, exactly as `trash` is until `History.delete(id:)`
        /// exists (§6.6). Never call it while a dictation is in flight; the
        /// model gates that.
        ///
        /// Main-actor, like `performFix`: it hands the window front back to the
        /// app underneath before it posts anything.
        public var pasteAtCursor: ((String) -> Void)?
        /// Apps where the insertion ladder has already learned it cannot stream
        /// live text. In-memory and per-launch — this is the ladder's own cache,
        /// not a probe.
        public var liveTypingFallbacks: @Sendable () -> [BundleVerdict]
        /// Perform a checklist fix. Runs on the main actor: some of these raise
        /// system prompts.
        public var performFix: (SetupFixKind) -> Void
        /// Phase-5 learn proposals awaiting review — `PendingLearnStore.pending()`
        /// in the Dictionary page's vocabulary. Defaults inert, like every seam.
        public var learnProposals: @Sendable () -> [LearnProposalRow]
        /// Accept: the SAME write auto-accept makes — `DictionaryStore.add` +
        /// `promoteConsumed` — owned by the app, not reimplemented here.
        public var acceptLearnProposal: @Sendable (LearnProposalRow) -> Void
        /// Dismiss: `PendingLearnStore.dismiss` — a permanent negative.
        public var dismissLearnProposal: @Sendable (String) -> Void
        /// The data inventory (R17): every store class with its size, read from
        /// disk. Called off the main actor; defaults empty so the section stays
        /// hidden in tests that never wire it.
        public var dataStores: @Sendable () -> [DataStoreStatus]
        /// Delete one store class's files. `.transcripts` never arrives here —
        /// the model routes it through `purgeHistory` above, the store's own
        /// purge. Owned by the app, which also reloads the dictionary after its
        /// file is removed.
        public var purgeDataStore: @Sendable (DataStoreID) -> Void
        /// The one-time time-to-wow row (R14): `(firstLaunchToDictateMs,
        /// stepsSkipped, relaunchCount)` → `MetricsWriter.writeOnboarding`.
        /// Track B owns the writer; this seam is the only way the row is
        /// written, so the schema stays owned in one place.
        public var writeOnboardingRow: @Sendable (Double, Int, Int) -> Void

        public init(fullProbe: @escaping @Sendable () async -> DoctorFacts = { DoctorFacts() },
                    fastProbe: @escaping @Sendable (DoctorFacts) -> DoctorFacts = { $0 },
                    globeKey: @escaping @Sendable () -> GlobeKeyUsage = { .unknown },
                    recents: @escaping @Sendable (Int) -> [HistoryEntry] = { _ in [] },
                    purgeHistory: @escaping @Sendable () -> Void = {},
                    copy: @escaping @Sendable (String) -> Void = { _ in },
                    pasteAtCursor: ((String) -> Void)? = nil,
                    liveTypingFallbacks: @escaping @Sendable () -> [BundleVerdict] = { [] },
                    performFix: @escaping (SetupFixKind) -> Void = { _ in },
                    learnProposals: @escaping @Sendable () -> [LearnProposalRow] = { [] },
                    acceptLearnProposal: @escaping @Sendable (LearnProposalRow) -> Void = { _ in },
                    dismissLearnProposal: @escaping @Sendable (String) -> Void = { _ in },
                    dataStores: @escaping @Sendable () -> [DataStoreStatus] = { [] },
                    purgeDataStore: @escaping @Sendable (DataStoreID) -> Void = { _ in },
                    writeOnboardingRow: @escaping @Sendable (Double, Int, Int) -> Void = { _, _, _ in }) {
            self.fullProbe = fullProbe
            self.fastProbe = fastProbe
            self.globeKey = globeKey
            self.recents = recents
            self.purgeHistory = purgeHistory
            self.copy = copy
            self.pasteAtCursor = pasteAtCursor
            self.liveTypingFallbacks = liveTypingFallbacks
            self.performFix = performFix
            self.learnProposals = learnProposals
            self.acceptLearnProposal = acceptLearnProposal
            self.dismissLearnProposal = dismissLearnProposal
            self.dataStores = dataStores
            self.purgeDataStore = purgeDataStore
            self.writeOnboardingRow = writeOnboardingRow
        }
    }

    /// The Hub's five pages — `docs/design/ui-redesign.md` §3.2.
    ///
    /// `allCases` is the sidebar's order, and the raw values are what
    /// `Wisprit window <page>` parses (`WindowLaunch.parse`, which also keeps
    /// the pre-redesign spellings working: `status → .setup`, `history → .home`).
    public enum Tab: String, Sendable, Equatable, CaseIterable, Identifiable {
        case home, dictionary, insights, setup, settings
        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .home: return "Home"
            case .dictionary: return "Dictionary"
            case .insights: return "Insights"
            case .setup: return "Setup"
            case .settings: return "Settings"
            }
        }

        public var symbol: String {
            switch self {
            case .home: return "house"
            case .dictionary: return "character.book.closed"
            case .insights: return "chart.bar.xaxis"
            case .setup: return "checklist"
            case .settings: return "gearshape"
            }
        }

        /// The two pinned to the bottom of the sidebar, under the hairline.
        public var isPinnedToBottom: Bool {
            switch self {
            case .setup, .settings: return true
            case .home, .dictionary, .insights: return false
            }
        }

        public static var primary: [Tab] { allCases.filter { !$0.isPinnedToBottom } }
        public static var pinned: [Tab] { allCases.filter(\.isPinnedToBottom) }
    }

    /// The 6 pt dot the `setup` nav row carries (§3.2). Absent is a real state:
    /// a checklist with nothing to say wears no badge at all.
    public enum SetupBadge: String, Sendable, Equatable {
        /// Something is blocking dictation outright.
        case blocking
        /// An essential row wants attention but dictation still works.
        case attention
    }

    /// One edit-derived learn candidate awaiting the user's decision — the
    /// Dictionary page's read of `PendingLearnStore.pending()`, in the window's
    /// own vocabulary so the page never names the store.
    public struct LearnProposalRow: Identifiable, Sendable, Equatable {
        public var term: String
        /// The misrecognitions it was corrected from, distinct utterances each.
        public var heard: [String]
        /// Distinct-utterance sightings — always ≥ the store's threshold, or
        /// the row would not be a proposal yet.
        public var count: Int

        public var id: String { term.lowercased() }

        public init(term: String, heard: [String] = [], count: Int = 0) {
            self.term = term
            self.heard = heard
            self.count = count
        }
    }

    /// The sidebar footer's dot + label (§3.2). Ordered by what the user most
    /// needs to know: a live microphone first, then a broken chain, then a
    /// switched-off app, then the quiet good news.
    public enum SidebarStatus: String, Sendable, Equatable {
        case listening, needsSetup, dictationOff, ready

        public var label: String {
            switch self {
            case .listening: return "Listening"
            case .needsSetup: return "Needs setup"
            case .dictationOff: return "Dictation off"
            case .ready: return "Ready"
            }
        }
    }

    // MARK: - Published state

    @Published public private(set) var facts = DoctorFacts()
    @Published public private(set) var hasProbed = false
    @Published public private(set) var items: [SetupItem] = []
    @Published public private(set) var summary = SetupSummary(
        hero: .checking, headline: "Checking…", subhead: "")
    @Published public private(set) var globeKey: GlobeKeyUsage = .unknown
    /// The Status page's short preview. The History page has its own, paged list
    /// — the two used to share this one, which is how a page titled "History"
    /// showed twenty rows while Purge deleted a thousand.
    @Published public private(set) var recents: [HistoryEntry] = []
    /// Apps the insertion ladder has learned cannot take live text.
    @Published public private(set) var liveTypingFallbacks: [BundleVerdict] = []
    @Published public private(set) var dictionaryRows: [DictionaryRow] = []
    @Published public private(set) var snippetRows: [SnippetRow] = []
    /// Always four, always in this order, filled or not — they are named
    /// fields, not a list.
    @Published public private(set) var identityRows: [IdentityRow] = []
    /// Phase-5 learn proposals awaiting review — §3.4's Pending badge grows a
    /// second population beyond the quarantined dictionary entries.
    @Published public private(set) var learnProposals: [LearnProposalRow] = []
    @Published public var dictionarySearch = ""
    @Published public var selectedTab: Tab = .setup
    /// The try-it scratch field. Held here so switching tabs does not lose it.
    @Published public var playgroundText = ""
    /// When the last full probe landed — "Checked 4 seconds ago." on the Setup
    /// page (§3.7). nil until the first one finishes.
    @Published public private(set) var lastProbeAt: Date?
    /// The session's own state, forwarded by the app. The sidebar's status dot
    /// is the only thing that reads it; nothing here drives dictation.
    @Published public private(set) var sessionState: SessionController.State = .idle

    // History page — its own list, its own limit.
    @Published public private(set) var history: [HistoryEntry] = []
    /// The last fetch came back full, so there is very likely more behind it.
    @Published public private(set) var historyHasMore = false

    /// The data inventory (R17): every store class Wisprit keeps, with sizes.
    /// Refreshed when the window opens and after every purge — sizes are a
    /// disk walk, not something to poll.
    @Published public private(set) var dataStores: [DataStoreStatus] = []

    // Home (§3.3).
    /// The same page of history in the neutral shape `HomeModel` groups,
    /// filters and counts. Mapped once, off the main actor, next to the fetch
    /// that produced it — not per render.
    @Published public private(set) var homeItems: [TranscriptItem] = []
    /// The right-hand stat rail. Derived from the whole retained table rather
    /// than the page on screen (a lifetime count is not in the newest fifty
    /// rows), so it has its own read. Nil until that read lands, which is also
    /// what tells the page apart from a genuinely empty history.
    @Published public private(set) var homeStats: HomeStats?
    /// Home's search box (§3.3). Not a filter the model applies: `HomeModel`
    /// owns the matching rule and the page calls it.
    @Published public var historySearch = ""

    // Onboarding
    @Published public private(set) var isOnboarding = false
    @Published public private(set) var onboardingStep: OnboardingStep = .welcome
    @Published public private(set) var welcomeAcknowledged = false
    @Published public private(set) var liveTypingSettled = false
    /// A transcript has landed since the window opened.
    @Published public private(set) var didDictate = false
    /// The onboarding mic test's engine transcribed the user (§4.2 step 3, R15).
    @Published public private(set) var micTestPassed = false

    // Settings mirrors — written straight through to `Settings` on change.
    @Published public private(set) var hotkey: WindowSettings.HotkeyOption = .fn
    @Published public private(set) var leadingSpace: WindowSettings.LeadingSpaceOption = .auto
    @Published public private(set) var dictationEnabled = true
    @Published public private(set) var aiCleanup = true
    @Published public private(set) var liveTypingEnabled = false
    @Published public private(set) var pillHidden = false
    @Published public private(set) var fillerRemoval = true
    @Published public private(set) var historyEnabled = true
    @Published public private(set) var holdDebounceMs = 150
    /// `keyup_grace_ms` — how long the mic stays open after key-up so the last
    /// syllable is not cut off. String-keyed; default 120, clamped 0…500.
    @Published public private(set) var keyupGraceMs = WindowSettings.keyupGraceDefault
    @Published public private(set) var pasteRestoreDelayMs = 500
    // Surfaced for the first time by the redesigned Settings page (§3.6). Same
    // shape as the ones above: a read-only mirror, one explicit setter, one
    // `Settings.set` per call.
    @Published public private(set) var locale = "en-US"
    @Published public private(set) var ensureSentencePeriod = false
    @Published public private(set) var terminalBundleIDs: [String] = []
    @Published public private(set) var aiCleanupMaxWords = 350
    @Published public private(set) var aiCleanupTimeoutMs = 12000
    @Published public private(set) var imSelectionPolicy: WindowSettings.SelectionPolicyOption = .warm
    @Published public private(set) var historyLimit = 1000
    @Published public private(set) var finalizeTimeoutMs = 1500
    @Published public private(set) var engine: WindowSettings.EngineOption = .auto
    /// `input_device_policy` — warn | prefer_builtin | off. String-keyed.
    @Published public private(set) var inputDevicePolicy: WindowSettings.InputDevicePolicyOption = .warn
    /// `vocabulary_retro` — on by default. String-keyed.
    @Published public private(set) var vocabularyRetro = true
    /// The pill has been dragged somewhere. "Reset its position" is disabled
    /// when it has not.
    @Published public private(set) var hasPillPosition = false
    // Context awareness (Phase 4). The enable path deliberately has NO direct
    // setter: the page routes it through `fix(.enableContextAwareness)`, so
    // every road to on runs the consent sheet. Off writes straight through.
    @Published public private(set) var contextAwareness = false
    /// True under `WISPRIT_NO_CONTEXT=1` — the section renders inert.
    @Published public private(set) var contextDisabledByEnvironment = false
    @Published public private(set) var contextVerbatimBundleIDs: [String] = []

    // MARK: - Collaborators

    private let settings: Settings
    private let dictionary: DictionaryEditor
    private let snippets: SnippetStore?
    private let identity: IdentityStore?
    private let ports: Ports
    private var timer: Timer?
    /// Full probes are expensive; the 2-second tick only does the cheap one and
    /// promotes to a full probe every `fullProbeEvery` ticks.
    private var ticksSinceFullProbe = 0
    private static let fullProbeEvery = 8   // ≈16 s
    /// How many transcripts the Status page previews, and the only reason the
    /// tick touches SQLite at all.
    public static let recentsPreviewLimit = 5
    /// One History page. "Load more" adds another.
    public static let historyPageSize = 50
    /// How many rows the Home page has asked for so far. Named for the *page*,
    /// not the setting: `historyLimit` is the user's `history_limit` cap.
    private var historyPageLimit = WispritWindowModel.historyPageSize
    /// Newest history timestamp when the window opened — the baseline the try-it
    /// step compares against when the session never reports directly. Set once,
    /// and reset only when the setup guide is re-run: reopening the window is
    /// not a reason to un-prove a dictation that already worked.
    private var dictationBaseline: Double = 0
    private var hasTakenDictationBaseline = false
    /// Newest timestamp the stat rail was computed from. The 5-row preview the
    /// tick already fetches is enough to notice a transcript the rail has not
    /// seen — including one written while the window was on another page — so
    /// the rail stays live without a second query every two seconds.
    private var statsNewestTs: Double = 0
    /// The window is on screen, so the tick has something to keep up to date.
    private var isWindowVisible = false
    /// A dictation is in flight. The timer is off for the duration: the hotkey
    /// tap, the pill and the IM streaming path all run on the main thread, and
    /// this window must not compete with them while the key is held.
    private var isDictating = false

    public init(settings: Settings, dictionary: DictionaryEditor,
                snippets: SnippetStore? = nil, identity: IdentityStore? = nil,
                ports: Ports = Ports()) {
        self.settings = settings
        self.dictionary = dictionary
        self.snippets = snippets
        self.identity = identity
        self.ports = ports
        reloadSettings()
        reloadDictionary()
        reloadSnippets()
        reloadIdentity()
        // The model is built once per launch, so this is where the
        // time-to-wow clock (R14) sees launches.
        noteLaunchForTimeToWow()
    }

    // MARK: - Refresh

    /// Called when the window opens: probe everything and start keeping up.
    ///
    /// Idempotent by design. It used to clear `didDictate` and re-take the
    /// try-it baseline on every `show()`, so closing and reopening the window
    /// wiped the green "Dictation is working." line while the transcript that
    /// proved it was still listed directly underneath — and silently un-proved
    /// the wizard's try-it step with it.
    public func windowDidOpen() {
        isWindowVisible = true
        takeDictationBaselineIfNeeded()
        reloadSettings()
        reloadDictionary()
        reloadSnippets()
        reloadIdentity()
        refreshRecents()
        loadHistory(reset: true)
        refreshHomeStats()
        refreshDataInventory()
        Task { await refreshFull() }
        startPolling()
    }

    public func windowDidClose() {
        isWindowVisible = false
        stopPolling()
    }

    /// The session state machine, forwarded by the app.
    ///
    /// Anything but `.idle` means the user is mid-utterance, and the window's
    /// job for that stretch is to do nothing at all.
    public func noteSessionState(_ state: SessionController.State) {
        sessionState = state
        let busy = state != .idle
        guard busy != isDictating else { return }
        isDictating = busy
        if busy {
            stopPolling()
        } else if isWindowVisible {
            // Catch up cheaply on what the pause skipped. Deliberately not a
            // full probe: that would put the asset inventory and the model
            // availability check at the end of every single utterance, which is
            // worse than the polling this was meant to relieve. The full probe
            // keeps its own ~16 s cadence, and `ticksSinceFullProbe` survives
            // the pause.
            Task { await refreshFast() }
            refreshRecents()
            startPolling()
        }
    }

    public func startPolling(interval: TimeInterval = 2.0) {
        stopPolling()
        guard !isDictating else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { self.tick() }
        }
        self.timer = timer
    }

    public func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    /// Whether the 2-second tick is armed. Exposed so "the window adds no
    /// main-thread work during a hold" is a property a test can assert rather
    /// than a promise in a comment.
    public var isPolling: Bool { timer != nil }

    private func tick() {
        guard !isDictating else { return }
        ticksSinceFullProbe += 1
        if ticksSinceFullProbe >= Self.fullProbeEvery {
            ticksSinceFullProbe = 0
            Task { await refreshFull() }
        } else {
            Task { await refreshFast() }
        }
        refreshRecents()
        // Home is the only page that would otherwise go stale while the user
        // watched it, and re-fetching its page is worth a query only while it is
        // the page on screen.
        if selectedTab == .home { loadHistory() }
    }

    /// The whole picture. Safe to call from anywhere; it awaits off the main
    /// actor and publishes back on it.
    public func refreshFull() async {
        let probe = ports.fullProbe
        let readGlobeKey = ports.globeKey
        let gathered = await probe()
        let usage = await Task.detached(priority: .utility) { readGlobeKey() }.value
        // Order matters: `apply` builds the hero, and the hero is "Checking…"
        // until `hasProbed` says a real probe has landed.
        hasProbed = true
        lastProbeAt = Date()
        globeKey = usage
        reloadSettings()
        apply(facts: gathered)
    }

    /// Five TCC reads and the 🌐-key preference over the last full snapshot.
    /// This is what makes a setting flipped in System Settings show up in the
    /// window within two seconds.
    ///
    /// Off the main actor, published back on it. They are only syscalls, but
    /// they are syscalls on a 2-second timer in a process whose main thread is
    /// also carrying the hotkey tap and the live-typing stream.
    public func refreshFast() async {
        guard hasProbed else { return }
        let probe = ports.fastProbe
        let readGlobeKey = ports.globeKey
        let snapshot = facts
        let refreshed = await Task.detached(priority: .utility) {
            (probe(snapshot), readGlobeKey())
        }.value
        globeKey = refreshed.1
        apply(facts: refreshed.0)
    }

    private func apply(facts newFacts: DoctorFacts) {
        facts = newFacts
        items = SetupChecklist.items(from: newFacts)
        liveTypingFallbacks = ports.liveTypingFallbacks()
        summary = SetupChecklist.summary(
            items: items,
            hotkeyLabel: SetupChecklist.hotkeyLabel(hotkey.rawValue),
            dictationEnabled: dictationEnabled,
            hasProbed: hasProbed)
        advanceOnboardingIfNeeded()
    }

    // MARK: - Sidebar (§3.2)

    /// The dot on the `setup` nav row. Pure, so the three-way rule is a property
    /// a test can pin rather than a condition buried in a view body.
    ///
    /// `attention` reads only *essential* rows: an optional feature the user has
    /// not set up is not a warning, and badging the sidebar for one is how a
    /// permanent dot gets learned as background noise.
    public nonisolated static func setupBadge(_ items: [SetupItem]) -> SetupBadge? {
        if items.contains(where: \.isBlocking) { return .blocking }
        if items.contains(where: { $0.isEssential && $0.mark == .warn }) { return .attention }
        return nil
    }

    public var setupBadge: SetupBadge? { Self.setupBadge(items) }

    /// The footer's dot + label.
    public nonisolated static func sidebarStatus(sessionState: SessionController.State,
                                     items: [SetupItem],
                                     dictationEnabled: Bool) -> SidebarStatus {
        // Recording outranks everything, including a broken checklist: if audio
        // is open the dot is the tally, and the tally never lies (§1.6).
        if sessionState == .recording { return .listening }
        if items.contains(where: \.isBlocking) { return .needsSetup }
        if !dictationEnabled { return .dictationOff }
        return .ready
    }

    public var sidebarStatus: SidebarStatus {
        Self.sidebarStatus(sessionState: sessionState,
                           items: items,
                           dictationEnabled: dictationEnabled)
    }

    /// Non-nil while macOS's Secure Keyboard Entry is held by some app: the one
    /// condition under which a fully green checklist still cannot dictate.
    /// Recomputed from `facts`, which the 2-second tick re-reads, so the banner
    /// appears and clears on its own.
    public var secureInputNotice: String? {
        guard hasProbed else { return nil }
        return SetupChecklist.secureInputNotice(facts)
    }

    /// The Status page's five-row preview, fetched off the main actor — it is a
    /// SQLite query and it runs on the same 2-second timer as everything else.
    public func refreshRecents() {
        let fetch = ports.recents
        let limit = Self.recentsPreviewLimit
        Task { [weak self] in
            let rows = await Task.detached(priority: .utility) { fetch(limit) }.value
            self?.publish(recents: rows)
        }
    }

    private func publish(recents rows: [HistoryEntry]) {
        recents = rows
        guard let newest = rows.first?.ts else { return }
        if newest > dictationBaseline {
            didDictate = true
            recordTimeToWowIfNeeded()
        }
        // A transcript the rail has not counted yet. One comparison against a
        // query that was already going to run, rather than re-reading the whole
        // table on the 2-second tick.
        if newest > statsNewestTs {
            refreshHomeStats()
        }
    }

    /// Home's stat rail (§3.3): lifetime words, today, the speaking-rate median
    /// and the streak grid, over every transcript the retention limit keeps.
    ///
    /// One SQLite read plus the derivation, both on a detached task and
    /// published back on the main actor — the pattern `refreshRecents` and
    /// `loadHistory` already set (§6.4). The rail is not on the 2-second tick:
    /// it re-reads when the window opens, when a dictation lands, when history
    /// is purged, and when the cheap preview notices a row it has not counted.
    public func refreshHomeStats() {
        let fetch = ports.recents
        let limit = max(historyLimit, Self.historyPageSize)
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                let entries = fetch(limit)
                return (HomeSource.stats(entries, now: Date(), calendar: .current),
                        entries.first?.ts ?? 0)
            }.value
            guard let self else { return }
            self.homeStats = result.0
            self.statsNewestTs = result.1
        }
    }

    /// The History page's own list. `reset` starts again at one page; otherwise
    /// this re-fetches whatever the user has already loaded.
    public func loadHistory(reset: Bool = false) {
        if reset { historyPageLimit = Self.historyPageSize }
        let fetch = ports.recents
        let limit = historyPageLimit
        Task { [weak self] in
            // Mapped where it is fetched, on the same detached task: Home reads
            // `homeItems`, and a per-render `map` over a thousand transcripts
            // would re-split every one of them for a word count that never
            // changes.
            let page = await Task.detached(priority: .utility) { () -> ([HistoryEntry], [TranscriptItem]) in
                let rows = fetch(limit)
                return (rows, HomeSource.items(rows))
            }.value
            guard let self else { return }
            self.history = page.0
            self.homeItems = page.1
            // A full page is the only evidence available without a count query:
            // it means the limit, not the table, decided where the list stopped.
            self.historyHasMore = page.0.count >= limit
        }
    }

    public func loadMoreHistory() {
        historyPageLimit += Self.historyPageSize
        loadHistory()
    }

    /// What the purge confirmation is allowed to claim. "N" only when N is the
    /// whole table; otherwise the dialog says plainly that it deletes more than
    /// the page shows.
    public var historyDeletionWarning: String {
        if historyHasMore {
            return "Every transcript Wisprit has saved will be deleted, including "
                + "the ones older than the \(history.count) listed here. This "
                + "cannot be undone, and Paste Last will have nothing to paste."
        }
        let count = history.count
        return "All \(count) saved transcript\(count == 1 ? "" : "s") will be deleted. "
            + "This cannot be undone, and Paste Last will have nothing to paste."
    }

    /// Called by the app when the session reaches INSERTING — proof a dictation
    /// completed even when history is switched off.
    public func noteDictationObserved() {
        didDictate = true
        recordTimeToWowIfNeeded()
        refreshRecents()
        advanceOnboardingIfNeeded()
    }

    /// Take the try-it baseline once, so an already-populated history is never
    /// mistaken for the sentence the user just spoke.
    private func takeDictationBaselineIfNeeded() {
        guard !hasTakenDictationBaseline else { return }
        hasTakenDictationBaseline = true
        dictationBaseline = ports.recents(1).first?.ts ?? 0
    }

    /// Re-arm the try-it proof. Only the setup guide does this: re-running the
    /// guide is a request to see it work *now*, whereas reopening the window is
    /// not.
    private func resetDictationProof() {
        dictationBaseline = ports.recents(1).first?.ts ?? 0
        hasTakenDictationBaseline = true
        didDictate = false
    }

    // MARK: - Fixes

    public func fix(_ kind: SetupFixKind) {
        guard kind != .none else { return }
        ports.performFix(kind)
        // A grant can land before the button's sheet even closes; re-probe now
        // and let the 2-second tick catch the rest.
        Task { await refreshFull() }
    }

    // MARK: - History

    public func copy(_ text: String) {
        ports.copy(text)
    }

    /// Whether Home draws the `text.insert` row action at all. Absent, not
    /// disabled: a paste button that cannot paste is worse than no button
    /// (§3.3's rule for `trash`, applied to the same class of missing seam).
    public var canPasteAtCursor: Bool { ports.pasteAtCursor != nil }

    /// Put one stored transcript back at the cursor.
    ///
    /// Refused mid-utterance. The insertion path swaps the clipboard and posts
    /// ⌘V, and the session is doing exactly that with the text the user just
    /// spoke — two of them interleaved is how a transcript lands in the wrong
    /// app with the wrong clipboard restored after it.
    public func pasteAtCursor(_ text: String) {
        guard sessionState == .idle, !text.isEmpty else { return }
        ports.pasteAtCursor?(text)
    }

    public func purgeHistory() {
        ports.purgeHistory()
        refreshRecents()
        loadHistory(reset: true)
        statsNewestTs = 0
        refreshHomeStats()
        refreshDataInventory()
    }

    // MARK: - Data inventory (R17)

    /// Re-read every store class's on-disk footprint. A disk walk, so it runs
    /// on a detached task and publishes back — the `refreshRecents` pattern.
    public func refreshDataInventory() {
        let scan = ports.dataStores
        Task { [weak self] in
            let rows = await Task.detached(priority: .utility) { scan() }.value
            self?.dataStores = rows
        }
    }

    /// Delete one store class. Transcripts go through the history store's own
    /// purge (a live SQLite handle is not a file to unlink); everything else is
    /// the app's file-level purge. The dictionary view model reloads afterwards
    /// so the page never shows rows whose file is gone.
    public func purgeDataStore(_ id: DataStoreID) {
        switch id {
        case .transcripts:
            purgeHistory()
            return
        case .settings:
            return
        case .metrics, .dictionary, .learnLedger, .models:
            ports.purgeDataStore(id)
        }
        if id == .dictionary || id == .learnLedger { reloadDictionary() }
        refreshDataInventory()
    }

    /// The one purge that reaches every store (soul test 6). Settings stay —
    /// preferences are not dictation content — and the inventory above says so.
    public func purgeAllData() {
        for id in DataInventory.deletableClasses { purgeDataStore(id) }
    }

    // MARK: - Dictionary

    public func reloadDictionary() {
        dictionaryRows = dictionary.rows()
        learnProposals = ports.learnProposals()
    }

    /// The Dictionary nav row's badge, from the same 6 pt-dot family as
    /// `setupBadge`. Pure, so "a proposal is a visible badge, an empty ledger is
    /// no badge at all" is pinnable without a window.
    public nonisolated static func dictionaryBadge(proposals: Int) -> SetupBadge? {
        proposals > 0 ? .attention : nil
    }

    public var dictionaryBadge: SetupBadge? {
        Self.dictionaryBadge(proposals: learnProposals.count)
    }

    /// Accept an edit-derived proposal: the port writes it into the dictionary
    /// (the same `add` + `promoteConsumed` the auto-accept path uses), then both
    /// lists refresh — the proposal disappears and the term appears as a row.
    public func acceptLearnProposal(_ row: LearnProposalRow) {
        ports.acceptLearnProposal(row)
        reloadDictionary()
    }

    /// Dismiss forever. The store keeps the negative, so this term is never
    /// proposed again however much later evidence arrives.
    public func dismissLearnProposal(_ row: LearnProposalRow) {
        ports.dismissLearnProposal(row.term)
        reloadDictionary()
    }

    public var filteredDictionaryRows: [DictionaryRow] {
        dictionaryRows.filter { $0.matches(dictionarySearch) }
    }

    @discardableResult
    public func saveTerm(original: DictionaryRow?, term: String, hear: [String]) -> Bool {
        let changed = dictionary.save(original: original, term: term, hear: hear)
        reloadDictionary()
        return changed
    }

    public func deleteTerm(_ term: String) {
        dictionary.delete(term)
        reloadDictionary()
    }

    /// Accept a quarantined term (§3.4's Pending badge). Dismissing one is just
    /// `deleteTerm` — the store's own removal, not a second kind of delete.
    @discardableResult
    public func promoteTerm(_ row: DictionaryRow) -> Bool {
        let promoted = dictionary.promote(row)
        reloadDictionary()
        return promoted
    }

    public var dictionaryPath: URL { dictionary.path }

    // MARK: - Snippets

    public struct SnippetRow: Identifiable, Equatable, Sendable {
        public var trigger: String
        public var expansion: String
        public var id: String { trigger.lowercased() }
    }

    public var hasSnippets: Bool { snippets != nil }

    public func reloadSnippets() {
        snippetRows = (snippets?.all() ?? []).map {
            SnippetRow(trigger: $0.trigger, expansion: $0.expansion)
        }
    }

    public var filteredSnippetRows: [SnippetRow] {
        let q = dictionarySearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return snippetRows }
        return snippetRows.filter {
            $0.trigger.localizedCaseInsensitiveContains(q)
                || $0.expansion.localizedCaseInsensitiveContains(q)
        }
    }

    @discardableResult
    public func saveSnippet(original: SnippetRow?, trigger: String, expansion: String) -> Bool {
        guard let snippets else { return false }
        if let original, original.trigger.caseInsensitiveCompare(trigger) != .orderedSame {
            snippets.remove(trigger: original.trigger)
        }
        let ok = snippets.upsert(SnippetStore.Snippet(trigger: trigger, expansion: expansion))
        reloadSnippets()
        return ok
    }

    public func deleteSnippet(_ trigger: String) {
        snippets?.remove(trigger: trigger)
        reloadSnippets()
    }

    // MARK: - Identity

    public struct IdentityRow: Identifiable, Equatable, Sendable {
        public var slot: IdentitySlot
        /// "" == unset. The row still exists — it is a named field.
        public var value: String
        public var id: String { slot.rawValue }

        public var label: String {
            switch slot {
            case .email: return "Email"
            case .linkedin: return "LinkedIn"
            case .github: return "GitHub"
            case .website: return "Website"
            }
        }

        /// The phrase shown next to the field, so the trigger is never a
        /// thing the user has to guess.
        public var spokenTrigger: String {
            switch slot {
            case .email: return "Say “my email”"
            case .linkedin: return "Say “my LinkedIn”"
            case .github: return "Say “my GitHub”"
            case .website: return "Say “my website”"
            }
        }

        /// The SHAPE, never a fake value — a placeholder must not read as
        /// something that would be typed.
        public var placeholder: String {
            switch slot {
            case .email: return "you@example.com"
            case .linkedin: return "linkedin.com/in/your-name"
            case .github: return "your-github-username"
            case .website: return "yoursite.com"
            }
        }
    }

    public enum IdentitySaveResult: Equatable {
        case saved(normalized: String)
        case cleared
        /// Refused values produce a message instead of a silent drop — and the
        /// field stays EMPTY, so a bad value degrades to no value rather than
        /// to a broken one that could be typed into a document.
        case rejected(reason: String)
    }

    public var hasIdentity: Bool { identity != nil }

    @Published public private(set) var emailSuggestionDismissed = false
    private var suggestedEmailProbed = false
    private var suggestedEmailCache: String?

    public func reloadIdentity() {
        let values = identity?.values() ?? IdentityValues()
        identityRows = IdentitySlot.allCases.map {
            IdentityRow(slot: $0, value: values.value($0) ?? "")
        }
    }

    /// Read on FIRST ACCESS, never in `init`: `AppController` builds this model
    /// at launch, and a user who never opens Settings should not have their
    /// `~/.gitconfig` opened on their behalf.
    ///
    /// VIEW STATE ONLY. This value fills a field's draft; the only call to
    /// `IdentityStore.set` in the whole app is `saveIdentity`, which the user
    /// triggers. Nothing unconfirmed can reach identity.json, and therefore
    /// nothing unconfirmed can reach a document.
    public var suggestedEmail: String? {
        guard !emailSuggestionDismissed else { return nil }
        if !suggestedEmailProbed {
            suggestedEmailProbed = true
            suggestedEmailCache = IdentitySeed.gitConfigEmail()
        }
        return suggestedEmailCache
    }

    /// Dismissing the suggestion hides it for the session.
    public func dismissEmailSuggestion() { emailSuggestionDismissed = true }

    @discardableResult
    public func saveIdentity(_ slot: IdentitySlot, value: String) -> IdentitySaveResult {
        guard let identity else { return .rejected(reason: "Identity is unavailable.") }
        // Clear short-circuits BEFORE normalize, so no caller can turn blank
        // input into a `https://github.com/` stub and store it.
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            identity.set(slot, to: "")
            reloadIdentity()
            return .cleared
        }
        let normalized = IdentityValue.normalize(trimmed, for: slot)
        if let reason = IdentityValue.validate(normalized, for: slot) {
            return .rejected(reason: reason)
        }
        identity.set(slot, to: normalized)
        reloadIdentity()
        return .saved(normalized: normalized)
    }

    public func clearIdentity(_ slot: IdentitySlot) {
        identity?.set(slot, to: "")
        reloadIdentity()
    }

    // MARK: - Settings

    public func reloadSettings() {
        settings.reload()
        hotkey = WindowSettings.HotkeyOption.parse(settings.hotkey)
        leadingSpace = WindowSettings.LeadingSpaceOption.parse(settings.leadingSpace)
        dictationEnabled = settings.enabled
        aiCleanup = settings.aiCleanup
        liveTypingEnabled = settings.bool(SettingsKey.liveTyping, or: false)
        pillHidden = settings.pillHidden
        fillerRemoval = settings.fillerRemoval
        historyEnabled = settings.historyEnabled
        holdDebounceMs = WindowSettings.clampHoldDebounce(settings.holdDebounceMs)
        keyupGraceMs = WindowSettings.clampKeyupGrace(
            settings.int(KeyupGraceSettings.key, or: KeyupGraceSettings.defaultMs))
        pasteRestoreDelayMs = WindowSettings.clampPasteRestore(settings.pasteRestoreDelayMs)
        locale = settings.locale
        ensureSentencePeriod = settings.ensureSentencePeriod
        terminalBundleIDs = settings.terminalBundleIDs
        aiCleanupMaxWords = WindowSettings.clampAiCleanupMaxWords(settings.aiCleanupMaxWords)
        aiCleanupTimeoutMs = WindowSettings.clampAiCleanupTimeout(settings.aiCleanupTimeoutMs)
        imSelectionPolicy = WindowSettings.SelectionPolicyOption.parse(
            settings.string(SettingsKey.imSelectionPolicy) ?? "")
        historyLimit = WindowSettings.clampHistoryLimit(settings.historyLimit)
        finalizeTimeoutMs = WindowSettings.clampFinalizeTimeout(settings.finalizeTimeoutMs)
        engine = WindowSettings.EngineOption.parse(settings.engine)
        inputDevicePolicy = WindowSettings.InputDevicePolicyOption.parse(
            settings.string(InputDevicePolicySettings.key,
                            or: InputDevicePolicySettings.warn.rawValue))
        vocabularyRetro = VocabularyRetroSettings.isEnabled(settings)
        hasPillPosition = settings.pillPosition != nil
        contextAwareness = ContextSettings.isEnabled(settings)
        contextDisabledByEnvironment = ContextEnvironment.isDisabled
        contextVerbatimBundleIDs = ContextSettings.verbatimBundleIDs(settings)
    }

    public func setHotkey(_ value: WindowSettings.HotkeyOption) {
        hotkey = value
        settings.set(SettingsKey.hotkey, value.rawValue)
        refreshSummaryOnly()
    }

    public func setLeadingSpace(_ value: WindowSettings.LeadingSpaceOption) {
        leadingSpace = value
        settings.set(SettingsKey.leadingSpace, value.rawValue)
    }

    public func setDictationEnabled(_ value: Bool) {
        dictationEnabled = value
        settings.set(SettingsKey.enabled, value)
        refreshSummaryOnly()
    }

    public func setAiCleanup(_ value: Bool) {
        aiCleanup = value
        settings.set(SettingsKey.aiCleanup, value)
    }

    public func setLiveTypingEnabled(_ value: Bool) {
        liveTypingEnabled = value
        settings.set(SettingsKey.liveTyping, value)
        // The checklist reads this setting through `DoctorFacts`, which only a
        // full probe refills. Patch it now so the Status row stops saying "off"
        // the instant the switch moves, instead of up to 16 seconds later.
        guard hasProbed else { return }
        var patched = facts
        patched.liveTypingEnabled = value
        apply(facts: patched)
    }

    /// The floating bar hides or returns to idle when this flips.
    public var onPillHiddenChange: ((Bool) -> Void)?

    public func setPillHidden(_ value: Bool) {
        pillHidden = value
        settings.set(SettingsKey.pillHidden, value)
        onPillHiddenChange?(value)
    }

    public func setFillerRemoval(_ value: Bool) {
        fillerRemoval = value
        settings.set(SettingsKey.fillerRemoval, value)
    }

    public func setHistoryEnabled(_ value: Bool) {
        historyEnabled = value
        settings.set(SettingsKey.historyEnabled, value)
    }

    public func setHoldDebounceMs(_ value: Int) {
        let clamped = WindowSettings.clampHoldDebounce(value)
        holdDebounceMs = clamped
        settings.set(SettingsKey.holdDebounceMs, clamped)
    }

    public func setKeyupGraceMs(_ value: Int) {
        let clamped = WindowSettings.clampKeyupGrace(value)
        keyupGraceMs = clamped
        settings.set(KeyupGraceSettings.key, clamped)
    }

    public func setPasteRestoreDelayMs(_ value: Int) {
        let clamped = WindowSettings.clampPasteRestore(value)
        pasteRestoreDelayMs = clamped
        settings.set(SettingsKey.pasteRestoreDelayMs, clamped)
    }

    public func setLocale(_ value: String) {
        locale = value
        settings.set(SettingsKey.locale, value)
    }

    public func setEnsureSentencePeriod(_ value: Bool) {
        ensureSentencePeriod = value
        settings.set(SettingsKey.ensureSentencePeriod, value)
    }

    /// The apps that get typed text instead of a paste. Blank lines and
    /// duplicates are dropped here rather than written to the file — the field
    /// is free text and the ladder reads this list on every insertion.
    public func setTerminalBundleIDs(_ value: [String]) {
        var seen = Set<String>()
        let cleaned = value
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        terminalBundleIDs = cleaned
        settings.set(SettingsKey.terminalBundleIDs, cleaned)
        // The verbatim list defaults to terminals ∪ IDEs until the user writes
        // their own; refresh the mirror so the Context section tracks the edit.
        contextVerbatimBundleIDs = ContextSettings.verbatimBundleIDs(settings)
    }

    /// OFF only. There is deliberately no `setContextAwareness(true)`: the
    /// page's enable button goes through `fix(.enableContextAwareness)` so the
    /// consent sheet is unskippable from every surface.
    public func setContextAwarenessOff() {
        contextAwareness = false
        ContextSettings.setEnabled(settings, false)
    }

    /// The apps whose dictation skips the refine stage. Same hygiene as the
    /// terminal list above.
    public func setContextVerbatimBundleIDs(_ value: [String]) {
        var seen = Set<String>()
        let cleaned = value
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        contextVerbatimBundleIDs = cleaned
        ContextSettings.setVerbatimBundleIDs(settings, cleaned)
    }

    public func setAiCleanupMaxWords(_ value: Int) {
        let clamped = WindowSettings.clampAiCleanupMaxWords(value)
        aiCleanupMaxWords = clamped
        settings.set(SettingsKey.aiCleanupMaxWords, clamped)
    }

    public func setAiCleanupTimeoutMs(_ value: Int) {
        let clamped = WindowSettings.clampAiCleanupTimeout(value)
        aiCleanupTimeoutMs = clamped
        settings.set(SettingsKey.aiCleanupTimeoutMs, clamped)
    }

    public func setImSelectionPolicy(_ value: WindowSettings.SelectionPolicyOption) {
        imSelectionPolicy = value
        settings.set(SettingsKey.imSelectionPolicy, value.rawValue)
    }

    public func setHistoryLimit(_ value: Int) {
        let clamped = WindowSettings.clampHistoryLimit(value)
        historyLimit = clamped
        settings.set(SettingsKey.historyLimit, clamped)
    }

    public func setFinalizeTimeoutMs(_ value: Int) {
        let clamped = WindowSettings.clampFinalizeTimeout(value)
        finalizeTimeoutMs = clamped
        settings.set(SettingsKey.finalizeTimeoutMs, clamped)
    }

    /// Only the two engines that exist. `mlx_whisper` / `faster_whisper` are
    /// unbuilt and are never offered (§3.6).
    public func setEngine(_ value: WindowSettings.EngineOption) {
        engine = value
        settings.set(SettingsKey.engine, value.rawValue)
    }

    public func setInputDevicePolicy(_ value: WindowSettings.InputDevicePolicyOption) {
        inputDevicePolicy = value
        settings.set(InputDevicePolicySettings.key, value.rawValue)
    }

    public func setVocabularyRetro(_ value: Bool) {
        vocabularyRetro = value
        VocabularyRetroSettings.setEnabled(settings, value)
    }

    /// Put the pill back at the default bottom-centre spot. Writing `null` is
    /// what `Pill.restorePosition` reads as "no saved position".
    public func resetPillPosition() {
        settings.set(SettingsKey.pillPosition, .null)
        hasPillPosition = false
    }

    public var configPath: URL { settings.configPath }
    public var metricsPath: URL { WispritPaths.metricsPath }

    private func refreshSummaryOnly() {
        summary = SetupChecklist.summary(
            items: items,
            hotkeyLabel: SetupChecklist.hotkeyLabel(hotkey.rawValue),
            dictationEnabled: dictationEnabled,
            hasProbed: hasProbed)
    }

    // MARK: - Onboarding

    public var onboardingInputs: OnboardingInputs {
        OnboardingInputs(items: items,
                         globeKey: globeKey,
                         didDictate: didDictate,
                         welcomeAcknowledged: welcomeAcknowledged,
                         liveTypingSettled: liveTypingSettled,
                         micTestPassed: micTestPassed,
                         hotkey: hotkey)
    }

    /// The mic test's engine transcribed the user (§4.2 step 3, R15).
    /// Deliberately not persisted: it proves the input worked *now*, and a
    /// machine whose mic has since been unplugged should be asked again.
    public func noteMicTestPassed() {
        guard !micTestPassed else { return }
        micTestPassed = true
        advanceOnboardingIfNeeded()
    }

    /// Re-arm the mic test — the setup guide, re-run from the top, has to see it
    /// work again.
    public func resetMicTest() {
        micTestPassed = false
    }

    /// True on a first run, or when a required permission has gone missing.
    public var shouldAutoOpenWindow: Bool {
        OnboardingModel.shouldAutoOpen(
            hasCompletedBefore: settings.bool(OnboardingSettings.completedKey, or: false),
            items: items)
    }

    public func beginOnboarding(resuming: Bool = true) {
        liveTypingSettled = settings.bool(OnboardingSettings.liveTypingSettledKey, or: false)
        welcomeAcknowledged = false
        isOnboarding = true
        // Re-running the guide from the top is a request to see it work again,
        // so the try-it step and the mic test both have to be re-proved.
        // Resuming is not.
        if !resuming {
            resetDictationProof()
            resetMicTest()
        }
        if resuming,
           let saved = settings.string(OnboardingSettings.stepKey),
           let step = OnboardingStep(rawValue: saved),
           step != .welcome {
            // Resuming past Welcome implies it was already read.
            welcomeAcknowledged = true
            onboardingStep = step
        } else {
            onboardingStep = .welcome
        }
        advanceOnboardingIfNeeded()
    }

    public func acknowledgeWelcome() {
        welcomeAcknowledged = true
        advanceOnboardingIfNeeded()
    }

    public func settleLiveTyping() {
        liveTypingSettled = true
        settings.set(OnboardingSettings.liveTypingSettledKey, true)
        advanceOnboardingIfNeeded()
    }

    /// Manual navigation — the wizard is a guide, not a cage.
    public func goToStep(_ step: OnboardingStep) {
        onboardingStep = step
        settings.set(OnboardingSettings.stepKey, step.rawValue)
    }

    public func skipStep() {
        noteStepSkippedForTimeToWow()
        guard let index = OnboardingStep.allCases.firstIndex(of: onboardingStep),
              index + 1 < OnboardingStep.allCases.count else {
            finishOnboarding()
            return
        }
        goToStep(OnboardingStep.allCases[index + 1])
    }

    // MARK: - Time-to-wow (R14)

    /// First launch → first successful dictation, as one metrics row. The
    /// clock starts only on a genuinely fresh install (no stamp yet, onboarding
    /// never completed), so an existing machine never writes a bogus row; it
    /// stops forever once the row is written. Counters live in the same
    /// append-only settings namespace as the rest of the wizard's state, so
    /// they survive the mid-onboarding relaunch that Input Monitoring forces —
    /// which is exactly the cost the row exists to measure.
    private func noteLaunchForTimeToWow() {
        guard !settings.bool(OnboardingSettings.wowRecordedKey, or: false) else { return }
        if settings.double(OnboardingSettings.firstLaunchKey) != nil {
            settings.set(OnboardingSettings.relaunchCountKey,
                         settings.int(OnboardingSettings.relaunchCountKey, or: 0) + 1)
        } else if !settings.bool(OnboardingSettings.completedKey, or: false) {
            settings.set(OnboardingSettings.firstLaunchKey, Date().timeIntervalSince1970)
        }
    }

    /// A Skip the user actually pressed, counted only while the clock runs.
    private func noteStepSkippedForTimeToWow() {
        guard !settings.bool(OnboardingSettings.wowRecordedKey, or: false),
              settings.double(OnboardingSettings.firstLaunchKey) != nil else { return }
        settings.set(OnboardingSettings.stepsSkippedKey,
                     settings.int(OnboardingSettings.stepsSkippedKey, or: 0) + 1)
    }

    /// Write the row, once, the first time a dictation lands. The recorded
    /// flag flips before the write so no re-entry can ever produce a second
    /// row.
    private func recordTimeToWowIfNeeded() {
        guard didDictate,
              !settings.bool(OnboardingSettings.wowRecordedKey, or: false),
              let firstLaunch = settings.double(OnboardingSettings.firstLaunchKey) else {
            return
        }
        settings.set(OnboardingSettings.wowRecordedKey, true)
        ports.writeOnboardingRow(
            max(0, Date().timeIntervalSince1970 - firstLaunch) * 1000.0,
            settings.int(OnboardingSettings.stepsSkippedKey, or: 0),
            settings.int(OnboardingSettings.relaunchCountKey, or: 0))
    }

    public func finishOnboarding() {
        isOnboarding = false
        settings.set(OnboardingSettings.completedKey, true)
        settings.set(OnboardingSettings.stepKey, OnboardingStep.liveTyping.rawValue)
    }

    /// Closed without finishing. The step is already persisted, so reopening
    /// resumes where the user stopped — but `onboarding_completed` stays false,
    /// which is what makes the next launch raise the wizard again.
    public func dismissOnboarding() {
        isOnboarding = false
    }

    /// Everything the wizard asks about is satisfied — the last page becomes the
    /// "you're set up" page, and Finish is the only way out.
    public var isOnboardingComplete: Bool {
        OnboardingModel.firstIncomplete(onboardingInputs) == nil
    }

    /// Move to the first unsatisfied step, but never backwards: a user who
    /// skipped ahead should not be yanked back by a probe finishing late.
    ///
    /// When there is nothing left it lands on the final step rather than closing
    /// the sheet. Dismissing on the first satisfied tick is what made the wizard
    /// flash and vanish on an already-healthy machine — the user got no
    /// completion moment at all, just a panel that appeared and disappeared,
    /// which reads as a glitch. Only the Finish button ends it now.
    private func advanceOnboardingIfNeeded() {
        guard isOnboarding else { return }
        let inputs = onboardingInputs
        let next = OnboardingModel.firstIncomplete(inputs) ?? OnboardingStep.allCases.last!
        guard let current = OnboardingStep.allCases.firstIndex(of: onboardingStep),
              let candidate = OnboardingStep.allCases.firstIndex(of: next) else { return }
        if candidate > current {
            goToStep(next)
        }
    }

    public var onboardingProgress: Double {
        OnboardingModel.progress(onboardingInputs)
    }
}
#endif
