#if canImport(SwiftUI)
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

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
    @ObservationIgnored public var onHover: ((Bool) -> Void)?
    @ObservationIgnored public var onCancel: (() -> Void)?
    @ObservationIgnored public var onConfirm: (() -> Void)?
    @ObservationIgnored public var onStart: (() -> Void)?
    @ObservationIgnored public var onDrag: ((CGPoint) -> Void)?
    @ObservationIgnored public var onDragEnded: (() -> Void)?
    @ObservationIgnored public var onDragCancelled: (() -> Void)?

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
/// 3. **The empty-state wiggle lives on the panel, not in this view.** The
///    hosting view clips to the panel, so a SwiftUI shake would slice itself
///    off at the edges. `Pill.beginShake` moves the `NSPanel` instead — the
///    same decaying sine as a password-field "no". Hover chrome buttons stay
///    inside the capsule (press scale 0.97, never past the circle).
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
            .frame(width: render.axis == .vertical ? render.height : render.totalWidth,
                   height: render.axis == .vertical ? render.totalWidth : render.height,
                   alignment: .center)
            .background(body(for: render))
            .scaleEffect(arrived ? 1 : PillMotion.appearScale)
            .opacity(render.isVisible ? 1 : 0)
            .onHover { hovering in
                hovered = hovering
                box.onHover?(hovering)
            }
            .animation(.easeOut(duration: 0.14), value: hovered)
            .simultaneousGesture(dragGesture())
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
        let boost = ((hovered && (state == .idle || state == .recording || state == .prewarming))
                        ? PillPalette.rimHoverBoost : 0)
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
        let holdingRoom = !hasTail && render.totalWidth > PillGeometry.widthListening
            && (render.state == .finalizing || render.state == .refining)
        let compact = hasTail || holdingRoom
        let chrome = render.hoverChrome
        let vertical = render.axis == .vertical
        let meterRotation = PillPlacement.meterRotation(edge: render.dockEdge)

        chromeStack(vertical: vertical, spacing: chrome == .none ? PillTailGeometry.gap : PillGeometry.chromeGap) {
            if chrome == .recording {
                chromeButton(symbol: "xmark", label: "Cancel dictation") {
                    box.onCancel?()
                }
            }
            if !meter.targets.isEmpty {
                meterView(meter, render: render, rotation: meterRotation, vertical: vertical)
            }
            glyph(render)
            if hasTail {
                Text(render.bubble)
                    .font(Theme.font(Theme.Role.mono))
                    .foregroundStyle(color(textColor(render)).opacity(PillPalette.textAlpha))
                    .lineLimit(1)
                    .truncationMode(truncationMode(render.state))
                    .frame(width: vertical ? render.height - 8 : render.bubbleWidth,
                           alignment: .leading)
                    .rotationEffect(.degrees(vertical ? 90 : 0))
                    .frame(width: vertical ? render.height - 8 : render.bubbleWidth,
                           height: vertical ? min(render.bubbleWidth, 80) : render.height,
                           alignment: .center)
                    .transition(.opacity)
            }
            if chrome == .recording {
                chromeButton(symbol: "checkmark", label: "Stop dictation") {
                    box.onConfirm?()
                }
            }
        }
        .padding(.horizontal, compact && !vertical ? PillTailGeometry.textInset : (chrome == .none ? 0 : 10))
        .padding(.vertical, vertical && chrome != .none ? 10 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity,
               alignment: compact ? (vertical ? .top : .leading) : .center)
        .overlay(alignment: vertical ? .bottom : .trailing) {
            if meter.spinning {
                PillSpinnerView(spinning: true, animated: !reduceMotion)
                    .frame(width: PillGeometry.spinnerBox, height: PillGeometry.spinnerBox)
                    .padding(vertical ? .bottom : .trailing, PillTailGeometry.textInset)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: PillMotion.committedDuration), value: render.glyph)
        .animation(.easeOut(duration: PillMotion.widthDuration), value: hasTail)
        .animation(.easeOut(duration: PillMotion.orientationDuration), value: render.axis)
        .modifier(PillAccessibility(render: render, chrome: chrome))
        .modifier(IdleStartTap(enabled: render.state == .idle && !render.isShaking) {
            box.onStart?()
        })
    }

    @ViewBuilder
    private func chromeStack<Content: View>(vertical: Bool, spacing: Double,
                                            @ViewBuilder content: () -> Content) -> some View {
        if vertical {
            VStack(spacing: spacing) { content() }
        } else {
            HStack(spacing: spacing) { content() }
        }
    }

    private func meterView(_ meter: PillMeterFrame, render: PillRender,
                           rotation: Double, vertical: Bool) -> some View {
        let field = PillGeometry.barFieldWidth
        let short = render.height
        return PillMeterView(frame: meter, box: box)
            .frame(width: field, height: short)
            .rotationEffect(.degrees(vertical ? rotation : 0))
            .frame(width: vertical ? short : field,
                   height: vertical ? field : short)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func chromeButton(symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(color(PillPalette.ink).opacity(0.92))
                .frame(width: PillGeometry.chromeButton, height: PillGeometry.chromeButton)
                .contentShape(Circle())
        }
        .buttonStyle(PillChromeButtonStyle())
        .accessibilityLabel(label)
        .help(label)
    }

    private func dragGesture() -> some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { _ in
                #if canImport(AppKit)
                box.onDrag?(NSEvent.mouseLocation)
                #endif
            }
            .onEnded { _ in
                box.onDragEnded?()
            }
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

/// Circular hover-chrome control. Press scales to 0.97 — the same physical
/// confirm Apple uses on every tappable chip — and never grows past the
/// circle, so the hosting view cannot clip it.
private struct PillChromeButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                Circle()
                    .fill(Color.white.opacity(configuration.isPressed ? 0.18 : 0.10))
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

private struct IdleStartTap: ViewModifier {
    let enabled: Bool
    let action: () -> Void

    func body(content: Content) -> some View {
        if enabled {
            content.onTapGesture(perform: action)
        } else {
            content
        }
    }
}

private struct PillAccessibility: ViewModifier {
    let render: PillRender
    let chrome: PillHoverChrome

    func body(content: Content) -> some View {
        if chrome == .recording {
            content
                .accessibilityElement(children: .contain)
                .accessibilityLabel(label)
        } else {
            content
                .accessibilityElement()
                .accessibilityLabel(label)
                .accessibilityAddTraits(.isStaticText)
        }
    }

    private var label: String {
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
        case .idle: return chrome == .idle ? "Click to start dictating" : "Ready"
        }
    }
}
#endif
