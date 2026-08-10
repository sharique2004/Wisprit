#if os(macOS)
import SwiftUI
import WispritMacUI

/// §4.1's sheet, in numbers. Sizes, not paddings — the 4 pt scale in
/// `Theme.Space` still governs everything inside a card.
enum OnboardingMetrics {
    static let sheetWidth: Double = 560
    static let sheetHeight: Double = 520
    static let footerHeight: Double = 56
    /// Body copy is centred and narrow: a 560 pt measure is a wall.
    static let proseWidth: Double = 380
    /// The progress rail's segments: 24 × 3, 4 pt gaps.
    static let segmentWidth: Double = 24
    static let segmentHeight: Double = 3
    /// §1.8's hero glyph.
    static let heroGlyph: Double = 34
    /// The mic test's Tally well (§4.2 step 3) — the 33-bar field is 293 pt and
    /// sits centred in it.
    static let tallyWell: Double = 340
    /// The practice field (§4.2 step 7).
    static let practiceField: Double = 110
    /// The live underline on provisional text: 1.5 pt, 4 pt below.
    static let liveUnderline: Double = 1.5
}

/// The two type roles the cascade needs that §1.3's table does not name
/// directly, spelled as `TypeRole`s so they stay inside the scale rather than
/// becoming loose `.system(size:)` calls.
enum OnboardingType {
    /// §1.3: the serif appears in exactly two situations, and this is the
    /// second one — the onboarding cover title. Never a paragraph, never a
    /// button.
    static let coverTitle = TypeRole("onboardingCoverTitle", size: 34,
                                     tracking: -0.4, family: .serif)
    /// §1.4: the practice field's live text is machine text — mono — but at
    /// body size, not the 11 pt caption `mono` is scaled for.
    static let practiceField = TypeRole("onboardingPracticeField", size: 13, family: .mono)
}

// MARK: - card chrome

/// One card, one decision — `docs/design/ui-redesign.md` §4.1.
///
/// The vertical rhythm is the wireframe's: 40 top, glyph, 24, title, 8,
/// message, 32, the decision, 20, the settings path. Every card in the cascade
/// is this shape, which is what makes eight consecutive permission asks read as
/// one flow instead of eight dialogs.
struct OnboardingCard<Content: View>: View {
    private let symbol: String?
    private let symbolTint: Color
    private let title: String
    private let titleRole: TypeRole
    private let message: String?
    private let hint: String?
    private let contentTopSpacing: Double
    private let content: Content

    init(symbol: String?,
         symbolTint: Color = Theme.inkSecondary,
         title: String,
         titleRole: TypeRole = Theme.Role.pageTitle,
         message: String? = nil,
         hint: String? = nil,
         contentTopSpacing: Double = Theme.Space.s32,
         @ViewBuilder content: () -> Content) {
        self.symbol = symbol
        self.symbolTint = symbolTint
        self.title = title
        self.titleRole = titleRole
        self.message = message
        self.hint = hint
        self.contentTopSpacing = contentTopSpacing
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: OnboardingMetrics.heroGlyph, weight: .light))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(symbolTint)
                    .padding(.bottom, Theme.Space.s24)
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(Theme.font(titleRole))
                .tracking(titleRole.tracking)
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let message {
                prose(message, role: Theme.Role.body, tint: Theme.inkSecondary)
                    .padding(.top, Theme.Space.s8)
            }
            // Wrapped, not padded directly: a modifier on a multi-view
            // `ViewBuilder` result applies to *each* view in it, which would
            // put the gap between the mic test's bars and its caption as well
            // as above them.
            VStack(spacing: 0) { content }
                .padding(.top, contentTopSpacing)
            if let hint {
                // The settings path is a literal value the user is about to
                // retype into a search field — machine text (§1.4).
                prose(hint, role: Theme.Role.mono, tint: Theme.inkTertiary)
                    .padding(.top, Theme.Space.s20)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, Theme.Space.s40)
        .padding(.horizontal, Theme.Space.s32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func prose(_ text: String, role: TypeRole, tint: Color) -> some View {
        Text(text)
            .font(Theme.font(role))
            .tracking(role.tracking)
            .foregroundStyle(tint)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: OnboardingMetrics.proseWidth)
    }
}

