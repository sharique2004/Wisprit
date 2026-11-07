#if os(macOS)
import Foundation
import WispritEngine
import WispritPersistence

extension WindowSettings {
    /// `capture_backend` — which Core Audio path opens the microphone. Raw
    /// values are `MicCapture.Backend`'s; anything else on disk reads as the
    /// default (`hal`), exactly as `CaptureBackendSettings.backend` does.
    public enum CaptureBackendOption: String, Sendable, Equatable, CaseIterable {
        case hal
        case engine

        public var label: String {
            switch self {
            case .hal: return "Core Audio (recommended)"
            case .engine: return "AVAudioEngine"
            }
        }

        public static func parse(_ raw: String?) -> CaptureBackendOption {
            raw.flatMap(CaptureBackendOption.init(rawValue:)) ?? .hal
        }
    }
}

/// The Settings window's half of the model: keys the old single-scroll page
/// never surfaced, the Language rule, and the window's own refresh.
///
/// No new `@Published` mirrors — an extension cannot add stored state, and these
/// do not need it: each getter is one locked dictionary read on `Settings`, and
/// each setter announces the change before its single `Settings.set`, so SwiftUI
/// re-reads exactly as it does for the mirrored keys. Every key here already
/// exists, either in `Settings.defaults` (`emoji_commands`,
/// `identity_expansion`) or string-keyed beside it like `vocabulary_retro`.
extension WispritWindowModel {

    // MARK: - Writing

    /// `emoji_commands` — "fire emoji" types 🔥. Read per utterance.
    public var emojiCommands: Bool { settings.emojiCommands }

    public func setEmojiCommands(_ value: Bool) {
        objectWillChange.send()
        settings.set(SettingsKey.emojiCommands, value)
    }

    /// `identity_expansion` — "my email" types the saved address. Inert while
    /// no value is saved, so on is harmless; off is the kill switch.
    public var identityExpansion: Bool { settings.identityExpansion }

    public func setIdentityExpansion(_ value: Bool) {
        objectWillChange.send()
        settings.set(SettingsKey.identityExpansion, value)
    }

    // MARK: - General

    /// `sounds` — the mic-open and commit cues. Explicit choice wins over the
    /// pending default (see `SoundCueSettings`).
    public var soundCues: Bool { SoundCueSettings.isEnabled(settings) }

    public func setSoundCues(_ value: Bool) {
        objectWillChange.send()
        SoundCueSettings.setEnabled(settings, value)
    }

    // MARK: - Privacy

    /// `history_detail` — whether the heard/written triple is stored beside
    /// each transcript. Honored at launch (`History` takes it at init).
    public var historyDetail: Bool { HistoryDetailSettings.isEnabled(settings) }

    public func setHistoryDetail(_ value: Bool) {
        objectWillChange.send()
        HistoryDetailSettings.setEnabled(settings, value)
    }

    // MARK: - Advanced

    /// `capture_backend` — read per press, so a flip needs no restart.
    public var captureBackend: WindowSettings.CaptureBackendOption {
        .parse(settings.string(CaptureBackendSettings.key))
    }

    public func setCaptureBackend(_ value: WindowSettings.CaptureBackendOption) {
        objectWillChange.send()
        settings.set(CaptureBackendSettings.key, value.rawValue)
    }

    /// `keyup_grace_adaptive` — stretch the key-up grace while the trailing
    /// audio is still speech (bounded by the 500 ms clamp).
    public var adaptiveGrace: Bool { KeyupGraceAdaptiveSettings.isEnabled(settings) }

    public func setAdaptiveGrace(_ value: Bool) {
        objectWillChange.send()
        settings.set(KeyupGraceAdaptiveSettings.key, value)
    }

