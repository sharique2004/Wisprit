import CryptoKit
import Foundation
import WispritKit

/// THE one file in Wisprit allowed to touch the network at runtime, and only
/// inside the explicit, user-invoked `download` call. Everything else in this
/// target — and in every other target — is enforced offline by
/// `NetworkInvariantTests`, which allowlists exactly this path.
///
/// What it guarantees:
/// * **Byte identity.** Every file is verified against the SHA-256 manifest
///   (`ParakeetManifest`) after download and again in `state()`. A moved
///   HuggingFace ref, a truncated transfer, a hand-edited file — all fail
///   closed as `.partial`.
/// * **No silent FluidAudio downloads.** `AsrModels.load` routes every model
///   file through ModelHub, which fetches anything missing (spike, API
///   reality §). `ParakeetLiveDecoder` therefore refuses to call it unless
///   this store answers `.verified` — and belt-and-braces sets
///   `ModelHub.offlineMode` first.
/// * **`WISPRIT_NO_NETWORK=1` hard-refuses** before the fetcher is even asked.
///
/// Layout under `modelsDir` (production: `~/.wisprit/models/parakeet`):
/// `parakeet-tdt-0.6b-v3/…` + `parakeet-ctc-110m-coreml/…` + `verified.json`,
/// the marker WispritMac's doctor checks by path without importing this target.
public final class ParakeetModelStore: Sendable {

    public enum StoreError: Error, Equatable {
        /// `WISPRIT_NO_NETWORK=1` — the download refused to start.
        case networkDisabled
        /// A fetched file failed its size or SHA-256 check. The bad bytes are
        /// deleted; state remains `.partial`; no marker is written.
        case verificationFailed(path: String, reason: String)
        /// The fetcher threw. `path` is the manifest-relative local path.
        case fetchFailed(path: String, underlying: String)
    }

    /// One manifest file finished (downloaded-and-verified, or already good).
    /// `completedBytes`/`totalBytes` make a single progress bar trivial.
    public struct Progress: Sendable, Equatable {
        public var file: String
        public var fileIndex: Int
        public var fileCount: Int
        public var completedBytes: Int
        public var totalBytes: Int
    }

    /// The models dir every production caller should pass. A parameter rather
    /// than a baked-in path so tests (and the live integration test's symlink
    /// farm) never touch the real one.
    public static var productionModelsDir: URL {
        WispritPaths.stateDir
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("parakeet", isDirectory: true)
    }

    public let modelsDir: URL
    private let manifest: [ParakeetManifestFile]
    private let fetcher: any ParakeetAssetFetching
    private let environment: [String: String]
    private let log = WLog.logger("parakeet.store")

    public init(modelsDir: URL,
                manifest: [ParakeetManifestFile] = ParakeetManifest.files,
                fetcher: (any ParakeetAssetFetching)? = nil,
                environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.modelsDir = modelsDir
        self.manifest = manifest
        self.fetcher = fetcher ?? HuggingFaceAssetFetcher()
        self.environment = environment
    }

    // MARK: - State

    /// Re-hashes every manifest file. Seconds of work over the full 586 MB set
    /// — called by the explicit download flow and once before model load,
    /// never on a dictation path. The doctor's cheap path check reads the
    /// marker instead.
    public func state() -> ParakeetModelState {
        var missing: [String] = []
        var anythingPresent = false
        for file in manifest {
            let url = localURL(of: file)
            guard FileManager.default.fileExists(atPath: url.path) else {
                missing.append(file.localPath)
                continue
            }
            anythingPresent = true
            if verify(file, at: url) != nil { missing.append(file.localPath) }
        }
        if missing.isEmpty { return .verified }
        return anythingPresent ? .partial(missing: missing) : .notDownloaded
    }

    // MARK: - Download (the network entry point)

