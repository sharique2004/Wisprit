#if os(macOS)
import AppKit
import Foundation
import WispritMacUI

/// `Wisprit notch-demo` — the living notch, every state, no microphone.
///
/// Hidden/dev verb, the notch's counterpart to `pill-demo`. Two modes:
///
/// - `--render DIR` draws every state offscreen through the real lifecycle,
///   choreography and layer tree, over a dark and a light menu bar, at 2×.
///   Deterministic to the pixel and needs no screen-recording grant. This is
///   what produces `docs/design/notch-listening/*.png`.
/// - default (optionally `--shots DIR`) drives the real panel on this Mac's
///   notch through a scripted utterance on synthetic levels, and with
///   `--shots` photographs the menu-bar band at the moment each state has
///   arrived.
@MainActor
enum NotchDemo {

    static func run(arguments: [String]) -> Never {
        if let dir = value(of: "--render", in: arguments) {
            exit(render(into: URL(fileURLWithPath: (dir as NSString).expandingTildeInPath,
                                  isDirectory: true)))
        }
        let shots = value(of: "--shots", in: arguments).map {
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true)
        }
        if let shots {
            try? FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let driver = LiveDriver(notch: NotchIndicator(), shots: shots)
        driver.start()
        app.run()
        exit(0)
    }

    // MARK: - offscreen

    typealias Cue = NotchSnapshot.Cue

    /// One rendered state: the script that reaches it and when to look.
    struct Shot {
        let name: String
        let caption: String
        let cues: [Cue]
        let at: TimeInterval
        var level: ((TimeInterval) -> Double)? = nil
    }

    /// A press at t = 0, mic open at 50 ms (measured), key-up at 2.6 s.
    static let press: [Cue] = [Cue(0, .prewarm), Cue(0.05, .record)]

    static func speaking(_ t: TimeInterval) -> Double { NotchIndicator.syntheticSpeech(t) }

    static func shots() -> [Shot] {
        let held = press
        let release: [Cue] = held + [Cue(2.6, .processing(.finalizing))]
        func result(_ kind: NotchResult) -> [Cue] {
            release + [Cue(2.9, .result(kind))]
        }
        return [
            Shot(name: "00-rest", caption: "rest — the hardware notch, nothing drawn",
                 cues: [], at: 0.2),
            Shot(name: "01-prewarming", caption: "key down, mic not open yet — grey, never orange",
                 cues: [Cue(0, .prewarm)], at: 0.5),
            Shot(name: "02-listening-silence", caption: "listening, silence — the row breathes",
                 cues: held, at: 1.5, level: { _ in 0 }),
            Shot(name: "03-listening-quiet", caption: "listening, quiet speech",
                 cues: held, at: 1.6, level: { t in 0.018 + 0.012 * sin(t * 9) }),
            Shot(name: "04-listening-speech", caption: "listening, speech — orange is the live mic",
                 cues: held, at: 1.93, level: speaking),
            Shot(name: "05-finalizing", caption: "key up — orange off, the ripple says working",
                 cues: release, at: 3.05, level: speaking),
            Shot(name: "06-refining", caption: "Apple Intelligence cleanup — sparkle + slower ripple",
                 cues: release + [Cue(2.75, .processing(.refining))], at: 3.6, level: speaking),
            Shot(name: "07-success", caption: "landed — the check draws on, row nods to dots",
                 cues: result(.success), at: 3.2, level: speaking),
            Shot(name: "08-missed", caption: "nothing to insert — neutral, a small head-shake",
                 cues: result(.missed), at: 3.25, level: speaking),
            Shot(name: "09-too-quiet", caption: "heard but too faint — ochre, calm",
                 cues: result(.tooQuiet), at: 3.3, level: speaking),
            Shot(name: "10-error", caption: "error — red, an ember wash, a shake",
                 cues: result(.error), at: 3.1, level: speaking),
            Shot(name: "11-blocked-secure", caption: "secure input — the lock; text is in history",
                 cues: result(.blockedSecure), at: 3.3, level: speaking),
        ]
    }

