#if os(macOS)
import Foundation
import WispritParakeet

/// `Wisprit parakeet <status|download>` — the explicit user action behind the
/// Parakeet reconcile channel (corrections B1). The app itself NEVER downloads
/// models: the store's manifest pins every file's URL and sha256, this command
/// fetches and verifies them, and the channel activates on the next launch
/// (`AppController` checks `state() == .verified` at wiring).
enum ParakeetCommand {

    static func run(arguments: [String]) -> Int32 {
        let store = ParakeetModelStore(modelsDir: ParakeetModelStore.productionModelsDir)
        switch arguments.first {
        case "status", nil:
            switch store.state() {
            case .verified:
                print("parakeet: models verified at \(store.modelsDir.path)")
                print("parakeet: the reconcile channel activates at app launch"
                      + " (parakeet_channel setting, default on)")
            case .partial(let missing):
                print("parakeet: models INCOMPLETE — \(missing.count) file(s) missing or"
                      + " failing their hash:")
                missing.prefix(8).forEach { print("  \($0)") }
                print("run: Wisprit parakeet download")
            case .notDownloaded:
                print("parakeet: models not downloaded (\(store.modelsDir.path))")
                print("run: Wisprit parakeet download")
            }
            return 0

        case "download":
            print("parakeet: downloading models to \(store.modelsDir.path)")
            print("parakeet: every file is verified against the pinned manifest sha256")
            let result: Int32 = runBlocking {
                do {
                    try await store.download { progress in
                        let percent = progress.totalBytes > 0
                            ? progress.completedBytes * 100 / progress.totalBytes : 0
                        print("  [\(progress.fileIndex)/\(progress.fileCount)] "
                              + "\(progress.file) — \(percent)%")
                    }
                    return 0
                } catch {
                    FileHandle.standardError.write(
                        Data("parakeet: download failed: \(error)\n".utf8))
                    return 1
                }
            }
            if result == 0 {
                print("parakeet: verified. The first launch compiles CoreML once (~16 s);"
                      + " after that the channel answers in ~300 ms.")
            }
            return result

        default:
            FileHandle.standardError.write(
                Data("usage: Wisprit parakeet [status|download]\n".utf8))
            return 2
        }
    }
}
#endif
