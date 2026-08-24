#if os(macOS)
import CoreAudio
import Foundation
import WispritEngine
import WispritKit

/// `Wisprit miclab` — the active microphone probe behind the headphone-mic
/// decision (docs/research/hearing-and-corrections.md, Phase 0).
///
/// Doctor stays passive; this deliberately OPENS each candidate input (the
/// orange indicator lights) because the negotiated truth only exists while the
/// link is up: a classic-Bluetooth headset advertises whatever rate it likes
/// until HFP is negotiated, and the SCO bring-up cost is invisible until it is
/// paid. One run answers, per device:
///
///   - what the device ADVERTISED before the mic opened (the number that lies)
///   - what the input chain actually opened at (8 k CVSD / 16 k mSBC / 24 k /
///     48 k — if a Bluetooth input reads ≥ 32 k here, the AirPods high-quality
///     path reaches third-party Mac apps and the whole HFP tradeoff dissolves)
///   - `start()` cost and start → first buffer (SCO bring-up + HAL wake)
///   - a few seconds of peak / noise-floor so the two mics' hearing of the
///     same room is comparable on the meter's own scale
enum MicLab {

    static func run(arguments: [String]) -> Int32 {
        var seconds = 5.0
        var iterator = arguments.makeIterator()
        while let flag = iterator.next() {
            switch flag {
            case "--seconds":
                guard let raw = iterator.next(), let value = Double(raw), value > 0 else {
                    FileHandle.standardError.write(Data("--seconds needs a positive number\n".utf8))
                    return 2
                }
                seconds = min(value, 30)
            default:
                FileHandle.standardError.write(Data("usage: Wisprit miclab [--seconds N]\n".utf8))
                return 2
            }
        }

        guard let systemDefault = InputDeviceProbe.defaultInput() else {
            print("miclab: no default audio input device")
            return 1
        }
        let outputTransport = InputDeviceProbe.defaultOutputTransport()
        print("miclab: default output transport is "
              + (outputTransport.map(InputDevicePolicy.transportName) ?? "(unknown)"))

        // The default input, plus the built-in mic when it is a different
        // device — the exact pair the dual-capture design would arbitrate.
        var targets: [(label: String, id: AudioDeviceID)] = [("default", systemDefault.deviceID)]
        if let builtIn = InputDeviceProbe.builtInInput(), builtIn != systemDefault.deviceID {
            targets.append(("built-in", builtIn))
        }

        var failures = 0
        for target in targets {
            print("")
            if !probe(label: target.label, device: target.id, seconds: seconds) {
                failures += 1
            }
        }
        return failures == 0 ? 0 : 1
    }

    /// Open one device, watch it deliver, report. Returns false when the
    /// device never produced a buffer (permission, wedged input, dead link).
    private static func probe(label: String, device: AudioDeviceID, seconds: Double) -> Bool {
        let advertised = InputDeviceProbe.info(of: device)
        print("[\(label)] \(advertised.name) — \(advertised.transportName), "
              + "advertised \(Int(advertised.nominalSampleRate)) Hz")

        // The sink does the metering itself, per chunk, so short peaks are not
        // lost to the poll interval below.
        let meter = ChunkMeter()
        let capture = MicCapture(onChunk: { meter.add($0) })
        capture.preferredDevice = { device }

        let startBegan = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        guard capture.start() else {
            print("[\(label)] could not open (permission? no input streams?)")
            return false
        }
        let startMs = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - startBegan) / 1_000_000.0

        // SCO negotiation can spend 1–3 s before the first sample exists, on
        // top of a cold HAL wake; 10 s of patience separates "slow link" from
        // "nothing will ever arrive".
        let firstChunkDeadline = Date().addingTimeInterval(10)
        while capture.firstChunkMs == nil, Date() < firstChunkDeadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard let firstChunkMs = capture.firstChunkMs else {
            capture.stop()
            print("[\(label)] opened but delivered nothing in 10 s — dead input")
            return false
        }

        Thread.sleep(forTimeInterval: seconds)
        let negotiated = capture.negotiatedRateHz
        let landedOn = capture.captureDevice
        let floor = capture.noiseFloor
        capture.stop()

        let negotiatedText = negotiated.map { "\(Int($0)) Hz" } ?? "(unknown)"
        print("[\(label)] opened in \(Self.tenth(startMs)) ms, "
              + "first buffer after \(Self.tenth(firstChunkMs)) ms")
        if let landedOn, landedOn.deviceID != device {
            print("[\(label)] NOTE: AUHAL landed on \(landedOn.name), not the requested device")
        }
        print("[\(label)] negotiated input rate: \(negotiatedText)"
              + Self.verdict(transport: advertised.transport, negotiated: negotiated))
        print("[\(label)] \(Self.tenth(seconds * 1000)) ms sampled — "
              + "peak \(Self.fourth(meter.peak)), "
              + "noise floor \(floor.map(Self.fourth) ?? "(needs ≥300 ms)") , "
              + "\(meter.chunks) chunks / \(meter.bytes) bytes")
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

    private static func tenth(_ value: Double) -> String { String(format: "%.1f", value) }
    private static func fourth(_ value: Double) -> String { String(format: "%.4f", value) }
}

/// Per-chunk metering on the delivery thread, so nothing is lost to polling.
private final class ChunkMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var peakValue: Double = 0
    private var chunkCount = 0
    private var byteCount = 0

    func add(_ pcm: Data) {
        let level = Double(PcmFormat.level(fromMeanSquare: PcmFormat.meanSquare(of: pcm)))
        lock.lock()
        peakValue = max(peakValue, level)
        chunkCount += 1
        byteCount += pcm.count
        lock.unlock()
    }

    var peak: Double { lock.lock(); defer { lock.unlock() }; return peakValue }
    var chunks: Int { lock.lock(); defer { lock.unlock() }; return chunkCount }
    var bytes: Int { lock.lock(); defer { lock.unlock() }; return byteCount }
}
#endif
