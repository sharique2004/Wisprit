#if os(macOS)
import SwiftUI

/// The page that answers the only question a confused user has: *is this thing
/// working, and if not, what do I press?*
///
/// A pinned hero line, then one row per permission with a plain-language
/// sentence and a button that performs the fix, then a scratch field to actually
/// try it. Above the hero, and only while macOS is holding the dictation key
/// hostage, the Secure Keyboard Entry banner.
struct StatusView: View {
    @ObservedObject var model: WispritWindowModel
    /// Held only so the page can prove it is *not* focusing the try-it field on
    /// open. A `TextEditor` that becomes first responder makes AppKit scroll the
    /// enclosing scroll view to reveal it, which pushed the permission rows off
    /// the top of a page tall enough to scroll.
    @FocusState private var playgroundFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                checklist
                playground
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        // Keep the first row at the top as the page grows. The checklist is
        // empty while the first probe runs and then gains seven rows at once,
        // and with no anchor the scroll view holds its old position — which is
        // how the page came up already past Microphone.
        .defaultScrollAnchor(.top)
        // The verdict does not scroll at all.
        //
        // It is the answer to the only question the user opened this window
        // with, and it used to be reachable by scrolling away: on any install
        // with a few transcripts behind it the page opened past the hero AND
        // past all three permissions. Pinning it is the one fix that cannot
        // regress, and it is worth more than the vertical space — the hero stays
        // on screen while the user reads down the list and while they use the
        // try-it box.
        //
        // Every scroll-position remedy was tried first and rejected: `scrollTo`
        // and an initial-offset anchor both align content with the scroll view's
        // own top, which under a `fullSizeContentView` titlebar is *behind* the
        // toolbar — the headline came back blurred instead of missing.
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                if let notice = model.secureInputNotice {
                    secureInputBanner(notice)
                }
                hero
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
        }
        .onAppear { playgroundFocused = false }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.beginOnboarding(resuming: false)
                } label: {
                    Label("Setup Guide", systemImage: "list.number")
                }
                .help("Walk through first-run setup again")
            }
        }
    }

    // MARK: - Secure input

    /// Above the hero, because while this is on the hero's "Ready" is true and
    /// useless: macOS is not delivering the key to anyone. It is transient, so it
    /// is a banner that comes and goes with the 2-second probe, not a row the
    /// user could ever "fix".
    private func secureInputBanner(_ notice: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lock.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.orange)
            Text(notice)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Hero

    private var hero: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: heroSymbol)
                .font(.system(size: 38, weight: .regular))
                .foregroundStyle(heroTint)
                .frame(width: 52)
            VStack(alignment: .leading, spacing: 5) {
                Text(model.summary.headline)
                    .font(.title2).fontWeight(.semibold)
                Text(model.summary.subhead)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(heroTint.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
    }

    private var heroSymbol: String {
        switch model.summary.hero {
        case .checking: return "hourglass"
        case .ready: return "checkmark.seal.fill"
        case .needsSetup: return "exclamationmark.triangle.fill"
        }
    }

    private var heroTint: Color {
        switch model.summary.hero {
        case .checking: return .secondary
        case .ready: return .green
        case .needsSetup: return .orange
        }
    }

    // MARK: - Checklist

    private var checklist: some View {
        Card(title: "Permissions & engine") {
            VStack(spacing: 0) {
                ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Divider().padding(.vertical, 10) }
                    row(item)
                }
            }
        }
    }

    private func row(_ item: SetupItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            StatusDot(mark: item.mark, isOff: item.isOff).padding(.top, 2)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(item.title).font(.headline)
                    if item.isOff {
                        Text("off")
                            .font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                    if !item.isEssential {
                        Text("optional")
                            .font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                }
                Text(item.summary)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !item.detail.isEmpty {
                    Text(item.detail)
                        .font(.caption).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let note = item.note {
                    Label(note, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if item.fix != .none || item.secondaryFix != .none {
                    HStack(spacing: 8) {
                        if item.fix != .none {
                            Button(item.fixTitle) { model.fix(item.fix) }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                        }
                        if item.secondaryFix != .none {
                            Button(item.secondaryFixTitle) { model.fix(item.secondaryFix) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                    }
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Try it

    private var playground: some View {
        Card(title: "Try it") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Click in the box, hold \(SetupChecklist.hotkeyLabel(model.hotkey.rawValue)), "
                     + "say something, then let go. The text lands right here.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                TextEditor(text: $model.playgroundText)
                    .font(.body)
                    .focused($playgroundFocused)
                    .frame(minHeight: 84)
                    .padding(6)
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))

                if model.didDictate {
                    Label("Dictation is working.", systemImage: "checkmark.circle.fill")
                        .font(.callout).foregroundStyle(.green)
                }

                if !model.recents.isEmpty {
                    Divider().padding(.vertical, 4)
                    Text("Recent transcripts").font(.headline)
                    ForEach(Array(model.recents.prefix(5).enumerated()), id: \.offset) { _, entry in
                        TranscriptRow(text: entry.text,
                                      subtitle: RelativeTime.string(from: entry.ts)) {
                            model.copy(entry.text)
                        }
                    }
                }
            }
        }
    }
}
#endif
