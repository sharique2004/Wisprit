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
/// The state machine, the tail logic, the width quantisation and the panel
/// plumbing are unchanged; the *object* is not. Three things happen here that
/// a flat capsule cannot do:
///
/// 1. **It is glass, not paint.** The panel puts an `NSVisualEffectView` under
///    this view; the body is a near-black tint at 76% over it, so the desktop
///    moves behind the pill while the tint still guarantees the same reading on
///    white and on black. The rim is a *lit edge* — bright along the top arc,
///    nearly gone underneath — which is the single detail that separates a
///    crafted object from a filled shape.
/// 2. **It never stops telling the truth about time.** Listening is the voice;
///    finalizing and refining are the same instrument moving under their own
///    power at a third of the amplitude (`PillMotion.thinkingLevel`); committed
///    is a check mark that draws itself. No spinner, no second chrome element,
///    one vocabulary throughout.
/// 3. **Nothing shakes, nothing pops out of its own panel.** The hosting view
///    clips to the panel, so the old hover scale and error shake were slicing
///    themselves off at the edges. Both are now edge-light changes, which is
///    also the calmer reading of an error.
public struct PillSurface: View {
    private let box: PillRenderBox
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Reduce Transparency: the panel drops its material, so the body has to
    /// stop counting on one. Read here *and* in `Pill` from the same system
    /// signal, which is what keeps the two layers in agreement.
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    /// Increase Contrast: one solid edge instead of a lit one.
    @Environment(\.colorSchemeContrast) private var contrast
    /// The §2.5 staggered collapse (row 6): one animatable phase over a
    /// snapshot of the meter as it stood at release. Both live here so the
    /// choreography is view state — the model's `bars` are already at floor,
    /// which is what every headless test asserts.
    @State private var collapseBase: [Double] = []
    @State private var collapsePhase: Double = 1
    /// The thinking wave's phase. 0 while the meter belongs to the voice.
    @State private var thinkingPhase: Double = 0
    /// The body's arrival spring. Reset while the panel is off screen, so the
    /// spring always has somewhere to come from.
    @State private var arrived = true
    /// The committed check mark's stroke, 0…1.
    @State private var checkDrawn = false
    @State private var hovered = false

    public init(box: PillRenderBox) {
        self.box = box
    }

    public var body: some View {
        let render = box.render

        content(render)
            .frame(width: render.totalWidth, height: render.height, alignment: .center)
            .background(body(for: render))
            .scaleEffect(arrived ? 1 : PillMotion.appearScale)
            .opacity(render.isVisible ? 1 : 0)
            .onHover { hovered = $0 }
            .animation(.easeOut(duration: 0.14), value: hovered)
            .onChange(of: box.render) { old, new in
                stage(from: old, to: new)
            }
    }

    // MARK: - the body

    /// Tint, lit edge, inner highlight — in that order, and never more than
    /// three fills. Everything here is a state-change-only value: a 20 Hz level
    /// tick changes none of it, so the background's rasterisation is stable for
    /// the whole utterance.
    @ViewBuilder
    private func body(for render: PillRender) -> some View {
        let fill = PillPalette.bodyFill(for: render.state)
        let capsule = Capsule(style: .continuous)
        ZStack {
            capsule.fill(color(fill.color).opacity(bodyAlpha(for: render.state)))
            // The lit edge. Under Increase Contrast it stops being lit and
            // becomes one solid, unmistakable line.
            capsule.strokeBorder(rimStyle(for: render.state), lineWidth: 1)
            // A hair of thickness under the top arc. Skipped entirely under
            // Increase Contrast, where it only muddies the solid edge.
            if contrast != .increased {
                capsule
                    .inset(by: 1)
                    .strokeBorder(
                        LinearGradient(
                            stops: [
                                .init(color: .white.opacity(PillPalette.innerHighlightAlpha),
                                      location: 0),
                                .init(color: .white.opacity(0), location: 0.45),
                            ],
                            startPoint: .top, endPoint: .bottom),
                        lineWidth: 1)
            }
        }
        .animation(.easeInOut(duration: PillMotion.alarmRimDuration), value: render.state)
    }

    /// The rim. Two jobs: separate the pill from an unknown desktop, and say
    /// "alarm" before a single word of the message has been read.
    private func rimStyle(for state: PillState) -> AnyShapeStyle {
        if contrast == .increased {
            return AnyShapeStyle(Color.white.opacity(PillPalette.rimContrastAlpha))
        }
        if state == .error || state == .blockedSecure {
            // A tinted edge for the whole life of the state, rather than a
            // shake at the start of it. Clear, and never an alarm.
            let tint = color(PillPalette.tint(for: state))
            return AnyShapeStyle(
                LinearGradient(
                    colors: [tint.opacity(PillPalette.alarmRimAlpha),
                             tint.opacity(PillPalette.alarmRimAlpha * 0.35)],
                    startPoint: .top, endPoint: .bottom))
        }
        // Hovering the resting bar lifts the edge into the light. It is the
        // whole hover affordance now, and it cannot clip.
        let boost = (hovered && state == .idle) ? PillPalette.rimHoverBoost : 0
        return AnyShapeStyle(
            LinearGradient(
                colors: [.white.opacity(PillPalette.rimTopAlpha + boost),
                         .white.opacity(PillPalette.rimBottomAlpha + boost / 2)],
                startPoint: .top, endPoint: .bottom))
    }

