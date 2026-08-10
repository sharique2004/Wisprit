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
    /// NEW — the meter levels as they stood the moment `finalizing`/`refining`
    /// collapsed them (oldest first, full slot count), so the surface can play
    /// the §2.5 staggered collapse from them. Empty when there is nothing to
    /// collapse; `bars` itself already reads all-floor — a held waveform would
    /// be a lie, and every existing assertion on `bars` stays true.
    public var collapseFrom: [Double]

    public static let collapsed = PillRender(
        isVisible: false, state: .hidden, tint: PillPalette.tint(for: .hidden), level: 0,
        bars: [], bubble: "", bubbleWidth: 0, message: "", glyph: .none,
        totalWidth: PillGeometry.widthListening, height: PillGeometry.height,
        tailMuted: false, collapseFrom: [])
}

/// Work the view layer must schedule on a real timer. `pill.py` used
/// `NSTimer.scheduledTimerWithTimeInterval_…` directly inside the controller;
/// keeping the *decision* here and the *timer* in `Pill` is what makes the
/// state machine testable without a run loop.
public enum PillDeferredAction: Equatable, Sendable {
    /// `_schedule_hide` → `orderOut`.
    case hide
    /// NEW — drop a `transientNotice` bubble but leave the pill on screen
    /// (used when a notice lands mid-utterance).
    case clearNotice
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
    /// The scrolling meter. Pure, and the reason silence is free (§2.3).
    public private(set) var waveform = WaveformBuffer(slots: PillGeometry.barCount)

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

