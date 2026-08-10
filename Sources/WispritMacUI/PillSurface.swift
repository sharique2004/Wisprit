#if canImport(SwiftUI)
import SwiftUI

/// The frame the hosting view reads, as one observable property.
///
/// §6.3: the `NSHostingView` is built once and its root view's render is
/// updated through this box, so a 20 Hz frame change is a single property write
/// rather than a hosting-view rebuild.
@MainActor
@Observable
public final class PillRenderBox {
    public var render: PillRender

    public init(render: PillRender = .collapsed) {
        self.render = render
    }
}

/// The pill's drawn surface — `docs/design/ui-redesign.md` §2.2, §2.4, §2.5.
///
/// Replaces the old `PillView: NSView`, which drew a halo, a level-reactive dot
/// and a grey bubble. Everything above the drawing — the state machine, the
/// tail logic, the width quantisation, the panel plumbing — is unchanged.
public struct PillSurface: View {
    private let box: PillRenderBox
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(box: PillRenderBox) {
        self.box = box
    }

    public var body: some View {
        let render = box.render
        let fill = PillPalette.bodyFill(for: render.state)

        content(render)
            .frame(width: render.totalWidth, height: render.height, alignment: .center)
            .background(
                Capsule(style: .continuous)
                    .fill(color(fill.color).opacity(fill.alpha))
                    .overlay(
                        // The 1 pt rim is what keeps the pill legible against a
                        // dark desktop; the body alone would dissolve into it.
                        Capsule(style: .continuous)
                            .strokeBorder(Theme.studioStroke, lineWidth: 1)
                    )
            )
            .overlay(alignment: .bottom) { sweep(render) }
            .modifier(AlarmShake(isActive: isAlarm(render.state), reduceMotion: reduceMotion))
            .opacity(render.isVisible ? 1 : 0)
    }

    // MARK: - content

    @ViewBuilder
    private func content(_ render: PillRender) -> some View {
        let hasTail = !render.bubble.isEmpty
        HStack(spacing: PillTailGeometry.gap) {
            if !render.bars.isEmpty {
                TallyWaveform(levels: render.bars,
                              metrics: hasTail ? .pillCompact : .pill,
                              color: barColor(render.state))
            }
            if let symbol = render.glyph.symbolName {
                Image(systemName: symbol)
                    .font(.system(size: glyphSize(render.glyph), weight: .medium))
                    .foregroundStyle(color(render.tint))
                    .accessibilityHidden(true)
            }
            if hasTail {
                // Machine text (§1.4), head-truncated: the newest words are the
                // ones worth keeping.
                Text(render.bubble)
                    .font(Theme.font(Theme.Role.mono))
                    .foregroundStyle(color(textColor(render.state)).opacity(PillPalette.textAlpha))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(width: render.bubbleWidth, alignment: .leading)
            }
        }
        .padding(.horizontal, hasTail ? PillTailGeometry.textInset : 0)
        .frame(maxWidth: .infinity, alignment: hasTail ? .leading : .center)
        .accessibilityElement()
        .accessibilityLabel(accessibilityLabel(render))
    }

    /// `finalizing` / `refining` draw a sweep hairline rather than a spinner:
    /// no rotation, no chrome, just a highlight crossing a track (§2.4).
    @ViewBuilder
    private func sweep(_ render: PillRender) -> some View {
        if render.state == .finalizing || render.state == .refining {
            SweepHairline(reduceMotion: reduceMotion)
                .frame(width: max(0, render.totalWidth - 2 * PillTailGeometry.textInset), height: 1.5)
                .padding(.bottom, 3)
        }
    }

    // MARK: - palette

    private func color(_ c: PillColor) -> Color {
        Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: 1)
    }

    /// The bars are the one place mic-orange appears, and they are orange only
    /// while the microphone is open (§1.6). Every other meter state is muted.
    private func barColor(_ state: PillState) -> Color {
        PillPalette.isLive(state) ? Theme.hot(.pillWaveform) : color(PillPalette.muted)
    }

    private func textColor(_ state: PillState) -> PillColor {
        switch state {
        case .error, .blockedSecure: return PillPalette.tint(for: state)
        default: return PillPalette.ink
        }
    }

    private func glyphSize(_ glyph: PillGlyph) -> Double {
        switch glyph {
        case .sparkles: return 9
        case .sparkle: return 11
        default: return 13
        }
    }

    private func isAlarm(_ state: PillState) -> Bool {
        state == .error || state == .blockedSecure
    }

    private func accessibilityLabel(_ render: PillRender) -> String {
        if !render.message.isEmpty { return render.message }
        switch render.state {
        case .hidden: return ""
        case .prewarming: return "Starting"
        case .recording: return "Listening"
        case .finalizing: return "Finishing"
        case .refining: return "Cleaning up"
        case .success: return "Inserted"
        case .error: return "Error"
        case .blockedSecure: return PillGeometry.blockedSecureMessage
        }
    }
}

// MARK: - the sweep

/// A 1.5 pt capsule track with a 24 pt highlight translating left→right on a
/// 900 ms linear loop. Under Reduce Motion it is a static 40%-filled track:
/// durations survive, only motion goes (§2.5).
private struct SweepHairline: View {
    let reduceMotion: Bool
    @State private var advanced = false

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.studioMuted.opacity(0.3))
                if reduceMotion {
                    Capsule().fill(Theme.studioInk.opacity(0.7)).frame(width: width * 0.4)
                } else {
                    Capsule().fill(Theme.studioInk.opacity(0.7))
                        .frame(width: 24)
                        .offset(x: advanced ? max(0, width - 24) : 0)
                        .animation(.linear(duration: 0.9).repeatForever(autoreverses: false),
                                   value: advanced)
                }
            }
            .onAppear { advanced = true }
        }
    }
}

// MARK: - the error shake

/// A single 2 pt horizontal shake, 2 cycles, 180 ms total — and then it stops.
/// Driven by `.task(id:)` so it is one-shot by construction: a pill that
/// vibrates until its auto-hide fires would be worse than no feedback at all.
private struct AlarmShake: ViewModifier {
    let isActive: Bool
    let reduceMotion: Bool
    @State private var offset: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .offset(x: offset)
            .task(id: isActive) {
                guard isActive, !reduceMotion else {
                    offset = 0
                    return
                }
                for step: CGFloat in [2, -2, 2, -2, 0] {
                    withAnimation(.linear(duration: 0.036)) { offset = step }
                    try? await Task.sleep(for: .milliseconds(36))
                }
            }
    }
}
#endif
