import Foundation

/// The glyph that replaces (or precedes) the meter, in SF Symbols terms.
/// Deciding this in the model rather than the view keeps `PillSurface` a pure
/// drawing pass and puts the mapping under test.
public enum PillGlyph: String, Equatable, Sendable {
    case none
    /// `committed`.
    case checkmark
    /// `error`.
    case warning
    /// `blockedSecure`.
    case lock
    /// `refining` — the cleanup pass is running.
    case sparkles
    /// A `transientNotice` ("Learned Sharique").
    case sparkle

    public var symbolName: String? {
        switch self {
        case .none: return nil
        case .checkmark: return "checkmark"
        case .warning: return "exclamationmark.triangle"
        case .lock: return "lock.fill"
        case .sparkles: return "sparkles"
        case .sparkle: return "sparkle"
        }
    }
}

/// One frame of pill state — everything `PillSurface` needs to draw, and
/// everything a test needs to assert. Value type, `Equatable`, no AppKit.
public struct PillRender: Equatable, Sendable {
    /// Whether the panel should be on screen (`orderFrontRegardless` vs
    /// `orderOut`).
    public var isVisible: Bool
    public var state: PillState
    /// The state's signature colour: the bars while listening, the glyph after.
    public var tint: PillColor
    /// Clamped 0…1. Retained for diagnostics — the meter is driven by `bars`.
    public var level: Double
    /// Shaped 0…1 levels, oldest first. Empty in the states whose meter is
    /// replaced by a glyph.
    public var bars: [Double]
    /// Tail text; empty means the pill is a bare 96 pt capsule.
    public var bubble: String
    public var bubbleWidth: Double
    /// NEW — the error/notice message as the app supplied it, before the tail's
    /// character budget. The old `PillView` discarded this; §2.7 says it is
    /// exactly what the user needed.
    public var message: String
    public var glyph: PillGlyph
    public var totalWidth: Double
    public var height: Double
    /// NEW — true while the tail is the live dead-mic cue (R10): notice
    /// styling, muted ink, never orange and never an alarm.
    public var tailMuted: Bool
    /// Horizontal (top/bottom / free) or vertical (left/right).
    public var axis: PillAxis
    /// The edge the pill is docked against, if any. Nil when free-floating.
    public var dockEdge: PillScreenEdge?
    public var isHovered: Bool
    /// Empty/nothing-heard wiggle in flight — no error chrome.
    public var isShaking: Bool
    /// Idle HUD: fully transparent but still on screen as a hit target.
    /// Distinct from `isVisible` / `.hidden`, which order the panel out.
    public var isDormant: Bool
    /// Wispr Flow hover/recording affordances.
    public var hoverChrome: PillHoverChrome

    public static let collapsed = PillRender(
        isVisible: false, state: .hidden, tint: PillPalette.tint(for: .hidden), level: 0,
        bars: [], bubble: "", bubbleWidth: 0, message: "", glyph: .none,
        totalWidth: PillGeometry.widthListening, height: PillGeometry.height,
        tailMuted: false, axis: .horizontal, dockEdge: nil,
        isHovered: false, isShaking: false, isDormant: false, hoverChrome: .none)

    /// Whether the only thing that moved between two frames is the meter.
    ///
    /// This is the predicate that keeps the SwiftUI view tree completely inert
    /// during dictation: a render that passes it is handed straight to the
    /// meter's `CALayer`s and never written to `PillRenderBox`, so the hosting
    /// view is not asked to lay anything out twenty times a second.
    ///
    /// It is deliberately *not* "the frame change is `.none`". The first level
    /// tick of an utterance also leaves the width and the visibility alone, but
    /// it ends `prewarming` — and the tint crossfade, the body and the
    /// accessibility label ("Starting" → "Listening") all live in SwiftUI. Key
    /// this on the frame kind and the surface freezes in `prewarming`.
    public static func isMeterOnly(_ old: PillRender, _ new: PillRender) -> Bool {
        guard !new.bars.isEmpty else { return false }
        var a = old, b = new
        a.bars = []; a.level = 0
        b.bars = []; b.level = 0
        return a == b
    }
}

