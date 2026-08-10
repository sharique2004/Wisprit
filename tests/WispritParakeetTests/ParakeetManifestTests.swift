import XCTest
@testable import WispritParakeet

/// Shape checks over the real 33-file manifest. The bytes themselves are
/// exercised by the gated live test; here we pin the properties everything
/// else relies on — layout, hash format, and the spike's footprint numbers.
final class ParakeetManifestTests: XCTestCase {

    func testManifestCoversBothRepos() {
        let repos = Set(ParakeetManifest.files.map(\.repo))
        XCTAssertEqual(repos, [ParakeetManifest.tdtRepo, ParakeetManifest.ctcRepo])
        XCTAssertEqual(ParakeetManifest.files.count, 33)
    }

    func testEveryEntryHasAWellFormedHashAndPositiveSize() {
        for file in ParakeetManifest.files {
            XCTAssertEqual(file.sha256.count, 64, file.path)
            XCTAssertTrue(file.sha256.allSatisfy(\.isHexDigit), file.path)
            XCTAssertEqual(file.sha256, file.sha256.lowercased(), file.path)
            XCTAssertGreaterThan(file.bytes, 0, file.path)
        }
    }

    func testLocalPathsAreUniqueAndUnderTheTwoDirectories() {
        let locals = ParakeetManifest.files.map(\.localPath)
        XCTAssertEqual(Set(locals).count, locals.count, "duplicate local path")
        for path in locals {
            XCTAssertTrue(path.hasPrefix(ParakeetManifest.tdtDirectory + "/")
                          || path.hasPrefix(ParakeetManifest.ctcDirectory + "/"), path)
            XCTAssertFalse(path.contains(".."), path)
        }
    }

    /// The spike's Q4 budget: ≈562 MiB for int8 + boosting. If this drifts the
    /// manifest no longer describes that measured asset set.
    func testTotalMatchesTheSpikeFootprint() {
        let mib = Double(ParakeetManifest.totalBytes) / 1_048_576.0
        XCTAssertEqual(mib, 559.0, accuracy: 6.0)
    }

    /// The int8 verdict is load-bearing (int4 audibly loses the words Wisprit
    /// cares about): the manifest must ship Encoder.mlmodelc, never the int4 one.
    func testInt8EncoderIsPinnedAndInt4IsAbsent() {
        let paths = ParakeetManifest.files.map(\.path)
        XCTAssertTrue(paths.contains("Encoder.mlmodelc/weights/weight.bin"))
        XCTAssertFalse(paths.contains { $0.hasPrefix("EncoderInt4") })
    }

    /// Every file FluidAudio's manual load path reads must be present:
    /// `AsrModels.load` (v3 int8), `CtcModels.loadDirect`, `CtcTokenizer.load`.
    func testLoadBearingFilesArePresent() {
        let paths = Set(ParakeetManifest.files.map(\.localPath))
        for required in [
            "parakeet-tdt-0.6b-v3/Preprocessor.mlmodelc/coremldata.bin",
            "parakeet-tdt-0.6b-v3/Decoder.mlmodelc/coremldata.bin",
            "parakeet-tdt-0.6b-v3/JointDecisionv3.mlmodelc/coremldata.bin",
            "parakeet-tdt-0.6b-v3/parakeet_vocab.json",
            "parakeet-ctc-110m-coreml/MelSpectrogram.mlmodelc/coremldata.bin",
            "parakeet-ctc-110m-coreml/AudioEncoder.mlmodelc/coremldata.bin",
            "parakeet-ctc-110m-coreml/vocab.json",
            "parakeet-ctc-110m-coreml/tokenizer.json",
        ] {
            XCTAssertTrue(paths.contains(required), required)
        }
    }
}
