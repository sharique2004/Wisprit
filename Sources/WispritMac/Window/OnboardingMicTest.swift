#if os(macOS)
import Foundation
import SwiftUI
import WispritEngine
import WispritMacUI
import WispritPersistence

/// Step 3 of the cascade — `docs/design/ui-redesign.md` §4.2, amended by R15.
///
/// The one thing no TCC read can answer: the microphone grant can be green
/// while macOS is handing Wisprit a muted input, a disconnected interface or
/// the wrong device entirely. So the step after the grant is not a claim, it is
/// a measurement — and since 2026-08-10 the judge of that measurement is the
/// engine itself. The step passes when the transcriber hands words back, not
/// when a level meter crosses a threshold: acoustic.md §2 proved the engine
/// transcribes perfectly at meter peak 0.010 while the old `passLevel = 0.02`
/// proxy failed exactly those users. "We heard you", demonstrated by hearing
/// them — a quiet-speaker false-fail is impossible by construction. The meter
/// stays, at 44 pt, as the progress bar; it decides nothing.
struct MicTestState: Equatable {

    enum Phase: String, Equatable, Sendable {
        /// Capture is open, no words have come back yet.
        case waiting
        /// The engine transcribed something. Terminal: a test that has passed
        /// does not un-pass because the user stopped talking.
        case heard
        /// Six seconds without a transcription, or an input that would not
        /// open at all.
        case stalled
    }

    /// Silence for this long swaps the caption and offers Skip (§4.2).
    static let stallAfter: TimeInterval = 6

    /// Caption-only heuristic for the stalled diagnosis: has the meter moved at
    /// all? Deliberately far below the engine's own proven floor (it transcribes
    /// at peak 0.010, acoustic §2) and NEVER part of the pass decision — its one
    /// job is choosing between "check your input device" and "the input works
    /// but recognition is not answering" once the wait has already failed.
    static let soundFloor = 0.005

    private(set) var phase: Phase = .waiting
    private(set) var elapsed: TimeInterval = 0
    /// Any tick has shown a level above `soundFloor` — see the stalled caption.
    private(set) var sawSound = false
    private var buffer = WaveformBuffer(slots: TallyMetrics.micTest.barCount)

    /// Shaped 0…1 levels, oldest first — straight into `TallyWaveform`.
    var levels: [Double] { buffer.normalized }

    var hasPassed: Bool { phase == .heard }

    /// §4.1's footer. The mic test is not `isOptional`, so its Skip cannot come
    /// from the step: it is earned by the engine staying silent long enough that
    /// waiting has stopped being useful.
    var offersSkip: Bool { phase == .stalled }

    var caption: String {
        switch phase {
        case .waiting: return "Listening…"
        case .heard: return "Heard you."
        case .stalled:
            // Two different failures deserve two different remedies: a meter
            // that never moved points at the input device; a meter that moved
            // while no words came back points past the mic, at recognition.
            return sawSound
                ? "We hear sound, but no words yet — keep talking, or check "
                  + "the speech model in Setup."
                : "Nothing yet — check System Settings ▸ Sound ▸ Input."
        }
    }

    /// One tick of the level ticker's cadence — the visualization and the stall
    /// clock, nothing else. The pass arrives through `hear(_:)`; the level can
    /// no longer pass the step (R15 retired the proxy).
    ///
    /// Time is accumulated from the caller's interval rather than read from a
    /// clock so the six-second branch is reachable in a test without waiting
    /// six seconds.
    mutating func tick(level: Double, interval: TimeInterval) {
        buffer.push(level)
        elapsed += interval
        if level >= MicTestState.soundFloor { sawSound = true }
        guard phase != .heard else { return }
        if elapsed >= MicTestState.stallAfter { phase = .stalled }
    }

