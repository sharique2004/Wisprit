import CryptoKit
import XCTest
@testable import WispritParakeet

/// The store's logic — manifest verification, partial detection, layout, the
/// NO_NETWORK refusal — against an injected fake fetcher and a tiny fixture
/// manifest. No network, no models: the real 586 MB manifest is exercised only
/// by `ParakeetManifestTests` (shape) and the gated live test (bytes).
final class ParakeetModelStoreTests: XCTestCase {

    // MARK: - Fixtures

    /// Two tiny "repos" mirroring the real layout: one file nested like an
    /// .mlmodelc inner file, one at repo root.
    private let contents: [String: Data] = [
        "Encoder.mlmodelc/weights/weight.bin": Data("tdt-weights".utf8),
        "parakeet_vocab.json": Data("{\"0\":\"a\"}".utf8),
        "AudioEncoder.mlmodelc/weights/weight.bin": Data("ctc-weights".utf8),
        "tokenizer.json": Data("{\"model\":{}}".utf8),
    ]

    private func fixtureManifest() -> [ParakeetManifestFile] {
        func entry(_ repo: String, _ path: String) -> ParakeetManifestFile {
            let data = contents[path]!
            let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            return ParakeetManifestFile(repo: repo, path: path, bytes: data.count, sha256: sha)
        }
        return [
            entry(ParakeetManifest.tdtRepo, "Encoder.mlmodelc/weights/weight.bin"),
            entry(ParakeetManifest.tdtRepo, "parakeet_vocab.json"),
            entry(ParakeetManifest.ctcRepo, "AudioEncoder.mlmodelc/weights/weight.bin"),
            entry(ParakeetManifest.ctcRepo, "tokenizer.json"),
        ]
    }

    private final class FakeFetcher: ParakeetAssetFetching, @unchecked Sendable {
        let lock = NSLock()
        var byPath: [String: Data]          // HF repo path suffix → payload
        var fetched: [String] = []          // absolute URLs, in order
        struct MissingFixture: Error {}

        init(_ byPath: [String: Data]) { self.byPath = byPath }

        func fetch(_ url: URL, to destination: URL) async throws {
            lock.lock()
            fetched.append(url.absoluteString)
            // Anchored at the resolve segment: "Encoder.mlmodelc/…" must not
            // also serve "AudioEncoder.mlmodelc/…".
            let match = byPath.first {
                url.absoluteString.hasSuffix("/resolve/main/" + $0.key)
            }?.value
            lock.unlock()
            guard let match else { throw MissingFixture() }
            try match.write(to: destination)
        }
    }

    private func makeStore(fetcher: FakeFetcher? = nil,
                           environment: [String: String] = [:],
                           manifest: [ParakeetManifestFile]? = nil) throws
        -> (ParakeetModelStore, URL, FakeFetcher) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("parakeet-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let fake = fetcher ?? FakeFetcher(contents)
        let store = ParakeetModelStore(modelsDir: dir,
                                       manifest: manifest ?? fixtureManifest(),
                                       fetcher: fake,
                                       environment: environment)
        return (store, dir, fake)
    }

