import Foundation

/// The `WispritIM.app` bundle's `Info.plist` and entitlements, generated from
/// one place.
///
/// `scripts/build_im.sh` does not hand-write the plist: it runs the built binary
/// with `--emit-info-plist`, which calls straight into here. So the keys the
/// tests pin are the keys that ship, and the sandbox connection-name rule cannot
/// drift between the code that opens the Mach service and the plist that names it.
public enum IMBundleTemplate {

    public struct Options: Sendable, Equatable {
        public var bundleID: String
        public var executableName: String
        public var displayName: String
        public var version: String
        public var shortVersion: String
        public var controllerClass: String
        public var principalClass: String
        public var inputSourceID: String
        public var inputModeID: String
        public var minimumSystemVersion: String
        /// `ComponentInvisibleInSystemUI` — keeps the palette out of the Input
        /// menu, exactly as `DictationIM.app` does. Without it the user sees a
        /// stray "Wisprit" entry in the menu bar's input-source picker.
        public var invisibleInSystemUI: Bool

        public init(bundleID: String = WispritIMNaming.bundleID,
                    executableName: String = "WispritIM",
                    displayName: String = "Wisprit Dictation",
                    version: String = "2.0.0-dev",
                    shortVersion: String = "2.0.0-dev",
                    controllerClass: String = "WispritInputController",
                    principalClass: String = "NSApplication",
                    inputSourceID: String = WispritIMNaming.inputSourceID,
                    inputModeID: String = WispritIMNaming.inputModeID,
                    minimumSystemVersion: String = "26.0",
                    invisibleInSystemUI: Bool = true) {
            self.bundleID = bundleID
            self.executableName = executableName
            self.displayName = displayName
            self.version = version
            self.shortVersion = shortVersion
            self.controllerClass = controllerClass
            self.principalClass = principalClass
            self.inputSourceID = inputSourceID
            self.inputModeID = inputModeID
            self.minimumSystemVersion = minimumSystemVersion
            self.invisibleInSystemUI = invisibleInSystemUI
        }
    }

    /// Keys that make this bundle an input method rather than an app.
    public enum Key {
        public static let type = "InputMethodType"
        public static let connectionName = "InputMethodConnectionName"
        public static let controllerClass = "InputMethodServerControllerClass"
        public static let sourceID = "TISInputSourceID"
        public static let invisible = "ComponentInvisibleInSystemUI"
        public static let inputModeDict = "ComponentInputModeDict"
        public static let modeList = "tsInputModeListKey"
        public static let visibleOrder = "tsVisibleInputModeOrderedArrayKey"
        public static let iconIsTemplate = "TISIconIsTemplate"
        public static let backgroundOnly = "LSBackgroundOnly"
        public static let uiElement = "NSUIElement"
    }

    /// `palette`, not `keyboard`: a palette input source never takes over the
    /// user's keyboard layout, and "zero or more of these can be selected"
    /// (TextInputSources.h) — which is what lets Wisprit ride alongside whatever
    /// layout the user actually types with. Verified on this machine: macOS
    /// Dictation is `InputMethodType = palette`.
    public static let inputMethodType = "palette"

