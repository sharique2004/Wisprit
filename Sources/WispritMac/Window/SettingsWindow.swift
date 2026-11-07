#if os(macOS)
import SwiftUI
import WispritMacUI

/// What the ⌘, Settings window hosts. Settings left the sidebar (HIG: settings
/// live in their own window, reached with ⌘,, titled by pane).
struct SettingsWindowRoot: View {
    @ObservedObject var model: WispritWindowModel

    var body: some View {
        SettingsPage(model: model)
            .frame(minWidth: 560, minHeight: 420)
            .background(Theme.surface)
    }
}
#endif
