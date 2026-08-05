import Foundation
import Speech
import WispritKit

/// Doctor-style asset/availability preflight, in the shape `doctor.py` uses
/// (ok + a one-line human detail + a fix hint).
public struct AsrPreflight: Sendable, Equatable {
    public var ok: Bool
    public var detail: String
    public var fix: String?
    public var transcriberAvailable: Bool
    public var requestedLocale: String
    /// The installed locale actually matched (Speech normalizes en-US → en_US).
    public var matchedLocale: String?
    public var installedLocales: [String]
    /// `AssetInventory.status` — ADVISORY ONLY, see below.
    public var assetStatus: String
}

public enum AsrDoctor {
    /// Preflight the live engine for `locale`.
    ///
    /// Gotcha measured in spike S1 (probe q5): on a machine where transcription
    /// demonstrably works, `AssetInventory.status(forModules:)` returns
    /// `.supported`, NOT `.installed`. A check keyed on `.installed` reports a
    /// false failure. The real signals are `SpeechTranscriber.isAvailable`
    /// (false on <A14 iPhones and on the entire Simulator) plus membership of
    /// the requested locale in `installedLocales`; `status` is reported for
    /// diagnostics only.
    public static func check(locale requested: String) async -> AsrPreflight {
        let available = SpeechTranscriber.isAvailable
        let module = SpeechTranscriber(locale: Locale(identifier: requested),
                                       preset: .progressiveTranscription)
        let status = "\(await AssetInventory.status(forModules: [module]))"
        let installed = await SpeechTranscriber.installedLocales
        let installedIds = installed.map { $0.identifier }
        let matched = installed.first { matches($0.identifier, requested) }?.identifier

        if !available {
            return AsrPreflight(
                ok: false,
                detail: "SpeechTranscriber unavailable on this device",
                fix: "Needs a 16-core Neural Engine (iPhone 12 or later); always false on the Simulator. Set engine to a batch fallback.",
                transcriberAvailable: false, requestedLocale: requested,
                matchedLocale: matched, installedLocales: installedIds, assetStatus: status)
        }
        if matched == nil {
            return AsrPreflight(
                ok: false,
                detail: "speech model for \(requested) is not installed (installed: \(installedIds.joined(separator: ", ")))",
                fix: "Install it via AssetInventory.assetInstallationRequest(supporting:), or pick an installed locale.",
                transcriberAvailable: true, requestedLocale: requested,
                matchedLocale: nil, installedLocales: installedIds, assetStatus: status)
        }
        return AsrPreflight(
            ok: true,
            detail: "SpeechTranscriber ready for \(matched!)",
            fix: nil,
            transcriberAvailable: true, requestedLocale: requested,
            matchedLocale: matched, installedLocales: installedIds, assetStatus: status)
    }

    /// Download the assets for `locale` if the system offers a request for them.
    /// Returns false when nothing needed downloading or no request was offered.
    @discardableResult
    public static func installAssets(locale: String) async -> Bool {
        let module = SpeechTranscriber(locale: Locale(identifier: locale),
                                       preset: .progressiveTranscription)
        do {
            guard let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) else {
                return false
            }
            try await request.downloadAndInstall()
            return true
        } catch {
            WLog.logger("engine.doctor").error("asset install failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// "en-US" and "en_US" are the same locale as far as Speech is concerned.
    static func matches(_ installed: String, _ requested: String) -> Bool {
        func norm(_ s: String) -> String { s.replacingOccurrences(of: "-", with: "_").lowercased() }
        return norm(installed) == norm(requested)
    }
}
