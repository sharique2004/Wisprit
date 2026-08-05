import Foundation

#if os(macOS)
import Carbon

/// READ-ONLY inspection of the input-source database.
///
/// This file calls `TISCreateInputSourceList` and nothing else. It never
/// registers, enables, selects or deselects anything — those are the app's
/// onboarding decisions, planned purely in `WispritIMProtocol.IMOnboarding` and
/// executed by the app with the user watching. Reading is safe from anywhere,
/// including `--status` on a developer's machine.
public enum InputSourceProbe {

    public static func status(sourceID: String = WispritIMNaming.inputSourceID,
                              layout: IMInstallLayout = .user,
                              stagedVersion: String? = nil) -> InputMethodStatus {
        let installed = layout.installedBundle
        // Under the sandbox the file check reads false even when the bundle is
        // right there — but if this process IS that bundle, we have our answer.
        let bundleInstalled = FileManager.default.fileExists(atPath: installed.path)
            || Bundle.main.bundleURL.standardizedFileURL == installed.standardizedFileURL

        var status = InputMethodStatus(
            bundleInstalled: bundleInstalled,
            registered: false,
            enabled: false,
            selected: false,
            installedVersion: bundleInstalled ? version(ofBundleAt: installed) : nil,
            stagedVersion: stagedVersion)

        guard let source = source(withID: sourceID) else { return status }
        status.registered = true
        status.enabled = boolProperty(source, kTISPropertyInputSourceIsEnabled)
        status.selected = boolProperty(source, kTISPropertyInputSourceIsSelected)
        return status
    }

    /// The installed bundle's Info.plist, for the doctor check that the
    /// connection-name rule survived the install.
    public static func installedInfoPlist(layout: IMInstallLayout = .user) -> [String: Any]? {
        let plist = layout.installedBundle.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil)
        else { return nil }
        return object as? [String: Any]
    }

    private static func source(withID id: String) -> TISInputSource? {
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource]
        else { return nil }
        return list.first
    }

    private static func boolProperty(_ source: TISInputSource, _ key: CFString) -> Bool {
        guard let raw = TISGetInputSourceProperty(source, key) else { return false }
        return unsafeBitCast(raw, to: CFBoolean.self) == kCFBooleanTrue
    }

    private static func version(ofBundleAt url: URL) -> String? {
        let plist = url.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = object as? [String: Any]
        else { return nil }
        return dict["CFBundleVersion"] as? String
    }
}

extension InputMethodStatus {
    /// JSON the main app's doctor can shell out for:
    /// `~/Library/Input\ Methods/WispritIM.app/Contents/MacOS/WispritIM --status --json`
    public var jsonLine: String {
        func quote(_ value: String?) -> String { value.map { "\"\($0)\"" } ?? "null" }
        return "{"
            + "\"bundle_installed\":\(bundleInstalled),"
            + "\"registered\":\(registered),"
            + "\"enabled\":\(enabled),"
            + "\"selected\":\(selected),"
            + "\"installed_version\":\(quote(installedVersion)),"
            + "\"staged_version\":\(quote(stagedVersion))"
            + "}"
    }
}
#endif
