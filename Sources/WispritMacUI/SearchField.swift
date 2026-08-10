#if canImport(SwiftUI)
import SwiftUI

/// The shared search field — `docs/design/ui-redesign.md` §3.3 / §3.4.
///
/// 240 pt, `rControl`, `fillSubtle`, a 12 pt `magnifyingglass` leading. Plain
/// text-field style on purpose: the system's bordered look would put a second
/// stroke inside the content card, and the card already has the only hairline
/// that page needs.
public struct SearchField: View {
    public static let width: Double = 240

    private let placeholder: String
    @Binding private var text: String

    public init(_ placeholder: String, text: Binding<String>) {
        self.placeholder = placeholder
        self._text = text
    }

    public var body: some View {
        HStack(spacing: Theme.Space.s8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Theme.inkTertiary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(Theme.font(Theme.Role.body))
                .foregroundStyle(Theme.ink)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.inkTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, Theme.Space.s8)
        .frame(width: SearchField.width, height: Theme.Size.hitTarget)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(Theme.fillSubtle)
        )
    }
}
#endif