    /// Put every Advanced-pane knob back to its shipped value, through the
    /// same setters the controls use. Nothing outside that pane moves — not
    /// the dictation key, not the language, not consent.
    /// Only a knob that is off its default is written, so a config that never
    /// named a key does not grow one.
    public func restoreDefaultTuning() {
        let d = TuningDefaults()
        if holdDebounceMs != d.holdDebounceMs { setHoldDebounceMs(d.holdDebounceMs) }
        if keyupGraceMs != d.keyupGraceMs { setKeyupGraceMs(d.keyupGraceMs) }
        if adaptiveGrace != d.adaptiveGrace { setAdaptiveGrace(d.adaptiveGrace) }
        if finalizeTimeoutMs != d.finalizeTimeoutMs { setFinalizeTimeoutMs(d.finalizeTimeoutMs) }
        if pasteRestoreDelayMs != d.pasteRestoreDelayMs { setPasteRestoreDelayMs(d.pasteRestoreDelayMs) }
        if aiCleanupMaxWords != d.aiCleanupMaxWords { setAiCleanupMaxWords(d.aiCleanupMaxWords) }
        if aiCleanupTimeoutMs != d.aiCleanupTimeoutMs { setAiCleanupTimeoutMs(d.aiCleanupTimeoutMs) }
        if engine != .auto { setEngine(.auto) }
        if captureBackend != .hal { setCaptureBackend(.hal) }
        if imSelectionPolicy != .warm { setImSelectionPolicy(.warm) }
    }

    /// Whether `restoreDefaultTuning` would change anything — the button is
    /// disabled when it would not.
    public var isTuningAtDefaults: Bool {
        let d = TuningDefaults()
        return holdDebounceMs == d.holdDebounceMs
            && keyupGraceMs == d.keyupGraceMs
            && adaptiveGrace == d.adaptiveGrace
            && finalizeTimeoutMs == d.finalizeTimeoutMs
            && pasteRestoreDelayMs == d.pasteRestoreDelayMs
            && aiCleanupMaxWords == d.aiCleanupMaxWords
            && aiCleanupTimeoutMs == d.aiCleanupTimeoutMs
            && engine == .auto
            && captureBackend == .hal
            && imSelectionPolicy == .warm
    }

    /// The shipped values, read from `Settings.defaults` (the golden-pinned
    /// source) where the key lives there.
    private struct TuningDefaults {
        var holdDebounceMs = WindowSettings.clampHoldDebounce(shippedInt(SettingsKey.holdDebounceMs, 150))
        var keyupGraceMs = WindowSettings.keyupGraceDefault
        var adaptiveGrace = KeyupGraceAdaptiveSettings.defaultEnabled
        var finalizeTimeoutMs = WindowSettings.clampFinalizeTimeout(shippedInt(SettingsKey.finalizeTimeoutMs, 1500))
        var pasteRestoreDelayMs = WindowSettings.clampPasteRestore(shippedInt(SettingsKey.pasteRestoreDelayMs, 500))
        var aiCleanupMaxWords = WindowSettings.clampAiCleanupMaxWords(shippedInt(SettingsKey.aiCleanupMaxWords, 350))
        var aiCleanupTimeoutMs = WindowSettings.clampAiCleanupTimeout(shippedInt(SettingsKey.aiCleanupTimeoutMs, 12000))
    }

    // MARK: - Language

    /// The picker's rows: every installed voice, plus the stored value when no
    /// installed voice matches it (so the picker never draws blank).
    public var languageOptions: [SettingsLanguage.Option] {
        SettingsLanguage.options(installed: facts.installedLocales, current: locale)
    }

    /// Choose a language by option value. The language already stored — in
    /// either spelling — writes nothing; anything else is written in the
    /// hyphen form every consumer reads (see `SettingsLanguage`). A change
    /// re-probes, so Setup's speech row follows the new language.
    public func chooseLanguage(_ value: String) {
        guard let write = SettingsLanguage.write(choosing: value, current: locale) else { return }
        setLocale(write)
        Task { await refreshFull() }
    }

    // MARK: - The window's own refresh

    /// Called when the Settings window opens or comes back to the front: read
    /// the file again (a menu toggle or a hand edit may have moved it), re-stat
    /// the data inventory, and re-probe if the last full probe is stale — the
    /// Microphone pane names the device a headset may have just replaced.
    public func refreshForSettings(now: Date = Date(), staleAfter: TimeInterval = 5) {
        reloadSettings()
        refreshDataInventory()
        // The transcripts delete quotes a count (`historyDeletionWarning`) from
        // the history page, which only the Hub loads. Re-fetch the page the Hub
        // already has — never a reset, which would undo its "load more".
        loadHistory()
        if let last = lastProbeAt, now.timeIntervalSince(last) < staleAfter { return }
        Task { await refreshFull() }
    }
}
/// An integer from the golden-pinned `Settings.defaults`, or `fallback` for a
/// key that is not there.
private func shippedInt(_ key: String, _ fallback: Int) -> Int {
    if case .int(let value)? = Settings.defaults[key] { return value }
    return fallback
}
#endif