    /// 92% over nothing, 76% over glass — and near-solid under Increase
    /// Contrast, where the desktop showing through is a cost with no benefit.
    private func bodyAlpha(for state: PillState) -> Double {
        let alarm = (state == .error || state == .blockedSecure)
        if contrast == .increased { return alarm ? 1.0 : 0.98 }
        if reduceTransparency {
            return alarm ? PillPalette.alarmBodyAlpha : PillPalette.bodyAlpha
        }
        return alarm ? PillPalette.alarmBodyAlphaOverMaterial : PillPalette.bodyAlphaOverMaterial
    }

    // MARK: - content

    @ViewBuilder
    private func content(_ render: PillRender) -> some View {
        let hasTail = !render.bubble.isEmpty
        let liveness: Double = PillPalette.isLive(render.state) ? 1 : 0
        // §2.4 holds the width an utterance earned across the finalize stages,
        // so a wait that follows a live tail is a wide capsule with nothing in
        // it yet. Lay that case out the way the tail laid it out — meter on the
        // left, room on the right — rather than re-centring the meter in the
        // held width: the words were on the right, the patience copy is about
        // to be on the right, and in between nothing should have moved.
        let holdingRoom = !hasTail && render.totalWidth > PillGeometry.widthListening
            && (render.state == .finalizing || render.state == .refining)
        let compact = hasTail || holdingRoom
        HStack(spacing: PillTailGeometry.gap) {
            if !render.bars.isEmpty {
                // §2.5 rows 2 and 6 plus the thinking wave: three animatable
                // lanes, one `Canvas`, no per-bar view identity. The 20 Hz
                // level path drives none of them — `liveness`, `collapsePhase`
                // and `thinkingPhase` only move at state changes.
                PillMeter(levels: compact ? newest(render.bars) : render.bars,
                          metrics: meterMetrics(render.state, compact: compact),
                          liveness: liveness,
                          collapseBase: collapseBase,
                          collapsePhase: collapsePhase,
                          thinkingPhase: thinkingPhase)
                    .animation(liveness == 1
                                   ? .easeInOut(duration: PillMotion.tintCrossfadeDuration)
                                   : .easeIn(duration: PillMotion.desaturateDuration),
                               value: liveness)
            }
            glyph(render)
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
                    // The copy arrives *with* the capsule that opened for it,
                    // rather than snapping in at the end of the widening.
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, compact ? PillTailGeometry.textInset : 0)
        .frame(maxWidth: .infinity, alignment: compact ? .leading : .center)
        // §2.5 row 7's other half: when the glyph changes, its insertion —
        // and whatever it replaces — crossfades over the committed duration
        // instead of popping. Under Reduce Motion this fade *is* the committed
        // transition: the contraction is dropped, the crossfade survives. The
        // 20 Hz level path never changes `glyph`, so this transaction is
        // state-change-only.
        .animation(.easeInOut(duration: PillMotion.committedDuration), value: render.glyph)
        .animation(.easeOut(duration: PillMotion.widthDuration), value: hasTail)
        .accessibilityElement()
        .accessibilityLabel(accessibilityLabel(render))
        // The pill is a status light, not a control: it never takes focus and
        // it never offers an action to perform.
        .accessibilityAddTraits(.isStaticText)
    }

    /// One instrument, three scales — the resting bar gets the larger dot
    /// because it has no waveform to resolve, only a pulse to have.
    private func meterMetrics(_ state: PillState, compact: Bool) -> TallyMetrics {
        if state == .idle { return .pillIdle }
        return compact ? .pillCompact : .pill
    }

    /// The newest slots, for the compact field. The model already does this for
    /// every state that *has* a tail; the held-width wait is the one case where
    /// the view has to, because the tail it is holding room for has not arrived.
    private func newest(_ bars: [Double]) -> [Double] {
        guard bars.count > PillGeometry.barCountCompact else { return bars }
        return Array(bars.suffix(PillGeometry.barCountCompact))
    }