/// Work the view layer must schedule on a real timer. `pill.py` used
/// `NSTimer.scheduledTimerWithTimeInterval_…` directly inside the controller;
/// keeping the *decision* here and the *timer* in `Pill` is what makes the
/// state machine testable without a run loop.
public enum PillDeferredAction: Equatable, Sendable {
    /// `_schedule_hide` → `orderOut`. Used when the user hides the bar.
    case hide
    /// Return to the persistent idle capsule. Success, a miss, and a
    /// notice settle here — Flow never leaves the desktop.
    case settle
    /// NEW — drop a `transientNotice` bubble but leave the pill on screen
    /// (used when a notice lands mid-utterance).
    case clearNotice
    /// NEW — the current stage has outlasted `PillGeometry.patienceDelay`;
    /// say what it is waiting on. Never hides, never changes state: the only
    /// thing that fires is a line of copy (AUDIT-2026-08-14's open decision).
    case patience
    /// Idle HUD: fade to fully transparent after `idleHideDelay`. The panel
    /// stays ordered front as a hit target; hover clears this.
    case idleHide
}

/// The pill's behaviour, headless.
///
/// 1:1 with `pill.py`'s public surface (`show_recording`, `update_level`,
/// `update_partial`, `show_finalizing`, `flash_success`, `flash_error`, `hide`)
/// plus the two text affordances (`livePartial`, `transientNotice`) and the
/// three states §2.4 adds (`showPrewarming`, `showRefining`,
/// `flashBlockedSecure`). Main-thread-only, like the Python — callers come
/// through `WispritUI.callOnMain`.
///
/// The new states all have safe defaults: a session that never calls them
/// behaves exactly as before, which is what lets the pill land ahead of the
/// session-layer wiring (§6.6).
public final class PillModel {
    // MARK: state

    public private(set) var state: PillState = .hidden
    public private(set) var isVisible = false
    public private(set) var level: Double = 0
    public private(set) var bubble: String = ""
    public private(set) var bubbleWidth: Double = 0
    /// The retained error / notice message (§2.7).
    public private(set) var message: String = ""
    /// The meter. Pure, seeded, and still the reason silence is free — the
    /// bars now breathe in place instead of scrolling (`BarSynthesizer`).
    private var synth = BarSynthesizer(barCount: PillGeometry.barCount)
    /// The last targets the synthesizer emitted, oldest-to-newest by position
    /// rather than by time: bar *i* is bar *i*, always.
    private var barValues = [Double](repeating: 0, count: PillGeometry.barCount)

    /// §2.4's "width held": once an utterance has widened the panel, the
    /// finalize/refine/error states keep that width rather than snapping back —
    /// a pill that shrinks and regrows between "you stopped talking" and "here
    /// is the result" reads as two events, not one.
    private var heldWidth: Double?

    // MARK: the live dead-mic cue (R10, amended trigger §1.1-T4)

    /// Consecutive level ticks below `PillGeometry.deadMicFloor` while
    /// `.recording`. A single voiced tick resets it.
    private var subFloorTicks = 0
    /// Any voiced tick this utterance disarms the cue for good: a microphone
    /// that has delivered voice is not dead, and the quiet-speech class
    /// belongs to the engine-evidence work (R15/R26), not to a nag.
    private var voicedSeen = false
    /// Engine evidence beats any proxy: one partial suppresses — and clears —
    /// the cue for the rest of the utterance.
    private var partialSeen = false
    /// Whether the cue tail is currently showing.
    private var deadMicCue = false
    /// Whether the tail is currently the patience cue ("Taking a second
    /// listen"). Same styling contract as the dead-mic cue — muted ink, never
    /// an alarm — which is why both feed one `tailMuted` flag rather than two.
    private var patienceCue = false

