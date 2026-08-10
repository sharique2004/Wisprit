import Foundation

/// The main window's permission checklist.
///
/// Every mark, every remedy string and every required-ness verdict comes from
/// `Doctor.report(from:)` — the same pure builder `wisprit doctor` prints. This
/// file adds only what a window needs and a terminal does not: a plain-language
/// one-liner, the macOS nuance that bit the user (Input Monitoring applies at
/// *launch*), and a machine-readable "what button fixes this" tag.
///
/// Nothing here probes anything. It is a function of `DoctorFacts`, so the whole
/// checklist — including the states you can only reach by revoking a TCC grant —
/// is testable without touching System Settings.

// MARK: - Fixes

/// What the FIX button on a row actually does. The window maps these to real
/// calls (`CGRequestListenEventAccess`, `AVCaptureDevice.requestAccess`, the
/// existing Enable Live Typing flow, a relaunch); the model only names them, so
/// the mapping is assertable in tests.
public enum SetupFixKind: String, Sendable, Equatable {
    /// Nothing to do — the row is green.
    case none
    /// Undetermined: raise the real system prompt.
    case requestMicrophone
    /// Denied: only System Settings can undo that.
    case openMicrophoneSettings
    /// `CGRequestListenEventAccess()` (lands the app in the list), then the pane.
    case requestInputMonitoring
    /// Quit and relaunch this bundle — the only way a new Input Monitoring grant
    /// takes effect.
    case relaunch
    /// `AXIsProcessTrustedWithOptions` prompt, then the pane. macOS requires the
    /// user to add the app by hand, so the pane is not optional here.
    case openAccessibilitySettings
    /// Speech assets for the configured locale install through the Dictation
    /// languages list.
    case openKeyboardSettings
    case openAppleIntelligenceSettings
    /// The existing "Enable Live Typing…" onboarding (installs + registers the
    /// input method, raises the system activation dialog).
    case enableLiveTyping
    /// Fold the learn loop's junk entries back into the terms they are garbled
    /// spellings of. The user's dictionary is never edited without this button:
    /// see `LearnedTermCleanup`, which writes `dictionary.json.bak` first.
    case cleanLearnedTerms
    /// The context-awareness consent flow (sheet → optional AX prompt → flip).
    /// Consent is never granted by a bare toggle: the Settings page routes its
    /// enable through this fix, so every road to on runs the sheet.
    case enableContextAwareness

    /// System Settings deep link, when the fix is "open a pane".
    public var settingsURL: String? {
        switch self {
        case .openMicrophoneSettings:
            return "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        case .requestInputMonitoring:
            return "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
        case .openAccessibilitySettings:
            return "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case .openKeyboardSettings:
            return "x-apple.systempreferences:com.apple.Keyboard-Settings.extension"
        case .openAppleIntelligenceSettings:
            return "x-apple.systempreferences:com.apple.Siri-Settings.extension"
        case .none, .requestMicrophone, .relaunch, .enableLiveTyping, .cleanLearnedTerms,
             .enableContextAwareness:
            return nil
        }
    }
}

// MARK: - One row

public struct SetupItem: Identifiable, Sendable, Equatable {
    /// Stable key — the doctor label is the display name, this is what tests and
    /// the onboarding wizard address a row by.
    public var id: String
    /// The `Doctor.report(from:)` check this row speaks for, by label.
    ///
    /// Recorded rather than implied so the "the window shows the whole doctor"
    /// property is assertable: a required check with no row carrying its label
    /// fails a test instead of silently disappearing from the window.
    public var doctorLabel: String
    public var title: String
    /// Straight from the doctor check of the same label.
    public var mark: DoctorMark
    /// Straight from the doctor check: a red required row is what "Needs setup"
    /// counts, so the window and `wisprit doctor` agree on ready-or-not.
    ///
    /// It is NOT the same question as "does the user need this". The doctor's
    /// required flag is an exit-code rule: Microphone is only required once it
    /// is *denied*, and Input Monitoring stops being required as soon as
    /// Accessibility is granted (the documented `IOHIDCheckAccess` staleness
    /// leniency). Labelling either of those "optional" in a window would be a
    /// lie — that is what `isEssential` is for.
    public var isRequired: Bool
    /// Whether dictation works at all without this. Fixed per row, and the only
    /// thing the "optional" badge is allowed to read.
    public var isEssential: Bool
    /// The user has switched this feature off, so a green check would be a lie
    /// even when everything it needs is installed and working.
    ///
    /// Distinct from a bad mark: nothing is broken and there is nothing to nag
    /// about, so an off row is drawn grey and left out of the hero's counts.
    public var isOff: Bool
    /// One line, in the user's language, about why Wisprit wants this.
    public var summary: String
    /// The doctor's own detail/remedy string, verbatim.
    public var detail: String
    /// The macOS behaviour that is not discoverable from the pane itself.
    public var note: String?
    public var fix: SetupFixKind
    /// Button label for `fix`; empty when there is nothing to do.
    public var fixTitle: String
    /// An extra affordance the row sometimes needs (the relaunch button that
    /// makes an Input Monitoring grant take effect).
    public var secondaryFix: SetupFixKind
    public var secondaryFixTitle: String

