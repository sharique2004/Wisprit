#if canImport(SwiftUI)
import SwiftUI

/// One stat on Home's right rail — `docs/design/ui-redesign.md` §3.3.
///
/// 240 × 72, flat, no card and no shadow: it is separated from its neighbours
/// by a hairline and nothing else (§1.7). The value is the only serif on the
/// row, which is the entire justification for bundling a display face.
public struct StatTile: View {
    public static let width: Double = 240
    public static let height: Double = 72

    private let label: String
    private let value: String
    private let sub: String?

    public init(label: String, value: String, sub: String? = nil) {
        self.label = label
        self.value = value
        self.sub = sub
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s4) {
            Text(label)
                .font(Theme.font(Theme.Role.captionEmph))
                .tracking(Theme.Role.captionEmph.tracking)
                .textCase(.uppercase)
                .foregroundStyle(Theme.inkTertiary)
            Text(value)
                .font(Theme.font(Theme.Role.numeralL))
                .tracking(Theme.Role.numeralL.tracking)
                .foregroundStyle(Theme.ink)
            if let sub {
                Text(sub)
                    .font(Theme.font(Theme.Role.caption))
                    .foregroundStyle(Theme.inkSecondary)
            }
        }
        .frame(width: StatTile.width, height: StatTile.height, alignment: .topLeading)
    }
}
#endif