    /// Pointer over the capsule — idle expands into the waveform bar.
    private var hovered = false
    /// Empty-utterance wiggle. Distinct from `.error`: no red, no copy.
    private var shaking = false
    /// Fully transparent idle HUD; the panel is still a hit target.
    private var dormant = false
    /// Pointer drag owns the frame — stay visible until drop.
    private var dragging = false
    private var axis: PillAxis = .horizontal
    private var dockEdge: PillScreenEdge?

    /// `pill.py._hidden()` — the `pill_hidden` setting. Injected so the UI
    /// target imports nothing from `WispritPersistence`.
    private let isSuppressed: () -> Bool

    // MARK: outputs

    /// Called whenever the frame changes. The view redraws / resizes.
    public var onRender: ((PillRender) -> Void)?
    /// Schedule `action` after `seconds`. Any previously scheduled action is
    /// already cancelled by the time this fires.
    public var onSchedule: ((Double, PillDeferredAction) -> Void)?
    /// Cancel a pending scheduled action (`_cancel_hide_timer`).
    public var onCancelSchedule: (() -> Void)?

    public init(isSuppressed: @escaping () -> Bool = { false }) {
        self.isSuppressed = isSuppressed
    }

    /// Current frame.
    public var render: PillRender {
        PillRender(
            isVisible: isVisible,
            state: state,
            tint: PillPalette.tint(for: state),
            level: level,
            bars: bars,
            bubble: bubble,
            bubbleWidth: bubbleWidth,
            message: message,
            glyph: glyph,
            totalWidth: totalWidth,
            height: capsuleHeight,
            tailMuted: deadMicCue || patienceCue,
            axis: axis,
            dockEdge: dockEdge,
            isHovered: hovered,
            isShaking: shaking,
            isDormant: dormant,
            hoverChrome: hoverChrome)
    }

    // MARK: - public API (main thread)

    /// The resting sliver: on screen unless the user hid it. Hover expands it
    /// into Flow's waveform capsule; a press grows it into listening.
    public func showIdle() {
        guard !isSuppressed() else { return }
        cancelSchedule()
        level = 0
        collapseMeter()
        clearBubbleState()
        heldWidth = nil
        resetDeadMicTracking()
        shaking = false
        dormant = false
        state = .idle
        isVisible = true
        emit()
        armIdleHide()
    }

    /// NEW — the key is down and the accept decision is made, but audio has not
    /// started. Bars at floor, `studioMuted`: the mic is not open yet, so this
    /// state is deliberately not orange.
    public func showPrewarming() {
        level = 0
        collapseMeter()
        clearBubbleState()
        heldWidth = nil
        resetDeadMicTracking()
        show(.prewarming)
    }

    /// `show_recording`: level reset to 0, panel ordered front.
    public func showRecording() {
        level = 0
        collapseMeter()
        clearBubbleState()
        heldWidth = nil
        resetDeadMicTracking()
        show(.recording)
    }

    /// `update_level`: silent while the pill is suppressed; never changes
    /// visibility.
    ///
    /// Two disciplines meet here. The bars breathe in place, so an *unchanged*
    /// level still moves them — the envelope is still settling and each bar's
    /// jitter still has its own deadline — but once the envelope has snapped to
    /// zero and the row is already at floor, `push` returns nil and nothing is
    /// emitted at all. An idle-but-visible pill costs zero redraws, which is
    /// the whole budget the CGEventTap left us (§2.3).
    public func updateLevel(_ newLevel: Double) {
        guard !isSuppressed() else { return }
        level = PillGeometry.clampLevel(newLevel)
        // The first tick is what proves the mic is open, so it is also what
        // ends `prewarming`.
        let opened = (state == .prewarming)
        if opened { state = .recording }
        var changed = false
        if let targets = synth.push(level) {
            barValues = targets
            changed = true
        }
        let cued = trackDeadMic()
        if changed || opened || cued { emit() }
    }

