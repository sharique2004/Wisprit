import Foundation

/// The transport object for the wire types.
///
/// The pipe wants bytes, the payloads want `Codable`, and mixing the two by hand
/// is how protocol drift starts. So there is exactly one
/// transport object: an immutable envelope that carries a wire version, a kind
/// tag and the JSON of the `Codable` message. Adding a case to `IMCommand` can
/// never desync the archiver, and an old build meeting a new payload sees a
/// version it does not support instead of a half-decoded struct.
public final class WispritIMPayload: NSObject, NSSecureCoding, @unchecked Sendable {
    /// Which conversation the bytes belong to. A receiver that does not know a
    /// kind fails to decode the archive at all (`init?(coder:)` returns nil), so
    /// a v1 input method meeting a v2 read does nothing whatsoever — which is
    /// precisely the degradation the read channel wants.
    public enum Kind: String, Sendable {
        /// app → IM, wire v1: writes into the field.
        case command
        /// IM → app, wire v1: what happened to the field.
        case event
        /// app → IM, wire v2: read-only questions (`IMRead`).
        case read
        /// IM → app, wire v2: the answers (`IMSnapshot`).
        case snapshot
    }

    private enum Key {
        static let version = "wireVersion"
        static let kind = "kind"
        static let json = "json"
    }

    public let wireVersion: Int
    public let kind: Kind
    public let json: Data

    public init(wireVersion: Int, kind: Kind, json: Data) {
        self.wireVersion = wireVersion
        self.kind = kind
        self.json = json
    }

    // MARK: Encoding helpers

    public convenience init(command: IMCommandMessage) throws {
        self.init(wireVersion: command.wireVersion,
                  kind: .command,
                  json: try WispritIMPayload.encoder.encode(command))
    }

    public convenience init(event: IMEventMessage) throws {
        self.init(wireVersion: event.wireVersion,
                  kind: .event,
                  json: try WispritIMPayload.encoder.encode(event))
    }

    public convenience init(read: IMReadMessage) throws {
        self.init(wireVersion: read.wireVersion,
                  kind: .read,
                  json: try WispritIMPayload.encoder.encode(read))
    }

    public convenience init(snapshot: IMSnapshotMessage) throws {
        self.init(wireVersion: snapshot.wireVersion,
                  kind: .snapshot,
                  json: try WispritIMPayload.encoder.encode(snapshot))
    }

    public enum DecodeError: Error, Equatable {
        case unsupportedVersion(Int)
        case wrongKind(expected: String, got: String)
        case malformed(String)
    }

    public func command() throws -> IMCommandMessage {
        try decode(IMCommandMessage.self, kind: .command)
    }

    public func event() throws -> IMEventMessage {
        try decode(IMEventMessage.self, kind: .event)
    }

    public func read() throws -> IMReadMessage {
        try decode(IMReadMessage.self, kind: .read)
    }

    public func snapshot() throws -> IMSnapshotMessage {
        try decode(IMSnapshotMessage.self, kind: .snapshot)
    }

    /// Version, then kind, then contents — in that order, so a message from a
    /// build we cannot understand is refused before anything is parsed out of it.
    private func decode<M: IMWireMessage>(_ type: M.Type, kind expected: Kind) throws -> M {
        guard WispritIMWire.isSupported(wireVersion) else {
            throw DecodeError.unsupportedVersion(wireVersion)
        }
        guard kind == expected else {
            throw DecodeError.wrongKind(expected: expected.rawValue, got: kind.rawValue)
        }
        do {
            let message = try WispritIMPayload.decoder.decode(M.self, from: json)
            guard WispritIMWire.isSupported(message.wireVersion) else {
                throw DecodeError.unsupportedVersion(message.wireVersion)
            }
            return message
        } catch let error as DecodeError {
            throw error
        } catch {
            throw DecodeError.malformed("\(error)")
        }
    }

    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    // MARK: Transport bytes

    /// Archived form for the wire. Secure coding is required, so a malformed or
    /// hostile archive fails to decode instead of instantiating something.
    public func archived() -> Data? {
        try? NSKeyedArchiver.archivedData(withRootObject: self, requiringSecureCoding: true)
    }

    public convenience init?(archived data: Data) {
        guard let payload = try? NSKeyedUnarchiver.unarchivedObject(
            ofClass: WispritIMPayload.self, from: data) else { return nil }
        self.init(wireVersion: payload.wireVersion, kind: payload.kind, json: payload.json)
    }

