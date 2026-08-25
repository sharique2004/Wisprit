import Foundation
import FluidAudio
import WispritEngine
import WispritKit

/// The FluidAudio-backed Silero scorer behind `WispritEngine.VadMonitor`
/// (docs/research/hearing-and-corrections.md, hearing tier 3).
///
/// Model custody: FluidAudio's own ModelHub cache
/// (`~/Library/Application Support/FluidAudio/Models/silero-vad-coreml`,
/// ~2 MB), fetched ONLY by the explicit `Wisprit vad download` command, which
/// writes the marker this scorer requires. `begin()` refuses unless BOTH the
/// marker and the cache directory exist — a marker whose cache was evicted
/// must not let `VadManager` quietly re-download at load time. The scorer is
/// advisory to the bone: every failure path answers nil/false and the monitor
/// above it stays inert.
public actor SileroVadScorer: VadScoring {

    /// Written by `Wisprit vad download` after a successful fetch — the
    /// explicit-consent receipt this scorer checks before ever loading.
    public static var markerURL: URL {
        WispritPaths.stateDir.appendingPathComponent("models/vad.downloaded")
    }

    /// Where FluidAudio's ModelHub keeps the compiled model.
    public static var cacheDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio/Models/silero-vad-coreml", isDirectory: true)
    }

    public static var isDownloaded: Bool {
        FileManager.default.fileExists(atPath: markerURL.path)
            && FileManager.default.fileExists(atPath: cacheDirectory.path)
    }

    private let log = WLog.logger("parakeet.vad")
    private var manager: VadManager?
    private var streamState: VadStreamState?
    /// One failed load per process is enough — begin() runs at every key-down.
    private var loadFailed = false

    public init() {}

    public func begin() async -> Bool {
        if manager == nil {
            guard !loadFailed, Self.isDownloaded else { return false }
            do {
                // Local directory load only: the consent receipt above is what
                // makes this a file read, never a network call.
                manager = try await VadManager(config: .default,
                                               modelDirectory: Self.cacheDirectory)
            } catch {
                loadFailed = true
                log.error("silero load failed: \(String(describing: error), privacy: .public)")
                return false
            }
        }
        streamState = await manager?.makeStreamState()
        return streamState != nil
    }

    public func score(window: Data) async -> Double? {
        guard let manager, let state = streamState else { return nil }
        let floats = Self.floats(of: window)
        guard floats.count == VadManager.chunkSize else { return nil }
        do {
            let result = try await manager.processStreamingChunk(floats, state: state)
            streamState = result.state
            return Double(result.probability)
        } catch {
            log.error("silero scoring failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// 16 kHz mono Int16 → the normalized floats the model eats.
    static func floats(of pcm: Data) -> [Float] {
        pcm.withUnsafeBytes { raw in
            raw.bindMemory(to: Int16.self).map { Float($0) / 32768.0 }
        }
    }
}