    /// R10 — the live dead-mic cue, engine-evidence trigger (§1.1-T4).
    ///
    /// After strictly more than `deadMicTickCount` consecutive sub-floor ticks
    /// (> 2 s) while `.recording`, and only when neither a voiced tick nor a
    /// partial has arrived this utterance, the tail shows a muted notice —
    /// "No sound yet". The first voiced tick or the first partial
    /// clears it (and disarms it for the rest of the utterance: a channel that
    /// has produced evidence is not dead). Returns true when the frame
    /// changed. The cue costs exactly one frame to appear and one to clear —
    /// the silence around it stays redraw-free.
    private func trackDeadMic() -> Bool {
        guard state == .recording else { return false }
        if level < PillGeometry.deadMicFloor {
            subFloorTicks += 1
            guard subFloorTicks > PillGeometry.deadMicTickCount,
                  !voicedSeen, !partialSeen, !deadMicCue, bubble.isEmpty
            else { return false }
            deadMicCue = true
            message = PillGeometry.deadMicMessage
            bubble = PillGeometry.deadMicMessage
            bubbleWidth = PillTailGeometry.width(forCharacters: bubble.count)
            return true
        }
        subFloorTicks = 0
        voicedSeen = true
        guard deadMicCue else { return false }
        clearBubbleState()
        return true
    }

    /// Engine evidence that the pipeline heard something. Transcription is
    /// inserted at the caret only — the pill never draws the words (Wispr
    /// Flow's bar is status + waveform; the text lands in the focused field).
    ///
    /// Still load-bearing: a partial suppresses the dead-mic cue for the rest
    /// of the utterance, which is why the session keeps calling this even
    /// though nothing is rendered from it.
    public func livePartial(_ text: String) {
        guard !isSuppressed(), state == .recording else { return }
        let hadText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hadText else { return }
        partialSeen = true
        guard deadMicCue else { return }
        deadMicCue = false
        bubble = ""
        message = ""
        bubbleWidth = 0
        emit()
    }

    /// Pointer entered or left the capsule. Idle hover expands into the
    /// waveform bar Flow shows on hover; recording chrome does not depend on
    /// it (Cancel/Stop are the recording affordance, always). Hover also
    /// wakes a dormant idle pill. The panel hit frame does not change.
    public func setHovered(_ hovering: Bool) {
        let woke = hovering && dormant
        let changed = hovered != hovering || woke
        hovered = hovering
        if hovering {
            dormant = false
            if state == .idle, !shaking { cancelSchedule() }
        }
        guard changed, isVisible else { return }
        if state == .idle, !shaking {
            emit()
            if !hovering { armIdleHide() }
        } else if woke {
            emit()
        }
    }

    /// Pointer drag owns the frame. Stay visible for the grab; the idle
    /// hide timer resumes on drop.
    public func setDragging(_ isDragging: Bool) {
        guard dragging != isDragging else { return }
        dragging = isDragging
        if isDragging {
            let woke = dormant
            dormant = false
            if state == .idle { cancelSchedule() }
            if woke { emit() }
        } else {
            armIdleHide()
        }
    }

    /// Reorient from a drag. No-op when nothing changed, so the 60 Hz drag
    /// path is free until an edge is actually crossed.
    public func setPlacement(axis: PillAxis, edge: PillScreenEdge?) {
        guard axis != self.axis || edge != dockEdge else { return }
        self.axis = axis
        dockEdge = edge
        guard isVisible else { return }
        emit()
    }

    /// NEW — flash a short app-authored message ("Learned Sharique").
    ///
    /// Mid-utterance it borrows the current colour and only the bubble expires;
    /// otherwise it is a success-coloured flash that takes the pill with it
    /// when it goes.
    public func transientNotice(_ text: String) {
        guard !isSuppressed() else { return }
        let noticed = PartialTail.notice(text)
        guard !noticed.isEmpty else { return }
        cancelSchedule()
        // A notice replaces either live cue on screen (and takes their muted
        // styling with it); the dead-mic one re-fires if the silence holds.
        deadMicCue = false
        patienceCue = false
        message = noticed
        bubble = noticed
        bubbleWidth = PillTailGeometry.width(forCharacters: noticed.count)
        let inFlight = (state == .recording || state == .finalizing || state == .refining)
        if !inFlight { state = .success }
        isVisible = true
        emit()
        schedule(PillGeometry.noticeDuration, inFlight ? .clearNotice : .settle)
    }

