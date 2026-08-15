import Foundation
import WispritKit

/// Engine-layer contract, ported from `wisprit/asr.py`.
///
/// Streaming ASR for one push-to-talk utterance: `begin` on key-down, `feed`
/// from the audio callback, `finalize` on key-up, `cancel` to throw it away.
/// Nothing in here is macOS-specific — the capture seam is `MicCapture`.

/// One utterance's outcome. Field-for-field the Python `UtteranceResult`.
public struct UtteranceResult: Sendable, Equatable {
    public var text: String
    public var engine: String
    public var finalizeMs: Double
    /// finalize did not complete inside `finalize_timeout_ms`.
    public var timedOut: Bool
    /// The engine failed for real (results stream errored / finalize threw).
    /// One of several conditions that may trigger the batch rescue — see
    /// `AsrManager.needsRescue`, which also covers a timeout and a clean finish
    /// that ate audible speech. What has never been a rescue trigger, and must
    /// not become one, is emptiness alone: on silence the engine legitimately
    /// returns nothing.
    public var crashed: Bool
    /// Less than one 100 ms chunk of audio ever reached the analyzer, so an
    /// empty result says nothing about the engine — the capture side starved it.
    ///
    /// This exists because the two faults were indistinguishable in production.
    /// A starved analyzer and a wedged analyzer both produced
    /// `outcome=empty, finalize_ms≈1500, timed_out=false` (measured: 1500.9 ms
    /// for both "no audio at all" and "3 s of digital silence"), which is what
    /// made the 2026-08-05 incident unreadable from `metrics.log` alone.
    public var starvedInput: Bool
    /// Loudest `PcmFormat.level` the engine saw across this utterance, 0 when it
    /// never metered any (batch paths, a session that never started). It is the
    /// primary thing that separates "the user did not speak" from "the analyzer
    /// ate speech and returned nothing" — see `EmptyReason`.
    public var peakLevel: Float
    /// Speech in, clean finish, no final out — the defect, as opposed to the
    /// several benign ways an utterance legitimately comes back empty.
    ///
    /// "Speech in" has two witnesses and needs only one: a `peakLevel` over the
    /// voiced threshold, or a volatile the analyzer itself emitted. The second
    /// exists because the meter is a threshold on a physical signal — a low-gain
    /// microphone can sit under it while the analyzer transcribes perfectly
    /// well, and requiring the meter dropped those utterances on the floor.
    public var producedNothing: Bool
    /// This text came from the batch engine after the streaming one failed.
    ///
    /// The failure flags (`timedOut`/`crashed`/`producedNothing`) stay set on a
    /// rescued result on purpose: the streaming engine did fail, and a metrics
    /// stream that quietly relabelled those rows as successes would erase the
    /// very rate this whole path exists to drive down. This flag is what keeps
    /// "the streaming engine failed" and "the user lost their words" separable —
    /// before it, the two were the same row.
    public var rescued: Bool
    /// The audio hardware was reconfigured under this utterance's capture —
    /// the default input changed, or its format did (2026-08-05).
    ///
    /// `AVAudioEngine` stops itself on such a change and keeps the old formats,
    /// so the tap stops delivering: whatever this result says, it describes the
    /// audio up to the switch and nothing after it. That makes a NON-empty
    /// result the dangerous case — a clean, plausible, silently truncated
    /// sentence — which is why this is stamped on every result rather than only
    /// on the empty ones. Appended last and defaulted, so every existing
    /// construction site (the eval runner, the fakes, `rescue()`) still compiles
    /// and still means what it did.
    public var sawConfigurationChange: Bool
    /// How much gain the rescue's peak normalization applied before the batch
    /// engine read the audio, in dB — nil when it did not normalize at all,
    /// which is every path except a quiet-but-voiced rescue (2026-08-15).
    ///
    /// It rides the result rather than the metrics call site because the
    /// decision is made inside `AsrManager.rescue`, where nothing else can see
    /// it, and because the rate of this class is exactly what says whether the
    /// normalization is buying anything in production. Set even when the
    /// rescue's text is DECLINED: the question the field answers is "how often
    /// did we have to amplify", not "how often did amplifying win".
    public var rescueGainDb: Double?

