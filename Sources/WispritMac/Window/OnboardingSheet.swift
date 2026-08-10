#if os(macOS)
import SwiftUI
import WispritMacUI

/// First run, one decision at a time — `docs/design/ui-redesign.md` §4.
///
/// A 560 × 520 sheet over the Hub, replacing the 720 × 540 two-pane wizard. The
/// left step-rail is gone on purpose: it advertised seven chores before the user
/// had done one, and a list of seven permissions is the single most effective
/// way to make someone close a window. What replaces it is a 3 pt segmented rail
/// in the footer — visible progress, no inventory.
///
/// The cascade itself is not new logic. `OnboardingModel.isSatisfied` over
/// `SetupItem`s built from `DoctorFacts` is still the only gate, so a step
/// cannot be green here and red on the Setup page; this file decides which card
/// is on screen and what the footer offers, and both of those are pure
/// functions in `OnboardingFlow`.
struct OnboardingSheet: View {
    @ObservedObject var model: WispritWindowModel

    /// The mic test's capture and its state, owned at the sheet level so the
    /// footer can read "has it gone quiet?" and so the capture's lifetime is
    /// exactly the lifetime of one `.task` (§4.2 step 3).
    @State private var micTest = OnboardingMicProbe()

    var body: some View {
        VStack(spacing: 0) {
            card
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 1)
            footer
        }
        .frame(width: OnboardingMetrics.sheetWidth, height: OnboardingMetrics.sheetHeight)
        .overlay(alignment: .topTrailing) { closeButton }
        .task(id: micTestRun) { await runMicTest() }
    }

    private var inputs: OnboardingInputs { model.onboardingInputs }

    // MARK: - the card

    @ViewBuilder
    private var card: some View {
        if OnboardingFlow.showsCompletion(model.onboardingStep, inputs) {
            OnboardingCompletionCard(
                hotkeyLabel: SetupChecklist.hotkeyLabel(model.hotkey.rawValue))
        } else {
            switch model.onboardingStep {
            case .welcome:
                OnboardingWelcomeCard()
            case .microphone:
                OnboardingPermissionCard(
                    item: item(SetupChecklist.microphoneID),
                    symbol: "mic",
                    title: "Let Wisprit hear you",
                    message: "macOS asks once. Wisprit only listens while you are "
                        + "holding the key, and the audio never leaves this Mac.",
                    hint: "System Settings ▸ Privacy & Security ▸ Microphone",
                    unprobed: (.requestMicrophone, "Allow Microphone"),
                    fix: { model.fix($0) })
            case .micTest:
                OnboardingMicTestCard(state: micTest.state)
            case .globeKey:
                OnboardingGlobeKeyCard(usage: model.globeKey,
                                       fix: { model.fix($0) },
                                       useRightOption: chooseRightOption)
            case .inputMonitoring:
                OnboardingPermissionCard(
                    item: item(SetupChecklist.inputMonitoringID),
                    symbol: "keyboard",
                    title: "Let Wisprit see the key",
                    message: "This is the one macOS handles worst: it never prompts, "
                        + "and switching it on while Wisprit is running changes "
                        + "nothing until Wisprit next starts.",
                    hint: "System Settings ▸ Privacy & Security ▸ Input Monitoring",
                    unprobed: (.requestInputMonitoring, "Open Input Monitoring"),
                    fix: { model.fix($0) })
            case .accessibility:
                OnboardingPermissionCard(
                    item: item(SetupChecklist.accessibilityID),
                    symbol: "hand.point.up.left",
                    title: "Let Wisprit type for you",
                    message: "Without this macOS silently drops the paste, which looks "
                        + "exactly like Wisprit hearing nothing at all.",
                    hint: "System Settings ▸ Privacy & Security ▸ Accessibility",
                    unprobed: (.openAccessibilitySettings, "Open Accessibility"),
                    fix: { model.fix($0) })
            case .tryIt:
                OnboardingPracticeCard(text: $model.playgroundText,
                                       hotkey: model.hotkey,
                                       isRecording: model.sessionState == .recording,
                                       didDictate: model.didDictate)
            case .liveTyping:
                OnboardingLiveTypingCard(item: item(SetupChecklist.liveTypingID),
                                         isSettled: model.liveTypingSettled,
                                         fix: { model.fix($0) },
                                         notNow: { model.settleLiveTyping() })
            }
        }
    }

    private func item(_ id: String) -> SetupItem? {
        model.items.first { $0.id == id }
    }

    // MARK: - footer

    /// `Back` · the progress rail · `Skip` or the primary action (§4.1). The
    /// rail is centred in the whole footer rather than laid out between the two
    /// buttons, so it does not shift when "Skip" becomes "Continue".
    private var footer: some View {
        ZStack {
            OnboardingProgressRail(segments: OnboardingFlow.segments(inputs))
            HStack(spacing: Theme.Space.s12) {
                backButton
                Spacer(minLength: Theme.Space.s16)
                trailingButton
            }
        }
        .padding(.horizontal, Theme.Space.s20)
        .frame(height: OnboardingMetrics.footerHeight)
    }

    private var backButton: some View {
        let target = OnboardingFlow.previous(before: model.onboardingStep, inputs)
        return Button {
            if let target { model.goToStep(target) }
        } label: {
            HStack(spacing: Theme.Space.s4) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .medium))
                Text("Back")
                    .font(Theme.font(Theme.Role.body))
            }
            .foregroundStyle(target == nil ? Theme.inkQuaternary : Theme.inkSecondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(target == nil)
    }

    @ViewBuilder
    private var trailingButton: some View {
        let trailing = OnboardingFlow.trailing(model.onboardingStep, inputs,
                                               micTestStalled: micTest.state.offersSkip)
        switch trailing {
        case .skip:
            Button {
                advance()
            } label: {
                HStack(spacing: Theme.Space.s4) {
                    Text("Skip")
                        .font(Theme.font(Theme.Role.body))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(Theme.inkSecondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        case .finish:
            Button(OnboardingFlow.trailingTitle(trailing)) { model.finishOnboarding() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        case .advance, .blocked:
            Button(OnboardingFlow.trailingTitle(trailing)) { advance() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(trailing == .blocked)
        }
    }

    /// `Do this later`, as §4.1's 12 pt `xmark` rather than a third footer
    /// button. The step is already persisted, so reopening resumes; what stays
    /// false is `onboarding_completed`, which is what makes the next launch
    /// raise the sheet again.
    private var closeButton: some View {
        Button {
            model.dismissOnboarding()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.inkTertiary)
                .frame(width: Theme.Size.hitTarget, height: Theme.Size.hitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("w", modifiers: .command)
        .help("Do this later")
        .accessibilityLabel("Do this later")
        .padding(Theme.Space.s8)
    }

    // MARK: - navigation

    private func advance() {
        if model.onboardingStep == .welcome {
            model.acknowledgeWelcome()
            // Acknowledging is itself a gate change, so the model may already
            // have walked the cascade forward. Moving again here would skip a
            // card the user never saw.
            if model.onboardingStep != .welcome { return }
        }
        if let next = OnboardingFlow.next(after: model.onboardingStep, model.onboardingInputs) {
            model.goToStep(next)
        } else {
            model.finishOnboarding()
        }
    }

    /// "I use an external keyboard" (§4.2). Choosing the right ⌥ key IS the
    /// answer to the 🌐 question — there is no 🌐 press left to intercept — so
    /// the card that asked it gets out of the way.
    private func chooseRightOption() {
        model.setHotkey(.rightOption)
        if model.onboardingStep == .globeKey { advance() }
    }

    // MARK: - the mic test's capture

    /// Restarting on a session change is not paranoia: the practice step is two
    /// cards away and the user has a hotkey. A dictation must own the input
    /// alone, so the probe yields for the duration and picks up again after.
    private struct MicTestRun: Equatable {
        let step: OnboardingStep
        let sessionIsIdle: Bool
    }

    private var micTestRun: MicTestRun {
        MicTestRun(step: model.onboardingStep, sessionIsIdle: model.sessionState == .idle)
    }

    private func runMicTest() async {
        guard model.onboardingStep == .micTest, model.sessionState == .idle else { return }
        await micTest.run { model.noteMicTestPassed() }
    }
}

// MARK: - the progress rail

/// Eight segments, 24 × 3, 4 pt gaps: `fillSubtle` → `ink` as each step is
/// satisfied (§4.1). Not a percentage and not a step counter — a filled segment
/// means *that* question is answered, which is the only claim the sheet can
/// make honestly while the user is free to skip forward.
private struct OnboardingProgressRail: View {
    let segments: [Bool]

    var body: some View {
        HStack(spacing: Theme.Space.s4) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, done in
                Capsule(style: .continuous)
                    .fill(done ? Theme.ink : Theme.fillSubtle)
                    .frame(width: OnboardingMetrics.segmentWidth,
                           height: OnboardingMetrics.segmentHeight)
            }
        }
        .animation(.easeOut(duration: 0.18), value: segments)
        .accessibilityElement()
        .accessibilityLabel("\(segments.filter { $0 }.count) of \(segments.count) steps done")
    }
}
#endif
