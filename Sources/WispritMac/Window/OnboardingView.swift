#if os(macOS)
import SwiftUI

/// First run, one thing at a time.
///
/// The order is the order that minimises relaunches, and each page states the
/// macOS behaviour that makes it confusing — above all the one that cost the
/// user an hour: Input Monitoring is never prompted for, and it only takes
/// effect when the app next launches.
struct OnboardingView: View {
    @ObservedObject var model: WispritWindowModel

    var body: some View {
        HStack(spacing: 0) {
            stepList
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    body(for: model.onboardingStep)
                        .padding(28)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                footer
            }
        }
        .frame(width: 720, height: 540)
    }

    // MARK: - Step list

    private var stepList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Set up Wisprit")
                .font(.headline)
                .padding(.horizontal, 18).padding(.top, 20).padding(.bottom, 12)

            ForEach(OnboardingStep.allCases, id: \.self) { step in
                let done = OnboardingModel.isSatisfied(step, model.onboardingInputs)
                Button {
                    model.goToStep(step)
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: done ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(done ? Color.green : Color.secondary)
                        Text(step.title)
                            .foregroundStyle(step == model.onboardingStep ? .primary : .secondary)
                            .fontWeight(step == model.onboardingStep ? .semibold : .regular)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 18).padding(.vertical, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(step == model.onboardingStep
                            ? Color.accentColor.opacity(0.12) : Color.clear)
            }

            Spacer()
            ProgressView(value: model.onboardingProgress)
                .padding(.horizontal, 18).padding(.bottom, 18)
        }
        .frame(width: 210)
        .background(.quaternary.opacity(0.25))
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Button("Back") { back() }
                .disabled(model.onboardingStep == OnboardingStep.allCases.first)
            Spacer()
            Button("Do this later") { model.dismissOnboarding() }
            if model.onboardingStep == OnboardingStep.allCases.last {
                Button("Finish") { model.finishOnboarding() }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button(continueTitle) { advance() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    /// "Skip for now" is only honest when there is something the user has not
    /// done. Reading the welcome page IS doing it, so that page always continues.
    private var continueTitle: String {
        if model.onboardingStep == .welcome { return "Continue" }
        return OnboardingModel.isSatisfied(model.onboardingStep, model.onboardingInputs)
            ? "Continue" : "Skip for now"
    }

    private func advance() {
        if model.onboardingStep == .welcome {
            model.acknowledgeWelcome()
            if model.onboardingStep == .welcome { model.skipStep() }
        } else {
            model.skipStep()
        }
    }

    private func back() {
        guard let index = OnboardingStep.allCases.firstIndex(of: model.onboardingStep),
              index > 0 else { return }
        model.goToStep(OnboardingStep.allCases[index - 1])
    }

    // MARK: - Pages

    @ViewBuilder
    private func body(for step: OnboardingStep) -> some View {
        switch step {
        case .welcome: welcomePage
        case .microphone: permissionPage(id: SetupChecklist.microphoneID)
        case .inputMonitoring: inputMonitoringPage
        case .accessibility: permissionPage(id: SetupChecklist.accessibilityID)
        case .globeKey: globeKeyPage
        case .tryIt: tryItPage
        case .liveTyping: liveTypingPage
        }
    }

    private var welcomePage: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "waveform")
                .font(.system(size: 44)).foregroundStyle(Color.accentColor)
            Text("Hold a key. Talk. Let go.").font(.title).fontWeight(.semibold)
            Text("""
                Wisprit types what you say into whatever app you are already using. \
                Everything — the recording, the transcription, the cleanup — happens \
                on this Mac. Nothing is uploaded and no audio is written to disk.
                """)
                .font(.body).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("""
                macOS needs to give Wisprit three permissions before any of that can \
                work, and it will not ask for them on its own. The next few pages do \
                them one at a time.
                """)
                .font(.body).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Two states, one page.
    ///
    /// A satisfied step drops the remediation entirely. Showing a green check
    /// beside "Input Monitoring" *and* three steps of instructions *and* a
    /// prominent "Quit & Reopen Wisprit" button is how a user who has nothing to
    /// do restarts the app for no reason.
    private func permissionPage(id: String) -> some View {
        let item = model.items.first { $0.id == id }
        let done = item?.isSatisfied ?? false
        return VStack(alignment: .leading, spacing: 16) {
            header(item)
            if let item {
                if done {
                    settledLine(item.detail)
                } else {
                    Text(item.summary).font(.body).fixedSize(horizontal: false, vertical: true)
                    if let note = item.note {
                        Label(note, systemImage: "info.circle")
                            .font(.callout).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(item.detail).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if item.fix != .none {
                        Button(item.fixTitle) { model.fix(item.fix) }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
    }

    private var inputMonitoringPage: some View {
        let item = model.items.first { $0.id == SetupChecklist.inputMonitoringID }
        let done = item?.isSatisfied ?? false
        return VStack(alignment: .leading, spacing: 16) {
            header(item)
            if done {
                settledLine(item?.detail ?? "")
                Text("This is the permission that most often goes wrong later — if "
                     + "the key ever stops working, come back here first.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("""
                    This is the one macOS handles worst, so read it once: Wisprit cannot \
                    make this prompt appear, and switching it on while Wisprit is running \
                    changes nothing.
                    """)
                    .font(.body).fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 10) {
                    numbered(1, "Open the Input Monitoring list.")
                    numbered(2, "Switch Wisprit on. Use the + button if it is not listed.")
                    numbered(3, "Quit Wisprit and open it again — the permission only takes "
                                + "effect at launch.")
                }
                .padding(.leading, 2)

                HStack(spacing: 10) {
                    Button("Open Input Monitoring") { model.fix(.requestInputMonitoring) }
                        .buttonStyle(.borderedProminent)
                    Button("Quit & Reopen Wisprit") { model.fix(.relaunch) }
                }

                if let item {
                    Label(item.detail, systemImage: "clock")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var globeKeyPage: some View {
        let clear = model.globeKey.isClear
        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                StatusDot(mark: clear ? .ok : .warn)
                Text("The 🌐 key").font(.title2).fontWeight(.semibold)
            }
            if clear {
                settledLine(model.globeKey.advice)
            } else {
                Text("""
                    By default macOS gives the 🌐 key its own job — usually the emoji \
                    picker or Apple's dictation. If it still has one, pressing it will do \
                    that instead of starting Wisprit, which looks exactly like Wisprit \
                    being broken.
                    """)
                    .font(.body).fixedSize(horizontal: false, vertical: true)
                Label(model.globeKey.advice, systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Text("System Settings ▸ Keyboard ▸ “Press 🌐 key to” → Do Nothing")
                    .font(.callout).monospaced().foregroundStyle(.secondary)
                Button("Open Keyboard Settings") { model.fix(.openKeyboardSettings) }
                    .buttonStyle(.borderedProminent)
            }
            Button("I use an external keyboard") { model.setHotkey(.rightOption) }
            Text("On many external keyboards Fn never reaches macOS at all. "
                 + "That button switches the hotkey to the right ⌥ key instead.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var tryItPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                StatusDot(mark: model.didDictate ? .ok : .warn)
                Text("Try a dictation").font(.title2).fontWeight(.semibold)
            }
            Text("Click in the box, hold "
                 + "\(SetupChecklist.hotkeyLabel(model.hotkey.rawValue)), say a sentence, "
                 + "then let go.")
                .font(.body).fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $model.playgroundText)
                .font(.body)
                .frame(height: 110)
                .padding(6)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
            if model.didDictate {
                Label("That worked — Wisprit is set up.", systemImage: "checkmark.circle.fill")
                    .font(.callout).foregroundStyle(.green)
            } else {
                Text("Nothing yet. If the key does nothing at all, go back to Input "
                     + "Monitoring — that is almost always the reason.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The last page, and therefore also the finish line.
    ///
    /// When there is nothing left to ask it becomes the completion moment the
    /// wizard used to skip: it dismissed itself on the first tick where
    /// everything was satisfied, so a user on an already-healthy machine watched
    /// a panel appear and vanish with no "you're set up" anywhere.
    private var liveTypingPage: some View {
        let item = model.items.first { $0.id == SetupChecklist.liveTypingID }
        return VStack(alignment: .leading, spacing: 16) {
            if model.isOnboardingComplete { completionBanner }
            header(item)
            Text("""
                Optional. Normally Wisprit pastes the finished sentence when you let \
                go of the key. Live Typing streams the words into the field while you \
                are still speaking, the way the system dictation does.
                """)
                .font(.body).fixedSize(horizontal: false, vertical: true)
            Text(SetupChecklist.liveTypingPerAppNote)
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("""
                Turning it on installs a small input method into your Input Sources \
                and macOS asks you to approve it. Everything keeps working without it.
                """)
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let item, !item.isSatisfied {
                Button(item.fixTitle) { model.fix(item.fix) }
                    .buttonStyle(.borderedProminent)
            }
            if !model.liveTypingSettled {
                Button("No thanks, paste at the end") { model.settleLiveTyping() }
            }
            if let item {
                Text(item.detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var completionBanner: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 26)).foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 4) {
                Text("Wisprit is set up.").font(.title3).fontWeight(.semibold)
                Text("Hold \(SetupChecklist.hotkeyLabel(model.hotkey.rawValue)) anywhere "
                     + "you can type. Press Finish to close this guide — you can reopen "
                     + "it any time from the Status page.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Bits

    private func header(_ item: SetupItem?) -> some View {
        HStack(spacing: 10) {
            StatusDot(mark: item?.mark ?? .warn)
            Text(item?.title ?? model.onboardingStep.title)
                .font(.title2).fontWeight(.semibold)
        }
    }

    /// A step with nothing left to do says so, and stops there.
    private func settledLine(_ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Done — nothing to do here.", systemImage: "checkmark.circle.fill")
                .font(.body).foregroundStyle(.green)
            if !detail.isEmpty {
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func numbered(_ index: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(index)")
                .font(.caption).fontWeight(.bold)
                .frame(width: 20, height: 20)
                .background(Color.accentColor.opacity(0.18), in: Circle())
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }
}
#endif
