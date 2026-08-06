#if os(macOS)
import Combine
import Foundation
import WispritDictionary
import WispritKit
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
        /// Apps where the insertion ladder has already learned it cannot stream
        /// live text. In-memory and per-launch — this is the ladder's own cache,
        /// not a probe.
        public var liveTypingFallbacks: @Sendable () -> [BundleVerdict]
        /// Perform a checklist fix. Runs on the main actor: some of these raise
        /// system prompts.
        public var performFix: (SetupFixKind) -> Void

        public init(fullProbe: @escaping @Sendable () async -> DoctorFacts = { DoctorFacts() },
                    fastProbe: @escaping @Sendable (DoctorFacts) -> DoctorFacts = { $0 },
                    globeKey: @escaping @Sendable () -> GlobeKeyUsage = { .unknown },
                    recents: @escaping @Sendable (Int) -> [HistoryEntry] = { _ in [] },
                    purgeHistory: @escaping @Sendable () -> Void = {},
                    copy: @escaping @Sendable (String) -> Void = { _ in },
                    liveTypingFallbacks: @escaping @Sendable () -> [BundleVerdict] = { [] },
                    performFix: @escaping (SetupFixKind) -> Void = { _ in }) {
            self.fullProbe = fullProbe
            self.fastProbe = fastProbe
            self.globeKey = globeKey
            self.recents = recents
            self.purgeHistory = purgeHistory
            self.copy = copy
            self.liveTypingFallbacks = liveTypingFallbacks
            self.performFix = performFix
        }
    }

    public enum Tab: String, Sendable, Equatable, CaseIterable, Identifiable {
        case status, dictionary, history, settings
        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .status: return "Status"
            case .dictionary: return "Dictionary"
            case .history: return "History"
            case .settings: return "Settings"
            }
        }

        public var symbol: String {
            switch self {
            case .status: return "waveform.circle"
            case .dictionary: return "character.book.closed"
            case .history: return "clock.arrow.circlepath"
            case .settings: return "gearshape"
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
    @Published public var dictionarySearch = ""
    @Published public var selectedTab: Tab = .status
    /// The try-it scratch field. Held here so switching tabs does not lose it.
    @Published public var playgroundText = ""

    // History page — its own list, its own limit.
    @Published public private(set) var history: [HistoryEntry] = []
    /// The last fetch came back full, so there is very likely more behind it.
    @Published public private(set) var historyHasMore = false

    // Onboarding
    @Published public private(set) var isOnboarding = false
    @Published public private(set) var onboardingStep: OnboardingStep = .welcome
    @Published public private(set) var welcomeAcknowledged = false
    @Published public private(set) var liveTypingSettled = false
    /// A transcript has landed since the window opened.
    @Published public private(set) var didDictate = false

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
    @Published public private(set) var pasteRestoreDelayMs = 500

    // MARK: - Collaborators

    private let settings: Settings
    private let dictionary: DictionaryEditor
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
    private var historyLimit = WispritWindowModel.historyPageSize
    /// Newest history timestamp when the window opened — the baseline the try-it
    /// step compares against when the session never reports directly. Set once,
    /// and reset only when the setup guide is re-run: reopening the window is
    /// not a reason to un-prove a dictation that already worked.
    private var dictationBaseline: Double = 0
    private var hasTakenDictationBaseline = false
    /// The window is on screen, so the tick has something to keep up to date.
    private var isWindowVisible = false
    /// A dictation is in flight. The timer is off for the duration: the hotkey
    /// tap, the pill and the IM streaming path all run on the main thread, and
    /// this window must not compete with them while the key is held.
    private var isDictating = false

    public init(settings: Settings, dictionary: DictionaryEditor, ports: Ports = Ports()) {
        self.settings = settings
        self.dictionary = dictionary
        self.ports = ports
        reloadSettings()
        reloadDictionary()
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
        refreshRecents()
        loadHistory(reset: true)
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
        // The History page is the only one that would otherwise go stale while
        // the user watched it, and re-fetching its page is worth a query only
        // while it is the page on screen.
        if selectedTab == .history { loadHistory() }
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
        if let newest = rows.first?.ts, newest > dictationBaseline {
            didDictate = true
        }
    }

    /// The History page's own list. `reset` starts again at one page; otherwise
    /// this re-fetches whatever the user has already loaded.
    public func loadHistory(reset: Bool = false) {
        if reset { historyLimit = Self.historyPageSize }
        let fetch = ports.recents
        let limit = historyLimit
        Task { [weak self] in
            let rows = await Task.detached(priority: .utility) { fetch(limit) }.value
            guard let self else { return }
            self.history = rows
            // A full page is the only evidence available without a count query:
            // it means the limit, not the table, decided where the list stopped.
            self.historyHasMore = rows.count >= limit
        }
    }

    public func loadMoreHistory() {
        historyLimit += Self.historyPageSize
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

    public func purgeHistory() {
        ports.purgeHistory()
        refreshRecents()
        loadHistory(reset: true)
    }

    // MARK: - Dictionary

    public func reloadDictionary() {
        dictionaryRows = dictionary.rows()
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

    public var dictionaryPath: URL { dictionary.path }

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
        pasteRestoreDelayMs = WindowSettings.clampPasteRestore(settings.pasteRestoreDelayMs)
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

    public func setPillHidden(_ value: Bool) {
        pillHidden = value
        settings.set(SettingsKey.pillHidden, value)
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

    public func setPasteRestoreDelayMs(_ value: Int) {
        let clamped = WindowSettings.clampPasteRestore(value)
        pasteRestoreDelayMs = clamped
        settings.set(SettingsKey.pasteRestoreDelayMs, clamped)
    }

    public var configPath: URL { settings.configPath }

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
                         liveTypingSettled: liveTypingSettled)
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
        // so the try-it step has to be re-proved. Resuming is not.
        if !resuming { resetDictationProof() }
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
        guard let index = OnboardingStep.allCases.firstIndex(of: onboardingStep),
              index + 1 < OnboardingStep.allCases.count else {
            finishOnboarding()
            return
        }
        goToStep(OnboardingStep.allCases[index + 1])
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
