import Foundation

/// The pinned Parakeet asset set: TDT v3 int8 (decode) + CTC 110m (vocabulary
/// spotting), exactly the files `AsrModels.load(version: .v3, encoderPrecision:
/// .int8)` + `CtcModels.loadDirect` + `CtcTokenizer.load(from:)` touch and not
/// one more. int4 was measured and rejected (spikes-parakeet.md Q4: it loses
/// exactly the words Wisprit cares about for 141 MB).
///
/// **The SHA-256 manifest IS the pin.** HuggingFace model repos move their
/// `main` ref; a `resolve/main` URL alone would not be a pin. Every downloaded
/// byte is verified against these hashes before anything else may happen, so a
/// moved ref fails closed — the store reports `.partial` and no FluidAudio load
/// call is ever reached. Hashes were recorded from the spike's validated caches
/// (docs/research/spikes-parakeet.md, the set the B-0 measurements ran on).
public struct ParakeetManifestFile: Sendable, Equatable {
    /// HuggingFace repo, e.g. "FluidInference/parakeet-tdt-0.6b-v3-coreml".
    public let repo: String
    /// Path within the repo (and within its local directory), e.g.
    /// "Encoder.mlmodelc/weights/weight.bin".
    public let path: String
    public let bytes: Int
    public let sha256: String

    public init(repo: String, path: String, bytes: Int, sha256: String) {
        self.repo = repo
        self.path = path
        self.bytes = bytes
        self.sha256 = sha256
    }

    /// Where the file lives under the models dir. The directory names are
    /// FluidAudio's `Repo.folderName` values — `AsrModels.load` re-derives the
    /// repo directory from them, so they are contract, not taste.
    public var localPath: String {
        (repo == ParakeetManifest.tdtRepo
            ? ParakeetManifest.tdtDirectory
            : ParakeetManifest.ctcDirectory) + "/" + path
    }
}

/// Everything about the on-disk layout that WispritMac's doctor mirrors BY PATH
/// (deliberately without importing this target): the models dir is
/// `~/.wisprit/models/parakeet`, its two subdirectories are named below, and a
/// `verified.json` marker (written only after a full-manifest hash pass) is the
/// cheap "downloaded and verified" signal. See `Doctor.parakeetModelsLabel`.
public enum ParakeetManifest {
    /// Bumped when the asset set changes; recorded in the version marker so a
    /// stale download is distinguishable from a verified one.
    public static let version = 1

    public static let tdtRepo = "FluidInference/parakeet-tdt-0.6b-v3-coreml"
    public static let ctcRepo = "FluidInference/parakeet-ctc-110m-coreml"

    /// `Repo.parakeetV3.folderName` — the name `AsrModels.load` resolves.
    public static let tdtDirectory = "parakeet-tdt-0.6b-v3"
    /// `Repo.parakeetCtc110m.folderName` — the name `CtcModels` resolves.
    public static let ctcDirectory = "parakeet-ctc-110m-coreml"

    /// Written by `ParakeetModelStore.download` after every file re-verified;
    /// checked by path in `Doctor.parakeetModelsState` (DoctorProbes.swift).
    public static let markerFileName = "verified.json"

    public static var totalBytes: Int { files.reduce(0) { $0 + $1.bytes } }