    /// The commit is the one glyph that is *drawn*. Everything else is an SF
    /// Symbol, which is the right call for a lock, a warning and a sparkle —
    /// but a check mark that appears fully formed is a picture of success,
    /// while one that strokes itself in 220 ms is the act of succeeding.
    @ViewBuilder
    private func glyph(_ render: PillRender) -> some View {
        if render.glyph == .checkmark {
            CheckStroke()
                .trim(from: 0, to: checkDrawn ? 1 : 0)
                .stroke(color(render.tint),
                        style: StrokeStyle(lineWidth: 1.9, lineCap: .round, lineJoin: .round))
                .frame(width: 12, height: 12)
                .accessibilityHidden(true)
        } else if let symbol = render.glyph.symbolName {
            Image(systemName: symbol)
                .font(.system(size: glyphSize(render.glyph), weight: .medium))
                .foregroundStyle(color(render.tint))
                .accessibilityHidden(true)
                .transition(.opacity)
        }
    }

    // MARK: - choreography

    /// Every state-change animation in one place, behind one guard.
    ///
    /// The guard is the load-bearing part: this closure runs on every `render`
    /// change, which during dictation means 20 times a second. A level tick
    /// changes neither the state, nor the visibility, nor the glyph, so it
    /// leaves on the first line and touches no `@State` at all.
    private func stage(from old: PillRender, to new: PillRender) {
        guard old.state != new.state
                || old.isVisible != new.isVisible
                || old.glyph != new.glyph else { return }
        stageCollapse(from: old, to: new)
        stageThinking(from: old, to: new)
        stageArrival(from: old, to: new)
        stageCheck(from: old, to: new)
    }

    /// Row 6 of §2.5: when `finalizing`/`refining` collapses a live meter, the
    /// model hands over the pre-collapse levels and the surface plays them to
    /// floor — 120 ms desaturate first (the tint lane above), then the 6 ms ×
    /// index stagger. Under Reduce Motion the bars snap, exactly as they do on
    /// the scroll.
    private func stageCollapse(from old: PillRender, to new: PillRender) {
        if new.state == .recording || new.state == .prewarming || new.state == .idle {
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

    /// The thinking wave. Starts once the collapse has landed the meter on its
    /// dots — the bars fall silent, and *then* the pill starts working — and
    /// keeps crossing until the stage ends.
    ///
    /// `finalizing → refining` is the same wait wearing a different label, so
    /// the wave rides straight through it rather than restarting: a stutter
    /// there would read as a hitch in the work, which it is not.
    ///
    /// Under Reduce Motion the crest parks at the centre. That is not a
    /// fallback to nothing: a still, shallow arc is visibly not the flat idle
    /// dot row, so the state stays legible with zero motion — which is the
    /// whole contract ("durations survive; only motion goes").
    private func stageThinking(from old: PillRender, to new: PillRender) {
        let thinking = isThinking(new)
        guard thinking else {
            withTransaction(Transaction(animation: nil)) { thinkingPhase = 0 }
            return
        }
        guard !isThinking(old) else { return }
        guard !reduceMotion else {
            withTransaction(Transaction(animation: nil)) {
                thinkingPhase = PillMotion.reducedMotionThinkingPhase
            }
            return
        }
        withTransaction(Transaction(animation: nil)) { thinkingPhase = 0 }
        withAnimation(.linear(duration: PillMotion.thinkingCycle)
                        .repeatForever(autoreverses: false)
                        .delay(PillMotion.collapseDuration(barCount: PillGeometry.barCount))) {
            thinkingPhase = 1
        }
    }

    private func isThinking(_ render: PillRender) -> Bool {
        render.isVisible && (render.state == .finalizing || render.state == .refining)
    }

    /// The body's arrival. The panel's own 90 ms fade + 4 pt rise (§2.5 row 1)
    /// is unchanged; this is the capsule springing up to meet it.
    ///
    /// The reset happens on the way *out*, while the panel is already ordered
    /// out — `Pill.apply` holds the last visible frame through the hide sink —
    /// so the spring always has a smaller value to start from and the shrink is
    /// never on screen.
    private func stageArrival(from old: PillRender, to new: PillRender) {
        guard new.isVisible != old.isVisible else { return }
        guard new.isVisible else {
            withTransaction(Transaction(animation: nil)) { arrived = false }
            return
        }
        guard !reduceMotion else {
            withTransaction(Transaction(animation: nil)) { arrived = true }
            return
        }
        withAnimation(.spring(response: PillMotion.appearSpringResponse,
                              dampingFraction: PillMotion.appearSpringDamping)) {
            arrived = true
        }
    }

    private func stageCheck(from old: PillRender, to new: PillRender) {
        guard new.glyph != old.glyph else { return }
        guard new.glyph == .checkmark else {
            withTransaction(Transaction(animation: nil)) { checkDrawn = false }
            return
        }
        guard !reduceMotion else {
            withTransaction(Transaction(animation: nil)) { checkDrawn = true }
            return
        }
        withAnimation(.easeOut(duration: PillMotion.checkDrawDuration)) { checkDrawn = true }
    }

    // MARK: - palette

    private func color(_ c: PillColor) -> Color {
        Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: 1)
    }

    private func textColor(_ render: PillRender) -> PillColor {
        // The dead-mic and patience cues are notices, not alarms: muted ink,
        // never orange (R10 — the mic is open, so the bars keep the tally
        // colour; the text must not borrow it).
        if render.tailMuted { return PillPalette.muted }
        switch render.state {
        case .error, .blockedSecure: return PillPalette.tint(for: render.state)
        case .missed: return PillPalette.muted
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
        case .missed: return render.message.isEmpty ? PillGeometry.missedMessage : render.message
        case .idle: return "Ready"
        }
    }
}

// MARK: - the meter's animated lanes

/// The pill's meter with the three §2.5 animations `TallyWaveform` itself must
/// never carry: the bar tint crossfade (`liveness`, muted ↔ hot), the staggered
/// collapse (`collapsePhase` over `collapseBase`), and the thinking wave
/// (`thinkingPhase`). One `Animatable` scalar triple, one `Canvas` underneath,
/// no per-bar view identity — the per-bar delays and crest heights come
/// precomputed from `PillMotion` (§2.12's constraint).
///
/// Steady states cost nothing: while recording, `liveness == 1`,
/// `collapsePhase == 1` and `thinkingPhase == 0`, so `displayedLevels` returns
/// the model's array without touching it and the only redraws are the level
/// ticks TallyWaveform was already drawing — and silence never reaches this
/// view at all.
private struct PillMeter: View, Animatable {
    var levels: [Double]
    var metrics: TallyMetrics
    /// 0 = `studioMuted`, 1 = mic-orange. Only 1 while the mic is open (§1.6).
    var liveness: Double
    /// Pre-collapse levels (oldest first), empty when no collapse is playing.
    var collapseBase: [Double]
    /// 0 → 1 across `PillMotion.collapseDuration`.
    var collapsePhase: Double
    /// 0 → 1 across `PillMotion.thinkingCycle`, looping. 0 means "not thinking".
    var thinkingPhase: Double
    @Environment(\.colorScheme) private var colorScheme