    /// `show_finalizing`: level 0, grey bars. The partial tail collapses —
    /// recording is over, so a stale tail would be a lie — but the width it
    /// bought is held.
    public func showFinalizing() {
        holdWidth()
        level = 0
        collapseMeter()
        clearBubbleState()
        show(.finalizing)
        armPatience()
    }

    /// NEW — the Apple Intelligence cleanup pass is running. Identical to
    /// `finalizing` apart from the `sparkles` glyph, which is the point: the
    /// user is waiting on a different thing and deserves to know which.
    public func showRefining() {
        holdWidth()
        level = 0
        collapseMeter()
        clearBubbleState()
        show(.refining)
        armPatience()
    }

    /// `flash_success`: auto-hide after 0.6 s.
    ///
    /// The panel contracts back to the 96 pt resting capsule — no check mark,
    /// no 28 pt circle. The text is already in the field; a receipt for it is
    /// the pill talking about itself.
    public func flashSuccess() {
        clearBubbleState()
        heldWidth = nil
        show(.success)
        schedule(PillGeometry.successHideDelay, .settle)
    }

    /// `flash_error`: auto-hide after 1.6 s.
    ///
    /// The message is now **drawn** rather than discarded (§2.7). It arrives
    /// already user-facing ("secure field — press ⌘⌃V to paste") and the
    /// session logs it too; showing it is the difference between "something
    /// went wrong" and "here is what to do about it".
    public func flashError(_ message: String = "") {
        holdWidth()
        showMessageState(.error, message, hideAfter: PillGeometry.errorHideDelay)
    }

    /// A miss, not a fault: the user spoke too quietly, said nothing, or
    /// the recognizer returned empty. No red, no banner — a small springy
    /// "no" (password-field energy), then idle.
    public func flashMissed(_ message: String = PillGeometry.missedMessage) {
        _ = message
        shakeEmpty()
    }

    /// The marginal-audio miss. Same visual contract as `flashMissed`: the
    /// session still owns the diagnosis, the pill answers with a wiggle
    /// instead of a "too quiet" banner or an alarm body.
    public func flashTooQuiet(_ message: String) {
        _ = message
        shakeEmpty()
    }

    /// NEW — the focused app holds Secure Keyboard Entry. Distinct from an
    /// error because nothing failed: the text is on the clipboard and the user
    /// only has to paste it. Stays up longer for that reason.
    public func flashBlockedSecure(_ message: String = PillGeometry.blockedSecureMessage) {
        holdWidth()
        showMessageState(.blockedSecure, message.isEmpty ? PillGeometry.blockedSecureMessage : message,
                         hideAfter: PillGeometry.blockedSecureHideDelay)
    }

    /// The empty-utterance wiggle: keep the listening capsule (so there is
    /// something to shake), no copy, no alarm body, then settle to idle.
    private func shakeEmpty() {
        cancelSchedule()
        level = 0
        collapseMeter()
        clearBubbleState()
        heldWidth = nil
        resetDeadMicTracking()
        hovered = false
        dormant = false
        guard !isSuppressed() else {
            schedule(PillMotion.shakeDuration, .settle)
            return
        }
        shaking = true
        state = .idle
        isVisible = true
        emit()
        schedule(PillMotion.shakeDuration, .settle)
    }

    /// `hide`: cancel the timer, order the panel out. Unlike the show paths
    /// this ignores `pill_hidden` — hiding an already-hidden pill is harmless
    /// and the state must converge.
    public func hide() {
        cancelSchedule()
        state = .hidden
        isVisible = false
        level = 0
        collapseMeter()
        clearBubbleState()
        heldWidth = nil
        resetDeadMicTracking()
        shaking = false
        dormant = false
        emit()
    }