    /// Fetch every missing-or-mismatched manifest file, verify it, and write
    /// the version marker. Explicit user action ONLY — nothing in Wisprit
    /// calls this on its own. Resume-friendly: files that already verify are
    /// skipped, so a cancelled 562 MB download continues where it stopped.
    public func download(progress: @escaping @Sendable (Progress) -> Void = { _ in }) async throws {
        guard environment["WISPRIT_NO_NETWORK"] != "1" else {
            log.error("download refused: WISPRIT_NO_NETWORK=1")
            throw StoreError.networkDisabled
        }

        // A dir being (re-)downloaded must never carry a verified marker.
        try? FileManager.default.removeItem(at: markerURL)

        let total = manifest.reduce(0) { $0 + $1.bytes }
        var completed = 0
        for (index, file) in manifest.enumerated() {
            let destination = localURL(of: file)
            if FileManager.default.fileExists(atPath: destination.path),
               verify(file, at: destination) == nil {
                // Already byte-identical: skip the network entirely.
            } else {
                try await fetch(file, to: destination)
            }
            completed += file.bytes
            progress(Progress(file: file.localPath, fileIndex: index + 1,
                              fileCount: manifest.count,
                              completedBytes: completed, totalBytes: total))
        }

        // The marker asserts a FULL pass, so earn it with one.
        guard case .verified = state() else {
            throw StoreError.verificationFailed(
                path: modelsDir.path, reason: "post-download re-verification failed")
        }
        try writeMarker()
        log.info("parakeet models verified at \(self.modelsDir.path, privacy: .public)")
    }

    private func fetch(_ file: ParakeetManifestFile, to destination: URL) async throws {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Note: `main`, not a commit — HF model repos are routinely re-pushed
        // and their history pruned, so a commit pin would rot. The SHA-256
        // manifest below is the actual pin: a moved ref fails verification
        // and the bytes never reach a load call.
        let url = URL(string: "https://huggingface.co/\(file.repo)/resolve/main/\(file.path)")!
        let partial = destination.appendingPathExtension("download")
        try? FileManager.default.removeItem(at: partial)
        do {
            try await fetcher.fetch(url, to: partial)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw StoreError.fetchFailed(path: file.localPath, underlying: "\(error)")
        }
        if let reason = verify(file, at: partial) {
            try? FileManager.default.removeItem(at: partial)
            throw StoreError.verificationFailed(path: file.localPath, reason: reason)
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: partial, to: destination)
    }

    // MARK: - Verification

    /// nil when the file is byte-identical to the manifest; else the reason.
    private func verify(_ file: ParakeetManifestFile, at url: URL) -> String? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.intValue
        guard size == file.bytes else {
            return "size \(size.map(String.init) ?? "unreadable") != \(file.bytes)"
        }
        guard let digest = try? Self.sha256Hex(of: url) else { return "unreadable" }
        guard digest == file.sha256 else { return "sha256 mismatch" }
        return nil
    }

    static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 4 << 20) ?? Data()
            guard !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Marker (the doctor's path-checkable signal)

    public var markerURL: URL {
        modelsDir.appendingPathComponent(ParakeetManifest.markerFileName)
    }

    private func writeMarker() throws {
        let payload: [String: Any] = [
            "manifest_version": ParakeetManifest.version,
            "files": manifest.count,
            "bytes": manifest.reduce(0) { $0 + $1.bytes },
            "fluidaudio_revision": ParakeetInfo.fluidAudioRevision,
            "verified_at": ISO8601DateFormatter().string(from: Date()),
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        try data.write(to: markerURL, options: .atomic)
    }

    func localURL(of file: ParakeetManifestFile) -> URL {
        modelsDir.appendingPathComponent(file.localPath)
    }
}

/// The seam the tests inject a fake through; the real one below is the only
/// networking code in Wisprit.
public protocol ParakeetAssetFetching: Sendable {
    /// Stream `url` into `destination` (parent directory already exists),
    /// throwing on any failure. Must not leave a partial file on throw.
    func fetch(_ url: URL, to destination: URL) async throws
}

/// Plain GET via URLSession. No auth, no cookies, no telemetry — the URL names
/// a public model file and the caller verifies every byte against the manifest.
struct HuggingFaceAssetFetcher: ParakeetAssetFetching {
    struct HTTPError: Error { let status: Int }

    func fetch(_ url: URL, to destination: URL) async throws {
        let (temp, response) = try await URLSession.shared.download(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            try? FileManager.default.removeItem(at: temp)
            throw HTTPError(status: (response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temp, to: destination)
    }
}
