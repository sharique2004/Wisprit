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
    /// The §2.5 staggered collapse (row 6): one animatable phase over a
    /// snapshot of the meter as it stood at release. Both live here so the
    /// choreography is view state — the model's `bars` are already at floor,
    /// which is what every headless test asserts.
    @State private var collapseBase: [Double] = []
    @State private var collapsePhase: Double = 1

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
            .onChange(of: box.render) { old, new in
                stageCollapse(from: old, to: new)
            }
    }

    // MARK: - content

    @ViewBuilder
    private func content(_ render: PillRender) -> some View {
        let hasTail = !render.bubble.isEmpty
        let liveness: Double = PillPalette.isLive(render.state) ? 1 : 0
        HStack(spacing: PillTailGeometry.gap) {
            if !render.bars.isEmpty {
                // §2.5 rows 2 and 6: the tint crossfade (prewarming →
                // listening, 140 ms ease-in-out; listening → finalizing
                // desaturate, 120 ms ease-in) and the staggered collapse ride
                // the meter's two animatable lanes. The 20 Hz level path
                // animates neither — `liveness` and `collapsePhase` only move
                // at state changes.
                PillMeter(levels: render.bars,
                          metrics: hasTail ? .pillCompact : .pill,
                          liveness: liveness,
                          collapseBase: collapseBase,
                          collapsePhase: collapsePhase)
                    .animation(liveness == 1
                                   ? .easeInOut(duration: PillMotion.tintCrossfadeDuration)
                                   : .easeIn(duration: PillMotion.desaturateDuration),
                               value: liveness)
            }
            if let symbol = render.glyph.symbolName {
                Image(systemName: symbol)
                    .font(.system(size: glyphSize(render.glyph), weight: .medium))
                    .foregroundStyle(color(render.tint))
                    .accessibilityHidden(true)
                    .transition(.opacity)
            }
            if hasTail {
                // Machine text (§1.4). Live tails head-truncate — the newest
                // words are the ones worth keeping; the alarm states
                // tail-truncate, because a diagnosis leads with the diagnosis
                // (R9a).
                Text(render.bubble)
                    .font(Theme.font(Theme.Role.mono))
                    .foregroundStyle(color(textColor(render)).opacity(PillPalette.textAlpha))
                    .lineLimit(1)
                    .truncationMode(truncationMode(render.state))
                    .frame(width: render.bubbleWidth, alignment: .leading)
            }
        }
        .padding(.horizontal, hasTail ? PillTailGeometry.textInset : 0)
        .frame(maxWidth: .infinity, alignment: hasTail ? .leading : .center)
        // §2.5 row 7's other half: when the glyph changes, its insertion —
        // and whatever it replaces — crossfades over the committed duration
        // instead of popping. Under Reduce Motion this fade *is* the committed
        // transition: the contraction is dropped, the crossfade survives. The
        // 20 Hz level path never changes `glyph`, so this transaction is
        // state-change-only.
        .animation(.easeInOut(duration: PillMotion.committedDuration), value: render.glyph)
        .accessibilityElement()
        .accessibilityLabel(accessibilityLabel(render))
    }

    /// Row 6 of §2.5: when `finalizing`/`refining` collapses a live meter, the
    /// model hands over the pre-collapse levels and the surface plays them to
    /// floor — 120 ms desaturate first (the tint lane above), then the 6 ms ×
    /// index stagger. Under Reduce Motion the bars snap, exactly as they do on
    /// the scroll.
    private func stageCollapse(from old: PillRender, to new: PillRender) {
        if new.state == .recording || new.state == .prewarming {
            collapseBase = []
            collapsePhase = 1
            return
        }
        guard !new.collapseFrom.isEmpty, old.collapseFrom.isEmpty,
              new.state == .finalizing || new.state == .refining
        else { return }
        guard !reduceMotion else {
            collapseBase = []
            collapsePhase = 1
            return
        }
        collapseBase = new.collapseFrom
        collapsePhase = 0
        let duration = PillMotion.collapseDuration(barCount: new.collapseFrom.count)
        withAnimation(.easeIn(duration: duration).delay(PillMotion.desaturateDuration)) {
            collapsePhase = 1
        }
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

    private func textColor(_ render: PillRender) -> PillColor {
        // The dead-mic cue is a notice, not an alarm: muted ink, never orange
        // (R10 — the mic is open, so the bars keep the tally colour; the text
        // must not borrow it).
        if render.tailMuted { return PillPalette.muted }
        switch render.state {
        case .error, .blockedSecure: return PillPalette.tint(for: render.state)
        default: return PillPalette.ink
        }
    }

    private func truncationMode(_ state: PillState) -> Text.TruncationMode {
        switch PillTailGeometry.truncation(for: state) {
        case .head: return .head
        case .tail: return .tail
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

// MARK: - the meter's two animated lanes

/// The pill's meter with the two §2.5 animations `TallyWaveform` itself must
/// never carry: the bar tint crossfade (`liveness`, muted ↔ hot) and the
/// staggered collapse (`collapsePhase` over `collapseBase`). One `Animatable`
/// scalar pair, one `Canvas` underneath, no per-bar view identity — the
/// per-bar delays come precomputed from `PillMotion` (§2.12's constraint).
///
/// Steady states cost nothing: while recording, `liveness == 1` and
/// `collapsePhase == 1`, so the only redraws are the level ticks TallyWaveform
/// was already drawing — and silence never reaches this view at all.
private struct PillMeter: View, Animatable {
    var levels: [Double]
    var metrics: TallyMetrics
    /// 0 = `studioMuted`, 1 = mic-orange. Only 1 while the mic is open (§1.6).
    var liveness: Double
    /// Pre-collapse levels (oldest first), empty when no collapse is playing.
    var collapseBase: [Double]
    /// 0 → 1 across `PillMotion.collapseDuration`.
    var collapsePhase: Double
    @Environment(\.colorScheme) private var colorScheme

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(liveness, collapsePhase) }
        set {
            liveness = newValue.first
            collapsePhase = newValue.second
        }
    }

    var body: some View {
        TallyWaveform(levels: displayedLevels, metrics: metrics, color: blendedColor)
    }

    /// While the collapse plays, draw the snapshot staggering down to floor;
    /// at phase 1 the drawn levels equal the model's truth (all floor).
    private var displayedLevels: [Double] {
        guard collapsePhase < 1, !collapseBase.isEmpty else { return levels }
        let count = collapseBase.count
        return collapseBase.enumerated().map { index, value in
            let progress = PillMotion.collapseProgress(phase: collapsePhase,
                                                       bar: index, barCount: count)
            return value * (1 - progress)
        }
    }

    /// The tint crossfade, interpolated in sRGB between the same two colours
    /// the static states use — `studioMuted` is appearance-independent and
    /// `hot` resolves per appearance, so the endpoints match `Theme` exactly.
    private var blendedColor: Color {
        let muted = PillPalette.muted
        let hot = PillColor(hex: colorScheme == .light
                                ? Theme.Token.hot.light
                                : Theme.Token.hot.dark)
        let t = min(1.0, max(0.0, liveness))
        return Color(.sRGB,
                     red: muted.r + (hot.r - muted.r) * t,
                     green: muted.g + (hot.g - muted.g) * t,
                     blue: muted.b + (hot.b - muted.b) * t,
                     opacity: 1)
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
