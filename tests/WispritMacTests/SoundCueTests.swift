import XCTest
import WispritPersistence
@testable import WispritMac

/// R11's cue assets and setting, pinned to the plan's own bars: both cues are
/// ≤ 100 ms, low-gain (≤ −20 dBFS peak), deterministic, and 16 kHz mono Int16 —
/// the pipeline's format, so the A-6 cue-bleed check can mix them straight
/// into corpus clip heads. The `sounds` default stays OFF until that check
/// passes (FINAL-PLAN cross-track dependency 4).
final class SoundCueTests: XCTestCase {

    // MARK: - assets

    func testBothCuesRespectTheDurationAndGainBudgets() {
        for cue in SoundCue.allCases {
            let samples = SoundCueSynth.samples(for: cue)
            XCTAssertFalse(samples.isEmpty, "\(cue)")
            let maxSamples = Int(SoundCueSynth.sampleRate * SoundCueSynth.maxDurationSeconds)
            XCTAssertLessThanOrEqual(samples.count, maxSamples,
                                     "\(cue) must stay within the 100 ms budget")
            let peak = samples.map { abs(Int($0)) }.max() ?? 0
            let ceiling = Int((SoundCueSynth.peakAmplitude * 32767.0).rounded()) + 1
            XCTAssertLessThanOrEqual(peak, ceiling,
                                     "\(cue) must stay low-gain (≤ −20 dBFS)")
            XCTAssertGreaterThan(peak, 500, "\(cue) must actually be audible")
        }
    }

    func testSynthesisIsDeterministic() {
        for cue in SoundCue.allCases {
            XCTAssertEqual(SoundCueSynth.samples(for: cue), SoundCueSynth.samples(for: cue))
            XCTAssertEqual(SoundCueSynth.wavData(for: cue), SoundCueSynth.wavData(for: cue))
        }
    }

    func testWavWrapperIsAValidRiffPcmFile() {
        for cue in SoundCue.allCases {
            let wav = SoundCueSynth.wavData(for: cue)
            let samples = SoundCueSynth.samples(for: cue)
            XCTAssertEqual(String(data: wav.prefix(4), encoding: .ascii), "RIFF")
            XCTAssertEqual(String(data: wav.subdata(in: 8..<12), encoding: .ascii), "WAVE")
            XCTAssertEqual(wav.count, 44 + samples.count * 2, "header + PCM, nothing else")
            // Sample rate at offset 24, little-endian.
            let rate = wav.subdata(in: 24..<28).withUnsafeBytes { $0.load(as: UInt32.self) }
            XCTAssertEqual(UInt32(littleEndian: rate), UInt32(SoundCueSynth.sampleRate))
        }
    }

    /// The two cues share a grammar but must be distinguishable — commit is
    /// not a replay of mic-open.
    func testTheTwoCuesAreDistinct() {
        XCTAssertNotEqual(SoundCueSynth.samples(for: .micOpen),
                          SoundCueSynth.samples(for: .commit))
    }

    // MARK: - the `sounds` setting

    private func temporarySettings() throws -> Settings {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wisprit-sounds-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return Settings(path: dir.appendingPathComponent("config.json"))
    }

    /// Default OFF: the intended pill_hidden-keyed default is gated on the
    /// A-6 cue-bleed eval check, which has not run. This test is the gate's
    /// tripwire — when A-6 passes and the fallback flips, it flips too.
    func testSoundsDefaultsOffUntilTheCueBleedCheckPasses() throws {
        let settings = try temporarySettings()
        XCTAssertFalse(SoundCueSettings.isEnabled(settings))
        // …even when the pill is hidden, until A-6 says otherwise.
        settings.set(SettingsKey.pillHidden, true)
        XCTAssertFalse(SoundCueSettings.isEnabled(settings))
    }

    func testExplicitChoiceWinsAndRoundTrips() throws {
        let settings = try temporarySettings()
        SoundCueSettings.setEnabled(settings, true)
        XCTAssertTrue(SoundCueSettings.isEnabled(settings))
        SoundCueSettings.setEnabled(settings, false)
        XCTAssertFalse(SoundCueSettings.isEnabled(settings))
        XCTAssertEqual(SoundCueSettings.enabledKey, "sounds")
    }

    // MARK: - the production port

    func testSystemSoundCuesHonorsTheEnabledClosure() {
        // Construction alone must succeed headless (NSSound from data), and a
        // disabled port must consult the closure on every play — the toggle
        // applies to the very next utterance, no relaunch.
        final class Flag: @unchecked Sendable { var on = false; var reads = 0 }
        let flag = Flag()
        let port = SystemSoundCues(enabled: { flag.reads += 1; return flag.on })
        port.play(.micOpen)
        XCTAssertEqual(flag.reads, 1, "the setting is consulted per play, not cached")
        flag.on = true
        port.play(.commit)
        XCTAssertEqual(flag.reads, 2)
    }
}
