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

    /// The 20 Hz bypass.
    ///
    /// `PillMeterView` registers the meter's layer view here when it is built.
    /// `Pill.apply` offers every meter-only render to this sink first, and when
    /// the sink takes it (returning true) the render is *never* written to
    /// `render` — so during steady dictation the SwiftUI view tree is asked for
    /// nothing at all and the only per-tick work is one `CATransaction`.
    ///
    /// `@ObservationIgnored` because it is wiring, not state: a view that
    /// observed its own registration would invalidate itself on attach.
    @ObservationIgnored public var meterSink: ((PillRender) -> Bool)?

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
/// 2. **It never stops telling the truth about time.** Listening is the voice,
///    interpolated at the display's own rate; finalizing and refining are a
///    discrete eight-tick spinner beside a dimmed dot row; the commit is the
///    pill going quiet. One vocabulary, and no element that moves without
///    meaning something.
/// 3. **Nothing shakes, nothing pops out of its own panel.** The hosting view
///    clips to the panel, so the old hover scale and error shake were slicing
///    themselves off at the edges. Both are now edge-light changes, which is
///    also the calmer reading of an error.
///
/// The meter is deliberately *not* drawn here. It is an `NSViewRepresentable`
/// over ten `CALayer`s, and level ticks reach it through `PillRenderBox`'s
/// meter sink without ever invalidating this view — see `PillMeterLayer.swift`.
/// Everything in this file is state-change-only, which is what lets a 20 Hz
/// meter share a main thread with the CGEventTap.
public struct PillSurface: View {
    private let box: PillRenderBox
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Reduce Transparency: the panel drops its material, so the body has to
    /// stop counting on one. Read here *and* in `Pill` from the same system
    /// signal, which is what keeps the two layers in agreement.
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    /// Increase Contrast: one solid edge instead of a lit one.
    @Environment(\.colorSchemeContrast) private var contrast
    /// The body's arrival spring. Reset while the panel is off screen, so the
    /// spring always has somewhere to come from.
    @State private var arrived = true
    /// The committed check mark's stroke, 0…1. Nothing emits `.checkmark` any
    /// more (the commit has no glyph — see `PillModel.glyph`); the lane is kept
    /// because the notice path is the one place a check could honestly return,
    /// and it costs a `Shape` and four lines to leave the door open.
    @State private var checkDrawn = false
    /// The toast's edge-light pop: a notice landing brightens the rim for
    /// 133 ms, which is Wispr's own toast pop timing on our own chrome.
    @State private var noticePop = false
    @State private var hovered = false

    public init(box: PillRenderBox) {
        self.box = box
    }

    public var body: some View {
        let render = box.render

        content(render)
            // The capsule is drawn at exactly the width `Pill` says, and
            // `Pill` says the width the *window* has at this instant — see
            // `windowDidResize`. Anything looser and the drawn shape and the
            // panel disagree for the length of a width animation, which is not
            // a subtle thing: a capsule centred in a narrower panel has both of
            // its caps clipped off and comes out a hard-edged slab.
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
        // whole hover affordance now, and it cannot clip. A landing notice
        // borrows the same lane for 133 ms — Wispr's toast pops its capsule as
        // it unfolds, and an edge that brightens is the version of that pop
        // which cannot be sheared off by the panel.
        let boost = ((hovered && state == .idle) ? PillPalette.rimHoverBoost : 0)
            + (noticePop ? PillMotion.noticeRimPop : 0)
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
        let meter = PillMeterFrame.make(for: render, reduceMotion: reduceMotion)
        // A wait that follows a live tail is a wide capsule with nothing in it
        // yet, and the processing frame is wide by definition. Lay both out the
        // way the tail laid it out — meter on the left, room on the right —
        // rather than re-centring the meter: the words were on the right, the
        // spinner and the patience copy are about to be on the right, and in
        // between nothing should have moved.
        let holdingRoom = !hasTail && render.totalWidth > PillGeometry.widthListening
            && (render.state == .finalizing || render.state == .refining)
        let compact = hasTail || holdingRoom
        HStack(spacing: PillTailGeometry.gap) {
            if !meter.targets.isEmpty {
                // Ten `CALayer`s the render server owns. Nothing about this
                // view changes at 20 Hz — the level ticks reach the layers
                // through `box.meterSink`, never through here.
                PillMeterView(frame: meter, box: box)
                    .frame(width: PillGeometry.barFieldWidth, height: render.height)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
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
        // The processing chrome sits at the trailing inset, where Flow puts it.
        //
        // An overlay rather than a row member on purpose: the spinner must be
        // pinned to the capsule's own edge whatever width the utterance
        // earned, and a trailing `Spacer` would make the row's width depend on
        // whether the pill is thinking. `PillTailGeometry.spinnerAllowance` is
        // the model's half of the same bargain — it keeps the copy from
        // running underneath this.
        .overlay(alignment: .trailing) {
            if meter.spinning {
                PillSpinnerView(spinning: true, animated: !reduceMotion)
                    .frame(width: PillGeometry.spinnerBox, height: PillGeometry.spinnerBox)
                    .padding(.trailing, PillTailGeometry.textInset)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .transition(.opacity)
            }
        }
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

    /// A drawn check mark, kept for the one path that could still want one.
    ///
    /// The commit no longer has a glyph at all — Flow has none, and the text
    /// arriving in the field is the confirmation — but a check that strokes
    /// itself in 220 ms is the act of succeeding rather than a picture of it,
    /// and the notice path ("Learned Sharique") is where that could honestly
    /// return. Everything else is an SF Symbol, which is right for a lock, a
    /// warning and a sparkle.
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
    /// change that reaches SwiftUI. A level tick reaches neither this closure
    /// nor the view (the meter sink consumes it), and even if one did, it
    /// changes no state, no visibility, no glyph and no message — so it leaves
    /// on the first line and touches no `@State` at all.
    private func stage(from old: PillRender, to new: PillRender) {
        guard old.state != new.state
                || old.isVisible != new.isVisible
                || old.glyph != new.glyph
                || old.message != new.message else { return }
        stageArrival(from: old, to: new)
        stageCheck(from: old, to: new)
        stageNotice(from: old, to: new)
    }

    /// The toast's edge-light pop.
    ///
    /// Wispr's own toast pops its capsule to a 34.4 pt circle in 133 ms before
    /// unfolding to full width; our capsule is already on screen, so what pops
    /// is its edge. It lands with the unfold (which `Pill.apply` is animating
    /// on the panel frame at the same instant) and decays behind it, so the
    /// two read as one arrival rather than as a light and then a widening.
    private func stageNotice(from old: PillRender, to new: PillRender) {
        guard old.message.isEmpty, !new.message.isEmpty, new.isVisible else { return }
        guard !reduceMotion else { return }
        withAnimation(.easeOut(duration: PillMotion.noticePopDuration)) { noticePop = true }
        withAnimation(.easeInOut(duration: PillMotion.noticeUnfoldDuration)
                        .delay(PillMotion.noticePopDuration)) { noticePop = false }
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
