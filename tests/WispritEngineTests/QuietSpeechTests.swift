import XCTest
import WispritKit
@testable import WispritEngine

/// The quiet-speech pair (2026-08-15): what the batch rescue is allowed to
/// amplify, and what counts as audio the room swallowed.
///
/// Both come out of one measured finding: the recognizer is level-invariant —
/// attenuating 60 LibriSpeech clips to a peak of 0.06 (the band the user's
/// telemetry shows) moved raw WER from 1.72 % to 1.89 %, and to 2.15 % at 0.015
/// — while the SAME speech over a 0.012 noise floor scored 5.58 %. Gain is
/// therefore worth a few lines on the failure path and nothing at all live, and
/// the honest remedy for the noisy case is to tell the user.
///
/// No speech model is involved: the streaming engine is `FakeAsrEngine` and the
/// batch engine is a double that keeps the bytes it was handed.
final class RescueNormalizationTests: XCTestCase {

    /// Records the audio the batch pass actually received — the whole question
    /// on this path.
    final class CapturingBatch: BatchTranscribing, @unchecked Sendable {
        let name = "capturing"
        let text: String?
        private let lock = UnfairLock()
        private var received: [Data] = []
        init(text: String?) { self.text = text }

        var calls: Int { lock.withLock { received.count } }
        var lastPcm: Data { lock.withLock { received.last ?? Data() } }

        func transcribe(pcm: Data, settings: AsrSettings) async -> String? {
            lock.withLock { received.append(pcm) }
            return text
        }
    }