    public static func plist(_ options: Options = Options()) -> String {
        let connection = WispritIMNaming.connectionName(forBundleID: options.bundleID)
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleName</key><string>\(options.executableName)</string>
            <key>CFBundleDisplayName</key><string>\(options.displayName)</string>
            <key>CFBundleIdentifier</key><string>\(options.bundleID)</string>
            <key>CFBundleExecutable</key><string>\(options.executableName)</string>
            <key>CFBundlePackageType</key><string>APPL</string>
            <key>CFBundleVersion</key><string>\(options.version)</string>
            <key>CFBundleShortVersionString</key><string>\(options.shortVersion)</string>
            <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
            <key>CFBundleDevelopmentRegion</key><string>en</string>
            <key>LSMinimumSystemVersion</key><string>\(options.minimumSystemVersion)</string>

            <!-- No Dock icon, no menu bar, no windows: this process exists only to
                 hold an IMKServer and write into the focused field. -->
            <key>\(Key.backgroundOnly)</key><true/>
            <key>\(Key.uiElement)</key><string>1</string>
            <key>NSPrincipalClass</key><string>\(options.principalClass)</string>

            <!-- Input method identity. -->
            <key>\(Key.type)</key><string>\(inputMethodType)</string>
            <key>\(Key.controllerClass)</key><string>\(options.controllerClass)</string>
            <!-- MUST be exactly <bundle id>_Connection: a sandboxed input method
                 fails to register its connection under any other name, and then
                 never receives a client at all. -->
            <key>\(Key.connectionName)</key><string>\(connection)</string>
            <key>\(Key.sourceID)</key><string>\(options.inputSourceID)</string>
            <key>\(Key.iconIsTemplate)</key><true/>
        \(options.invisibleInSystemUI ? "    <key>\(Key.invisible)</key><true/>\n" : "")\
            <!-- One invisible mode. Apple's own palette IMs omit this dict
                 entirely; third-party bundles registered via TISRegisterInputSource
                 are more reliable with a minimal one. -->
            <key>\(Key.inputModeDict)</key>
            <dict>
                <key>\(Key.modeList)</key>
                <dict>
                    <key>\(options.inputModeID)</key>
                    <dict>
                        <key>TISInputSourceID</key><string>\(options.inputModeID)</string>
                        <key>TISIntendedLanguage</key><string>en</string>
                        <key>tsInputModeAlternateKeyboardLayoutKey</key><string>com.apple.keylayout.US</string>
                        <key>tsInputModeIsVisibleKey</key><\(options.invisibleInSystemUI ? "false" : "true")/>
                        <key>tsInputModePrimaryInScriptKey</key><true/>
                        <key>tsInputModeScriptKey</key><string>smRoman</string>
                    </dict>
                </dict>
                <key>\(Key.visibleOrder)</key>
                <array/>
            </dict>
        </dict>
        </plist>
        """
    }

    /// Sandbox entitlements. An input method may be sandboxed (vChewing ships
    /// sandboxed) — the App Store block is Guideline 2.4.5, not the sandbox — and
    /// the sandbox is worth having in a process that can see every keystroke's
    /// worth of text. `mach-register.global-name` is what lets the sandboxed IM
    /// register Mach names at all: `<bundle id>_Connection` for `IMKServer`, and
    /// `<bundle id>.port` for the app's own channel.
    public static func entitlements(bundleID: String = WispritIMNaming.bundleID,
                                    sandboxed: Bool = true) -> String {
        let names = WispritIMNaming.registeredMachNames(forBundleID: bundleID)
            .map { "        <string>\($0)</string>" }
            .joined(separator: "\n")
        let lookups = WispritIMNaming.lookedUpMachNames
            .map { "        <string>\($0)</string>" }
            .joined(separator: "\n")
        guard sandboxed else {
            return """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>com.apple.security.app-sandbox</key><false/>
            </dict>
            </plist>
            """
        }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>com.apple.security.app-sandbox</key><true/>
            <!-- Both global Mach names this bundle registers: IMKServer's
                 InputMethodConnectionName, and the app-facing command port. -->
            <key>com.apple.security.temporary-exception.mach-register.global-name</key>
            <array>
        \(names)
            </array>
            <!-- Post events back to the main app's port. -->
            <key>com.apple.security.temporary-exception.mach-lookup.global-name</key>
            <array>
        \(lookups)
            </array>
            <!-- No network, ever. The dictation path makes zero network calls. -->
            <key>com.apple.security.network.client</key><false/>
            <key>com.apple.security.network.server</key><false/>
        </dict>
        </plist>
        """
    }

    // MARK: Validation

    /// Invariants a `WispritIM.app` Info.plist must satisfy. Used by the tests
    /// and by the app's doctor check against the *installed* bundle, which is
    /// how a half-updated install gets caught instead of silently never
    /// connecting.
    public static func violations(in plist: [String: Any]) -> [String] {
        var problems: [String] = []

        guard let bundleID = plist["CFBundleIdentifier"] as? String, !bundleID.isEmpty else {
            return ["CFBundleIdentifier is missing"]
        }

        let expectedConnection = WispritIMNaming.connectionName(forBundleID: bundleID)
        let connection = plist[Key.connectionName] as? String
        if connection != expectedConnection {
            problems.append("\(Key.connectionName) must be exactly \"\(expectedConnection)\" "
                            + "(found \(connection.map { "\"\($0)\"" } ?? "nothing")) — a sandboxed "
                            + "input method never registers under any other name")
        }

        if (plist[Key.type] as? String) != inputMethodType {
            problems.append("\(Key.type) must be \"\(inputMethodType)\" so the source never "
                            + "replaces the user's keyboard layout")
        }

        if (plist[Key.controllerClass] as? String)?.isEmpty ?? true {
            problems.append("\(Key.controllerClass) is missing — IMKServer would have no controller to make")
        }

        if (plist[Key.sourceID] as? String)?.isEmpty ?? true {
            problems.append("\(Key.sourceID) is missing")
        }

        if !truthy(plist[Key.backgroundOnly]) {
            problems.append("\(Key.backgroundOnly) must be true — the input method has no UI")
        }

        if plist[Key.inputModeDict] == nil {
            problems.append("\(Key.inputModeDict) is missing")
        }

        if plist["NSPrincipalClass"] == nil {
            problems.append("NSPrincipalClass is missing")
        }

        return problems
    }

    private static func truthy(_ value: Any?) -> Bool {
        switch value {
        case let bool as Bool: return bool
        case let number as NSNumber: return number.boolValue
        case let string as String: return string == "1" || string.lowercased() == "true"
        default: return false
        }
    }
}
