#if os(macOS)
import FluidAudio
import Foundation
import WispritParakeet

/// `Wisprit vad <status|download>` — the explicit user action behind the
/// voice-activity witness (hearing tier 3). The download (~2 MB) goes through
/// FluidAudio's own ModelHub into its cache; success writes the marker
/// `SileroVadScorer` requires before it will ever load. The app itself never
/// fetches: no marker, no load, no network.
enum VadCommand {

    static func run(arguments: [String]) -> Int32 {
        switch arguments.first {
        case "status", nil:
            if SileroVadScorer.isDownloaded {
                print("vad: silero model present at \(SileroVadScorer.cacheDirectory.path)")
                print("vad: the speech witness activates at the next app launch")
            } else if FileManager.default.fileExists(atPath: SileroVadScorer.markerURL.path) {
                print("vad: marker present but the model cache is gone "
                      + "(\(SileroVadScorer.cacheDirectory.path))")
                print("run: Wisprit vad download")
            } else {
                print("vad: not downloaded")
                print("run: Wisprit vad download   (~2 MB, FluidInference/silero-vad-coreml)")
            }
            return 0

        case "download":
            print("vad: downloading silero-vad-coreml (~2 MB) via FluidAudio's ModelHub…")
            return runBlocking {
                do {
                    // The default initializer downloads into FluidAudio's
                    // cache when absent, then loads — one call is fetch,
                    // compile, and verify-by-loading in one.
                    _ = try await VadManager(config: .default)
                    let marker = SileroVadScorer.markerURL
                    try FileManager.default.createDirectory(
                        at: marker.deletingLastPathComponent(),
                        withIntermediateDirectories: true)
                    try Data("downloaded \(Date())\n".utf8).write(to: marker)
                    print("vad: model ready at \(SileroVadScorer.cacheDirectory.path)")
                    print("vad: marker written — the witness activates at the next launch")
                    return 0
                } catch {
                    FileHandle.standardError.write(
                        Data("vad: download failed: \(error)\n".utf8))
                    return 1
                }
            }

        default:
            FileHandle.standardError.write(Data("usage: Wisprit vad [status|download]\n".utf8))
            return 2
        }
    }
}
#endif