    var animatableData: AnimatablePair<Double, AnimatablePair<Double, Double>> {
        get { AnimatablePair(liveness, AnimatablePair(collapsePhase, thinkingPhase)) }
        set {
            liveness = newValue.first
            collapsePhase = newValue.second.first
            thinkingPhase = newValue.second.second
        }
    }

    var body: some View {
        TallyWaveform(levels: displayedLevels, metrics: metrics, color: blendedColor)
    }

    /// While the collapse plays, draw the snapshot staggering down to floor; at
    /// phase 1 the drawn levels equal the model's truth (all floor). The
    /// thinking crest then rides over whatever that leaves, so the two never
    /// fight: during the collapse the crest is still off the left edge, and by
    /// the time it arrives the bars are dots.
    private var displayedLevels: [Double] {
        let base: [Double]
        if collapsePhase < 1, !collapseBase.isEmpty {
            let count = collapseBase.count
            base = collapseBase.enumerated().map { index, value in
                value * (1 - PillMotion.collapseProgress(phase: collapsePhase,
                                                         bar: index, barCount: count))
            }
        } else {
            base = levels
        }
        guard thinkingPhase > 0 else { return base }
        let count = base.count
        return base.enumerated().map { index, value in
            max(value, PillMotion.thinkingLevel(phase: thinkingPhase,
                                                bar: index, barCount: count))
        }
    }

    /// The tint crossfade, interpolated in sRGB between the same two colours
    /// the static states use — `studioMuted` is appearance-independent and
    /// `hot` resolves per appearance, so the endpoints match `Theme` exactly.
    private var blendedColor: Color {
        let rest = PillPalette.cream
        let hot = PillColor(hex: colorScheme == .light
                                ? Theme.Token.hot.light
                                : Theme.Token.hot.dark)
        let t = min(1.0, max(0.0, liveness))
        return Color(.sRGB,
                     red: rest.r + (hot.r - rest.r) * t,
                     green: rest.g + (hot.g - rest.g) * t,
                     blue: rest.b + (hot.b - rest.b) * t,
                     opacity: 1)
    }
}

// MARK: - the drawn check mark

/// The commit glyph, as a path so it can stroke itself on.
///
/// Proportions are the SF Symbol's, in a unit box: a short leg dropping to the
/// low point at 40% across, then the long leg rising past it. Trimming runs
/// along the path in that order, which is the order a hand draws it in.
struct CheckStroke: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.14,
                              y: rect.minY + rect.height * 0.54))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.40,
                                 y: rect.minY + rect.height * 0.80))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.86,
                                 y: rect.minY + rect.height * 0.22))
        return path
    }
}
#endif
