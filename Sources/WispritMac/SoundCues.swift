import AppKit
import Foundation
import WispritKit
import WispritPersistence

/// R11 — the two sound cues (mic-open, commit) and their setting.
///
/// Why sound exists at all: `pill_hidden` is a shipped setting and a hidden
/// pill suppresses every visual state, so a pill-hidden user currently dictates
/// with no feedback channel except a 16 pt menu icon (native-feel §2.10). The
/// cues carry the whole feedback burden for that user and stay out of the way
/// for everyone else. Deliberately NO error cue — the visual alarm body is
/// enough, and a failure buzzer would make a starved mic feel like a slot
/// machine.
///
/// Honesty contract, enforced at the call sites in `SessionController`:
/// mic-open plays on the show-recording event, which is only reachable after
/// `audio.start()` succeeded (the orange rule in a second sense); commit plays
/// at the delivery instant, alongside the success flash (R6's ordering).
///
/// The assets are SYNTHESIZED, not bundled: `Package.swift` is
/// orchestrator-owned and declares no resources for this target, and a
/// deterministic ~70 ms low-gain synthesis needs no bundle, no network, and
/// gives the cue-bleed eval check (A-6) the exact PCM it must mix into clip
/// heads. Both cues are ≤ 100 ms at ≤ −20 dBFS peak, pinned by tests.
public enum SoundCueSettings {
    /// `sounds` — the one toggle. String-keyed like `LiveTypingSettings` et
    /// al.: it never enters the golden-pinned `Settings.defaults`, and the
    /// config file preserves it across builds.
    public static let enabledKey = "sounds"

    /// Explicit user choice wins. Absent one, the fallback is OFF — the
    /// plan's intended default is `pill_hidden`-keyed (cues on exactly when
    /// the pill is hidden, i.e. when they are the only channel), but that
    /// default flip is gated on the A-6 cue-bleed eval check (zero transcript
    /// delta with the cue mixed into matrix clip heads at realistic coupling
    /// levels), which has not run yet. When A-6 passes, change this fallback
    /// to `settings.pillHidden` — one line, and the manual matrix in
    /// FINAL-PLAN B-5 is the regression sheet.
    public static func isEnabled(_ settings: Settings) -> Bool {
        settings.bool(enabledKey) ?? false
    }

    public static func setEnabled(_ settings: Settings, _ value: Bool) {
        settings.set(enabledKey, value)
    }
}

/// Deterministic synthesis of the two cues, 16 kHz mono Int16 — the pipeline's
/// own format, so the A-6 harness can mix `pcm(for:)` straight into corpus
/// clips without resampling.
public enum SoundCueSynth {
    public static let sampleRate = 16_000.0
    /// Hard budget from the plan: cues are ≤ 100 ms.
    public static let maxDurationSeconds = 0.1
    /// Low-gain ceiling: −20 dBFS (peak amplitude 0.1 full scale).
    public static let peakAmplitude = 0.1

    /// The cue's samples. Short two-partial blips with a fast attack and an
    /// exponential decay — present without being percussive. mic-open rises
    /// (D5→A5: "go"), commit resolves downward onto the same root ("landed"),
    /// so the pair reads as one grammar even with eyes closed.
    public static func samples(for cue: SoundCue) -> [Int16] {
        switch cue {
        case .micOpen:
            return blip(notes: [(587.33, 0.034), (880.0, 0.044)])
        case .commit:
            return blip(notes: [(880.0, 0.030), (587.33, 0.048)])
        }
    }

    /// A minimal RIFF/WAVE wrapper around `samples(for:)`, playable by
    /// `NSSound(data:)`.
    public static func wavData(for cue: SoundCue) -> Data {
        let samples = samples(for: cue)
        var pcm = Data(capacity: samples.count * 2)
        for s in samples {
            let le = UInt16(bitPattern: s).littleEndian
            pcm.append(UInt8(truncatingIfNeeded: le))
            pcm.append(UInt8(truncatingIfNeeded: le >> 8))
        }
        var data = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8))
        u32(UInt32(36 + pcm.count))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        u32(16)                                   // PCM fmt chunk size
        u16(1)                                    // linear PCM
        u16(1)                                    // mono
        u32(UInt32(sampleRate))
        u32(UInt32(sampleRate) * 2)               // byte rate
        u16(2)                                    // block align
        u16(16)                                   // bits per sample
        data.append(contentsOf: Array("data".utf8))
        u32(UInt32(pcm.count))
        data.append(pcm)
        return data
    }

    private static func blip(notes: [(frequency: Double, seconds: Double)]) -> [Int16] {
        var out: [Int16] = []
        var phase = 0.0
        for (index, note) in notes.enumerated() {
            let count = Int(sampleRate * note.seconds)
            for i in 0..<count {
                let t = Double(i) / Double(count)
                // 3 ms linear attack on the first note only (the later note
                // inherits a continuous phase, so no click), exponential decay.
                let attack = index == 0 ? min(1.0, Double(i) / (sampleRate * 0.003)) : 1.0
                let envelope = attack * exp(-2.6 * t)
                let sample = sin(phase) * envelope * peakAmplitude
                out.append(Int16(max(-32768, min(32767, sample * 32767.0)).rounded()))
                phase += 2.0 * .pi * note.frequency / sampleRate
            }
        }
        return out
    }
}

/// The production `SoundPort`: pre-built `NSSound`s, played only while the
/// `sounds` setting is on (checked per play, so a toggle applies to the very
/// next utterance), always off the session thread's critical path.
public final class SystemSoundCues: SoundPort, @unchecked Sendable {
    private let enabled: @Sendable () -> Bool
    private let sounds: [SoundCue: NSSound]

    public convenience init(settings: Settings) {
        self.init(enabled: { SoundCueSettings.isEnabled(settings) })
    }

    public init(enabled: @escaping @Sendable () -> Bool) {
        self.enabled = enabled
        var built: [SoundCue: NSSound] = [:]
        for cue in SoundCue.allCases {
            if let sound = NSSound(data: SoundCueSynth.wavData(for: cue)) {
                sound.volume = 1.0   // the gain lives in the asset (−20 dBFS)
                built[cue] = sound
            }
        }
        self.sounds = built
    }

    public func play(_ cue: SoundCue) {
        guard enabled(), let sound = sounds[cue] else { return }
        // NSSound.play is asynchronous; hop to main anyway so the session
        // thread never touches AppKit. `stop()` first so a rapid re-press
        // retriggers rather than being swallowed by a still-playing instance.
        DispatchQueue.main.async {
            if sound.isPlaying { sound.stop() }
            sound.play()
        }
    }
}
