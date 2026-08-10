#if canImport(SwiftUI)
import SwiftUI

/// A row badge — `docs/design/ui-redesign.md` §3.4.
///
/// `rChip`, `fillSubtle`, 11 pt, 6 pt horizontal padding. The tint is a glyph
/// tint only: `attention` is never a fill wider than 16 pt (§1.6), and a chip
/// is wider than that.
public struct Badge: View {
    private let title: String
    private let symbol: String?
    private let tint: Color

    public init(_ title: String, symbol: String? = nil, tint: Color = Theme.inkSecondary) {
        self.title = title
        self.symbol = symbol
        self.tint = tint
    }

    public var body: some View {
        HStack(spacing: Theme.Space.s4) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(tint)
            }
            Text(title)
                .font(Theme.font(Theme.Role.captionEmph))
                .tracking(Theme.Role.captionEmph.tracking)
                .foregroundStyle(Theme.inkSecondary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, Theme.Space.s2)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                .fill(Theme.fillSubtle)
        )
    }
}

/// A heard-phrase chip: same geometry, quoted machine text (§1.4 — this is what
/// the recognizer produced, not what a human wrote).
public struct PhraseChip: View {
    private let phrase: String

    public init(_ phrase: String) {
        self.phrase = phrase
    }

    public var body: some View {
        Text("“\(phrase)”")
            .font(Theme.font(Theme.Role.caption))
            .foregroundStyle(Theme.inkSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, Theme.Space.s2)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                    .fill(Theme.fillSubtle)
            )
    }
}
#endif