    /// The §2.5 staggered-collapse source — see `PillRender.collapseFrom`.
    private var collapseFrom: [Double] = []

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
            height: PillGeometry.height,
            tailMuted: deadMicCue,
            collapseFrom: collapseFrom)
    }

    // MARK: - public API (main thread)

    /// NEW — the key is down and the accept decision is made, but audio has not
    /// started. Bars at floor, `studioMuted`: the mic is not open yet, so this
    /// state is deliberately not orange.
    public func showPrewarming() {
        level = 0
        waveform.collapse()
        clearBubbleState()
        heldWidth = nil
        resetDeadMicTracking()
        show(.prewarming)
    }

    /// `show_recording`: level reset to 0, panel ordered front.
    public func showRecording() {
        level = 0
        waveform.collapse()
        clearBubbleState()
        heldWidth = nil
        resetDeadMicTracking()
        show(.recording)
    }

    /// `update_level`: silent while the pill is suppressed; never changes
    /// visibility.
    ///
    /// Two disciplines meet here. The buffer scrolls, so an *unchanged* level
    /// still moves the waveform and still redraws — but once the incoming level
    /// and every slot are at floor, `push` returns false and nothing is emitted
    /// at all. An idle-but-visible pill costs zero redraws, which is the whole
    /// budget the CGEventTap left us (§2.3).
    public func updateLevel(_ newLevel: Double) {
        guard !isSuppressed() else { return }
        level = PillGeometry.clampLevel(newLevel)
        // The first tick is what proves the mic is open, so it is also what
        // ends `prewarming`.
        let opened = (state == .prewarming)
        if opened { state = .recording }
        let changed = waveform.push(level)
        let cued = trackDeadMic()
        if changed || opened || cued { emit() }
    }

    /// R10 — the live dead-mic cue, engine-evidence trigger (§1.1-T4).
    ///
    /// After strictly more than `deadMicTickCount` consecutive sub-floor ticks
    /// (> 2 s) while `.recording`, and only when neither a voiced tick nor a
    /// partial has arrived this utterance, the tail shows a muted notice —
    /// "No audio — check mic". The first voiced tick or the first partial
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

    /// NEW — render the tail of the in-progress transcript.
    ///
    /// Only meaningful while recording (the finalize/insert states have their
    /// own colours and the text is already on its way to the cursor). The
    /// engine feeds monotonically growing text; we keep the last few words.
    ///
    /// Flicker control, in three layers: an unchanged tail is dropped before
    /// any redraw; the tail width is quantised; and the width never shrinks
    /// within one utterance, so a word boundary can only ever widen the pill.
    public func livePartial(_ text: String) {
        guard !isSuppressed(), state == .recording else { return }
        // Engine evidence: a partial is proof the pipeline hears something, so
        // it suppresses the dead-mic cue for the rest of the utterance — and
        // replaces it on screen if it was already up (§1.1-T4).
        partialSeen = true
        if deadMicCue {
            deadMicCue = false
            bubble = ""
            message = ""
        }
        let tail = PartialTail.tail(of: text)
        guard tail != bubble else { return }
        bubble = tail
        // Monotone width: shrinking mid-utterance is the one thing that reads
        // as a glitch, so the tail only ever grows until the next press.
        bubbleWidth = max(bubbleWidth, PillTailGeometry.width(forCharacters: tail.count))
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
        // A notice replaces the dead-mic cue on screen (and takes its muted
        // styling with it); the cue re-fires afterwards if the silence holds.
        deadMicCue = false
        message = noticed
        bubble = noticed
        bubbleWidth = PillTailGeometry.width(forCharacters: noticed.count)
        let inFlight = (state == .recording || state == .finalizing || state == .refining)
        if !inFlight { state = .success }
        isVisible = true
        emit()
        schedule(PillGeometry.noticeDuration, inFlight ? .clearNotice : .hide)
    }

    /// `show_finalizing`: level 0, grey bars. The partial tail collapses —
    /// recording is over, so a stale tail would be a lie — but the width it
    /// bought is held.
    public func showFinalizing() {
        holdWidth()
        level = 0
        captureCollapse()
        waveform.collapse()
        clearBubbleState()
        show(.finalizing)
    }

    /// NEW — the Apple Intelligence cleanup pass is running. Identical to
    /// `finalizing` apart from the `sparkles` glyph, which is the point: the
    /// user is waiting on a different thing and deserves to know which.
    public func showRefining() {
        holdWidth()
        level = 0
        captureCollapse()
        waveform.collapse()
        clearBubbleState()
        show(.refining)
    }

    /// `flash_success`: auto-hide after 0.6 s. The panel contracts to a 28 pt
    /// circle — a check mark needs no width.
    public func flashSuccess() {
        clearBubbleState()
        heldWidth = nil
        show(.success)
        schedule(PillGeometry.successHideDelay, .hide)
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

    /// NEW — the focused app holds Secure Keyboard Entry. Distinct from an
    /// error because nothing failed: the text is on the clipboard and the user
    /// only has to paste it. Stays up longer for that reason.
    public func flashBlockedSecure(_ message: String = PillGeometry.blockedSecureMessage) {
        holdWidth()
        showMessageState(.blockedSecure, message.isEmpty ? PillGeometry.blockedSecureMessage : message,
                         hideAfter: PillGeometry.blockedSecureHideDelay)
    }

    /// `hide`: cancel the timer, order the panel out. Unlike the show paths
    /// this ignores `pill_hidden` — hiding an already-hidden pill is harmless
    /// and the state must converge.
    public func hide() {
        cancelSchedule()
        state = .hidden
        isVisible = false
        level = 0
        waveform.collapse()
        clearBubbleState()
        heldWidth = nil
        resetDeadMicTracking()
        collapseFrom = []
        emit()
    }

    /// Timer callback (`_hideFired_`). The view layer forwards whatever
    /// `onSchedule` handed it; tests call this directly.
    public func fireDeferred(_ action: PillDeferredAction) {
        switch action {
        case .hide:
            hide()
        case .clearNotice:
            guard !bubble.isEmpty else { return }
            clearBubbleState()
            emit()
        }
    }

    // MARK: - internals

    /// The meter, sized for the frame: the compact 7-bar field when a text tail
    /// shares the capsule, nothing at all in the states whose meter is replaced
    /// by a glyph.
    private var bars: [Double] {
        switch state {
        case .prewarming, .recording, .finalizing, .refining:
            return bubble.isEmpty ? waveform.normalized
                                  : waveform.newest(PillGeometry.barCountCompact)
        case .hidden, .success, .error, .blockedSecure:
            return []
        }
    }

    private var glyph: PillGlyph {
        switch state {
        case .success: return bubble.isEmpty ? .checkmark : .sparkle
        case .error: return .warning
        case .blockedSecure: return .lock
        case .refining: return .sparkles
        case .hidden, .prewarming, .recording, .finalizing: return .none
        }
    }

    /// Panel width for the current frame (§2.4's Panel column).
    private var totalWidth: Double {
        let natural = bubble.isEmpty
            ? PillGeometry.widthListening
            : PillTailGeometry.totalWidth(tailWidth: bubbleWidth)
        switch state {
        case .success:
            // `committed` contracts to a circle — unless it is carrying a
            // notice, which is a text row that happens to be green.
            return bubble.isEmpty ? PillGeometry.widthCommitted : natural
        case .error:
            return max(PillGeometry.errorMinWidth, max(natural, heldWidth ?? 0))
        case .blockedSecure:
            return max(PillGeometry.blockedSecureMinWidth, max(natural, heldWidth ?? 0))
        case .finalizing, .refining:
            return max(natural, heldWidth ?? 0)
        case .hidden, .prewarming, .recording:
            return natural
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
            bubbleWidth = PillTailGeometry.errorWidth(forCharacters: flat.count)
            deadMicCue = false
        }
        show(newState)
        schedule(hideAfter, .hide)
    }

    /// `pill.py._show`: no-op while suppressed, otherwise cancel any pending
    /// auto-hide, recolour, and order front.
    private func show(_ newState: PillState) {
        guard !isSuppressed() else { return }
        cancelSchedule()
        // The collapse choreography belongs to the two states that own it;
        // any other show means the meter's story is over.
        if newState != .finalizing && newState != .refining { collapseFrom = [] }
        state = newState
        isVisible = true
        emit()
    }

    private func clearBubbleState() {
        bubble = ""
        bubbleWidth = 0
        message = ""
        deadMicCue = false
    }

    /// A fresh utterance re-arms the dead-mic cue.
    private func resetDeadMicTracking() {
        subFloorTicks = 0
        voicedSeen = false
        partialSeen = false
        deadMicCue = false
    }

    /// Snapshot the meter for the §2.5 staggered collapse — taken just before
    /// `waveform.collapse()`, and only when there is something to collapse
    /// (re-entering via `showRefining` right after `showFinalizing` finds the
    /// buffer already at floor and must not restart the choreography).
    private func captureCollapse() {
        collapseFrom = waveform.isSilent ? [] : waveform.normalized
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
