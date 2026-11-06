import AppKit
import XCTest
@testable import WispritMacUI

/// The panel itself: it comes up, it goes away, and nothing can keep it up.
@MainActor
final class NotchIndicatorTests: XCTestCase {

    /// Spin the main run loop until `condition` holds or `timeout` passes.
    private func spin(until timeout: TimeInterval, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    func testListeningOrdersThePanelAndAFoldRemovesIt() {
        let notch = NotchIndicator()
        XCTAssertFalse(notch.isOnScreen)
        notch.receive(.prewarm)
        notch.receive(.record)
        XCTAssertTrue(notch.isOnScreen)
        XCTAssertEqual(notch.phase, .listening(micLive: true))
        notch.updateLevel(0.2)
        // Let it open: a hide before anything was drawn is (rightly) instant.
        spin(until: 0.4) { false }
        XCTAssertTrue(notch.isOnScreen)
        notch.hide()
        XCTAssertTrue(notch.isOnScreen, "an open notch folds; it is not ordered out")
        XCTAssertEqual(notch.phase, .collapsing)
        spin(until: 2) { !notch.isOnScreen }
        XCTAssertFalse(notch.isOnScreen)
        XCTAssertEqual(notch.phase, .hidden)
        // And it opens again.
        notch.show()
        XCTAssertTrue(notch.isOnScreen)
        notch.hideImmediately()
        XCTAssertFalse(notch.isOnScreen)
    }

    func testTheResultBeatEndsOffScreenOnItsOwn() {
        let notch = NotchIndicator()
        notch.receive(.prewarm)
        notch.receive(.record)
        notch.receive(.processing(.finalizing))
        notch.receive(.result(.success))
        XCTAssertEqual(notch.phase, .result(.success))
        spin(until: 3) { !notch.isOnScreen }
        XCTAssertFalse(notch.isOnScreen)
        XCTAssertEqual(notch.phase, .hidden)
    }

    /// The watchdog, with a clock we control: a live notch whose level ticks
    /// stop is folded by the heartbeat even if no frame ever arrives.
    func testTheWatchdogFoldsASilentListeningNotch() {
        var now: TimeInterval = 100
        let notch = NotchIndicator(clock: { now })
        notch.receive(.prewarm)
        notch.receive(.record)
        XCTAssertTrue(notch.isOnScreen)
        now += NotchLifecycle.levelSilenceTimeout + NotchLifecycle.collapseBudget + 0.1
        spin(until: 1.5) { !notch.isOnScreen }
        XCTAssertFalse(notch.isOnScreen, "no ticks for 3 s: folded and gone")
        XCTAssertEqual(notch.phase, .hidden)
    }

    func testPillHiddenSuppressesEverything() {
        let notch = NotchIndicator(isSuppressed: { true })
        for signal: NotchSignal in [.prewarm, .record, .processing(.refining), .result(.error)] {
            notch.receive(signal)
            XCTAssertFalse(notch.isOnScreen, "\(signal)")
            XCTAssertEqual(notch.phase, .hidden)
        }
    }

    func testTurningPillHiddenOnMidUtteranceClearsTheScreen() {
        var hidden = false
        let notch = NotchIndicator(isSuppressed: { hidden })
        notch.receive(.prewarm)
        notch.receive(.record)
        notch.receive(.processing(.refining))
        XCTAssertTrue(notch.isOnScreen)
        hidden = true
        // No signal at all: the heartbeat notices on its own.
        spin(until: 1) { !notch.isOnScreen }
        XCTAssertFalse(notch.isOnScreen)
        XCTAssertEqual(notch.phase, .hidden)
    }

    func testAStaleRecordCannotResurrectAHiddenNotch() {
        let notch = NotchIndicator()
        notch.receive(.prewarm, sequence: 1)
        notch.receive(.dismiss, sequence: 3)
        spin(until: 2) { !notch.isOnScreen }
        notch.receive(.record, sequence: 2)
        notch.receive(.level(0.5), sequence: 2)
        XCTAssertFalse(notch.isOnScreen)
        XCTAssertEqual(notch.phase, .hidden)
    }

    func testTheSequenceStampIsMonotonicAcrossThreads() {
        let sequence = NotchSequence()
        let lock = NSLock()
        var seen: [UInt64] = []
        DispatchQueue.concurrentPerform(iterations: 2000) { _ in
            let value = sequence.next()
            lock.lock(); seen.append(value); lock.unlock()
        }
        XCTAssertEqual(Set(seen).count, 2000, "no stamp handed out twice")
        XCTAssertEqual(seen.max(), 2000)
    }

    // MARK: - pixels

    /// Counts pixels close to mic-orange in an RGBA8 image.
    private func orangePixels(_ image: CGImage) -> Int {
        let width = image.width, height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let ctx = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let hot = NotchPalette.hot
        var count = 0
        for i in stride(from: 0, to: data.count, by: 4) where data[i + 3] > 200 {
            let r = Double(data[i]) / 255, g = Double(data[i + 1]) / 255, b = Double(data[i + 2]) / 255
            if abs(r - hot.r) + abs(g - hot.g) + abs(b - hot.b) < 0.25 { count += 1 }
        }
        return count
    }

    /// The orange rule, checked on the rendered pixels of the real layer tree.
    func testRenderedOrangeAppearsOnlyWhileTheMicIsLive() throws {
        let layout = NotchGeometry.layout(on: .macBookPro14)
        let press = [NotchSnapshot.Cue(0, .prewarm), NotchSnapshot.Cue(0.05, .record)]
        let voice: (TimeInterval) -> Double = { 0.15 + 0.1 * sin($0 * 9) }

        let live = NotchSnapshot.simulate(layout: layout, cues: press, until: 1.5, level: voice)
        let liveImage = try XCTUnwrap(NotchSnapshot.image(layout: layout, frame: live.frame, backdrop: nil))
        XCTAssertGreaterThan(orangePixels(liveImage), 60, "dot and meter are orange")

        let grey = NotchSnapshot.simulate(layout: layout, cues: [press[0]], until: 1)
        let greyImage = try XCTUnwrap(NotchSnapshot.image(layout: layout, frame: grey.frame, backdrop: nil))
        XCTAssertEqual(orangePixels(greyImage), 0, "prewarm: the mic is not open")

        for stage: NotchSignal in [.processing(.finalizing), .processing(.refining), .result(.tooQuiet)] {
            let state = NotchSnapshot.simulate(layout: layout,
                                               cues: press + [NotchSnapshot.Cue(1.5, stage)],
                                               until: 2.1, level: voice)
            let image = try XCTUnwrap(NotchSnapshot.image(layout: layout, frame: state.frame, backdrop: nil))
            XCTAssertEqual(orangePixels(image), 0, "\(stage): mic closed, no orange")
        }
    }

    func testAHiddenFrameDrawsNothing() throws {
        let layout = NotchGeometry.layout(on: .macBookPro14)
        let state = NotchSnapshot.simulate(layout: layout, cues: [], until: 0.2)
        let image = try XCTUnwrap(NotchSnapshot.image(layout: layout, frame: state.frame, backdrop: nil))
        let width = image.width, height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let ctx = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        XCTAssertFalse(stride(from: 3, to: data.count, by: 4).contains { data[$0] != 0 })
    }
}