extension OnboardingCard where Content == EmptyView {
    init(symbol: String?,
         symbolTint: Color = Theme.inkSecondary,
         title: String,
         titleRole: TypeRole = Theme.Role.pageTitle,
         message: String? = nil,
         hint: String? = nil) {
        self.init(symbol: symbol, symbolTint: symbolTint, title: title,
                  titleRole: titleRole, message: message, hint: hint,
                  contentTopSpacing: 0) { EmptyView() }
    }
}

/// "There is nothing to do here" — the settled state of a permission card.
///
/// A card the user has already satisfied drops its remediation entirely. A
/// green check *and* three steps of instructions *and* a prominent "Quit &
/// Reopen Wisprit" is how a user with nothing to do restarts the app for no
/// reason.
struct OnboardingSettledLine: View {
    let text: String

    var body: some View {
        VStack(spacing: Theme.Space.s8) {
            HStack(spacing: Theme.Space.s8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.positive)
                Text("Done — nothing to do here.")
                    .font(Theme.font(Theme.Role.body))
                    .foregroundStyle(Theme.positive)
            }
            .accessibilityElement(children: .combine)
            if !text.isEmpty {
                Text(text)
                    .font(Theme.font(Theme.Role.caption))
                    .tracking(Theme.Role.caption.tracking)
                    .foregroundStyle(Theme.inkTertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: OnboardingMetrics.proseWidth)
            }
        }
    }
}

// MARK: - step 1

/// The cover. The one place in the app besides numerals where the serif is
/// allowed (§1.3).
struct OnboardingWelcomeCard: View {
    var body: some View {
        OnboardingCard(
            symbol: "waveform",
            title: "Hold a key. Talk. Let go.",
            titleRole: OnboardingType.coverTitle,
            message: "Wisprit types what you say into whatever app you are already "
                + "using. The recording, the transcription and the cleanup all happen "
                + "on this Mac — nothing is uploaded, and no audio is written to disk."
        ) {
            Text("macOS will not hand over the microphone, the dictation key or the "
                 + "keyboard on its own. The next few cards ask for them one at a time.")
                .font(Theme.font(Theme.Role.body))
                .foregroundStyle(Theme.inkSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: OnboardingMetrics.proseWidth)
        }
    }
}

// MARK: - steps 2, 5, 6

/// A permission card: one grant, one button, one settings path.
///
/// The copy above the button is the redesign's (§4.1); the button itself comes
/// from the `SetupItem` the Setup page draws, so the wizard cannot offer
/// "Allow Microphone" on a machine where the only remedy left is the
/// Privacy pane.
struct OnboardingPermissionCard: View {
    let item: SetupItem?
    let symbol: String
    let title: String
    let message: String
    let hint: String
    /// What to offer before the first probe has landed and `items` is empty.
    let unprobed: (SetupFixKind, String)
    let fix: (SetupFixKind) -> Void

    var body: some View {
        OnboardingCard(symbol: symbol,
                       title: title,
                       message: message,
                       hint: isSettled ? nil : hint) {
            if isSettled {
                OnboardingSettledLine(text: item?.detail ?? "")
            } else {
                VStack(spacing: Theme.Space.s12) {
                    HStack(spacing: Theme.Space.s8) {
                        Button(primary.1) { fix(primary.0) }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                        if let secondary {
                            Button(secondary.1) { fix(secondary.0) }
                                .buttonStyle(.bordered)
                                .controlSize(.large)
                        }
                    }
                    if let note = item?.note {
                        // Not orange (§1.6): a note explains macOS behaviour, it
                        // does not warn about it.
                        Text(note)
                            .font(Theme.font(Theme.Role.caption))
                            .tracking(Theme.Role.caption.tracking)
                            .foregroundStyle(Theme.inkSecondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: OnboardingMetrics.proseWidth)
                    }
                }
            }
        }
    }

    private var isSettled: Bool { item?.isSatisfied ?? false }

    private var primary: (SetupFixKind, String) {
        guard let item, item.fix != .none else { return unprobed }
        return (item.fix, item.fixTitle)
    }

