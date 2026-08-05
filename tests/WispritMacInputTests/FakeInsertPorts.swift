import Foundation
@testable import WispritMacInput

/// Records every system interaction in order, so the tests can assert the exact
/// cascade — including the clipboard dance's ordering, which is where the
/// "it pasted my old clipboard" class of bug lives. Nothing here touches the
/// real pasteboard, posts an event, or sleeps.
final class FakeInsertPorts: InsertPorts, @unchecked Sendable {

    enum Op: Equatable, CustomStringConvertible {
        case secureProbe
        case trustProbe
        case frontmost
        case type(String, units: Int)
        case commandV
        case sleep(Double)
        case snapshot
        case clear
        case declare([String])
        case setString(String, type: String)
        case changeCount
        case restore(items: Int)

        var description: String {
            switch self {
            case .secureProbe: return "secureProbe"
            case .trustProbe: return "trustProbe"
            case .frontmost: return "frontmost"
            case .type(let s, let u): return "type(\(s), \(u))"
            case .commandV: return "commandV"
            case .sleep(let s): return "sleep(\(s))"
            case .snapshot: return "snapshot"
            case .clear: return "clear"
            case .declare(let t): return "declare(\(t))"
            case .setString(_, let t): return "setString(type: \(t))"
            case .changeCount: return "changeCount"
            case .restore(let n): return "restore(\(n))"
            }
        }
    }

    // Scripted responses.
    var secure = false
    var trusted = true
    var bundleID: String?
    var executable = "/usr/bin/wisprit"
    var setStringSucceeds = true
    var restoreSucceeds = true
    var snapshotItems: [PasteboardItemSnapshot] = []
    /// Successive `changeCount()` answers; the last value repeats.
    var changeCountScript: [Int] = [7, 7]
    var typeError: Error?
    var postVError: Error?

    // Observations.
    private let lock = NSLock()
    private var _ops: [Op] = []
    private var changeCountCalls = 0
    private(set) var restored: [PasteboardItemSnapshot] = []
    private(set) var typedChunks: [String] = []
    private(set) var writtenString: String?

    var ops: [Op] { lock.withLock { _ops } }
    var sleeps: [Double] { ops.compactMap { if case .sleep(let s) = $0 { return s } else { return nil } } }

    private func record(_ op: Op) { lock.withLock { _ops.append(op) } }

    // --- InsertPorts ----------------------------------------------------------

    func secureInputEnabled() -> Bool { record(.secureProbe); return secure }
    func accessibilityTrusted() -> Bool { record(.trustProbe); return trusted }
    func frontmostBundleID() -> String? { record(.frontmost); return bundleID }
    func executablePath() -> String { executable }

    func typeUnicode(_ chunk: String, utf16Units: Int) throws {
        record(.type(chunk, units: utf16Units))
        lock.withLock { typedChunks.append(chunk) }
        if let typeError { throw typeError }
    }

    func postCommandV() throws {
        record(.commandV)
        if let postVError { throw postVError }
    }

    func sleep(_ seconds: Double) { record(.sleep(seconds)) }

    func pasteboardSnapshot() -> [PasteboardItemSnapshot] {
        record(.snapshot)
        return snapshotItems
    }

    func pasteboardClearContents() { record(.clear) }

    func pasteboardDeclareTypes(_ types: [String]) { record(.declare(types)) }

    func pasteboardSetString(_ text: String, forType type: String) -> Bool {
        record(.setString(text, type: type))
        lock.withLock { writtenString = text }
        return setStringSucceeds
    }

    func pasteboardChangeCount() -> Int {
        record(.changeCount)
        return lock.withLock {
            let value = changeCountScript.indices.contains(changeCountCalls)
                ? changeCountScript[changeCountCalls]
                : (changeCountScript.last ?? 0)
            changeCountCalls += 1
            return value
        }
    }

    func pasteboardRestore(_ snapshot: [PasteboardItemSnapshot]) -> Bool {
        record(.restore(items: snapshot.count))
        lock.withLock { restored.append(contentsOf: snapshot.isEmpty ? [[]] : snapshot) }
        return restoreSucceeds
    }
}

enum FakeError: Error, Equatable { case boom }
