import Foundation

/// One frame of pill state — everything `PillView` needs to draw, and
/// everything a test needs to assert. Value type, `Equatable`, no AppKit.
public struct PillRender: Equatable, Sendable {
    /// Whether the panel should be on screen (`orderFrontRegardless` vs
    /// `orderOut`).
    public var isVisible: Bool
    public var state: PillState
    public var dot: PillColor
    /// Clamped 0…1.
    public var level: Double
    /// `6 + level * 5`.
    public var dotRadius: Double
    /// Bubble text; empty means the pill is a bare 26×26 dot.
    public var bubble: String
    public var bubbleWidth: Double
    public var totalWidth: Double
    public var height: Double

    public static let collapsed = PillRender(
        isVisible: false, state: .hidden, dot: PillPalette.neutral, level: 0,
        dotRadius: PillGeometry.dotBaseRadius, bubble: "", bubbleWidth: 0,
        totalWidth: PillGeometry.width, height: PillGeometry.height)
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
/// plus the two new text affordances (`livePartial`, `transientNotice`).
/// Main-thread-only, like the Python — callers come through
/// `WispritUI.callOnMain`.
public final class PillModel {
    // MARK: state

    public private(set) var state: PillState = .hidden
    public private(set) var isVisible = false
    public private(set) var level: Double = 0
    public private(set) var bubble: String = ""
    public private(set) var bubbleWidth: Double = 0

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
            dot: PillPalette.dot(for: state),
            level: level,
            dotRadius: PillGeometry.dotRadius(forLevel: level),
            bubble: bubble,
            bubbleWidth: bubbleWidth,
            totalWidth: PillBubbleGeometry.totalWidth(bubbleWidth: bubble.isEmpty ? 0 : bubbleWidth),
            height: PillGeometry.height)
    }

    // MARK: - public API (main thread)

    /// `show_recording`: level reset to 0, red dot, panel ordered front.
    public func showRecording() {
        level = 0
        clearBubbleState()
        show(.recording)
    }

    /// `update_level`: silent while the pill is suppressed; never changes
    /// visibility.
    public func updateLevel(_ newLevel: Double) {
        guard !isSuppressed() else { return }
        let clamped = PillGeometry.clampLevel(newLevel)
        guard clamped != level else { return }   // no redraw for an unchanged frame
        level = clamped
        emit()
    }

    /// NEW — render the tail of the in-progress transcript.
    ///
    /// Only meaningful while recording (the finalize/insert states have their
    /// own colours and the text is already on its way to the cursor). The
    /// engine feeds monotonically growing text; we keep the last few words.
    ///
    /// Flicker control, in three layers: an unchanged tail is dropped before
    /// any redraw; the bubble width is quantised; and the width never shrinks
    /// within one utterance, so a word boundary can only ever widen the bubble.
    public func livePartial(_ text: String) {
        guard !isSuppressed(), state == .recording else { return }
        let tail = PartialTail.tail(of: text)
        guard tail != bubble else { return }
        bubble = tail
        // Monotone width: shrinking mid-utterance is the one thing that reads
        // as a glitch, so the bubble only ever grows until the next press.
        bubbleWidth = max(bubbleWidth, PillBubbleGeometry.width(forCharacters: tail.count))
        emit()
    }

    /// NEW — flash a short app-authored message ("Learned Sharique").
    ///
    /// Mid-utterance it borrows the current colour and only the bubble expires;
    /// otherwise it is a success-coloured flash that takes the pill with it
    /// when it goes.
    public func transientNotice(_ text: String) {
        guard !isSuppressed() else { return }
        let message = PartialTail.notice(text)
        guard !message.isEmpty else { return }
        cancelSchedule()
        bubble = message
        bubbleWidth = PillBubbleGeometry.width(forCharacters: message.count)
        let inFlight = (state == .recording || state == .finalizing)
        if !inFlight { state = .success }
        isVisible = true
        emit()
        schedule(PillGeometry.noticeDuration, inFlight ? .clearNotice : .hide)
    }

    /// `show_finalizing`: level 0, grey dot. The partial bubble collapses —
    /// recording is over, so a stale tail would be a lie.
    public func showFinalizing() {
        level = 0
        clearBubbleState()
        show(.finalizing)
    }

    /// `flash_success`: green, auto-hide after 0.6 s.
    public func flashSuccess() {
        clearBubbleState()
        show(.success)
        schedule(PillGeometry.successHideDelay, .hide)
    }

    /// `flash_error`: amber, auto-hide after 1.6 s. The message is not drawn
    /// (the session logs the reason) — the parameter exists for call-site
    /// parity with the Python.
    public func flashError(_ message: String = "") {
        _ = message
        clearBubbleState()
        show(.error)
        schedule(PillGeometry.errorHideDelay, .hide)
    }

    /// `hide`: cancel the timer, order the panel out. Unlike the show paths
    /// this ignores `pill_hidden` — hiding an already-hidden pill is harmless
    /// and the state must converge.
    public func hide() {
        cancelSchedule()
        state = .hidden
        isVisible = false
        level = 0
        clearBubbleState()
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

    /// `pill.py._show`: no-op while suppressed, otherwise cancel any pending
    /// auto-hide, recolour, and order front.
    private func show(_ newState: PillState) {
        guard !isSuppressed() else { return }
        cancelSchedule()
        state = newState
        isVisible = true
        emit()
    }

    private func clearBubbleState() {
        bubble = ""
        bubbleWidth = 0
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
