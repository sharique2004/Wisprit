import XCTest
import WispritIMProtocol
@testable import WispritIM

/// The bundle's Info.plist is load-bearing: get one string wrong and the input
/// method registers nothing, receives no client, and fails completely silently.
/// These tests pin the strings.
final class BundleTemplateTests: XCTestCase {

    private func parsed(_ options: IMBundleTemplate.Options = .init()) throws -> [String: Any] {
        let xml = IMBundleTemplate.plist(options)
        let object = try PropertyListSerialization.propertyList(
            from: Data(xml.utf8), options: [], format: nil)
        return try XCTUnwrap(object as? [String: Any])
    }

    func testTemplateIsValidPropertyList() throws {
        let plist = try parsed()
        XCTAssertEqual(plist["CFBundleIdentifier"] as? String, "com.wisprit.im")
        XCTAssertEqual(plist["CFBundleExecutable"] as? String, "WispritIM")
    }

    /// THE rule: a sandboxed input method registers its connection only under
    /// `$(PRODUCT_BUNDLE_IDENTIFIER)_Connection`.
    func testConnectionNameIsExactlyBundleIDPlusConnection() throws {
        let plist = try parsed()
        XCTAssertEqual(plist[IMBundleTemplate.Key.connectionName] as? String,
                       "com.wisprit.im_Connection")
        XCTAssertEqual(WispritIMNaming.connectionName(forBundleID: "com.example.thing"),
                       "com.example.thing_Connection")
    }

    func testConnectionNameRuleHoldsForAnyBundleID() throws {
        let plist = try parsed(.init(bundleID: "com.wisprit.im.beta"))
        XCTAssertEqual(plist[IMBundleTemplate.Key.connectionName] as? String,
                       "com.wisprit.im.beta_Connection")
        XCTAssertTrue(IMBundleTemplate.violations(in: plist).isEmpty)
    }

    /// IMKServer claims `<bundle id>_Connection` itself, so the app-facing port
    /// MUST be a different name — measured: a second listener on that name fails
    /// with `xpc_error=[37: Operation already in progress]`.
    func testTheAppPortIsNotTheIMKServerConnectionName() throws {
        let plist = try parsed()
        XCTAssertNotEqual(WispritIMNaming.machServiceName,
                          plist[IMBundleTemplate.Key.connectionName] as? String)
        XCTAssertEqual(WispritIMNaming.machServiceName, "com.wisprit.im.port")
        XCTAssertEqual(WispritIMNaming.eventPortName, "com.wisprit.app.im-events")
    }

    func testEveryNameTheBundleRegistersIsInTheSandboxException() throws {
        let entitlements = IMBundleTemplate.entitlements()
        for name in WispritIMNaming.registeredMachNames(forBundleID: "com.wisprit.im") {
            XCTAssertTrue(entitlements.contains(name), "\(name) must be registerable")
        }
        for name in WispritIMNaming.lookedUpMachNames {
            XCTAssertTrue(entitlements.contains(name), "\(name) must be lookupable")
        }
    }

    func testItIsAPaletteInputMethodSoItNeverReplacesTheKeyboardLayout() throws {
        let plist = try parsed()
        XCTAssertEqual(plist[IMBundleTemplate.Key.type] as? String, "palette")
    }

    func testItIsInvisibleAndHeadless() throws {
        let plist = try parsed()
        XCTAssertEqual(plist[IMBundleTemplate.Key.backgroundOnly] as? Bool, true)
        XCTAssertEqual(plist[IMBundleTemplate.Key.uiElement] as? String, "1")
        XCTAssertEqual(plist[IMBundleTemplate.Key.invisible] as? Bool, true,
                       "stays out of the Input menu, exactly as DictationIM does")
        XCTAssertEqual(plist[IMBundleTemplate.Key.iconIsTemplate] as? Bool, true)
    }

    func testControllerClassMatchesTheClassWeActuallyShip() throws {
        let plist = try parsed()
        XCTAssertEqual(plist[IMBundleTemplate.Key.controllerClass] as? String,
                       "WispritInputController")
        #if os(macOS)
        XCTAssertNotNil(NSClassFromString("WispritInputController"),
                        "IMKServer looks this class up by name at runtime")
        #endif
    }

    func testMinimalInputModeDictIsPresentAndInvisible() throws {
        let plist = try parsed()
        let modes = try XCTUnwrap(plist[IMBundleTemplate.Key.inputModeDict] as? [String: Any])
        let list = try XCTUnwrap(modes[IMBundleTemplate.Key.modeList] as? [String: Any])
        let mode = try XCTUnwrap(list["com.wisprit.im.dictation"] as? [String: Any])
        XCTAssertEqual(mode["TISInputSourceID"] as? String, "com.wisprit.im.dictation")
        XCTAssertEqual(mode["tsInputModeIsVisibleKey"] as? Bool, false)
        XCTAssertEqual((modes[IMBundleTemplate.Key.visibleOrder] as? [Any])?.count, 0)
    }