    // MARK: NSSecureCoding

    public static var supportsSecureCoding: Bool { true }

    public func encode(with coder: NSCoder) {
        coder.encode(wireVersion, forKey: Key.version)
        coder.encode(kind.rawValue as NSString, forKey: Key.kind)
        coder.encode(json as NSData, forKey: Key.json)
    }

    public required init?(coder: NSCoder) {
        let version = coder.decodeInteger(forKey: Key.version)
        guard let rawKind = coder.decodeObject(of: NSString.self, forKey: Key.kind) as String?,
              let kind = Kind(rawValue: rawKind),
              let data = coder.decodeObject(of: NSData.self, forKey: Key.json) as Data?
        else { return nil }
        self.wireVersion = version
        self.kind = kind
        self.json = data
        super.init()
    }

    public override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? WispritIMPayload else { return false }
        return other.wireVersion == wireVersion && other.kind == kind && other.json == json
    }

    public override var hash: Int {
        var hasher = Hasher()
        hasher.combine(wireVersion)
        hasher.combine(kind)
        hasher.combine(json)
        return hasher.finalize()
    }

    public override var description: String {
        "WispritIMPayload(v\(wireVersion), \(kind.rawValue), \(json.count)B)"
    }
}

// MARK: - Naming

/// Bundle identity and the one string that has to be exactly right.
///
/// A sandboxed input method fails to register its `NSConnection` unless
/// `InputMethodConnectionName` is literally `$(PRODUCT_BUNDLE_IDENTIFIER)_Connection`
/// (vChewing hit this; it is the single most common reason a sandboxed IM never
/// gets a client). We derive the connection name from the bundle id in exactly
/// one place, use the same string for the Mach service the app talks to, and pin
/// the rule in a test.
public enum WispritIMNaming {
    /// The input method bundle's identifier. Distinct from the app's
    /// `com.wisprit.app` — two bundles, two identities, two TCC records.
    public static let bundleID = "com.wisprit.im"
    /// `TISInputSourceID` of the palette source. Apple's own Dictation uses its
    /// bundle id here (`com.apple.inputmethod.ironwood`); so do we.
    public static let inputSourceID = bundleID
    /// Input mode id inside `ComponentInputModeDict`.
    public static let inputModeID = bundleID + ".dictation"
    /// The bundle's on-disk name.
    public static let bundleName = "WispritIM.app"

    /// THE rule. Any other value and a sandboxed IM silently never connects.
    public static func connectionName(forBundleID id: String) -> String {
        id + "_Connection"
    }

    /// `InputMethodConnectionName` for our bundle. Owned by `IMKServer`, which
    /// registers this Mach name itself the moment it is created.
    public static var connectionName: String { connectionName(forBundleID: bundleID) }

    /// The port the APP sends commands to — deliberately a different name.
    ///
    /// Measured on this machine: `IMKServer(name:bundleIdentifier:)` claims
    /// `<bundle id>_Connection` for itself, so a second listener on that same
    /// name fails outright (`xpc_error=[37: Operation already in progress]`) and
    /// the app then waits forever for a reply that can never come.
    public static func serviceName(forBundleID id: String) -> String {
        id + ".port"
    }

    public static var machServiceName: String { serviceName(forBundleID: bundleID) }

    /// The main app's bundle id, and the port the input method posts events to.
    public static let appBundleID = "com.wisprit.app"
    public static var eventPortName: String { appBundleID + ".im-events" }

    /// Every global Mach name this bundle registers, for the sandbox exception.
    public static func registeredMachNames(forBundleID id: String) -> [String] {
        [connectionName(forBundleID: id), serviceName(forBundleID: id)]
    }

    /// Names the sandboxed input method must be allowed to LOOK UP.
    public static var lookedUpMachNames: [String] { [eventPortName] }
}

// MARK: - Roles

/// Which side of the pipe a port belongs to. Both are plain named Mach ports
/// registered through `CFMessagePort` — see `IMPortTransport.swift` for why not
/// `NSXPCConnection`.
public enum WispritIMRole: String, Sendable {
    /// The input method's port: the app sends commands here.
    case inputMethod
    /// The app's port: the input method posts unsolicited events here
    /// (clientAcquired / clientLost).
    case app

    public var portName: String {
        switch self {
        case .inputMethod: return WispritIMNaming.machServiceName
        case .app: return WispritIMNaming.eventPortName
        }
    }
}