    public init(id: String, doctorLabel: String = "", title: String,
                mark: DoctorMark, isRequired: Bool,
                isEssential: Bool = true, isOff: Bool = false,
                summary: String, detail: String, note: String? = nil,
                fix: SetupFixKind = .none, fixTitle: String = "",
                secondaryFix: SetupFixKind = .none, secondaryFixTitle: String = "") {
        self.id = id
        self.doctorLabel = doctorLabel
        self.title = title
        self.mark = mark
        self.isRequired = isRequired
        self.isEssential = isEssential
        self.isOff = isOff
        self.summary = summary
        self.detail = detail
        self.note = note
        self.fix = fix
        self.fixTitle = fixTitle
        self.secondaryFix = secondaryFix
        self.secondaryFixTitle = secondaryFixTitle
    }

    /// Green: everything this row needs is in place AND the user has it on.
    public var isSatisfied: Bool { mark == .ok && !isOff }
    /// A row that stops dictation from working at all.
    public var isBlocking: Bool { isRequired && mark != .ok }
}

// MARK: - Hero

public enum SetupHero: Sendable, Equatable {
    /// No probe has completed yet — the window opens in this state.
    case checking
    case ready
    case needsSetup(blocking: Int)
}

public struct SetupSummary: Sendable, Equatable {
    public var hero: SetupHero
    public var headline: String
    public var subhead: String

    public init(hero: SetupHero, headline: String, subhead: String) {
        self.hero = hero
        self.headline = headline
        self.subhead = subhead
    }
}

// MARK: - Builder

public enum SetupChecklist {

    public static let microphoneID = "microphone"
    public static let inputMonitoringID = "input_monitoring"
    public static let accessibilityID = "accessibility"
    public static let postEventID = "post_event"
    public static let speechID = "speech"
    public static let appleIntelligenceID = "apple_intelligence"
    public static let liveTypingID = "live_typing"
    public static let learnedTermsID = "learned_terms"

    /// The nuance that cost the user an hour: the grant binds when the event tap
    /// is created, so a toggle flipped while Wisprit is running changes nothing
    /// until the process starts again.
    public static let relaunchNote =
        "macOS applies Input Monitoring only when an app launches. After you switch "
        + "Wisprit on in the list, quit and reopen it — the button below does both."

    /// Live Typing is per-app, and saying so is not a footnote.
    ///
    /// `InsertionLadder` keeps a per-bundle delivery tier and downgrades
    /// imStreaming → imCommit → paste the moment an app refuses marked text;
    /// terminals never get the streaming rung at all. Every string that
    /// described the feature promised streaming unconditionally, so a user who
    /// switched it on, dictated into Terminal or an Electron field, and saw
    /// paste-at-the-end concluded the feature — or Wisprit — was broken. That
    /// invisible fallback is the exact confusion this window exists to end.
    public static let liveTypingPerAppNote =
        "Some apps (terminals, and some browser and Electron text fields) don't "
        + "accept live text. Wisprit notices and quietly pastes at the end there "
        + "instead — nothing is lost either way."

