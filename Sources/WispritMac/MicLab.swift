#if os(macOS)
import AVFoundation
import CoreAudio
import Foundation
import WispritEngine
import WispritKit

/// `Wisprit miclab` — the active microphone probe behind the headphone-mic
/// decision (docs/research/hearing-and-corrections.md, Phase 0) and, since
/// 2026-11-06, the capture-backend A/B (docs/eval/AUDIT-2026-11-06.md).
///
/// Doctor stays passive; this deliberately OPENS each candidate input (the
/// orange indicator lights) because the negotiated truth only exists while the
/// link is up: a classic-Bluetooth headset advertises whatever rate it likes
/// until HFP is negotiated, and the SCO bring-up cost is invisible until it is
/// paid. One run answers, per device and per capture backend:
///
///   - what the device ADVERTISED before the mic opened (the number that lies)
///   - which device the capture actually landed on (`engine` lands on macOS
///     27's private default-device aggregate when unpinned)
///   - what the input chain actually opened at (8 k CVSD / 16 k mSBC / 24 k /
///     48 k — if a Bluetooth input reads ≥ 32 k here, the AirPods high-quality
///     path reaches third-party Mac apps and the whole HFP tradeoff dissolves)
///   - `start()` cost, start → first buffer (SCO bring-up + HAL wake), and how
///     much of the head was DIGITAL ZERO (an aggregate filling for an input
///     that is not running yet — what a cold Bluetooth mic looked like through
///     the engine path)
///   - delivered audio vs wall time, and whether the hardware reconfigured
///   - a few seconds of peak / noise-floor so the two mics' (or two
///     backends') hearing of the same room is comparable on the meter's scale
///
/// `--record DIR` also writes each probe's 16 kHz capture as a WAV, so the
/// same signal can be scored through `Wisprit eval` (a `say -a` into a
/// loopback device makes it repeatable).
enum MicLab {

    struct Options: Equatable {
        var seconds = 5.0
        var backends: [MicCapture.Backend] = [.hal, .engine]
        /// A device id or a case-insensitive name fragment; nil = the default
        /// input plus the built-in mic when it differs.
        var device: String?
        var recordDir: String?
        var trials = 1
    }

    static let usage = """
        usage: Wisprit miclab [--seconds N] [--backend hal|engine|both] \
        [--device ID|NAME] [--trials N] [--record DIR]
        """

    static func parse(_ arguments: [String]) -> Options? {
        var options = Options()
        var iterator = arguments.makeIterator()
        while let flag = iterator.next() {
            guard let raw = iterator.next() else { return nil }
            switch flag {
            case "--seconds":
                guard let value = Double(raw), value > 0 else { return nil }
                options.seconds = min(value, 30)
            case "--backend":
                switch raw {
                case "both": options.backends = [.hal, .engine]
                default:
                    guard let backend = MicCapture.Backend(rawValue: raw) else { return nil }
                    options.backends = [backend]
                }
            case "--device":
                options.device = raw
            case "--trials":
                guard let value = Int(raw), value > 0 else { return nil }
                options.trials = min(value, 20)
            case "--record":
                options.recordDir = raw
            default:
                return nil
            }
        }
        return options
    }