    /// Timer callback (`_hideFired_`). The view layer forwards whatever
    /// `onSchedule` handed it; tests call this directly.
    public func fireDeferred(_ action: PillDeferredAction) {
        switch action {
        case .hide:
            hide()
        case .settle:
            showIdle()
        case .clearNotice:
            guard !bubble.isEmpty else { return }
            clearBubbleState()
            emit()
        case .patience:
            showPatienceCue()
        case .idleHide:
            goDormant()
        }
    }

    /// Arm the patience clock for a stage the user is now waiting on.
    ///
    /// `show` has already cancelled whatever was pending, so this rides the
    /// same one-timer budget every other deferred action uses. A stage that
    /// finishes first cancels it on its own way out; a `transientNotice` that
    /// lands mid-wait replaces it, which is right — a notice is newer news.
    private func armPatience() {
        guard !isSuppressed() else { return }
        patienceCue = false
        schedule(PillGeometry.patienceDelay, .patience)
    }

    /// The wait outlasted `patienceDelay`: grow a quiet line of copy naming the
    /// stage. Not a state change and not an alarm — muted ink on the same body,
    /// and the pill keeps thinking underneath it.
    ///
    /// It defers to anything already in the tail: a live notice or a held error
    /// is information the user asked for, and this is only ever a reassurance.
    private func showPatienceCue() {
        guard !isSuppressed(), bubble.isEmpty else { return }
        let text: String
        switch state {
        case .finalizing: text = PillGeometry.finalizingPatienceMessage
        case .refining: text = PillGeometry.refiningPatienceMessage
        default: return
        }
        patienceCue = true
        message = text
        bubble = text
        bubbleWidth = PillTailGeometry.width(forCharacters: text.count)
        emit()
    }

    // MARK: - internals

    /// The meter — one ten-bar field, in every state that has one.
    ///
    /// Idle rest is the mini sliver with no meter. Idle hover and the empty
    /// wiggle borrow the listening field at floor — cream dots, the same
    /// object Flow shows when you point at the bar.
    private var bars: [Double] {
        switch state {
        case .hidden, .error, .blockedSecure:
            return []
        case .idle:
            return (hovered || shaking) ? barValues : []
        case .prewarming, .recording, .finalizing, .refining, .missed, .success:
            return barValues
        }
    }

    private var hoverChrome: PillHoverChrome {
        if shaking { return .none }
        switch state {
        case .idle where hovered: return .idle
        case .prewarming, .recording: return .recording
        default: return .none
        }
    }

    private var isMiniRest: Bool {
        state == .idle && !hovered && !shaking
    }

    private var capsuleHeight: Double {
        isMiniRest ? PillGeometry.heightMini : PillGeometry.height
    }

    private var glyph: PillGlyph {
        switch state {
        // No commit glyph. Flow has none — the inserted text is the
        // confirmation — and a check mark that contracts the pill to a circle
        // was the loudest thing in a moment that should be the quietest. A
        // notice still gets its sparkle: that one is *news*, not a receipt.
        case .success: return bubble.isEmpty ? .none : .sparkle
        case .error: return .warning
        case .blockedSecure: return .lock
        // `refining`'s sparkles are gone too: the spinner already says "still
        // working", and the patience copy already says which work. Two glyphs
        // for one wait is chrome, not information.
        case .hidden, .prewarming, .recording, .finalizing, .refining, .missed, .idle:
            return .none
        }
    }

