import Foundation
import WispritMacUI
import WispritPolish

/// The pure half of the "Polish Last" menu item — the bit worth a test.
///
/// Replaces `app.py`'s "Polish Last with Claude" submenu. Same four modes, same
/// keys, same labels; the model behind them is Apple Intelligence, in-process,
/// with no subprocess and no network.
enum PolishMenu {

    /// Submenu rows, in `PolishMode.allCases` order. The represented object is
    /// the mode's raw value — byte-identical to the Python `MODES` keys, so an
    /// item built by an older build still resolves through `PolishMode.named`.
    static var modeItems: [PolishModeItem] {
        PolishMode.allCases.map { PolishModeItem(key: $0.rawValue, label: $0.label) }
    }

    /// What the pill says after a successful polish. The text is on the
    /// clipboard, not in the field: polish is an explicit, off-path action over
    /// a transcript that was already inserted.
    static func successNotice(for mode: PolishMode) -> String {
        "\(mode.label) — ⌘V to paste"
    }

    /// Failure copy comes straight from the cage, which already phrases every
    /// kind for a user.
    static func failureNotice(for result: PolishResult) -> String? {
        guard case .failure(let reason, _) = result else { return nil }
        return reason
    }
}
