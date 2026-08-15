#if os(macOS)
import AppKit
import Foundation
import WispritMacUI

/// `Wisprit pill-demo` — the pill, every state, no microphone.
///
/// Hidden/dev verb. The pill is the one surface in this app that cannot be
/// reviewed from a unit test: its whole job is how it looks and moves over
/// somebody else's window. So this walks it through the full state vocabulary
/// on synthetic level data, dwelling long enough on each to be looked at, and
/// — with `--shots DIR` — takes its own screenshots at the moment each state
/// has finished arriving. Self-timed shots are the point: a `sleep` in a shell
/// script next to a spring animation catches the spring, not the state.
///
/// It runs entirely off the main run loop with one repeating 20 Hz timer, which
/// is the same cadence `SessionController.startLevelTicker` feeds the real pill
/// — so what you are looking at is the real redraw budget, not a slideshow.
@MainActor
enum PillDemo {

    /// One beat of the script.
    struct Step {
        let name: String
        /// Seconds to dwell before moving on.
        let dwell: Double
        /// When to take the shot, measured from the start of the step. Flash
        /// states auto-hide, so theirs lands early; the waiting states get a
        /// late one, once the release has played out.
        let shotAt: Double
        /// Extra shots, in seconds from the start of the step, for looking at
        /// *motion* rather than at a state.
        ///
        /// A single screenshot cannot show interpolation — that is the whole
        /// reason the old pill's tick was hard to argue about. A burst across
        /// one transition can: eight frames 40 ms apart over a 200 ms tween
        /// show the bars mid-flight, at heights no 20 Hz sample ever asked for.
        let burst: [Double]
        /// When, in step time, the state change actually fires.
        ///
        /// Normally zero. It is non-zero for the two transitions that finish
        /// faster than `screencapture` can start: a launched capture does not
        /// photograph the instant it was asked for, it photographs a couple of
        /// hundred milliseconds later, so a 120 ms collapse fired at t = 0 is
        /// over before the first frame lands. Starting the burst first and
        /// pulling the trigger into the middle of it is the honest fix —
        /// nothing about the transition changes, only when the camera was
        /// switched on.
        let enterAt: Double
        let enter: (Pill) -> Void
        /// Synthetic level for a tick `t` seconds into the step. Returning nil
        /// means "no sample this tick" — which is what makes the
        /// single-sample proof possible: feed one level, then stop, and every
        /// frame that follows is the compositor's own work.
        let level: ((Double) -> Double?)?

        init(_ name: String, dwell: Double = 2.0, shotAt: Double = 1.2,
             burst: [Double] = [], enterAt: Double = 0,
             level: ((Double) -> Double?)? = nil,
             enter: @escaping (Pill) -> Void) {
            self.name = name
            self.dwell = dwell
            self.shotAt = shotAt
            self.burst = burst
            self.enterAt = enterAt
            self.enter = enter
            self.level = level
        }
    }

    /// The level ticker's cadence, matching `SessionController.levelTickInterval`.
    /// This is what the *pill* sees, and it does not change.
    private static let tickInterval: Double = 0.05
    /// The driver's own clock.
    ///
    /// Five times finer than the level feed, and only so that a burst frame
    /// can be asked for at 30 ms rather than 50 ms — a 200 ms tween sampled at
    /// the feed's own rate would only ever be photographed at the moments the
    /// feed acted, which is precisely the evidence that proves nothing. The
    /// pill still receives exactly one sample every 50 ms.
    private static let frameInterval: Double = 0.01

    static func run(arguments: [String]) -> Never {
        let shotsDirectory = value(of: "--shots", in: arguments).map {
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true)
        }
        if let shotsDirectory {
            try? FileManager.default.createDirectory(at: shotsDirectory,
                                                     withIntermediateDirectories: true)
        }

        let app = NSApplication.shared
        // Accessory: no Dock tile, no menu bar, nothing to steal focus from
        // whatever is behind the pill. Same posture the real app runs in.
        app.setActivationPolicy(.accessory)

        // `--backdrop` puts a test card behind the pill: white, bone, a mid
        // grey, near-black and a saturated block, side by side. The pill's
        // whole legibility claim — "it reads the same on white and on black" —
        // is a claim about a composite, and this is the only way to look at
        // that composite rather than take its word for it.
        //
        // It is sized from the pill's own widest frame plus a margin and never
        // from the screen: an unexpected full-bleed test card on somebody's
        // desktop is alarming, and a QA affordance that alarms you is a bug.
        let backdrop = arguments.contains("--backdrop") ? makeBackdrop() : nil