    public static let files: [ParakeetManifestFile] = {
        let tdt = tdtRepo
        let ctc = ctcRepo
        return [
        // --- TDT v3, int8 encoder (decode) ---------------------------------
        .init(repo: tdt, path: "Preprocessor.mlmodelc/coremldata.bin", bytes: 486,
              sha256: "dbde3f2300842c1fd51ef3ff948a0bcffe65ffd2dca10707f2509f32c1d65b1d"),
        .init(repo: tdt, path: "Preprocessor.mlmodelc/metadata.json", bytes: 2841,
              sha256: "2a98699e22d279dd37fa1d238aeb1c6db1df0d6fad687775324157689d8f3acf"),
        .init(repo: tdt, path: "Preprocessor.mlmodelc/model.mil", bytes: 28181,
              sha256: "4b8518a956450fec57f06c2a21bdffc26973f7f1fa6842fb38fe917f896b6b93"),
        .init(repo: tdt, path: "Preprocessor.mlmodelc/weights/weight.bin", bytes: 491072,
              sha256: "129b76e3aeafa8afa3ea76d995b964b145fe83700d579f6ff42c4c38fa0968ea"),
        .init(repo: tdt, path: "Preprocessor.mlmodelc/analytics/coremldata.bin", bytes: 243,
              sha256: "c9beeb989c8d66f8be11df59bc6df277ec76cee404f6865b46243835ef562f6d"),
        .init(repo: tdt, path: "Encoder.mlmodelc/coremldata.bin", bytes: 485,
              sha256: "d48034a167a82e88fc3df64f60af963ab3983538271175b8319e7d5720a0fb86"),
        .init(repo: tdt, path: "Encoder.mlmodelc/metadata.json", bytes: 2921,
              sha256: "da24da9cca943fb29d7fa8e376d57fca7cb3aa08ca51b956b0b0e56813f087e9"),
        .init(repo: tdt, path: "Encoder.mlmodelc/model.mil", bytes: 959769,
              sha256: "ed7b19156ca29fa7dfd6891deb9fda4b0e8893f68597c985d135736546a43808"),
        .init(repo: tdt, path: "Encoder.mlmodelc/weights/weight.bin", bytes: 445_187_200,
              sha256: "e2020f323703477a5b21d7c2d282c403e371afb5962e79877e3033e73ba6f421"),
        .init(repo: tdt, path: "Encoder.mlmodelc/analytics/coremldata.bin", bytes: 243,
              sha256: "42e638870d73f26b332918a3496ce36793fbb413a81cbd3d16ba01328637a105"),
        .init(repo: tdt, path: "Decoder.mlmodelc/coremldata.bin", bytes: 554,
              sha256: "18647af085d87bd8f3121c8a9b4d4564c1ede038dab63d295b4e745cf2d7fb99"),
        .init(repo: tdt, path: "Decoder.mlmodelc/metadata.json", bytes: 3427,
              sha256: "a39e93cd8371b8ded92635c7804fcd0590f0d1dd9415c6d19a0484be073077d9"),
        .init(repo: tdt, path: "Decoder.mlmodelc/model.mil", bytes: 13110,
              sha256: "ef2a0a281695398a62fde86ac269c68f73d5b578d7ed3b31f2ba91a2d1ea1f35"),
        .init(repo: tdt, path: "Decoder.mlmodelc/weights/weight.bin", bytes: 23_604_992,
              sha256: "48adf0f0d47c406c8253d4f7fef967436a39da14f5a65e66d5a4b407be355d41"),
        .init(repo: tdt, path: "Decoder.mlmodelc/analytics/coremldata.bin", bytes: 243,
              sha256: "4238c4e81ecd0dc94bd7dfbb60f7e2cc824107c1ffe0387b8607b72833dba350"),
        .init(repo: tdt, path: "JointDecisionv3.mlmodelc/coremldata.bin", bytes: 521,
              sha256: "f5fc08b741400f0088492c9e839418b1e18522f19cba28d361dd030c5f398342"),
        .init(repo: tdt, path: "JointDecisionv3.mlmodelc/metadata.json", bytes: 3453,
              sha256: "d9307211b9a37e0f0ac260c7660b1571a3de25841035cfdf9b58fd40425f890f"),
        .init(repo: tdt, path: "JointDecisionv3.mlmodelc/model.mil", bytes: 11775,
              sha256: "be60732943389a047175111a83f8839f3eb39d4803adafa828a0871b2f39818d"),
        .init(repo: tdt, path: "JointDecisionv3.mlmodelc/weights/weight.bin", bytes: 12_642_764,
              sha256: "4e0e63d840032f7f07ddb1d64446051166281e5491bf22da8a945c41f6eedb3e"),
        .init(repo: tdt, path: "JointDecisionv3.mlmodelc/analytics/coremldata.bin", bytes: 243,
              sha256: "26def4bf73dd56d29dee21c8ef97cb8969e62f6120ed1adc91e46828e2737b6c"),
        .init(repo: tdt, path: "parakeet_vocab.json", bytes: 151_122,
              sha256: "7ec60e05f1b24480736ec0eed40900f4626bce1fa9a60fd700ec7e2a59198735"),
        // --- CTC 110m (vocabulary spotting + tokenizer) --------------------
        .init(repo: ctc, path: "MelSpectrogram.mlmodelc/coremldata.bin", bytes: 330,
              sha256: "3a32ec67c76aa0aa2faef518413c311493e89aeb7fa11289fa4b8653ab8a160c"),
        .init(repo: ctc, path: "MelSpectrogram.mlmodelc/metadata.json", bytes: 1962,
              sha256: "5e11d21a65c02bcfc37db43e941978e5d60d59e0efeadfda08e41f33b4f835d3"),
        .init(repo: ctc, path: "MelSpectrogram.mlmodelc/model.mil", bytes: 12584,
              sha256: "0a7cb5693b39667295218bac5c7c09053f6bcd4b32699a83d06ac35d14ac6b79"),
        .init(repo: ctc, path: "MelSpectrogram.mlmodelc/weights/weight.bin", bytes: 567_712,
              sha256: "0a89c055bfde9022029d3cc59a23e949385e063974460d8eaec3a7614c3eaaa8"),
        .init(repo: ctc, path: "MelSpectrogram.mlmodelc/analytics/coremldata.bin", bytes: 243,
              sha256: "22f2a8cba1de25c984050566b534a1d8caf22a82f9fe6c1c6f3149a0dd7e8ae3"),
        .init(repo: ctc, path: "AudioEncoder.mlmodelc/coremldata.bin", bytes: 505,
              sha256: "a88b002b58193b4c31211754cdfdf220a85f9651dc61caf336ab84400cbc191a"),
        .init(repo: ctc, path: "AudioEncoder.mlmodelc/metadata.json", bytes: 3456,
              sha256: "4f288bfe5cbe867ef1e592cdae33578b2fe59ada69182fc12209879558f985c2"),
        .init(repo: ctc, path: "AudioEncoder.mlmodelc/model.mil", bytes: 1_060_924,
              sha256: "2f84ef93a69115e55f3b5d8ce695b3c937de1833d4d229620634fae967cd587e"),
        .init(repo: ctc, path: "AudioEncoder.mlmodelc/weights/weight.bin", bytes: 100_778_304,
              sha256: "af0734b4a5d7465ad9e8bb170f0c53c5e6b91ebb75a9bdf88d3f59ae4ad6aebd"),
        .init(repo: ctc, path: "AudioEncoder.mlmodelc/analytics/coremldata.bin", bytes: 243,
              sha256: "8906c823e9bb3bf6b16d9f0308f98cd70573526333ad85dd767dc3f9ae6b25fa"),
        .init(repo: ctc, path: "vocab.json", bytes: 16086,
              sha256: "319d386eead79aadc80df9c3ecc8340d1a727efb7c02a8847eb940380dd61e1f"),
        .init(repo: ctc, path: "tokenizer.json", bytes: 360_106,
              sha256: "9f7c517c0bf644b1b690ab037bab4d4c53aecd38e047e7154d011013ab9160db"),
        ]
    }()
}

/// The store's answer to "may FluidAudio be loaded?". Everything except
/// `.verified` means NO load call is made — that is what keeps `AsrModels.load`'s
/// silent ModelHub fallback (spikes-parakeet.md, API reality §) unreachable.
public enum ParakeetModelState: Sendable, Equatable {
    case notDownloaded
    /// Some manifest files are absent or fail their hash. The list names the
    /// offending manifest-relative paths, for logs and the doctor's remedy.
    case partial(missing: [String])
    case verified
}