    static func run(arguments: [String]) -> Int32 {
        guard let options = parse(arguments) else {
            FileHandle.standardError.write(Data((usage + "\n").utf8))
            return 2
        }
        guard let systemDefault = InputDeviceProbe.defaultInput() else {
            print("miclab: no default audio input device")
            return 1
        }
        let outputTransport = InputDeviceProbe.defaultOutputTransport()
        print("miclab: default input is \(systemDefault.name) (\(systemDefault.transportName)); "
              + "default output transport is "
              + (outputTransport.map(InputDevicePolicy.transportName) ?? "(unknown)"))

        var targets: [(label: String, id: AudioDeviceID, pinned: Bool)] = []
        if let wanted = options.device {
            guard let id = resolve(wanted) else {
                print("miclab: no input device matches \"\(wanted)\"")
                return 1
            }
            targets.append(("device", id, true))
        } else {
            // The default input UNPINNED — exactly what a press opens — plus
            // the built-in mic when it is a different device: the pair the
            // dual-capture design arbitrates.
            targets.append(("default", systemDefault.deviceID, false))
            if let builtIn = InputDeviceProbe.builtInInput(), builtIn != systemDefault.deviceID {
                targets.append(("built-in", builtIn, true))
            }
        }

        var failures = 0
        for target in targets {
            for trial in 1...options.trials {
                for backend in options.backends {
                    print("")
                    let label = "\(target.label)/\(backend.rawValue)"
                        + (options.trials > 1 ? "#\(trial)" : "")
                    if !probe(label: label, device: target.id, pinned: target.pinned,
                              backend: backend, options: options) {
                        failures += 1
                    }
                    Thread.sleep(forTimeInterval: 0.3)
                }
            }
        }
        return failures == 0 ? 0 : 1
    }

    /// An input device by id, or the first whose name contains `wanted`.
    private static func resolve(_ wanted: String) -> AudioDeviceID? {
        if let id = UInt32(wanted) { return id }
        return InputDeviceProbe.inputDevices().first {
            InputDeviceProbe.info(of: $0).name.localizedCaseInsensitiveContains(wanted)
        }
    }

    /// Open one device on one backend, watch it deliver, report. Returns false
    /// when the device never produced a buffer (permission, wedged input, dead
    /// link).
    private static func probe(label: String, device: AudioDeviceID, pinned: Bool,
                              backend: MicCapture.Backend, options: Options) -> Bool {
        let advertised = InputDeviceProbe.info(of: device)
        print("[\(label)] \(advertised.name) — \(advertised.transportName), "
              + "advertised \(Int(advertised.nominalSampleRate)) Hz"
              + (pinned ? "" : " (unpinned: whatever a press opens)"))

        // The sink does the metering itself, per chunk, so short peaks are not
        // lost to the poll interval below.
        let meter = ChunkMeter(keepAudio: options.recordDir != nil)
        let reconfigured = Flag()
        let capture = MicCapture(onChunk: { meter.add($0) },
                                 onConfigurationChange: { reconfigured.set() })
        if pinned { capture.preferredDevice = { device } }
        capture.backend = { backend }

        let startBegan = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        guard capture.start() else {
            print("[\(label)] could not open (permission? no input streams?)")
            return false
        }
        let startMs = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - startBegan) / 1_000_000.0
        let opened = Date()

        // SCO negotiation can spend 1–3 s before the first sample exists, on
        // top of a cold HAL wake; 10 s of patience separates "slow link" from
        // "nothing will ever arrive".
        let firstChunkDeadline = Date().addingTimeInterval(10)
        while capture.firstChunkMs == nil, Date() < firstChunkDeadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard let firstChunkMs = capture.firstChunkMs else {
            capture.stop()
            print("[\(label)] opened but delivered nothing in 10 s — dead input")
            return false
        }

        Thread.sleep(forTimeInterval: options.seconds)
        let negotiated = capture.negotiatedRateHz
        let landedOn = capture.captureDevice
        let ran = capture.activeBackend
        capture.stop()
        let wallMs = Date().timeIntervalSince(opened) * 1000
        let floor = capture.noiseFloor