    /// A constant-amplitude buffer at a chosen meter level (RMS × 4).
    private func tone(atLevel level: Float, seconds: Double = 1.0) -> Data {
        let count = Int(seconds * PcmFormat.sampleRate)
        let samples = [Int16](repeating: Int16((Double(level) / 4.0 * 32768).rounded()),
                              count: count)
        return samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private func run(_ result: UtteranceResult, audio: Data, batchText: String?,
                     engine: AsrEngineKind = .appleLive) async -> (UtteranceResult, CapturingBatch) {
        let batch = CapturingBatch(text: batchText)
        let m = AsrManager(settings: AsrSettings(engine: engine),
                           primaryFactory: { _ in FakeAsrEngine(script: .init(result: result)) },
                           batch: FilteredBatchTranscriber(batch))
        await m.begin { _ in }
        m.feed(pcm: audio)
        return (await m.finalize(), batch)
    }

    /// The whole point: a failed utterance in the user's own telemetry band is
    /// re-read at a level the recognizer has a full 36 dB of measured tolerance
    /// for, instead of at the level the microphone happened to capture.
    func testAQuietFailedUtteranceIsHandedNormalizedAudio() async {
        let quiet = tone(atLevel: 0.06)
        let (r, batch) = await run(
            .init(text: "", engine: "apple_live", finalizeMs: 90,
                  peakLevel: 0.06, producedNothing: true),
            audio: quiet, batchText: "the words the meter nearly lost")

        XCTAssertEqual(batch.calls, 1)
        XCTAssertEqual(PcmFormat.peakLevel(of: batch.lastPcm),
                       PcmFormat.normalizationTargetPeak, accuracy: 0.01)
        XCTAssertEqual(r.text, "the words the meter nearly lost")
        XCTAssertTrue(r.rescued)
        XCTAssertEqual(r.rescueGainDb ?? 0, 18.4, accuracy: 0.3, "20·log10(0.5 / 0.06)")
    }

    /// Above the ceiling the engine is measurably level-invariant, so scaling is
    /// risk without measured return: the batch pass gets the retained bytes.
    func testALoudFailedUtteranceIsHandedTheRetainedBytesUnchanged() async {
        let loud = tone(atLevel: 0.4)
        let (r, batch) = await run(
            .init(text: "", engine: "apple_live", finalizeMs: 1500,
                  timedOut: true, peakLevel: 0.4),
            audio: loud, batchText: "read back whole")

        XCTAssertEqual(batch.calls, 1)
        XCTAssertEqual(batch.lastPcm, loud, "bit-identical, not merely similar")
        XCTAssertNil(r.rescueGainDb)
    }

    /// The ceiling itself, and the floor: both ends of `[voicedPeakThreshold,
    /// 0.25)` are decided by the STREAMING engine's metered peak.
    func testTheGateIsExactlyTheMeasuredWindow() {
        let quiet = tone(atLevel: 0.06)
        XCTAssertEqual(AsrManager.rescueGain(peakLevel: 0.249, pcm: quiet),
                       PcmFormat.normalizationGain(of: quiet), accuracy: 1e-6)
        XCTAssertEqual(AsrManager.rescueGain(peakLevel: 0.25, pcm: quiet), 1,
                       "at the ceiling the engine is level-invariant")
        XCTAssertEqual(AsrManager.rescueGain(peakLevel: 0.9, pcm: quiet), 1)
        XCTAssertEqual(
            AsrManager.rescueGain(peakLevel: SpeechAnalyzerEngine.voicedPeakThreshold - 0.001,
                                  pcm: quiet), 1,
            "below the voiced threshold there is nothing but room to amplify")
    }

    /// A clean-finish silent hold never reaches the rescue at all — the
    /// b0a763f rule, unmoved by any of this.
    func testASilentCleanFinishNeverReachesTheRescue() async {
        let (r, batch) = await run(
            .init(text: "", engine: "apple_live", finalizeMs: 45, peakLevel: 0.005),
            audio: tone(atLevel: 0.005), batchText: "Thank you.")
        XCTAssertEqual(batch.calls, 0)
        XCTAssertEqual(r.text, "")
        XCTAssertNil(r.rescueGainDb)
    }

    /// …but `producedNothing` CAN fire under the voiced threshold, on the
    /// volatile witness (an analyzer transcribing audio the meter never saw).
    /// That utterance is rescued, and the silence exemption still refuses to
    /// amplify it — twice over, since the retained audio is quiet too.
    func testAVolatileWitnessBelowTheThresholdIsRescuedButNeverAmplified() async {
        let nearSilence = tone(atLevel: 0.004)
        let (r, batch) = await run(
            .init(text: "quietly spoken", engine: "apple_live", finalizeMs: 90,
                  peakLevel: 0.001, producedNothing: true),
            audio: nearSilence, batchText: "quietly spoken words the meter never saw")

        XCTAssertEqual(batch.calls, 1, "the volatile is speech evidence in its own right")
        XCTAssertEqual(batch.lastPcm, nearSilence, "and its silence is still exempt")
        XCTAssertNil(r.rescueGainDb)
    }

    /// The field describes the AUDIO, not the arbitration: a rescue whose text
    /// loses the word-count comparison still says the audio had to be lifted.
    func testTheGainRidesADeclinedRescueToo() async {
        let (r, batch) = await run(
            .init(text: "four words came through", engine: "apple_live",
                  finalizeMs: 1500, timedOut: true, peakLevel: 0.06),
            audio: tone(atLevel: 0.06), batchText: "fewer words")

        XCTAssertEqual(batch.calls, 1)
        XCTAssertEqual(r.text, "four words came through", "the rescue may add words, never lose them")
        XCTAssertFalse(r.rescued)
        XCTAssertNotNil(r.rescueGainDb, "the amplification happened and the row must say so")
    }

    /// The exclusion the brief is emphatic about: the batch-ONLY path is not a
    /// failure path. Its transcripts feed the learn loop, and a nonlinear stage
    /// in front of that is not a thing to introduce quietly.
    func testTheBatchOnlyPathIsNeverNormalized() async {
        let quiet = tone(atLevel: 0.06)
        let (r, batch) = await run(
            .init(text: "unused", engine: "apple_live", finalizeMs: 10),
            audio: quiet, batchText: "from the retained audio", engine: .mlxWhisper)

        XCTAssertEqual(batch.calls, 1)
        XCTAssertEqual(batch.lastPcm, quiet)
        XCTAssertNil(r.rescueGainDb)
    }
}

/// The classifier behind the honest pill copy. Pure — no audio, no session.
final class MarginalAudioTests: XCTestCase {

    /// The production shape: peak 0.04 over floor 0.0146 is a ratio of 2.7,
    /// about 9 dB — one of the six `produced_nothing` rows in `metrics.log`.
    func testTheProductionFailureRowsAreMarginal() {
        XCTAssertTrue(MarginalAudio.isMarginal(peakLevel: 0.0398, noiseFloor: 0.0146))
        XCTAssertTrue(MarginalAudio.isMarginal(peakLevel: 0.0224, noiseFloor: 0.0111))
        XCTAssertTrue(MarginalAudio.isMarginal(peakLevel: 0.0199, noiseFloor: 0.0103))
    }

    /// The quiet dictations that SUCCEED sit above the peak ceiling — a user
    /// with a working quiet setup must never be told to speak up.
    func testQuietButWorkingUtterancesAreNotMarginal() {
        XCTAssertFalse(MarginalAudio.isMarginal(peakLevel: 0.1512, noiseFloor: 0.0249))
        XCTAssertFalse(MarginalAudio.isMarginal(peakLevel: 0.0763, noiseFloor: 0.0097),
                       "ratio 7.9 — comfortably clear of the room")
    }

