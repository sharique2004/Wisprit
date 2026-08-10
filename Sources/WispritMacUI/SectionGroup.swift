#if canImport(SwiftUI)
import SwiftUI

/// A settings / list group — `docs/design/ui-redesign.md` §3.6.
///
/// A `sectionTitle` header over hairline-separated rows, **inside** the content
/// card. No nested cards, no shadow: depth is value steps and hairlines (§1.7),
/// and 20 pt of air is what separates one group from the next.
public struct SectionGroup<Content: View>: View {
    private let title: String
    private let footnote: String?
    private let content: Content

    public init(_ title: String, footnote: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footnote = footnote
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s8) {
            Text(title)
                .font(Theme.font(Theme.Role.sectionTitle))
                .foregroundStyle(Theme.ink)
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            if let footnote {
                Text(footnote)
                    .font(Theme.font(Theme.Role.caption))
                    .foregroundStyle(Theme.inkTertiary)
            }
        }
        .padding(.bottom, Theme.Space.s20)
    }
}

/// One row of a `SectionGroup`: a title, an optional description, and a
/// trailing control. 32 pt without the description, 44 pt with it (§1.5).
public struct SectionRow<Control: View>: View {
    private let title: String
    private let description: String?
    private let control: Control

    public init(_ title: String, description: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.description = description
        self.control = control()
    }

    public var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.s12) {
            VStack(alignment: .leading, spacing: Theme.Space.s2) {
                Text(title)
                    .font(Theme.font(Theme.Role.rowTitle))
                    .foregroundStyle(Theme.ink)
                if let description {
                    Text(description)
                        .font(Theme.font(Theme.Role.body))
                        .foregroundStyle(Theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Theme.Space.s16)
            control
        }
        .frame(minHeight: description == nil ? Theme.Size.rowHeight
                                             : Theme.Size.rowHeightWithDescription)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 1)
        }
    }
}
#endif
