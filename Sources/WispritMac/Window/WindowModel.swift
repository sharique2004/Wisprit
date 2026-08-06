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
        /// Perform a checklist fix. Runs on the main actor: some of these raise
        /// system prompts.
        public var performFix: (SetupFixKind) -> Void

        public init(fullProbe: @escaping @Sendable () async -> DoctorFacts = { DoctorFacts() },
                    fastProbe: @escaping @Sendable (DoctorFacts) -> DoctorFacts = { $0 },
                    globeKey: @escaping @Sendable () -> GlobeKeyUsage = { .unknown },
                    recents: @escaping @Sendable (Int) -> [HistoryEntry] = { _ in [] },
                    purgeHistory: @escaping @Sendable () -> Void = {},
                    copy: @escaping @Sendable (String) -> Void = { _ in },
                    performFix: @escaping (SetupFixKind) -> Void = { _ in }) {
            self.fullProbe = fullProbe
            self.fastProbe = fastProbe
            self.globeKey = globeKey
            self.recents = recents
            self.purgeHistory = purgeHistory
            self.copy = copy
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
    @Published public private(set) var recents: [HistoryEntry] = []
    @Published public private(set) var dictionaryRows: [DictionaryRow] = []
    @Published public var dictionarySearch = ""
    @Published public var selectedTab: Tab = .status
    /// The try-it scratch field. Held here so switching tabs does not lose it.
    @Published public var playgroundText = ""

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
    /// Newest history timestamp when the window opened — the baseline the try-it
    /// step compares against when the session never reports directly.
    private var dictationBaseline: Double = 0

    public init(settings: Settings, dictionary: DictionaryEditor, ports: Ports = Ports()) {
        self.settings = settings
        self.dictionary = dictionary
        self.ports = ports
        reloadSettings()
        reloadDictionary()
    }

    // MARK: - Refresh

    /// Called when the window opens: reset the try-it baseline, probe everything.
    public func windowDidOpen() {
        dictationBaseline = ports.recents(1).first?.ts ?? 0
        didDictate = false
        reloadSettings()
        reloadDictionary()
        refreshRecents()
        globeKey = ports.globeKey()
        Task { await refreshFull() }
        startPolling()
    }

    public func windowDidClose() {
        stopPolling()
    }

    public func startPolling(interval: TimeInterval = 2.0) {
        stopPolling()
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { self.tick() }
        }
        self.timer = timer
    }

    public func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        ticksSinceFullProbe += 1
        if ticksSinceFullProbe >= Self.fullProbeEvery {
            ticksSinceFullProbe = 0
            Task { await refreshFull() }
        } else {
            refreshFast()
        }
        refreshRecents()
    }

    /// The whole picture. Safe to call from anywhere; it awaits off the main
    /// actor and publishes back on it.
    public func refreshFull() async {
        let probe = ports.fullProbe
        let gathered = await probe()
        // Order matters: `apply` builds the hero, and the hero is "Checking…"
        // until `hasProbed` says a real probe has landed.
        hasProbed = true
        globeKey = ports.globeKey()
        reloadSettings()
        apply(facts: gathered)
    }

    /// Four TCC reads over the last full snapshot. This is what makes a grant
    /// flipped in System Settings show up in the window within two seconds.
    public func refreshFast() {
        guard hasProbed else { return }
        apply(facts: ports.fastProbe(facts))
    }

    private func apply(facts newFacts: DoctorFacts) {
        facts = newFacts
        items = SetupChecklist.items(from: newFacts)
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

    public func refreshRecents() {
        recents = ports.recents(20)
        if let newest = recents.first?.ts, newest > dictationBaseline {
            didDictate = true
        }
    }

    /// Called by the app when the session reaches INSERTING — proof a dictation
    /// completed even when history is switched off.
    public func noteDictationObserved() {
        didDictate = true
        refreshRecents()
        advanceOnboardingIfNeeded()
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

    /// Move to the first unsatisfied step, but never backwards: a user who
    /// skipped ahead should not be yanked back by a probe finishing late.
    private func advanceOnboardingIfNeeded() {
        guard isOnboarding else { return }
        let inputs = onboardingInputs
        guard let next = OnboardingModel.firstIncomplete(inputs) else {
            finishOnboarding()
            return
        }
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