    /// Panel width for the current frame (§2.4's Panel column).
    private var totalWidth: Double {
        let natural = bubble.isEmpty
            ? PillGeometry.widthListening
            : PillTailGeometry.totalWidth(tailWidth: bubbleWidth)
        switch state {
        case .error:
            return max(PillGeometry.errorMinWidth, max(natural, heldWidth ?? 0))
        case .blockedSecure:
            return max(PillGeometry.blockedSecureMinWidth, max(natural, heldWidth ?? 0))
        case .finalizing, .refining:
            // The processing floor: Flow widens ×1.34 on release to make room
            // for the spinner beside a leading-aligned dot row. When a patience
            // line is also in the tail, the spinner's own room is added on top
            // — otherwise the copy runs underneath it.
            let waiting = bubble.isEmpty ? natural : natural + PillTailGeometry.spinnerAllowance
            return max(PillGeometry.widthProcessing, max(waiting, heldWidth ?? 0))
        case .missed:
            return max(natural, heldWidth ?? 0)
        // `success` holds the full capsule for its flash; the settle that
        // follows is what lands on the mini sliver.
        case .hidden, .success:
            return natural
        case .prewarming, .recording:
            return PillGeometry.widthChrome
        case .idle:
            return (hovered || shaking) ? PillGeometry.widthListening : PillGeometry.widthMini
        }
    }

    /// Remember the width the utterance earned, before the tail is cleared.
    private func holdWidth() {
        guard !bubble.isEmpty else { return }
        heldWidth = PillTailGeometry.totalWidth(tailWidth: bubbleWidth)
    }

    /// The shared body of the two message states: retain the message, lay it
    /// out with the error character budget — and the error width cap, so the
    /// 40-character budget actually fits the frame (R9a) — show, and arm the
    /// auto-hide.
    private func showMessageState(_ newState: PillState, _ text: String, hideAfter: Double) {
        if !isSuppressed() {
            let flat = PartialTail.notice(text, maxCharacters: PillGeometry.errorMessageCharacters)
            message = flat
            bubble = flat
            bubbleWidth = newState == .missed
                ? PillTailGeometry.width(forCharacters: flat.count)
                : PillTailGeometry.errorWidth(forCharacters: flat.count)
            deadMicCue = false
            patienceCue = false
        }
        show(newState)
        schedule(hideAfter, .settle)
    }

    /// `pill.py._show`: no-op while suppressed, otherwise cancel any pending
    /// auto-hide, recolour, and order front.
    private func show(_ newState: PillState) {
        guard !isSuppressed() else { return }
        cancelSchedule()
        shaking = false
        dormant = false
        state = newState
        isVisible = true
        emit()
    }

    private func clearBubbleState() {
        bubble = ""
        bubbleWidth = 0
        message = ""
        deadMicCue = false
        patienceCue = false
    }

    /// A fresh utterance re-arms the dead-mic cue.
    private func resetDeadMicTracking() {
        subFloorTicks = 0
        voicedSeen = false
        partialSeen = false
        deadMicCue = false
    }

    /// Every bar back to floor.
    ///
    /// There is no snapshot to hand the surface any more, and no choreography
    /// to restart: the meter's layers already hold the heights they are at, so
    /// a collapse is one retarget to zero and the render server plays the fall
    /// from wherever each bar happens to be. `showRefining` right after
    /// `showFinalizing` is therefore a no-op on screen, which is what it should
    /// always have been — the same wait wearing a different label.
    private func collapseMeter() {
        synth.reset()
        barValues = [Double](repeating: 0, count: PillGeometry.barCount)
    }

    private func goDormant() {
        guard isVisible, state == .idle, !hovered, !shaking, !dragging, !dormant else { return }
        dormant = true
        emit()
    }

    /// Only when the pill is a resting sliver nobody is using. Other
    /// deferred actions (settle, patience, error hide) own the one-timer
    /// budget while they are in flight.
    private func armIdleHide() {
        guard isVisible, state == .idle, !hovered, !shaking, !dragging, !dormant else { return }
        schedule(PillGeometry.idleHideDelay, .idleHide)
    }

    private func schedule(_ seconds: Double, _ action: PillDeferredAction) {
        onSchedule?(seconds, action)
    }

    private func cancelSchedule() {
        onCancelSchedule?()
    }

    private func emit() {
        onRender?(render)
    }
}