    /// The engine transcribed something — the evidence the step passes on.
    ///
    /// Returns true exactly once, on the transcription that passes the step,
    /// which is what the caller turns into `noteMicTestPassed()`. Whitespace is
    /// not words: an engine that hands back an empty partial has not heard
    /// anyone yet.
    @discardableResult
    mutating func hear(_ words: String) -> Bool {
        guard phase != .heard else { return false }
        guard !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        phase = .heard
        return true
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
/// Since R15 the captured audio is fed to a *dedicated* engine — the same
/// `AsrManager` facade the session dictates through, on its own `MicCapture` —
/// and the step passes when partial transcripts come back. The audio is
/// transcribed in memory and discarded with the engine on the way out; nothing
/// is retained, nothing is written anywhere. It is still not the session's
/// `AudioPort`: that seam terminates at `PillPort`, and the session is idle for
/// the whole of this step (the sheet yields the input to any dictation).
@MainActor
@Observable
final class OnboardingMicProbe {

    /// The seams this needs, narrowed to closures so the loop is drivable from
    /// a test with no input device and no speech model.
    struct Source {
        var start: () -> Bool
        var stop: () -> Void
        var level: () -> Double
        /// Install the engine-as-judge: begin a streaming transcription of the
        /// capture's audio, delivering every partial to the callback (any
        /// thread). The default is inert so a fake without an engine still
        /// drives the meter and the stall clock.
        var beginEvidence: (@escaping @Sendable (String) -> Void) -> Void

        init(start: @escaping () -> Bool,
             stop: @escaping () -> Void,
             level: @escaping () -> Double,
             beginEvidence: @escaping (@escaping @Sendable (String) -> Void) -> Void = { _ in }) {
            self.start = start
            self.stop = stop
            self.level = level
            self.beginEvidence = beginEvidence
        }

        /// A dedicated `MicCapture` feeding a dedicated `AsrManager`: the level
        /// drives the bars, the chunks drive the engine, and the engine's
        /// partials are the pass. `stop()` tears the whole pair down —
        /// `AsrManager.cancel()` drops the engine *and* resets its retention
        /// buffer, so no audio outlives the card.
        static func microphone() -> Source {
            let settings = Settings.load()
            let asr = AsrManager(
                settings: AsrSettings(
                    locale: settings.locale,
                    finalizeTimeoutMs: Double(settings.finalizeTimeoutMs),
                    engine: AsrEngineKind(settingsValue: settings.engine)))
            let port = MicCapturePort(MicCapture(onChunk: { asr.feed(pcm: $0) }))
            return Source(
                start: { port.start() },
                stop: {
                    port.stop()
                    Task { await asr.cancel() }
                },
                level: { port.level },
                beginEvidence: { onWords in
                    // Chunks that land before this install completes sit in the
                    // retention buffer, and `begin` splices that head into the
                    // engine (R7) — the mic test cannot lose the user's first
                    // word to its own startup either.
                    Task { await asr.begin(onPartial: onWords) }
                })
        }
    }

    /// `SessionController.Configuration.levelTickInterval` — 20 Hz, the cadence
    /// `WaveformBuffer` was shaped for (§2.3). One meter, one rate.
    static let tickInterval: TimeInterval = 0.05
    /// How long "✓ Heard you." stays on screen before the cascade takes the
    /// card away. The confirmation *is* the step; advancing on the same frame
    /// as the transcription would mean the user never sees the thing they
    /// proved.
    static let confirmHold: Duration = .milliseconds(700)

    private(set) var state = MicTestState()

    private let makeSource: () -> Source

    init(source: @escaping () -> Source = Source.microphone) {
        makeSource = source
    }

    /// Opens the input, installs the engine judge, polls the level until
    /// cancelled, and closes everything on the way out.
    ///
    /// `onPass` fires once, after the confirmation beat, and never after
    /// cancellation: a user who navigated away must not be yanked forward by a
    /// transcription that landed as they left.
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
        source.beginEvidence { [weak self] words in
            Task { @MainActor in self?.state.hear(words) }
        }

        var notified = false
        while !Task.isCancelled {
            state.tick(level: source.level(), interval: Self.tickInterval)
            if state.hasPassed && !notified {
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
/// on a measurement rather than on a grant — and the measurement is a
/// transcription, not a meter reading (R15).
struct OnboardingMicTestCard: View {
    let state: MicTestState

    var body: some View {
        OnboardingCard(
            symbol: nil,
            title: "Say anything",
            message: "Wisprit transcribes you right here to prove the mic "
                + "works. Nothing you say is kept."
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
