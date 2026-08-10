#if canImport(SwiftUI)
import SwiftUI

/// The site's keycap, translated — `docs/design/ui-redesign.md` §4.4.
///
/// The held state's inset ring is the fourth and final sanctioned orange, and
/// it is correct: the key is held, so the microphone is open (§1.6).
public struct KeycapView: View {
    public enum Size: Equatable, Sendable {
        case small
        case large

        var side: Double { self == .large ? 74 : 28 }
        var radius: Double { self == .large ? 16 : 6 }
        var symbolSize: Double { self == .large ? 26 : 12 }
        var showsLabel: Bool { self == .large }
        /// The offset copy behind the cap.
        var depth: Double { self == .large ? 3 : 2 }
    }

    private static let faceTop = ColorToken("keycapFaceTop", light: 0xFFFFFF, dark: 0x2A2F36)
    private static let faceBottom = ColorToken("keycapFaceBottom", light: 0xEEF0F3, dark: 0x1E2226)
    private static let depthFill = ColorToken("keycapDepth", light: 0xC9CDD3, dark: 0x0E1114)

    private let symbol: String
    private let label: String
    private let size: Size
    private let isHeld: Bool

    /// Defaults to the 🌐 key, which is the one this app is about.
    public init(symbol: String = "globe", label: String = "fn",
                size: Size = .large, isHeld: Bool = false) {
        self.symbol = symbol
        self.label = label
        self.size = size
        self.isHeld = isHeld
    }

    public var body: some View {
        ZStack {
            // Depth: an offset copy behind, which collapses when the key is
            // held — the cap travels down onto it.
            if !isHeld {
                RoundedRectangle(cornerRadius: size.radius, style: .continuous)
                    .fill(Color(KeycapView.depthFill))
                    .offset(y: size.depth)
            }
            RoundedRectangle(cornerRadius: size.radius, style: .continuous)
                .fill(LinearGradient(colors: [Color(KeycapView.faceTop), Color(KeycapView.faceBottom)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(
                    RoundedRectangle(cornerRadius: size.radius, style: .continuous)
                        .strokeBorder(Theme.hairlineStrong, lineWidth: 1)
                )
                .overlay {
                    if isHeld {
                        RoundedRectangle(cornerRadius: size.radius, style: .continuous)
                            .strokeBorder(Theme.hot(.heldKeycap).opacity(0.55), lineWidth: 2)
                            .padding(2)
                    }
                }
                .overlay {
                    VStack(spacing: Theme.Space.s2) {
                        Image(systemName: symbol)
                            .font(.system(size: size.symbolSize, weight: .regular))
                            .foregroundStyle(Theme.ink)
                        if size.showsLabel && !label.isEmpty {
                            Text(label)
                                .font(Theme.font(Theme.Role.caption))
                                .foregroundStyle(Theme.inkTertiary)
                        }
                    }
                }
                .offset(y: isHeld ? size.depth : 0)
        }
        .frame(width: size.side, height: size.side + size.depth, alignment: .top)
        .accessibilityElement()
        .accessibilityLabel(label.isEmpty ? symbol : label)
    }
}
#endif
