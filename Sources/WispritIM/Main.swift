import Foundation
import WispritIMProtocol

#if os(macOS)
import AppKit
import InputMethodKit
#endif

/// Entry point for `WispritIM.app`.
///
/// Normally it is launched by the Text Services Manager when the palette input
/// source is selected, and it does one thing: hold an `IMKServer` and a Mach
/// service so `Wisprit.app` can stream text into whatever the user is typing in.
///
/// The flags exist so the bundle is built from one source of truth:
/// `scripts/build_im.sh` asks the binary for its own Info.plist and entitlements
/// instead of duplicating them in shell, and `--status` gives the app's doctor a
/// read-only view of the input-source database.
public enum WispritIMEntry {

    public enum Command: Equatable {
        case serve
        case emitInfoPlist(bundleID: String, version: String)
        case emitEntitlements(bundleID: String, sandboxed: Bool)
        case status(json: Bool)
        /// Time from `exec` to "ready for a client", then exit. This is the
        /// cold-start tax an enabled-but-unselected palette input method pays on
        /// the first Fn-down, minus whatever TSM adds on top.
        case measureLaunch
        case version
        case help
        case unknown(String)
    }

    /// Pure argument parsing, so the CLI surface is testable without launching
    /// an input method server.
    public static func parse(_ arguments: [String]) -> Command {
        var bundleID = WispritIMNaming.bundleID
        var version = defaultVersion
        var json = false
        var sandboxed = true
        var verb: String?
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--bundle-id":
                index += 1
                if index < arguments.count { bundleID = arguments[index] }
            case "--version-string":
                index += 1
                if index < arguments.count { version = arguments[index] }
            case "--json":
                json = true
            case "--no-sandbox":
                sandboxed = false
            case "--emit-info-plist", "--emit-entitlements", "--status", "--serve",
                 "--measure-launch", "--version", "-h", "--help":
                verb = argument
            default:
                if argument.hasPrefix("-") { return .unknown(argument) }
            }
            index += 1
        }

        switch verb {
        case "--emit-info-plist": return .emitInfoPlist(bundleID: bundleID, version: version)
        case "--emit-entitlements": return .emitEntitlements(bundleID: bundleID, sandboxed: sandboxed)
        case "--status": return .status(json: json)
        case "--measure-launch": return .measureLaunch
        case "--version": return .version
        case "-h", "--help": return .help
        default: return .serve
        }
    }

    public static let defaultVersion = "2.0.0-dev"

    public static let usage = """
    WispritIM — Wisprit's palette input method (live in-field dictation).

      WispritIM                       run the input method server (TSM launches this)
      WispritIM --emit-info-plist     print the bundle's Info.plist
      WispritIM --emit-entitlements   print the sandbox entitlements
      WispritIM --status [--json]     report install / enabled / selected state (read-only)
      WispritIM --measure-launch      time exec → ready-for-a-client, then exit
      WispritIM --version             print the wire version and build version

    Options: --bundle-id ID   --version-string V   --no-sandbox

    This binary never enables or selects an input source. Wisprit.app does that,
    once, during onboarding, with your permission.
    """

    /// Returns the process exit code. `serve` never returns on macOS.
    @discardableResult
    public static func run(_ arguments: [String], emit: (String) -> Void = { print($0) }) -> Int32 {
        switch parse(arguments) {
        case .help:
            emit(usage)
            return 0
        case .version:
            emit("WispritIM \(defaultVersion) (wire v\(WispritIMWire.version))")
            return 0
        case .emitInfoPlist(let bundleID, let version):
            let options = IMBundleTemplate.Options(bundleID: bundleID,
                                                   version: version,
                                                   shortVersion: version)
            emit(IMBundleTemplate.plist(options))
            return 0
        case .emitEntitlements(let bundleID, let sandboxed):
            emit(IMBundleTemplate.entitlements(bundleID: bundleID, sandboxed: sandboxed))
            return 0
        case .status(let json):
            return reportStatus(json: json, emit: emit)
        case .measureLaunch:
            return measureLaunch(emit: emit)
        case .unknown(let flag):
            emit("unknown flag: \(flag)\n\n\(usage)")
            return 2
        case .serve:
            return serve(emit: emit)
        }
    }

    #if os(macOS)
    private static var server: IMKServer?

    private static func reportStatus(json: Bool, emit: (String) -> Void) -> Int32 {
        let status = InputSourceProbe.status(stagedVersion: defaultVersion)
        if json {
            emit(status.jsonLine)
            return status.enabled ? 0 : 1
        }
        let verdict = IMPreflight.evaluate(status)
        if IMInstallLayout.isSandboxed {
            emit("note             : sandboxed — file checks under ~/Library/Input Methods "
                 + "read false from here; the registered/enabled/selected lines are still true")
        }
        emit("bundle installed : \(status.bundleInstalled)")
        emit("registered       : \(status.registered)")
        emit("enabled          : \(status.enabled)")
        emit("selected         : \(status.selected)")
        emit("verdict          : \(verdict)")
        emit("remedy           : \(IMPreflight.remedy(for: verdict))")
        if let plist = InputSourceProbe.installedInfoPlist() {
            let problems = IMBundleTemplate.violations(in: plist)
            emit("installed plist  : \(problems.isEmpty ? "ok" : problems.joined(separator: "; "))")
        }
        return verdict.isUsable ? 0 : 1
    }

    /// How long does the cold start actually cost?
    ///
    /// An enabled-but-unselected palette input method is NOT a resident process
    /// (verification V8), so the first Fn-down of a session pays a process
    /// launch. This measures everything that launch involves — exec, dyld,
    /// InputMethodKit, IMKServer, the Mach service — from the kernel's own record
    /// of when the process started, so nothing is missed.
    ///
    /// It does not include TSM's own select→activateServer round trip, which
    /// needs the input method installed and is part of spike S2.
    private static func measureLaunch(emit: (String) -> Void) -> Int32 {
        let started = processStartDate()
        let bundleID = Bundle.main.bundleIdentifier ?? WispritIMNaming.bundleID
        let connectionName = WispritIMNaming.connectionName(forBundleID: bundleID)

        let beforeServer = Date()
        server = IMKServer(name: connectionName, bundleIdentifier: bundleID)
        let afterServer = Date()
        IMService.shared.start(machServiceName: WispritIMNaming.serviceName(forBundleID: bundleID))
        let ready = Date()

        func ms(_ interval: TimeInterval) -> String { String(format: "%.1f", interval * 1000) }
        emit("{"
             + "\"exec_to_main_ms\":\(ms(beforeServer.timeIntervalSince(started))),"
             + "\"imkserver_ms\":\(ms(afterServer.timeIntervalSince(beforeServer))),"
             + "\"listener_ms\":\(ms(ready.timeIntervalSince(afterServer))),"
             + "\"total_ms\":\(ms(ready.timeIntervalSince(started)))"
             + "}")
        return 0
    }

    /// The kernel's record of when this process was exec'd.
    private static func processStartDate() -> Date {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0 else {
            return Date()
        }
        let started = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: Double(started.tv_sec) + Double(started.tv_usec) / 1e6)
    }

    private static func serve(emit: (String) -> Void) -> Int32 {
        let bundleID = Bundle.main.bundleIdentifier ?? WispritIMNaming.bundleID
        let connectionName = Bundle.main.object(forInfoDictionaryKey: IMBundleTemplate.Key.connectionName)
            as? String ?? WispritIMNaming.connectionName(forBundleID: bundleID)

        // If these two ever disagree, a sandboxed build registers no connection
        // and then silently never receives a client. Fail loudly instead.
        let expected = WispritIMNaming.connectionName(forBundleID: bundleID)
        if connectionName != expected {
            emit("FATAL: InputMethodConnectionName is \"\(connectionName)\" but must be \"\(expected)\"")
            return 78  // EX_CONFIG
        }

        // IMKServer owns `connectionName`; the app's channel gets its own name.
        server = IMKServer(name: connectionName, bundleIdentifier: bundleID)
        IMService.shared.start(machServiceName: WispritIMNaming.serviceName(forBundleID: bundleID))
        NSApplication.shared.run()
        return 0
    }
    #else
    private static func reportStatus(json: Bool, emit: (String) -> Void) -> Int32 {
        emit("WispritIM runs on macOS only.")
        return 1
    }

    private static func serve(emit: (String) -> Void) -> Int32 {
        emit("WispritIM runs on macOS only.")
        return 1
    }

    private static func measureLaunch(emit: (String) -> Void) -> Int32 {
        emit("WispritIM runs on macOS only.")
        return 1
    }
    #endif
}

@main
enum WispritIMMain {
    static func main() {
        let code = WispritIMEntry.run(Array(CommandLine.arguments.dropFirst()))
        if code != 0 { exit(code) }
    }
}