    func testVisibleVariantIsAvailableForTheManualSpike() throws {
        let plist = try parsed(.init(invisibleInSystemUI: false))
        XCTAssertNil(plist[IMBundleTemplate.Key.invisible])
        let modes = try XCTUnwrap(plist[IMBundleTemplate.Key.inputModeDict] as? [String: Any])
        let list = try XCTUnwrap(modes[IMBundleTemplate.Key.modeList] as? [String: Any])
        let mode = try XCTUnwrap(list["com.wisprit.im.dictation"] as? [String: Any])
        XCTAssertEqual(mode["tsInputModeIsVisibleKey"] as? Bool, true,
                       "the spike build must be selectable from the Input menu by hand")
    }

    // MARK: Validation

    func testAWrongConnectionNameIsCaught() throws {
        var plist = try parsed()
        plist[IMBundleTemplate.Key.connectionName] = "WispritIM_1_Connection"
        let problems = IMBundleTemplate.violations(in: plist)
        XCTAssertEqual(problems.count, 1)
        XCTAssertTrue(problems[0].contains("com.wisprit.im_Connection"))
    }

    func testAMissingConnectionNameIsCaught() throws {
        var plist = try parsed()
        plist.removeValue(forKey: IMBundleTemplate.Key.connectionName)
        XCTAssertFalse(IMBundleTemplate.violations(in: plist).isEmpty)
    }

    func testAKeyboardInputMethodIsCaught() throws {
        var plist = try parsed()
        plist[IMBundleTemplate.Key.type] = "keyboard"
        XCTAssertTrue(IMBundleTemplate.violations(in: plist)
            .contains { $0.contains("palette") })
    }

    func testTheShippedTemplateHasNoViolations() throws {
        XCTAssertEqual(IMBundleTemplate.violations(in: try parsed()), [])
    }

    // MARK: Entitlements

    func testSandboxEntitlementsRegisterExactlyTheConnectionName() throws {
        let xml = IMBundleTemplate.entitlements()
        let object = try PropertyListSerialization.propertyList(
            from: Data(xml.utf8), options: [], format: nil)
        let plist = try XCTUnwrap(object as? [String: Any])
        XCTAssertEqual(plist["com.apple.security.app-sandbox"] as? Bool, true)
        XCTAssertEqual(
            plist["com.apple.security.temporary-exception.mach-register.global-name"] as? [String],
            ["com.wisprit.im_Connection", "com.wisprit.im.port"])
        XCTAssertEqual(
            plist["com.apple.security.temporary-exception.mach-lookup.global-name"] as? [String],
            ["com.wisprit.app.im-events"])
    }

    func testTheInputMethodHasNoNetworkEntitlementsAtAll() throws {
        let xml = IMBundleTemplate.entitlements()
        let object = try PropertyListSerialization.propertyList(
            from: Data(xml.utf8), options: [], format: nil)
        let plist = try XCTUnwrap(object as? [String: Any])
        XCTAssertEqual(plist["com.apple.security.network.client"] as? Bool, false)
        XCTAssertEqual(plist["com.apple.security.network.server"] as? Bool, false)
    }

    // MARK: CLI

    func testCLIEmitsThePlistTheBuildScriptInstalls() {
        var output = ""
        let code = WispritIMEntry.run(["--emit-info-plist", "--version-string", "9.9.9"]) {
            output += $0
        }
        XCTAssertEqual(code, 0)
        XCTAssertTrue(output.contains("<string>9.9.9</string>"))
        XCTAssertTrue(output.contains("com.wisprit.im_Connection"))
    }

    func testCLIParsing() {
        XCTAssertEqual(WispritIMEntry.parse([]), .serve)
        XCTAssertEqual(WispritIMEntry.parse(["--status", "--json"]), .status(json: true))
        XCTAssertEqual(WispritIMEntry.parse(["--emit-entitlements", "--no-sandbox"]),
                       .emitEntitlements(bundleID: "com.wisprit.im", sandboxed: false))
        XCTAssertEqual(WispritIMEntry.parse(["--emit-info-plist", "--bundle-id", "com.x.y"]),
                       .emitInfoPlist(bundleID: "com.x.y", version: WispritIMEntry.defaultVersion))
        XCTAssertEqual(WispritIMEntry.parse(["--nope"]), .unknown("--nope"))
    }

    func testHelpNeverStartsAServer() {
        var output = ""
        XCTAssertEqual(WispritIMEntry.run(["--help"]) { output += $0 }, 0)
        XCTAssertTrue(output.contains("never enables or selects an input source"))
    }
}