    func testBothConditionsAreRequired() {
        // Quiet enough, but well clear of the floor.
        XCTAssertFalse(MarginalAudio.isMarginal(peakLevel: 0.05, noiseFloor: 0.002))
        // Poor ratio, but loud — a noisy room the user is out-talking.
        XCTAssertFalse(MarginalAudio.isMarginal(peakLevel: 0.5, noiseFloor: 0.2))
        XCTAssertTrue(MarginalAudio.isMarginal(peakLevel: 0.05, noiseFloor: 0.012))
    }

    /// A capture shorter than three 100 ms chunks has no floor at all, and
    /// guessing one from a fumbled tap is how a working setup gets nagged.
    func testAMissingOrEmptyFloorIsNeverMarginal() {
        XCTAssertFalse(MarginalAudio.isMarginal(peakLevel: 0.05, noiseFloor: nil))
        XCTAssertFalse(MarginalAudio.isMarginal(peakLevel: 0.05, noiseFloor: 0),
                       "digital silence under the speech swallowed nothing")
    }

    /// Silence is not faint speech: the voiced threshold gates this exactly as
    /// it gates the rescue.
    func testSilenceIsNotMarginal() {
        XCTAssertFalse(MarginalAudio.isMarginal(peakLevel: 0.001, noiseFloor: 0.0005))
        XCTAssertFalse(MarginalAudio.isMarginal(
            peakLevel: SpeechAnalyzerEngine.voicedPeakThreshold - 0.001, noiseFloor: 0.005))
    }

    func testTheBoundariesAreWhereTheyAreDocumented() {
        XCTAssertFalse(MarginalAudio.isMarginal(peakLevel: MarginalAudio.peakCeiling,
                                                noiseFloor: 0.03))
        XCTAssertTrue(MarginalAudio.isMarginal(peakLevel: MarginalAudio.peakCeiling - 0.001,
                                               noiseFloor: 0.03))
        // Exactly at the ratio is NOT marginal — the rule is "closer than 5×".
        XCTAssertFalse(MarginalAudio.isMarginal(peakLevel: 0.05, noiseFloor: 0.01))
    }
}

#if os(macOS)
/// The one-time input-volume advisory. Read-only by construction: the probe is
/// injected, and nothing in the type can write a Core Audio property.
final class InputVolumeAdvisorTests: XCTestCase {

    private func advisor(volume: Float, device: UInt32 = 7,
                         enabled: Bool = true) -> InputVolumeAdvisor {
        InputVolumeAdvisor(isEnabled: { enabled }, probe: { (device: device, volume: volume) })
    }

    func testALowSliderIsMentionedExactlyOnce() {
        let a = advisor(volume: 0.51)
        XCTAssertEqual(a.lowVolumePercent(), 51)
        XCTAssertNil(a.lowVolumePercent(), "once per device appearance, never per utterance")
        XCTAssertNil(a.lowVolumePercent())
    }

    func testAHealthySliderSaysNothingAtAll() {
        XCTAssertNil(advisor(volume: 0.7).lowVolumePercent(), "the ceiling is exclusive")
        XCTAssertNil(advisor(volume: 1.0).lowVolumePercent())
    }

    func testTheDevicePolicyKillSwitchSilencesIt() {
        XCTAssertNil(advisor(volume: 0.2, enabled: false).lowVolumePercent())
    }

    func testADeviceWithNoVolumeControlIsNotGuessedAt() {
        XCTAssertNil(InputVolumeAdvisor(probe: { nil }).lowVolumePercent())
    }

    /// A new default input is a new fact about the user's setup, so it earns one
    /// more line — the `NarrowbandWarner` rule, deliberately identical.
    func testANewDeviceEarnsOneMoreNotice() {
        let volumes = VolumeScript(readings: [(device: 7, volume: 0.51),
                                             (device: 7, volume: 0.51),
                                             (device: 9, volume: 0.30)])
        let a = InputVolumeAdvisor(probe: { volumes.next() })
        XCTAssertEqual(a.lowVolumePercent(), 51)
        XCTAssertNil(a.lowVolumePercent())
        XCTAssertEqual(a.lowVolumePercent(), 30)
    }

    private final class VolumeScript: @unchecked Sendable {
        private let lock = UnfairLock()
        private var readings: [(device: UInt32, volume: Float)]
        init(readings: [(device: UInt32, volume: Float)]) { self.readings = readings }
        func next() -> (device: UInt32, volume: Float)? {
            lock.withLock { readings.isEmpty ? nil : readings.removeFirst() }
        }
    }
}
#endif