    private var secondary: (SetupFixKind, String)? {
        guard let item, item.secondaryFix != .none else { return nil }
        return (item.secondaryFix, item.secondaryFixTitle)
    }
}

// MARK: - step 4

/// The 🌐 key — the only step in the cascade resolvable without a system
/// prompt, and the reason it now comes before Input Monitoring (§4.2).
///
/// The keycap is the subject of the decision, so it sits where the decision is
/// rather than as a hero glyph above the title.
struct OnboardingGlobeKeyCard: View {
    let usage: GlobeKeyUsage
    let fix: (SetupFixKind) -> Void
    let useRightOption: () -> Void

    var body: some View {
        OnboardingCard(
            symbol: nil,
            title: "Give the 🌐 key back",
            message: usage.isClear
                ? "Nothing else is using it, so a press reaches Wisprit."
                : "macOS gives the 🌐 key a job of its own — usually the emoji picker. "
                  + "While it has one, pressing it does that instead of starting "
                  + "Wisprit, which looks exactly like Wisprit being broken.",
            hint: usage.isClear
                ? nil
                : "System Settings ▸ Keyboard ▸ “Press 🌐 key to” → Do Nothing"
        ) {
            VStack(spacing: Theme.Space.s24) {
                KeycapView(symbol: "globe", label: "fn", size: .large)
                if usage.isClear {
                    OnboardingSettledLine(text: usage.advice)
                } else {
                    VStack(spacing: Theme.Space.s12) {
                        HStack(spacing: Theme.Space.s8) {
                            Button("Open Keyboard Settings") { fix(.openKeyboardSettings) }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.large)
                            Button("I use an external keyboard") { useRightOption() }
                                .buttonStyle(.bordered)
                                .controlSize(.large)
                        }
                        Text("Many external keyboards never send Fn to macOS at all. "
                             + "That switches the dictation key to the right ⌥ key, "
                             + "which makes this question moot.")
                            .font(Theme.font(Theme.Role.caption))
                            .tracking(Theme.Role.caption.tracking)
                            .foregroundStyle(Theme.inkTertiary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: OnboardingMetrics.proseWidth)
                    }
                }
            }
        }
    }
}

// MARK: - step 7

/// The practice moment (§4.2 step 7) — the only step that can *prove* the whole
/// chain works, because it runs it.
///
/// Two live signals, and both are real:
///
///  * The keycap takes its held state while `sessionState == .recording`. That
///    is §4.4's fourth sanctioned orange, and it is correct by definition: the
///    key is down, so the microphone is open.
///  * The field takes a 1.5 pt `hot` underline for the same window — the site's
///    `.volatile` rule, and the only place in the Hub where orange touches
///    text. The spec draws it under the provisional glyph run; there is no
///    per-range seam into a focused `TextEditor`, and the field has to *stay* a
///    focused `TextEditor` or the dictation lands somewhere else, so the rule
///    runs under the field instead. Same grammar, same meaning, same lifetime.
///
/// What is deliberately absent is the wireframe's inline 28 pt Tally. Levels
/// reach the pill through `SessionController`'s `pill-level` thread and
/// terminate at `PillPort`; there is no read-only path back to the window
/// without editing files §6.6 reserves. Opening a second capture instead would
/// break the rule that no page adds main-thread work while a key is held
/// (§6.4) — and the pill, which is on screen during this exact hold, is already
/// drawing the real one.
struct OnboardingPracticeCard: View {
    @Binding var text: String
    let hotkey: WindowSettings.HotkeyOption
    let isRecording: Bool
    let didDictate: Bool

    var body: some View {
        OnboardingCard(symbol: nil,
                       title: "Try it right here",
                       contentTopSpacing: Theme.Space.s8) {
            VStack(spacing: Theme.Space.s24) {
                instruction
                field
                outcome
            }
        }
    }