    /// The plain-language banner for a transient condition that no permission
    /// can fix and no checklist row should nag about once it clears.
    ///
    /// Secure Keyboard Entry is the reason a perfectly healthy Wisprit can look
    /// dead: while a password field (or an app like Slack) holds it, macOS never
    /// delivers the dictation key at all. The doctor prints it as a check; a
    /// window has to say it where the user is already looking.
    public static func secureInputNotice(_ facts: DoctorFacts) -> String? {
        guard facts.secureInputActive else { return nil }
        return "A password field is open somewhere — macOS switches off the "
            + "dictation key until it closes. Nothing is broken; close or leave "
            + "that field and try again."
    }

    /// The window's seven rows, in the order a first-time user should read them.
    ///
    /// The marks are not recomputed here: each row looks up the doctor check of
    /// the same label, so the window and `wisprit doctor` can never disagree.
    /// Where one row stands for more than one check (Live Typing), it takes the
    /// worst of them rather than the first.
    public static func items(from facts: DoctorFacts) -> [SetupItem] {
        let report = Doctor.report(from: facts)
        func check(_ label: String) -> DoctorCheck {
            report.check(label) ?? DoctorCheck(.warn, label, "not reported yet")
        }

        var items: [SetupItem] = []

        // 1. Microphone — the only one macOS prompts for on its own.
        let mic = check("Microphone")
        items.append(SetupItem(
            id: microphoneID,
            doctorLabel: "Microphone",
            title: "Microphone",
            mark: mic.mark,
            isRequired: mic.isRequired,
            summary: "Wisprit records only while you hold the dictation key. "
                + "The audio is transcribed on this Mac and never uploaded or saved.",
            detail: mic.detail,
            fix: micFix(facts.microphone),
            fixTitle: micFixTitle(facts.microphone)))

        // 2. Input Monitoring — never auto-prompted, and only applied at launch.
        let listen = check("Input Monitoring")
        let listenGranted = facts.inputMonitoring == "granted"
        items.append(SetupItem(
            id: inputMonitoringID,
            doctorLabel: "Input Monitoring",
            title: "Input Monitoring",
            mark: listen.mark,
            isRequired: listen.isRequired,
            summary: "Lets Wisprit notice the dictation key going down and up. "
                + "It watches for that one key and posts nothing.",
            detail: listen.detail,
            note: listenGranted ? nil : relaunchNote,
            fix: listenGranted ? .none : .requestInputMonitoring,
            fixTitle: listenGranted ? "" : "Open Input Monitoring",
            secondaryFix: listenGranted ? .none : .relaunch,
            secondaryFixTitle: listenGranted ? "" : "Quit & Reopen Wisprit"))

        // 3. Accessibility — macOS never prompts with a working add button, so
        //    the pane is part of the fix, not a fallback.
        let ax = check("Accessibility")
        items.append(SetupItem(
            id: accessibilityID,
            doctorLabel: "Accessibility",
            title: "Accessibility",
            mark: ax.mark,
            isRequired: ax.isRequired,
            summary: "Lets Wisprit put the finished text into whatever you were "
                + "typing in. Without it macOS silently drops the paste.",
            detail: ax.detail,
            note: ax.mark == .ok ? nil
                : "macOS will not add Wisprit for you: switch it on in the list "
                  + "that opens, using the + button if Wisprit is not there yet.",
            fix: ax.mark == .ok ? .none : .openAccessibilitySettings,
            fixTitle: ax.mark == .ok ? "" : "Open Accessibility"))

        // 4. Post-event access — the other half of the Accessibility grant, and
        //    the half that fails *silently*: `AXIsProcessTrusted` can already be
        //    true while `CGPreflightPostEventAccess` is still false (the grant
        //    binds to the process at launch), and in that window every paste is
        //    dropped with no error anywhere. Without this row the checklist can
        //    be all green while nothing is ever typed.
        let post = check("Post-event access")
        items.append(SetupItem(
            id: postEventID,
            doctorLabel: "Post-event access",
            title: "Sending the paste keystroke",
            mark: post.mark,
            isRequired: post.isRequired,
            summary: "macOS also has to let Wisprit press ⌘V for you. It comes "
                + "from the same Accessibility switch — but only from the moment "
                + "Wisprit next starts.",
            detail: post.detail,
            note: post.mark == .ok ? nil
                : "Accessibility above can read green while this is still off. "
                  + "That is the state where dictation looks like it does nothing: "
                  + "quit and reopen Wisprit to clear it.",
            fix: post.mark == .ok ? .none : .openAccessibilitySettings,
            fixTitle: post.mark == .ok ? "" : "Open Accessibility",
            secondaryFix: post.mark == .ok ? .none : .relaunch,
            secondaryFixTitle: post.mark == .ok ? "" : "Quit & Reopen Wisprit"))

        // 5. Speech assets for the configured locale.
        let speech = check("SpeechTranscriber (on-device ASR)")
        items.append(SetupItem(
            id: speechID,
            doctorLabel: "SpeechTranscriber (on-device ASR)",
            title: "Speech model (\(facts.requestedLocale))",
            mark: speech.mark,
            isRequired: speech.isRequired,
            summary: "Apple's on-device speech recognition, which is what actually "
                + "turns your voice into text. Nothing is sent to a server.",
            detail: speech.detail,
            note: speech.mark == .ok ? nil
                : "Add \(facts.requestedLocale) under Keyboard ▸ Dictation ▸ Languages; "
                  + "macOS downloads the model once and keeps it.",
            fix: speech.mark == .ok ? .none : .openKeyboardSettings,
            fixTitle: speech.mark == .ok ? "" : "Open Keyboard Settings"))

        // 6. Apple Intelligence — optional by design; dictation degrades to the
        //    deterministic pipeline without it.
        let ai = check("AI cleanup (Apple Intelligence)")
        items.append(SetupItem(
            id: appleIntelligenceID,
            doctorLabel: "AI cleanup (Apple Intelligence)",
            title: "Apple Intelligence",
            mark: ai.mark,
            isRequired: ai.isRequired,
            isEssential: false,
            summary: "Optional. Tidies filler words and punctuation on-device. "
                + "Dictation works without it — the text just stays verbatim.",
            detail: ai.detail,
            fix: ai.mark == .ok ? .none : .openAppleIntelligenceSettings,
            fixTitle: ai.mark == .ok ? "" : "Open Apple Intelligence"))

        // 7. Live Typing — the optional in-field streaming tier.
        //
        // Three doctor checks land on this one row. The bundle check is the one
        // that matters most and is emitted only once WispritIM.app is installed:
        // a `.bad` there is a half-finished update whose input method registers,
        // is selected, and then never receives a client. Reading only the
        // registration check would paint that green.
        let live = check(Doctor.liveTypingLabel)
        let bridge = check(Doctor.liveTypingBridgeLabel)
        let bundle = report.check(Doctor.liveTypingBundleLabel)
        let installMark = DoctorMark.worst(live.mark, bundle?.mark)
        let installed = installMark == .ok
        // The `live_typing` setting. Installed-but-switched-off is a perfectly
        // ordinary state (it ships off), so it is drawn grey rather than orange —
        // but never green, because green here means "words appear as you speak"
        // and they do not.
        let switchedOff = !facts.liveTypingEnabled
        let liveDetail: String
        if let bundle, bundle.mark == .bad {
            liveDetail = bundle.detail
        } else if installed {
            liveDetail = bridge.detail
        } else {
            liveDetail = live.detail
        }
        items.append(SetupItem(
            id: liveTypingID,
            doctorLabel: Doctor.liveTypingLabel,
            title: "Live Typing",
            mark: installMark,
            isRequired: live.isRequired,
            isEssential: false,
            isOff: switchedOff,
            summary: switchedOff
                ? "Optional, and switched off. Wisprit pastes the finished text "
                  + "in one go when you let the key go. Turn it on to watch the "
                  + "words arrive as you speak."
                : "Optional. Types words into the field as you speak instead of "
                  + "pasting them all at the end. " + liveTypingPerAppNote,
            detail: liveDetail,
            fix: (installed && !switchedOff) ? .none : .enableLiveTyping,
            fixTitle: (installed && !switchedOff)
                ? ""
                : (switchedOff && installed ? "Turn On Live Typing…" : "Enable Live Typing…")))

        // 8. Learned spellings that need folding back — the one row that
        //    appears only when there is something to do. It is not a permission
        //    and not a setup step: a clean dictionary has nothing to say here,
        //    and an always-green eighth row would be noise on every install.
        if !facts.learnedTerms.suspects.isEmpty {
            let learned = check(Doctor.learnedTermsLabel)
            let count = facts.learnedTerms.suspects.count
            items.append(SetupItem(
                id: learnedTermsID,
                doctorLabel: Doctor.learnedTermsLabel,
                title: "Learned spellings",
                mark: learned.mark,
                isRequired: learned.isRequired,
                isEssential: false,
                summary: "Wisprit learned \(count) spelling\(count == 1 ? "" : "s") that "
                    + "look like garbled versions of words it already knows. Cleaning them "
                    + "up folds each one back into the right word — your own entries are "
                    + "left alone, and a backup is written first.",
                detail: learned.detail,
                fix: .cleanLearnedTerms,
                fixTitle: Doctor.cleanLearnedTermsTitle))
        }

        return items
    }

