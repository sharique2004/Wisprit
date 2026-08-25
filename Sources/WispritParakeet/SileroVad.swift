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

    /// FluidAudio's base directory; its ModelHub resolves `Models/silero-vad`
    /// beneath it.
    public static var fluidAudioBaseDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio", isDirectory: true)
    }

    /// Where the compiled model actually lands (verified on disk 2026-08-24:
    /// the local folder is `silero-vad`, not the HF repo's `-coreml` name).
    public static var cacheDirectory: URL {
        fluidAudioBaseDirectory.appendingPathComponent("Models/silero-vad", isDirectory: true)
    }

    /// The marker AND a compiled model actually on disk. This gate is what
    /// keeps `begin()` a file read: ModelHub's loader "handles downloading if
    /// needed" even on the from-directory path, so an evicted cache must fail
    /// HERE, before the loader could reach for the network.
    public static var isDownloaded: Bool {
        guard FileManager.default.fileExists(atPath: markerURL.path) else { return false }
        let entries = (try? FileManager.default
            .contentsOfDirectory(atPath: cacheDirectory.path)) ?? []
        return entries.contains { $0.hasSuffix(".mlmodelc") }
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
                // `modelDirectory` is FluidAudio's BASE dir (ModelHub appends
                // `Models/silero-vad` itself). `isDownloaded` above already
                // proved the compiled model is on disk, so this is a file
                // read — the loader's own download fallback can never fire.
                manager = try await VadManager(config: .default,
                                               modelDirectory: Self.fluidAudioBaseDirectory)
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
