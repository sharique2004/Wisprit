#if os(macOS)
import Foundation

/// The sheet's step-flow logic, as values — `docs/design/ui-redesign.md` §4.1.
///
/// `OnboardingModel` answers *is this step done?*; this answers *what does the
/// footer show, and where does Continue go?* Splitting them is what keeps the
/// sheet's every branch reachable from `WispritMacTests` without a window
/// server: the footer is a pure function of `(step, inputs)` plus the one piece
/// of live state a value cannot know — whether the mic test has gone quiet.
///
/// Nothing here re-decides a gate. `isSatisfied` stays the single source of
/// truth, so a card cannot offer Continue on a step the checklist calls open.
enum OnboardingFlow {

    /// A step the cascade walks straight past without ever drawing it.
    ///
    /// Exactly one is possible today, and §4.2 names it: the 🌐-key question is
    /// moot on the right ⌥ key. There is no 🌐 press to intercept, so asking
    /// whether the emoji picker owns a key Wisprit does not use is a chore
    /// invented for its own sake. `isSatisfied(.globeKey, …)` already returns
    /// true in that case — this is the *navigation* half of the same fact, so
    /// Back does not reveal a card Continue skipped.
    static func isSkipped(_ step: OnboardingStep, _ inputs: OnboardingInputs) -> Bool {
        step == .globeKey && inputs.hotkey == .rightOption
    }

    /// The card after this one, or nil at the end of the cascade — which the
    /// caller turns into `finishOnboarding()`, matching `skipStep()`'s contract.
    static func next(after step: OnboardingStep, _ inputs: OnboardingInputs) -> OnboardingStep? {
        guard let index = OnboardingStep.allCases.firstIndex(of: step) else { return nil }
        return OnboardingStep.allCases[(index + 1)...].first { !isSkipped($0, inputs) }
    }

    /// The card before this one. nil is what disables Back on step 1 (§4.1).
    static func previous(before step: OnboardingStep,
                         _ inputs: OnboardingInputs) -> OnboardingStep? {
        guard let index = OnboardingStep.allCases.firstIndex(of: step) else { return nil }
        return OnboardingStep.allCases[..<index].last { !isSkipped($0, inputs) }
    }

    /// The completion card lives *inside* step 8 rather than being a ninth step
    /// (§4.3), so it needs both halves to be true: the optional Live Typing
    /// question has been answered either way, and every required step is done.
    /// "You're set." over a missing Accessibility grant would be the one lie
    /// this whole window exists to prevent.
    static func showsCompletion(_ step: OnboardingStep, _ inputs: OnboardingInputs) -> Bool {
        step == .liveTyping
            && OnboardingModel.isSatisfied(.liveTyping, inputs)
            && OnboardingModel.isComplete(inputs)
    }

    /// The footer's trailing control (§4.1): `Skip →`, or the primary action.
    enum Trailing: Equatable {
        /// The step is settled — a prominent Continue.
        case advance
        /// Nothing done here, and the user is allowed past.
        case skip
        /// The mic test with no voiced peak yet: Continue, disabled, with
        /// "Waiting for sound…" under the bars. The only disabled trailing
        /// control in the cascade, and the only step that earns its Skip by
        /// falling silent instead of by being optional.
        case blocked
        /// The completion card — `finishOnboarding()`, and the sheet closes.
        case finish
    }

    /// `micTestStalled` is the six-second silence from `MicTestState`; it is
    /// only consulted on `.micTest`.
    static func trailing(_ step: OnboardingStep, _ inputs: OnboardingInputs,
                         micTestStalled: Bool = false) -> Trailing {
        if showsCompletion(step, inputs) { return .finish }
        // Reading the welcome card IS doing it, so it never offers Skip — the
        // Continue *is* the acknowledgement.
        if step == .welcome { return .advance }
        if OnboardingModel.isSatisfied(step, inputs) { return .advance }
        if step == .micTest { return micTestStalled ? .skip : .blocked }
        return .skip
    }

    static func trailingTitle(_ trailing: Trailing) -> String {
        switch trailing {
        case .advance, .blocked: return "Continue"
        case .skip: return "Skip"
        case .finish: return "Open Wisprit"
        }
    }

    /// The 8-segment progress rail (§4.1): one segment per step, filled when
    /// that step is satisfied. Every step counts, skipped ones included — they
    /// are satisfied by definition, so the rail never shows a hole for a
    /// question the user was never asked.
    static func segments(_ inputs: OnboardingInputs) -> [Bool] {
        OnboardingStep.allCases.map { OnboardingModel.isSatisfied($0, inputs) }
    }
}
#endif