        let negotiatedText = negotiated.map { "\(Int($0)) Hz" } ?? "(unknown)"
        print("[\(label)] backend \(ran?.rawValue ?? "?")"
              + (ran != backend ? " (FELL BACK from \(backend.rawValue))" : "")
              + ", opened in \(tenth(startMs)) ms, first buffer after \(tenth(firstChunkMs)) ms")
        print("[\(label)] attributed to: \(landedOn.map { "\($0.name) (\($0.transportName))" } ?? "(unknown)")")
        print("[\(label)] negotiated input rate: \(negotiatedText)"
              + verdict(transport: advertised.transport, negotiated: negotiated))
        print("[\(label)] delivered \(tenth(meter.audioMs)) ms of audio in \(tenth(wallMs)) ms wall; "
              + "leading digital-zero audio \(tenth(meter.zeroLeadMs)) ms"
              + (meter.zeroLeadMs >= meter.audioMs && meter.audioMs > 0 ? " (ALL ZERO — muted, denied, or a filled aggregate)" : ""))
        print("[\(label)] peak \(fourth(meter.peak)), "
              + "noise floor \(floor.map(fourth) ?? "(needs ≥300 ms)"), "
              + "\(meter.chunks) chunks / \(meter.bytes) bytes"
              + (reconfigured.value ? ", HARDWARE RECONFIGURED during the probe" : ""))
        if let dir = options.recordDir {
            let safe = label.replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: "#", with: "-")
            let url = URL(fileURLWithPath: dir).appendingPathComponent("miclab-\(safe).wav")
            do {
                try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                try writeWav(meter.audio, to: url)
                print("[\(label)] wrote \(url.path)")
            } catch {
                print("[\(label)] could not write \(url.path): \(error)")
            }
        }
        return true
    }

    /// The Phase-0 question, answered inline where the number appears.
    private static func verdict(transport: UInt32, negotiated: Double?) -> String {
        guard InputDevicePolicy.isClassicBluetooth(transport), let negotiated else { return "" }
        switch negotiated {
        case ..<12_000: return "  ← CVSD (8 kHz telephony — genuinely narrowband)"
        case ..<24_000: return "  ← mSBC wideband (16 kHz — the pipeline's own canonical rate)"
        case ..<32_000: return "  ← 24 kHz (AAC-ELD-class link)"
        default: return "  ← ≥32 kHz on classic BT: the high-quality path IS reachable here"
        }
    }

    /// 16 kHz mono Int16 → a canonical WAV.
    private static func writeWav(_ pcm: Data, to url: URL) throws {
        let file = try AVAudioFile(forWriting: url, settings: PcmFormat.canonical.settings,
                                   commonFormat: .pcmFormatInt16, interleaved: true)
        guard let buffer = PcmFormat.buffer(from: pcm, in: PcmFormat.canonical) else { return }
        try file.write(from: buffer)
    }

    private static func tenth(_ value: Double) -> String { String(format: "%.1f", value) }
    private static func fourth(_ value: Double) -> String { String(format: "%.4f", value) }
}

/// Per-chunk metering on the delivery thread, so nothing is lost to polling.
private final class ChunkMeter: @unchecked Sendable {
    private let lock = NSLock()
    private let keepAudio: Bool
    private var peakValue: Double = 0
    private var chunkCount = 0
    private var byteCount = 0
    private var zeroLeadBytes = 0
    private var sawSignal = false
    private var kept = Data()

    init(keepAudio: Bool) { self.keepAudio = keepAudio }

    func add(_ pcm: Data) {
        let level = Double(PcmFormat.level(fromMeanSquare: PcmFormat.meanSquare(of: pcm)))
        let allZero = pcm.allSatisfy { $0 == 0 }
        lock.lock()
        peakValue = max(peakValue, level)
        chunkCount += 1
        byteCount += pcm.count
        if !sawSignal {
            if allZero { zeroLeadBytes += pcm.count } else { sawSignal = true }
        }
        if keepAudio { kept.append(pcm) }
        lock.unlock()
    }

    var peak: Double { lock.lock(); defer { lock.unlock() }; return peakValue }
    var chunks: Int { lock.lock(); defer { lock.unlock() }; return chunkCount }
    var bytes: Int { lock.lock(); defer { lock.unlock() }; return byteCount }
    var audio: Data { lock.lock(); defer { lock.unlock() }; return kept }
    var audioMs: Double { Double(bytes) / Double(PcmFormat.bytesPerFrame) / PcmFormat.sampleRate * 1000 }
    var zeroLeadMs: Double {
        lock.lock(); defer { lock.unlock() }
        return Double(zeroLeadBytes) / Double(PcmFormat.bytesPerFrame) / PcmFormat.sampleRate * 1000
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    func set() { lock.lock(); raised = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return raised }
}
#endif