    private func plant(_ file: ParakeetManifestFile, in dir: URL,
                       bytes: Data? = nil) throws {
        let url = dir.appendingPathComponent(file.localPath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (bytes ?? contents[file.path]!).write(to: url)
    }

    // MARK: - State

    func testEmptyDirIsNotDownloaded() throws {
        let (store, _, _) = try makeStore()
        XCTAssertEqual(store.state(), .notDownloaded)
    }

    func testSomeFilesMissingIsPartialNamingThem() throws {
        let (store, dir, _) = try makeStore()
        let manifest = fixtureManifest()
        try plant(manifest[0], in: dir)
        try plant(manifest[1], in: dir)
        guard case .partial(let missing) = store.state() else {
            return XCTFail("expected partial, got \(store.state())")
        }
        XCTAssertEqual(Set(missing), [manifest[2].localPath, manifest[3].localPath])
    }

    func testHashMismatchIsPartialNotVerified() throws {
        let (store, dir, _) = try makeStore()
        for file in fixtureManifest() { try plant(file, in: dir) }
        // Same byte count, different bytes: only the SHA can catch it.
        let manifest = fixtureManifest()
        try plant(manifest[0], in: dir, bytes: Data("tdt-weightZ".utf8))
        guard case .partial(let missing) = store.state() else {
            return XCTFail("expected partial, got \(store.state())")
        }
        XCTAssertEqual(missing, [manifest[0].localPath])
    }

    func testAllFilesVerify() throws {
        let (store, dir, _) = try makeStore()
        for file in fixtureManifest() { try plant(file, in: dir) }
        XCTAssertEqual(store.state(), .verified)
    }

    // MARK: - Download

    func testDownloadFetchesVerifiesLaysOutAndWritesMarker() async throws {
        let (store, dir, fetcher) = try makeStore()
        try await store.download()

        XCTAssertEqual(store.state(), .verified)
        // Layout: each file under its repo's FluidAudio folder name.
        XCTAssertTrue(FileManager.default.fileExists(atPath:
            dir.appendingPathComponent("parakeet-tdt-0.6b-v3/Encoder.mlmodelc/weights/weight.bin").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath:
            dir.appendingPathComponent("parakeet-ctc-110m-coreml/tokenizer.json").path))
        // URLs: pinned resolve form against the two spike repos.
        XCTAssertEqual(fetcher.fetched.first,
                       "https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml/"
                       + "resolve/main/Encoder.mlmodelc/weights/weight.bin")
        XCTAssertTrue(fetcher.fetched.allSatisfy {
            $0.hasPrefix("https://huggingface.co/FluidInference/parakeet-")
                && $0.contains("/resolve/main/")
        })
        // Marker: present, versioned — the doctor's path-checkable signal.
        let marker = try JSONSerialization.jsonObject(
            with: Data(contentsOf: store.markerURL)) as? [String: Any]
        XCTAssertEqual(marker?["manifest_version"] as? Int, ParakeetManifest.version)
        XCTAssertEqual(marker?["fluidaudio_revision"] as? String,
                       ParakeetInfo.fluidAudioRevision)
    }

    func testDownloadSkipsFilesAlreadyVerified() async throws {
        let (store, dir, fetcher) = try makeStore()
        let manifest = fixtureManifest()
        try plant(manifest[0], in: dir)
        try plant(manifest[1], in: dir)
        try await store.download()
        XCTAssertEqual(store.state(), .verified)
        XCTAssertEqual(fetcher.fetched.count, 2, "verified files must not re-fetch")
        XCTAssertTrue(fetcher.fetched.allSatisfy { $0.contains("parakeet-ctc-110m") })
    }

    func testNoNetworkHardRefusesBeforeTouchingTheFetcher() async throws {
        let (store, _, fetcher) = try makeStore(environment: ["WISPRIT_NO_NETWORK": "1"])
        do {
            try await store.download()
            XCTFail("expected networkDisabled")
        } catch let error as ParakeetModelStore.StoreError {
            XCTAssertEqual(error, .networkDisabled)
        }
        XCTAssertTrue(fetcher.fetched.isEmpty, "the fetcher must never be asked")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.markerURL.path))
    }

    func testCorruptFetchFailsVerificationAndWritesNoMarker() async throws {
        var poisoned = contents
        poisoned["parakeet_vocab.json"] = Data("{\"0\":\"X\"}".utf8)  // same size, wrong bytes
        let (store, _, _) = try makeStore(fetcher: FakeFetcher(poisoned))
        do {
            try await store.download()
            XCTFail("expected verificationFailed")
        } catch let error as ParakeetModelStore.StoreError {
            guard case .verificationFailed(let path, _) = error else {
                return XCTFail("unexpected \(error)")
            }
            XCTAssertEqual(path, "parakeet-tdt-0.6b-v3/parakeet_vocab.json")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.markerURL.path))
        if case .verified = store.state() { XCTFail("corrupt set must not verify") }
    }

    func testRedownloadClearsAStaleMarkerFirst() async throws {
        let (store, _, _) = try makeStore()
        try await store.download()
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.markerURL.path))

        // Second store over the same dir with a fetcher that always fails: the
        // marker must be gone the moment a re-download starts, and the failed
        // run must not restore it — a dir being rewritten is not verified.
        var failing = contents
        failing["tokenizer.json"] = Data("{}".utf8)
        let brokenFetcher = FakeFetcher(failing)
        let broken = ParakeetModelStore(modelsDir: store.modelsDir,
                                        manifest: fixtureManifest(),
                                        fetcher: brokenFetcher,
                                        environment: [:])
        // Corrupt one file so download has something to re-fetch (badly).
        try Data("{}".utf8).write(
            to: store.modelsDir.appendingPathComponent("parakeet-ctc-110m-coreml/tokenizer.json"))
        do {
            try await broken.download()
            XCTFail("expected verificationFailed")
        } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.markerURL.path))
    }

    func testProgressReportsPerFileWithRunningByteTotals() async throws {
        let (store, _, _) = try makeStore()
        let recorded = Recorder()
        try await store.download { progress in recorded.append(progress) }
        let events = recorded.snapshot()

        let manifest = fixtureManifest()
        XCTAssertEqual(events.count, manifest.count)
        XCTAssertEqual(events.map(\.fileIndex), [1, 2, 3, 4])
        XCTAssertTrue(events.allSatisfy { $0.fileCount == manifest.count })
        XCTAssertEqual(events.map(\.file), manifest.map(\.localPath))
        let total = manifest.reduce(0) { $0 + $1.bytes }
        XCTAssertEqual(events.last?.completedBytes, total)
        XCTAssertTrue(events.allSatisfy { $0.totalBytes == total })
    }

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [ParakeetModelStore.Progress] = []
        func append(_ event: ParakeetModelStore.Progress) {
            lock.lock(); events.append(event); lock.unlock()
        }
        func snapshot() -> [ParakeetModelStore.Progress] {
            lock.lock(); defer { lock.unlock() }
            return events
        }
    }

    // MARK: - Doctor path convention

    /// The doctor mirrors these strings BY PATH in WispritMac (no import); if
    /// either side moves, this is the test that names the drift.
    func testDoctorPathConventionMatchesTheStore() {
        XCTAssertTrue(ParakeetModelStore.productionModelsDir.path
            .hasSuffix(".wisprit/models/parakeet"))
        XCTAssertEqual(ParakeetManifest.markerFileName, "verified.json")
    }
}
