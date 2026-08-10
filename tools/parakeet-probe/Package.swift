// swift-tools-version: 6.0
// Parakeet B-0 gating spike probe (Wisprit accuracy-parity plan, Phase 6).
//
// STANDALONE — lives in scratch space, never in the Wisprit repo. Pins
// FluidAudio to the SAME revision MeetingScribe's diarization A/B validated
// (native/fluiddiarizer/Package.swift), so the numbers transfer.
//
// tools-version must be >= 6.0: this machine's CLT (Swift 6.3.3, no Xcode)
// ships a ManifestAPI that no longer links 5.x manifests.
import PackageDescription

let package = Package(
    name: "ParakeetSpike",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(
            url: "https://github.com/FluidInference/FluidAudio.git",
            revision: "5390df9752c8fc583596018360c5fd70d6fa6c75"
        )
    ],
    targets: [
        .executableTarget(
            name: "parakeet-probe",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio")
            ]
        )
    ],
    swiftLanguageVersions: [.v5]
)