    private var instruction: some View {
        HStack(spacing: Theme.Space.s8) {
            Text("Hold")
            KeycapView(symbol: hotkey == .fn ? "globe" : "option",
                       label: hotkey == .fn ? "fn" : "opt",
                       size: .small, isHeld: isRecording)
            Text(", say a sentence, let go.")
        }
        .font(Theme.font(Theme.Role.body))
        .foregroundStyle(Theme.inkSecondary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Hold \(SetupChecklist.hotkeyLabel(hotkey.rawValue)), "
                            + "say a sentence, let go.")
    }

    private var field: some View {
        TextEditor(text: $text)
            .font(Theme.font(OnboardingType.practiceField))
            .foregroundStyle(Theme.ink)
            .scrollContentBackground(.hidden)
            .padding(Theme.Space.s12)
            .frame(height: OnboardingMetrics.practiceField)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                    .fill(Theme.groundRecessed)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1)
            )
            .overlay(alignment: .bottom) { underline }
            .accessibilityLabel("Practice field")
    }

    @ViewBuilder
    private var underline: some View {
        if isRecording {
            Rectangle()
                .fill(Theme.hot(.liveTranscriptRow))
                .frame(height: OnboardingMetrics.liveUnderline)
                .padding(.horizontal, Theme.Space.s12)
                .padding(.bottom, Theme.Space.s4)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var outcome: some View {
        if didDictate {
            HStack(spacing: Theme.Space.s8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.positive)
                Text("That worked.")
                    .font(Theme.font(Theme.Role.body))
                    .foregroundStyle(Theme.positive)
            }
            .accessibilityElement(children: .combine)
        } else {
            Text("Nothing yet. If the key does nothing at all, go back to Input "
                 + "Monitoring — that is almost always the reason.")
                .font(Theme.font(Theme.Role.caption))
                .tracking(Theme.Role.caption.tracking)
                .foregroundStyle(Theme.inkTertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: OnboardingMetrics.proseWidth)
        }
    }
}

// MARK: - step 8

/// Live Typing — the last question, and the only one whose honest answer is
/// often "no".
struct OnboardingLiveTypingCard: View {
    let item: SetupItem?
    let isSettled: Bool
    let fix: (SetupFixKind) -> Void
    let notNow: () -> Void

    var body: some View {
        OnboardingCard(
            symbol: "text.cursor",
            title: "Watch the words arrive",
            message: "Optional. Wisprit normally pastes the finished sentence when you "
                + "let go of the key. Live Typing streams the words into the field "
                + "while you are still speaking.",
            hint: nil
        ) {
            if item?.isSatisfied ?? false {
                OnboardingSettledLine(text: item?.detail ?? "")
            } else {
                VStack(spacing: Theme.Space.s12) {
                    HStack(spacing: Theme.Space.s8) {
                        Button(enableTitle) { fix(.enableLiveTyping) }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                        // "Not now" is an answer, and once given it is not asked
                        // again — that is what `liveTypingSettled` means.
                        if !isSettled {
                            Button("Not now") { notNow() }
                                .buttonStyle(.bordered)
                                .controlSize(.large)
                        }
                    }
                    Text("Turning it on installs a small input method into your Input "
                         + "Sources and macOS asks you to approve it. "
                         + SetupChecklist.liveTypingPerAppNote)
                        .font(Theme.font(Theme.Role.caption))
                        .tracking(Theme.Role.caption.tracking)
                        .foregroundStyle(Theme.inkTertiary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: OnboardingMetrics.proseWidth)
                }
            }
        }
    }

    private var enableTitle: String {
        guard let title = item?.fixTitle, !title.isEmpty else { return "Enable Live Typing…" }
        return title
    }
}

// MARK: - completion

/// §4.3 — inside step 8's card, not a ninth step. The wizard used to dismiss
/// itself on the first tick where everything was satisfied, so a user on a
/// healthy machine watched a panel appear and vanish with no "you're set up"
/// anywhere, which reads as a glitch. `Open Wisprit` in the footer is the only
/// way out of this one.
struct OnboardingCompletionCard: View {
    let hotkeyLabel: String

    var body: some View {
        OnboardingCard(symbol: "checkmark.seal.fill",
                       symbolTint: Theme.positive,
                       title: "You're set.",
                       message: "Hold \(hotkeyLabel) anywhere you can type.")
    }
}
#endif