    public init(text: String, engine: String, finalizeMs: Double,
                timedOut: Bool = false, crashed: Bool = false,
                starvedInput: Bool = false, peakLevel: Float = 0,
                producedNothing: Bool = false, rescued: Bool = false,
                sawConfigurationChange: Bool = false,
                rescueGainDb: Double? = nil) {
        self.text = text; self.engine = engine; self.finalizeMs = finalizeMs
        self.timedOut = timedOut; self.crashed = crashed
        self.starvedInput = starvedInput; self.peakLevel = peakLevel
        self.producedNothing = producedNothing; self.rescued = rescued
        self.sawConfigurationChange = sawConfigurationChange
        self.rescueGainDb = rescueGainDb
    }
}

public protocol AsrEngine: AnyObject, Sendable {
    /// Start an utterance. `onPartial` receives the full text-so-far
    /// (finalized prefix + current volatile window — see `SpeechAnalyzerEngine`),
    /// on an arbitrary task. Returns false if the engine could not start, so the
    /// caller can fall back.
    func begin(onPartial: @escaping @Sendable (String) -> Void) async -> Bool

    /// Hand one PCM chunk (16 kHz mono Int16) to the engine. **Never blocks** —
    /// it is called from the audio callback. Bounded queue, drop-oldest: a
    /// dropped chunk costs a few ms of captions, never a stall.
    func feed(pcm: Data)

    // CONTRACT-DEVIATION: SWIFT-INTERFACES.md specifies `finalize() async -> String`,
    // but the same clause requires finalize to report the timed-out flag, which a
    // String cannot carry. The requirement returns `UtteranceResult`; `finalizeText()`
    // below is the String-shaped convenience.
    func finalize() async -> UtteranceResult

    /// Discard the utterance and release the transcriber.
    func cancel() async
}

public extension AsrEngine {
    func finalizeText() async -> String { await finalize().text }
}

/// `settings["engine"]`, exactly the Python vocabulary.
public enum AsrEngineKind: String, Sendable, CaseIterable {
    case auto = "auto"
    case appleLive = "apple_live"
    case mlxWhisper = "mlx_whisper"
    case fasterWhisper = "faster_whisper"

    public init(settingsValue: String?) {
        self = AsrEngineKind(rawValue: settingsValue ?? "auto") ?? .auto
    }

    /// auto/apple_live drive the streaming primary; the whisper values skip
    /// straight to finalize-time batch transcription of the retained PCM.
    public var usesStreamingPrimary: Bool { self == .auto || self == .appleLive }
}

/// The slice of `config.json` the engine layer needs. WispritPersistence owns
/// `Settings`; the shell copies the relevant keys in here.
public struct AsrSettings: Sendable {
    public var locale: String
    public var finalizeTimeoutMs: Double
    public var engine: AsrEngineKind
    /// Cap on `contextualStrings` terms. nil = the whole dictionary — spike S1 Q3
    /// measured ~3.1 ms/term, all of it in session setup, on a path the user
    /// never waits for, and no biasing dilution at n = 500.
    public var contextualTermLimit: Int?

    public init(locale: String = "en-US", finalizeTimeoutMs: Double = 1500,
                engine: AsrEngineKind = .auto, contextualTermLimit: Int? = nil) {
        self.locale = locale; self.finalizeTimeoutMs = finalizeTimeoutMs
        self.engine = engine; self.contextualTermLimit = contextualTermLimit
    }

    var finalizeTimeoutSeconds: Double {
        finalizeTimeoutMs > 0 ? finalizeTimeoutMs / 1000.0 : 1.5
    }
}