        // A demo pill reads no settings and persists no position: it must not
        // move the real pill the user has dragged somewhere. It also parks
        // itself well clear of the default bottom-centre spot, so an installed
        // Wisprit running alongside it cannot wander into the screenshots.
        let pill = Pill(configuration: Pill.Configuration(
            isSuppressed: { false }, savedPosition: { demoOrigin() },
            persistPosition: { _ in }))

        let driver = Driver(pill: pill, steps: script(), shots: shotsDirectory,
                            backdrop: backdrop)
        driver.start()
        app.run()
        exit(0)
    }

    /// How much desktop the shots show around the pill. The capture rect is
    /// derived from the pill's *live* frame plus this margin, so a screenshot
    /// is also a check on the panel geometry: if the frame were wrong, the
    /// crop would be visibly off-centre.
    static let shotMargin: Double = 46
    /// The backdrop covers the widest pill (`PillTailGeometry.errorMaxWidth`
    /// plus its chrome) and nothing more.
    static var cardSize: NSSize {
        NSSize(width: PillTailGeometry.totalWidth(tailWidth: PillTailGeometry.errorMaxWidth)
                   + shotMargin * 2,
               height: PillGeometry.height + shotMargin * 2)
    }

    /// Where the demo parks its pill: bottom-centre's x, but four times the
    /// bottom margin up, which clears both the Dock and an installed Wisprit's
    /// own pill.
    static func demoOrigin() -> CGPoint? {
        guard let screen = NSScreen.main else { return nil }
        return CGPoint(x: screen.frame.midX - PillGeometry.widthListening / 2,
                       y: screen.frame.minY + PillGeometry.bottomMargin * 4)
    }

    /// The widest window this verb is ever allowed to put on a real desktop.
    ///
    /// It exists as a named number because it is a safety rail, not a layout:
    /// the backdrop below is a QA affordance, and a QA affordance that covers
    /// somebody's screen with test bars is a bug, not a feature. Everything the
    /// demo draws is derived from the pill's own frame plus `shotMargin`, and
    /// this is the assertion that keeps it that way.
    static var maxCardWidth: Double {
        PillTailGeometry.totalWidth(tailWidth: PillTailGeometry.errorMaxWidth) + shotMargin * 2
    }

    /// The test card. `.floating` — above ordinary windows so whatever the user
    /// happens to have open cannot get between the card and the pill, and still
    /// well below the pill's own `.statusBar` panel, which is what the
    /// behind-window material has to sample.
    private static func makeBackdrop() -> NSWindow? {
        guard let origin = demoOrigin() else { return nil }
        // Clamped, belt and braces: the card is derived from the pill's widest
        // frame, and it is *also* refused permission to exceed it.
        var size = cardSize
        size.width = min(size.width, maxCardWidth)
        // Anchored to the pill's own origin, not to the screen: the card grows
        // rightward with the pill and never larger than the widest pill.
        let frame = NSRect(x: origin.x - shotMargin,
                           y: origin.y + PillGeometry.height / 2 - size.height / 2,
                           width: size.width, height: size.height)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.level = .floating
        window.isOpaque = true
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.contentView = BackdropView(frame: NSRect(origin: .zero, size: size))
        window.orderFrontRegardless()
        return window
    }

    /// Narrow vertical bands cycling white → bone → mid grey → near black →
    /// saturated, plus a diagonal rule across them.
    ///
    /// Narrow on purpose: at 60 pt every pill from the 48 pt resting bar to the
    /// 288 pt alarm spans four or five of them at once, so each shot is a test
    /// of the *same* capsule against every extreme simultaneously — which is
    /// the actual claim ("it reads on white and on black"), and one a wide band
    /// would let the pill dodge.
    final class BackdropView: NSView {
        private static let bandWidth: CGFloat = 60
        private static let bands: [NSColor] = [
            .white,
            NSColor(srgbRed: 0.96, green: 0.95, blue: 0.92, alpha: 1),   // bone
            NSColor(srgbRed: 0.55, green: 0.57, blue: 0.60, alpha: 1),   // mid grey
            NSColor(srgbRed: 0.05, green: 0.06, blue: 0.07, alpha: 1),   // near black
            NSColor(srgbRed: 0.14, green: 0.36, blue: 0.85, alpha: 1),   // saturated
        ]

        override func draw(_ dirtyRect: NSRect) {
            var x: CGFloat = 0
            var index = 0
            while x < bounds.width {
                Self.bands[index % Self.bands.count].setFill()
                NSRect(x: x, y: 0, width: Self.bandWidth, height: bounds.height).fill()
                x += Self.bandWidth
                index += 1
            }
            NSColor(white: 0.5, alpha: 0.6).setStroke()
            let rule = NSBezierPath()
            rule.lineWidth = 3
            rule.move(to: NSPoint(x: 0, y: bounds.maxY))
            rule.line(to: NSPoint(x: bounds.maxX, y: 0))
            rule.stroke()
        }
    }

    // MARK: - the script

    /// Every state the session can put the pill in, in the order a real
    /// utterance meets them, plus the three that only arrive when something
    /// goes sideways.
    static func script() -> [Step] {
        [
            Step("01-idle", dwell: 2.0) { $0.showIdle() },

            Step("02-prewarming", dwell: 1.2, shotAt: 0.6) { $0.showPrewarming() },

            // The bars coming alive. Idle and listening are the same capsule
            // now, so this transition moves no frame at all — which is exactly
            // what the burst should show: ten dots in place, growing.
            Step("03-listening-bloom", dwell: 2.0, shotAt: 1.2,
                 burst: [0.05, 0.10, 0.15, 0.20, 0.25, 0.30, 0.40, 0.50],
                 level: { t in speech(t) }) { $0.showRecording() },

            // Quiet speech: the gamma in `WaveformBuffer.shaped` is what makes
            // this visible at all, so it is worth a shot of its own.
            Step("04-listening-quiet", dwell: 2.4, shotAt: 1.6,
                 level: { t in 0.012 + 0.010 * sin(t * 7.0) }) { $0.showRecording() },

            // Speech at a normal level, with the syllable rate a real voice has.
            Step("05-listening-loud", dwell: 2.4, shotAt: 1.8,
                 level: { t in speech(t) }) { _ in },

            // **The interpolation proof.** One sample at t = 0.05 s and then
            // nothing: the feed goes silent, so every frame after it is the
            // render server tweening on its own. If these eight PNGs differ,
            // the pill is drawing frames nobody asked it for — which is the
            // entire difference between Flow's glide and our old tick.
            Step("06-single-sample-tween", dwell: 1.4, shotAt: 1.3,
                 burst: [0.07, 0.10, 0.13, 0.16, 0.19, 0.22, 0.25, 0.30],
                 level: { t in t < 0.06 ? 0.9 : nil }) { $0.showRecording() },

            // The live tail: the capsule opens rightwards for the words.
            Step("07-listening-tail", dwell: 2.6, shotAt: 1.8,
                 level: { t in speech(t) }) { pill in
                pill.showRecording()
                pill.livePartial("so I was thinking about")
            },

            // **The release.** Bars to floor, cream to muted, capsule to
            // 128 pt, spinner in — all inside 160 ms, as one event.
            Step("08-finalizing", dwell: 2.2, shotAt: 1.6,
                 burst: [0.00, 0.04, 0.08, 0.12, 0.16, 0.20, 0.26, 0.34],
                 enterAt: 0.26) {
                $0.showFinalizing()
            },

            // The long one (AUDIT-2026-08-14): a batch rescue can hold this
            // state for seconds. At 1.4 s the pill says what it is waiting on.
            Step("09-rescue-wait", dwell: 3.4, shotAt: 2.4) { $0.showFinalizing() },

            // The spinner mid-revolution, four frames a step apart, so the
            // discrete 45° tick is visible as a tick.
            Step("10-refining", dwell: 2.4, shotAt: 1.4,
                 burst: [0.60, 0.71, 0.82, 0.93]) { $0.showRefining() },

            // **The commit.** 128 → 96 with the spinner going and the dots
            // brightening back to cream. No check mark: the text is the
            // confirmation.
            Step("11-committed", dwell: 1.8, shotAt: 0.9,
                 burst: [0.00, 0.04, 0.08, 0.12, 0.16, 0.22, 0.30, 0.40],
                 enterAt: 0.26) { $0.flashSuccess() },

            // **The toast.** Wispr's unfold: a 133 ms edge pop and a 400 ms
            // width unfold on the heavy-deceleration bezier.
            Step("12-notice", dwell: 2.4, shotAt: 1.2,
                 burst: [0.00, 0.05, 0.11, 0.17, 0.23, 0.30, 0.38, 0.48],
                 enterAt: 0.26) {
                $0.transientNotice("Learned Sharique")
            },

            Step("13-missed", dwell: 1.8, shotAt: 0.45) {
                $0.flashMissed("Didn't catch that")
            },

            Step("14-error", dwell: 2.2, shotAt: 0.8) {
                $0.flashError("Microphone delivered no audio")
            },

            Step("15-blocked-secure", dwell: 3.0, shotAt: 0.9) {
                $0.flashBlockedSecure()
            },

            Step("16-settled", dwell: 1.6, shotAt: 1.0) { $0.showIdle() },
        ]
    }

    /// A plausible speaking envelope: a slow phrase contour with syllables on
    /// top and a little jitter, clamped to the meter's 0…1. Deterministic, so
    /// two runs produce comparable screenshots.
    static func speech(_ t: Double) -> Double {
        let phrase = 0.55 + 0.45 * sin(t * 1.7)
        let syllable = 0.5 + 0.5 * sin(t * 13.0)
        let jitter = 0.12 * sin(t * 31.0)
        return max(0, min(1, 0.26 * phrase * (0.35 + 0.75 * syllable) + jitter * 0.05))
    }

    private static func value(of flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag),
              index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    // MARK: - the driver

    /// Walks the script on the main run loop. One repeating timer does both
    /// jobs — feed the level ticker and advance the script — because that is
    /// also how the app does it, and a demo that used a different clock would
    /// be showing a different pill.
    @MainActor
    final class Driver {
        private let pill: Pill
        private let steps: [Step]
        private let shots: URL?
        /// Held so the exit path can take it down. A QA window that outlives
        /// its process is somebody else's problem later.
        private let backdrop: NSWindow?
        private var index = -1
        private var elapsed: Double = 0
        private var shotTaken = false
        /// How many of the current step's burst frames have been taken.
        private var burstTaken = 0
        /// When the next 20 Hz level sample is due, in step time.
        private var nextSample: Double = PillDemo.tickInterval
        private var entered = false
        private var timer: Timer?

        init(pill: Pill, steps: [Step], shots: URL?, backdrop: NSWindow?) {
            self.pill = pill
            self.steps = steps
            self.shots = shots
            self.backdrop = backdrop
        }

        func start() {
            emit("pill-demo: \(steps.count) states, "
                 + String(format: "%.1f", steps.reduce(0) { $0 + $1.dwell }) + " s total")
            if let shots { emit("pill-demo: shots → \(shots.path)") }
            advance()
            let timer = Timer.scheduledTimer(withTimeInterval: PillDemo.frameInterval,
                                             repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }

        private func tick() {
            guard index >= 0, index < steps.count else { return }
            let step = steps[index]
            elapsed += PillDemo.frameInterval
            let now = elapsed + 1e-9          // float accumulation, not a fudge

            if !entered, now >= step.enterAt {
                entered = true
                step.enter(pill)
            }
            if now >= nextSample {
                nextSample += PillDemo.tickInterval
                // A nil sample is a *skipped* tick, not a zero: feeding zero
                // would retarget the bars to floor and destroy the very thing
                // the single-sample burst is there to photograph.
                if let level = step.level, let value = level(elapsed) {
                    pill.updateLevel(value)
                }
            }

            // One burst frame per turn: two `screencapture` launches in the
            // same millisecond photograph the same instant twice.
            if burstTaken < step.burst.count, now >= step.burst[burstTaken] {
                capture(named: String(format: "%@-f%02d", step.name, burstTaken + 1))
                burstTaken += 1
            }
            if !shotTaken, now >= step.shotAt {
                shotTaken = true
                capture(named: step.name)
            }
            if now >= step.dwell { advance() }
        }

        private func advance() {
            index += 1
            elapsed = 0
            shotTaken = false
            burstTaken = 0
            nextSample = PillDemo.tickInterval
            entered = false
            guard index < steps.count else { return finish() }
            let step = steps[index]
            emit("pill-demo: → \(step.name)")
            if step.enterAt <= 0 {
                entered = true
                step.enter(pill)
            }
        }

        private func finish() {
            timer?.invalidate()
            timer = nil
            pill.hide()
            backdrop?.orderOut(nil)
            backdrop?.close()
            emit("pill-demo: done")
            // One run-loop turn so the hide animation is not cut off mid-fade.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { exit(0) }
        }

        /// `screencapture -x` over the pill's **live** frame plus a fixed
        /// margin. Deriving the rect from the panel rather than from a constant
        /// makes each screenshot a check on the geometry too: if the frame were
        /// wrong, the pill would not be centred in its own crop.
        ///
        /// AppKit's origin is bottom-left of the main screen and
        /// `screencapture`'s is top-left, which is the whole of the conversion.
        private func capture(named name: String) {
            guard let shots, let frame = pill.frameOnScreen,
                  let screen = NSScreen.main else { return }
            let margin = PillDemo.shotMargin
            let x = frame.minX - margin
            let width = frame.width + margin * 2
            let height = frame.height + margin * 2
            let top = screen.frame.maxY - (frame.maxY + margin)
            let rect = String(format: "%.0f,%.0f,%.0f,%.0f", x, top, width, height)
            let path = shots.appendingPathComponent("\(name).png").path
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-x", "-R\(rect)", path]
            try? process.run()
            emit("pill-demo:   shot \(name).png @ \(rect)")
        }

        private func emit(_ line: String) {
            print(line)
            fflush(stdout)
        }
    }
}
#endif
