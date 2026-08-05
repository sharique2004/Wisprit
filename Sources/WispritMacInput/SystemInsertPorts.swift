import AppKit
import ApplicationServices
import Carbon
import CoreGraphics
import Foundation
import WispritKit

/// The real system edge behind `InsertPorts`: NSPasteboard, NSWorkspace,
/// CGEvent posting, Carbon's secure-input probe, and the Accessibility TCC
/// check. Deliberately thin — every decision lives in `Inserter`, so this file
/// is the only part that cannot be unit-tested and the only part that needs
/// TCC grants at runtime.
///
/// Called from the session thread. `NSPasteboard` off the main thread is the
/// documented pattern here (and what the Python does); nothing in this type
/// touches AppKit views.
public final class SystemInsertPorts: InsertPorts, @unchecked Sendable {
    private let log = WLog.logger("insert")

    public init() {}

    // --- probes ---------------------------------------------------------------

    public func secureInputEnabled() -> Bool {
        IsSecureEventInputEnabled()
    }

    public func accessibilityTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    public func frontmostBundleID() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    public func executablePath() -> String {
        Bundle.main.executablePath
            ?? CommandLine.arguments.first
            ?? ProcessInfo.processInfo.processName
    }

    // --- event posting --------------------------------------------------------

    /// One keyDown/keyUp pair carrying the text as a unicode payload. Virtual
    /// keycode 0 with a unicode string is the standard "type this text"
    /// synthetic event; the keycode itself is irrelevant to the receiver.
    public func typeUnicode(_ chunk: String, utf16Units: Int) throws {
        let buffer = Array(chunk.utf16)
        guard !buffer.isEmpty else { return }
        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: isDown) else {
                throw InsertPortError.eventCreationFailed
            }
            buffer.withUnsafeBufferPointer { ptr in
                event.keyboardSetUnicodeString(stringLength: utf16Units, unicodeString: ptr.baseAddress)
            }
            event.post(tap: .cghidEventTap)
        }
    }

    /// ⌘V by virtual keycode (layout-independent for shortcuts).
    public func postCommandV() throws {
        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil,
                                      virtualKey: CGKeyCode(KeyCodes.ansiV),
                                      keyDown: isDown) else {
                throw InsertPortError.eventCreationFailed
            }
            event.flags = .maskCommand
            event.post(tap: .cghidEventTap)
        }
    }

    public func sleep(_ seconds: Double) {
        guard seconds > 0 else { return }
        Thread.sleep(forTimeInterval: seconds)
    }

    // --- pasteboard -----------------------------------------------------------

    private var pasteboard: NSPasteboard { .general }

    /// Best-effort copy of EVERY pasteboard item's data, keyed by type. Items
    /// that yield no readable data at all are skipped (as in `insert.py`), so a
    /// promise-only item doesn't come back as an empty husk.
    public func pasteboardSnapshot() -> [PasteboardItemSnapshot] {
        var snapshot: [PasteboardItemSnapshot] = []
        for item in pasteboard.pasteboardItems ?? [] {
            var entries: PasteboardItemSnapshot = []
            for type in item.types {
                guard let data = item.data(forType: type) else { continue }
                entries.append(PasteboardEntry(type: type.rawValue, data: data))
            }
            if !entries.isEmpty { snapshot.append(entries) }
        }
        return snapshot
    }

    public func pasteboardClearContents() {
        pasteboard.clearContents()
    }

    public func pasteboardDeclareTypes(_ types: [String]) {
        pasteboard.declareTypes(types.map { NSPasteboard.PasteboardType($0) }, owner: nil)
    }

    public func pasteboardSetString(_ text: String, forType type: String) -> Bool {
        pasteboard.setString(text, forType: NSPasteboard.PasteboardType(type))
    }

    public func pasteboardChangeCount() -> Int {
        pasteboard.changeCount
    }

    public func pasteboardRestore(_ snapshot: [PasteboardItemSnapshot]) -> Bool {
        var items: [NSPasteboardItem] = []
        for entry in snapshot {
            let item = NSPasteboardItem()
            for pair in entry {
                item.setData(pair.data, forType: NSPasteboard.PasteboardType(pair.type))
            }
            items.append(item)
        }
        pasteboard.clearContents()
        guard !items.isEmpty else { return true }   // empty snapshot = empty pasteboard
        let ok = pasteboard.writeObjects(items)
        if !ok { log.error("pasteboard restore failed") }
        return ok
    }
}

public enum InsertPortError: Error, Equatable {
    case eventCreationFailed
}
