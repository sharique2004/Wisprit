import Foundation

/// The first-run wizard, as a pure state machine.
///
/// The steps are ordered by dependency, not by importance: Input Monitoring
/// comes before Accessibility because a user who grants them in that order
/// relaunches once instead of twice, and the try-a-dictation step comes last
/// because it is the only one that can actually *prove* the chain works.
///
/// Every "is this done?" answer is derived from the same `SetupItem` rows the
/// status page shows, so a step cannot be green in the wizard and red on the
/// checklist.
public enum OnboardingStep: String, Sendable, Equatable, CaseIterable {
    case welcome
    case microphone
    case inputMonitoring
    case accessibility
    case globeKey
    case tryIt
    case liveTyping

    public var title: String {
        switch self {
        case .welcome: return "Welcome"
        case .microphone: return "Microphone"
        case .inputMonitoring: return "Input Monitoring"
        case .accessibility: return "Accessibility"
        case .globeKey: return "The 🌐 key"
        case .tryIt: return "Try it"
        case .liveTyping: return "Live Typing"
        }
    }

    /// A step the user may skip without leaving Wisprit broken.
    public var isOptional: Bool {
        switch self {
        case .globeKey, .liveTyping: return true
        case .welcome, .microphone, .inputMonitoring, .accessibility, .tryIt: return false
        }
    }
}

/// Everything the wizard needs to know, gathered once per refresh.
public struct OnboardingInputs: Sendable, Equatable {
    /// The status checklist, as built by `SetupChecklist.items(from:)`.
    public var items: [SetupItem]
    public var globeKey: GlobeKeyUsage
    /// A transcript has landed since the wizard opened — the only honest proof
    /// that hotkey → mic → speech → insertion all work.
    public var didDictate: Bool
    /// The user pressed Continue on the welcome page.
    public var welcomeAcknowledged: Bool
    /// `live_typing`, or the user explicitly said "not now".
    public var liveTypingSettled: Bool

    public init(items: [SetupItem] = [], globeKey: GlobeKeyUsage = .unknown,
                didDictate: Bool = false, welcomeAcknowledged: Bool = false,
                liveTypingSettled: Bool = false) {
        self.items = items
        self.globeKey = globeKey
        self.didDictate = didDictate
        self.welcomeAcknowledged = welcomeAcknowledged
        self.liveTypingSettled = liveTypingSettled
    }

    func item(_ id: String) -> SetupItem? { items.first { $0.id == id } }
}

public enum OnboardingModel {

    public static let steps = OnboardingStep.allCases

    public static func isSatisfied(_ step: OnboardingStep, _ inputs: OnboardingInputs) -> Bool {
        switch step {
        case .welcome:
            return inputs.welcomeAcknowledged
        case .microphone:
            return inputs.item(SetupChecklist.microphoneID)?.isSatisfied ?? false
        case .inputMonitoring:
            // Deliberately stricter than the doctor's leniency (which lets
            // Accessibility stand in for a stale Input Monitoring read): during
            // onboarding a warn means "we cannot prove the key is visible", and
            // walking the user past that is how the hour got lost.
            return inputs.item(SetupChecklist.inputMonitoringID)?.isSatisfied ?? false
        case .accessibility:
            return inputs.item(SetupChecklist.accessibilityID)?.isSatisfied ?? false
        case .globeKey:
            return inputs.globeKey.isClear
        case .tryIt:
            return inputs.didDictate
        case .liveTyping:
            return inputs.liveTypingSettled
                || (inputs.item(SetupChecklist.liveTypingID)?.isSatisfied ?? false)
        }
    }

    /// The step the wizard should be showing: the first unsatisfied one, in
    /// order. nil means there is nothing left to do.
    ///
    /// Optional steps are skipped only when a *later* required step is still
    /// open — so a user with everything else done still gets asked about the 🌐
    /// key, but a user who has not granted the microphone is not detoured into
    /// Live Typing first.
    public static func firstIncomplete(_ inputs: OnboardingInputs) -> OnboardingStep? {
        steps.first { !isSatisfied($0, inputs) }
    }

    /// The wizard is finished when every non-optional step is satisfied. The
    /// optional ones are offered, never enforced.
    public static func isComplete(_ inputs: OnboardingInputs) -> Bool {
        steps.filter { !$0.isOptional }.allSatisfy { isSatisfied($0, inputs) }
    }

    /// 0…1, for the progress bar. Counts every step, optional included, so the
    /// bar does not jump backwards when an optional step appears.
    public static func progress(_ inputs: OnboardingInputs) -> Double {
        let done = steps.filter { isSatisfied($0, inputs) }.count
        return Double(done) / Double(steps.count)
    }

    /// Whether a fresh launch should raise the wizard rather than sit silently
    /// in the menu bar. First run always does; after that, only a broken chain.
    public static func shouldAutoOpen(hasCompletedBefore: Bool, items: [SetupItem]) -> Bool {
        if !hasCompletedBefore { return true }
        return items.contains(where: \.isBlocking)
    }
}

/// Wizard progress, persisted through `Settings`.
///
/// The keys are appended, never inserted, and are read through the generic
/// string accessors: `Settings` merges the file over `Settings.defaults` and
/// re-emits keys it does not know, so a config written by this build stays
/// readable by one that predates the window (and vice versa).
public enum OnboardingSettings {
    /// The wizard has run to completion at least once on this machine.
    public static let completedKey = "onboarding_completed"
    /// Where the user left off, so reopening resumes instead of restarting.
    public static let stepKey = "onboarding_step"
    /// The user answered the optional Live Typing question, either way.
    public static let liveTypingSettledKey = "onboarding_live_typing_settled"
}