    static func render(into dir: URL) -> Int32 {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let notched = NotchGeometry.layout(on: NotchScreen.macBookPro14)
        let flat = NotchGeometry.layout(on: NotchScreen.external1080)
        var written = 0

        func draw(_ layout: NotchLayout, _ shot: Shot, _ backdrop: NotchSnapshot.Backdrop,
                  reduceMotion: Bool = false, increaseContrast: Bool = false) -> CGImage? {
            let state = NotchSnapshot.simulate(layout: layout, cues: shot.cues, until: shot.at,
                                               level: shot.level, reduceMotion: reduceMotion,
                                               increaseContrast: increaseContrast)
            return NotchSnapshot.image(layout: layout, frame: state.frame, backdrop: backdrop,
                                       increaseContrast: increaseContrast)
        }
        func save(_ image: CGImage?, _ name: String) {
            guard let image else { return }
            do {
                try NotchSnapshot.writePNG(image, to: dir.appendingPathComponent("\(name).png"))
                written += 1
                print("notch-demo: \(name).png")
            } catch {
                FileHandle.standardError.write(Data("notch-demo: \(name): \(error)\n".utf8))
            }
        }

        for backdrop in NotchSnapshot.Backdrop.allCases {
            var rows: [(String, CGImage)] = []
            for shot in shots() {
                guard let image = draw(notched, shot, backdrop) else { continue }
                if backdrop == .dark { save(image, shot.name) }
                rows.append((shot.caption, image))
            }
            save(NotchSnapshot.sheet(rows, dark: backdrop == .dark), "states-\(backdrop.rawValue)")
        }

        // Motion: the open and the fold as filmstrips.
        let openTimes: [TimeInterval] = [0.0, 0.03, 0.06, 0.09, 0.12, 0.16, 0.22, 0.32, 0.5]
        var openRows: [(String, CGImage)] = []
        for t in openTimes {
            let shot = Shot(name: "", caption: String(format: "open  +%3.0f ms", t * 1000),
                            cues: press, at: t, level: speaking)
            if let image = draw(notched, shot, .light) { openRows.append((shot.caption, image)) }
        }
        save(NotchSnapshot.sheet(openRows, dark: false), "motion-open")

        let foldStart = 2.9 + NotchLifecycle.dwell(for: .success)
        var foldRows: [(String, CGImage)] = []
        for dt in [0.0, 0.05, 0.1, 0.15, 0.2, 0.28, 0.4] {
            let shot = Shot(name: "", caption: String(format: "fold  +%3.0f ms", dt * 1000),
                            cues: press + [Cue(2.6, .processing(.finalizing)), Cue(2.9, .result(.success))],
                            at: foldStart + dt, level: speaking)
            if let image = draw(notched, shot, .light) { foldRows.append((shot.caption, image)) }
        }
        save(NotchSnapshot.sheet(foldRows, dark: false), "motion-fold")

        // A display without a notch, and the accessibility variants.
        var extra: [(String, CGImage)] = []
        let all = shots()
        for name in ["04-listening-speech", "06-refining", "07-success", "10-error"] {
            guard let shot = all.first(where: { $0.name == name }),
                  let image = draw(flat, shot, .light) else { continue }
            extra.append(("no notch · " + shot.caption, image))
        }
        if let speech = all.first(where: { $0.name == "04-listening-speech" }) {
            if let image = draw(notched, speech, .dark, reduceMotion: true) {
                extra.append(("Reduce Motion · listening (static row, brightness follows voice)", image))
            }
            if let image = draw(notched, speech, .light, increaseContrast: true) {
                extra.append(("Increase Contrast · listening (rim on the silhouette)", image))
            }
        }
        save(NotchSnapshot.sheet(extra, dark: false), "variants")
        return written > 0 ? 0 : 1
    }

    static func value(of flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    // MARK: - live

    /// Walks one scripted utterance per result on the real panel.
    @MainActor
    final class LiveDriver {
        struct Beat {
            let at: TimeInterval
            let name: String?
            let action: (NotchIndicator) -> Void
        }

        private let notch: NotchIndicator
        private let shots: URL?
        private var beats: [Beat] = []
        private var startedAt: TimeInterval = 0
        private var timer: Timer?
        private var nextTick: TimeInterval = 0

        init(notch: NotchIndicator, shots: URL?) {
            self.notch = notch
            self.shots = shots
            var t: TimeInterval = 0.5
            for kind in NotchResult.allCases {
                let base = t
                beats.append(Beat(at: base, name: nil) { $0.receive(.prewarm) })
                beats.append(Beat(at: base + 0.05, name: nil) { $0.receive(.record) })
                beats.append(Beat(at: base + 0.4, name: "live-\(kind.rawValue)-opening", action: { _ in }))
                beats.append(Beat(at: base + 1.6, name: "live-\(kind.rawValue)-listening", action: { _ in }))
                beats.append(Beat(at: base + 2.2, name: nil) { $0.receive(.processing(.finalizing)) })
                beats.append(Beat(at: base + 2.5, name: nil) { $0.receive(.processing(.refining)) })
                beats.append(Beat(at: base + 3.0, name: "live-\(kind.rawValue)-refining", action: { _ in }))
                beats.append(Beat(at: base + 3.3, name: nil) { $0.receive(.result(kind)) })
                beats.append(Beat(at: base + 3.55, name: "live-\(kind.rawValue)-result", action: { _ in }))
                t = base + 3.3 + NotchLifecycle.dwell(for: kind) + 1.0
            }
            beats.append(Beat(at: t, name: "live-folded", action: { _ in }))
        }

        func start() {
            startedAt = CACurrentMediaTime()
            print("notch-demo: live walkthrough, \(NotchResult.allCases.count) utterances")
            let timer = Timer(timeInterval: 0.01, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }

        private func tick() {
            let now = CACurrentMediaTime() - startedAt
            while let beat = beats.first, beat.at <= now {
                beats.removeFirst()
                beat.action(notch)
                if let name = beat.name { capture(name) }
            }
            if case .listening(micLive: true) = notch.phase, now >= nextTick {
                nextTick = now + 0.05
                notch.receive(.level(NotchIndicator.syntheticSpeech(now)))
            }
            if beats.isEmpty {
                timer?.invalidate()
                print("notch-demo: done (phase \(notch.phase), on screen \(notch.isOnScreen))")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(0) }
            }
        }

        /// The menu-bar band around the notch, generous on both sides.
        private func capture(_ name: String) {
            guard let shots, let screen = NSScreen.screens.first(where: {
                $0.auxiliaryTopLeftArea != nil
            }) ?? NSScreen.main else { return }
            let width: CGFloat = 420
            let height: CGFloat = 52
            let x = screen.frame.midX - width / 2
            let rect = String(format: "%.0f,%.0f,%.0f,%.0f", x, 0, width, height)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-x", "-R\(rect)", shots.appendingPathComponent("\(name).png").path]
            try? process.run()
            print("notch-demo:   shot \(name).png")
        }
    }
}
#endif
