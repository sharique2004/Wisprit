#if os(macOS)
import Foundation
import SwiftUI
import WispritEngine
import WispritMacUI
import WispritPersistence

/// Step 3 of the cascade — `docs/design/ui-redesign.md` §4.2.
///
/// The one thing no TCC read can answer: the microphone grant can be green
/// while macOS is handing Wisprit a muted input, a disconnected interface or
/// the wrong device entirely. So the step after the grant is not a claim, it is
/// a measurement — and the measurement is shown, at 44 pt, in the same
/// instrument the pill uses.
struct MicTestState: Equatable {

    enum Phase: String, Equatable, Sendable {
        /// Capture is open, nothing loud enough has arrived yet.
        case waiting
        /// A voiced peak landed. Terminal: a test that has passed does not
        /// un-pass because the user stopped talking.
        case heard
        /// Six seconds of silence, or an input that would not open at all.
        case stalled
    }

    /// Any pushed level at or above this passes. Reused from the engine's own
    /// definition of "voiced", never restated (§4.2): a mic test with a
    /// different threshold from the transcriber's would pass inputs that then
    /// produce empty transcripts.
    static let passLevel = MetricsSummary.voicedPeakThreshold
    /// Silence for this long swaps the caption and offers Skip (§4.2).
    static let stallAfter: TimeInterval = 6

    private(set) var phase: Phase = .waiting
    private(set) var elapsed: TimeInterval = 0
    private var buffer = WaveformBuffer(slots: TallyMetrics.micTest.barCount)

    /// Shaped 0…1 levels, oldest first — straight into `TallyWaveform`.
    var levels: [Double] { buffer.normalized }

    var hasPassed: Bool { phase == .heard }

    /// §4.1's footer. The mic test is not `isOptional`, so its Skip cannot come
    /// from the step: it is earned by the input staying silent long enough that
    /// waiting has stopped being useful.
    var offersSkip: Bool { phase == .stalled }

    var caption: String {
        switch phase {
        case .waiting: return "Waiting for sound…"
        case .heard: return "Heard you."
        case .stalled: return "Nothing yet — check System Settings ▸ Sound ▸ Input."
        }
    }

    /// One tick of the level ticker's cadence.
    ///
    /// Returns true exactly once — on the tick that passes the step — which is
    /// what the caller turns into `noteMicTestPassed()`. Time is accumulated
    /// from the caller's interval rather than read from a clock so the
    /// six-second branch is reachable in a test without waiting six seconds.
    @discardableResult
    mutating func tick(level: Double, interval: TimeInterval) -> Bool {
        buffer.push(level)
        elapsed += interval
        guard phase != .heard else { return false }
        if level >= MicTestState.passLevel {
            phase = .heard
            return true
        }
        if elapsed >= MicTestState.stallAfter { phase = .stalled }
        return false
    }

    /// The input could not be opened at all. There is nothing to wait *for*, so
    /// the user is not made to sit out the six seconds before Skip appears.
    mutating func noteCaptureFailed() {
        guard phase != .heard else { return }
        phase = .stalled
        buffer.collapse()
    }
}

// MARK: - the capture behind it

/// The short-lived capture that feeds the mic test (§4.2 step 3).
///
/// **Started on step entry, stopped on exit — never left running.** The macOS
/// orange indicator is Wisprit's honesty guarantee: the mic is live only while
/// the key is held, plus these few seconds, which the card says out loud. The
/// capture is owned by one `.task`, so cancelling that task — a step change, a
/// dismissed sheet, a closed window — stops it by construction.
///
/// It is a *dedicated* `AudioPort`, not the session's. The level the pill draws
/// reaches it through `SessionController`'s `pill-level` thread
/// (`AudioPort.level` at 20 Hz), and that seam terminates at `PillPort` — there
/// is no read-only path from it back to the window without editing
/// `SessionController`/`AppController`, which the UI pass does not own (§6.6).
/// Polling our own port at the same cadence is the fallback, and it is also
/// what §4.2 asks for in the first place.
@MainActor
@Observable
final class OnboardingMicProbe {

    /// The `AudioPort` calls this needs, narrowed to three closures so the loop
    /// is drivable from a test with no input device.
    struct Source {
        var start: () -> Bool
        var stop: () -> Void
        var level: () -> Double

        /// A dedicated `MicCapture` with its chunks dropped on the floor: this
        /// step is about the level, not the words. Nothing is transcribed,
        /// nothing is retained, and `stop()` tears the engine down.
        static func microphone() -> Source {
            let port = MicCapturePort(MicCapture(onChunk: { _ in }))
            return Source(start: { port.start() }, stop: { port.stop() },
                          level: { port.level })
        }
    }

    /// `SessionController.Configuration.levelTickInterval` — 20 Hz, the cadence
    /// `WaveformBuffer` was shaped for (§2.3). One meter, one rate.
    static let tickInterval: TimeInterval = 0.05
    /// How long "✓ Heard you." stays on screen before the cascade takes the
    /// card away. The confirmation *is* the step; advancing on the same frame
    /// as the peak would mean the user never sees the thing they proved.
    static let confirmHold: Duration = .milliseconds(700)

    private(set) var state = MicTestState()

    private let makeSource: () -> Source

    init(source: @escaping () -> Source = Source.microphone) {
        makeSource = source
    }

    /// Opens the input, polls it until cancelled, and closes it on the way out.
    ///
    /// `onPass` fires once, after the confirmation beat, and never after
    /// cancellation: a user who navigated away must not be yanked forward by a
    /// peak that landed as they left.
    func run(onPass: () -> Void) async {
        // Coming back to the card — from Back, or after yielding the input to a
        // dictation — restarts the six-second wait. A passed test is kept: it
        // proved the input works, and proving it twice is a chore.
        if !state.hasPassed { state = MicTestState() }
        let source = makeSource()
        guard source.start() else {
            state.noteCaptureFailed()
            return
        }
        defer { source.stop() }

        var notified = false
        while !Task.isCancelled {
            let passed = state.tick(level: source.level(), interval: Self.tickInterval)
            if passed && !notified {
                notified = true
                try? await Task.sleep(for: Self.confirmHold)
                if Task.isCancelled { break }
                onPass()
            }
            do {
                try await Task.sleep(for: .seconds(Self.tickInterval))
            } catch {
                break
            }
        }
    }
}

// MARK: - the card

/// Step 3's card. The second Tally, and the only card whose Continue is gated
/// on a measurement rather than on a grant.
struct OnboardingMicTestCard: View {
    let state: MicTestState

    var body: some View {
        OnboardingCard(
            symbol: nil,
            title: "Say anything",
            message: "Just checking macOS gave us the right input."
        ) {
            TallyWaveform(levels: state.levels,
                          metrics: .micTest,
                          color: Theme.hot(.micTestWaveform))
                .frame(width: OnboardingMetrics.tallyWell,
                       height: TallyMetrics.micTest.height)
                .accessibilityHidden(true)

            caption
                .padding(.top, Theme.Space.s20)
        }
    }

    private var caption: some View {
        HStack(spacing: Theme.Space.s8) {
            if state.hasPassed {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.positive)
            }
            Text(state.caption)
                .font(Theme.font(Theme.Role.body))
                .foregroundStyle(state.hasPassed ? Theme.positive : Theme.inkSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: OnboardingMetrics.proseWidth)
        .accessibilityElement(children: .combine)
    }
}
#endif