    // MARK: - Hero

    /// `hotkeyLabel` is the human name of the configured trigger, so the hero
    /// line tells the user which key to actually hold.
    public static func summary(items: [SetupItem],
                               hotkeyLabel: String,
                               dictationEnabled: Bool = true,
                               hasProbed: Bool = true) -> SetupSummary {
        guard hasProbed else {
            return SetupSummary(hero: .checking,
                                headline: "Checking…",
                                subhead: "Looking at permissions and the speech model.")
        }
        let blocking = items.filter(\.isBlocking)
        guard blocking.isEmpty else {
            let names = blocking.map(\.title).joined(separator: ", ")
            return SetupSummary(
                hero: .needsSetup(blocking: blocking.count),
                headline: "Needs setup",
                subhead: blocking.count == 1
                    ? "\(names) is still missing. Fix it below and you're done."
                    : "\(blocking.count) things are still missing: \(names).")
        }
        guard dictationEnabled else {
            return SetupSummary(
                hero: .ready,
                headline: "Dictation is off",
                subhead: "Everything is set up. Turn dictation back on in Settings.")
        }
        let headline = "Ready — hold \(hotkeyLabel) to dictate"

        // An essential row that is not green while nothing is *provably*
        // blocking: an undetermined Input Monitoring read, or post-event access
        // that has not caught up with the Accessibility grant. The doctor's
        // exit-code rule forgives both (and the window must not disagree with
        // it), but they are exactly the states where dictation fails without
        // saying anything — so the hero names them instead of a flat "Ready".
        let unresolved = items.filter { $0.isEssential && $0.mark != .ok }
        guard unresolved.isEmpty else {
            let names = unresolved.map(\.title).joined(separator: ", ")
            return SetupSummary(
                hero: .ready,
                headline: headline,
                subhead: "Still worth a look below: \(names). macOS can drop the "
                    + "text without a word while \(unresolved.count == 1 ? "that is" : "those are") unresolved.")
        }

        let optional = items.filter { !$0.isEssential && $0.mark != .ok && !$0.isOff }
        return SetupSummary(
            hero: .ready,
            headline: headline,
            subhead: optional.isEmpty
                ? "Hold the key, talk, let go. The text lands where your cursor is."
                : "Hold the key, talk, let go. "
                  + "\(optional.count) optional extra\(optional.count == 1 ? "" : "s") below.")
    }

    /// "fn" / "right_option" as a key a person can find on the keyboard.
    public static func hotkeyLabel(_ setting: String) -> String {
        switch setting {
        case "right_option": return "the right ⌥ key"
        default: return "🌐"
        }
    }

    // MARK: - Microphone fix selection

    static func micFix(_ status: String) -> SetupFixKind {
        switch status {
        case "granted": return .none
        case "undetermined": return .requestMicrophone
        default: return .openMicrophoneSettings   // denied / restricted
        }
    }

    static func micFixTitle(_ status: String) -> String {
        switch status {
        case "granted": return ""
        case "undetermined": return "Allow Microphone"
        default: return "Open Microphone Settings"
        }
    }
}
