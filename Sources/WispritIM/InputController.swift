import Foundation
import WispritIMProtocol

#if os(macOS)
import InputMethodKit

/// The `IMKInputController` the Text Services Manager instantiates for every
/// input session, named in Info.plist as `InputMethodServerControllerClass`.
///
/// It is deliberately inert as an *input* method: `recognizedEvents` is empty and
/// every input hook returns false, so not one keystroke is intercepted, delayed
/// or swallowed. Wisprit is a palette source — it rides alongside the user's real
/// keyboard layout (that is what `InputMethodType = palette` buys) and its only
/// job here is to hand the live `IMKTextInput` client to the session so the app
/// can stream into the focused field.
@objc(WispritInputController)
public final class WispritInputController: IMKInputController {

    // MARK: Session lifecycle

    public override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        guard let client = sender as? IMKTextInput else {
            IMService.shared.clientLost(reason: "activateServer without an IMKTextInput client")
            return
        }
        IMService.shared.clientAcquired(IMKClientSeam(client))
    }

    public override func deactivateServer(_ sender: Any!) {
        IMService.shared.clientLost(reason: "deactivateServer")
        super.deactivateServer(sender)
    }

    /// The client wants the composition finished right now (the user clicked
    /// elsewhere in the text, the app is closing the session). Commit whatever is
    /// marked — dropping it would lose words the user already said.
    public override func commitComposition(_ sender: Any!) {
        IMService.shared.commitCompositionFromClient()
        super.commitComposition(sender)
    }

    // MARK: Never touch the user's typing

    /// No event mask: TSM will not route key events to us at all.
    public override func recognizedEvents(_ sender: Any!) -> Int { 0 }

    public override func inputText(_ string: String!, client sender: Any!) -> Bool { false }

    public override func inputText(_ string: String!,
                                   key keyCode: Int,
                                   modifiers flags: Int,
                                   client sender: Any!) -> Bool { false }

    public override func handle(_ event: NSEvent!, client sender: Any!) -> Bool { false }

    public override func didCommand(by aSelector: Selector!, client sender: Any!) -> Bool { false }

    /// No candidate window, no menu, no preferences pane — nothing that could
    /// steal focus from what the user is writing.
    public override func candidates(_ sender: Any!) -> [Any]! { [] }

    public override func menu() -> NSMenu! { NSMenu(title: "Wisprit") }
}
#endif
